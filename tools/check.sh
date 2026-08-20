#!/usr/bin/env bash
# THE GATE. One command, one answer, one exit code.
#
#   tools/check.sh              # everything below
#   tools/check.sh --fast       # skip determinism, perf, and the slow gate runs
#   tools/check.sh --no-perf    # everything but the perf gate
#   tools/check.sh --no-gate    # skip reachability + contracts + the visual run
#   tools/check.sh --no-visual  # keep the gate, skip the windowed run
#   tools/check.sh --quiet      # only the summary and the failures
#
#   import · parse · sim lint · tests · standalone suites · determinism · perf
#   · ENGINE ERRORS · REACHABILITY · SCENARIO CONTRACTS · a VISUAL run
#
# The last four are new, and they are why this file exists in this shape. On
# 2026-08-13 this script printed CHECK GREEN on a build where:
#
#   * the build menu was never in the scene tree, so the palette, tech tree,
#     recipe browser, blueprint library and Book of Laws did not exist in the
#     running game and no human could reach the logistics pillar at all;
#   * 70 engine errors printed per visual run, none of which Log.errors counts,
#     and line 154 of this very file filtered `^ERROR` out of the output before
#     a human could read it;
#   * first_night ran 24000 ticks with logistics.items_moved flat at 0.
#
# 768 tests, a determinism replay and a perf gate all said green, because all
# three test the simulation and none of them asked whether anything HAPPENED or
# whether a player could reach it.
#
# Every stage runs even when an earlier one fails: a builder wants the whole
# list of what is wrong, not the first item on it.
#
# Exit code 0 means the build is green and a critic can be handed the artifacts.
# "CHECK GREEN, PARTIAL" means some stage never ran. It is not green.
set -uo pipefail
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RUN_DETERMINISM=1
RUN_PERF=1
RUN_GATE=1
GATE_ARGS=""
QUIET=0
PY="${PYTHON:-python3}"
for arg in "$@"; do
  case "$arg" in
    --fast)    RUN_DETERMINISM=0; RUN_PERF=0; GATE_ARGS="--fast" ;;
    --no-perf) RUN_PERF=0 ;;
    --no-determinism) RUN_DETERMINISM=0 ;;
    --no-gate) RUN_GATE=0 ;;
    --no-visual) GATE_ARGS="$GATE_ARGS --no-visual" ;;
    --quiet)   QUIET=1 ;;
    *) echo "check: unknown option $arg"; exit 2 ;;
  esac
done

if ! command -v "$PY" >/dev/null 2>&1; then
  echo "check: no $PY on PATH — the engine-error scan and the scenario contracts"
  echo "       are written in python. Set PYTHON=/path/to/python3."
  exit 2
fi

if [ ! -x "$GODOT" ]; then
  echo "check: no Godot at $GODOT (set GODOT=/path/to/Godot)"
  exit 2
fi

# Hard wall-clock cap for a single standalone suite. GNU coreutils `timeout` if
# present, `gtimeout` on a stock mac, and no cap at all if neither exists.
SUITE_TIMEOUT="${SUITE_TIMEOUT:-240}"
TIMEOUT=""
if command -v timeout >/dev/null 2>&1; then TIMEOUT="timeout -k 5 ${SUITE_TIMEOUT}"
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT="gtimeout -k 5 ${SUITE_TIMEOUT}"; fi

LOGDIR="$(mktemp -d "${TMPDIR:-/tmp}/lcn_check.XXXXXX")"
trap 'rm -rf "$LOGDIR"' EXIT
mkdir -p artifacts && : > artifacts/.gdignore   # keep the editor from importing run output

STAGES=()
RESULTS=()      # "pass" | "FAIL" | "SKIP"
DETAILS=()
STAGE_GROUP=()  # for the one-screen summary: pass lines collapse per group
                # (NOT "GROUPS": bash 3.2 owns that name and an append to it
                # aborts the enclosing function without a word, which silently
                # desynced this array from RESULTS the first time it ran)
fail=0
skipped=0

# stage <name> <logfile> <exit code> [detail] [group]
record() {
  STAGES+=("$1")
  DETAILS+=("${4:-}")
  STAGE_GROUP+=("${5:-$1}")
  if [ "$3" -ne 0 ]; then
    RESULTS+=("FAIL")
    fail=1
    echo "  ✗ $1${4:+ — $4}"
    [ -s "$2" ] && tail -40 "$2" | sed 's/^/      /'
  else
    RESULTS+=("pass")
    echo "  ✓ $1${4:+ — $4}"
  fi
}

