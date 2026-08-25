#!/usr/bin/env bash
# Bash port of upstream's .github/workflows/.craft.ps1: run CraftMaster with
# the Pin's own .craft.ini (from the materialised tree) plus our CI override.
#
# Required environment:
#   AITY_MATERIALIZED  absolute path of the materialised tree
#                      (build/materialized/<env>)
#   CRAFT_TARGET       Craft target from the Pin's .craft.ini, e.g.
#                      linux-64-gcc
#
# CraftMaster itself is expected at $HOME/craft/CraftMaster/CraftMaster
# (cloned by the CI job, exactly like upstream's workflow does).
set -euo pipefail

: "${AITY_MATERIALIZED:?set AITY_MATERIALIZED to the materialised tree}"
: "${CRAFT_TARGET:?set CRAFT_TARGET (e.g. linux-64-gcc)}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

exec python3 "$HOME/craft/CraftMaster/CraftMaster/CraftMaster.py" \
    --config "$AITY_MATERIALIZED/.craft.ini" \
    --config-override "$REPO_ROOT/ci/craft-override.ini" \
    --target "$CRAFT_TARGET" \
    --variables "WORKSPACE=$HOME/craft" \
    "$@"
