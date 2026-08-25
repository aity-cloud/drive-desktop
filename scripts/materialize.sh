#!/usr/bin/env bash
# Materialise the Aity Drive desktop client tree for one Environment build:
#
#   scripts/materialize.sh <production|staging>
#
# 1. clone the Upstream (owncloud/client) at the Pin into build/upstream
#    (cached between runs, re-cloned when the Pin moved),
# 2. copy it to build/materialized/<env>,
# 3. lay the Overlay on top as the tree's branding/ directory - the branding
#    input upstream's THEME.cmake implements at the Pin: an in-tree
#    `branding/` dir at the source root is picked up as OEM_THEME_DIR and its
#    OEM.cmake replaces OWNCLOUD.cmake (see UPSTREAM.md for why this
#    mechanism and not WITH_EXTERNAL_BRANDING),
# 4. apply patches/*.patch, if any (zero is the target - PATCHES.md).
#
# Same script for CI and for a developer working locally; needs git + bash
# only (on the Windows runner it runs under Git for Windows' bash).
set -euo pipefail

ENV="${1:-}"
case "$ENV" in
    production|staging) ;;
    *) echo "usage: $0 <production|staging>" >&2; exit 2 ;;
esac

cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"

UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/owncloud/client.git}"

# The Pin lives in .gitlab-ci.yml as the renovate-annotated UPSTREAM_TAG
# variable; CI exports it, local runs parse it so there is one source of
# truth.
if [ -z "${UPSTREAM_TAG:-}" ]; then
    UPSTREAM_TAG=$(sed -n 's/^[[:space:]]*UPSTREAM_TAG:[[:space:]]*"\([^"]*\)".*/\1/p' .gitlab-ci.yml | head -n1)
fi
[ -n "$UPSTREAM_TAG" ] || { echo "materialize: UPSTREAM_TAG not set and not found in .gitlab-ci.yml" >&2; exit 1; }
case "$UPSTREAM_TAG" in
    v[0-9]*.[0-9]*.[0-9]*) ;;
    *) echo "materialize: Pin must be a release tag (vX.Y.Z), got '$UPSTREAM_TAG'" >&2; exit 1 ;;
esac

UPSTREAM_DIR="$REPO_ROOT/build/upstream"
OUT_DIR="$REPO_ROOT/build/materialized/$ENV"

# --- 1. clone the Pin (cached) ---------------------------------------------
current_tag=""
if [ -d "$UPSTREAM_DIR/.git" ]; then
    current_tag=$(git -C "$UPSTREAM_DIR" describe --tags --exact-match 2>/dev/null || true)
fi
if [ "$current_tag" != "$UPSTREAM_TAG" ]; then
    echo "materialize: cloning $UPSTREAM_URL at $UPSTREAM_TAG"
    rm -rf "$UPSTREAM_DIR"
    git clone --depth 1 --branch "$UPSTREAM_TAG" "$UPSTREAM_URL" "$UPSTREAM_DIR"
else
    echo "materialize: build/upstream already at $UPSTREAM_TAG"
fi

# Guard: the Pin's own VERSION.cmake must agree with the tag, so a bumped
# tag with a stale checkout (or vice versa) fails loudly.
ver=$(sed -n 's/^set( MIRALL_VERSION_MAJOR \([0-9]*\) )/\1/p' "$UPSTREAM_DIR/VERSION.cmake").$(sed -n 's/^set( MIRALL_VERSION_MINOR \([0-9]*\) )/\1/p' "$UPSTREAM_DIR/VERSION.cmake").$(sed -n 's/^set( MIRALL_VERSION_PATCH \([0-9]*\) )/\1/p' "$UPSTREAM_DIR/VERSION.cmake")
[ "v$ver" = "$UPSTREAM_TAG" ] || { echo "materialize: VERSION.cmake says $ver but Pin is $UPSTREAM_TAG" >&2; exit 1; }

# --- 2. copy to the per-Environment tree -----------------------------------
rm -rf "$OUT_DIR"
mkdir -p "$(dirname "$OUT_DIR")"
cp -a "$UPSTREAM_DIR" "$OUT_DIR"

# --- 3. Overlay as branding/ (common first, Environment wins) --------------
mkdir -p "$OUT_DIR/branding"
cp -a "$REPO_ROOT/overlay/common/." "$OUT_DIR/branding/"
cp -a "$REPO_ROOT/overlay/$ENV/." "$OUT_DIR/branding/"
[ -f "$OUT_DIR/branding/OEM.cmake" ] || { echo "materialize: overlay produced no branding/OEM.cmake" >&2; exit 1; }

# --- 4. patches (target: none) ---------------------------------------------
shopt -s nullglob
patches=("$REPO_ROOT"/patches/*.patch)
if [ ${#patches[@]} -gt 0 ]; then
    for p in "${patches[@]}"; do
        echo "materialize: applying $(basename "$p")"
        git -C "$OUT_DIR" apply --check "$p" || { echo "materialize: patch does not apply against $UPSTREAM_TAG: $p" >&2; exit 1; }
        git -C "$OUT_DIR" apply "$p"
    done
else
    echo "materialize: no patches (good)"
fi

echo "materialize: $ENV tree ready at build/materialized/$ENV (Pin $UPSTREAM_TAG)"
