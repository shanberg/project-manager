#!/usr/bin/env bash
# Bump version, push, tag, update Homebrew formula, push tap.
# Requires: GITHUB_TOKEN or HOMEBREW_GITHUB_API_TOKEN (for formula tarball), and git push access to both repos.
#
# Usage: ./scripts/release.sh <version | bump>
#   version   literal version, e.g. 0.2.0
#   bump      patch (bug fixes), minor (new features), major (breaking changes)
#
# Env:   TAP_DIR  path to homebrew-s repo (default: ../homebrew-s)
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAP_DIR="${TAP_DIR:-${ROOT}/../homebrew-s}"
ARG="${1:?Usage: $0 <patch|minor|major|version>}"

cd "$ROOT"

# package.json must have a "version" field; the script updates it as part of the release
CURRENT=$(node -p "require('./package.json').version" 2>/dev/null || true)
if [[ -z "$CURRENT" || "$CURRENT" == "undefined" ]]; then
  echo "package.json is missing a \"version\" field. Add one (e.g. \"0.1.0\") and run again." >&2
  exit 1
fi

# Resolve VERSION: if arg is patch/minor/major, bump current; else use arg as version
if [[ "$ARG" == patch || "$ARG" == minor || "$ARG" == major ]]; then
  VERSION=$(node -e "
    const bump = process.env.BUMP;
    const v = require('./package.json').version;
    const [major, minor, patch] = v.split('.').map(Number);
    if (bump === 'major') console.log((major + 1) + '.0.0');
    else if (bump === 'minor') console.log(major + '.' + (minor + 1) + '.0');
    else console.log(major + '.' + minor + '.' + (patch + 1));
  " BUMP="$ARG")
  echo "==> Bump $ARG: $CURRENT → $VERSION"
else
  VERSION="$ARG"
fi

TAG="v${VERSION}"

echo "==> Set package.json to $VERSION"
node -e "
const p = require('./package.json');
p.version = process.env.VERSION;
require('fs').writeFileSync('package.json', JSON.stringify(p, null, 2) + '\n');
" VERSION="$VERSION"
# Verify the write stuck (catches overwrites or bad cwd)
[[ "$(node -p "require('./package.json').version")" == "$VERSION" ]] || {
  echo "package.json version is missing or wrong after write. Check for tools that rewrite package.json." >&2
  exit 1
}

echo "==> Commit and push"
git add package.json
git commit -m "Release $TAG"
git push

echo "==> Tag and push $TAG"
git tag "$TAG"
git push origin "$TAG"

echo "==> Update Homebrew formula"
"$ROOT/scripts/update-homebrew-formula.sh" "$TAG"

echo "==> Commit and push tap"
cd "$TAP_DIR"
git add Formula/project-manager.rb
git diff --staged --quiet || git commit -m "project-manager $VERSION"
git push

echo "==> Done. Release $TAG is out; tap updated."
