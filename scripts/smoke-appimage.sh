#!/usr/bin/env bash
# Branding smoke for a produced AppImage:
#
#   scripts/smoke-appimage.sh <AppImage> <production|staging>
#
# Verifies the facts the Overlay is supposed to bake in, without a server:
#   - the AppImage runs headlessly and --version reports the branded
#     shortname plus the Pin's upstream version,
#   - the Environment's server URL and the drive-desktop OIDC client id are
#     compiled in (Qt string literals are UTF-16, hence strings -e l),
#   - the other Environment's server URL is NOT present,
#   - "Aity Drive" (APPLICATION_NAME) is present,
#   - the updater feed URL is present in production and absent in staging,
#   - the expected executable name is shipped.
#
# Deliberately NOT asserted: absence of upstream's stock OAuth2 client id.
# Theme::oauthClientId()'s default implementation stays compiled into
# libowncloudsync (we override, upstream does not delete), so its literal is
# always present; runtime behaviour is what the override changes.
#
# The real sync round-trip against the live Environment is the separate
# smoke:sync job (scripts/smoke-sync.sh; MAINTAINING.md "Sync smoke").
set -euo pipefail

APPIMAGE="${1:?usage: $0 <AppImage> <production|staging>}"
ENV="${2:?usage: $0 <AppImage> <production|staging>}"

case "$ENV" in
    production)
        SHORTNAME="aitydrive"
        EXECUTABLE="aity-drive"
        SERVER_URL="https://drive.aity.tech"
        OTHER_URL="https://drive.aity.works"
        UPDATE_URL="https://aity-cloud.github.io/drive-desktop/update/"
        WANT_UPDATER=1
        ;;
    staging)
        SHORTNAME="aitydrive-staging"
        EXECUTABLE="aity-drive-staging"
        SERVER_URL="https://drive.aity.works"
        OTHER_URL="https://drive.aity.tech"
        UPDATE_URL="https://aity-cloud.github.io/drive-desktop/update/"
        WANT_UPDATER=0
        ;;
    *) echo "smoke: unknown environment '$ENV'" >&2; exit 2 ;;
esac

if [ -z "${UPSTREAM_TAG:-}" ]; then
    UPSTREAM_TAG=$(sed -n 's/^[[:space:]]*UPSTREAM_TAG:[[:space:]]*"\([^"]*\)".*/\1/p' "$(dirname "$0")/../.gitlab-ci.yml" | head -n1)
fi
UPSTREAM_VERSION="${UPSTREAM_TAG#v}"

fail() { echo "smoke($ENV): FAIL - $*" >&2; exit 1; }
note() { echo "smoke($ENV): $*"; }

[ -f "$APPIMAGE" ] || fail "no such file: $APPIMAGE"
chmod +x "$APPIMAGE"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp "$APPIMAGE" "$WORK/app.AppImage"
cd "$WORK"

# No FUSE in the CI container: extract instead of mounting.
./app.AppImage --appimage-extract >/dev/null 2>&1 || fail "--appimage-extract failed"
[ -d squashfs-root ] || fail "extraction produced no squashfs-root"

BIN=$(find squashfs-root -type f -name "$EXECUTABLE" -path "*/bin/*" | head -n1)
[ -n "$BIN" ] || fail "executable $EXECUTABLE not found inside the AppImage"
note "found $BIN"

# 1. it runs, and identifies itself
VERSION_OUT=$(cd squashfs-root && QT_QPA_PLATFORM=offscreen HOME="$WORK" ./AppRun --version 2>&1) \
    || fail "AppRun --version exited non-zero: $VERSION_OUT"
echo "$VERSION_OUT" | sed 's/^/smoke('"$ENV"'): --version: /'
echo "$VERSION_OUT" | grep -qF "$SHORTNAME $UPSTREAM_VERSION" \
    || fail "--version does not say '$SHORTNAME $UPSTREAM_VERSION'"

# 2. compiled-in branding facts (UTF-16LE and plain, binaries and libs)
DUMP="$WORK/strings.txt"
find squashfs-root -type f \( -name '*.so*' -o -path '*/bin/*' \) \
    -exec sh -c 'strings -a -e l "$1"; strings -a "$1"' _ {} \; > "$DUMP"

grep -qF "$SERVER_URL" "$DUMP" || fail "baked server URL $SERVER_URL not found"
grep -qF "$OTHER_URL" "$DUMP" && fail "other Environment's URL $OTHER_URL leaked in"
grep -qF "drive-desktop" "$DUMP" || fail "OIDC client id drive-desktop not found"
grep -qF "Aity Drive" "$DUMP" || fail "APPLICATION_NAME 'Aity Drive' not found"

if [ "$WANT_UPDATER" = 1 ]; then
    grep -qF "$UPDATE_URL" "$DUMP" || fail "updater feed URL missing from production build"
else
    grep -qF "$UPDATE_URL" "$DUMP" && fail "updater feed URL present in staging build"
fi

# 3. desktop integration file carries the branded name
DESKTOP=$(find squashfs-root -maxdepth 1 -name '*.desktop' | head -n1)
if [ -n "$DESKTOP" ]; then
    grep -q "Aity Drive" "$DESKTOP" || fail "desktop file lacks 'Aity Drive': $DESKTOP"
    note "desktop file OK: $(grep '^Name=' "$DESKTOP" | head -n1)"
else
    note "warning: no top-level .desktop file found (layout changed?)"
fi

note "PASS - $APPIMAGE is a branded $ENV build of $UPSTREAM_TAG"
