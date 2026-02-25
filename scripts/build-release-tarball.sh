#!/usr/bin/env bash
# Build a self-contained tarball with dist/, node_modules (prod), package.json, templates.
# Used by release.sh so the Homebrew formula does not need to run npm install (no registry auth).
#
# Usage: ./scripts/build-release-tarball.sh <version>
#   version   e.g. 0.1.12
#
# Env:   GITHUB_TOKEN or HOMEBREW_GITHUB_API_TOKEN  for npm ci to fetch @shanberg/project-schema
set -e

VERSION="${1:?Usage: $0 <version>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARBALL_NAME="project-manager-${VERSION}.tar.gz"
TARBALL_PATH="$ROOT/$TARBALL_NAME"

cd "$ROOT"

TOKEN="${GITHUB_TOKEN:-${HOMEBREW_GITHUB_API_TOKEN}}"
if [[ -z "$TOKEN" ]]; then
  echo "Set GITHUB_TOKEN or HOMEBREW_GITHUB_API_TOKEN so npm ci can fetch @shanberg/project-schema." >&2
  exit 1
fi

# Temporary .npmrc for this run only; TMPDIR created later
NPMRC="$ROOT/.npmrc"
TMPDIR=""
cleanup() {
  rm -f "$NPMRC"
  [[ -n "$TMPDIR" && -d "$TMPDIR" ]] && rm -rf "$TMPDIR"
}
trap cleanup EXIT

echo "//npm.pkg.github.com/:_authToken=$TOKEN" > "$NPMRC"
echo "@shanberg:registry=https://npm.pkg.github.com" >> "$NPMRC"

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
