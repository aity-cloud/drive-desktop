#!/usr/bin/env bash
# Collect Craft's packaged output for one Environment build into dist/<env>,
# renamed to the release-worthy shape:
#
#   <executable>-<upstream>.<build>-linux-x86_64.AppImage   (+ .sha256)
#   <executable>-<upstream>.<build>-macos-arm64.dmg         (+ .sha256)
#   <executable>-<upstream>.<build>-windows-x86_64.exe/.msi (+ .sha256)
#
# Craft names its archive after the blueprint package and git ref
# (owncloud-client-HEAD-<n>-linux-gcc-x86_64.AppImage); the AppImage format
# does not care about the file name, but customers and the update feeds do.
set -euo pipefail

ENV="${1:?usage: $0 <production|staging>}"
case "$ENV" in
    production) EXECUTABLE=aity-drive ;;
    staging)    EXECUTABLE=aity-drive-staging ;;
    *) echo "unknown environment: $ENV" >&2; exit 2 ;;
esac

cd "$(dirname "$0")/.."

if [ -z "${UPSTREAM_TAG:-}" ]; then
    UPSTREAM_TAG=$(sed -n 's/^[[:space:]]*UPSTREAM_TAG:[[:space:]]*"\([^"]*\)".*/\1/p' .gitlab-ci.yml | head -n1)
fi
VERSION="${UPSTREAM_TAG#v}.${CI_PIPELINE_IID:-0}"

SRC="$HOME/craft/binaries"
DEST="${COLLECT_DEST:-dist/$ENV}"
mkdir -p "$DEST"

shopt -s nullglob

# macOS emits a .dmg, Linux an .AppImage, Windows an .exe and/or .msi
# installer. Craft names ALL of them after the blueprint -
# `owncloud-client-HEAD-14-macos-clang-arm64.dmg` - which puts upstream's
# trademark in the name of a file we hand to customers. The app inside is
# already branded; only the wrapper was wrong (caught on the first
# successful macOS package, 2026-08-30). meta/AGENTS.md: no "owncloud" in
# any name we ship. On Windows this runs under git-bash (uname MINGW*).
case "$(uname -s)" in
    Darwin)                EXTS=(dmg);      PLATFORM="macos-arm64"   ;;
    MINGW*|MSYS*|CYGWIN*)  EXTS=(exe msi);  PLATFORM="windows-x86_64" ;;
    *)                     EXTS=(AppImage); PLATFORM="linux-x86_64"  ;;
esac

artifacts=()
for ext in "${EXTS[@]}"; do
    matches=("$SRC"/*."$ext")
    [ ${#matches[@]} -le 1 ] || { echo "collect: expected at most one .$ext in $SRC, got: ${matches[*]}" >&2; ls -la "$SRC" >&2; exit 1; }
    artifacts+=("${matches[@]}")
done
[ ${#artifacts[@]} -ge 1 ] || { echo "collect: no packaged artifact (${EXTS[*]}) in $SRC" >&2; ls -la "$SRC" >&2; exit 1; }

for f in "${artifacts[@]}"; do
    ext="${f##*.}"
    NEW="$EXECUTABLE-$VERSION-$PLATFORM.$ext"
    mv "$f" "$DEST/$NEW"
    [ "$ext" = AppImage ] && chmod +x "$DEST/$NEW"
    if command -v sha256sum >/dev/null 2>&1; then
        ( cd "$DEST" && sha256sum "$NEW" > "$NEW.sha256" )
    else
        # macOS has no sha256sum; shasum ships with the system perl.
        ( cd "$DEST" && shasum -a 256 "$NEW" > "$NEW.sha256" )
    fi
done

# anything else craft emitted (debug archives etc.) rides along unrenamed
for f in "$SRC"/*; do
    case "$f" in
        *.sha256) rm -f "$f" ;;    # regenerated above for the renamed file
        *) mv "$f" "$DEST/" ;;
    esac
done

ls -la "$DEST/"
