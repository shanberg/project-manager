#!/usr/bin/env bash
# A throwaway PARA vault for manual testing, so poking at the app or the CLI never
# creates projects in ~/Documents/PARA. Everything lives under one directory that is
# safe to delete; `reset` deletes and recreates it.
#
# Usage:
#   ./scripts/dev-vault.sh app        Build PM.app and launch it against the dev vault
#   ./scripts/dev-vault.sh pm <args>  Run the pm CLI against the dev vault
#   ./scripts/dev-vault.sh shell      Open a shell with PM_CONFIG_HOME already exported
#   ./scripts/dev-vault.sh reset      Wipe the vault back to empty
#   ./scripts/dev-vault.sh path       Print the vault directory
#
# The dev vault is keyed off PM_CONFIG_HOME, which PmLib's getConfigDir() honours, so the
# app, the CLI and the MCP server all follow it without any code knowing this is a test run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VAULT="${PM_DEV_VAULT:-$ROOT/.dev-vault}"
CONFIG_HOME="$VAULT/config"
PARA="$VAULT/PARA"

create_vault() {
  mkdir -p "$CONFIG_HOME" "$PARA/Projects" "$PARA/Archive" "$PARA/Areas"
  cat > "$CONFIG_HOME/config.json" <<JSON
{
  "activePath" : "$PARA/Projects",
  "archivePath" : "$PARA/Archive",
  "areasPath" : "$PARA/Areas",
  "paraPath" : "$PARA",
  "domains" : {
    "W" : "Work",
    "P" : "Personal",
    "L" : "Learning",
    "O" : "Other"
  },
  "subfolders" : [
    "deliverables",
    "docs",
    "resources",
    "previews",
    "working files"
  ]
}
JSON
}

# Never let a stray PM_DEV_VAULT point `reset` at something real.
guard_vault() {
  case "$VAULT" in
    "$HOME"|"$HOME"/|/|"$HOME/Documents"*)
      echo "Refusing to operate on '$VAULT' — set PM_DEV_VAULT to a scratch directory." >&2
      exit 1
      ;;
  esac
}

guard_vault
[[ -f "$CONFIG_HOME/config.json" ]] || create_vault
export PM_CONFIG_HOME="$CONFIG_HOME"

cmd="${1:-app}"
shift || true

case "$cmd" in
  path)
    echo "$VAULT"
    ;;
  reset)
    rm -rf "$VAULT"
    create_vault
    echo "Dev vault reset: $PARA"
    ;;
  pm)
    PM="$ROOT/pm-swift/.build/debug/pm"
    [[ -x "$PM" ]] || { echo "Build it first: (cd pm-swift && swift build)" >&2; exit 1; }
    exec "$PM" "$@"
    ;;
  shell)
    echo "PM_CONFIG_HOME=$CONFIG_HOME  (vault: $PARA)"
    exec "${SHELL:-/bin/zsh}"
    ;;
  app)
    DERIVED="$ROOT/pm-mac/.build-dev"
    echo "==> Building PM.app (Debug)"
    xcodebuild -project "$ROOT/pm-mac/PM.xcodeproj" -scheme PM \
      -configuration Debug -destination 'platform=macOS,arch=arm64' \
      -derivedDataPath "$DERIVED" build >/dev/null
    APP="$DERIVED/Build/Products/Debug/PM.app"
    # Launch the executable directly rather than via `open`, so PM_CONFIG_HOME is inherited.
    echo "==> Launching against dev vault: $PARA"
    exec "$APP/Contents/MacOS/PM"
    ;;
  *)
    echo "Usage: $0 {app|pm <args>|shell|reset|path}" >&2
    exit 1
    ;;
esac
