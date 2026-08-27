# Aity Drive - production Environment build (server drive.aity.tech).
#
# Included by upstream THEME.cmake when the materialised tree carries this
# overlay as its branding/ directory (scripts/materialize.sh production).
# Identity values: meta/specs/aity-drive-v1.md, identity table.

set(APPLICATION_NAME       "Aity Drive")
set(APPLICATION_SHORTNAME  "aitydrive")
set(APPLICATION_EXECUTABLE "aity-drive")
set(APPLICATION_DOMAIN     "aity.tech")
set(APPLICATION_VENDOR     "AITY CLOUD SRL")
# Distinct from the iOS app's id (tech.aity.drive): they are
# different binaries from different codebases, and on an Apple Silicon Mac
# both can be installed at once (the iOS app runs there too), which one
# shared identifier turns into a LaunchServices collision. Registered as
# its own App ID, signed with Developer ID, never App Store.
set(APPLICATION_REV_DOMAIN "tech.aity.drive.desktop")
set(APPLICATION_ICON_NAME  "aitydrive")
set(APPLICATION_VIRTUALFILE_SUFFIX "aitydrive" CACHE STRING "Virtual file suffix (not including the .)")

set(LINUX_PACKAGE_SHORTNAME "aitydrive")

# The updater is ON for production. Static per-OS feeds on the Public
# Mirror's GitHub Pages: the client appends only query parameters, and the
# three platforms consume three different formats (owncloudclient XML with a
# zsync downloadurl for the AppImage, owncloudclient XML with an installer
# downloadurl for Windows, a Sparkle appcast for macOS), so the dispatch a
# dynamic updater server would do from the query string is done by path
# here. scripts/gen-update-feeds.sh generates all three.
if(APPLE)
    set(APPLICATION_UPDATE_URL "https://aity-cloud.github.io/drive-desktop/update/macos/appcast.xml" CACHE STRING "URL for updater")
elseif(WIN32)
    set(APPLICATION_UPDATE_URL "https://aity-cloud.github.io/drive-desktop/update/windows/" CACHE STRING "URL for updater")
else()
    set(APPLICATION_UPDATE_URL "https://aity-cloud.github.io/drive-desktop/update/linux/" CACHE STRING "URL for updater")
endif()

set(THEME_CLASS   "AityDriveTheme")
set(THEME_INCLUDE "${OEM_THEME_DIR}/aitydrivetheme.h")

# Baked into the Theme subclass (overrideServerUrl()).
add_compile_definitions(AITY_SERVER_URL="https://drive.aity.tech")

# No crash reporter, no submit URL (client defaults, decision 15).
option(WITH_CRASHREPORTER "Build crashreporter" OFF)
set(CRASHREPORTER_SUBMIT_URL "" CACHE STRING "URL for crash reporter")
