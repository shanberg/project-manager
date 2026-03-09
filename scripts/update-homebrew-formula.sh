#!/usr/bin/env bash
# Update homebrew-s Formula/project-manager.rb with a new version's release-asset url, version, and sha256.
# Uses the release asset (bundled tarball) uploaded at release.
# Run from project-manager repo. Uses GITHUB_TOKEN or HOMEBREW_GITHUB_API_TOKEN.
#
# Usage: ./scripts/update-homebrew-formula.sh [tag]
#   tag   e.g. v0.1.6 (default: read version from package.json, prefix with v)
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
# Ensure version is safe for the formula (semver-like: digits and dots only)
if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
  echo "Invalid version for formula: $VERSION (expected e.g. 0.1.2)" >&2
  exit 1
fi

TOKEN="${GITHUB_TOKEN:-${HOMEBREW_GITHUB_API_TOKEN}}"
if [[ -z "$TOKEN" ]]; then
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    TOKEN=$(gh auth token)
  fi
fi
if [[ -z "$TOKEN" ]]; then
  echo "Set GITHUB_TOKEN or HOMEBREW_GITHUB_API_TOKEN, or run \`gh auth login\`." >&2
  exit 1
fi

# Download release asset via API (bundled tarball uploaded at release)
ASSET_NAME="project-manager-${VERSION}.tar.gz"
echo "Fetching release $TAG asset $ASSET_NAME..."
RELEASE_JSON=$(curl -sL -H "Authorization: token $TOKEN" -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${REPO}/releases/tags/${TAG}")
# Find asset id by name
ASSET_ID=$(echo "$RELEASE_JSON" | node -e "
const d = JSON.parse(require('fs').readFileSync(0, 'utf8'));
const a = d.assets && d.assets.find(x => x.name === process.argv[1]);
console.log(a ? a.id : '');
" "$ASSET_NAME")
if [[ -z "$ASSET_ID" ]]; then
  echo "Asset $ASSET_NAME not found in release $TAG. Upload it first." >&2
  exit 1
fi

curl -sL -H "Authorization: token $TOKEN" -H "Accept: application/octet-stream" \
  "https://api.github.com/repos/${REPO}/releases/assets/${ASSET_ID}" -o /tmp/pm-tarball.tar.gz

SHA256=$(shasum -a 256 /tmp/pm-tarball.tar.gz | awk '{print $1}')
rm -f /tmp/pm-tarball.tar.gz
echo "sha256=$SHA256"

FORMULA="${TAP_DIR}/Formula/project-manager.rb"
if [[ ! -f "$FORMULA" ]]; then
  echo "Formula not found at $FORMULA. Set TAP_DIR if homebrew-s is elsewhere." >&2
  exit 1
fi

# Update release-asset url, sha256, and version (anchored regexes)
perl -i -pe "s|releases/download/v[0-9.]+/project-manager-[0-9.]+\\.tar\\.gz|releases/download/${TAG}/project-manager-${VERSION}.tar.gz|" "$FORMULA"
perl -i -pe 's/^(  sha256 ")\K[a-f0-9]{64}/'"$SHA256"'/' "$FORMULA"
perl -i -pe 's/^(  version ")[\d.]+(")$/${1}'"$VERSION"'${2}/' "$FORMULA"

# Verify formula syntax
ruby_err="$(ruby -c "$FORMULA" 2>&1)" || {
  echo "Formula syntax error after update:" >&2
  echo "$ruby_err" >&2
  exit 1
}

echo "Updated $FORMULA → version $VERSION, sha256 $SHA256"
