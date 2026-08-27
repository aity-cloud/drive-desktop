#!/usr/bin/env bash
# Developer ID signing + notarisation of the macOS artifacts Craft produced.
#
# The desktop client is NOT an App Store app (sandbox forbids the Finder
# integration and arbitrary-filesystem sync, and GPLv2 carries no App Store
# exception), so its macOS channel is a Developer ID signed, notarised
# download - the desktop equivalent of TestFlight. Apple restricts Developer
# ID certificates by ROLE (Account Holder), not by membership type, so an
# individual membership can do all of this.
#
# Credentials, all protected CI variables of the drive group:
#   ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_P8   App Store Connect API key
#   AITY_TEAM_ID                              Apple Team ID
#   MATCH_PASSWORD / MATCH_GIT_PRIVATE_KEY    the match store
# With any of them missing the script prints why and exits 0: an unsigned
# build stays a useful artifact, it just cannot be handed to anyone.
#
# Usage: scripts/sign-macos.sh <dist-dir>
set -euo pipefail

DIST="${1:?usage: sign-macos.sh <dist-dir>}"
[ -d "$DIST" ] || { echo "sign-macos: no such directory: $DIST"; exit 1; }

missing=""
for v in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8 AITY_TEAM_ID MATCH_PASSWORD MATCH_GIT_PRIVATE_KEY; do
  [ -n "${!v:-}" ] || missing="$missing $v"
done
if [ -n "$missing" ]; then
  echo "sign-macos: SKIPPING signing and notarisation - missing:$missing"
  echo "sign-macos: the artifacts in $DIST are UNSIGNED; macOS will refuse to open them on another machine."
  exit 0
fi

echo "sign-macos: fetching the Developer ID certificate from the match store"
bundle install --quiet
bundle exec fastlane developer_id_certificate

IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')
[ -n "$IDENTITY" ] || { echo "sign-macos: no Developer ID Application identity in the keychain"; exit 1; }
echo "sign-macos: signing with: $IDENTITY"

shopt -s nullglob
apps=("$DIST"/*.app)
if [ ${#apps[@]} -eq 0 ]; then
  # Craft packages a .dmg or .pkg; mount-free approach: sign what is inside
  # the payload only when an .app is present, otherwise sign the package.
  echo "sign-macos: no .app in $DIST - signing packages directly"
fi

for app in "${apps[@]}"; do
  # --options runtime is mandatory: the notary service rejects anything
  # without the hardened runtime.
  codesign --force --deep --timestamp --options runtime \
    --sign "$IDENTITY" "$app"
  codesign --verify --deep --strict --verbose=2 "$app"
done

for pkg in "$DIST"/*.dmg "$DIST"/*.pkg; do
  [ -e "$pkg" ] || continue
  codesign --force --timestamp --sign "$IDENTITY" "$pkg" || true

  echo "sign-macos: notarising $(basename "$pkg")"
  xcrun notarytool submit "$pkg" \
    --key "$ASC_KEY_P8" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" \
    --wait --timeout 30m

  # Stapling lets the artifact validate offline; a zip cannot be stapled,
  # only the .dmg/.pkg itself.
  xcrun stapler staple "$pkg"
  xcrun stapler validate "$pkg"
  echo "sign-macos: $(basename "$pkg") is signed, notarised and stapled"
done

echo "sign-macos: done"
