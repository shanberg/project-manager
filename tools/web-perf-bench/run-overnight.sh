#!/bin/zsh
# Every engine, cold, N rounds of the scenario, back to back; prints one "<variant> <result dir>" line each.
#   run-overnight.sh /path/to/bench/Folio.app [rounds]
set -u
here=${0:A:h}
app=${1:?usage: run-overnight.sh /path/to/Folio.app [rounds]}
rounds=${2:-10}
scenario=$(mktemp -t scenario).json
python3 -c "import json,sys; s=json.load(open('$here/scenario.json')); s['rounds']=$rounds; json.dump(s,open('$scenario','w'))"
cd "$here"
caffeinate -dims -w $$ &
echo "folio $(SCENARIO=$scenario ./run-folio.sh "$app" | tail -1)"
echo "wkwebview $(SCENARIO=$scenario PM_BENCH_BARE=1 ./run-folio.sh "$app" | tail -1)"
echo "chrome $(node run-chrome.mjs --scenario "$scenario" 2>&1 | tail -1)"
echo "folio-unfiltered $(SCENARIO=$scenario PM_BENCH_UNFILTERED=1 ./run-folio.sh "$app" | tail -1)"
