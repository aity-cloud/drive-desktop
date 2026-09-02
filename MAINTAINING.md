# Maintaining the desktop Factory

Traps this Factory has actually hit, and the standing gaps. The generic
loop (watch, response targets, per-Bump checklist) is
`../meta/docs/maintenance.md`; the Pin mechanics are `UPSTREAM.md`.

## Sync smoke: CLOSED 2026-09-02 - a real round-trip runs in CI

`smoke:sync` round-trips a real file both ways through the SHIPPED staging
AppImage against `https://drive.aity.works`, headless, on every pipeline.
`smoke:sync:production` is its manual twin against production (it signs in
as a real user and writes files there, so a human decides - and it stays
invisible until `AITY_CONTRACT_USER_PROD` / `AITY_CONTRACT_PASSWORD_PROD`
exist; no production contract user has been created yet).

How: `scripts/smoke-sync.sh` extracts the AppImage (no FUSE in CI), starts a
private dbus session with gnome-keyring as the Secret Service, and
`scripts/smoke-sync.py seed` signs in as `drive-desktop` (authorization code
+ PKCE, the realm's identity-first pages - the flow meta's
`drive_client_auth.py` proves) and plants a ready-to-sync account. The
client runs under `QT_QPA_PLATFORM=offscreen` and does everything a user's
client does: reads the keychain, refreshes the token, connects, syncs. The
`verify` phase then proves a file goes local -> server and server -> local,
sweeps `smoke-sync-*` litter from earlier failed runs, and deletes what it
created (staging hygiene rule).

The two claims of the 2026-08-27 investigation still hold: there is no
headless entry point in the AppImage (one binary, no sync/account CLI
options, `owncloudcmd` is gone at this Pin) and upstream's own GUI harness
is Squish (commercial) plus Playwright for the OIDC page. What changed is
the third route: seeding the config stopped being guesswork once each piece
was pinned to the code, and the WAF fix (below) made the login provable
first. Every trap found on the way, so a Bump knows what to re-verify
(all paths `src/` of the materialised tree):

- **A seeded account whose `capabilities` value is missing, unparseable or
  not spaces-enabled is DELETED at load**, credentials included
  (`AccountManager::loadAccountHelper`: `settings.remove("")`). The seeder
  fetches the LIVE `/ocs/v2.php/cloud/capabilities` map and lets Qt itself
  serialise it - python3-pyqt6's QSettings writes the `@Variant` QVariantMap
  encoding the client reads. Never hand-roll that encoding.
- **The client only asks the keychain for keys book-kept in the cfg**:
  `CredentialManager::get` checks `[Credentials/<scope>]` first and logs
  `We don't know "http/oauthtoken" skipping retrieval from keychain` if the
  entry is absent. The scope is `<appName>_credentials:<host>:<uuid>`
  (`credentialKeyC()` - the prefix is the BRANDED app name, not a literal).
- **The keychain entry** (qtkeychain 0.15, libsecret backend): service =
  `Theme::appName()` (`aitydrive-staging` / `aitydrive`), key =
  `<scope>:http/oauthtoken`, item attributes `user`/`server`/`type=base64`,
  secret = base64 of a CBOR text string (`CredentialJob` parses CBOR).
  python3-secretstorage creates a matching item; gnome-keyring must be
  unlocked on the session bus first.
- **An account alone syncs nothing.** The default theme has
  `syncNewlyDiscoveredSpaces() == false`, and the wizard-only
  `setUpInitialSyncFolders` path never runs for config-loaded accounts, so
  the seeder writes one Folder definition for the personal space too. Keys
  per `FolderDefinition::save` - the display name key is `displayString`,
  the journal is `.sync_journal.db` (`SyncJournalDb::makeDbName`), and the
  journal file itself need not exist.
