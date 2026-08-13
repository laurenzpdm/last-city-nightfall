#!/usr/bin/env bash
# Deterministic headless run. No renderer. Fast. For balance / regression / perf.
#
#   tools/run_sim.sh --scenario=first_night --ticks=12000 --seed=7 --out=artifacts/run_a
#
# Every flag is passed straight through to game/core/harness.gd:
#   --scenario=<name|res://path>   tests/scenarios/<name>.json
#   --ticks=<n>                    override the scenario's tick count
#   --seed=<n>                     override the scenario's seed
#   --out=<dir>                    where state.json / metrics.csv / log.txt land
#   --sample=<n>                   ticks between metrics.csv rows
#
# Exit code is the harness's: non-zero when the run raised a severity>=2 alert.
set -uo pipefail
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ ! -x "$GODOT" ]; then
  echo "run_sim: no Godot at $GODOT (set GODOT=/path/to/Godot)" >&2
  exit 2
fi

# Run output is data, not content: keep the editor from importing CSVs as
# translations and PNGs as textures on the next --import.
mkdir -p "$ROOT/artifacts" && : > "$ROOT/artifacts/.gdignore"

# stderr is captured and classified, not just forwarded. game/core/harness.gd
# gates the run on Log.errors, which counts calls to game/core/log.gd and
# nothing else — every `ERROR:` and `SCRIPT ERROR:` Godot itself prints was
# invisible to it. Set LCN_NO_ERROR_GATE=1 to keep the old behaviour (tools that
# do their own scanning use it so the same errors are not reported twice).
LOG="$(mktemp "${TMPDIR:-/tmp}/lcn_run_sim.XXXXXX")"
"$GODOT" --headless --path "$ROOT" --quit-after 100000 -- --harness "$@" 2>"$LOG"
code=$?
cat "$LOG" >&2   # replayed, not tee'd: a process substitution can still be
                 # writing when the scan below reads the file, and a gate that
                 # races the stream it grades is a gate that misses errors.
if [ "${LCN_NO_ERROR_GATE:-0}" != "1" ]; then
  if ! "${PYTHON:-python3}" "$ROOT/tools/scan_errors.py" "$LOG" --label "engine errors (run_sim)" --quiet; then
    echo "run_sim: the run exited $code but the engine printed errors — see above" >&2
    [ "$code" -eq 0 ] && code=3
  fi
fi
rm -f "$LOG"
exit $code
