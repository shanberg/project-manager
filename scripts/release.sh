#!/usr/bin/env bash
# Bump version, push, tag, update Homebrew formula, push tap.
# Requires: GitHub token for release upload and formula tarball — use one of:
#   gh auth login   (then this script uses `gh auth token`)
#   export GITHUB_TOKEN=... or HOMEBREW_GITHUB_API_TOKEN=...
#
# Usage: ./scripts/release.sh <version | bump>
#   version   literal version, e.g. 0.2.0
#   bump      patch (bug fixes), minor (new features), major (breaking changes)
#
# Env:   TAP_DIR  path to homebrew-s repo (default: ../homebrew-s)
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE_JSON="$ROOT/package.json"
TAP_DIR="${TAP_DIR:-${ROOT}/../homebrew-s}"
# Allow "npm run release -- patch" (npm passes -- as $1)
if [[ "$1" == "--" && -n "${2:-}" ]]; then shift; fi
ARG="${1:?Usage: $0 <patch|minor|major|version>}"

cd "$ROOT"

# package.json must have a "version" field; the script updates it as part of the release
CURRENT=$(PACKAGE_JSON="$PACKAGE_JSON" node -p "require(process.env.PACKAGE_JSON).version" 2>/dev/null || true)
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
const fs = require('fs');
const pj = process.argv[1];
const version = process.argv[2];
if (!pj || !version) throw new Error('usage: node script package.json.path version');
const tmp = pj + '.release_tmp';
const p = JSON.parse(fs.readFileSync(pj, 'utf8'));
p.version = version;
const out = JSON.stringify(p, null, 2) + '\n';
fs.writeFileSync(tmp, out);
fs.renameSync(tmp, pj);
const readBack = JSON.parse(fs.readFileSync(pj, 'utf8'));
if (readBack.version !== version) {
  process.stderr.write('package.json version missing or wrong after write (got \"' + readBack.version + '\"). Close package.json in your editor and run again.\n');
  process.exit(1);
}
" "$PACKAGE_JSON" "$VERSION"

# Verify again right before commit (editor may have overwritten after our write)
ON_DISK=$(node -p "require(process.argv[1]).version" "$PACKAGE_JSON" 2>/dev/null || true)
if [[ "$ON_DISK" != "$VERSION" ]]; then
  echo "package.json was changed before commit (on disk: \"$ON_DISK\", expected: \"$VERSION\"). Close package.json in your editor and run again." >&2
  exit 1
fi

echo "==> Commit and push"
git add package.json
git commit -m "Release $TAG"
git push

echo "==> Tag and push $TAG"
git tag "$TAG"
git push origin "$TAG"

# Build deterministic tarball and upload as release asset (same sha256 everywhere)
echo "==> Create release asset (deterministic tarball)"
TARBALL="project-manager-${VERSION}.tar.gz"
git archive --format=tar.gz --prefix="project-manager-${VERSION}/" "$TAG" -o "$TARBALL"
RELEASE_TOKEN="${GITHUB_TOKEN:-${HOMEBREW_GITHUB_API_TOKEN}}"
if [[ -z "$RELEASE_TOKEN" ]] && command -v gh >/dev/null 2>&1; then
  RELEASE_TOKEN=$(gh auth token 2>/dev/null) || true
fi
if [[ -z "$RELEASE_TOKEN" ]]; then
  echo "Need a GitHub token: run \`gh auth login\` or set GITHUB_TOKEN / HOMEBREW_GITHUB_API_TOKEN." >&2
  rm -f "$TARBALL"
  exit 1
fi
# Get or create release
RELEASE=$(curl -sL -H "Authorization: token $RELEASE_TOKEN" -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/shanberg/project-manager/releases/tags/$TAG")
if echo "$RELEASE" | grep -q '"message":"Not Found"'; then
  RELEASE=$(curl -sL -X POST -H "Authorization: token $RELEASE_TOKEN" -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    -d "{\"tag_name\":\"$TAG\",\"name\":\"$TAG\"}" \
    "https://api.github.com/repos/shanberg/project-manager/releases")
fi
UPLOAD_URL=$(echo "$RELEASE" | node -e "const d=JSON.parse(require('fs').readFileSync(0,'utf8')); console.log((d.upload_url || '').replace(/\{.*\}/,'').trim());" 2>/dev/null)
if [[ -z "$UPLOAD_URL" ]]; then
  echo "Could not get release upload_url. Check token and repo." >&2
  echo "API response (first 400 chars): $(echo "$RELEASE" | head -c 400)" >&2
  rm -f "$TARBALL"
  exit 1
fi
curl -sL -X POST -H "Authorization: token $RELEASE_TOKEN" -H "Content-Type: application/gzip" \
  --data-binary "@$TARBALL" "${UPLOAD_URL}?name=${TARBALL}"
rm -f "$TARBALL"

echo "==> Update Homebrew formula"
"$ROOT/scripts/update-homebrew-formula.sh" "$TAG"

echo "==> Commit and push tap"
cd "$TAP_DIR"
git add Formula/project-manager.rb
git diff --staged --quiet || git commit -m "project-manager $VERSION"
git push

echo "==> Done. Release $TAG is out; tap updated."
