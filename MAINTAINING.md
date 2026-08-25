# Maintaining the desktop Factory

Traps this Factory has actually hit, and the standing gaps. The generic
loop (watch, response targets, per-Bump checklist) is
`../meta/docs/maintenance.md`; the Pin mechanics are `UPSTREAM.md`.

## Sync smoke gap (standing, investigated 2026-08-25)

The spec wants an `owncloudcmd` sync round-trip against
`https://drive.aity.works` as the desktop smoke. **That is impossible at
Pin v7.1.0**: upstream removed `owncloudcmd` (only the stale
`owncloudcmd.desktop.in` remains in the tree); the only client is the GUI,
and its auth is OIDC through a real browser + loopback redirect.

What was investigated, so nobody re-treads it:

- Non-interactive TOKENS are obtainable: the staging seed tooling
  (`infra/harvester-cluster/scripts/_drive_lib.py`, read-only) does a
  Keycloak password grant with client `drive` and the `drive-test-*`
  users. But there is no headless CONSUMER for such a token in the client
  at this Pin - no CLI, and the GUI's account wiring cannot be fed a
  bearer token from outside.
- A raw WebDAV round-trip with such a token (curl) would test the server,
  not the built client - worthless as a Client smoke.
- Upstream's own end-to-end GUI tests use Squish (licence-gated,
  `.github/workflows/branded-client.yml` and `gui-tests.yml`); adopting
  that harness is the real path to a sync smoke if one is ever needed
  beyond the mobile Clients' coverage.

Until then `smoke:appimage` verifies branding facts (binary runs and
identifies itself, baked server URL + OIDC client id, updater posture per
Environment) and the `smoke:sync` job in `.gitlab-ci.yml` stays a
`when: never` skeleton pointing here.

## Traps

- **Craft's CMake cache leaks branding across Environment builds.** The
  blueprint reuses one build dir; `OEM_THEME_DIR` and other
  `CACHE STRING`s stick. `build:appimage` wipes the blueprint build dir
  (`craft -q --get buildDir owncloud-client`) before each Environment's
  build - keep that when touching the job.
- **The blueprint hardcodes the NSIS icon path to
  `src/gui/owncloud.ico`** (`createPackage` in
  `craft-blueprints-owncloud/owncloud/owncloud-client.py`), but
  `ecm_add_app_icon(... OUTFILE_BASENAME ${APPLICATION_ICON_NAME})`
  writes `aitydrive.ico` for a branded build. Affects the Windows
  installer's own icon only (the app's icon is correct). Check what the
  first Windows build produces; the fix, if needed, is an upstream
  blueprint PR (env-var lookup like appname), not a patch here.
- **Blueprints float on `master`.** `.craft.shelf` pins package versions
  but records blueprint repos at `|master|`, so
  craft-blueprints-owncloud/kde changes can break a rebuild of the SAME
  Pin. If a previously-green pipeline breaks without a repo change, diff
  those two repos first.
- **`APPLICATION_EXECUTABLE`/`APPLICATION_SHORTNAME` env vars at package
  time.** The blueprint filters executables by them; forgetting the
  staging values ships an AppImage without the binary. The CI exports
  them per Environment - keep build and package in the same exported
  scope.
- **Brand master is low-res.** `../meta/brand/logo.svg` embeds 188px
  raster layers, so the 512/1024 icon renders are upscales and slightly
  soft, and at 16px the wordmark is a faint line (mitigated with alpha
  gain in `scripts/gen-icons.py`). The real fix is a vector master in
  meta/brand; regenerate with `scripts/gen-icons.sh` when one lands.
- **Do not assert the stock OAuth client id is gone.** The default
  `Theme::oauthClientId()` body (upstream's `xdXOt13...` literal) stays
  compiled into libowncloudsync even though the subclass overrides it;
  the smoke asserts the presence of `drive-desktop` instead.
- **Static Pages cannot dispatch the updater by query string.** The
  client appends `platform=`/`oem=`/... to `APPLICATION_UPDATE_URL`, but
  the three platforms need three response formats. Hence the per-OS
  `APPLICATION_UPDATE_URL` branch in `overlay/production/OEM.cmake` and
  the per-OS files from `scripts/gen-update-feeds.sh`. If a Bump changes
  the updater protocol (`src/gui/updater/`), re-derive both.

## Unverified scaffolds (state as of 2026-08-25)

- `build:windows`: written from upstream's workflow, wall-clock on the
  2 vCPU hosted runner to be measured on first manual run (spec flags it;
  fallback is a Windows VM on Harvester registered as `windows`).
- `build:macos`: cannot run until the `macos` runner exists (M0).
- `sign:windows`: no-op until `AZURE_*` variables exist (runbook
  `../meta/docs/runbooks/publisher-accounts.md` section 4); the Jsign
  invocation is sketched in the job.
- `publish:staging-prerelease` / `promote`: gated on a
  `GITHUB_RELEASES_TOKEN` variable that does not exist yet (the mirror
  deploy key cannot create releases); promote additionally still needs
  the release-creation + Pages-push implementation and deliberately
  fails until then. Pages on the mirror is enabled by Raul, never by CI.
