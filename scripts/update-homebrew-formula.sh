#!/usr/bin/env bash
# Update homebrew-s Formula/project-manager.rb with a new version's url ref, version, and sha256.
# Run from project-manager repo. Uses GITHUB_TOKEN or HOMEBREW_GITHUB_API_TOKEN to download the tarball.
#
# Usage: ./scripts/update-homebrew-formula.sh [tag]
#   tag   e.g. v0.1.2 (default: read version from package.json, prefix with v)
#
# Env:   TAP_DIR  path to homebrew-s repo (default: ../homebrew-s)
set -e

REPO="shanberg/project-manager"
TAG="${1:-}"
TAP_DIR="${TAP_DIR:-$(cd "$(dirname "$0")/../.." && pwd)/homebrew-s}"

if [[ -z "$TAG" ]]; then
  VERSION=$(node -p "require('./package.json').version")
  TAG="v${VERSION}"
fi

VERSION="${TAG#v}"
TOKEN="${GITHUB_TOKEN:-${HOMEBREW_GITHUB_API_TOKEN}}"
if [[ -z "$TOKEN" ]]; then
  echo "Set GITHUB_TOKEN or HOMEBREW_GITHUB_API_TOKEN to download the private tarball." >&2
  exit 1
fi

echo "Downloading $REPO tarball $TAG..."
curl -sL -H "Authorization: token $TOKEN" \
  "https://api.github.com/repos/${REPO}/tarball/${TAG}" -o /tmp/pm-tarball.tar.gz

SHA256=$(shasum -a 256 /tmp/pm-tarball.tar.gz | awk '{print $1}')
rm -f /tmp/pm-tarball.tar.gz
echo "sha256=$SHA256"

FORMULA="${TAP_DIR}/Formula/project-manager.rb"
if [[ ! -f "$FORMULA" ]]; then
  echo "Formula not found at $FORMULA. Set TAP_DIR if homebrew-s is elsewhere." >&2
  exit 1
fi

# Update url ref, sha256, and version (portable: perl -i works on macOS and Linux)
perl -i -pe "s|refs/tags/v[0-9.]+\\.tar\\.gz|refs/tags/${TAG}.tar.gz|" "$FORMULA"
perl -i -pe 's/sha256 "\K[a-f0-9]+/'"$SHA256"'/' "$FORMULA"
perl -i -pe 's/(version ")[\d.]+/$1'"$VERSION"'/' "$FORMULA"

echo "Updated $FORMULA → version $VERSION, sha256 $SHA256"
