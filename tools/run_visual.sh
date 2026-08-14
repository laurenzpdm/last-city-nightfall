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

# A visual run is the ONLY place the UI code executes, and it is where every
# engine error this build has ever printed came from: 68 String formatting
# errors and one refused add_child() in a single 30 second pass, all of them
# invisible to Log.errors and therefore to the harness's exit code.
# LCN_NO_ERROR_GATE=1 opts out.
LOG="$(mktemp "${TMPDIR:-/tmp}/lcn_run_visual.XXXXXX")"
# `--audio-driver Dummy`: a build machine has no sound card, and ALSA's failure
# to open one prints `ERROR: Condition "status < 0" is true` from
# drivers/alsa/audio_driver_alsa.cpp before a single line of this project runs.
# That is engine noise about the machine, not about the build, and the one thing
# the error gate must not learn is to ignore errors. [P23] still installs its
# buses and streams; only the output device is a null sink. `tests/audio/` keeps
# the real driver, so a genuine audio regression still has somewhere to show up.
LCN_AUDIO_DRIVER="${LCN_AUDIO_DRIVER:-Dummy}"
"$GODOT" --audio-driver "$LCN_AUDIO_DRIVER" --path "$ROOT" --resolution 1920x1080 \
    -- --harness --visual "$@" 2>"$LOG"
code=$?
cat "$LOG" >&2   # replayed, not tee'd: a process substitution can still be
                 # writing when the scan below reads the file, and a gate that
                 # races the stream it grades is a gate that misses errors.
if [ "${LCN_NO_ERROR_GATE:-0}" != "1" ]; then
  if ! "${PYTHON:-python3}" "$ROOT/tools/scan_errors.py" "$LOG" --label "engine errors (run_visual)"; then
    echo "run_visual: the run exited $code but the engine printed errors — see above" >&2
    [ "$code" -eq 0 ] && code=3
  fi
fi
rm -f "$LOG"
exit $code