# A stage that did not run is not a stage that passed. It does not fail the
# exit code, but it downgrades the verdict to PARTIAL and is printed in the
# summary in full — the whole disease here was output a reader could come away
# from with a rosier impression than the truth.
record_skip() {
  STAGES+=("$1")
  RESULTS+=("SKIP")
  DETAILS+=("${2:-}")
  STAGE_GROUP+=("${3:-$1}")
  skipped=$((skipped + 1))
  echo "  ~ $1 — NOT CHECKED: ${2:-}"
}

say() { [ "$QUIET" -eq 1 ] || echo "$@"; }

echo "────────────────────────────────────────────────────────────────────────"
echo " Last City: Nightfall — check"
echo " $(cd "$ROOT" && pwd)"
echo "────────────────────────────────────────────────────────────────────────"

# --- 1. import -------------------------------------------------------------
say ""
say "== import =="
"$GODOT" --headless --path "$ROOT" --import > "$LOGDIR/import.log" 2>&1
import_code=0
if grep -qE "SCRIPT ERROR|Parse Error|Failed to load script" "$LOGDIR/import.log"; then
  import_code=1
  grep -nE "SCRIPT ERROR|Parse Error|Failed to load script" "$LOGDIR/import.log" | head -20 > "$LOGDIR/import.err"
  cp "$LOGDIR/import.err" "$LOGDIR/import.log"
fi
record "import" "$LOGDIR/import.log" "$import_code"

# --- 2. parse every script -------------------------------------------------
say ""
say "== parse =="
"$GODOT" --headless --path "$ROOT" --script tools/parse_check.gd > "$LOGDIR/parse.log" 2>&1
parse_code=$?
parse_note="$(grep -m1 '^parse check:' "$LOGDIR/parse.log" | sed 's/^parse check: //')"
# load() answers from the resource cache, so parse_check.gd can hand back a
# perfectly good Script object for a file that no longer compiles. It printed
# PARSE OK on a build where four SimSystems refused to load and the game came up
# with two systems in it. The parser still SAYS so on stderr, so read that, the
# same way the import stage already does.
if grep -qE "SCRIPT ERROR|Parse Error|Compile Error|Failed to load script" "$LOGDIR/parse.log"; then
  parse_code=1
  parse_note="a script does not compile"
  grep -nE "SCRIPT ERROR|Parse Error|Compile Error|Failed to load script" "$LOGDIR/parse.log" | head -20 > "$LOGDIR/parse.err"
  cat "$LOGDIR/parse.err" > "$LOGDIR/parse.log"
fi
record "parse" "$LOGDIR/parse.log" "$parse_code" "$parse_note"

# --- 3. determinism lint ---------------------------------------------------
say ""
say "== sim lint =="
tools/lint_sim.sh > "$LOGDIR/lint.log" 2>&1
lint_code=$?
record "sim lint" "$LOGDIR/lint.log" "$lint_code" "game/sim/** obeys ARCHITECTURE.md §3"

# --- 4. the test suites ----------------------------------------------------
say ""
say "== tests =="
# --verbose so the runner prints one line PER TEST with its assert count. It is
# the only way this stage can see a test that asserted nothing (below), and the
# extra thousand lines never reach a human: the listing below drops them again.
"$GODOT" --headless --path "$ROOT" --script tests/run_tests.gd -- --verbose > "$LOGDIR/tests.log" 2>&1
tests_code=$?
grep -q "TESTS FAILED" "$LOGDIR/tests.log" && tests_code=1
if [ "$QUIET" -eq 0 ]; then
  # The engine's own ERROR/WARNING lines are filtered OUT of this listing on
  # purpose — but only because tools/scan_errors.py now reads the same log and
  # gates on them further down. Before that stage existed, this filter was the
  # single line of shell that hid 70 engine errors per run from every human who
  # ever read this output.
  sed -n '/^─/,$p' "$LOGDIR/tests.log" \
    | grep -vE '^(WARNING|ERROR|\s+at:)' | grep -vE '^ *pass +' | sed 's/^/  /'
