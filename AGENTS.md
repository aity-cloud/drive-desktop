# Agent rules for drive/desktop

The desktop Factory of the Aity Drive Clients: it turns the Upstream
(`owncloud/client`) at the Pin plus the Overlay in this repo into the
branded Windows/macOS/Linux sync client, through CI only. Read
`../meta/AGENTS.md` first - every rule there (overlay-only, trademark,
CI-publishes-humans-promote, both Environment builds, no secrets, plain
dashes) applies here unchanged. Vocabulary: `../meta/CONTEXT.md`. Spec:
`../meta/specs/aity-drive-v1.md`.

## This repo's own rules

- The Pin is the `UPSTREAM_TAG` variable in `.gitlab-ci.yml` and nowhere
  else; `scripts/materialize.sh` parses it from there for local runs.
  Bump procedure: `UPSTREAM.md`.
- The upstream tree is NEVER committed here. `build/` (materialised trees)
  and `public/` (generated feeds) are gitignored; if `git status` shows
  upstream files, something is wrong.
- Branding beats patching: anything expressible in `overlay/` (OEM.cmake
  variables, the Theme subclass, theme assets) must be done there. A patch
  in `patches/` needs a "not shippable without it" justification and an
  entry in `PATCHES.md`. Current count: 1 (product behavior the upstream
  theme has no hooks for - see PATCHES.md); keep it minimal and drop
  hunks a Bump makes redundant.
- Icons and wizard logos under `overlay/*/theme/` are GENERATED from
  `../meta/brand/logo.svg` by `scripts/gen-icons.sh`. Regenerate, never
  hand-edit the PNGs/SVGs.
- Windows (`build:windows`) and macOS (`build:macos`) jobs are manual,
  always - the Windows runner burns purchased minutes, the Mac runner is
  shared hardware. Never make them run on plain pushes.
- Traps that have actually bitten this Factory are recorded in
  `MAINTAINING.md`; extend it when a new one bites, prune entries a Bump
  makes obsolete.
