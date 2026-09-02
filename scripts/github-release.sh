#!/usr/bin/env bash
# Create or update the GitHub Release for a tag on the Public Mirror and
# upload assets. Run by CI only (meta/AGENTS.md: CI publishes, humans
# promote); a workstation has no GITHUB_RELEASES_TOKEN.
#
#   scripts/github-release.sh prerelease <tag> <file...>
#       publish:staging-prerelease - find or create the tag's release,
#       marked pre-release, and attach the staging Environment build.
#   scripts/github-release.sh promote <tag> <file...>
#       promote - the SAME release (one tag = one release on GitHub) gains
#       the production assets and its pre-release flag is cleared. Until
#       promote runs, the release stays a pre-release, which is exactly the
#       channels table: staging = pre-release, production = Release.
#
# Uploads are idempotent: an asset with the same name is deleted first, so a
# retried job never fails on "already_exists".
#
# Needs: GITHUB_RELEASES_TOKEN - a fine-grained token on the
# aity-cloud/drive-desktop mirror with the "Contents" repository permission
# set to read-write (GitHub serves releases under the contents permission;
# there is no narrower one). Plus curl and jq.
set -euo pipefail

MODE="${1:?usage: $0 prerelease|promote <tag> <file...>}"
TAG="${2:?usage: $0 prerelease|promote <tag> <file...>}"
shift 2
[ $# -gt 0 ] || { echo "github-release: no files to upload" >&2; exit 2; }
[ -n "${GITHUB_RELEASES_TOKEN:-}" ] || { echo "github-release: GITHUB_RELEASES_TOKEN is not set" >&2; exit 2; }

REPO="${GITHUB_RELEASE_REPO:-aity-cloud/drive-desktop}"
API="https://api.github.com/repos/$REPO"

api() {
    curl -sS -H "Authorization: Bearer $GITHUB_RELEASES_TOKEN" \
         -H "Accept: application/vnd.github+json" \
         -H "X-GitHub-Api-Version: 2022-11-28" "$@"
}

case "$MODE" in
    prerelease)
        NAME="$TAG (staging pre-release)"
        BODY="Staging Environment build for verification before promote. Server: https://drive.aity.works"
        ;;
    promote)
        NAME="$TAG"
        BODY="Aity Drive desktop client $TAG. The staging assets (aity-drive-staging-*) target https://drive.aity.works and exist for verification; install the aity-drive-* assets. Complete corresponding source is attached (ADR 0004)."
        ;;
    *) echo "github-release: unknown mode '$MODE'" >&2; exit 2 ;;
esac

# One release per tag: find it, else create it. The tag itself is pushed by
# mirror:github before this stage runs, so no target_commitish is needed.
RELEASE=$(api "$API/releases/tags/$TAG" || true)
RELEASE_ID=$(echo "$RELEASE" | jq -r '.id // empty')
if [ -z "$RELEASE_ID" ]; then
    RELEASE=$(api -X POST "$API/releases" -d "$(jq -n \
        --arg tag "$TAG" --arg name "$NAME" --arg body "$BODY" \
        --argjson pre "$([ "$MODE" = prerelease ] && echo true || echo false)" \
        '{tag_name: $tag, name: $name, body: $body, prerelease: $pre}')")
    RELEASE_ID=$(echo "$RELEASE" | jq -r '.id // empty')
    [ -n "$RELEASE_ID" ] || { echo "github-release: creating the release failed: $RELEASE" >&2; exit 1; }
    echo "github-release: created release $RELEASE_ID for $TAG ($MODE)"
elif [ "$MODE" = promote ]; then
    api -X PATCH "$API/releases/$RELEASE_ID" -d "$(jq -n \
        --arg name "$NAME" --arg body "$BODY" \
        '{name: $name, body: $body, prerelease: false}')" >/dev/null
    echo "github-release: release $RELEASE_ID promoted (pre-release flag cleared)"
else
    echo "github-release: reusing existing release $RELEASE_ID for $TAG"
fi

UPLOAD_URL=$(echo "$RELEASE" | jq -r '.upload_url' | sed 's/{.*}//')
[ -n "$UPLOAD_URL" ] && [ "$UPLOAD_URL" != null ] \
    || UPLOAD_URL="https://uploads.github.com/repos/$REPO/releases/$RELEASE_ID/assets"

ASSETS=$(api "$API/releases/$RELEASE_ID/assets?per_page=100")
for f in "$@"; do
    [ -f "$f" ] || { echo "github-release: no such file: $f" >&2; exit 1; }
    name=$(basename "$f")
    existing=$(echo "$ASSETS" | jq -r --arg n "$name" '.[] | select(.name == $n) | .id')
    if [ -n "$existing" ]; then
        api -X DELETE "$API/releases/assets/$existing" >/dev/null
        echo "github-release: replaced existing asset $name"
    fi
    curl -sSf -H "Authorization: Bearer $GITHUB_RELEASES_TOKEN" \
         -H "Content-Type: application/octet-stream" \
         --data-binary @"$f" "$UPLOAD_URL?name=$name" >/dev/null
    echo "github-release: uploaded $name"
done

echo "github-release: $MODE of $TAG complete ($(($#)) asset(s))"