fi
tests_note="$(grep -m1 '^ tests ' "$LOGDIR/tests.log" | sed 's/^ tests  *//')"

# A TEST THAT CANNOT FAIL IS WORSE THAN NO TEST, because it also occupies the
# slot where a real one would go. This build has been burned three times —
# a sprite suite reading its own cache, a gallery comparing an anchor list
# nobody rebuilt, a reachability suite passing in the one configuration the gate
# used — and every one of them was still counted in "1070 passed".
#
# The runner prints `pass  <method>   N assert(s), X ms`. A test that ran to
# completion and asserted NOTHING is green by construction: there is no input,
# no regression and no revert that can turn it red. It is caught here rather
# than in the framework because tests/framework/ belongs to another part.
hollow="$(grep -cE '^ *pass +[^ ]+ +0 assert\(s\)' "$LOGDIR/tests.log" 2>/dev/null || true)"
if [ "${hollow:-0}" -gt 0 ]; then
  tests_code=1
  tests_note="${tests_note} — $hollow test(s) passed WITHOUT ASSERTING ANYTHING: $(grep -m3 -E '^ *pass +[^ ]+ +0 assert\(s\)' "$LOGDIR/tests.log" | awk '{print $2}' | tr '\n' ' ')"
  {
    echo "tests that cannot fail — they ran, they were counted as passing, and they"
    echo "asserted nothing. Nothing can turn them red:"
    grep -E '^ *pass +[^ ]+ +0 assert\(s\)' "$LOGDIR/tests.log" | head -20
  } >> "$LOGDIR/tests.log"
fi
record "tests" "$LOGDIR/tests.log" "$tests_code" "$tests_note"

# --- 4b. suites that brought their own entry point -------------------------
#
# A suite may need command-line switches to be asking the question it thinks it
# is asking. It declares them itself, in one line at the top of its script:
#
#     ## REQUIRES: --force-ui
#
# rather than in a list kept here. The case that forced this: every part that
# installs itself (`game/content/**/*_bootstrap.tres`) asks
# `LcnLayers.view_wanted()` while Registry is still scanning, so with a display
# or with `--force-ui` those parts come up BEFORE boot and the tree is assembled
# in a different order, with a different owner for the number row. Run headless
# without the switch and tests/boot/run_reachability.tscn printed
# `TESTS PASSED — 86 checks, 0 failures` on a build that failed three checks the
# moment a display was attached. The gate was asking the easy question.
suite_args() {   # suite_args <path> -> the user args that suite declares it needs
  local rel="$1" src="$rel"
  if [ "${rel##*.}" = "tscn" ]; then
    src="$(grep -m1 -oE 'path="res://[^"]+\.gd"' "$rel" 2>/dev/null \
           | sed 's|^path="res://||; s|"$||')"
  fi
  [ -n "$src" ] && [ -f "$src" ] || return 0
  grep -m1 '^## REQUIRES: ' "$src" 2>/dev/null | sed 's/^## REQUIRES: //'
}

# --- 4c. suites that grade a visual run's PNGs -----------------------------
#
# The same idea one step further. Three suites in this build do not test code
# directly: they open the screenshots a harness run wrote and measure them.
# They declare that, in the same one-line idiom:
#
#     ## READS: visual-run
#
# WHY THIS EXISTS, MEASURED. Standalone suites are stage 5 and the gate's visual
# run is stage 8, so at the moment these three execute, `artifacts/gate/visual`
# still holds the run the PREVIOUS check.sh made — and each of them, finding it
# unsuitable, walks on to the newest folder in `artifacts/` that will answer.
# On this tree that folder was `artifacts/H4b_v6`, a builder's private scratch
# run; four folders further down the same list is `artifacts/H4b_nofloor`, an
# ablation with the night's sun and sky energy deliberately set to zero. A gate
# stage that grades an ablation somebody left lying around is not a gate.
# `tests/render/run_ground_frame.gd` could never grade the gate's own run in any
# case: it reads shots named midday/dusk/deep_night/third_day_city and the gate
# photographs `smoke`, whose beats are named morning_industry/dusk_city/
# night_perimeter/deep_night_zoomout. The two halves of the gate disagreed about
# which run the build is, and the suites settled it by wandering.
#
# So they are deferred to after the visual run and pinned to it with
# LCN_FRAME_DIR, which those suites now treat as "this run or nothing" rather
# than as the first guess of a search.
suite_reads() {   # suite_reads <path> -> what this suite needs to have been produced first
  local rel="$1" src="$rel"
  if [ "${rel##*.}" = "tscn" ]; then
    src="$(grep -m1 -oE 'path="res://[^"]+\.gd"' "$rel" 2>/dev/null \
           | sed 's|^path="res://||; s|"$||')"
  fi
  [ -n "$src" ] && [ -f "$src" ] || return 0
  grep -m1 '^## READS: ' "$src" 2>/dev/null | sed 's/^## READS: //'
}

