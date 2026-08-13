extends TestCase
## LcnNumberTicker — a number that travels instead of snapping. [P15]
##
## A city builder shows eleven numbers that change every tick. Snapping makes
## them unreadable: the eye cannot tell 412 falling to 380 from 412 becoming 41.
## A number that COUNTS reports its own direction and magnitude for free.

var _saved_reduce: bool = false


func setup() -> void:
	_saved_reduce = bool(Settings.accessibility.get("reduce_motion", false))
	Settings.accessibility["reduce_motion"] = false


func teardown() -> void:
	Settings.accessibility["reduce_motion"] = _saved_reduce


func test_it_travels_and_lands_inside_its_span() -> void:
	var n := LcnNumberTicker.new(0.0, 0.5)
	n.target = 100.0
	n.advance(0.1)
	assert_gt(n.value(), 0.0, "it left")
	assert_lt(n.value(), 100.0, "and has not arrived")
	assert_true(n.travelling())
	n.advance(0.5)
	assert_near(n.value(), 100.0, 1.0e-4, "it lands within the span, whatever the jump")
	assert_false(n.travelling())


func test_a_bigger_jump_takes_the_same_time() -> void:
	var small := LcnNumberTicker.new(0.0, 0.4)
	var big := LcnNumberTicker.new(0.0, 0.4)
	small.target = 5.0
	big.target = 500.0
	for _i: int in 20:
		small.advance(0.02)
		big.advance(0.02)
	assert_near(small.value(), 5.0, 1.0e-3, "both are done at the same moment")
	assert_near(big.value(), 500.0, 1.0e-3, "time-bounded, not rate-based")


## A world load or a save restore is not a change the player made and must not
## be animated — a stock bar sweeping up from zero on load is a lie about what
## just happened.
func test_a_reset_sized_change_snaps_instead_of_animating() -> void:
	var n := LcnNumberTicker.new(10.0, 1.0)
	n.target = 40000.0
	n.advance(0.001)
	assert_near(n.value(), 40000.0, 1.0e-3, "that is a different number, not a change")
	assert_false(n.travelling())


func test_noise_below_the_deadzone_does_not_animate() -> void:
	var n := LcnNumberTicker.new(100.0, 0.5)
	n.deadzone = 0.5
	n.target = 100.2
	n.advance(0.05)
	assert_false(n.travelling(), "a fifth of a unit is not worth a second of motion")
	assert_near(n.value(), 100.0, 1.0e-4)


func test_direction_is_reported_while_travelling() -> void:
	var n := LcnNumberTicker.new(50.0, 0.5)
	n.target = 90.0
	n.advance(0.05)
	assert_true(n.rising(), "it is going up")
	assert_false(n.falling())
	n.advance(1.0)
	assert_false(n.rising(), "and stops reporting once it lands")

	n.target = 10.0
	n.advance(0.05)
	assert_true(n.falling(), "it is going down")


func test_retargeting_mid_travel_starts_from_where_it_is() -> void:
	var n := LcnNumberTicker.new(0.0, 0.4)
	n.target = 100.0
	n.advance(0.2)
	var mid: float = n.value()
	assert_between(mid, 1.0, 99.0, "genuinely mid-flight")
	n.advance(0.4)
	n.target = 0.0
	n.advance(0.02)
	assert_lt(n.value(), 100.0, "it turned around from where it was")
	assert_gt(n.value(), 0.0, "rather than teleporting to the new target")


func test_reduce_motion_snaps() -> void:
	Settings.accessibility["reduce_motion"] = true
	var n := LcnNumberTicker.new(0.0, 1.0)
	n.target = 250.0
	n.advance(0.001)
	assert_near(n.value(), 250.0, 1.0e-4, "no travel when the player asked for none")
	assert_false(n.travelling())


func test_snap_to_moves_both_ends() -> void:
	var n := LcnNumberTicker.new(0.0, 1.0)
	n.target = 100.0
	n.advance(0.1)
	n.snap_to(7.0)
	assert_near(n.value(), 7.0, 1.0e-6)
	assert_near(n.target, 7.0, 1.0e-6)
	assert_false(n.travelling())
	n.advance(0.5)
	assert_near(n.value(), 7.0, 1.0e-6, "and it stays there")


func test_rounded_and_progress_are_usable_every_frame() -> void:
	var n := LcnNumberTicker.new(0.0, 0.4)
	n.target = 10.0
	assert_near(n.progress01(), 1.0, 1.0e-4, "at rest it is complete")
	n.advance(0.2)
	assert_between(n.progress01(), 0.01, 0.99)
	assert_between(float(n.rounded()), 0.0, 10.0)
	n.advance(0.4)
	assert_eq(n.rounded(), 10)


func test_the_same_input_produces_the_same_travel() -> void:
	var sample: Callable = func() -> Array:
		var n := LcnNumberTicker.new(0.0, 0.5)
		n.target = 73.0
		var out: Array = []
		for _i: int in 25:
			n.advance(0.02)
			out.append(snappedf(n.value(), 0.000001))
		return out
	assert_deterministic(sample, "a counting number is pure math", 3)
