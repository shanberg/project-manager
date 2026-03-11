#!/usr/bin/env bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PM_SWIFT="$REPO_ROOT/pm-swift"

cd "$PM_SWIFT"
echo "Building pm (debug)..."
swift build

if command -v fswatch &>/dev/null; then
  echo "Watching pm-swift for changes (fswatch). Ctrl+C to stop."
  fswatch -o "$PM_SWIFT/Sources" "$PM_SWIFT/Package.swift" | while read -r; do
    echo "Change detected, rebuilding..."
    (cd "$PM_SWIFT" && swift build) || true
  done
else
  echo "Watching pm-swift for changes (polling every 2s). Install fswatch (brew install fswatch) for instant rebuilds. Ctrl+C to stop."
  while true; do
    sleep 2
    # Only rebuild if Sources or Package.swift changed (compare mtime of build product vs sources)
    BIN="$PM_SWIFT/.build/debug/pm"
    NEWER=$(find "$PM_SWIFT/Sources" "$PM_SWIFT/Package.swift" -newer "$BIN" 2>/dev/null | head -1)
    if [[ -n "$NEWER" ]]; then
      echo "Change detected, rebuilding..."
      (cd "$PM_SWIFT" && swift build) || true
    fi
  done
fi
