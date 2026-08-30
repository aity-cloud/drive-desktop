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
#        scripts/sign-macos.sh --preflight
#
# --preflight does the credential check and resolves fastlane, then stops.
# The job runs it BEFORE the build: signing is the last step of a job whose
# build takes many minutes, so a missing variable or a gem that will not load
# used to be discovered at the most expensive possible moment. Everything it
# checks is cheap and none of it depends on build output.
set -euo pipefail

PREFLIGHT=0
if [ "${1:-}" = "--preflight" ]; then PREFLIGHT=1; shift; fi

DIST="${1:-}"
if [ "$PREFLIGHT" -eq 0 ]; then
  : "${DIST:?usage: sign-macos.sh <dist-dir> | sign-macos.sh --preflight}"
  [ -d "$DIST" ] || { echo "sign-macos: no such directory: $DIST"; exit 1; }
fi

missing=""
for v in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8 AITY_TEAM_ID MATCH_PASSWORD MATCH_GIT_PRIVATE_KEY; do
  [ -n "${!v:-}" ] || missing="$missing $v"
done
if [ -n "$missing" ]; then
  echo "sign-macos: SKIPPING signing and notarisation - missing:$missing"
  if [ "$PREFLIGHT" -eq 1 ]; then
    echo "sign-macos: preflight - the build will produce UNSIGNED artifacts, which is fine for a test build."
  else
    echo "sign-macos: the artifacts in $DIST are UNSIGNED; macOS will refuse to open them on another machine."
  fi
  exit 0
fi

# RESOLVING FASTLANE. `bundle install --quiet && bundle exec fastlane` looked
# obvious and failed with "bundler: command not found: fastlane" (2026-08-30)
# on a runner carrying Homebrew ruby 4.0.6 next to user gems in
# ~/.gem/ruby/4.0.0 - two rdoc versions load on every invocation, so the
# environment is already inconsistent before we ask it for anything.
#
# --quiet is gone: it hid whatever bundler actually did. If bundler cannot
# produce a working fastlane we print the ground truth (bundle list, bundle
# config, gem env, every fastlane on PATH) and then self-heal, because a
# signing job that dies on gem plumbing after a 25 minute build is the worst
# possible place to stop.
echo "sign-macos: resolving fastlane"
FASTLANE=""
if bundle install; then
  if bundle exec fastlane --version >/dev/null 2>&1; then
    FASTLANE="bundle exec fastlane"
    echo "sign-macos: using bundler"
  fi
fi

if [ -z "$FASTLANE" ]; then
  echo "sign-macos: bundler cannot run fastlane here. Ground truth:"
  { bundle list; bundle config; gem env; type -a fastlane; } 2>&1 | sed 's/^/    /' || true

  if command -v fastlane >/dev/null 2>&1 && fastlane --version >/dev/null 2>&1; then
    echo "sign-macos: falling back to the fastlane already on PATH"
    FASTLANE="fastlane"
  else
    echo "sign-macos: installing fastlane into the user gem dir"
    gem install --no-document --user-install fastlane
    PATH="$(ruby -e 'require "rubygems"; print Gem.user_dir')/bin:$PATH"
    export PATH
    fastlane --version >/dev/null 2>&1 || {
      echo "sign-macos: fastlane still not runnable after a user-install - stopping."
      exit 1
    }
    FASTLANE="fastlane"
  fi
fi

if [ "$PREFLIGHT" -eq 1 ]; then
  echo "sign-macos: preflight OK - credentials present and fastlane runnable."
  exit 0
fi

echo "sign-macos: fetching the Developer ID certificate from the match store"
$FASTLANE developer_id_certificate

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
