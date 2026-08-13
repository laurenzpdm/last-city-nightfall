#!/usr/bin/env bash
# Real window, real rendering, auto-driven. Writes PNGs to <out>/shots/.
# usage: tools/run_visual.sh --scenario=first_night --out=artifacts/vis
set -uo pipefail
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$GODOT" --path "$ROOT" --resolution 1920x1080 -- --harness --visual "$@"
