#!/usr/bin/env bash
# Deterministic headless run. No renderer. Fast. For balance / regression / perf.
# usage: tools/run_sim.sh --scenario=first_night --ticks=12000 --seed=7 --out=artifacts/run_a
set -uo pipefail
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$GODOT" --headless --path "$ROOT" --quit-after 100000 -- --harness "$@"
