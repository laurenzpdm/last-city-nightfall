#!/usr/bin/env bash
# THE TEETH. Everything the old gate could not see.
#
#   tools/gate.sh                  # reachability + gate scenarios + endurance + a visual run
#   tools/gate.sh --fast           # reachability + smoke only        (pre-commit loop)
#   tools/gate.sh --all            # every scenario in tests/scenarios/, including the long one
#   tools/gate.sh --no-visual      # skip the windowed run  (says so, loudly, in the report)
#   tools/gate.sh --scenarios=a,b  # exactly these
#   tools/gate.sh --show-pass      # print the assertions that held, too
#
# Three questions the 768 tests, the determinism replay and the perf gate could
# all answer "green" to while the build was unplayable:
#
#   1. did the process print engine errors?  Godot's ERROR:/SCRIPT ERROR: go to
#      stderr and never touch Log.errors, so 70 of them in one visual run were
#      invisible to every gate in this repo — and check.sh even filtered ^ERROR
#      out of the test output before showing it to a human.
#   2. can a human reach what was built?     the build menu was never in the
#      scene tree, so the palette, tech tree, recipe browser, blueprint library
#      and Book of Laws did not exist in the running game.
#   3. did anything actually HAPPEN?         24000 ticks, 0 items moved, 0 belt
#      lines, 43 shots in three days, an enemy at full HP for 7000 ticks.
#
# Writes <out>/summary.txt as `section|status|detail` lines so tools/check.sh can
# print one honest line per section instead of a single opaque verdict.
#
# Exit 0 only when every section is clean.
set -uo pipefail
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PY="${PYTHON:-python3}"

SCENARIOS=(smoke first_night stress_1000 determinism)
RUN_VISUAL=1
RUN_ENDURANCE=1
SHOW_PASS=""
OUT_ROOT="artifacts/gate"
SUMMARY_OUT=""

