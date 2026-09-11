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
# Usage: scripts/sign-macos.sh <dist-dir>     notarise+staple every DMG in it
#        scripts/sign-macos.sh --sign <path>   Craft calls this during --package,
#                                             once with the .app, once with the .dmg
#        scripts/sign-macos.sh --preflight
#
# Craft's CodeSigning/MacCustomSignCommand (ci/craft-override.ini, macOS
# target only) routes BOTH of Craft's signing points here: the .app after
# bundling and the .dmg after create-dmg. It has to be both, because Craft's
# own package signer ends with `spctl -a -t open`, which rejects any Developer
# ID DMG that is not notarised yet - so without a custom command the package
# step can only succeed when Craft notarises itself, and that path wants an
# Apple ID plus app-specific password rather than the API key we have.
#
# The first notarisation attempt (2026-09-11) came back Invalid because only
# the DMG container was Developer ID signed while everything inside it still
# carried Craft's ad-hoc `--sign -`. The notary service checks every Mach-O.
#
# --preflight does the credential check and resolves fastlane, then stops.
# The job runs it BEFORE the build: signing is the last step of a job whose
# build takes many minutes, so a missing variable or a gem that will not load
# used to be discovered at the most expensive possible moment. Everything it
# checks is cheap and none of it depends on build output.
set -euo pipefail

PREFLIGHT=0; ONE=""
case "${1:-}" in
  --preflight) PREFLIGHT=1; shift ;;
  --sign) ONE="${2:?usage: sign-macos.sh --sign <file.app|file.dmg>}"; shift 2
          [ -e "$ONE" ] || { echo "sign-macos: no such path: $ONE"; exit 1; }
          # Craft buffers this command's output and did not show it when the
          # DMG leg failed (2026-09-11), so keep our own trace; the job prints
          # it when --package fails.
          SIGN_LOG="${CI_PROJECT_DIR:-/tmp}/sign-macos.log"
          exec > >(tee -a "$SIGN_LOG") 2>&1
          set -x ;;
esac

DIST="${1:-}"
if [ "$PREFLIGHT" -eq 0 ] && [ -z "$ONE" ]; then
  : "${DIST:?usage: sign-macos.sh <dist-dir> | --sign <path> | --preflight}"
  [ -d "$DIST" ] || { echo "sign-macos: no such directory: $DIST"; exit 1; }
fi

# Is a Developer ID Application identity ALREADY in the keychain? If so this
# script needs no match store, no fastlane and no gems at all - it just signs.
# That is the normal case on a Mac whose owner is the Apple account holder,
# and it is the ONLY case that works today: CI cannot mint the certificate
# (Apple: "This operation can only be performed by the Account Holder"), so
# whatever is already in the keychain is what we sign with.
#
# MACOS_SIGN_IDENTITY overrides the search when several identities exist and
# the first one found is not the one you mean.
find_developer_id() {
  security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}'
}

IDENTITY="${MACOS_SIGN_IDENTITY:-}"
[ -n "$IDENTITY" ] || IDENTITY="$(find_developer_id)"

if [ -n "$IDENTITY" ]; then
  echo "sign-macos: Developer ID identity already in the keychain: $IDENTITY"
  NEED_MATCH=0
else
  echo "sign-macos: no Developer ID Application identity in the keychain."
  # Ground truth, because "not found" has two very different causes and they
  # need opposite fixes: the certificate may be a different TYPE (an "Apple
  # Development" or "Apple Distribution" certificate is NOT a Developer ID
  # one and cannot notarise), or it may exist and simply be invisible to this
  # process - a LaunchAgent runner does not necessarily carry the desktop
  # session's keychain search list.
  echo "sign-macos: identities this process can see:"
  security find-identity -v -p codesigning 2>&1 | sed 's/^/    /' || true
  echo "sign-macos: keychains in its search list:"
  security list-keychains -d user 2>&1 | sed 's/^/    /' || true
  echo "sign-macos: identities in the login keychain specifically:"
  security find-identity -v -p codesigning "$HOME/Library/Keychains/login.keychain-db" 2>&1 | sed 's/^/    /' || true
  # Name the specific wrong-type mistake, because it is the likely one and
  # the message "no identity found" sends people looking for a keychain
  # problem they do not have. Apple Development signs for your own devices;
  # Apple Distribution signs for the App Store. NEITHER can be notarised and
  # neither satisfies Gatekeeper for a download - only Developer ID
  # Application can. Measured 2026-08-30: this Mac had exactly one identity,
  # "Apple Distribution: Raul Bag", which is the iOS Factory certificate.
  if security find-identity -v -p codesigning 2>/dev/null | grep -qE 'Apple (Development|Distribution):'; then
    echo "sign-macos: NOTE - there IS an Apple Development/Distribution identity here."
    echo "sign-macos: that is not a substitute. Those sign for your own devices and"
    echo "sign-macos: for the App Store; the notary service rejects them and Gatekeeper"
    echo "sign-macos: refuses a download signed with one. Only Developer ID Application"
    echo "sign-macos: works for this client, and only the Apple account HOLDER can create it:"
    echo "sign-macos:   Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application"
    echo "sign-macos: or, to put it in the shared store at the same time:"
    echo "sign-macos:   bundle exec fastlane developer_id_certificate_bootstrap"
  fi
  echo "sign-macos: will try the match store instead"
  NEED_MATCH=1
fi

# Notarisation always needs the API key. The match variables are needed ONLY
# when we have to fetch a certificate we do not already hold.
required="ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8"
[ "$NEED_MATCH" -eq 1 ] && required="$required AITY_TEAM_ID MATCH_PASSWORD MATCH_GIT_PRIVATE_KEY"

missing=""
for v in $required; do
  [ -n "${!v:-}" ] || missing="$missing $v"
