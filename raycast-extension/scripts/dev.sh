#!/usr/bin/env bash
# Launch `ray develop` against Raycast, preferring Raycast 2 Beta when it is
# installed and falling back to the release app otherwise.
#
# Two things must agree for the extension to open in the intended app:
#   1. RAY_Target — tells the @raycast/api CLI which flavor to build for
#      ("x" = Beta / com.raycast-x.macos; unset = release / com.raycast.macos).
#   2. The default handler for the `raycast://` URL scheme — `ray develop`
#      opens the extension via a deep-link, which macOS routes by scheme owner.
# This script picks the target and pins the scheme handler to match.
set -euo pipefail

BETA_APP="/Applications/Raycast Beta.app"
RELEASE_APP="/Applications/Raycast.app"

if [ -d "$BETA_APP" ]; then
  APP_NAME="Raycast Beta"
  BUNDLE="com.raycast-x.macos"
  export RAY_Target="x"
elif [ -d "$RELEASE_APP" ]; then
  APP_NAME="Raycast (release)"
  BUNDLE="com.raycast.macos"
  # release is the empty flavor — make sure a stray RAY_Target doesn't leak in
  unset RAY_Target
else
  echo "error: no Raycast app found in /Applications" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/raycast-scheme.swift"
CACHE_DIR="$SCRIPT_DIR/.cache"
TOOL="$CACHE_DIR/raycast-scheme"

# Compile the scheme helper on first use (or when its source changes).
mkdir -p "$CACHE_DIR"
if [ ! -x "$TOOL" ] || [ "$SRC" -nt "$TOOL" ]; then
  swiftc -O -suppress-warnings "$SRC" -o "$TOOL"
fi

# Point the raycast:// scheme at the chosen app only if it isn't already.
CURRENT="$("$TOOL")"
if [ "$CURRENT" != "$BUNDLE" ]; then
  "$TOOL" "$BUNDLE" >/dev/null
  echo "→ set raycast:// handler to $APP_NAME ($BUNDLE)"
fi

echo "→ developing against $APP_NAME"
exec ray develop
