# Aity Drive - desktop Factory

Produces the Aity Drive desktop sync client for Windows, macOS and Linux
from the upstream ownCloud client (`owncloud/client`) at a pinned release,
plus the Overlay in this repository - branding only, zero source patches
(`PATCHES.md`). Part of the `aity-cloud/drive` subgroup; the spec is
`../meta/specs/aity-drive-v1.md`, the vocabulary `../meta/CONTEXT.md`,
the agent rules `AGENTS.md`.

Two Environment builds come out of every pipeline, side-by-side
installable:

| | production | staging |
|---|---|---|
| Server (preset, locked) | `https://drive.aity.tech` | `https://drive.aity.works` |
| Name | Aity Drive | Aity Drive (staging), STG-badged icon |
| Executable / shortname | `aity-drive` / `aitydrive` | `aity-drive-staging` / `aitydrive-staging` |
| Updater | on, feeds on the Public Mirror's Pages | off |

## Layout

```
.gitlab-ci.yml          the Pin (UPSTREAM_TAG, renovate-annotated) + pipeline
overlay/
  common/               Theme subclass (aitydrivetheme.h), tray state icons,
                        wizard logos
  production/           OEM.cmake + icon set per Environment
  staging/              (staging icons carry the STG badge)
patches/                *.patch applied after the overlay (empty, keep it so)
scripts/
  materialize.sh        clone Pin -> overlay as branding/ -> patches
  gen-icons.sh|py       regenerate overlay icons from ../meta/brand/logo.svg
  gen-update-feeds.sh   update feeds into public/update/ (formats: UPSTREAM.md)
  craft.sh|ps1          CraftMaster wrappers (ports of upstream's .craft.ps1)
  smoke-appimage.sh     branding smoke on a built AppImage
ci/craft-override.ini   our Craft config override
UPSTREAM.md             what the Pin is, the branding mechanism, how to Bump
MAINTAINING.md          traps + standing gaps (read before touching CI)
```

## Building locally

A materialised tree is a normal upstream checkout with a `branding/` dir,
so it opens in an IDE and builds like upstream:

```sh
scripts/materialize.sh staging          # or production
cmake -S build/materialized/staging -B build/b -G Ninja
cmake --build build/b
```

(Qt 6.8, ECM and the rest of upstream's dependencies required - or use
Craft exactly like CI does, see `.gitlab-ci.yml` `build:appimage`.)
Local builds are for development only: nothing built on a workstation is
ever signed or published (`../meta/AGENTS.md`).

## Releases and update feeds

Tags `v<upstream>-aity-<n>` drive the release pipeline
(materialize -> build -> smoke -> publish-staging -> promote -> mirror).
The manual `promote` job publishes the production installers, the
materialised source tarball (ADR 0004) and the regenerated update feeds
from `scripts/gen-update-feeds.sh` to the Public Mirror
(`github.com/aity-cloud/drive-desktop`): installers + sources as a GitHub
Release, `public/update/` to the mirror's GitHub Pages, which
`APPLICATION_UPDATE_URL` (`https://aity-cloud.github.io/drive-desktop/update/...`)
points at. Nothing is ever pushed to the mirror or its Pages by hand.
