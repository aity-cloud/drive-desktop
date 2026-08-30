#!/usr/bin/env bash
# Neutralise macOS SDK removals that Craft's prebuilt Qt still asks for.
#
# THE BUG THIS EXISTS FOR (first build:macos run, 2026-08-30):
#
#   ld: framework 'AGL' not found
#
# AGL is Apple's legacy OpenGL wrapper, deprecated since 10.11 and gone from
# the modern SDK. Nothing in this client calls it. It arrives through Qt:
# Qt ships its own FindWrapOpenGL.cmake, that module looks AGL up and feeds
# the result into WrapOpenGL::WrapOpenGL, which Qt6::Gui links - so every
# target linking Qt6::Gui gets `-framework AGL`, and the first one to link
# dies. The link line names it in Qt's order, `QtGui -framework AGL
# -framework AppKit -framework OpenGL`, which is what identifies the source.
#
# MEASURED ON THE RUNNER, 2026-08-30 - the find succeeds and the link fails:
#
#   absent : <Xcode>/…/MacOSX.sdk/System/Library/Frameworks/AGL.framework
#   present: /System/Library/Frameworks/AGL.framework
#
# CMake's find also searches the RUNNING SYSTEM, while ld is pinned to the
# SDK by -isysroot. Never read "configure found it" as "it is there".
#
# We make the lookup come back empty inside the Craft prefix, which is
# disposable and rebuilt from cache - no source patch, no blueprint fork.
# It is a NO-OP when AGL links fine, so it removes itself the day a Qt bump
# or an SDK makes it unnecessary, and it is idempotent.
#
# Usage: scripts/mac-sdk-quirks.sh [craft-prefix]
set -euo pipefail

PREFIX="${1:-$HOME/craft/CraftMaster/${CRAFT_TARGET:?set CRAFT_TARGET}}"
[ -d "$PREFIX" ] || { echo "craft prefix not found: $PREFIX"; exit 1; }

echo "== macOS SDK quirks, prefix $PREFIX"
SDK="$(xcrun --show-sdk-path)"
echo "   SDK: $SDK"

# Ground truth from the linker itself, not a hardcoded SDK version.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
printf 'int main(void){return 0;}\n' > "$TMP/t.c"
if clang -framework AGL -o "$TMP/t" "$TMP/t.c" >/dev/null 2>&1; then
    echo "   AGL links against this SDK - nothing to do."
    exit 0
fi
echo "   AGL does NOT link against this SDK."
for d in "$SDK/System/Library/Frameworks/AGL.framework" "/System/Library/Frameworks/AGL.framework"; do
    if [ -e "$d" ]; then echo "   present on disk : $d"; else echo "   absent          : $d"; fi
done

CMAKE_DIR="$PREFIX/lib/cmake"
[ -d "$CMAKE_DIR" ] || { echo "   no $CMAKE_DIR - is Qt installed?"; exit 1; }

python3 - "$CMAKE_DIR" <<'PY'
import pathlib, re, sys

MARK = "AITY: AGL removed from the macOS SDK"
root = pathlib.Path(sys.argv[1])
touched = already = 0

# Any lookup call whose argument list is `<VAR> AGL`. Deliberately NOT
# pinned to find_library: Qt uses its own wrappers here, and the first
# version of this script matched only find_library(), patched nothing, and
# reported success-shaped output while the build stayed broken.
# The real spelling in Qt 6.8.3, seen on the runner 2026-08-30:
#     find_library(WrapOpenGL_AGL NAMES AGL)
# The optional NAMES keyword is why version two of this script still missed
# it. Kept deliberately loose - any lookup-ish call, any variable name, with
# or without NAMES - because the point is to survive Qt changing the
# spelling again, not to match one release.
LOOKUP = re.compile(
    r'^([ \t]*)(\w*find\w*)\(\s*(\w+)\s+(?:NAMES\s+)?AGL\s*\)[ \t]*$',
    re.M | re.I)

# Runs after Qt's own module body, so it does not care HOW AGL got into the
# interface - only that it is gone before anything links against it.
SCRUB = f'''
# {MARK} (scripts/mac-sdk-quirks.sh).
# Belt and braces for the substitution above: whatever route AGL took into
# this target, take it back out before any consumer links.
if(TARGET WrapOpenGL::WrapOpenGL)
    get_target_property(_aity_agl_libs WrapOpenGL::WrapOpenGL INTERFACE_LINK_LIBRARIES)
    if(_aity_agl_libs)
        # Plain substring match on purpose. CMake's regex engine has no \\t
        # and no lookaround, and this target's link interface is only ever
        # OpenGL, AppKit and AGL - nothing else here can contain "AGL".
        list(FILTER _aity_agl_libs EXCLUDE REGEX "AGL")
        set_target_properties(WrapOpenGL::WrapOpenGL PROPERTIES
            INTERFACE_LINK_LIBRARIES "${{_aity_agl_libs}}")
    endif()
endif()
'''

for f in sorted(root.rglob("*.cmake")):
    try:
        s = f.read_text()
    except (UnicodeDecodeError, OSError):
        continue
    if "AGL" not in s:
        continue
    if MARK in s:
        already += 1
        continue

    print(f"   {f.relative_to(root)}: AGL referenced at")
    for i, line in enumerate(s.split("\n"), 1):
        if "AGL" in line:
            print(f"      {i}: {line.strip()[:110]}")

    new, n = LOOKUP.subn(
        lambda m: (f'{m.group(1)}# {MARK} - was: {m.group(0).strip()}\n'
                   f'{m.group(1)}set({m.group(3)} "")'),
        s)
    if n:
        print(f"      -> emptied {n} AGL lookup(s)")
    if "-framework AGL" in new:
        new = new.replace("-framework AGL", "")
        print("      -> stripped literal -framework AGL")
    if f.name == "FindWrapOpenGL.cmake":
        new = new.rstrip("\n") + "\n" + SCRUB
        print("      -> appended WrapOpenGL interface scrub")

    if new != s:
        f.write_text(new)
        touched += 1

if already and not touched:
    print(f"   {already} file(s) already patched - nothing to do.")
    sys.exit(0)
if not touched:
    print("   AGL does not link AND nothing under lib/cmake could be patched.")
    print("   Do NOT assume this script fixed the build - the lines printed")
    print("   above are where it actually comes from.")
    sys.exit(1)
print(f"   patched {touched} file(s)")
PY

echo "== done"
