#!/usr/bin/env bash
# Build, sign (Developer ID), notarize, and staple PM.app, then zip it for distribution.
#
# This produces a Gatekeeper-approved artifact any consumer can open: the Release config
# signs with the Developer ID Application cert + hardened runtime (see pm-mac/project.yml),
# Apple's notary service inspects it, and `stapler` attaches the ticket so it validates offline.
#
# Usage: ./scripts/build-app-dist.sh <version> [notary-profile]
#   version         e.g. 0.8.0 (stamped as MARKETING_VERSION and into the zip name)
#   notary-profile  keychain profile from `xcrun notarytool store-credentials` (default: notary)
#
# Produces: dist/PM-v<version>.zip  (prints its path on the last line)
# Run on an Apple Silicon Mac with the Developer ID cert + notary profile in the keychain.
set -euo pipefail

VERSION="${1:?Usage: $0 <version> [notary-profile]}"
NOTARY_PROFILE="${2:-notary}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAC="$ROOT/pm-mac"
DIST="$ROOT/dist"
IDENTITY="Developer ID Application: Stuart Hanberg (9626CTDMM9)"

cd "$MAC"

# Regenerate the Xcode project from project.yml (files/settings may have changed).
if command -v xcodegen >/dev/null 2>&1; then
  echo "==> xcodegen generate"
  xcodegen generate >/dev/null
fi

DERIVED="$(mktemp -d)"
trap 'rm -rf "$DERIVED"' EXIT

echo "==> Building PM.app (Release, Developer ID, hardened runtime)"
xcodebuild \
  -project PM.xcodeproj \
  -scheme PM \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" \
  MARKETING_VERSION="$VERSION" \
  clean build >/dev/null

APP="$DERIVED/Build/Products/Release/PM.app"
[[ -d "$APP" ]] || { echo "Build did not produce $APP" >&2; exit 1; }

# `xcodebuild build` signs without a secure timestamp (only `archive` contacts Apple's timestamp
# server), but notarization rejects a timestamp-less signature. Re-sign explicitly to add one.
# The bundle is a single executable (PmLib is statically linked, no nested frameworks/dylibs), so
# one top-level sign covers it; add an inside-out pass here if embedded code is ever introduced.
echo "==> Re-signing with a secure timestamp (required for notarization)"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"

echo "==> Verifying signature + hardened runtime"
codesign --verify --deep --strict --verbose=2 "$APP"
# Capture into a var rather than piping into `grep -q`: under `set -o pipefail`, grep -q's early
# exit can SIGPIPE codesign (141) and flip this test into a false negative.
SIGN_INFO="$(codesign -dv --verbose=4 "$APP" 2>&1 || true)"
if ! grep -q "flags=.*runtime" <<<"$SIGN_INFO"; then
  echo "Hardened runtime flag missing on the signed app — notarization would fail." >&2
  exit 1
fi

mkdir -p "$DIST"
ZIP="$DIST/PM-v${VERSION}.zip"

# ditto --keepParent is the Apple-recommended way to zip a .app for notarization
# (preserves the bundle structure and symlinks that plain `zip` mangles).
echo "==> Zipping for notarization"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Submitting to Apple notary service (profile: $NOTARY_PROFILE) — this can take a few minutes"
# `notarytool submit --wait` exits 0 once processing finishes even when the verdict is Invalid,
# so inspect the status ourselves and dump the log before we'd otherwise staple a rejected build.
SUBMIT_OUT="$(xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)"
echo "$SUBMIT_OUT"
SUBMISSION_ID="$(grep -m1 '^  id:' <<<"$SUBMIT_OUT" | awk '{print $2}')"
if ! grep -q "status: Accepted" <<<"$SUBMIT_OUT"; then
  echo "Notarization was not Accepted. Fetching Apple's log:" >&2
  [[ -n "$SUBMISSION_ID" ]] && xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
  exit 1
fi

echo "==> Stapling notarization ticket to the app"
xcrun stapler staple "$APP"

echo "==> Re-zipping the stapled app for distribution"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Gatekeeper assessment (what a consumer's Mac will decide)"
spctl -a -vvv --type exec "$APP" || {
  echo "spctl rejected the app — investigate before shipping." >&2
  exit 1
}

echo "==> Done. Distributable: $ZIP"
echo "$ZIP"
