class_name LcnEase
extends RefCounted
## The curve library. [P15] Feel & Juice.
##
## Nothing in this game moves linearly. A linear tween is the tell that a
## programmer moved something instead of a hand: it starts at full speed, stops
## at full speed, and the eye reads it as a slide rather than as a thing with
## mass. Every motion in the build picks a curve with an opinion in it, and this
## is the one place those opinions live, so the whole game eases the same way.
##
##     var k: float = LcnEase.apply(LcnEase.Kind.SETTLE, elapsed / duration)
##     node.position = a.lerp(b, k)
##
## There are two families here and mixing them up is the usual mistake.
##
## TRANSITIONS (LINEAR .. SMOOTHSTEP) take k in 0..1 and return 0 at 0 and 1 at
## 1. Several overshoot in between. That is the point — an overshoot is what
## makes a thing look like it *arrived* somewhere rather than *stopped*
## somewhere. Use them to move a value from A to B.
##
## ENVELOPES (IMPACT, PULSE, SPIKE) do not end where they started and are not
## interpolators. They describe the life of a thing that appears and goes away:
## IMPACT is 1 -> 0 (full on the first frame, then decay), PULSE is 0 -> 1 -> 0,
## SPIKE is a fast attack and a long tail. Use them for strength over lifetime.
##
## Pure math, no engine state, no randomness: a curve is testable and a visual
## regression run diffs cleanly.

enum Kind {
	LINEAR,         ## No opinion. For values that are not motion (a shader ramp, a colour mix).
	SINE_IN,
	SINE_OUT,       ## The gentlest deceleration there is. Ambient drift, breathing.
	SINE_IN_OUT,
	QUAD_IN,
	QUAD_OUT,
	QUAD_IN_OUT,
	CUBIC_IN,
	CUBIC_OUT,      ## The default "something moved and stopped" curve.
	CUBIC_IN_OUT,   ## The default "a panel travelled" curve.
	QUART_OUT,      ## Sharper stop than cubic. Cursor-speed feedback.
	EXPO_IN,
	EXPO_OUT,       ## Near-instant arrival with a long visual tail. Snaps.
	EXPO_IN_OUT,
	BACK_OUT,       ## Overshoots, then returns. The "it landed" curve.
	ANTICIPATE,     ## Pulls back before it goes. The "it is about to" curve.
	ELASTIC_OUT,    ## Springy. Use sparingly; too much of it reads as cartoon.
	BOUNCE_OUT,     ## Lands, bounces, lands. Physical weight, comic timing.
	SETTLE,         ## A heavy thing dropping into place: fast, one small bounce, done.
	IMPACT,         ## Instant to full, then a decaying fall. For flashes and hits.
	PULSE,          ## 0 -> 1 -> 0 across the whole span. For anything that blinks.
	SPIKE,          ## Sharp attack, long tail. Sparks, shake envelopes, embers.
	SMOOTHSTEP,     ## Symmetric S. For crossfades that must not favour either end.
}

## Overshoot constant for BACK_OUT / ANTICIPATE. 1.70158 is the classic Penner
## value (a ~10% overshoot); tuned down slightly here because a top-down grid
## makes overshoot more visible than it is in a side view.
const BACK_C: float = 1.42

## Number of enum entries. Kept as a constant so a test can walk every curve
## without depending on Kind.size() existing.
const KIND_COUNT: int = 23


