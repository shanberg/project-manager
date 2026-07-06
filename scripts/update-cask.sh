#!/usr/bin/env bash
# Update homebrew-s Casks/pm.rb with a new version + sha256 for the notarized PM.app zip.
# Companion to update-homebrew-formula.sh (which updates the CLI formula).
#
# Usage: ./scripts/update-cask.sh <version> [sha256]
#   version  e.g. 0.8.0
#   sha256   optional; if omitted, uses dist/PM-v<version>.zip when present, otherwise downloads
#            the release asset PM-v<version>.zip and computes it.
#
# Env:   TAP_DIR  path to homebrew-s repo (default: ../homebrew-s)
#        GITHUB_TOKEN / HOMEBREW_GITHUB_API_TOKEN  (only needed for the download fallback)
set -euo pipefail

VERSION="${1:?Usage: $0 <version> [sha256]}"
SHA256="${2:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAP_DIR="${TAP_DIR:-${ROOT}/../homebrew-s}"
REPO="shanberg/project-manager"
CASK="${TAP_DIR}/Casks/pm.rb"

[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "Invalid version: $VERSION" >&2; exit 1; }
[[ -f "$CASK" ]] || { echo "Cask not found at $CASK (set TAP_DIR)." >&2; exit 1; }

if [[ -z "$SHA256" ]]; then
  LOCAL="$ROOT/dist/PM-v${VERSION}.zip"
  if [[ -f "$LOCAL" ]]; then
    SHA256="$(shasum -a 256 "$LOCAL" | awk '{print $1}')"
  else
    TOKEN="${GITHUB_TOKEN:-${HOMEBREW_GITHUB_API_TOKEN:-}}"
    if [[ -z "$TOKEN" ]] && command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
      TOKEN="$(gh auth token)"
    fi
    [[ -n "$TOKEN" ]] || { echo "Pass sha256 as arg 2, or provide a token to download the asset." >&2; exit 1; }
    TAG="v${VERSION}"; ASSET="PM-v${VERSION}.zip"
    REL=$(curl -sL -H "Authorization: token $TOKEN" -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/${REPO}/releases/tags/${TAG}")
    AID=$(echo "$REL" | node -e "const d=JSON.parse(require('fs').readFileSync(0,'utf8'));const a=d.assets&&d.assets.find(x=>x.name===process.argv[1]);console.log(a?a.id:'')" "$ASSET")
    [[ -n "$AID" ]] || { echo "Asset $ASSET not found in release $TAG." >&2; exit 1; }
    curl -sL -H "Authorization: token $TOKEN" -H "Accept: application/octet-stream" \
      "https://api.github.com/repos/${REPO}/releases/assets/${AID}" -o /tmp/pm-app.zip
    SHA256="$(shasum -a 256 /tmp/pm-app.zip | awk '{print $1}')"
    rm -f /tmp/pm-app.zip
  fi
fi

echo "version=$VERSION sha256=$SHA256"
# Anchored replacements so we only touch the version/sha256 stanzas.
perl -i -pe 's/^(  version ")[^"]+(")/${1}'"$VERSION"'${2}/' "$CASK"
perl -i -pe 's/^(  sha256 ")[a-f0-9]{64}(")/${1}'"$SHA256"'${2}/' "$CASK"

ruby -c "$CASK" >/dev/null
echo "Updated $CASK → version $VERSION, sha256 $SHA256"
