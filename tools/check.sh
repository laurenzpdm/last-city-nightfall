#!/usr/bin/env bash
# THE GATE. One command, one answer, one exit code.
#
#   tools/check.sh              # import + parse + lint + tests + determinism + perf
#   tools/check.sh --fast       # skip determinism and perf (pre-commit loop)
#   tools/check.sh --no-perf    # everything but the perf gate
#   tools/check.sh --quiet      # only the summary and the failures
#
# Every stage runs even when an earlier one fails: a builder wants the whole
# list of what is wrong, not the first item on it.
#
# Exit code 0 means the build is green and a critic can be handed the artifacts.
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
GROUPS=()       # for the one-screen summary: pass lines collapse per group
fail=0
skipped=0

# stage <name> <logfile> <exit code> [detail] [group]
record() {
  STAGES+=("$1")
  DETAILS+=("${4:-}")
  GROUPS+=("${5:-$1}")
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
  GROUPS+=("${3:-$1}")
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
"$GODOT" --headless --path "$ROOT" --script tests/run_tests.gd > "$LOGDIR/tests.log" 2>&1
tests_code=$?
grep -q "TESTS FAILED" "$LOGDIR/tests.log" && tests_code=1
if [ "$QUIET" -eq 0 ]; then
  # The engine's own ERROR/WARNING lines are filtered OUT of this listing on
  # purpose — but only because tools/scan_errors.py now reads the same log and
  # gates on them further down. Before that stage existed, this filter was the
  # single line of shell that hid 70 engine errors per run from every human who
  # ever read this output.
  sed -n '/^─/,$p' "$LOGDIR/tests.log" | grep -vE '^(WARNING|ERROR|\s+at:)' | sed 's/^/  /'
fi
tests_note="$(grep -m1 '^ tests ' "$LOGDIR/tests.log" | sed 's/^ tests  *//')"
record "tests" "$LOGDIR/tests.log" "$tests_code" "$tests_note"

# --- 4b. suites that brought their own entry point -------------------------
STANDALONE="$("$GODOT" --headless --path "$ROOT" --script tests/run_tests.gd -- --list-standalone 2>/dev/null | grep '^res://' || true)"
if [ -n "$STANDALONE" ]; then
  say ""
  say "== standalone suites =="
  while IFS= read -r suite; do
    [ -z "$suite" ] && continue
    rel="${suite#res://}"
    log="$LOGDIR/standalone_$(echo "$rel" | tr '/' '_').log"
    # A .tscn is run AS A SCENE. Godot compiles a --script file before it
    # registers the autoloads, so a Node-based suite launched that way dies on
    # `Identifier not found: Log`, prints nothing and exits 0 — which is exactly
    # how 371 build assertions were reported green while never executing.
    # A suite that never exits is worse than one that fails: without this the
    # gate blocks forever and every other agent's check.sh queues behind it.
    if [ "${rel##*.}" = "tscn" ]; then
      $TIMEOUT "$GODOT" --headless --path "$ROOT" "res://$rel" > "$log" 2>&1
    else
      $TIMEOUT "$GODOT" --headless --path "$ROOT" --script "$rel" > "$log" 2>&1
    fi
    code=$?
    note=""
    if [ "$code" -eq 124 ]; then
      note="hung — killed after ${SUITE_TIMEOUT}s"
      record "$rel" "$log" 1 "$note"
      continue
    fi
    if grep -q "TESTS FAILED" "$log"; then
      code=1
      note="$(grep -m1 -oE '[0-9]+ (passed|checks).*' "$log" || true)"
    elif ! grep -q "TESTS PASSED" "$log"; then
      # No verdict at all means the suite never ran. Silence is not success.
      code=1
      note="printed no TESTS PASSED / TESTS FAILED verdict — did it run at all?"
    else
      note="$(grep -m1 -oE '[0-9]+ (passed|checks)[^,]*' "$log" || true)"
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
  [ "$QUIET" -eq 0 ] && sed -n '/scenario  *ticks/,$p' "$LOGDIR/perf.log" | sed 's/^/  /'
  perf_note="$(grep -m1 -E '^ [a-z_0-9]+ +[0-9]+ ' "$LOGDIR/perf.log" | awk '{printf "%s at %s ticks/s", $1, $4}')"
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
  tools/gate.sh $GATE_ARGS --out=artifacts/gate > "$LOGDIR/gate.log" 2>&1
  [ "$QUIET" -eq 0 ] && sed -n '/── /,$p' "$LOGDIR/gate.log" | grep -vE '^ *(ok|$)' | sed 's/^/  /'
  if [ -s artifacts/gate/summary.txt ]; then
    while IFS='|' read -r gname gstatus gdetail; do
      [ -z "$gname" ] && continue
      case "$gstatus" in
        pass) record "$gname" /dev/null 0 "$gdetail" "gate" ;;
        SKIP) record_skip "$gname" "$gdetail" "gate" ;;
        *)    record "$gname" /dev/null 1 "$gdetail" "gate" ;;
      esac
    done < artifacts/gate/summary.txt
  else
    record "gate" "$LOGDIR/gate.log" 1 "produced no summary — it did not run"
  fi
else
  record_skip "gate" "reachability, scenario contracts and the visual run were all skipped" "gate"
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
  g="${GROUPS[$i]}"
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
