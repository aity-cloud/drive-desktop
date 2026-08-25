# Aity Drive - staging Environment build (server drive.aity.works).
#
# Included by upstream THEME.cmake when the materialised tree carries this
# overlay as its branding/ directory (scripts/materialize.sh staging).
# Own install identity so both Environment builds live on one device
# (meta/specs/aity-drive-v1.md, identity table); the icon set carries the
# visible STG badge.

set(APPLICATION_NAME       "Aity Drive (staging)")
set(APPLICATION_SHORTNAME  "aitydrive-staging")
set(APPLICATION_EXECUTABLE "aity-drive-staging")
set(APPLICATION_DOMAIN     "aity.tech")
set(APPLICATION_VENDOR     "AITY CLOUD SRL")
set(APPLICATION_REV_DOMAIN "tech.aity.drive.staging")
set(APPLICATION_ICON_NAME  "aitydrive-staging")
set(APPLICATION_VIRTUALFILE_SUFFIX "aitydrive-staging" CACHE STRING "Virtual file suffix (not including the .)")

set(LINUX_PACKAGE_SHORTNAME "aitydrive-staging")

# No updater on staging builds: WITHOUT_AUTO_UPDATER makes THEME.cmake force
# WITH_AUTO_UPDATER off, and leaving APPLICATION_UPDATE_URL unset keeps
# Theme::updateCheckUrl() empty, so no update check ever fires.
set(WITHOUT_AUTO_UPDATER TRUE)

set(THEME_CLASS   "AityDriveTheme")
set(THEME_INCLUDE "${OEM_THEME_DIR}/aitydrivetheme.h")

# Baked into the Theme subclass (overrideServerUrl()).
add_compile_definitions(AITY_SERVER_URL="https://drive.aity.works")

# No crash reporter, no submit URL (client defaults, decision 15).
option(WITH_CRASHREPORTER "Build crashreporter" OFF)
set(CRASHREPORTER_SUBMIT_URL "" CACHE STRING "URL for crash reporter")
