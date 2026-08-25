#!/usr/bin/env bash
# Collect Craft's packaged output for one Environment build into dist/<env>,
# renamed to the release-worthy shape:
#
#   <executable>-<upstream>.<build>-linux-x86_64.AppImage (+ .sha256)
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
DEST="dist/$ENV"
mkdir -p "$DEST"

shopt -s nullglob
appimages=("$SRC"/*.AppImage)
[ ${#appimages[@]} -eq 1 ] || { echo "collect: expected exactly one AppImage in $SRC, got: ${appimages[*]:-none}" >&2; ls -la "$SRC" >&2; exit 1; }

NEW="$EXECUTABLE-$VERSION-linux-x86_64.AppImage"
mv "${appimages[0]}" "$DEST/$NEW"
chmod +x "$DEST/$NEW"
( cd "$DEST" && sha256sum "$NEW" > "$NEW.sha256" )

# anything else craft emitted (debug archives etc.) rides along unrenamed
for f in "$SRC"/*; do
    case "$f" in
        *.sha256) rm -f "$f" ;;    # regenerated above for the renamed file
        *) mv "$f" "$DEST/" ;;
    esac
done

ls -la "$DEST/"
