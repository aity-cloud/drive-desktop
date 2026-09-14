#!/usr/bin/env bash
# The NSIS installer takes its window title, Add/Remove Programs entry,
# Publisher, about-URL and Start Menu shortcut from the BLUEPRINT, never from
# OEM.cmake: craft-core's PackagerBase.setDefaults derives productname and
# description from subinfo.displayName/description, and the ownCloud blueprint
# sets company to a literal in createPackage. All of them say ownCloud, which
# meta/AGENTS.md forbids in anything we hand out.
#
# None of these are registered Craft options and only `appname` reads the
# environment, so there is no supported override to use. This rewrites the four
# literals into environment lookups inside the Craft prefix, which is
# disposable and rebuilt from cache - the same shape an upstream blueprint PR
# would take. Values come from the job (APPLICATION_NAME, APPLICATION_VENDOR,
# APPLICATION_WEBSITE, APPLICATION_DESCRIPTION); an unset one keeps upstream's.
#
# It also writes the values for this Environment to build/craft-branding.env as
# KEY=VALUE, because only the job's own shell can export them into the craft
# invocations - reading OEM.cmake here keeps CI from carrying a second copy of
# the product name, which is what drifts when branding changes.
#
#   scripts/craft-blueprint-branding.sh <craft-workspace-root> <production|staging>
set -euo pipefail

ROOT="${1:?usage: $0 <craft-workspace-root> <production|staging>}"
ENV="${2:?usage: $0 <craft-workspace-root> <production|staging>}"
[ -d "$ROOT" ] || { echo "blueprint-branding: no such directory: $ROOT" >&2; exit 1; }

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
OEM="$REPO_ROOT/overlay/$ENV/OEM.cmake"
[ -f "$OEM" ] || { echo "blueprint-branding: no such file: $OEM" >&2; exit 1; }
oem() { sed -n "s/^set($1  *\"\\([^\"]*\\)\").*/\\1/p" "$OEM" | head -n1; }

APP_NAME=$(oem APPLICATION_NAME)
APP_VENDOR=$(oem APPLICATION_VENDOR)
APP_DOMAIN=$(oem APPLICATION_DOMAIN)
APP_ICON=$(oem APPLICATION_ICON_NAME)
[ -n "$APP_NAME" ] && [ -n "$APP_VENDOR" ] && [ -n "$APP_DOMAIN" ] && [ -n "$APP_ICON" ] \
    || { echo "blueprint-branding: APPLICATION_NAME/VENDOR/DOMAIN/ICON_NAME missing from $OEM" >&2; exit 1; }

ENV_FILE="$REPO_ROOT/build/craft-branding.env"
mkdir -p "$(dirname "$ENV_FILE")"
cat > "$ENV_FILE" <<ENVEOF
APPLICATION_NAME=$APP_NAME
APPLICATION_VENDOR=$APP_VENDOR
APPLICATION_WEBSITE=https://$APP_DOMAIN
APPLICATION_DESCRIPTION=$APP_NAME sync client
APPLICATION_ICON_NAME=$APP_ICON
ENVEOF
echo "blueprint-branding: $ENV branding from $OEM"
sed 's/^/      /' "$ENV_FILE"

mapfile -t FILES < <(find "$ROOT" -type f -path '*owncloud/owncloud-client/owncloud-client.py' 2>/dev/null)
[ ${#FILES[@]} -gt 0 ] || { echo "blueprint-branding: found no owncloud-client.py under $ROOT" >&2; exit 1; }

echo "blueprint-branding: ${#FILES[@]} blueprint file(s) under $ROOT"
for f in "${FILES[@]}"; do
    echo "  $f"
    grep -nE 'displayName|self\.description|self\.webpage|defines\["company"\]' "$f" | sed 's/^/      /'
done

# git-bash on the Windows runner ships `python`, not `python3` (that cost a
# 26 minute job), while macOS and the Linux images have only `python3`.
PYTHON=$(command -v python3 || command -v python || true)
[ -n "$PYTHON" ] || { echo "blueprint-branding: no python3 or python on PATH" >&2; exit 1; }
echo "blueprint-branding: using $PYTHON"

"$PYTHON" - "${FILES[@]}" <<'PY'
import sys

# (literal in the blueprint, environment variable that should win)
SUBS = [
    ('self.description = "ownCloud Desktop Client"', "APPLICATION_DESCRIPTION"),
    ('self.displayName = "ownCloud"', "APPLICATION_NAME"),
    ('self.webpage = "https://github.com/owncloud/client"', "APPLICATION_WEBSITE"),
    ('self.defines["company"] = "ownCloud GmbH"', "APPLICATION_VENDOR"),
]

handled = 0
for path in sys.argv[1:]:
    src = open(path, encoding="utf-8").read()
    if "os.environ.get(\"APPLICATION_NAME\")" in src:
        print(f"blueprint-branding: already applied to {path}")
        handled += 1
        continue
    changed = 0
    for literal, var in SUBS:
        if literal not in src:
            print(f"blueprint-branding: NOT FOUND in {path}: {literal}")
            continue
        lhs, rhs = literal.split(" = ", 1)
        src = src.replace(literal, f'{lhs} = os.environ.get("{var}") or {rhs}')
        changed += 1
    # The DMG's VOLUME name - what the user sees after mounting - is derived
    # from defines["setupname"], which defaults to the blueprint's archive
    # name (owncloud-client-HEAD-<n>-macos-clang-arm64). That holds on both
    # the old create-dmg path and the dmgbuild one the fork moved to, so
    # overriding setupname fixes it without touching either packager. Only
    # applies when the job asks for it, so Windows and Linux filenames are
    # untouched.
    # The installer ships this file into the install directory as the
    # uninstall entry's icon, so its NAME is handed to the customer too - it
    # was arriving as owncloud.ico. Pointing the define at the branded icon
    # also retires the CI step that copied our .ico onto that name.
    icon_old = 'self.defines["icon"] = self.buildDir() / "src/gui/owncloud.ico"'
    icon_new = ('self.defines["icon"] = self.buildDir() / '
                'f"src/gui/{os.environ.get(\'APPLICATION_ICON_NAME\') or \'owncloud\'}.ico"')
    if icon_old in src:
        src = src.replace(icon_old, icon_new)
        changed += 1
    else:
        print(f"blueprint-branding: NOT FOUND in {path}: the icon define")

    anchor = '        self.defines["company"] = os.environ.get("APPLICATION_VENDOR")'
    if "APPLICATION_SETUPNAME" not in src:
        for line in src.split("\n"):
            if line.startswith(anchor):
                src = src.replace(
                    line,
                    line
                    + '\n        if os.environ.get("APPLICATION_SETUPNAME"):'
                    + '\n            self.defines["setupname"] = self.packageDestinationDir() / os.environ["APPLICATION_SETUPNAME"]',
                )
                changed += 1
                break
        else:
            print(f"blueprint-branding: NO company line to anchor setupname to in {path}")

    if changed:
        open(path, "w", encoding="utf-8").write(src)
        handled += 1
    print(f"blueprint-branding: rewrote {changed} branding site(s) in {path}")

# A silent no-op here ships an installer branded ownCloud, so refuse to be one.
if handled == 0:
    sys.exit("blueprint-branding: patched NOTHING - the blueprint changed shape, fix this script")
PY
