extends TestCase
## The curve library. [P15]
##
## Two families with two different contracts, and the bug this suite exists to
## catch is a curve being used as the wrong one: an envelope where an
## interpolator belongs makes a panel open backwards, and an interpolator where
## an envelope belongs makes a flash fade IN.

const TRANSITIONS: Array[int] = [
	LcnEase.Kind.LINEAR,
	LcnEase.Kind.SINE_IN, LcnEase.Kind.SINE_OUT, LcnEase.Kind.SINE_IN_OUT,
	LcnEase.Kind.QUAD_IN, LcnEase.Kind.QUAD_OUT, LcnEase.Kind.QUAD_IN_OUT,
	LcnEase.Kind.CUBIC_IN, LcnEase.Kind.CUBIC_OUT, LcnEase.Kind.CUBIC_IN_OUT,
	LcnEase.Kind.QUART_OUT,
	LcnEase.Kind.EXPO_IN, LcnEase.Kind.EXPO_OUT, LcnEase.Kind.EXPO_IN_OUT,
	LcnEase.Kind.BACK_OUT, LcnEase.Kind.ANTICIPATE,
	LcnEase.Kind.ELASTIC_OUT, LcnEase.Kind.BOUNCE_OUT,
	LcnEase.Kind.SETTLE, LcnEase.Kind.SMOOTHSTEP,
]
const ENVELOPES: Array[int] = [
	LcnEase.Kind.IMPACT, LcnEase.Kind.PULSE, LcnEase.Kind.SPIKE,
]


func test_every_transition_starts_at_zero_and_ends_at_one() -> void:
	for kind: int in TRANSITIONS:
		var n: String = LcnEase.kind_name(kind)
		assert_near(LcnEase.apply(kind, 0.0), 0.0, 1.0e-4, "%s(0) is 0" % n)
		assert_near(LcnEase.apply(kind, 1.0), 1.0, 1.0e-4, "%s(1) is 1" % n)


## A curve fed a value outside 0..1 by a caller whose own timer overshot must
## clamp, not extrapolate. An unclamped BACK_OUT at k=1.4 sends a panel off screen.
func test_curves_clamp_their_input() -> void:
	for kind: int in TRANSITIONS + ENVELOPES:
		var n: String = LcnEase.kind_name(kind)
		assert_eq(LcnEase.apply(kind, -3.0), LcnEase.apply(kind, 0.0), "%s clamps below" % n)
		assert_eq(LcnEase.apply(kind, 9.0), LcnEase.apply(kind, 1.0), "%s clamps above" % n)


func test_transitions_stay_in_a_sane_band() -> void:
	# Overshoot is allowed and wanted; a curve that leaves ±30% is a bug, because
	# every consumer sizes its motion assuming roughly unit travel.
	for kind: int in TRANSITIONS:
		var n: String = LcnEase.kind_name(kind)
		for step: int in 51:
			var v: float = LcnEase.apply(kind, float(step) / 50.0)
			assert_between(v, -0.3, 1.3, "%s at k=%.2f stays in band" % [n, float(step) / 50.0])


func test_back_out_actually_overshoots() -> void:
	var peak: float = 0.0
	for step: int in 101:
		peak = maxf(peak, LcnEase.apply(LcnEase.Kind.BACK_OUT, float(step) / 100.0))
	assert_gt(peak, 1.02, "BACK_OUT overshoots — that is the entire point of it")
	assert_lt(peak, 1.20, "and not so far it reads as a bug")


func test_anticipate_pulls_back_first() -> void:
	var low: float = 1.0
	for step: int in 101:
		low = minf(low, LcnEase.apply(LcnEase.Kind.ANTICIPATE, float(step) / 100.0))
	assert_lt(low, -0.02, "ANTICIPATE dips below zero before it goes")


## SETTLE is the placement curve: most of the travel early, one bounce, still.
func test_settle_lands_early_and_bounces_once() -> void:
	assert_gt(LcnEase.apply(LcnEase.Kind.SETTLE, 0.3), 0.85,
		"SETTLE is most of the way there in the first third")
	var overshoot: float = 0.0
	for step: int in 101:
		overshoot = maxf(overshoot, LcnEase.apply(LcnEase.Kind.SETTLE, float(step) / 100.0))
	assert_gt(overshoot, 1.0, "it overshoots")
	assert_lt(overshoot, 1.09, "by a hair, not a hop")
	assert_near(LcnEase.apply(LcnEase.Kind.SETTLE, 1.0), 1.0, 1.0e-4, "and comes to rest")


## An IMPACT that starts at 0 is not a flash, it is a fade-in. This assertion is
## the one that keeps a hit from looking like a sunrise.
func test_impact_is_full_on_the_first_frame() -> void:
	assert_near(LcnEase.apply(LcnEase.Kind.IMPACT, 0.0), 1.0, 1.0e-4,
		"IMPACT is at full strength immediately")
	assert_near(LcnEase.apply(LcnEase.Kind.IMPACT, 1.0), 0.0, 1.0e-4, "and gone at the end")
	var prev: float = 2.0
	for step: int in 51:
		var v: float = LcnEase.apply(LcnEase.Kind.IMPACT, float(step) / 50.0)
		assert_le(v, prev + 1.0e-5, "IMPACT never rises")
		prev = v


