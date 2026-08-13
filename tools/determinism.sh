#!/usr/bin/env bash
# Determinism replay checker: run a scenario twice in two separate processes and
# demand byte-identical state.
#
#   tools/determinism.sh                          # smoke + determinism
#   tools/determinism.sh first_night              # one scenario
#   tools/determinism.sh --seed=99 determinism    # a different seed
#
# Two processes, not two runs inside one, on purpose: a single process can hide
# divergence behind warm caches, cached resources and a dictionary that happens
# to be laid out the same way twice.
#
# wall_ms is excluded from the comparison — it is the only field in state.json
# that is allowed to differ, because it measures the clock on the wall.
#
# Exit codes: 0 identical, 1 divergent or a run failed.
set -uo pipefail
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SEED_ARG=""
SCENARIOS=()
for arg in "$@"; do
  case "$arg" in
    --seed=*) SEED_ARG="$arg" ;;
    --*)      echo "determinism: unknown option $arg"; exit 2 ;;
    *)        SCENARIOS+=("$arg") ;;
  esac
done
if [ "${#SCENARIOS[@]}" -eq 0 ]; then
  SCENARIOS=(smoke determinism)
fi

mkdir -p artifacts && : > artifacts/.gdignore
fail=0

for scenario in "${SCENARIOS[@]}"; do
  if [ ! -f "tests/scenarios/${scenario}.json" ]; then
    echo "determinism: no scenario tests/scenarios/${scenario}.json"
    fail=1
    continue
  fi
  echo ""
  echo "-- $scenario --"
  a="artifacts/determinism/${scenario}_a"
  b="artifacts/determinism/${scenario}_b"
  rm -rf "$a" "$b"

  for out in "$a" "$b"; do
    if ! tools/run_sim.sh --scenario="$scenario" --out="$out" $SEED_ARG > "/tmp/lcn_det_$$.log" 2>&1; then
      echo "determinism: the $scenario run into $out failed"
      tail -25 "/tmp/lcn_det_$$.log" | sed 's/^/    /'
      fail=1
    fi
  done
  rm -f "/tmp/lcn_det_$$.log"

  if [ ! -f "$a/state.json" ] || [ ! -f "$b/state.json" ]; then
    echo "determinism: $scenario produced no state.json"
    fail=1
    continue
  fi

  "$GODOT" --headless --path "$ROOT" --script tools/json_diff.gd -- \
      --a="$a/state.json" --b="$b/state.json" --ignore=wall_ms --max=20 \
      2>&1 | grep -vE '^(Godot Engine v|$)'
  code=${PIPESTATUS[0]}
  [ "$code" -ne 0 ] && fail=1

  # metrics.csv is advisory, not a gate: a wall-clock profiling counter in a
  # metric does not break a replay, but it does make two balance runs
  # incomparable, so name the columns rather than staying quiet about them.
  if [ -f "$a/metrics.csv" ] && [ -f "$b/metrics.csv" ] \
     && ! cmp -s "$a/metrics.csv" "$b/metrics.csv"; then
    echo "  ! metrics.csv differs between the two runs. Unstable column(s):"
    awk -F, '
      NR==FNR { if (FNR==1) { for (i=1;i<=NF;i++) name[i]=$i } else { for (i=1;i<=NF;i++) A[FNR"."i]=$i }; next }
      FNR>1   { for (i=1;i<=NF;i++) if (A[FNR"."i] != $i) bad[name[i]]=1 }
      END     { for (c in bad) print "      " c }
    ' "$a/metrics.csv" "$b/metrics.csv" | sort
    echo "      A metric that moves without the world moving cannot be diffed across builds."
  fi
done

echo ""
if [ "$fail" -eq 0 ]; then
  echo "DETERMINISM OK"
else
  echo "DETERMINISM BROKEN"
fi
exit $fail
