#!/usr/bin/env bash
# Neutralise macOS SDK removals that Craft's prebuilt Qt still asks for.
#
# THE BUG THIS EXISTS FOR (first build:macos run, 2026-08-30):
#
#   ld: framework 'AGL' not found
#   clang++: error: linker command failed with exit code 1
#
# AGL is Apple's legacy OpenGL wrapper, deprecated since 10.11 and REMOVED
# from the modern macOS SDK. Nothing in the ownCloud client calls into it -
# it arrives entirely through Qt: Qt ships `FindWrapOpenGL.cmake` in its own
# prefix, that module does `find_library(FWAGL AGL)` and puts the result in
# `WrapOpenGL::WrapOpenGL`, which `Qt6::Gui` links. Every target that links
# Qt6::Gui therefore gets `-framework AGL` on its link line, and the first
# one to link (libownCloudResources) dies.
#
# The find SUCCEEDS while the link FAILS, which is the confusing part and
# why this script prints where it found the thing: CMake's find_library also
# searches the running system's /System/Library/Frameworks, while ld is
# pinned to the SDK by -isysroot. A framework that exists on the host but not
# in the SDK passes configure and fails link.
#
# So: no source patch, no Craft blueprint fork. We make the find come back
# empty in Craft's own prefix, which is disposable and rebuilt from cache.
#
# It is a NO-OP when AGL links fine (a newer Qt, or an SDK that still has
# it), so it disappears by itself instead of becoming a permanent lie. It is
# idempotent: running it twice changes nothing the second time.
#
# Usage: scripts/mac-sdk-quirks.sh [craft-prefix]
#        defaults to $HOME/craft/CraftMaster/$CRAFT_TARGET
set -euo pipefail

PREFIX="${1:-$HOME/craft/CraftMaster/${CRAFT_TARGET:?set CRAFT_TARGET}}"
[ -d "$PREFIX" ] || { echo "craft prefix not found: $PREFIX"; exit 1; }

echo "== macOS SDK quirks, prefix $PREFIX"

SDK="$(xcrun --show-sdk-path)"
echo "   SDK: $SDK"

# Ground truth, not a guess about which SDK dropped what: ask the linker.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
printf 'int main(void){return 0;}\n' > "$TMP/t.c"
if clang -framework AGL -o "$TMP/t" "$TMP/t.c" >/dev/null 2>&1; then
    echo "   AGL links against this SDK - nothing to do."
    exit 0
fi
echo "   AGL does NOT link against this SDK."

# Diagnostics: this is the pair that explains a passing configure and a
# failing link, and it is worth having in the job log every time.
for d in "$SDK/System/Library/Frameworks/AGL.framework" \
         "/System/Library/Frameworks/AGL.framework"; do
    [ -e "$d" ] && echo "   present on disk : $d" || echo "   absent          : $d"
done

CHANGED=0

# 1. The source of it: Qt's own find module.
while IFS= read -r f; do
    grep -q 'AITY: AGL removed from the macOS SDK' "$f" && continue
    python3 - "$f" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
# Replace the find_library call, whatever its exact spelling, with an empty
# cache entry. An already-set variable makes CMake skip the search, and an
# empty ${FWAGL} expands to nothing in the target_link_libraries below.
new, n = re.subn(
    r'find_library\(\s*(\w*AGL\w*)\s+AGL\s*\)',
    r'# AITY: AGL removed from the macOS SDK (scripts/mac-sdk-quirks.sh).\n'
    r'# Qt still looks for it and CMake still finds it on the HOST, which is\n'
    r'# why configure passes and the link then fails under -isysroot.\n'
    r'set(\1 "" CACHE FILEPATH "AITY: AGL removed from the macOS SDK" FORCE)',
    s)
if n:
    open(p, 'w').write(new)
print(f"   patched {n} find_library(AGL) call(s) in {p}")
sys.exit(0 if n else 3)
PY
    # exit 3 means the file mentions AGL but not via find_library - report it
    # rather than silently believing we fixed something.
    case $? in
        0) CHANGED=1 ;;
        3) echo "   WARNING: $f mentions AGL but has no find_library(... AGL) call" ;;
    esac
done < <(grep -rl 'AGL' "$PREFIX/lib/cmake" 2>/dev/null || true)

# 2. Belt and braces: any Qt config that baked in the literal flag at the
#    time Qt itself was built (the binary cache is built elsewhere, on
#    whatever SDK that machine had).
while IFS= read -r f; do
    if grep -q -- '-framework AGL' "$f"; then
        perl -pi -e 's/-framework AGL\s*//g' "$f"
        echo "   stripped literal -framework AGL from $f"
        CHANGED=1
    fi
done < <(grep -rl -- '-framework AGL' "$PREFIX/lib/cmake" 2>/dev/null || true)

if [ "$CHANGED" = 0 ]; then
    echo "   AGL does not link AND nothing in $PREFIX/lib/cmake asks for it."
    echo "   The reference is coming from somewhere else - do not assume this"
    echo "   script fixed the build. Grep the failing link line's origin."
    exit 1
fi
echo "== done"