- **A file written into the folder in the same second the client discovers
  it is not uploaded.** The propagator defers it ("Local file changed
  during sync. It will be resumed.") and the resume never re-examined it
  (observed against 7.1.0.20). The verify phase writes the file OUTSIDE the
  folder, backdates its mtime 30s, and renames it in atomically.
- **The probe must not share the client's tokens.** Keycloak rotates
  refresh tokens: after the client's first refresh the seeder's copy is
  dead. `verify` holds its own password-grant token on the `drive` client
  (the one client the realm allows the grant on, same as
  `drive_contract.py`), re-granted on 401 so long polls survive expiry.

What is still true and worth keeping in mind: the branding facts stay in
`smoke:appimage` (no server needed there), and the sync smoke's seeding
touches private on-disk formats, so a Pin bump re-runs this job as its
proof - if upstream reshapes the cfg or the credential scope, the smoke
fails loudly and this section plus `scripts/smoke-sync.py` are what to
update.

### The staging WAF used to 403 the desktop's loopback redirect (FIXED 2026-08-27)

The staging gateway had no loopback exception at all (prod's rule 10023
listed only ownCloud's stock client ids and the staging twin was missing
entirely), so every authorization request with a loopback `redirect_uri`
got a bare 403 from istio-envoy - the desktop client, whose redirects are
all loopback, could not sign in at all, and neither could a human testing
it. Both gateways now list the drive ids and staging has the 10023/10024
twin (infra/harvester-cluster `platform/istio/values.yaml`). Verified end
to end: `drive-desktop` completes authorization, token exchange, a rotated
refresh, and oCIS accepts the token; removed from `KNOWN_BLOCKED` in meta's
`contract/drive_client_auth.py`. Diagnostic worth keeping: a 403 with an
empty body and `Server: istio-envoy` on the auth endpoint is the WAF, while
Keycloak answers a 400 to a bad-but-reachable redirect.

## The upstream theme brands the login screen and nothing else (2026-09-02)

Raul's first installable build was branded ONLY on the wizard/login screen;
the rest of the app kept ownCloud's blue, the wizard opened on a server-URL
page despite the URL being preset, and signing in downloaded every space.
The `Theme` subclass has no hook for any of these - they are the first
patch (`patches/0001-*`, PATCHES.md). Facts that cost time to find, kept
here so a Bump can re-verify fast:

- **All in-app icons are tinted by ONE hardcoded literal pair** in
  `Resources::getCoreIcon` (`#435671` light / `#ADACAB` dark), used by the
  toolbar, connection-state dots, folder-status icons and the default space
  image. It is not a `Theme` value. The patch swaps it for the aity-ds
  neutrals; if a Bump makes it themable, drop that hunk.
- **The selection/highlight color comes from the platform style, not the
  theme.** The blue selected-account tab and list selections are
  `QPalette::Highlight`. The patch sets it app-wide in `main.cpp` from
  `wizardHeaderBackgroundColor()`. `avatarColor()`/`avatarColorChecked()`
  ARE real `Theme` hooks (overlay, no patch) - the checked avatar sits on
  the new red highlight, so it is white.
- **`SYNC_ALL` is upstream's default whenever no VFS plugin exists**, and
  this Pin ships a VFS plugin for Windows ONLY (`src/plugins/vfs/{win,off}`,
  no linux/mac). So on Linux/macOS "sign in" meant "download everything".
  The patch makes the no-VFS default `SELECTIVE_SYNC` (picker opens, nothing
  downloads until chosen); Windows keeps `USE_VFS`. There is no Linux/mac
  virtual-files option to select at this Pin - that is upstream, not the
  overlay.
- **A preset+locked server URL still shows the URL page.** The patch queues
  one `QWizard::next()` in the controller ctor when
  `AppConfig::serverUrl()` is set and `allowServerUrlChange()` is false, so
  the wizard opens on the sign-in step and the browser launches at once. The
  URL page's own validation is what runs, so a network failure still shows
  it with the error.

Verifying the GUI headlessly: run the AppImage under `xvfb-run -s "-screen 0
1280x900x24"` and `xwd -root -out x.xwd` (Chromium device emulation cannot
show any of this, and WebKit will not launch here). For the logged-in
window, seed an account with `scripts/smoke-sync.py seed` first and pass
`--show`. There is no `xdotool` on the dev box, so the Advanced page's
default radio cannot be clicked to for a screenshot - read the built default
in `build/materialized/<env>/src/gui/newaccountwizard/advancedsettingspagecontroller.cpp`
instead.

## Traps

- **`registry.aity.tech/catalog` is a curated mirror, not a Docker Hub
  proxy.** `catalog/library/alpine` exists; `catalog/library/ubuntu` and
  `catalog/owncloudci/*` return "not found" (pipelines #2788232840 and
  #2788463409). Images outside the curated set are pulled from Docker Hub
  directly and inherit that path's flakiness - hence the retry blocks.
- **Craft silently no-ops a second build of an installed package.** After
  the staging build, `craft owncloud/owncloud-client` for production does
  nothing (already merged) and `--package` archives STAGING files - the
  production leg must pass `-i` (ignore installed) plus the build-dir
  wipe. Failed exactly this way in pipeline #2788240525.
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
- `publish:staging-prerelease` / `promote`: implemented end to end
  (2026-09-02) but UNVERIFIED - no tag has run them, and both stay
  invisible until the `GITHUB_RELEASES_TOKEN` variable exists (the mirror
  deploy key cannot create releases). One release per tag: the staging
  pre-release is created first and promote flips the SAME release to a
  full Release, adds the production assets, the AppImage's .zsync and the
  materialised source tarball (ADR 0004), and pushes the update feeds to
  the mirror's gh-pages branch with `GITHUB_MIRROR_KEY`. What Raul must
  create, once: a GitHub FINE-GRAINED token scoped to the single repo
  `aity-cloud/drive-desktop` with the "Contents" repository permission set
  to read-write (releases ride the contents permission; no narrower one
  exists), stored as a protected+masked CI variable
  `GITHUB_RELEASES_TOKEN` on `aity-cloud/drive` (group level, so the other
  desktop-adjacent factories can reuse the pattern) - plus enabling Pages
  on the mirror (source: gh-pages branch, root) in the repo settings.

## Smoke image: libOpenGL.so.0 (hit 2026-08-25)

`AppRun --version` on a bare `ubuntu:24.04` died with `error while loading
shared libraries: libOpenGL.so.0` even under `QT_QPA_PLATFORM=offscreen`:
the AppImage bundles Qt but not the GL vendor-neutral dispatch library or
the X/xcb runtime the platform plugins dlopen. The smoke job installs
`libopengl0 libglx0` plus the xcb set; if a Bump adds a new Qt platform
dependency, this apt line is where it shows up first.

## macOS identity and signing (2026-08-27)

The macOS bundle id is `tech.aity.drive.desktop` (staging:
`.desktop.staging`), NOT the iOS app's `tech.aity.drive`. They are
different binaries from different codebases and both can sit on one Apple
Silicon Mac (the iOS app runs there too), so one shared identifier is a
LaunchServices collision. Changed before anything shipped.

Signing is Developer ID, never App Store: the sandbox forbids this
client's Finder integration and arbitrary-filesystem sync, and GPLv2 has
no App Store exception. `scripts/sign-macos.sh` pulls the Developer ID
certificate from the shared match store (that is the only reason this
Factory has a Gemfile and a two-file fastlane setup), codesigns with
`--options runtime` (the notary service refuses anything else), then
notarises with `notarytool` and staples. Missing credentials skip the
whole step loudly rather than producing a quietly unsigned artifact.

Developer ID is gated by ROLE (Account Holder), not by membership type -
an individual Apple account signs and notarises fine.

## macOS: `ld: framework 'AGL' not found` (first build:macos run, 2026-08-30)

The first ever `build:macos` configured cleanly, compiled 69 of 425 objects
and died on the first link:

    ld: framework 'AGL' not found

AGL is Apple's legacy OpenGL wrapper, deprecated since 10.11 and gone from
the modern SDK. Nothing in this client calls it. It arrives through Qt:
Qt ships its own `FindWrapOpenGL.cmake`, that module looks AGL up and feeds
the result into `WrapOpenGL::WrapOpenGL`, which `Qt6::Gui` links - so every
target linking Qt6::Gui gets `-framework AGL`, and the first to link dies.
The link line names it in Qt's own order, `QtGui -framework AGL -framework
AppKit -framework OpenGL`, which is what identifies the source.

**The find SUCCEEDS and the link FAILS**, measured on the runner:

    absent : <Xcode>/…/MacOSX.sdk/System/Library/Frameworks/AGL.framework
    present: /System/Library/Frameworks/AGL.framework

CMake's lookup also searches the RUNNING SYSTEM; `ld` is pinned to the SDK
by `-isysroot`. Never read "configure found it" as "it is there".

`scripts/mac-sdk-quirks.sh` (run by the job after `--install-deps`) empties
the lookup inside the Craft prefix, which is disposable and rebuilt from
cache - no source patch, no blueprint fork. It asks the LINKER whether AGL
works rather than hardcoding an SDK version, so it becomes a no-op by itself
when a Qt bump or an SDK fixes this, and it is idempotent.

**Two mistakes in the first version of that script, both worth not
repeating:**

- It matched `find_library(... AGL)` only. Qt does not use `find_library`
  here - it uses its own Apple-framework wrapper - so the script patched
  NOTHING while printing output that read like success (`patched 0
  find_library(AGL) call(s)`). It now matches any lookup of the shape
  `<something-find-something>(<VAR> AGL)`, it PRINTS every AGL-referencing
  line it finds before touching anything, and it additionally appends a
  scrub of `WrapOpenGL::WrapOpenGL`'s link interface, which does not care
  how AGL got in there.
- Its per-file exit status leaked through `set -e` and killed the job with
  a bare `exit status 3`. The patching is now one python pass that returns
  only 0 or 1.

The lesson under both: a CI-only script still has to be exercised before it
is shipped. The fixture in this repo's history is two synthetic `.cmake`
files under a fake prefix; running the patcher over them takes seconds on
Linux and would have caught both.

### Two icon messages in the same log that are NOT defects

Checked, because they read like branding leaks and are not:

    -- Icon not found: .../theme/colored/aitydrive-icon.png
    -- Icon not found: .../theme/colored/wizard_logo.png

`generate_theme` probes the legacy "ownbrander" layout (`theme/colored/`)
first and the full-theme layout (`theme/universal/`) second. We ship the
full theme, so the first probe misses and the second resolves - all four of
`aitydrive-icon.svg`, `wizard_logo.svg`, `wizard_logo_dark.svg` and
`wizard_footer_logo.svg` are in `overlay/common/theme/universal/` and none
of them printed a miss. There is no fallback to ownCloud artwork here.

    -- not found sidebar_icons_at_1024px .../1024-aitydrive-sidebar.png
    -- not found sidebar_icons_at_512px  .../512-aitydrive-sidebar.png

Both files exist and are genuinely 1024x1024 and 512x512 (checked). The
message is not in this tree at all - it comes from outside the materialised
source, so it is the Craft blueprint or ECM doing the `.icns` assembly.
UNVERIFIED and macOS-only: confirm the sidebar icon on the built `.app`
once the link succeeds, rather than theorising about it now.

## The macos runner is a SHELL executor: nothing may assume a clean machine

GitLab wipes the PROJECT directory between jobs and nothing else. `$HOME` on
Raul's laptop persists, so every step that writes outside `$CI_PROJECT_DIR`
has to be written twice-runnable. The second `build:macos` run died on the
second line for exactly this reason:

    fatal: destination path '/Users/raul/craft/CraftMaster/CraftMaster'
    already exists and is not an empty directory

Two places are now hardened, and they fail in opposite ways:

- **The CraftMaster checkout** fails LOUDLY on the second run. Fixed by
  updating an existing checkout in place and only cloning when there is no
  usable git dir there.
- **`$HOME/craft/binaries`**, Craft's package destination, fails SILENTLY:
  the job used to `mv "$HOME"/craft/binaries/*` into `dist/`, so a previous
  run's `.dmg` would be collected, artifacted and eventually signed and
  notarised as if this pipeline had produced it. The directory is now emptied
  before packaging, and the collection step fails if `--package` produced
  nothing instead of silently shipping whatever was lying around. This one
  had never fired yet - it was waiting for the first run that got far enough
  to package twice.

The rest of the job is deliberately left alone: `materialize.sh` writes only
under the project dir, and Craft's own `--setup` / `--unshelve` / `--set` are
built for persistent CI workspaces. `scripts/mac-sdk-quirks.sh` is idempotent
by construction (it re-checks the linker and skips files it has already
marked).

When adding a step to `build:macos`, ask what it leaves behind in `$HOME` and
what happens when it finds that thing already there.

## macOS: `Finder got an error: AppleEvent timed out. (-1712)` (2026-08-30)

The run after the AGL fix compiled and linked all 425 objects and then died
in packaging. ownCloud's craft-core fork packages with `create-dmg`, which
drives FINDER over AppleScript to position the icons and set the window
background. That needs a logged-in Aqua session AND macOS Automation (TCC)
permission for the calling process; a GitLab LaunchAgent has neither
reliably - the TCC prompt has nobody to answer it, so the Apple event just
times out after the expensive part of the job is already done.

`scripts/mac-dmg-headless.sh` adds create-dmg's own `--skip-jenkins`, which
upstream documents as "skip Finder-prettifying AppleScript, useful in Sandbox
and non-GUI environments". The DMG still carries the app and the
`/Applications` drop link; what is lost is icon positioning and the
background image.

**Deliberately NOT fixed by granting Automation permission.** That would make
the build work only while somebody is logged in with Finder responsive, and
hang for five minutes when they are not. A release build must not depend on a
desktop session, and the cosmetics are worth strictly less than that.

**The better fix, when the window layout starts to matter:** KDE's craft-core
uses `dmgbuild` instead - pure Python, no Finder at all, and it keeps the
background and icon positions. Switching means replacing that packager's
`createPackage` wholesale, which is more than a quirk workaround deserves
today. The script already recognises the dmgbuild variant and no-ops on it,
so a craft-core bump that adopts it needs no further action here.

## The DMG shipped upstream's trademark in its FILENAME (2026-08-30)

The first successful macOS package produced:

    dist/macos-production/owncloud-client-HEAD-14-macos-clang-arm64.dmg

The `.app` inside was branded correctly all along - Craft names the PACKAGE
after the blueprint, and the macOS job moved it into `dist/` untouched while
the AppImage job had been renaming its output via `scripts/collect-binaries.sh`
since day one. meta/AGENTS.md allows no "owncloud" in anything we hand out,
and a filename is the first thing a customer sees.

`collect-binaries.sh` now handles both platforms and the macOS job uses it:

    aity-drive-7.1.0.<build>-macos-arm64.dmg (+ .sha256)

Two macOS specifics in there: the destination is overridable with
`COLLECT_DEST` because the macOS job writes to `dist/macos-<env>` rather than
`dist/<env>`, and checksums fall back to `shasum -a 256` because macOS has no
`sha256sum`. Both paths are exercised in the repo's history against a fake
Darwin PATH with no `sha256sum` present.

## Signing preflight, and why bundler could not find fastlane (2026-08-30)

`bundle install --quiet && bundle exec fastlane` failed with:

    bundler: command not found: fastlane
    Install missing gem executables with `bundle install`

after the client had built and the DMG had been packaged - i.e. at the most
expensive possible moment. The runner carries Homebrew ruby 4.0.6 alongside
user gems in `~/.gem/ruby/4.0.0`, and every invocation logs two rdoc versions
initialising over each other, so that environment is inconsistent before we
ask it for anything.

Two changes, and the second matters more than the first:

- `--quiet` is gone, because it hid what bundler actually did. If bundler
  cannot produce a runnable fastlane the script now PRINTS the ground truth
  (`bundle list`, `bundle config`, `gem env`, every `fastlane` on PATH) and
  then self-heals: fastlane on PATH if there is one, otherwise a
  `--user-install`. It only gives up after that, and says so.
- **`scripts/sign-macos.sh --preflight` runs FIRST in the job**, before
  `materialize.sh`. It checks the credential variables and resolves fastlane,
  then stops - none of which needs build output. A missing variable or broken
  gem now fails in seconds instead of after the build.

The general rule the third macOS iteration in a row taught: when a step near
the END of a long job depends only on things known at the START, check it at
the start. The desktop factory's build is ~6 minutes; the iOS one is far
worse.

## Signing: the keychain first, match only as a fallback (2026-08-30)

The run that got through build, DMG and match's git store ended with Apple
refusing:

    This request is forbidden for security reasons -
    This operation can only be performed by the Account Holder.

**An App Store Connect API key is not the Account Holder**, whatever role it
carries, and creating a Developer ID certificate is Account-Holder-only. No
retry helps and no keychain prompt is involved: that is an HTTP response from
Apple's portal. fastlane reaches the same conclusion by itself and prints
"Enabling match readonly mode" in every CI run.

The note in this file and in the checkpoint said "Developer ID is gated by
ROLE (Account Holder), not membership type - the individual Apple account can
do it today". True, and never the problem; what it omitted is that the
account holder has to be the one ASKING, which means Apple ID login with 2FA
from a Mac, not an API key from a runner.

So `sign-macos.sh` now looks in the KEYCHAIN first. Raul's Mac already holds
a `Developer ID Application: Raul Bag` certificate, and when an identity is
present the script needs no match store, no fastlane and no gems at all - it
just signs. `MACOS_SIGN_IDENTITY` overrides the search when several
identities exist. match remains as the fallback for a machine that holds no
certificate, and its lane is `readonly: true` permanently.

Consequences worth knowing:

- The credential requirements now split. Notarisation always needs
  `ASC_KEY_ID` / `ASC_ISSUER_ID` / `ASC_KEY_P8`; the match variables are
  required ONLY when a certificate has to be fetched. A machine with the
  certificate and the API key can sign and notarise with nothing else.
- **codesign needs the private KEY**, so macOS asks permission the first time
  a process that is not Xcode uses it. A LaunchAgent runner cannot answer
  that prompt unattended, and a Deny fails the job at signing. Allow it once
  for that keychain and it stops asking.
- `developer_id_certificate_bootstrap` exists for the day a second machine
  needs the certificate in the store. Certificates cap at 5 per account and
  revoking one invalidates everything already signed with it, so it is a
  once-ever command, not a refresh.

### While here: the runner's gem env is split

    USER INSTALLATION DIRECTORY: /Users/raul/.gem/ruby/4.0.0
    EXECUTABLE DIRECTORY:        /opt/homebrew/lib/ruby/gems/4.0.0/bin

which is why `bundle install` reports success and `bundle exec fastlane` then
cannot find the binary. The script puts the user gem bin dir on PATH before
trying anything, so the fallback installs fastlane at most once per machine
rather than once per invocation. On the keychain path it never runs at all.

### An Apple Distribution certificate is NOT a substitute (measured 2026-08-30)

The runner reported:

    identities this process can see:
      1) 5CEA2980... "Apple Distribution: Raul Bag (Z3C9R3AHZ8)"
         1 valid identities found
    keychains in its search list:
      "/Users/raul/Library/Keychains/login.keychain-db"
      "/Users/raul/Library/Keychains/fastlane_tmp_keychain-db"

So the runner's keychain visibility was never the problem - the login
keychain is in its search list and it can read it. The machine simply holds
the wrong TYPE of certificate:

- **Apple Development** signs builds for your own devices.
- **Apple Distribution** signs for the App Store. This is what the iOS
  Factory uses, and it is the one that was there.
- **Developer ID Application** is the only one that can be NOTARISED and the
  only one Gatekeeper accepts for a download outside the App Store.

Signing the DMG with the Distribution certificate would be worse than
shipping it unsigned: it would look signed and fail to open on every Mac but
this one. The script deliberately refuses and says why, rather than picking
whatever identity it finds.

Creating the right one is Account-Holder-only, so it is a human step either
way. Xcode (Settings > Accounts > Manage Certificates > + > Developer ID
Application) puts it in the login keychain, where the runner will find it
immediately. `developer_id_certificate_bootstrap` does the same AND pushes it
to the match store, which is what a second machine or a different runner
would need later.
