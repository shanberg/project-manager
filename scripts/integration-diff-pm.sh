#!/usr/bin/env bash
# Smoke test: run key pm (Swift) commands with existing config. No Node.
# Usage: ./scripts/integration-diff-pm.sh
# Requires: pm-swift/.build/release/pm exists
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PM_CONFIG_HOME="${PM_CONFIG_HOME:-$HOME/.config/pm}"
PM="./pm-swift/.build/release/pm"

if [[ ! -x "$ROOT/pm-swift/.build/release/pm" ]]; then
  echo "Build Swift pm first: cd pm-swift && swift build -c release" >&2
  exit 1
fi

run_ok() {
  local name="$1"
  shift
  if $PM "$@" >/dev/null 2>&1; then
    echo "OK   $name"
  else
    echo "FAIL $name"
    $PM "$@" 2>&1 || true
    exit 1
  fi
}

echo "Smoke testing Swift pm (config: $PM_CONFIG_HOME)"
run_ok "list --all" list --all
run_ok "config get" config get
run_ok "notes current-day" notes current-day
first_project=$($PM list --all 2>/dev/null | awk '/^ [A-Za-z]+-[0-9]/ { sub(/^ /,""); print; exit }')
if [[ -n "$first_project" ]]; then
  run_ok "notes path <first>" notes path "$first_project"
fi
echo "Done."
