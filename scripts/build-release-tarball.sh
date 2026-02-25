#!/usr/bin/env bash
# Build a self-contained tarball with dist/, node_modules (prod), package.json, templates.
# Used by release.sh so the Homebrew formula does not need to run npm install (no registry auth).
#
# Usage: ./scripts/build-release-tarball.sh <version>
#   version   e.g. 0.1.12
#
# Repo .npmrc has @shanberg:registry so public packages install without auth.
# Optional: GITHUB_TOKEN or HOMEBREW_GITHUB_API_TOKEN if the registry requires auth.
set -e

VERSION="${1:?Usage: $0 <version>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARBALL_NAME="project-manager-${VERSION}.tar.gz"
TARBALL_PATH="$ROOT/$TARBALL_NAME"

cd "$ROOT"

TMPDIR=""
cleanup() {
  [[ -n "$TMPDIR" && -d "$TMPDIR" ]] && rm -rf "$TMPDIR"
}
trap cleanup EXIT

# Use repo .npmrc (scope only). If token is set, use temp userconfig so npm ci can auth.
TOKEN="${GITHUB_TOKEN:-${HOMEBREW_GITHUB_API_TOKEN}}"
if [[ -n "$TOKEN" ]]; then
  NPMRC_RELEASE=$(mktemp)
  trap "rm -f '$NPMRC_RELEASE'; cleanup" EXIT
  echo "//npm.pkg.github.com/:_authToken=$TOKEN" > "$NPMRC_RELEASE"
  echo "@shanberg:registry=https://npm.pkg.github.com" >> "$NPMRC_RELEASE"
  NPM_CONFIG_USERCONFIG="$NPMRC_RELEASE"
  export NPM_CONFIG_USERCONFIG
fi

echo "==> npm ci"
npm ci

echo "==> npm run build"
npm run build

echo "==> Prune dev dependencies"
npm prune --omit=dev

echo "==> Create tarball $TARBALL_NAME"
rm -f "$TARBALL_PATH"
PREFIX="project-manager-${VERSION}"
TMPDIR=$(mktemp -d)
mkdir -p "$TMPDIR/$PREFIX"
cp -R dist node_modules package.json templates "$TMPDIR/$PREFIX/"
tar -czf "$TARBALL_PATH" -C "$TMPDIR" "$PREFIX"

echo "==> Restore node_modules for local dev"
npm ci

echo "==> Done. Tarball: $TARBALL_PATH"
echo "$TARBALL_PATH"