for arg in "$@"; do
  case "$arg" in
    --fast)        SCENARIOS=(smoke); RUN_VISUAL=0; RUN_ENDURANCE=0 ;;
    --all)         SCENARIOS=(); for f in tests/scenarios/*.json; do b="$(basename "$f" .json)"; [ "${b#_}" = "$b" ] && SCENARIOS+=("$b"); done ;;
    --no-visual)   RUN_VISUAL=0 ;;
    --no-endurance) RUN_ENDURANCE=0 ;;
    --show-pass)   SHOW_PASS="--show-pass" ;;
    --scenarios=*) IFS=',' read -r -a SCENARIOS <<< "${arg#--scenarios=}" ;;
    --out=*)       OUT_ROOT="${arg#--out=}" ;;
    --summary=*)   SUMMARY_OUT="${arg#--summary=}" ;;
    *) echo "gate: unknown option $arg"; exit 2 ;;
  esac
done

if [ ! -x "$GODOT" ]; then
  echo "gate: no Godot at $GODOT (set GODOT=/path/to/Godot)" >&2
  exit 2
fi

mkdir -p artifacts && : > artifacts/.gdignore

# ── A DISPLAY, OR THE NEAREST HONEST THING TO ONE ──────────────────────────
#
# Two sections below are WINDOWED on purpose: the reachability probe boots the
# real game because a headless boot skips the whole view layer, and the visual
# run is the only pass in this repo that executes game/ui/** and game/view/**.
# `LCN_NO_DISPLAY=1` is the documented way to say "this box has none", and it
# SKIPS them and calls the build unverified rather than pretending.
#
# What was neither documented nor skipped is the third case, which is what this
# gate's own CI container actually is: no X11, no Wayland, and Xvfb sitting on
# the PATH. Godot then fails to create a DisplayServer and exits before
# `_ready`, so the reachability section reported "the probe wrote no dump — a
# boot that produces no evidence is a boot that failed" and the visual section
# reported "0 screenshots", and both of those read as DEFECTS IN THE BUILD.
# Measured on 2026-08-17, same tree, same commit: under `xvfb-run` the probe
# exits 0 with 15 pass / 0 FAIL / 0 unchecked and 0 blocking engine errors, and
# the visual run exits 0 with 10 shots and 0 blocking errors. Four of twelve
# red stages in that check run were this and nothing else.
#
# A gate that is red for reasons unrelated to the code gets ignored exactly like
# one that is never red. So: if there is a real display, use it; if there is
# none and Xvfb is here, run those two sections inside one; if neither, the
# LCN_NO_DISPLAY path already says the honest thing.
DISPLAY_WRAP=()
if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ] \
   && command -v xvfb-run >/dev/null 2>&1; then
  DISPLAY_WRAP=(xvfb-run -a -s "-screen 0 1920x1080x24")
  echo "gate: no DISPLAY and no WAYLAND_DISPLAY — the windowed sections run under xvfb-run"
fi
# `${a[@]+"${a[@]}"}`, not `"${a[@]}"`: this script runs under `set -u`, where
# expanding an EMPTY array is an unbound-variable error on bash 3.2, which is
# what the project's macOS job uses.
xvfb() { "${DISPLAY_WRAP[@]+${DISPLAY_WRAP[@]}}" "$@"; }

# TEN AGENTS SHARE THIS REPO AND ALL OF THEM RUN tools/check.sh. Two gate runs
# in the same artifacts/gate/ delete each other's scenario directories between a
# harness run and the assertion over it — which is exactly what happened the
# first time this stage ran for real: stress_1000 was graded "holds no
# state.json" while a 21 MB state.json sat in the folder, written by a run whose
# directory a concurrent gate had already removed. So: one gate owns the shared
# path, everyone else gets their own and is told so.
LOCK="artifacts/.gate.lock"
if mkdir "$LOCK" 2>/dev/null; then
  echo $$ > "$LOCK/pid"
  trap 'rm -rf "$LOCK" "$LOGDIR"' EXIT
else
  holder="$(cat "$LOCK/pid" 2>/dev/null || echo 0)"
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
    OUT_ROOT="${OUT_ROOT}-$$"
    echo "gate: another run (pid $holder) holds artifacts/.gate.lock — writing to $OUT_ROOT"
    trap 'rm -rf "$LOGDIR"' EXIT
  else
    echo $$ > "$LOCK/pid"
    echo "gate: took over a stale lock from pid $holder"
    trap 'rm -rf "$LOCK" "$LOGDIR"' EXIT
  fi
fi
mkdir -p "$OUT_ROOT"
SUMMARY="${SUMMARY_OUT:-$OUT_ROOT/summary.txt}"
: > "$SUMMARY"
LOGDIR="$(mktemp -d "${TMPDIR:-/tmp}/lcn_gate.XXXXXX")"
fail=0
skipped=0

# section <name> <code> <detail>
sect() {
  local status="pass"
  [ "$2" -ne 0 ] && { status="FAIL"; fail=1; }
  printf '%s|%s|%s\n' "$1" "$status" "$3" >> "$SUMMARY"
}

# A section that did not run is NOT a section that passed. It never fails the
# exit code — a pre-commit loop has to stay usable — but it downgrades the
# verdict to PARTIAL and is printed in full, so nobody can read a skipped
# visual pass as a checked one.
sect_skip() {
  skipped=$((skipped + 1))
  printf '%s|SKIP|%s\n' "$1" "$2" >> "$SUMMARY"
}

# The one-line verdict a python checker printed, for the summary file.
tailnote() { grep -m1 -E "^ [a-z].* — .*pass" "$1" | sed 's/^ *//' ; }

echo "════════════════════════════════════════════════════════════════════════"
echo " gate — engine errors · reachability · scenario contracts"
echo "════════════════════════════════════════════════════════════════════════"

# ── 1. reachability: boot the real game and look in the tree ────────────────
echo ""
echo "── reachability ──"
REACH_OUT="$OUT_ROOT/reach"
rm -rf "$REACH_OUT"
if [ "${LCN_NO_DISPLAY:-0}" = "1" ]; then
  echo " SKIPPED BY LCN_NO_DISPLAY. Without a display server boot skips the whole"
  echo " view layer, so a headless pass can say nothing about whether the UI is"
  echo " reachable. The build is UNVERIFIED here, not green."
  sect_skip "reachability" "LCN_NO_DISPLAY=1 — the UI was never looked at"
else
  xvfb "$GODOT" --path "$ROOT" --resolution 1280x720 tools/reachability_scene.tscn -- \
      --out="$REACH_OUT" --frames=50 > "$LOGDIR/reach.log" 2>&1
  rcode=$?
  if [ "$rcode" -ne 0 ]; then
    echo " the probe process exited $rcode"
    tail -20 "$LOGDIR/reach.log" | sed 's/^/   /'
  fi
  "$PY" tools/check_reachability.py "$REACH_OUT" $SHOW_PASS > "$LOGDIR/reach.check" 2>&1
  ccode=$?
  cat "$LOGDIR/reach.check"
  [ "$rcode" -ne 0 ] && ccode=1
  sect "reachability" "$ccode" "$(tailnote "$LOGDIR/reach.check")"
  "$PY" tools/scan_errors.py "$LOGDIR/reach.log" --label "engine errors during boot" --quiet
  sect "engine errors: boot" $? "Godot's own stderr during a real launch"
fi