## The dispatcher. `k` is clamped, so a caller that overshoots its own timer
## cannot make a curve return garbage.
static func apply(kind: Kind, k: float) -> float:
	var t: float = clampf(k, 0.0, 1.0)
	match kind:
		Kind.LINEAR: return t
		Kind.SINE_IN: return sine_in(t)
		Kind.SINE_OUT: return sine_out(t)
		Kind.SINE_IN_OUT: return sine_in_out(t)
		Kind.QUAD_IN: return t * t
		Kind.QUAD_OUT: return 1.0 - (1.0 - t) * (1.0 - t)
		Kind.QUAD_IN_OUT: return quad_in_out(t)
		Kind.CUBIC_IN: return t * t * t
		Kind.CUBIC_OUT: return cubic_out(t)
		Kind.CUBIC_IN_OUT: return cubic_in_out(t)
		Kind.QUART_OUT: return quart_out(t)
		Kind.EXPO_IN: return expo_in(t)
		Kind.EXPO_OUT: return expo_out(t)
		Kind.EXPO_IN_OUT: return expo_in_out(t)
		Kind.BACK_OUT: return back_out(t)
		Kind.ANTICIPATE: return anticipate(t)
		Kind.ELASTIC_OUT: return elastic_out(t)
		Kind.BOUNCE_OUT: return bounce_out(t)
		Kind.SETTLE: return settle(t)
		Kind.IMPACT: return impact(t)
		Kind.PULSE: return pulse(t)
		Kind.SPIKE: return spike(t)
		Kind.SMOOTHSTEP: return smoothstep(0.0, 1.0, t)
	return t


## Interpolate two floats along a curve. The form most callers actually want.
static func lerp_curve(from: float, to: float, k: float, kind: Kind) -> float:
	return from + (to - from) * apply(kind, k)


## Same, for anything Vector2-shaped.
static func lerp_vec(from: Vector2, to: Vector2, k: float, kind: Kind) -> Vector2:
	return from.lerp(to, apply(kind, k))


## Same, for colour. Alpha rides the curve with everything else.
static func lerp_col(from: Color, to: Color, k: float, kind: Kind) -> Color:
	return from.lerp(to, apply(kind, k))


# --- the curves ---------------------------------------------------------------

static func sine_in(t: float) -> float:
	return 1.0 - cos(t * PI * 0.5)


static func sine_out(t: float) -> float:
	return sin(t * PI * 0.5)


static func sine_in_out(t: float) -> float:
	return -(cos(PI * t) - 1.0) * 0.5


static func quad_in_out(t: float) -> float:
	if t < 0.5:
		return 2.0 * t * t
	var f: float = -2.0 * t + 2.0
	return 1.0 - f * f * 0.5


static func cubic_out(t: float) -> float:
	var f: float = 1.0 - t
	return 1.0 - f * f * f


static func cubic_in_out(t: float) -> float:
	if t < 0.5:
		return 4.0 * t * t * t
	var f: float = -2.0 * t + 2.0
	return 1.0 - f * f * f * 0.5


static func quart_out(t: float) -> float:
	var f: float = 1.0 - t
	return 1.0 - f * f * f * f


static func expo_in(t: float) -> float:
	if t <= 0.0:
		return 0.0
	return pow(2.0, 10.0 * t - 10.0)


static func expo_out(t: float) -> float:
	if t >= 1.0:
		return 1.0
	return 1.0 - pow(2.0, -10.0 * t)


static func expo_in_out(t: float) -> float:
	if t <= 0.0:
		return 0.0
	if t >= 1.0:
		return 1.0
	if t < 0.5:
		return pow(2.0, 20.0 * t - 10.0) * 0.5
	return (2.0 - pow(2.0, -20.0 * t + 10.0)) * 0.5


## Overshoots past 1 and comes back. The single most useful curve in the file.
static func back_out(t: float) -> float:
	var f: float = t - 1.0
	return 1.0 + (BACK_C + 1.0) * f * f * f + BACK_C * f * f


## Dips below 0 first. Pair it with BACK_OUT on the way back for a full
## anticipate-and-release, or use it alone for "a thing is winding up".
static func anticipate(t: float) -> float:
	return (BACK_C + 1.0) * t * t * t - BACK_C * t * t


static func elastic_out(t: float) -> float:
	if t <= 0.0:
		return 0.0
	if t >= 1.0:
		return 1.0
	# Amplitude damped to 0.72: the textbook constant overshoots by 35%, which on
	# a top-down grid reads as a cartoon rather than as a spring, and it broke the
	# ±30% band every other curve in this file lives inside.
	const P: float = 0.32
	return 0.72 * pow(2.0, -10.0 * t) * sin((t - P * 0.25) * TAU / P) + 1.0