# One attempt at one standalone suite. Sets SUITE_CODE (0 pass, 1 fail, 2 could
# not ask everything) and SUITE_NOTE. Split out of the loop below so a failing
# suite can be READ AGAIN — see FLAKE_RETRIES.
SUITE_CODE=0
SUITE_NOTE=""
suite_attempt() {   # suite_attempt <rel> <log>
  local rel="$1" log="$2"
  # shellcheck disable=SC2046
  read -r -a SUITE_ARGS <<< "$(suite_args "$rel")"
  # A .tscn is run AS A SCENE. Godot compiles a --script file before it
  # registers the autoloads, so a Node-based suite launched that way dies on
  # `Identifier not found: Log`, prints nothing and exits 0 — which is exactly
  # how 371 build assertions were reported green while never executing.
  # A suite that never exits is worse than one that fails: without this the
  # gate blocks forever and every other agent's check.sh queues behind it.
  # `${a[@]+"${a[@]}"}`, not `"${a[@]}"`: this script runs under `set -u`, and
  # the gate's own macOS job runs on bash 3.2, where expanding an EMPTY array
  # is an unbound-variable error that aborts the whole run. Every suite without
  # a REQUIRES line has an empty array.
  if [ "${rel##*.}" = "tscn" ]; then
    $TIMEOUT "$GODOT" --headless --path "$ROOT" "res://$rel" \
        -- ${SUITE_ARGS[@]+"${SUITE_ARGS[@]}"} > "$log" 2>&1
  else
    $TIMEOUT "$GODOT" --headless --path "$ROOT" --script "$rel" \
        -- ${SUITE_ARGS[@]+"${SUITE_ARGS[@]}"} > "$log" 2>&1
  fi
  local raw=$?
  SUITE_CODE=0
  SUITE_NOTE=""
  if [ "$raw" -eq 124 ]; then
    SUITE_CODE=1
    SUITE_NOTE="hung — killed after ${SUITE_TIMEOUT}s"
    return 0
  fi
  if grep -q "TESTS FAILED" "$log"; then
    SUITE_CODE=1
    # "1 of 67 checks failed:" was being reported as "67 checks failed:",
    # because the old pattern started matching at the first number it could
    # find rather than at the count of failures. One failing check read as
    # sixty-seven in the summary, which is the difference between "look at
    # this first" and "look at this later".
    SUITE_NOTE="$(grep -m1 -oE '[0-9]+ of [0-9]+ checks? failed' "$log" \
            || grep -m1 -oE '[0-9]+ (passed|checks).*' "$log" || true)"
  elif grep -q "TESTS PASSED, PARTIAL" "$log"; then
    # The suite ran and nothing it asked came back wrong, but it could not ask
    # everything it exists to ask. That is not a pass, and the one thing it
    # must never do is read like one.
    SUITE_CODE=2
    SUITE_NOTE="$(grep -m1 -oE '[0-9]+ unchecked' "$log" || echo 'some checks never ran') — $(grep -m1 -oE 'UNCHECKED .*' "$log" | cut -c1-90)"
  elif ! grep -q "TESTS PASSED" "$log"; then
    # No verdict at all means the suite never ran. Silence is not success.
    SUITE_CODE=1
    SUITE_NOTE="printed no TESTS PASSED / TESTS FAILED verdict — did it run at all?"
  else
    SUITE_NOTE="$(grep -m1 -oE '[0-9]+ (passed|checks)[^,]*' "$log" || true)"
    # The standalone half of the same disease. A suite that prints a passing
    # verdict over ZERO checks has told you nothing at all —
    # tests/tutorial/run_tutorial.gd carries the case in its own comments:
    # `TESTS PASSED — 0 checks` against a tree the suite never looked at. Only
    # fires when the suite prints a count, so a suite that reports differently
    # is not failed for its formatting.
    if grep -qE '(^|[^0-9])0 (checks?|assertions?|cases?)\b' "$log"; then
      SUITE_CODE=1
      SUITE_NOTE="printed a PASSING verdict over 0 checks — a suite that asks nothing cannot answer anything"
    fi
  fi
  return 0
}

