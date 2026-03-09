#!/usr/bin/env bash
# Visual test runner: for each fixture markdown, create a temp pm project, run commands, capture output to results.json.
# Requires: swift (to build pm), jq (to build JSON). Run from repo root or tests/visual/.

set -e

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"
PM_SWIFT="$REPO_ROOT/pm-swift"
PM_BIN="$PM_SWIFT/.build/debug/pm"
RESULTS_FILE="$SCRIPT_DIR/results.json"

# Build pm if needed
if [[ ! -x "$PM_BIN" ]]; then
  echo "Building pm..." >&2
  (cd "$PM_SWIFT" && swift build)
fi
if [[ ! -x "$PM_BIN" ]]; then
  echo "Failed to build pm at $PM_BIN" >&2
  exit 1
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
CONFIG_DIR="$TMP_DIR/config"
ACTIVE_DIR="$TMP_DIR/active"
mkdir -p "$CONFIG_DIR" "$ACTIVE_DIR"

# One project: W-1 VisualTest → docs/Notes - VisualTest.md
PROJECT_FOLDER="W-1 VisualTest"
PROJECT_PATH="$ACTIVE_DIR/$PROJECT_FOLDER"
DOCS_PATH="$PROJECT_PATH/docs"
NOTES_PATH="$DOCS_PATH/Notes - VisualTest.md"
mkdir -p "$DOCS_PATH"

# pm config (no Obsidian, minimal)
CONFIG_JSON='{"activePath":"'"$ACTIVE_DIR"'","archivePath":"'"$TMP_DIR"'/archive","domains":{"W":"Work","P":"Personal"},"subfolders":["deliverables","docs","resources","previews","working files"]}'
echo "$CONFIG_JSON" > "$CONFIG_DIR/config.json"
mkdir -p "$TMP_DIR/archive"

export PM_CONFIG_HOME="$CONFIG_DIR"

CMD_OUT="$TMP_DIR/out"
CMD_ERR="$TMP_DIR/err"
run_cmd() {
  "$PM_BIN" "$@" > "$CMD_OUT" 2> "$CMD_ERR"
  echo $? > "$TMP_DIR/exit"
}

# One JSON object per fixture (compact) for later slurp
FIXTURES_JSON_LIST="$TMP_DIR/fixtures_list.json"
: > "$FIXTURES_JSON_LIST"

for fixture in "$FIXTURES_DIR"/*.md; do
  [[ -f "$fixture" ]] || continue
  name="$(basename "$fixture" .md)"
  echo "Running fixture: $name" >&2

  cp "$fixture" "$NOTES_PATH"

  commands_json="[]"

  run_cmd notes path W-1
  ec=$(< "$TMP_DIR/exit")
  cmd_json=$(jq -n --arg cmd "pm notes path W-1" --arg stdout "$(cat "$CMD_OUT")" --arg stderr "$(cat "$CMD_ERR")" --argjson exitCode "$ec" '{cmd:$cmd,stdout:$stdout,stderr:$stderr,exitCode:$exitCode}')
  commands_json=$(echo "$commands_json" | jq --argjson c "$cmd_json" '. + [$c]')

  run_cmd notes show W-1
  ec=$(< "$TMP_DIR/exit")
  cmd_json=$(jq -n --arg cmd "pm notes show W-1" --arg stdout "$(cat "$CMD_OUT")" --arg stderr "$(cat "$CMD_ERR")" --argjson exitCode "$ec" '{cmd:$cmd,stdout:$stdout,stderr:$stderr,exitCode:$exitCode}')
  commands_json=$(echo "$commands_json" | jq --argjson c "$cmd_json" '. + [$c]')

  run_cmd notes todo complete W-1 0 0
  ec=$(< "$TMP_DIR/exit")
  cmd_json=$(jq -n --arg cmd "pm notes todo complete W-1 0 0" --arg stdout "$(cat "$CMD_OUT")" --arg stderr "$(cat "$CMD_ERR")" --argjson exitCode "$ec" '{cmd:$cmd,stdout:$stdout,stderr:$stderr,exitCode:$exitCode}')
  commands_json=$(echo "$commands_json" | jq --argjson c "$cmd_json" '. + [$c]')

  run_cmd notes show W-1
  ec=$(< "$TMP_DIR/exit")
  cmd_json=$(jq -n --arg cmd "pm notes show W-1 (after complete)" --arg stdout "$(cat "$CMD_OUT")" --arg stderr "$(cat "$CMD_ERR")" --argjson exitCode "$ec" '{cmd:$cmd,stdout:$stdout,stderr:$stderr,exitCode:$exitCode}')
  commands_json=$(echo "$commands_json" | jq --argjson c "$cmd_json" '. + [$c]')

  markdown_escaped=$(jq -Rs . < "$fixture")
  fixture_json=$(jq -n --arg name "$name" --argjson markdown "$markdown_escaped" --argjson commands "$commands_json" '{name:$name,markdown:$markdown,commands:$commands}')
  echo "$fixture_json" >> "$FIXTURES_JSON_LIST"
done

jq -s '{fixtures: .}' "$FIXTURES_JSON_LIST" > "$RESULTS_FILE"

echo "Results written to $RESULTS_FILE" >&2
echo "Run: node $SCRIPT_DIR/generate-report.js" >&2
