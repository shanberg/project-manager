#!/bin/zsh
# Build the harness and launch it as an app bundle (WebKit storage and keyboard focus want a bundle).
set -euo pipefail
cd "${0:A:h}"
swift build -c debug 2>&1 | grep -E "error|Build complete" || true
APP=build/WebAttentionHarness.app
mkdir -p "$APP/Contents/MacOS"
cp .build/debug/Harness "$APP/Contents/MacOS/WebAttentionHarness"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.stuarthanberg.web-attention-harness</string>
  <key>CFBundleName</key><string>Web Attention Harness</string>
  <key>CFBundleExecutable</key><string>WebAttentionHarness</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1
if [[ "${1:-}" == "--selftest" ]]; then
  HARNESS_SELFTEST="$2" "$APP/Contents/MacOS/WebAttentionHarness"
else
  # `open` drops the environment, so a logged session launches the binary directly.
  if [[ "${HARNESS_LOG_FILE:-}" == "1" ]]; then "$APP/Contents/MacOS/WebAttentionHarness" & else open "$APP"; fi
fi
