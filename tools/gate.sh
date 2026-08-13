#!/usr/bin/env bash
# THE TEETH. Everything the old gate could not see.
#
#   tools/gate.sh                 # reachability + the gate scenarios + a visual run
#   tools/gate.sh --fast          # reachability + smoke only  (pre-commit loop)
#   tools/gate.sh --all           # every scenario in tests/scenarios/, including the long one
#   tools/gate.sh --no-visual     # skip the windowed run  (states it in the report)
#   tools/gate.sh --scenarios=a,b # exactly these
#
# Three questions the 768 tests, the determinism replay and the perf gate could
# all answer "green" to while the build was unplayable:
#
#   1. did the process print engine errors?   Godot's ERROR:/SCRIPT ERROR: go to
#      stderr and never touch Log.errors, so 70 of them per visual run were
#      invisible to every gate in the repo.
#   2. can a human reach what was built?      the build menu was never in the
#      scene tree; the palette, tech tree, recipe browser, blueprint library and
#      Book of Laws therefore did not exist in the running game.
#   3. did anything actually HAPPEN?          24000 ticks, 0 items moved, 0 belt
#      lines, 43 shots in three days, one enemy alive at full HP for 7000 ticks.
#
# Exit 0 only when all three are clean. Every stage runs even after one fails.
set -uo pipefail
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PY="${PYTHON:-python3}"

SCENARIOS=(smoke first_night stress_1000 determinism)
RUN_VISUAL=1
SHOW_PASS=""
OUT_ROOT="artifacts/gate"

for arg in "$@"; do
  case "$arg" in
    --fast)        SCENARIOS=(smoke); RUN_VISUAL=0 ;;
    --all)         SCENARIOS=(); for f in tests/scenarios/*.json; do b="$(basename "$f" .json)"; [ "${b#_}" = "$b" ] && SCENARIOS+=("$b"); done ;;
    --no-visual)   RUN_VISUAL=0 ;;
    --show-pass)   SHOW_PASS="--show-pass" ;;
    --scenarios=*) IFS=',' read -r -a SCENARIOS <<< "${arg#--scenarios=}" ;;
    --out=*)       OUT_ROOT="${arg#--out=}" ;;
    *) echo "gate: unknown option $arg"; exit 2 ;;
  esac
done

if [ ! -x "$GODOT" ]; then
  echo "gate: no Godot at $GODOT (set GODOT=/path/to/Godot)" >&2
  exit 2
fi

mkdir -p artifacts && : > artifacts/.gdignore
LOGDIR="$(mktemp -d "${TMPDIR:-/tmp}/lcn_gate.XXXXXX")"
trap 'rm -rf "$LOGDIR"' EXIT

fail=0
NOTES=()
note() { NOTES+=("$1"); }

echo "════════════════════════════════════════════════════════════════════════"
echo " gate — engine errors · reachability · scenario contracts"
echo "════════════════════════════════════════════════════════════════════════"

# ── 1. reachability: boot the real game and look in the tree ────────────────
echo ""
echo "── reachability ──"
REACH_OUT="$OUT_ROOT/reach"
rm -rf "$REACH_OUT"
if [ "${LCN_NO_DISPLAY:-0}" = "1" ]; then
  echo " SKIPPED BY LCN_NO_DISPLAY — boot skips the entire view layer without a"
  echo " display server, so this run can say nothing about whether the UI is"
  echo " reachable. Treat the build as UNVERIFIED, not as green."
  note "reachability SKIPPED (LCN_NO_DISPLAY=1) — the UI was never checked"
  fail=1
else
  "$GODOT" --path "$ROOT" --resolution 1280x720 tools/reachability_scene.tscn -- \
      --out="$REACH_OUT" --frames=50 > "$LOGDIR/reach.log" 2>&1
  reach_run=$?
  [ "$reach_run" -ne 0 ] && { echo " the probe process exited $reach_run"; tail -20 "$LOGDIR/reach.log" | sed 's/^/   /'; fail=1; }
  "$PY" tools/check_reachability.py "$REACH_OUT" $SHOW_PASS || fail=1
  "$PY" tools/scan_errors.py "$LOGDIR/reach.log" --label "engine errors during boot" || fail=1
fi

# ── 2. the scenarios: run them, then hold them to their contract ────────────
for s in "${SCENARIOS[@]}"; do
  echo ""
  echo "── $s ──"
  out="$OUT_ROOT/$s"
  rm -rf "$out"
  # The harness run is the one a critic is handed: state.json + metrics.csv.
  LCN_NO_ERROR_GATE=1 tools/run_sim.sh --scenario="$s" --out="$out" > "$LOGDIR/$s.harness.log" 2>&1
  hcode=$?
  # The probe adds what state.json cannot hold: alerts, Bus signals, rosters.
  "$GODOT" --headless --path "$ROOT" --script tools/gate_probe.gd -- \
      --scenario="$s" --out="$out" > "$LOGDIR/$s.probe.log" 2>&1
  pcode=$?
  if [ "$hcode" -ne 0 ]; then
    echo " the harness exited $hcode"
    tail -15 "$LOGDIR/$s.harness.log" | sed 's/^/   /'
    fail=1
  fi
  if [ "$pcode" -ne 0 ]; then
    echo " gate_probe exited $pcode"
    tail -15 "$LOGDIR/$s.probe.log" | sed 's/^/   /'
    fail=1
  fi
  "$PY" tools/assert_run.py "$out" --scenario="$s" $SHOW_PASS || fail=1
  "$PY" tools/scan_errors.py "$LOGDIR/$s.harness.log" "$LOGDIR/$s.probe.log" \
      --label "engine errors in $s" || fail=1
done

# ── 3. the visual run: the only place the UI code actually executes ─────────
echo ""
echo "── visual run ──"
if [ "$RUN_VISUAL" -eq 0 ]; then
  echo " SKIPPED BY FLAG. Every engine error this build has ever printed came from"
  echo " a visual run — 68 String formatting errors and a refused add_child() in a"
  echo " single 30 second pass. A headless-only check has not looked at the UI."
  note "visual run SKIPPED — the UI layer was not executed at all"
else
  vis="$OUT_ROOT/visual"
  rm -rf "$vis"
  "$GODOT" --path "$ROOT" --resolution 1920x1080 -- --harness --visual \
      --scenario=smoke --out="$vis" > "$LOGDIR/visual.log" 2>&1
  vcode=$?
  [ "$vcode" -ne 0 ] && { echo " the visual harness exited $vcode"; fail=1; }
  shots=$(ls "$vis/shots" 2>/dev/null | wc -l | tr -d ' ')
  echo " $shots screenshot(s) in $vis/shots"
  [ "$shots" -eq 0 ] && { echo " a visual run that writes no frames proves nothing"; fail=1; }
  "$PY" tools/scan_errors.py "$LOGDIR/visual.log" --label "engine errors in the visual run" || fail=1
fi

echo ""
echo "════════════════════════════════════════════════════════════════════════"
for n in "${NOTES[@]:-}"; do [ -n "$n" ] && echo " ! $n"; done
if [ "$fail" -eq 0 ]; then
  echo " GATE GREEN — no engine errors, the UI is in the tree, every band held"
else
  echo " GATE RED"
fi
echo "════════════════════════════════════════════════════════════════════════"
exit $fail