done
if [ -n "$missing" ]; then
  echo "sign-macos: SKIPPING signing and notarisation - missing:$missing"
  if [ "$PREFLIGHT" -eq 1 ]; then
    echo "sign-macos: preflight - the build will produce UNSIGNED artifacts, which is fine for a test build."
  else
    echo "sign-macos: ${ONE:-the artifacts in $DIST} UNSIGNED; macOS will refuse to open them on another machine."
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
# The runner's gem env is split: gems install to
#   USER INSTALLATION DIRECTORY: /Users/raul/.gem/ruby/4.0.0
# while executables are expected in
#   EXECUTABLE DIRECTORY: /opt/homebrew/lib/ruby/gems/4.0.0/bin
# so `bundle install` reports success and `bundle exec fastlane` then cannot
# find the binary. Putting the user gem bin dir on PATH up front means the
# fallback below installs fastlane at most ONCE per machine instead of once
# per invocation - preflight and the real run were each paying ~50s for it.
if command -v ruby >/dev/null 2>&1; then
  USER_GEM_BIN="$(ruby -e 'require "rubygems"; print Gem.user_dir' 2>/dev/null)/bin"
  case ":$PATH:" in
    *":$USER_GEM_BIN:"*) ;;
    *) [ -d "$USER_GEM_BIN" ] && PATH="$USER_GEM_BIN:$PATH" && export PATH ;;
  esac
fi

if [ "$NEED_MATCH" -eq 0 ]; then
  if [ "$PREFLIGHT" -eq 1 ]; then
    echo "sign-macos: preflight OK - signing identity present, notarisation credentials present."
    exit 0
  fi
else

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
# match is readonly forever (only the Account Holder can create this
# certificate, and not from a runner), so an empty store is not an error we
# can retry out of - it crashes with "No code signing identity found and
# cannot create a new one because you enabled readonly". Treat it the same
# as absent credentials: say so LOUDLY and leave the artifact unsigned,
# rather than failing a job whose build is otherwise good. Unsigned is an
# acceptable test build; a failed job that hides a usable DMG is not.
if ! $FASTLANE developer_id_certificate || [ -z "$(find_developer_id)" ]; then
  echo "sign-macos: NO Developer ID Application certificate is available - neither in the"
  echo "sign-macos: keychain nor in the match store, and only the Apple account HOLDER can"
  echo "sign-macos: create one (Xcode > Settings > Accounts > Manage Certificates > + >"
  echo "sign-macos: Developer ID Application, or: bundle exec fastlane developer_id_certificate_bootstrap)."
  echo "sign-macos: the artifacts in $DIST are UNSIGNED and UNNOTARISED. Gatekeeper will"
  echo "sign-macos: refuse to open them on any other Mac until that certificate exists."
  exit 0
fi

IDENTITY="$(find_developer_id)"

fi   # NEED_MATCH

echo "sign-macos: signing with: $IDENTITY"

sign_app() {
  local app="$1" main
  main="$app/Contents/MacOS/$(basename "$app" .app)"
  local flags=(--force --options runtime --timestamp \
               --preserve-metadata=identifier,entitlements --sign "$IDENTITY")
  # --deep never descends into Contents/Resources, and Qt's QML plugins live
  # there - the notary service named three of them (2026-09-11). Every loose
  # Mach-O is signed first; nested bundles and the main executable are left to
  # --deep, which signs them as bundles with the right identifiers.
  find "$app" -type f ! -path "$main" \
       ! -path '*.framework/*' ! -path '*.appex/*' ! -path '*.xpc/*' -print0 \
    | xargs -0 file | awk -F': ' '$2 ~ /Mach-O/ {print $1}' \
    | tr '\n' '\0' | xargs -0 -n 50 codesign "${flags[@]}"
  codesign "${flags[@]}" --deep "$app"
  codesign --verify --deep --strict --verbose=2 "$app"
  echo "sign-macos: $(basename "$app") signed with Developer ID and the hardened runtime"
}

notarise_dmg() {
  local pkg="$1"
  if xcrun stapler validate "$pkg" >/dev/null 2>&1; then
    echo "sign-macos: $(basename "$pkg") already notarised and stapled - nothing to do"
    return 0
  fi

  codesign --force --timestamp --sign "$IDENTITY" "$pkg"

  echo "sign-macos: notarising $(basename "$pkg")"
  local out id
  out="$(xcrun notarytool submit "$pkg" \
    --key "$ASC_KEY_P8" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" \
    --wait --timeout 30m 2>&1)" || true
  printf '%s\n' "$out"
  id="$(printf '%s\n' "$out" | awk '/^ *id: /{print $2; exit}')"

  # notarytool exits 0 on a completed submission whatever the verdict, so the
  # status line is the only signal. On anything but Accepted the developer
  # log names every offending file and reason - print it, then fail.
  if ! printf '%s\n' "$out" | grep -qE '^ *status: Accepted'; then
    echo "sign-macos: notarisation of $(basename "$pkg") was NOT accepted; developer log:"
    [ -n "$id" ] && xcrun notarytool log "$id" \
      --key "$ASC_KEY_P8" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" || true
    return 1
  fi

  xcrun stapler staple "$pkg"
  xcrun stapler validate "$pkg"
  echo "sign-macos: $(basename "$pkg") is signed, notarised and stapled"
}

if [ -n "$ONE" ]; then
  case "$ONE" in
    *.app) sign_app "$ONE" ;;
    *.dmg) notarise_dmg "$ONE" ;;
    *) echo "sign-macos: do not know how to sign $ONE"; exit 1 ;;
  esac
else
  shopt -s nullglob
  for pkg in "$DIST"/*.dmg; do notarise_dmg "$pkg"; done
fi

echo "sign-macos: done"
