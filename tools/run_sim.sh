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

"$GODOT" --headless --path "$ROOT" --quit-after 100000 -- --harness "$@"
