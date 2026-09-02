#!/usr/bin/env python3
"""The sync smoke's two phases, driven by scripts/smoke-sync.sh.

seed    Sign in to the Environment's realm as drive-desktop (authorization
        code + PKCE against the realm's identity-first login pages) and
        plant everything the branded client needs to sync headlessly:
          - the .cfg account entry: url, dav_user (ocs/cloud/user id),
            display-name, uuid, default_sync_root, and the LIVE capabilities
            map - serialised by Qt itself via PyQt6, because an account whose
            stored capabilities do not parse as a spaces-enabled QVariantMap
            is DELETED at load (AccountManager::loadAccountHelper),
          - one Folder definition for the personal space (the default theme
            does not auto-sync discovered spaces: syncNewlyDiscoveredSpaces()
            is false, so with no Folders group nothing would ever sync),
          - the cfg's [Credentials/<scope>] bookkeeping entry - the client
            only asks the keychain for keys listed there ("We don't know
            <key>, skipping retrieval from keychain") - and the refresh
            token in the Secret Service keychain the exact way qtkeychain
            0.15's libsecret backend stores it: service = branded app name,
            key = <appName>_credentials:<host>:<uuid>:http/oauthtoken,
            secret = base64 of a CBOR text string, in a type=base64 item.
        The client does the rest by itself: refreshes the access token,
        connects, and syncs the seeded folder.

verify  Prove a real file round-trip through the RUNNING client:
        local file -> appears on the server, server-side PUT -> appears
        locally. Uses its own password-grant token on the `drive` client
        (the one the realm allows it on, same as meta's drive_contract.py) -
        NOT the client's drive-desktop tokens, which Keycloak rotates on the
        client's first refresh. Sweeps stale smoke-sync-* litter first and
        deletes everything it created (staging hygiene).

Credentials come from AITY_CONTRACT_USER / AITY_CONTRACT_PASSWORD.
seed needs python3-pyqt6 + python3-secretstorage and a running Secret
Service; verify is stdlib-only.
"""
import argparse
import base64
import hashlib
import html
import http.cookiejar
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid as uuidlib

sys.stdout.reconfigure(line_buffering=True)

TIMEOUT = 30
UP_SYNC_TIMEOUT = 180     # local change -> server (inotify, usually seconds)
DOWN_SYNC_TIMEOUT = 240   # server change -> local (remote poll interval is 60s)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(newurl, code, msg, headers, fp)


