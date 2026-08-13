#!/usr/bin/env bash
# Performance gate. Runs the perf scenarios headless, measures ticks/second, and
# fails loudly when a build drops below the floor its scenario declares.
#
#   tools/perf.sh                       # stress_1000 + smoke
#   tools/perf.sh first_night           # any scenario
#   tools/perf.sh --all                 # every scenario in the library
#
# Writes artifacts/perf.json — the number a critic quotes, and the number the
# next regression is measured against.
#
# Exit codes: 0 within budget, 1 regression or a run failed.
set -uo pipefail
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SCENARIOS=()
for arg in "$@"; do
  case "$arg" in
    --all)
      for f in tests/scenarios/*.json; do
        base="$(basename "$f" .json)"
        [ "${base#_}" = "$base" ] && SCENARIOS+=("$base")
      done
      ;;
    --*) echo "perf: unknown option $arg"; exit 2 ;;
    *)   SCENARIOS+=("$arg") ;;
  esac
done
if [ "${#SCENARIOS[@]}" -eq 0 ]; then
  SCENARIOS=(stress_1000 smoke)
fi

mkdir -p artifacts && : > artifacts/.gdignore
runs=""
fail=0

# Engine errors are graded ONCE, by tools/scan_errors.py (tools/check.sh runs it
# over every stage log, and tools/gate.sh over every run it makes). Without this
# opt-out run_sim.sh would also fail here, and a perf stage that goes red because
# an unrelated script did not compile reports 'PERF OK' and 'FAILED' in the same
# breath — one stage, one question.
export LCN_NO_ERROR_GATE=1

for scenario in "${SCENARIOS[@]}"; do
  if [ ! -f "tests/scenarios/${scenario}.json" ]; then
    echo "perf: no scenario tests/scenarios/${scenario}.json"
    fail=1
    continue
  fi
  out="artifacts/perf/${scenario}"
  rm -rf "$out"
  printf 'perf: running %-16s' "$scenario"
  if tools/run_sim.sh --scenario="$scenario" --out="$out" > "/tmp/lcn_perf_$$.log" 2>&1; then
    echo "ok"
  else
    echo "FAILED"
    tail -25 "/tmp/lcn_perf_$$.log" | sed 's/^/    /'
    fail=1
  fi
  runs="${runs:+$runs,}$out"
done
rm -f "/tmp/lcn_perf_$$.log"

if [ -z "$runs" ]; then
  echo "perf: nothing ran"
  exit 1
fi

"$GODOT" --headless --path "$ROOT" --script tools/perf_report.gd -- \
    --runs="$runs" --out=artifacts/perf.json --budget=tools/perf_budget.json \
    2>&1 | grep -vE '^(Godot Engine v|$)'
code=${PIPESTATUS[0]}
[ "$code" -ne 0 ] && fail=1

exit $fail