func test_pulse_returns_to_zero_and_peaks_in_the_middle() -> void:
	assert_near(LcnEase.apply(LcnEase.Kind.PULSE, 0.0), 0.0, 1.0e-4)
	assert_near(LcnEase.apply(LcnEase.Kind.PULSE, 1.0), 0.0, 1.0e-4)
	assert_near(LcnEase.apply(LcnEase.Kind.PULSE, 0.5), 1.0, 1.0e-4, "peak at the middle")


func test_spike_attacks_fast_and_tails_long() -> void:
	assert_gt(LcnEase.apply(LcnEase.Kind.SPIKE, 0.12), 0.95, "at full strength by 12%")
	assert_lt(LcnEase.apply(LcnEase.Kind.SPIKE, 0.9), 0.1, "and nearly gone at 90%")
	assert_near(LcnEase.apply(LcnEase.Kind.SPIKE, 1.0), 0.0, 1.0e-4)


func test_spring_starts_at_zero_settles_at_one_and_rings() -> void:
	assert_near(LcnEase.spring(0.0), 0.0, 1.0e-4)
	assert_near(LcnEase.spring(1.0), 1.0, 1.0e-4)
	var peak: float = 0.0
	for step: int in 100:
		peak = maxf(peak, LcnEase.spring(float(step) / 100.0))
	assert_gt(peak, 1.0, "a spring overshoots or it is not a spring")


func test_breathe_is_a_bounded_cycle() -> void:
	var lo: float = 2.0
	var hi: float = -1.0
	for step: int in 200:
		var v: float = LcnEase.breathe(float(step) / 100.0)
		lo = minf(lo, v)
		hi = maxf(hi, v)
	assert_between(lo, -0.001, 0.05, "bottoms out at 0")
	assert_between(hi, 0.95, 1.001, "tops out at 1")
	assert_near(LcnEase.breathe(0.0), LcnEase.breathe(1.0), 1.0e-4, "and it is periodic")


func test_ramp_maps_and_clamps() -> void:
	assert_near(LcnEase.ramp(-40.0, -40.0, 0.0), 0.0, 1.0e-4)
	assert_near(LcnEase.ramp(0.0, -40.0, 0.0), 1.0, 1.0e-4)
	assert_near(LcnEase.ramp(20.0, -40.0, 0.0), 1.0, 1.0e-4, "clamps above the top")
	assert_near(LcnEase.ramp(-90.0, -40.0, 0.0), 0.0, 1.0e-4, "clamps below the bottom")
	assert_near(LcnEase.ramp(5.0, 5.0, 5.0), 0.0, 1.0e-4, "a zero-width ramp is 0, not NaN")


func test_lerp_helpers_agree_with_the_curve() -> void:
	var k: float = 0.37
	var e: float = LcnEase.apply(LcnEase.Kind.CUBIC_OUT, k)
	assert_near(LcnEase.lerp_curve(10.0, 20.0, k, LcnEase.Kind.CUBIC_OUT), 10.0 + 10.0 * e, 1.0e-5)
	var v: Vector2 = LcnEase.lerp_vec(Vector2.ZERO, Vector2(100.0, 0.0), k, LcnEase.Kind.CUBIC_OUT)
	assert_near(v.x, 100.0 * e, 1.0e-4)
	var c: Color = LcnEase.lerp_col(Color(0, 0, 0, 0), Color(1, 1, 1, 1), k, LcnEase.Kind.CUBIC_OUT)
	assert_near(c.a, e, 1.0e-4)


## Same input, same output, forever. A curve that is not deterministic makes a
## visual regression run undiffable, which is the whole reason the harness exists.
func test_curves_are_deterministic() -> void:
	var sample: Callable = func() -> Array:
		var out: Array = []
		for kind: int in TRANSITIONS + ENVELOPES:
			for step: int in 17:
				out.append(snappedf(LcnEase.apply(kind, float(step) / 16.0), 0.000001))
		return out
	assert_deterministic(sample, "every curve is pure math", 3)


func test_every_kind_has_a_name() -> void:
	var seen: Dictionary[String, bool] = {}
	for kind: int in TRANSITIONS + ENVELOPES:
		var n: String = LcnEase.kind_name(kind)
		assert_false(n.begins_with("curve"), "kind %d has a real name, not '%s'" % [kind, n])
		assert_false(seen.has(n), "'%s' is used twice" % n)
		seen[n] = true
	assert_eq(seen.size(), TRANSITIONS.size() + ENVELOPES.size(),
		"every curve in the enum is covered by this suite")
