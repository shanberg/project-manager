#!/usr/bin/env bash
# Replace /Applications/PM.app with a fresh build from this working tree and relaunch it.
#
# xcodebuild only writes the product into a build directory; the app the user actually sees is
# the one in /Applications. This does the swap.
#
# Usage: ./scripts/install-app-local.sh [--release] [--no-launch]
#   --release    build the Release configuration (default: Debug)
#   --no-launch  install but don't relaunch the app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/pm-mac/.build-dev"
CONFIG=Debug
LAUNCH=1
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

for arg in "$@"; do
  case "$arg" in
    --release)   CONFIG=Release ;;
    --no-launch) LAUNCH=0 ;;
    *) echo "Usage: $0 [--release] [--no-launch]" >&2; exit 1 ;;
  esac
done

# project.yml is the source of truth; XcodeGen writes the pbxproj from it.
if [[ "$ROOT/pm-mac/project.yml" -nt "$ROOT/pm-mac/PM.xcodeproj/project.pbxproj" ]]; then
  echo "==> project.yml changed, regenerating the Xcode project"
  (cd "$ROOT/pm-mac" && xcodegen generate)
fi

echo "==> Building PM.app ($CONFIG)"
# Fixed -derivedDataPath on purpose: picking the product out of ~/Library/.../DerivedData means
# guessing between several PM-* folders, and the freshest-looking one is not always this build.
xcodebuild -project "$ROOT/pm-mac/PM.xcodeproj" -scheme PM \
  -configuration "$CONFIG" -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" build >/dev/null

APP="$DERIVED/Build/Products/$CONFIG/PM.app"
[[ -d "$APP" ]] || { echo "Build succeeded but $APP is missing." >&2; exit 1; }

if pgrep -x PM >/dev/null; then
  echo "==> Quitting the running PM"
  osascript -e 'quit app "PM"' 2>/dev/null || killall PM 2>/dev/null || true
  for _ in $(seq 20); do
    pgrep -x PM >/dev/null || break
    sleep 0.25
  done
  pgrep -x PM >/dev/null && killall -9 PM 2>/dev/null || true
fi

echo "==> Replacing /Applications/PM.app"
rm -rf /Applications/PM.app
cp -R "$APP" /Applications/PM.app

# Keep exactly one registered copy of com.stuarthanberg.pm: a second bundle with the same id lets
# Siri and appintentsd bind to the stale one.
"$LSREG" -u "$APP" >/dev/null 2>&1 || true
"$LSREG" -f /Applications/PM.app >/dev/null 2>&1 || true

VERSION=$(defaults read /Applications/PM.app/Contents/Info CFBundleShortVersionString 2>/dev/null || echo "?")
echo "==> Installed PM.app $VERSION ($CONFIG)"

if [[ "$LAUNCH" == 1 ]]; then
  open /Applications/PM.app
  echo "==> Relaunched. Log: ~/.config/pm/pm-mac.log"
fi
