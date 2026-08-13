#!/usr/bin/env bash
# Real window, real rendering, auto-driven. Writes PNGs to <out>/shots/.
#
#   tools/run_visual.sh --scenario=first_night --out=artifacts/vis
#   tools/run_visual.sh --scenario=first_night --shots=opening,build,dusk,assault,dawn
#
# Shot beats come from the scenario's `shots` array; --shots is accepted and
# passed through for callers that want to name them on the command line.
# Flags are otherwise identical to tools/run_sim.sh.
set -uo pipefail
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ ! -x "$GODOT" ]; then
  echo "run_visual: no Godot at $GODOT (set GODOT=/path/to/Godot)" >&2
  exit 2
fi

mkdir -p "$ROOT/artifacts" && : > "$ROOT/artifacts/.gdignore"

"$GODOT" --path "$ROOT" --resolution 1920x1080 -- --harness --visual "$@"