# HOW MANY TIMES A FAILING SUITE IS READ BEFORE THE FAILURE IS BELIEVED.
#
# Four gate stages move run to run with no code change. Six readings of one of
# them on the same runner: 9410 · 9913 · 10442 · 11427 · 12177 · 16215 µs against
# a floor of 9000 — a 72 % spread, wider than the gap to the floor. A stage that
# trips on one reading in six is not measuring the code, and a gate that is red
# for reasons unrelated to the code gets ignored exactly like one that is never
# red. This does not decide whether that suite passes — its threshold belongs to
# the part that owns it — but it does say, in the summary, which kind of red it
# is. Costs nothing on a green run: only a FAILING suite is read again.
FLAKE_RETRIES="${LCN_FLAKE_RETRIES:-2}"

DEFERRED_FRAME_SUITES=""
STANDALONE="$("$GODOT" --headless --path "$ROOT" --script tests/run_tests.gd -- --list-standalone 2>/dev/null | grep '^res://' || true)"
if [ -n "$STANDALONE" ]; then
  say ""
  say "== standalone suites =="
  while IFS= read -r suite; do
    [ -z "$suite" ] && continue
    rel="${suite#res://}"
    if [ "$(suite_reads "$rel")" = "visual-run" ]; then
      DEFERRED_FRAME_SUITES="$DEFERRED_FRAME_SUITES$rel
"
      continue
    fi
    log="$LOGDIR/standalone_$(echo "$rel" | tr '/' '_').log"
    suite_attempt "$rel" "$log"
    code=$SUITE_CODE
    note=$SUITE_NOTE
    if [ "$code" -eq 2 ]; then
      record_skip "$rel" "$note" "standalone suites"
      continue
    fi
    if [ "$code" -ne 0 ] && [ "$FLAKE_RETRIES" -gt 0 ]; then
      # Re-reads go to a file the engine-error scan does not glob (*.log), so
      # one flaky suite cannot triple its own error counts.
      attempts=1
      fails=1
      while [ "$attempts" -le "$FLAKE_RETRIES" ]; do
        attempts=$((attempts + 1))
        suite_attempt "$rel" "$log.reread$attempts"
        [ "$SUITE_CODE" -ne 0 ] && fails=$((fails + 1))
      done
      if [ "$fails" -lt "$attempts" ]; then
        note="FLAPPING: failed $fails of $attempts identical reads — noise or an intermittent defect, NOT a reproducible regression. $note"
      else
        note="$note  [reproducible: $fails of $attempts reads]"
      fi
    fi
    record "$rel" "$log" "$code" "$note" "standalone suites"
  done <<< "$STANDALONE"
fi

# --- 5. determinism replay -------------------------------------------------
if [ "$RUN_DETERMINISM" -eq 1 ]; then
  say ""
  say "== determinism =="
  tools/determinism.sh > "$LOGDIR/determinism.log" 2>&1
  det_code=$?
  [ "$QUIET" -eq 0 ] && grep -E '^(--|determinism:|DETERMINISM)' "$LOGDIR/determinism.log" | sed 's/^/  /'
  record "determinism replay" "$LOGDIR/determinism.log" "$det_code" "same seed, two processes, identical state"
fi

# --- 6. performance gate ---------------------------------------------------
if [ "$RUN_PERF" -eq 1 ]; then
  say ""
  say "== perf =="
  tools/perf.sh > "$LOGDIR/perf.log" 2>&1
  perf_code=$?
  [ "$QUIET" -eq 0 ] && sed -n '/^ scenario /,$p' "$LOGDIR/perf.log" | sed 's/^/  /'
  # The one-line note carries the SPREAD, not a single number. A reader looking
  # at a red perf stage has to be able to tell in one glance whether it is real,
  # and "stress_1000 at 79 ticks/s" could never tell them: six readings of the
  # same test on the same runner spanned 72 % with no code change.
  perf_note="$("$PY" - <<'PY' 2>/dev/null || true
