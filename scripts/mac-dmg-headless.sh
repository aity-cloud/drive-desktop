#!/usr/bin/env bash
# Make Craft's DMG packaging work without a GUI session.
#
# THE BUG THIS EXISTS FOR (build:macos, 2026-08-30): the client compiled and
# linked all 425 objects and then died in packaging:
#
#   createdmg.tmp.XXXXXXXXXX: execution error:
#   Finder got an error: AppleEvent timed out. (-1712)
#
# ownCloud's craft-core fork packages with `create-dmg`, which drives FINDER
# over AppleScript to position the icons and set the window background. That
# needs a logged-in Aqua session AND macOS Automation (TCC) permission for
# the calling process. A GitLab LaunchAgent has neither reliably: the TCC
# prompt has nobody to answer it, so the Apple event just times out.
#
# `create-dmg --skip-jenkins` is upstream's own flag for this, documented as
# "skip Finder-prettifying AppleScript, useful in Sandbox and non-GUI
# environments". The DMG still contains the app and the /Applications drop
# link - what is lost is the icon positioning and background image.
#
# WHY NOT JUST GRANT THE PERMISSION: because then the build only works while
# Raul is logged in with Finder responsive, and silently hangs for five
# minutes when he is not. A release build must not depend on somebody's
# desktop session. The cosmetics are worth strictly less than that.
#
# THE BETTER FIX, when the DMG window layout starts to matter: KDE's craft
# uses `dmgbuild` instead, which is pure Python, needs no Finder at all, AND
# keeps the background and icon positions. Switching means replacing this
# packager's createPackage wholesale, which is more than a quirk workaround
# deserves today.
#
# Patches the Craft prefix, which is disposable and re-created from cache,
# and is idempotent.
#
# Usage: scripts/mac-dmg-headless.sh [craft-prefix]
set -euo pipefail

PREFIX="${1:-$HOME/craft/CraftMaster/${CRAFT_TARGET:?set CRAFT_TARGET}}"
[ -d "$PREFIX" ] || { echo "craft prefix not found: $PREFIX"; exit 1; }

echo "== DMG headless packaging, prefix $PREFIX"

mapfile -t FILES < <(find "$PREFIX" -name MacDMGPackager.py -not -path '*/downloads/*' 2>/dev/null)
if [ "${#FILES[@]}" -eq 0 ]; then
    echo "   no MacDMGPackager.py under $PREFIX - craft-core layout changed?"
    exit 1
fi

python3 - "${FILES[@]}" <<'PY'
import pathlib, re, sys

MARK = "AITY: no Finder in CI"
patched = already = skipped = 0

for p in map(pathlib.Path, sys.argv[1:]):
    s = p.read_text()
    if "create-dmg" not in s:
        # KDE's craft-core uses dmgbuild, which needs no Finder at all.
        print(f"   {p}: does not call create-dmg - nothing to do")
        skipped += 1
        continue
    if MARK in s:
        print(f"   {p}: already patched")
        already += 1
        continue

    # Insert the flag immediately after the executable name, whatever the
    # surrounding argument list looks like.
    new, n = re.subn(r'("create-dmg",)',
                     r'\1\n                # ' + MARK + r': Finder cannot be scripted from a\n'
                     r'                # LaunchAgent, so the icon-positioning AppleScript times\n'
                     r'                # out (-1712) after the app has already built. See\n'
                     r'                # scripts/mac-dmg-headless.sh.\n'
                     r'                "--skip-jenkins",',
                     s, count=1)
    if not n:
        print(f"   {p}: calls create-dmg but the argument list did not match")
        continue
    p.write_text(new)
    print(f"   {p}: added --skip-jenkins")
    patched += 1

if patched or already:
    sys.exit(0)
if skipped:
    print("   nothing calls create-dmg - if packaging still fails, it is not this.")
    sys.exit(0)
print("   found MacDMGPackager.py but could not patch it. Do NOT assume this")
print("   script fixed anything.")
sys.exit(1)
PY

echo "== done"
