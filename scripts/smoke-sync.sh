#!/usr/bin/env bash
# Sync smoke for a produced AppImage: a real file round-trip against the
# Environment's live server, through the SHIPPED client, fully headless.
#
#   scripts/smoke-sync.sh <AppImage> <production|staging>
#
# How: scripts/smoke-sync.py seeds a ready-to-sync account (cfg + Secret
# Service keychain), the AppImage runs under the offscreen Qt platform inside
# a private dbus session with gnome-keyring as the Secret Service, and the
# verify phase proves a file syncs local -> server and server -> local, then
# deletes everything it created. MAINTAINING.md "Sync smoke" has the story
# and the traps.
#
# Needs: dbus (dbus-run-session), gnome-keyring, python3-pyqt6,
# python3-secretstorage, plus the same Qt runtime set as smoke-appimage.sh.
# Credentials: AITY_CONTRACT_USER / AITY_CONTRACT_PASSWORD in the env.
set -euo pipefail

if [ "${1:-}" != "--inner" ]; then
    APPIMAGE="${1:?usage: $0 <AppImage> <production|staging>}"
    ENV="${2:?usage: $0 <AppImage> <production|staging>}"
    # everything below runs on a private session bus; re-enter this script
    exec dbus-run-session -- bash "$0" --inner "$APPIMAGE" "$ENV"
fi
APPIMAGE="$2"
ENV="$3"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

case "$ENV" in
    production)
        SERVICE="aitydrive"
        EXECUTABLE="aity-drive"
        BASE_URL="https://drive.aity.tech"
        ISSUER="https://auth.aity.tech/realms/aity"
        ;;
    staging)
        SERVICE="aitydrive-staging"
        EXECUTABLE="aity-drive-staging"
        BASE_URL="https://drive.aity.works"
        ISSUER="https://auth.aity.works/realms/aity"
        ;;
    *) echo "smoke-sync: unknown environment '$ENV'" >&2; exit 2 ;;
esac

fail() { echo "smoke-sync($ENV): FAIL - $*" >&2; exit 1; }
note() { echo "smoke-sync($ENV): $*"; }

[ -f "$APPIMAGE" ] || fail "no such file: $APPIMAGE"
chmod +x "$APPIMAGE"

WORK=$(mktemp -d)
CLIENT_PID=""
cleanup() {
    # every step tolerant: set -e is live inside this trap, and the killed
    # client's wait status (143) must not become the JOB's exit code - it
    # did exactly that on the first container run (PASS printed, exit 143)
    if [ -n "$CLIENT_PID" ]; then
        kill "$CLIENT_PID" 2>/dev/null || true
        wait "$CLIENT_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

cp "$APPIMAGE" "$WORK/app.AppImage"
cd "$WORK"

# No FUSE in the CI container: extract instead of mounting.
./app.AppImage --appimage-extract >/dev/null 2>&1 || fail "--appimage-extract failed"
[ -d squashfs-root ] || fail "extraction produced no squashfs-root"

# A sandboxed HOME so nothing of the runner (or a developer machine) leaks in.
export HOME="$WORK/home"
export XDG_RUNTIME_DIR="$WORK/xdg-runtime"
mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$WORK/logs"
chmod 700 "$XDG_RUNTIME_DIR"

# qtkeychain needs a Secret Service on this session bus. In a fresh
# container there is no login keyring at all, and CREATING a collection
# over the API needs a GUI prompt (gcr-prompter dies with "cannot open
# display", the CreateCollection prompt is dismissed, the job fails - CI
# job 16251680059). So pre-create a blank-password login keyring on disk:
# gnome-keyring stores blank-password keyrings in this plaintext format,
# and unlocking one over the API succeeds without any prompt.
mkdir -p "$HOME/.local/share/keyrings"
printf '[keyring]\ndisplay-name=login\nctime=0\nmtime=0\nlock-on-idle=false\nlock-after=false\n' \
    > "$HOME/.local/share/keyrings/login.keyring"
printf 'login' > "$HOME/.local/share/keyrings/default"
eval "$(echo -n "" | gnome-keyring-daemon --unlock --components=secrets --daemonize)"
export GNOME_KEYRING_CONTROL
note "keyring up on the private session bus"

STATE="$WORK/state.json"
python3 "$SCRIPT_DIR/smoke-sync.py" seed \
    --issuer "$ISSUER" --base-url "$BASE_URL" --state "$STATE" \
    --cfg "$HOME/.config/$SERVICE/$EXECUTABLE.cfg" \
    --service "$SERVICE" \
    --sync-root "$HOME/sync" || fail "seeding the account failed"

QT_QPA_PLATFORM=offscreen ./squashfs-root/AppRun \
    --logdir "$WORK/logs" --logdebug --logflush &
CLIENT_PID=$!
note "client running (pid $CLIENT_PID), verifying the round-trip"

if ! python3 "$SCRIPT_DIR/smoke-sync.py" verify \
    --issuer "$ISSUER" --base-url "$BASE_URL" --state "$STATE"; then
    echo "smoke-sync($ENV): client log tail:" >&2
    tail -n 100 "$WORK/logs/$SERVICE.log" >&2 || true
    fail "sync round-trip failed"
fi

note "PASS - $APPIMAGE syncs against $BASE_URL"
