# Upstream and the Pin

Upstream: `github.com/owncloud/client` - the ownCloud desktop sync client,
GPL-2.0-or-later, Qt 6, built with KDE Craft.

The Pin is the `UPSTREAM_TAG` variable in `.gitlab-ci.yml`:

```yaml
variables:
  # renovate: datasource=github-tags depName=owncloud/client
  UPSTREAM_TAG: "v7.1.1"
```

Bumped v7.1.0 -> v7.1.1 on 2026-09-02: a single upstream change,
`src/libsync/config/appconfig.cpp` (OIDC `prompt` was read from the ports
key, and `.ini` port lists were mis-parsed). It touches none of the overlay
inputs or `patches/0001` targets - verified with `git diff v7.1.0 v7.1.1`
(8 files: the fix + its test, VERSION.cmake, CHANGELOG, and GitHub runner
labels in `.github/workflows/*` that our CI does not use). The Renovate MR
that watch produces is a SIGNAL, not a mergeable change - the Bump procedure
is in `../meta/docs/maintenance.md`.

## The branding mechanism at this Pin

Upstream's `THEME.cmake` implements three ways to inject an OEM theme, in
this order:

1. `-DWITH_EXTERNAL_BRANDING=<git url>` (+`WITH_EXTERNAL_BRANDING_TAG`):
   FetchContent-clones a branding repo at configure time and uses it as
   `OEM_THEME_DIR`.
2. An in-tree `branding/` directory at the source root: picked up
   automatically as `OEM_THEME_DIR`.
3. An explicit `-DOEM_THEME_DIR=<path>` cache variable.

Whichever wins, `${OEM_THEME_DIR}/OEM.cmake` is included INSTEAD of
upstream's `OWNCLOUD.cmake` and defines the whole identity
(`APPLICATION_*`, `THEME_CLASS`/`THEME_INCLUDE`, updater and crash
reporter switches). `WITHOUT_AUTO_UPDATER` defined there force-disables
`WITH_AUTO_UPDATER`.

**This Factory uses mechanism 2**: `scripts/materialize.sh <env>` copies
`overlay/common/` + `overlay/<env>/` into the materialised tree as
`branding/`. Not 1, because that would re-introduce a network fetch of a
second repo inside the build (the Pin must fully determine the build, and
the per-Environment overlay would need two branches or repos); not 3,
because 2 needs no extra flag and is what a developer opening the
materialised tree gets by default.

The theme assets follow what `cmake/modules/OCBundleResources.cmake` and
the root `CMakeLists.txt` glob at this Pin:

- `theme/colored/<size>-<APPLICATION_ICON_NAME>-icon.png` - app icon set
  (`ecm_add_app_icon` builds the .ico/.icns from it, the Linux install
  rules feed hicolor from it),
- `theme/colored/<size>-<APPLICATION_ICON_NAME>-sidebar.png` - macOS
  sidebar icons,
- `theme/universal/<APPLICATION_ICON_NAME>-icon.svg`, `wizard_logo.svg`,
  `wizard_logo_dark.svg`, `wizard_footer_logo.svg`,
- `theme/{colored,dark,black,white}/state-{ok,error,information,offline,pause,sync}.svg`
  - REQUIRED (configure fails if any is missing).

The Theme subclass is header-only (`overlay/common/aitydrivetheme.h`),
compiled through `theme.cpp`'s `#include THEME_INCLUDE`; it must not carry
`Q_OBJECT` (nothing runs moc on it).

## The build recipe at this Pin

Upstream builds with CraftMaster + the repo's own `.craft.ini` (Qt and
dependency pins, upstream's public binary cache at
`download.owncloud.com/desktop/craft/cache/`) and the
`owncloud/owncloud-client` blueprint from
`github.com/owncloud/craft-blueprints-owncloud` (wired via the repo's
`.craft.shelf`). Our CI reproduces upstream's
`.github/workflows/main.yml` matrix legs:

- Linux AppImage: container `owncloudci/appimage-build:sles15-amd64`,
  target `linux-64-gcc`, `dev-utils/linuxdeploy`,
  `enableAppImageUpdater=true`, `enableAutoUpdater=true`.
- Windows: `windows-cl-msvc2022-x86_64` + `dev-utils/nsis` (installer .exe;
  upstream's MSI path is still TODO in the blueprint).
- macOS: `macos-clang-arm64`.

The blueprint reads `APPLICATION_EXECUTABLE` / `APPLICATION_SHORTNAME`
from the environment at package time (executable filter, package naming) -
they must match the Environment's OEM.cmake, which is why the CI exports
them per Environment. `buildNumber=$CI_PIPELINE_IID` becomes
`MIRALL_VERSION_BUILD`, i.e. versions are `<upstream>.<pipeline iid>`.

`scripts/craft.sh` / `scripts/craft.ps1` are 1:1 ports of upstream's
`.github/workflows/.craft.ps1` (config from the materialised tree, our
override in `ci/craft-override.ini`).

## Bumping

1. Move `UPSTREAM_TAG` (a Renovate MR proposes it; the Bump itself is a
   human act, `../meta/docs/maintenance.md`).
2. Diff upstream's `THEME.cmake`, `OWNCLOUD.cmake`, `OCBundleResources.cmake`
   and `src/libsync/theme.{h,cpp}` between the Pins - renamed OEM
   variables, changed icon globs and changed Theme virtuals are the only
   breaking changes an Overlay can see. Also diff `.craft.ini` /
   `.github/workflows/main.yml` for build-recipe drift.
3. `scripts/materialize.sh` both Environments; re-validate `patches/`
   (drop what upstream absorbed).
4. Push, let `build:appimage` + `smoke:appimage` prove it, tag
   `v<upstream>-aity-1`.