static func bounce_out(t: float) -> float:
	const N: float = 7.5625
	const D: float = 2.75
	var x: float = t
	if x < 1.0 / D:
		return N * x * x
	if x < 2.0 / D:
		x -= 1.5 / D
		return N * x * x + 0.75
	if x < 2.5 / D:
		x -= 2.25 / D
		return N * x * x + 0.9375
	x -= 2.625 / D
	return N * x * x + 0.984375


## A heavy object dropping into its slot: most of the travel in the first third,
## one small bounce, dead still after that. This is the placement curve.
static func settle(t: float) -> float:
	if t < 0.62:
		return expo_out(t / 0.62) * 1.055
	var f: float = (t - 0.62) / 0.38
	return 1.0 + 0.055 * cos(f * PI) * (1.0 - f)


## Instant to full, then a decaying fall. Flashes, muzzle light, impact tint —
## anything that must be at full strength on the first frame it exists.
##
## No `if t <= 0.0: return 0.0` guard here, and that is the point: this is an
## ENVELOPE, not a transition. The guard was in this function for exactly one
## test run and it made every flash in the game fade IN, which is the difference
## between a hit and a sunrise.
static func impact(t: float) -> float:
	return 1.0 - expo_in(t)


## Rises to 1 at the middle and returns to 0 at the end. One call, one blink.
static func pulse(t: float) -> float:
	return sin(clampf(t, 0.0, 1.0) * PI)


## Sharp attack, long tail: 0 -> 1 in the first 12%, then a soft decay.
## The envelope of a spark, an ember, or a shake that must not feel symmetric.
static func spike(t: float) -> float:
	const ATTACK: float = 0.12
	if t < ATTACK:
		return quart_out(t / ATTACK)
	var f: float = (t - ATTACK) / (1.0 - ATTACK)
	return 1.0 - cubic_in_out(f)


# --- shaped helpers -----------------------------------------------------------

## A damped spring at time k (0..1 over `cycles` oscillations). Returns a value
## that starts at 0, overshoots 1, and rings down. For things that should feel
## sprung rather than tweened — a hover lift, a bar that gets kicked.
static func spring(k: float, cycles: float = 2.0, damping: float = 6.0) -> float:
	var t: float = clampf(k, 0.0, 1.0)
	if t >= 1.0:
		return 1.0
	return 1.0 - exp(-damping * t) * cos(TAU * cycles * t)


## A breath: 0..1..0 forever, on a sine, with a held top. `phase` is in turns.
## Used by the idle-life layer so a hundred buildings can breathe out of phase
## without a hundred timers.
static func breathe(phase: float) -> float:
	var s: float = sin(phase * TAU)
	return 0.5 + 0.5 * (s * (1.15 - 0.15 * absf(s)))


## Remaps a value into 0..1 and eases it in one call. Handy for pressure meters
## that drive a visual: `LcnEase.ramp(temp, -40.0, 0.0, LcnEase.Kind.QUAD_OUT)`.
static func ramp(value: float, low: float, high: float, kind: Kind = Kind.LINEAR) -> float:
	if is_equal_approx(low, high):
		return 0.0
	return apply(kind, clampf((value - low) / (high - low), 0.0, 1.0))


## Human name of a curve, for logs and for the timing documentation.
static func kind_name(kind: Kind) -> String:
	var names: PackedStringArray = PackedStringArray([
		"linear", "sine_in", "sine_out", "sine_in_out",
		"quad_in", "quad_out", "quad_in_out",
		"cubic_in", "cubic_out", "cubic_in_out", "quart_out",
		"expo_in", "expo_out", "expo_in_out",
		"back_out", "anticipate", "elastic_out", "bounce_out",
		"settle", "impact", "pulse", "spike", "smoothstep",
	])
	var i: int = int(kind)
	return names[i] if i >= 0 and i < names.size() else "curve%d" % i