# ── 2. the scenarios: run them, then hold them to their contract ────────────
run_scenario() {   # run_scenario <label> <scenario> [extra harness args...]
  local label="$1"; shift
  local scenario="$1"; shift
  echo ""
  echo "── $label ──"
  local out="$OUT_ROOT/$label"
  rm -rf "$out"
  # The harness run is what a critic is handed: state.json + metrics.csv + log.txt.
  LCN_NO_ERROR_GATE=1 tools/run_sim.sh --scenario="$scenario" --out="$out" "$@" \
      > "$LOGDIR/$label.harness.log" 2>&1
  local hcode=$?
  # The probe adds what state.json cannot hold: alerts, Bus signals, rosters.
  "$GODOT" --headless --path "$ROOT" --script tools/gate_probe.gd -- \
      --scenario="$scenario" --out="$out" "$@" > "$LOGDIR/$label.probe.log" 2>&1
  local pcode=$?
  if [ "$hcode" -ne 0 ]; then
    echo " the harness exited $hcode"; tail -12 "$LOGDIR/$label.harness.log" | sed 's/^/   /'
  fi
  if [ "$pcode" -ne 0 ]; then
    echo " gate_probe exited $pcode"; tail -12 "$LOGDIR/$label.probe.log" | sed 's/^/   /'
  fi
  "$PY" tools/assert_run.py "$out" --scenario="$label" $SHOW_PASS > "$LOGDIR/$label.check" 2>&1
  local acode=$?
  cat "$LOGDIR/$label.check"
  [ "$hcode" -ne 0 ] || [ "$pcode" -ne 0 ] && acode=1
  sect "contract: $label" "$acode" "$(tailnote "$LOGDIR/$label.check")"
  "$PY" tools/scan_errors.py "$LOGDIR/$label.harness.log" "$LOGDIR/$label.probe.log" \
      --label "engine errors in $label" --quiet
  sect "engine errors: $label" $? "headless run + probe"
}

for s in "${SCENARIOS[@]}"; do
  run_scenario "$s" "$s"
done

# The shipped first_night stops at 11000 ticks and never reaches wave 2, which
# is where "the wave that never ended" lived. tests/scenarios/ belongs to [P00],
# so the gate stretches the run instead of editing the file.
if [ "$RUN_ENDURANCE" -eq 1 ]; then
  run_scenario "first_night_endurance" "first_night" --ticks=24000
fi

# ── 3. the visual run: the only place the UI code actually executes ─────────
echo ""
echo "── visual run ──"
if [ "$RUN_VISUAL" -eq 0 ]; then
  echo " SKIPPED BY FLAG. Every engine error this build has printed came out of a"
  echo " visual run — 68 String formatting errors and one refused add_child() in a"
  echo " single 30 second pass. A headless-only check has not looked at the UI."
  sect_skip "visual run" "the UI layer was never executed in this check"
else
  vis="$OUT_ROOT/visual"
  rm -rf "$vis"
  # `env` rather than a `VAR=1 xvfb ...` prefix: a variable assignment in front
  # of a FUNCTION call is not exported to the processes that function starts, so
  # the prefix form would have silently stopped disabling the inner error gate
  # the moment this call was wrapped.
  xvfb env LCN_NO_ERROR_GATE=1 tools/run_visual.sh --scenario=smoke --out="$vis" \
      > "$LOGDIR/visual.log" 2>&1
  vcode=$?
  shots=$(ls "$vis/shots" 2>/dev/null | wc -l | tr -d ' ')
  echo " harness exit $vcode, $shots screenshot(s) in $vis/shots"
  [ "$shots" -eq 0 ] && { echo " a visual run that writes no frames proves nothing"; vcode=1; }
  sect "visual run" "$vcode" "$shots screenshot(s)"
  "$PY" tools/scan_errors.py "$LOGDIR/visual.log" --label "engine errors in the visual run"
  sect "engine errors: visual" $? "the only pass that executes ui/ and view/"
fi

# ── the verdict ────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════════════"
while IFS='|' read -r name status detail; do
  case "$status" in
    pass) printf ' %-34s pass   %s\n' "$name" "$detail" ;;
    SKIP) printf ' %-34s SKIP   %s\n' "$name" "$detail" ;;
    *)    printf ' %-34s FAIL   %s\n' "$name" "$detail" ;;
  esac
done < "$SUMMARY"
echo "════════════════════════════════════════════════════════════════════════"
if [ "$fail" -ne 0 ]; then
  echo " GATE RED"
elif [ "$skipped" -ne 0 ]; then
  echo " GATE GREEN, PARTIAL — $skipped section(s) were not checked at all (SKIP above)"
else
  echo " GATE GREEN — no engine errors, the UI is in the tree, every band held"
fi
exit $fail
