class_name LcnTiming
extends RefCounted
## THE TIMING VOCABULARY. [P15] Feel & Juice.
##
## Seven durations, named, for the whole game. If every part invents its own
## 0.25 the build ends up feeling like eleven different hands made it, because
## that is exactly what happened. Pick the word, not the number:
##
##   FLICK   0.06s  the cursor is acknowledged. Hover tint, key-down state.
##   SNAP    0.12s  a decision lands. Button press, snap-to-grid, tab change.
##   QUICK   0.20s  a small thing appears. Tooltip, toast, badge, icon swap.
##   SETTLE  0.32s  a physical thing arrives. A building lands, a panel opens.
##   HEAVY   0.55s  something large and consequential. Demolition, a law signed.
##   SWELL   0.90s  a value travels. A number counts up, a bar fills, a meter moves.
##   EVENT   2.60s  the world changes. Nightfall, a wave arriving, the hearth dying.
##
## The rule of thumb behind the ladder: anything the player CAUSED must be
## visibly under way within FLICK and finished by SETTLE, or the game feels like
## it is thinking. Anything the WORLD caused may take as long as EVENT, because
## the player needs time to notice it and time to feel it.
##
## Two multipliers ride on top, and both come from [P24]'s settings:
##   * `accessibility.reduce_motion` collapses travel to a cut (scale 0) for
##     anything decorative and to SNAP for anything that carries meaning.
##   * `graphics.screen_shake` scales every camera impulse, 0 silences it.
##
## Everything here is static and cheap. Call it per frame without thinking.

# --- the ladder ---------------------------------------------------------------

const FLICK: float = 0.06
const SNAP: float = 0.12
const QUICK: float = 0.20
const SETTLE: float = 0.32
const HEAVY: float = 0.55
const SWELL: float = 0.90
const EVENT: float = 2.60

## Names in ladder order, for documentation, tests and tooling.
const LADDER: Array[StringName] = [
	&"flick", &"snap", &"quick", &"settle", &"heavy", &"swell", &"event",
]

## The paired curve for each rung. A duration without its curve is half a
## decision, and this is the half parts kept getting wrong.
const LADDER_CURVE: Array[int] = [
	LcnEase.Kind.QUART_OUT,     # flick   — arrive fast, stop hard
	LcnEase.Kind.EXPO_OUT,      # snap    — practically instant, with a tail
	LcnEase.Kind.CUBIC_OUT,     # quick   — the everyday deceleration
	LcnEase.Kind.SETTLE,        # settle  — one small bounce, then still
	LcnEase.Kind.CUBIC_IN_OUT,  # heavy   — mass has to accelerate too
	LcnEase.Kind.QUART_OUT,     # swell   — a value should rush then ease in
	LcnEase.Kind.SINE_IN_OUT,   # event   — no edges at all; the world is turning
]

## Delay between successive items in a staggered group (a row of icons, a line
## of pipes being placed). Long enough to read as a sequence, short enough that
## a whole group plus its own SETTLE still lands inside SWELL — a stagger the
## player has to wait out is a stagger that has stopped being a flourish.
const STAGGER: float = 0.022
const STAGGER_MAX: int = 8

## The longest an effect may live regardless of what it asks for. A juice layer
## that leaks a ten-second particle is a juice layer that eventually costs a
## frame, so the spawn path clamps against this.
const MAX_EFFECT_LIFE: float = 3.2


# --- lookups ------------------------------------------------------------------

## Duration for a rung name. Unknown names get QUICK rather than 0, because a
## typo should look slightly wrong, not invisible.
static func duration(rung: StringName) -> float:
	match rung:
		&"flick": return FLICK
		&"snap": return SNAP
		&"quick": return QUICK
		&"settle": return SETTLE
		&"heavy": return HEAVY
		&"swell": return SWELL
		&"event": return EVENT
	return QUICK


## The curve that belongs with a rung.
static func curve(rung: StringName) -> LcnEase.Kind:
	var i: int = LADDER.find(rung)
	return LADDER_CURVE[i] if i >= 0 else LcnEase.Kind.CUBIC_OUT


## Delay for the n-th item of a staggered group.
static func stagger(index: int) -> float:
	return float(clampi(index, 0, STAGGER_MAX)) * STAGGER


# --- accessibility -------------------------------------------------------------

## 1.0 normally, 0.0 when the player asked for reduced motion. Multiply any
## DECORATIVE travel by this: a dust puff, an overshoot, a screen sweep.
static func motion_scale() -> float:
	return 0.0 if reduce_motion() else 1.0


## Duration for motion that CARRIES MEANING and therefore may not be deleted,
## only shortened — a panel still has to be seen to open, or the player loses
## the causal link between the click and the panel.
static func meaningful(seconds: float) -> float:
	if reduce_motion():
		return minf(seconds, SNAP)
	return seconds


## Duration for motion that is pure decoration. Zero under reduce_motion.
static func decorative(seconds: float) -> float:
	return 0.0 if reduce_motion() else seconds


static func reduce_motion() -> bool:
	if not is_instance_valid(Settings):
		return false
	return bool((Settings.accessibility as Dictionary).get("reduce_motion", false))


## Player's shake preference, 0..1+. Camera impulses are multiplied by this AND
## by reduce_motion, so there are two independent ways to switch shake off.
static func shake_scale() -> float:
	if reduce_motion():
		return 0.0
	if not is_instance_valid(Settings):
		return 1.0
	return maxf(0.0, float((Settings.graphics as Dictionary).get("screen_shake", 1.0)))


## Whether hit-stop is allowed. Separate from shake because some players are
## fine with a shaking camera and hate a stuttering one.
static func hit_stop_enabled() -> bool:
	if reduce_motion():
		return false
	if not is_instance_valid(Settings):
		return true
	return bool((Settings.graphics as Dictionary).get("hit_stop", true))


# --- the two clocks -------------------------------------------------------------

## WORLD TIME. Effects that belong to a simulated event — dust from a placement,
## sparks from a hit, an ember from a death — age on this. It stops when the
## player pauses (a paused world holds its breath, which is correct) and runs
## triple at 3x (the world really is moving faster).
static func world_now() -> float:
	return SimClock.seconds() if is_instance_valid(SimClock) else 0.0


## INTERFACE TIME. Everything the cursor drives — hover, selection, tooltips,
## panels — ages on this instead, because a paused game must still respond to
## the hand holding the mouse. Advanced by the feel root once per frame.
static var ui_now: float = 0.0


## Advances interface time. Called once per frame by LcnFeel and nothing else.
## Clamped: after a stall (a shot in the harness, a window drag, a load) the
## frame delta can be seconds, and every tween in the game would jump to its end.
static func advance_ui(delta: float) -> float:
	var dt: float = clampf(delta, 0.0, 0.1)
	ui_now += dt
	return dt
