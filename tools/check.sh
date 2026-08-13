#!/usr/bin/env bash
# Green gate: parse every script, run the test suite, verify determinism.
set -uo pipefail
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
fail=0

echo "== import =="
"$GODOT" --headless --path "$ROOT" --import >/tmp/lcn_import.log 2>&1
grep -E "SCRIPT ERROR|Parse Error|Failed to load" /tmp/lcn_import.log && { echo "IMPORT ERRORS"; fail=1; }

echo "== parse check =="
out=$("$GODOT" --headless --path "$ROOT" --check-only --script game/boot.gd 2>&1)
echo "$out" | grep -qE "Error|error" && { echo "$out"; fail=1; }

echo "== tests =="
if [ -f tests/run_tests.gd ]; then
  "$GODOT" --headless --path "$ROOT" --script tests/run_tests.gd 2>&1 | tee /tmp/lcn_tests.log
  grep -q "TESTS FAILED" /tmp/lcn_tests.log && fail=1
else
  echo "(no test runner yet)"
fi

echo "== determinism =="
if [ -f tests/scenarios/smoke.json ]; then
  tools/run_sim.sh --scenario=smoke --out=artifacts/_det_a >/dev/null 2>&1
  tools/run_sim.sh --scenario=smoke --out=artifacts/_det_b >/dev/null 2>&1
  if [ -f artifacts/_det_a/state.json ] && [ -f artifacts/_det_b/state.json ]; then
    a=$(shasum artifacts/_det_a/state.json | cut -d' ' -f1)
    b=$(shasum artifacts/_det_b/state.json | cut -d' ' -f1)
    if [ "$a" != "$b" ]; then echo "DETERMINISM BROKEN"; fail=1; else echo "deterministic OK"; fi
  fi
fi

[ $fail -eq 0 ] && echo "CHECK GREEN" || echo "CHECK RED"
exit $fail
