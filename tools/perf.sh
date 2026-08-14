#!/usr/bin/env bash
# Performance gate. Runs the perf scenarios headless, measures ticks/second, and
# fails loudly when a build drops below the floor its scenario declares.
#
#   tools/perf.sh                       # stress_1000 + smoke
#   tools/perf.sh first_night           # any scenario
#   tools/perf.sh --all                 # every scenario in the library
#   tools/perf.sh --repeat=5            # five readings per scenario
#
# Writes artifacts/perf.json — the numbers a critic quotes, and the numbers the
# next regression is measured against.
#
# ONE READING IS NOT A MEASUREMENT. Six readings of the same test on the same
# runner with no code change spanned 9410..16215 µs — a 72 % spread, wider than
# the gap to the floor, and four gate stages flapped on it. So each scenario is
# read REPEAT times into artifacts/perf/<scenario>/r<n>/ and tools/perf_report.gd
# judges the median and prints the whole distribution. The floors are untouched.
#
# Default REPEAT is 3. Set LCN_PERF_REPEATS=1 for the fast pre-commit loop and
# accept that the answer is a coin flip; the report says `1 reading` when you do.
#
# Exit codes: 0 within budget (noise included), 1 regression or a run failed.
set -uo pipefail
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SCENARIOS=()
REPEAT="${LCN_PERF_REPEATS:-3}"
for arg in "$@"; do
  case "$arg" in
    --all)
      for f in tests/scenarios/*.json; do
        base="$(basename "$f" .json)"
        [ "${base#_}" = "$base" ] && SCENARIOS+=("$base")
      done
      ;;
    --repeat=*) REPEAT="${arg#--repeat=}" ;;
    --*) echo "perf: unknown option $arg"; exit 2 ;;
    *)   SCENARIOS+=("$arg") ;;
  esac
done
case "$REPEAT" in
  ''|*[!0-9]*) echo "perf: --repeat wants a positive integer, not '$REPEAT'"; exit 2 ;;
esac
[ "$REPEAT" -lt 1 ] && REPEAT=1
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

# A timing measured next to somebody else's Godot is not a timing. The same test
# read 9913 and 14617 µs on this box purely as a function of what else was on it,
# and ten agents share this repo. This cannot fail the stage — the neighbour is
# not this build's defect — but it goes in the report, because "is this red
# real?" is unanswerable without it.
neighbours() { ps -eo cmd 2>/dev/null | grep -c "[g]odot --" || true; }
BUSY_BEFORE="$(neighbours)"

for scenario in "${SCENARIOS[@]}"; do
  if [ ! -f "tests/scenarios/${scenario}.json" ]; then
    echo "perf: no scenario tests/scenarios/${scenario}.json"
    fail=1
    continue
  fi
  rm -rf "artifacts/perf/${scenario}"
  n=1
  while [ "$n" -le "$REPEAT" ]; do
    out="artifacts/perf/${scenario}/r${n}"
    rm -rf "$out"
    printf 'perf: running %-16s reading %d/%-3s ' "$scenario" "$n" "$REPEAT"
    if tools/run_sim.sh --scenario="$scenario" --out="$out" > "/tmp/lcn_perf_$$.log" 2>&1; then
      echo "ok"
    else
      echo "FAILED"
      tail -25 "/tmp/lcn_perf_$$.log" | sed 's/^/    /'
      fail=1
    fi
    runs="${runs:+$runs,}$out"
    n=$((n + 1))
  done
done
rm -f "/tmp/lcn_perf_$$.log"

if [ -z "$runs" ]; then
  echo "perf: nothing ran"
  exit 1
fi

# `neighbours` counts this stage's own sims too, so only the surplus over the one
# we expect is worth reporting.
BUSY_AFTER="$(neighbours)"
if [ "$BUSY_BEFORE" -gt 1 ] || [ "$BUSY_AFTER" -gt 1 ]; then
  echo "perf: WARNING — $BUSY_BEFORE other Godot process(es) before these readings and"
  echo "perf:           $BUSY_AFTER after. These numbers were measured on a busy box;"
  echo "perf:           treat a red verdict as unproven until it is re-read alone."
fi

"$GODOT" --headless --path "$ROOT" --script tools/perf_report.gd -- \
    --runs="$runs" --out=artifacts/perf.json --budget=tools/perf_budget.json \
    2>&1 | grep -vE '^(Godot Engine v|$)'
code=${PIPESTATUS[0]}
[ "$code" -ne 0 ] && fail=1

exit $fail
