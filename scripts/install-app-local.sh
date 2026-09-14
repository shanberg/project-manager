#!/usr/bin/env bash
# Replace /Applications/Folio.app with a fresh build from this working tree and relaunch it.
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

echo "==> Building Folio.app ($CONFIG)"
# Fixed -derivedDataPath on purpose: picking the product out of ~/Library/.../DerivedData means
# guessing between several PM-* folders, and the freshest-looking one is not always this build.
xcodebuild -project "$ROOT/pm-mac/PM.xcodeproj" -scheme PM \
  -configuration "$CONFIG" -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" build >/dev/null

APP="$DERIVED/Build/Products/$CONFIG/Folio.app"
[[ -d "$APP" ]] || { echo "Build succeeded but $APP is missing." >&2; exit 1; }

# The app was PM until it became Folio, and the running copy may still be the old one. Both
# executables are asked by name, and the old name goes on being asked until nobody has a PM.app.
for NAME in Folio PM; do
  pgrep -x "$NAME" >/dev/null || continue
  echo "==> Quitting the running $NAME"
  osascript -e "quit app \"$NAME\"" 2>/dev/null || killall "$NAME" 2>/dev/null || true
  for _ in $(seq 20); do
    pgrep -x "$NAME" >/dev/null || break
    sleep 0.25
  done
  pgrep -x "$NAME" >/dev/null && killall -9 "$NAME" 2>/dev/null || true
done

# A PM.app left beside Folio.app is a second bundle claiming com.stuarthanberg.pm, which is what
# sends Siri and appintentsd to the stale copy — so it goes, rather than being left to be found.
if [[ -d /Applications/PM.app ]]; then
  echo "==> Removing /Applications/PM.app (the app before it was renamed Folio)"
  "$LSREG" -u /Applications/PM.app >/dev/null 2>&1 || true
  rm -rf /Applications/PM.app
fi

echo "==> Replacing /Applications/Folio.app"
rm -rf /Applications/Folio.app
cp -R "$APP" /Applications/Folio.app

# Keep exactly one registered copy of com.stuarthanberg.pm: a second bundle with the same id lets
# Siri and appintentsd bind to the stale one.
"$LSREG" -u "$APP" >/dev/null 2>&1 || true
"$LSREG" -f /Applications/Folio.app >/dev/null 2>&1 || true

VERSION=$(defaults read /Applications/Folio.app/Contents/Info CFBundleShortVersionString 2>/dev/null || echo "?")
echo "==> Installed Folio.app $VERSION ($CONFIG)"

if [[ "$LAUNCH" == 1 ]]; then
  open /Applications/Folio.app
  echo "==> Relaunched. Log: ~/.config/pm/pm-mac.log"
fi
