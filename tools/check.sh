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
QUIET=0
for arg in "$@"; do
  case "$arg" in
    --fast)    RUN_DETERMINISM=0; RUN_PERF=0 ;;
    --no-perf) RUN_PERF=0 ;;
    --no-determinism) RUN_DETERMINISM=0 ;;
    --quiet)   QUIET=1 ;;
    *) echo "check: unknown option $arg"; exit 2 ;;
  esac
done

if [ ! -x "$GODOT" ]; then
  echo "check: no Godot at $GODOT (set GODOT=/path/to/Godot)"
  exit 2
fi

LOGDIR="$(mktemp -d "${TMPDIR:-/tmp}/lcn_check.XXXXXX")"
trap 'rm -rf "$LOGDIR"' EXIT
mkdir -p artifacts && : > artifacts/.gdignore   # keep the editor from importing run output

STAGES=()
RESULTS=()
DETAILS=()
fail=0

# stage <name> <logfile> <exit code> [detail]
record() {
  STAGES+=("$1")
  RESULTS+=("$3")
  DETAILS+=("${4:-}")
  if [ "$3" -ne 0 ]; then
    fail=1
    echo "  ✗ $1${4:+ — $4}"
    [ -s "$2" ] && tail -40 "$2" | sed 's/^/      /'
  else
    echo "  ✓ $1${4:+ — $4}"
  fi
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
    "$GODOT" --headless --path "$ROOT" --script "$rel" > "$log" 2>&1
    code=$?
    grep -q "TESTS FAILED" "$log" && code=1
    record "$rel" "$log" "$code"
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

# --- summary ---------------------------------------------------------------
echo ""
echo "────────────────────────────────────────────────────────────────────────"
for i in "${!STAGES[@]}"; do
  if [ "${RESULTS[$i]}" -eq 0 ]; then
    printf ' %-28s pass\n' "${STAGES[$i]}"
  else
    printf ' %-28s FAIL   %s\n' "${STAGES[$i]}" "${DETAILS[$i]}"
  fi
done
echo "────────────────────────────────────────────────────────────────────────"

if [ "$fail" -eq 0 ]; then
  echo "CHECK GREEN"
else
  echo "CHECK RED"
fi
exit $fail
