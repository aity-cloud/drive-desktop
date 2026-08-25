#!/usr/bin/env bash
# Generate the desktop update feeds into public/update/, in exactly the
# formats the client requests at the Pin (v7.1.x):
#
#   linux + windows (src/gui/updater/ocupdater.cpp, updateinfo.cpp): a GET on
#     APPLICATION_UPDATE_URL returning an <owncloudclient> XML document with
#     <version> (compared as QVersionNumber against the running
#     x.y.z.buildnumber), <versionstring>, <web> and <downloadurl>. For the
#     AppImage the <downloadurl> must be the *.zsync file (it is handed to
#     libappimageupdate as "zsync|<url>"); for Windows it is the installer.
#   macos (sparkleupdater_mac.mm): a Sparkle appcast RSS feed.
#
# The client only appends query parameters (platform, oem, channel, ...) to
# APPLICATION_UPDATE_URL, and GitHub Pages is static, so platform dispatch
# happens by path: the production OEM.cmake bakes
#   .../update/linux/    .../update/windows/    .../update/macos/appcast.xml
# and Pages serves update/<platform>/index.html (query string ignored). The
# XML lives in an index.html because that is the only name Pages serves for
# a directory URL; the client parses the body, never the content type.
#
# Published by the manual promote job to the Public Mirror's GitHub Pages -
# never by hand (AGENTS.md: CI publishes, humans promote).
#
# Usage:
#   scripts/gen-update-feeds.sh \
#       --version 7.1.0.123 \
#       --tag v7.1.0-aity-1 \
#       [--base-url https://github.com/aity-cloud/drive-desktop/releases/download] \
#       [--appimage aity-drive-7.1.0.123-linux-x86_64.AppImage] \
#       [--windows-installer aity-drive-7.1.0.123-windows-cl-msvc2022-x86_64.exe] \
#       [--macos-pkg aity-drive-7.1.0.123-macos-clang-arm64.pkg]
#
# The AppImage's .zsync sidecar (zsyncmake output, uploaded next to the
# AppImage by the promote job) is assumed at <appimage>.zsync.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="" TAG=""
BASE_URL="https://github.com/aity-cloud/drive-desktop/releases/download"
APPIMAGE="" WINDOWS_INSTALLER="" MACOS_PKG=""

while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --tag) TAG="$2"; shift 2 ;;
        --base-url) BASE_URL="$2"; shift 2 ;;
        --appimage) APPIMAGE="$2"; shift 2 ;;
        --windows-installer) WINDOWS_INSTALLER="$2"; shift 2 ;;
        --macos-pkg) MACOS_PKG="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
[ -n "$VERSION" ] && [ -n "$TAG" ] || { echo "usage: --version x.y.z.build --tag vX.Y.Z-aity-N [...]" >&2; exit 2; }

RELEASE_WEB="https://github.com/aity-cloud/drive-desktop/releases/tag/$TAG"
DL="$BASE_URL/$TAG"

mkdir -p public/update/linux public/update/windows public/update/macos

write_owncloudclient_xml() { # $1=outfile $2=downloadurl
    cat > "$1" <<XML
<?xml version="1.0"?>
<owncloudclient>
    <version>$VERSION</version>
    <versionstring>Aity Drive $VERSION</versionstring>
    <web>$RELEASE_WEB</web>
    <downloadurl>$2</downloadurl>
</owncloudclient>
XML
}

if [ -n "$APPIMAGE" ]; then
    # AppImage self-update consumes the zsync control file.
    write_owncloudclient_xml public/update/linux/index.html "$DL/$APPIMAGE.zsync"
else
    # No release yet: an empty (unparseable) body means "no update" to the
    # client, which is the safe default.
    : > public/update/linux/index.html
fi

if [ -n "$WINDOWS_INSTALLER" ]; then
    write_owncloudclient_xml public/update/windows/index.html "$DL/$WINDOWS_INSTALLER"
else
    : > public/update/windows/index.html
fi

# Sparkle appcast skeleton for macOS. Enclosure URL + EdDSA signature
# (sparkle:edSignature) are filled in once the macOS build and Developer ID
# signing exist (runbook: meta/docs/runbooks/publisher-accounts.md); until
# then the feed is a valid appcast with no items = no update offered.
cat > public/update/macos/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Aity Drive</title>
        <link>https://aity-cloud.github.io/drive-desktop/update/macos/appcast.xml</link>
        <description>Aity Drive desktop client updates for macOS</description>
        <language>en</language>
$(if [ -n "$MACOS_PKG" ]; then cat <<ITEM
        <item>
            <title>Aity Drive $VERSION</title>
            <link>$RELEASE_WEB</link>
            <sparkle:version>$VERSION</sparkle:version>
            <sparkle:shortVersionString>${VERSION%.*}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
            <pubDate>$(date -R)</pubDate>
            <enclosure url="$DL/$MACOS_PKG"
                       sparkle:edSignature="TODO-FILLED-BY-PROMOTE-ONCE-SIGNING-EXISTS"
                       length="0"
                       type="application/octet-stream"/>
        </item>
ITEM
fi)
    </channel>
</rss>
XML

echo "gen-update-feeds: wrote public/update/{linux,windows}/index.html and public/update/macos/appcast.xml for $TAG ($VERSION)"
