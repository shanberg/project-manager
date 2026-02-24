#!/usr/bin/env bash
# One-time: upload a release asset for an existing tag (e.g. after switching to deterministic tarballs).
# Usage: ./scripts/upload-release-asset.sh [tag]
#   tag   e.g. v0.1.6 (default: latest tag)
set -e

TAG="${1:-$(git tag -l 'v*' | sort -V | tail -1)}"
VERSION="${TAG#v}"
TOKEN="${GITHUB_TOKEN:-${HOMEBREW_GITHUB_API_TOKEN}}"
[[ -n "$TOKEN" ]] || { echo "Set GITHUB_TOKEN or HOMEBREW_GITHUB_API_TOKEN." >&2; exit 1; }

TARBALL="project-manager-${VERSION}.tar.gz"
echo "Building $TARBALL from $TAG..."
git archive --format=tar.gz --prefix="project-manager-${VERSION}/" "$TAG" -o "$TARBALL"

echo "Get or create release $TAG..."
RELEASE=$(curl -sL -H "Authorization: token $TOKEN" -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/shanberg/project-manager/releases/tags/$TAG")
if echo "$RELEASE" | grep -q '"message":"Not Found"'; then
  echo "Creating release $TAG..."
  RELEASE=$(curl -sL -X POST -H "Authorization: token $TOKEN" -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" -d "{\"tag_name\":\"$TAG\",\"name\":\"$TAG\"}" \
    "https://api.github.com/repos/shanberg/project-manager/releases")
fi
UPLOAD_URL=$(echo "$RELEASE" | node -e "
const d = JSON.parse(require('fs').readFileSync(0, 'utf8'));
const u = (d && d.upload_url) ? d.upload_url.replace(/\{.*\}/, '').trim() : '';
console.log(u);
")
[[ -n "$UPLOAD_URL" ]] || { echo "No upload_url in release response. Check token scope (repo)." >&2; rm -f "$TARBALL"; exit 1; }

echo "Uploading $TARBALL..."
curl -sL -X POST -H "Authorization: token $TOKEN" -H "Content-Type: application/gzip" \
  --data-binary "@$TARBALL" "${UPLOAD_URL}?name=${TARBALL}"
rm -f "$TARBALL"
echo "Done. Run: ./scripts/update-homebrew-formula.sh $TAG (if formula not yet updated)"
echo "sha256 from git archive: $(git archive --format=tar.gz --prefix="project-manager-${VERSION}/" "$TAG" | shasum -a 256 | awk '{print $1}')"
