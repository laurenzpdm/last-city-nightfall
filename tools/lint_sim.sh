#!/usr/bin/env bash
# Determinism lint. Greps game/sim/** for the things §3 of docs/ARCHITECTURE.md
# forbids, because a determinism failure found by grep costs a second and the
# same failure found by a replay diff costs an afternoon.
#
#   tools/lint_sim.sh                 # lint game/sim/**
#   tools/lint_sim.sh game/sim/heat   # one part
#   tools/lint_sim.sh --strict        # advisories fail too
#
# Two severities, because a grep cannot prove intent:
#
#   FATAL     nothing in a deterministic simulation can legitimately do this —
#             raw randf(), reading input or user settings, touching the scene
#             tree, running off an engine frame callback.
#   ADVISORY  legitimate in narrow cases (a profiling timer, a debug print) and
#             harmless as long as the value never reaches serialize(). Whether
#             it does is settled dynamically by tools/determinism.sh, which is
#             a stronger check than any grep.
#
# A line may opt out with a trailing `# lint:allow` — rare, and the comment is
# the argument for why.
#
# Exit codes: 0 clean, 1 fatal violations (or any violation under --strict).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

STRICT=0
TARGET="game/sim"
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=1 ;;
    --*) echo "sim lint: unknown option $arg"; exit 2 ;;
    *) TARGET="$arg" ;;
  esac
done

if [ ! -d "$TARGET" ]; then
  echo "sim lint: nothing at $TARGET yet"
  exit 0
fi

fatal=0
advisory=0

# rule <FATAL|ADVISORY> <name> <extended-regex> <why>
rule() {
  local severity="$1" name="$2" pattern="$3" why="$4"
  local hits
  hits="$(grep -rnE --include='*.gd' "$pattern" "$TARGET" 2>/dev/null \
          | grep -v 'lint:allow' \
          | grep -vE ':[0-9]+:[[:space:]]*#' || true)"
  [ -z "$hits" ] && return 0
  echo ""
  if [ "$severity" = "FATAL" ]; then
    echo "  ✗ $name — $why"
    fatal=$((fatal + 1))
  else
    echo "  ! $name — $why"
    advisory=$((advisory + 1))
  fi
  echo "$hits" | sed 's/^/      /'
}

echo "== sim lint ($TARGET) =="

rule FATAL "raw randomness" \
     '(^|[^A-Za-z0-9_.])(randf|randi|randf_range|randi_range|randfn|randomize)[[:space:]]*\(' \
     "use Rng.stream(\"name\"); a bare randf() is not replayable"

rule FATAL "engine frame callbacks" \
     'func[[:space:]]+_(process|physics_process|input|unhandled_input|draw)[[:space:]]*\(' \
     "a SimSystem advances through step(tick), never through an engine callback"

rule FATAL "input" \
     '(^|[^A-Za-z0-9_.])Input(Event|Map)?[[:space:]]*\.' \
     "input belongs in view/ and ui/; the sim only sees Sim.submit_command"

rule FATAL "user settings" \
     '(^|[^A-Za-z0-9_.])Settings[[:space:]]*\.' \
     "Settings is per-user config — reading it makes one seed diverge between players"

rule FATAL "reaching into the scene tree" \
     '(res://game/view|res://game/ui|get_tree\(\)|get_viewport\(\))' \
     "the sim never looks at the scene tree; talk through Bus signals"

rule FATAL "frame await" \
     'await[[:space:]]+(get_tree|RenderingServer|[A-Za-z_.]*process_frame|[A-Za-z_.]*frame_post_draw)' \
     "awaiting a frame ties simulation state to frame rate"

rule ADVISORY "wall clock" \
     '(Time\.get_ticks_|Time\.get_unix_time|OS\.get_ticks|Time\.get_datetime)' \
     "fine for a profiling counter, fatal the moment it reaches serialize(); tools/determinism.sh decides"

rule ADVISORY "frame time" \
     '(get_process_delta_time|get_physics_process_delta_time|Engine\.get_frames_|Engine\.get_process_frames)' \
     "the sim runs on a fixed tick; use SimClock.DT for integration"

rule ADVISORY "print" \
     '(^|[^A-Za-z0-9_.])(print|print_rich|printt|prints|print_debug)[[:space:]]*\(' \
     "use Log.info/warn/error so the harness can capture it"

echo ""
if [ "$fatal" -eq 0 ] && [ "$advisory" -eq 0 ]; then
  echo "sim lint: clean"
  exit 0
fi
echo "sim lint: $fatal fatal, $advisory advisory"
echo "See docs/ARCHITECTURE.md §3. If a hit is genuinely fine, append '# lint:allow' and say why."
if [ "$fatal" -gt 0 ] || { [ "$STRICT" -eq 1 ] && [ "$advisory" -gt 0 ]; }; then
  exit 1
fi
exit 0