import json
try:
    d = json.load(open("artifacts/perf.json"))
except Exception:
    raise SystemExit
rows = d.get("scenarios") or []
bad = [g for g in rows if g.get("status") in ("regressed", "error")]
noisy = [g for g in rows if g.get("status") == "noisy"]
def one(g):
    return "%s median %.0f/s (%.0f..%.0f, %.0f%% spread, floor %.0f, %d reading%s)" % (
        g.get("scenario", "?"), g.get("median_ticks_per_second", 0),
        g.get("min_ticks_per_second", 0), g.get("max_ticks_per_second", 0),
        g.get("spread_percent", 0), g.get("floor_ticks_per_second", 0),
        g.get("readings", 0), "" if g.get("readings") == 1 else "s")
if bad:
    print("REGRESSION: " + "; ".join(one(g) for g in bad))
elif noisy:
    print("noise, not a regression: " + "; ".join(one(g) for g in noisy))
elif rows:
    print("; ".join(one(g) for g in rows))
PY
)"
  record "perf gate" "$LOGDIR/perf.log" "$perf_code" "$perf_note"
fi

# --- 7. engine errors ------------------------------------------------------
# Godot writes ERROR: / SCRIPT ERROR: / USER ERROR: to stderr and never touches
# game/core/log.gd, so Log.errors — the number the harness gates on — counted
# none of them. Every stage above already redirects 2>&1 into its own log; this
# reads all of them at once. tools/error_allowlist.txt is the only escape, and
# an entry there needs an owner, a justification and an expiry date.
say ""
say "== engine errors =="
ERR_LOGS=("$LOGDIR"/*.log)
"$PY" tools/scan_errors.py "${ERR_LOGS[@]}" --label "engine errors across every stage" \
    --json artifacts/engine_errors.json > "$LOGDIR/errors.report" 2>&1
err_code=$?
[ "$QUIET" -eq 0 ] && sed 's/^/  /' "$LOGDIR/errors.report"
err_note="$("$PY" - <<'PY' 2>/dev/null || true
import json
try:
    d = json.load(open("artifacts/engine_errors.json"))
except Exception:
    raise SystemExit
b = sum(x["count"] for x in d["blocking"])
k = sum(x["count"] for x in d["tracked"])
if b:
    top = d["blocking"][0]
    print("%d blocking (worst: x%d %s %s)" % (b, top["count"], top["message"][:60], top["blame"]))
else:
    print("none blocking, %d known" % k)
PY
)"
record "engine errors" "$LOGDIR/errors.report" "$err_code" "$err_note"

# --- 8. the gate: reachability, scenario contracts, the visual run ---------
if [ "$RUN_GATE" -eq 1 ]; then
  say ""
  say "== gate =="
  # The summary lands in THIS check's private log dir, never in the shared
  # artifacts/gate/: nine other agents run this same script, and reading a
  # summary file another process is rewriting is how a stage silently loses
  # half its rows.
  tools/gate.sh $GATE_ARGS --out=artifacts/gate --summary="$LOGDIR/gate.summary" \
      > "$LOGDIR/gate.log" 2>&1
  [ "$QUIET" -eq 0 ] && sed -n '/── /,$p' "$LOGDIR/gate.log" | grep -vE '^ *(ok|$)' | sed 's/^/  /'
  if [ -s "$LOGDIR/gate.summary" ]; then
    while IFS='|' read -r gname gstatus gdetail; do
      [ -z "$gname" ] && continue
      case "$gstatus" in
        pass) record "$gname" /dev/null 0 "$gdetail" "gate" ;;
        SKIP) record_skip "$gname" "$gdetail" "gate" ;;
        *)    record "$gname" /dev/null 1 "$gdetail" "gate" ;;
      esac
    done < "$LOGDIR/gate.summary"
  else
    record "gate" "$LOGDIR/gate.log" 1 "produced no summary — it did not run"
  fi
else
  record_skip "gate" "reachability, scenario contracts and the visual run were all skipped" "gate"
fi

# --- 9. the suites that grade the frames the gate just photographed --------
#
# Deferred out of stage 5 by `suite_reads`. LCN_FRAME_DIR is exported, and these
# suites read it as "grade THIS run or report UNCHECKED" — never as a hint they
# may improve on by looking elsewhere. A suite that reports PARTIAL here is
# telling the truth about the gate: the run it was given does not carry the
# beats it measures. That is a SKIP in the summary, and it is strictly better
# than the pass it used to report off another folder.
if [ -n "$DEFERRED_FRAME_SUITES" ]; then
  say ""
  say "== frame suites (graded against the gate's own visual run) =="
  vis_dir="artifacts/gate/visual"
  # A visual run that THIS check did not make is not this check's evidence.
  # Under --no-gate / --no-visual the folder may still be on disk from an
  # earlier invocation, and grading it would report a verdict about a build
  # that is not the one in the tree — the same mistake, one folder to the left,
  # that deferring these suites exists to stop.
  if [ "$RUN_GATE" -eq 0 ] || [ ! -f "$vis_dir/log.txt" ]; then
    reason="the gate wrote no visual run to grade ($vis_dir)"
    [ "$RUN_GATE" -eq 0 ] && reason="the gate was skipped, so there is no visual run from THIS check to grade"
    while IFS= read -r rel; do
      [ -z "$rel" ] && continue
      record_skip "$rel" "$reason" "frame suites"
    done <<< "$DEFERRED_FRAME_SUITES"
  else
    while IFS= read -r rel; do
      [ -z "$rel" ] && continue
      log="$LOGDIR/frame_$(echo "$rel" | tr '/' '_').log"
      # `export`, not a `VAR=x suite_attempt ...` prefix: suite_attempt is a
      # FUNCTION, and a prefix assignment on a function call does not reach the
      # Godot process the function starts. tools/gate.sh carries the same note
      # over its own xvfb call, having been bitten by it once already.
      export LCN_FRAME_DIR="$vis_dir"
      suite_attempt "$rel" "$log"
      unset LCN_FRAME_DIR
      if [ "$SUITE_CODE" -eq 2 ]; then
        record_skip "$rel" "$SUITE_NOTE" "frame suites"
      else
        record "$rel" "$log" "$SUITE_CODE" "$SUITE_NOTE" "frame suites"
      fi
    done <<< "$DEFERRED_FRAME_SUITES"
  fi
fi

# --- summary ---------------------------------------------------------------
# One screen. Failures and unchecked stages in full, passes collapsed by group,
# and a verdict that cannot be read more generously than the evidence.
echo ""
echo "────────────────────────────────────────────────────────────────────────"
printf ' %-22s %s\n' "checked" "${#STAGES[@]} stages"
n_fail=0; n_skip=0
for i in "${!STAGES[@]}"; do
  [ "${RESULTS[$i]}" = "FAIL" ] && n_fail=$((n_fail + 1))
  [ "${RESULTS[$i]}" = "SKIP" ] && n_skip=$((n_skip + 1))
done
printf ' %-22s %s\n' "failing" "$n_fail"
printf ' %-22s %s\n' "not checked" "$n_skip"
echo ""
for i in "${!STAGES[@]}"; do
  case "${RESULTS[$i]}" in
    FAIL) printf ' FAIL  %-30s %s\n' "${STAGES[$i]}" "${DETAILS[$i]}" ;;
    SKIP) printf ' SKIP  %-30s %s\n' "${STAGES[$i]}" "${DETAILS[$i]}" ;;
  esac
done
[ "$n_fail" -eq 0 ] && [ "$n_skip" -eq 0 ] && echo " nothing failed and nothing was skipped"
echo ""
printf ' passed:'
prev=""
for i in "${!STAGES[@]}"; do
  [ "${RESULTS[$i]}" != "pass" ] && continue
  g="${STAGE_GROUP[$i]}"
  if [ "$g" != "$prev" ]; then
    printf ' %s' "$g"
    prev="$g"
  fi
done
echo ""
echo "────────────────────────────────────────────────────────────────────────"

if [ "$fail" -ne 0 ]; then
  echo "CHECK RED — $n_fail failing"
elif [ "$n_skip" -ne 0 ]; then
  echo "CHECK GREEN, PARTIAL — $n_skip stage(s) were never checked. Not the same as green."
else
  echo "CHECK GREEN"
fi
exit $fail
