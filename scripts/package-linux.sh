#!/usr/bin/env bash
# Build .deb and .rpm from a produced AppImage: a self-contained install
# under /opt plus the desktop-menu integration (launcher, .desktop, icons)
# the bare AppImage does not give. Both formats come from one staging tree
# via fpm.
#
#   scripts/package-linux.sh <AppImage> <production|staging>
#
# The AppImage already bundles the whole Qt runtime and is relocatable (its
# AppRun computes paths from its own location), so the package is that same
# tree dropped under /opt with a launcher symlink on PATH. It declares NO
# distro dependencies: a desktop already carries the GL/xcb/fontconfig
# runtime the bundle dlopens, which is exactly what the AppImage assumes and
# it runs on a normal desktop.
# ponytail: no per-distro Depends (deb and rpm name those libs differently);
# add them only if we ever target minimal or headless installs.
#
# Needs: fpm, plus dpkg-deb (deb) and rpmbuild (rpm). The CI job installs
# them; see MAINTAINING.md "Linux .deb/.rpm".
set -euo pipefail

APPIMAGE="${1:?usage: $0 <AppImage> <production|staging>}"
ENV="${2:?usage: $0 <AppImage> <production|staging>}"

case "$ENV" in
    production) SHORTNAME="aitydrive"; EXECUTABLE="aity-drive" ;;
    staging)    SHORTNAME="aitydrive-staging"; EXECUTABLE="aity-drive-staging" ;;
    *) echo "package-linux: unknown environment '$ENV'" >&2; exit 2 ;;
esac

APPIMAGE=$(readlink -f "$APPIMAGE")
[ -f "$APPIMAGE" ] || { echo "package-linux: no such file: $APPIMAGE" >&2; exit 1; }

# Version from the collect-binaries filename:
#   aity-drive[-staging]-<version>-linux-x86_64.AppImage
BASE=$(basename "$APPIMAGE")
VERSION=$(printf '%s\n' "$BASE" | sed -E 's/^aity-drive(-staging)?-([0-9.]+)-linux-x86_64\.AppImage$/\2/')
[ -n "$VERSION" ] && [ "$VERSION" != "$BASE" ] \
    || { echo "package-linux: cannot parse a version from '$BASE'" >&2; exit 1; }

OUT="${COLLECT_DEST:-$(cd "$(dirname "$0")/.." && pwd)/dist/$ENV}"
mkdir -p "$OUT"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp "$APPIMAGE" "$WORK/app.AppImage" && chmod +x "$WORK/app.AppImage"
( cd "$WORK" && ./app.AppImage --appimage-extract >/dev/null 2>&1 ) \
    || { echo "package-linux: --appimage-extract failed" >&2; exit 1; }
APPDIR="$WORK/squashfs-root"
[ -x "$APPDIR/AppRun" ] || { echo "package-linux: extracted tree has no AppRun" >&2; exit 1; }
[ -f "$APPDIR/usr/share/applications/$EXECUTABLE.desktop" ] \
    || { echo "package-linux: no $EXECUTABLE.desktop in the AppDir (wrong env?)" >&2; exit 1; }

# The install tree: the whole AppDir under /opt/<shortname>, a launcher on
# PATH, and the .desktop + hicolor icons so it shows up in the menu. The
# .desktop's Exec is `<executable> --showsettings` and /usr/bin/<executable>
# is the launcher, so the menu entry and the CLI are the same path.
STAGE="$WORK/stage"
install -d "$STAGE/opt/$SHORTNAME" "$STAGE/usr/bin" "$STAGE/usr/share/applications"
cp -a "$APPDIR/." "$STAGE/opt/$SHORTNAME/"
# A launcher SCRIPT, not a symlink: AppRun resolves its own directory with
# `dirname "$0"` (no readlink on $0 first), so a symlink at /usr/bin makes
# it look for its bundled hooks under /usr/bin and die. exec'ing AppRun by
# its absolute path gives it the right $0.
cat > "$STAGE/usr/bin/$EXECUTABLE" <<LAUNCHER
#!/bin/sh
exec "/opt/$SHORTNAME/AppRun" "\$@"
LAUNCHER
chmod 755 "$STAGE/usr/bin/$EXECUTABLE"
cp "$APPDIR/usr/share/applications/$EXECUTABLE.desktop" "$STAGE/usr/share/applications/"
cp -a "$APPDIR/usr/share/icons" "$STAGE/usr/share/"

common=(
    -s dir -C "$STAGE"
    -n "$SHORTNAME" -v "$VERSION" --iteration 1
    --license "GPL-2.0-or-later"
    --vendor "AITY CLOUD SRL"
    --maintainer "AITY CLOUD SRL <raul@aity.ro>"
    --url "https://aity.ro"
    --category "Utility"
    --description "Aity Drive desktop synchronization client"
    --force
)

fpm "${common[@]}" -t deb -a amd64 \
    -p "$OUT/${EXECUTABLE}-${VERSION}-linux-x86_64.deb" opt usr
fpm "${common[@]}" -t rpm -a x86_64 \
    -p "$OUT/${EXECUTABLE}-${VERSION}-linux-x86_64.rpm" opt usr

for f in "$OUT/${EXECUTABLE}-${VERSION}-linux-x86_64.deb" \
         "$OUT/${EXECUTABLE}-${VERSION}-linux-x86_64.rpm"; do
    [ -s "$f" ] || { echo "package-linux: fpm produced no $f" >&2; exit 1; }
    ( cd "$(dirname "$f")" && sha256sum "$(basename "$f")" > "$(basename "$f").sha256" )
    echo "package-linux($ENV): wrote $(basename "$f")"
done
