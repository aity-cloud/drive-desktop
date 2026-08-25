#!/usr/bin/env bash
# Regenerate the OEM theme icon set from ../meta/brand/logo.svg.
# Bootstraps a local Pillow venv under build/ (gitignored); the generated
# assets under overlay/ are committed. See scripts/gen-icons.py.
set -euo pipefail
cd "$(dirname "$0")/.."
VENV=build/venv-icons
[ -x "$VENV/bin/python" ] || { python3 -m venv "$VENV"; "$VENV/bin/pip" -q install pillow; }
"$VENV/bin/python" -c 'import PIL' 2>/dev/null || "$VENV/bin/pip" -q install pillow
exec "$VENV/bin/python" scripts/gen-icons.py
