#!/usr/bin/env bash
#
# Regenerates the content-blocking rule lists PM ships inside its bundle.
#
# Filter lists are written in Adblock Plus syntax, which WebKit cannot read. AdGuard's
# SafariConverterLib turns them into the Safari content-blocker JSON that WKContentRuleList
# compiles. That library is GPLv3, so it is used here as a *build tool* producing data files — it is
# never linked into PM, which is also why conversion cannot happen on the device.
#
# The output is committed and shipped in the app bundle rather than fetched at runtime. That costs
# about 2.2 MB per refresh in history and means the lists are only as fresh as the last PM release —
# bought in exchange for the app doing no network I/O at launch, working offline, and above all being
# the same everywhere: the rules that get notarised are the rules every user runs, so a canary that
# passes here passes there. Nothing varies per machine, so nothing can quietly differ per machine.
#
# Run it deliberately — before a release, not on every build — and commit the result.
#
# Two limits are load-bearing, both measured against the macOS 26.5 WebKit:
#   * A single compiled list is refused outright above 150,000 rules ("Too many rules in JSON
#     array"). The converter already self-caps at exactly 150,000, which silently truncates a large
#     list — so hitting the cap is treated as a failure here, not a success.
#   * Each list carries one extra `css-display-none` rule keyed to a sentinel host. That is the
#     canary CanvasContentBlocker checks at launch: a list can compile, attach, and still not be
#     applied, and nothing in the API will say so.
#
# Usage:  scripts/build-blocklists.sh [path-to-SafariConverterLib-checkout]
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$here/Resources/BlockLists"
work="${TMPDIR:-/tmp}/pm-blocklists"
converter_src="${1:-$work/SafariConverterLib}"

# name|url — the four lists that fit comfortably under the capacity ceiling. Regional lists were
# measured and deliberately left out: they add bulk for no benefit on an English-language desk.
lists=(
  "easylist|https://easylist.to/easylist/easylist.txt"
  "easyprivacy|https://easylist.to/easylist/easyprivacy.txt"
  "annoyance|https://secure.fanboy.co.nz/fanboy-annoyance.txt"
  "cookie|https://secure.fanboy.co.nz/fanboy-cookiemonster.txt"
)

mkdir -p "$work" "$out"

if [ ! -d "$converter_src" ]; then
  echo "==> cloning SafariConverterLib"
  git clone --depth 1 -q https://github.com/AdguardTeam/SafariConverterLib.git "$converter_src"
fi
converter="$converter_src/.build/release/ConverterTool"
if [ ! -x "$converter" ]; then
  echo "==> building ConverterTool"
  (cd "$converter_src" && swift build -c release --product ConverterTool >/dev/null)
fi

echo "==> converting"
total=0
for entry in "${lists[@]}"; do
  name="${entry%%|*}"; url="${entry##*|}"
  curl -fsSL -o "$work/$name.txt" "$url"
  "$converter" convert --safari-version 26.0 \
      --input-path "$work/$name.txt" \
      --safari-rules-json-path "$work/$name.json" >/dev/null

  count=$(python3 "$here/scripts/pack-blocklist.py" "$work/$name.json" "$name" "$out")
  packed=$(du -h "$out/$name.json.deflate" | cut -f1 | tr -d ' ')
  total=$((total + count))
  printf "    %-14s %7s rules -> %s\n" "$name" "$count" "$packed"
done

echo "==> $total rules across ${#lists[@]} lists in Resources/BlockLists"
echo "    commit these, then check the launch log says: verified ${#lists[@]} list(s) in force"
