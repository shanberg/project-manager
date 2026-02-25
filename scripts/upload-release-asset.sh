#!/usr/bin/env bash
# One-time: upload a release asset for an existing tag (builds bundled tarball and uploads).
# Usage: ./scripts/upload-release-asset.sh [tag]
#   tag   e.g. v0.1.6 (default: latest tag)
set -e

TAG="${1:-$(git tag -l 'v*' | sort -V | tail -1)}"
VERSION="${TAG#v}"
TOKEN="${GITHUB_TOKEN:-${HOMEBREW_GITHUB_API_TOKEN}}"
[[ -n "$TOKEN" ]] || { echo "Set GITHUB_TOKEN or HOMEBREW_GITHUB_API_TOKEN." >&2; exit 1; }

echo "Building bundled tarball for $TAG..."
TARBALL=$(./scripts/build-release-tarball.sh "$VERSION" | tail -1)
[[ -f "$TARBALL" ]] || { echo "Build failed." >&2; exit 1; }

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

TARBALL_NAME="project-manager-${VERSION}.tar.gz"
echo "Uploading $TARBALL_NAME..."
curl -sL -X POST -H "Authorization: token $TOKEN" -H "Content-Type: application/gzip" \
  --data-binary "@$TARBALL" "${UPLOAD_URL}?name=${TARBALL_NAME}"
rm -f "$TARBALL"
echo "Done. Run: ./scripts/update-homebrew-formula.sh $TAG (if formula not yet updated)"