def login_authcode(issuer, client_id, redirect_uri, username, password):
    """The browser flow drive_client_auth.py proves; returns the token reply."""
    verifier = base64.urlsafe_b64encode(os.urandom(40)).rstrip(b"=").decode()
    challenge = base64.urlsafe_b64encode(
        hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    noredir = urllib.request.build_opener(
        urllib.request.HTTPCookieProcessor(jar), NoRedirect)

    query = urllib.parse.urlencode({
        "client_id": client_id, "response_type": "code",
        "scope": "openid profile email offline_access",
        "redirect_uri": redirect_uri, "code_challenge": challenge,
        "code_challenge_method": "S256", "state": "smoke", "nonce": "smoke",
    })
    page = opener.open(f"{issuer}/protocol/openid-connect/auth?{query}",
                       timeout=TIMEOUT).read().decode("utf-8", "replace")

    def action_of(page):
        m = re.search(r'"loginAction"\s*:\s*"([^"]+)"', page)
        if not m:
            raise SystemExit("smoke-sync: no loginAction on the login page")
        return html.unescape(m.group(1)).replace("\\/", "/")

    def post(url, fields):
        req = urllib.request.Request(
            url, data=urllib.parse.urlencode(fields).encode(),
            headers={"Content-Type": "application/x-www-form-urlencoded"})
        try:
            return noredir.open(req, timeout=TIMEOUT).read().decode("utf-8", "replace"), None
        except urllib.error.HTTPError as err:
            if 300 <= err.code < 400:
                return "", err.headers.get("Location", "")
            return err.read().decode("utf-8", "replace"), None

    # identity-first realm: username page first, then the password page;
    # posting both at once silently redisplays page 1 (meta/contract/README.md)
    page2, location = post(action_of(page), {"username": username})
    if location is None:
        _, location = post(action_of(page2), {"password": password, "credentialId": ""})
    if not location or not location.startswith(redirect_uri):
        raise SystemExit(f"smoke-sync: login did not redirect to {redirect_uri}: {location!r}")
    code = urllib.parse.parse_qs(urllib.parse.urlparse(location).query)["code"][0]

    return json.loads(urllib.request.urlopen(urllib.request.Request(
        f"{issuer}/protocol/openid-connect/token",
        data=urllib.parse.urlencode({
            "grant_type": "authorization_code", "client_id": client_id,
            "code": code, "redirect_uri": redirect_uri,
            "code_verifier": verifier}).encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"}),
        timeout=TIMEOUT).read())


def get_json(url, token):
    return json.loads(urllib.request.urlopen(urllib.request.Request(
        url, headers={"Authorization": "Bearer " + token}), timeout=TIMEOUT).read())


def cbor_text(s: str) -> bytes:
    """CBOR text string (major type 3) - the shape CredentialManager stores."""
    b = s.encode()
    n = len(b)
    if n < 24:
        return bytes([0x60 + n]) + b
    if n < 0x100:
        return bytes([0x78, n]) + b
    if n < 0x10000:
        return b"\x79" + n.to_bytes(2, "big") + b
    return b"\x7a" + n.to_bytes(4, "big") + b


def seed(args, username, password):
    tokens = login_authcode(args.issuer, "drive-desktop", "http://127.0.0.1:51234",
                            username, password)
    access, refresh = tokens["access_token"], tokens["refresh_token"]
    print("smoke-sync seed: signed in as drive-desktop")

    base = args.base_url.rstrip("/")
    user = get_json(f"{base}/ocs/v2.php/cloud/user?format=json", access)["ocs"]["data"]
    caps = get_json(f"{base}/ocs/v2.php/cloud/capabilities?format=json",
                    access)["ocs"]["data"]["capabilities"]
    if not caps.get("spaces", {}).get("enabled"):
        raise SystemExit("smoke-sync: capabilities do not advertise spaces - "
                         "the client would delete the seeded account at load")
    drives = get_json(f"{base}/graph/v1.0/me/drives", access)["value"]
    personal = next((d for d in drives if d.get("driveType") == "personal"), None)
    if personal is None:
        raise SystemExit("smoke-sync: no personal space for the contract user")
    dav_url = personal["root"]["webDavUrl"]
    print(f"smoke-sync seed: user {user['id']}, personal space {personal['id'][:24]}...")

    account_uuid = uuidlib.uuid4()
    local_path = os.path.join(args.sync_root, personal["name"]) + "/"
    os.makedirs(local_path, exist_ok=True)

    from PyQt6.QtCore import QSettings
    os.makedirs(os.path.dirname(args.cfg), exist_ok=True)
    settings = QSettings(args.cfg, QSettings.Format.IniFormat)
    settings.beginGroup("Accounts")
    settings.beginGroup("0")
    settings.setValue("url", args.base_url)
    settings.setValue("dav_user", user["id"])
    settings.setValue("display-name", user.get("display-name", user["id"]))
    settings.setValue("uuid", "{%s}" % account_uuid)
    settings.setValue("default_sync_root", args.sync_root)
    settings.setValue("capabilities", caps)
    settings.beginGroup("Folders")
    settings.beginGroup(str(uuidlib.uuid4()))
    settings.setValue("localPath", local_path)
    settings.setValue("journalPath", ".sync_journal.db")
    settings.setValue("targetPath", "")
    settings.setValue("spaceId", personal["id"])
    settings.setValue("davUrl", dav_url)
    settings.setValue("displayString", personal["name"])
    settings.setValue("paused", False)
    settings.setValue("deployed", False)
    settings.setValue("priority", 0)
    settings.setValue("virtualFilesMode", "off")
    settings.endGroup()
    settings.endGroup()
    settings.endGroup()
    settings.endGroup()

    host = urllib.parse.urlparse(args.base_url).hostname
    scope = f"{args.service}_credentials:{host}:{account_uuid}"
    settings.beginGroup("Credentials")
    settings.beginGroup(scope)
    settings.setValue("http/oauthtoken", True)
    settings.endGroup()
    settings.endGroup()
    settings.sync()
    if settings.status() != QSettings.Status.NoError:
        raise SystemExit(f"smoke-sync: writing {args.cfg} failed: {settings.status()}")

    import secretstorage
    conn = secretstorage.dbus_init()
    collection = secretstorage.get_default_collection(conn)
    if collection.is_locked():
        collection.unlock()
    key = f"{scope}:http/oauthtoken"
    collection.create_item(
        f"{args.service} ({key})",
        {"user": key, "server": args.service, "type": "base64"},
        base64.b64encode(cbor_text(refresh)), replace=True)
    print("smoke-sync seed: cfg + keychain planted, folder "
          f"{local_path} <-> {dav_url}")

    with open(args.state, "w") as f:
        json.dump({"dav_url": dav_url, "local_path": local_path}, f)


class Probe:
    """WebDAV probe with its own password-grant token on the `drive` client
    (re-granted on 401, so a long poll never dies on token expiry)."""

    def __init__(self, issuer, username, password):
        self._issuer = issuer
        self._username = username
        self._password = password
        self._token = self._grant()

    def _grant(self):
        return json.loads(urllib.request.urlopen(urllib.request.Request(
            f"{self._issuer}/protocol/openid-connect/token",
            data=urllib.parse.urlencode({
                "grant_type": "password", "client_id": "drive",
                "scope": "openid profile email",
                "username": self._username, "password": self._password}).encode(),
            headers={"Content-Type": "application/x-www-form-urlencoded"}),
            timeout=TIMEOUT).read())["access_token"]

    def request(self, method, url, data=None, headers=None):
        for attempt in (1, 2):
            req = urllib.request.Request(url, data=data, method=method,
                                         headers=dict(headers or {}))
            req.add_header("Authorization", "Bearer " + self._token)
            try:
                with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
                    return resp.status, resp.read()
            except urllib.error.HTTPError as err:
                if err.code == 401 and attempt == 1:
                    self._token = self._grant()
                    continue
                return err.code, err.read()

    def list_names(self, dav_url):
        status, body = self.request("PROPFIND", dav_url.rstrip("/") + "/",
                                    headers={"Depth": "1"})
        if status != 207:
            raise SystemExit(f"smoke-sync: PROPFIND {dav_url} -> HTTP {status}")
        names = re.findall(r"<[^>]*href[^>]*>([^<]+)</", body.decode("utf-8", "replace"))
        return [urllib.parse.unquote(n.rstrip("/").rsplit("/", 1)[-1]) for n in names]


def verify(args, username, password):
    with open(args.state) as f:
        state = json.load(f)
    dav = state["dav_url"].rstrip("/")
    local = state["local_path"]
    probe = Probe(args.issuer, username, password)

    # 0. sweep litter a previously failed run may have left (staging hygiene)
    stale = [n for n in probe.list_names(dav) if n.startswith("smoke-sync-")]
    for name in stale:
        probe.request("DELETE", f"{dav}/{name}")
        print(f"smoke-sync verify: swept stale {name}")

    run_id = uuidlib.uuid4().hex[:12]
    failures = []

    # 1. local -> server: drop a file into the synced folder, the running
    #    client must upload it. Written OUTSIDE the folder with a backdated
    #    mtime and renamed in atomically: a file whose mtime is the same
    #    second as the discovery trips the propagator's "Local file changed
    #    during sync. It will be resumed." guard, and the resume never
    #    re-examined it (observed against the shipped 7.1.0 client).
    up_name = f"smoke-sync-{run_id}-up.txt"
    up_body = f"aity drive sync smoke (up) {run_id}\n"
    staged = os.path.join(os.path.dirname(local.rstrip("/")), up_name + ".staged")
    with open(staged, "w") as f:
        f.write(up_body)
    past = time.time() - 30
    os.utime(staged, (past, past))
    os.rename(staged, os.path.join(local, up_name))
    deadline = time.time() + UP_SYNC_TIMEOUT
    while time.time() < deadline:
        status, body = probe.request("GET", f"{dav}/{up_name}")
        if status == 200 and body.decode("utf-8", "replace") == up_body:
            print(f"smoke-sync verify: PASS local -> server ({up_name})")
            break
        time.sleep(3)
    else:
        failures.append(f"local file {up_name} never appeared on the server "
                        f"(waited {UP_SYNC_TIMEOUT}s)")

    # 2. server -> local: PUT a file server-side, the running client must
    #    download it (bounded by the client's 60s remote poll interval)
    down_name = f"smoke-sync-{run_id}-down.txt"
    down_body = f"aity drive sync smoke (down) {run_id}\n"
    status, _ = probe.request("PUT", f"{dav}/{down_name}", data=down_body.encode(),
                              headers={"Content-Type": "text/plain"})
    if status not in (201, 204):
        failures.append(f"server-side PUT of {down_name} -> HTTP {status}")
    else:
        local_down = os.path.join(local, down_name)
        deadline = time.time() + DOWN_SYNC_TIMEOUT
        while time.time() < deadline:
            try:
                with open(local_down) as f:
                    if f.read() == down_body:
                        print(f"smoke-sync verify: PASS server -> local ({down_name})")
                        break
            except OSError:
                pass
            time.sleep(3)
        else:
            failures.append(f"server file {down_name} never arrived locally "
                            f"(waited {DOWN_SYNC_TIMEOUT}s)")

    # 3. leave nothing behind, pass or fail (the local copy dies with the job)
    for name in (up_name, down_name):
        probe.request("DELETE", f"{dav}/{name}")

    if failures:
        for f in failures:
            print(f"smoke-sync verify: FAIL - {f}", file=sys.stderr)
        return 1
    print("smoke-sync verify: PASS - a real file round-tripped both ways "
          "through the shipped client")
    return 0


def main():
    p = argparse.ArgumentParser()
    p.add_argument("phase", choices=["seed", "verify"])
    p.add_argument("--issuer", required=True)
    p.add_argument("--base-url", required=True)
    p.add_argument("--state", required=True, help="state file handed from seed to verify")
    p.add_argument("--cfg", help="full path of the client's .cfg (seed)")
    p.add_argument("--service", help="branded app shortname, the keychain service (seed)")
    p.add_argument("--sync-root", help="directory the folder syncs under (seed)")
    args = p.parse_args()

    username = os.environ.get("AITY_CONTRACT_USER", "").strip()
    password = os.environ.get("AITY_CONTRACT_PASSWORD", "").strip()
    if not username or not password:
        print("AITY_CONTRACT_USER / AITY_CONTRACT_PASSWORD are not set", file=sys.stderr)
        return 2

    if args.phase == "seed":
        for required in ("cfg", "service", "sync_root"):
            if not getattr(args, required):
                p.error(f"--{required.replace('_', '-')} is required for seed")
        return seed(args, username, password)
    return verify(args, username, password)


if __name__ == "__main__":
    sys.exit(main())
