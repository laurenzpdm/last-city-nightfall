extends TestCase
## The timing vocabulary. [P15]
##
## The point of a shared vocabulary is that it is SHARED, so most of this suite
## is about the ladder staying a ladder and about accessibility being part of the
## vocabulary rather than a switch bolted on next to it.

var _saved_reduce: bool = false
var _saved_shake: float = 1.0


func setup() -> void:
	_saved_reduce = bool(Settings.accessibility.get("reduce_motion", false))
	_saved_shake = float(Settings.graphics.get("screen_shake", 1.0))


func teardown() -> void:
	Settings.accessibility["reduce_motion"] = _saved_reduce
	Settings.graphics["screen_shake"] = _saved_shake


func test_the_ladder_is_strictly_increasing() -> void:
	var last: float = 0.0
	for rung: StringName in LcnTiming.LADDER:
		var d: float = LcnTiming.duration(rung)
		assert_gt(d, last, "'%s' is longer than the rung below it" % rung)
		last = d
	assert_near(LcnTiming.duration(&"flick"), LcnTiming.FLICK, 1.0e-6)
	assert_near(LcnTiming.duration(&"event"), LcnTiming.EVENT, 1.0e-6)


## A rung without its curve is half a decision, and half a decision is how a
## build ends up with eleven different 0.25s in it.
func test_every_rung_has_a_curve() -> void:
	assert_eq(LcnTiming.LADDER.size(), LcnTiming.LADDER_CURVE.size(),
		"one curve per rung, no exceptions")
	for rung: StringName in LcnTiming.LADDER:
		var kind: int = LcnTiming.curve(rung)
		assert_false(LcnEase.kind_name(kind).begins_with("curve"),
			"'%s' maps to a real curve" % rung)
		# The curve a rung names must be an interpolator, never an envelope: you
		# cannot open a panel on an IMPACT.
		assert_near(LcnEase.apply(kind, 1.0), 1.0, 1.0e-4,
			"'%s' uses a transition, not an envelope" % rung)


func test_an_unknown_rung_is_visible_not_invisible() -> void:
	assert_near(LcnTiming.duration(&"nonsense"), LcnTiming.QUICK, 1.0e-6,
		"a typo should look slightly wrong, never take zero time")


func test_stagger_reads_as_a_sequence_and_still_finishes_in_time() -> void:
	assert_near(LcnTiming.stagger(0), 0.0, 1.0e-6)
	assert_gt(LcnTiming.stagger(1), 0.0)
	assert_le(LcnTiming.stagger(LcnTiming.STAGGER_MAX) + LcnTiming.SETTLE, LcnTiming.SWELL,
		"a whole staggered group plus its own settle lands inside a swell")
	assert_eq(LcnTiming.stagger(400), LcnTiming.stagger(LcnTiming.STAGGER_MAX),
		"the stagger is capped, so a hundred items do not take four seconds")


func test_reduce_motion_deletes_decoration_and_shortens_meaning() -> void:
	Settings.accessibility["reduce_motion"] = false
	assert_near(LcnTiming.decorative(LcnTiming.HEAVY), LcnTiming.HEAVY, 1.0e-6)
	assert_near(LcnTiming.meaningful(LcnTiming.HEAVY), LcnTiming.HEAVY, 1.0e-6)
	assert_near(LcnTiming.motion_scale(), 1.0, 1.0e-6)

	Settings.accessibility["reduce_motion"] = true
	assert_near(LcnTiming.decorative(LcnTiming.HEAVY), 0.0, 1.0e-6,
		"decoration is deleted outright")
	assert_le(LcnTiming.meaningful(LcnTiming.HEAVY), LcnTiming.SNAP,
		"meaning is shortened, never deleted — a panel still has to be seen to open")
	assert_near(LcnTiming.motion_scale(), 0.0, 1.0e-6)


func test_shake_has_two_independent_off_switches() -> void:
	Settings.accessibility["reduce_motion"] = false
	Settings.graphics["screen_shake"] = 1.0
	assert_near(LcnTiming.shake_scale(), 1.0, 1.0e-6)

	Settings.graphics["screen_shake"] = 0.0
	assert_near(LcnTiming.shake_scale(), 0.0, 1.0e-6, "the graphics slider silences it")

	Settings.graphics["screen_shake"] = 1.0
	Settings.accessibility["reduce_motion"] = true
	assert_near(LcnTiming.shake_scale(), 0.0, 1.0e-6, "and so does reduce motion, alone")


func test_hit_stop_is_separate_from_shake() -> void:
	Settings.accessibility["reduce_motion"] = false
	Settings.graphics["screen_shake"] = 0.0
	Settings.graphics["hit_stop"] = true
	assert_true(LcnTiming.hit_stop_enabled(),
		"a player who turned shake off has not asked for hit-stop to go too")
	Settings.graphics["hit_stop"] = false
	assert_false(LcnTiming.hit_stop_enabled())
	Settings.graphics["hit_stop"] = true
	Settings.accessibility["reduce_motion"] = true
	assert_false(LcnTiming.hit_stop_enabled(), "reduce motion still wins")
	Settings.graphics.erase("hit_stop")


## After a stall — a harness screenshot, a window drag, a level load — the frame
## delta can be seconds. Unclamped, every tween in the game jumps to its end and
## the player sees the aftermath of an animation they never saw.
func test_the_interface_clock_clamps_a_stall() -> void:
	var before: float = LcnTiming.ui_now
	var dt: float = LcnTiming.advance_ui(4.0)
	assert_le(dt, 0.1, "a four-second frame advances the clock by at most 0.1 s")
	assert_le(LcnTiming.ui_now - before, 0.1)
	assert_near(LcnTiming.advance_ui(-1.0), 0.0, 1.0e-6, "and never runs backwards")


func test_world_time_follows_the_simulation_clock() -> void:
	var a: float = LcnTiming.world_now()
	SimClock.advance(20)
	var b: float = LcnTiming.world_now()
	assert_near(b - a, 1.0, 0.001, "twenty ticks is one second of world time")


func test_effect_life_is_capped_by_the_vocabulary() -> void:
	assert_gt(LcnTiming.MAX_EFFECT_LIFE, LcnTiming.EVENT * 0.5,
		"long enough for the effects the ladder actually asks for")
	assert_lt(LcnTiming.MAX_EFFECT_LIFE, 5.0,
		"short enough that a leaked particle cannot cost a frame later")
