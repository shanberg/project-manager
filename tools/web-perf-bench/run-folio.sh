#!/bin/zsh
# WebKit-in-Folio run: build a scratch vault + bench.canvas from scenario.json, launch a bench build of
# Folio (its own bundle id, so its own defaults and website data), sample its WebKit processes, wait.
#
#   run-folio.sh /path/to/Folio.app                       cold run (results/folio-cold-<stamp>/)
#   PM_BENCH_WARM=1 run-folio.sh …                        pages kept live between layouts
#   PM_BENCH_UNFILTERED=1 run-folio.sh …                  Folio's block lists off for the scenario's hosts
#   PM_BENCH_COPY_COOKIES="Google Chrome" run-folio.sh …  copy the sites' cookies from Chrome first
#   PM_BENCH_SIGNIN=1 run-folio.sh …                      open the board and wait; sign in by hand, then quit
#   PM_BENCH_BARE=1 run-folio.sh …                        control: plain WKWebViews at Folio's tile frames
#
# Build the app with its own id, e.g.:
#   xcodebuild -scheme PM -destination 'platform=macOS,arch=arm64' -configuration Release \
#     -derivedDataPath <dd> PRODUCT_BUNDLE_IDENTIFIER=com.stuarthanberg.pm.benchdev build
set -euo pipefail
here=${0:A:h}
app=${1:?usage: run-folio.sh /path/to/Folio.app}
scenario=${SCENARIO:-$here/scenario.json}
bundle=$(defaults read "$app/Contents/Info" CFBundleIdentifier)
[[ $bundle == com.stuarthanberg.pm ]] && { echo "refusing: $app has the real bundle id"; exit 1; }

mode=cold; [[ ${PM_BENCH_WARM:-} == 1 ]] && mode=warm
[[ ${PM_BENCH_UNFILTERED:-} == 1 ]] && mode=$mode-unfiltered
[[ ${PM_BENCH_SHOW_AT_ONCE:-} == 1 ]] && mode=$mode-showatonce
prefix=folio; [[ ${PM_BENCH_BARE:-} == 1 ]] && prefix=wkwebview
stamp=$(date -u +%Y-%m-%dT%H-%M-%SZ)
out=$here/results/$prefix-$mode-$stamp
[[ ${PM_BENCH_SIGNIN:-} == 1 ]] && out=$here/results/folio-signin
vault=$here/profiles/folio-vault
mkdir -p "$out" "$vault/config" "$vault/PARA/Projects" "$vault/PARA/Archive" "$vault/PARA/Areas"
cp "$scenario" "$out/scenario.json"
cp "$here/probe.js" "$out/probe.js"
# The bare control lays its views out at the frames Folio's last run measured.
[[ -f $here/results/tiles.json ]] && cp "$here/results/tiles.json" "$out/folio-tiles.json"
cat > "$vault/config/config.json" <<EOF
{"activePath":"$vault/PARA/Projects","archivePath":"$vault/PARA/Archive","areasPath":"$vault/PARA/Areas",
 "paraPath":"$vault/PARA","domains":{"W":"Work"},"subfolders":["docs"]}
EOF

# One link card per (layout, site), so a crossing never adopts another layout's live page.
python3 - "$out/scenario.json" "$out/bench.canvas" <<'EOF'
import json, sys
s = json.load(open(sys.argv[1]))
nodes, x = [], 0
for layout in s['layouts']:
    y = 0
    for site in [site for col in layout['columns'] for site in col]:
        nodes.append({'id': f"{layout['name']}.{site}", 'type': 'link', 'url': s['sites'][site]['url'],
                      'x': x, 'y': y, 'width': 640, 'height': 400})
        y += 440
    x += 700
json.dump({'nodes': nodes, 'edges': []}, open(sys.argv[2], 'w'), indent=1)
EOF

defaults write "$bundle" PMFrameMeterEnabled -bool YES
# Per-site settings are the bench build's own; an unfiltered run writes them, so start every run clean.
defaults delete "$bundle" PMCanvasSites 2>/dev/null || true
# Hidden boards never keep pages alive on their own between steps; the bench freezes them anyway.
defaults write "$bundle" PMCanvasOffScreenGrace -float 0.001
[[ $mode == warm* ]] && defaults write "$bundle" PMCanvasOffScreenGrace -float 3600

open -n -a "$app" --env PM_CONFIG_HOME="$vault/config" --env PM_LAYOUT_BENCH="$out" \
  --env PM_BENCH_WARM="${PM_BENCH_WARM:-}" --env PM_BENCH_UNFILTERED="${PM_BENCH_UNFILTERED:-}" \
  --env PM_BENCH_COPY_COOKIES="${PM_BENCH_COPY_COOKIES:-}" --env PM_BENCH_SIGNIN="${PM_BENCH_SIGNIN:-}" \
  --env PM_BENCH_SHOW_AT_ONCE="${PM_BENCH_SHOW_AT_ONCE:-}" --env PM_BENCH_BARE="${PM_BENCH_BARE:-}"
for _ in {1..50}; do pid=$(pgrep -f "$app/Contents/MacOS" | head -1 || true); [[ -n $pid ]] && break; sleep 0.2; done
[[ -z ${pid:-} ]] && { echo "app did not start"; exit 1; }
python3 "$here/sampler.py" --responsible "$pid" --out "$out/procs.jsonl" &
sampler=$!
while kill -0 "$pid" 2>/dev/null; do sleep 1; done
kill "$sampler" 2>/dev/null || true
[[ -f $out/tiles.json && ${PM_BENCH_BARE:-} != 1 ]] && cp "$out/tiles.json" "$here/results/tiles.json"
echo "$out"
