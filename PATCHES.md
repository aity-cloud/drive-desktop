# Patch inventory

Hunk-by-hunk inventory of `patches/` (ADR 0001: a patch needs "not
shippable without it"; every patch is re-validated on every Bump).

**Current count: 1.**

## 0001-preset-server-flow-and-brand-colors.patch

Raul rejected the first installable build on three product grounds
(2026-09-02): the wizard still shows a server page instead of going
straight to the login, signing in downloads everything, and the app
outside the wizard keeps ownCloud's blues. None of the four hunks is
expressible through the OEM theme - the upstream theme has no hook for
any of them - so a build without this patch is not shippable as Aity
Drive. Candidates for upstreaming as proper `Theme` hooks; drop any hunk
a Bump makes redundant.

- **`src/gui/newaccountwizard/newaccountwizardcontroller.cpp`** - when the
  theme presets the server URL and forbids changing it (our
  `overrideServerUrl()`), the URL page has nothing to ask; queue one
  `QWizard::next()` so the wizard opens on the sign-in step and the
  browser launches immediately. The page's own validation still runs (it
  performs the server checks), and a failed check leaves the URL page
  visible with its error, so nothing is lost on a broken network.
- **`src/gui/newaccountwizard/advancedsettingspagecontroller.cpp`** - when
  no virtual-files plugin exists (this Pin ships VFS for Windows only),
  the default sync type becomes SELECTIVE_SYNC instead of SYNC_ALL: the
  folder picker opens after sign-in and nothing downloads until chosen.
  Windows keeps upstream's USE_VFS default, which is what the spec's
  "virtual files where they exist" asks for.
- **`src/gui/main.cpp`** - apply the theme's wizard colors to
  `QPalette::Highlight`/`HighlightedText` app-wide (guarded on the theme
  providing a color, so vanilla builds are untouched). This is what turns
  the selected-account tab and list selections brand red instead of the
  platform style's blue.
- **`src/resources/resources.cpp`** - the core-icon tint is a hardcoded
  pair of literals (`#435671`/`#ADACAB`) used by every in-app icon
  (toolbar, connection state, folder status, default space image);
  replaced with the aity-ds neutrals slate-600 `#4b5160` / slate-400
  `#99a0af`.
