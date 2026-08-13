extends TestCase
## LcnImpulse — the value that gets kicked and recovers. [P15]
##
## Half of "feel" is a value that reacts and comes back: a hover lift, an alert
## glow, the pressure of a night falling. The behaviour under INTERRUPTION is
## the whole reason this class exists instead of a Tween, so most of this suite
## is about what happens when a second kick lands on the first.


func test_a_kick_starts_at_full_and_decays_to_nothing() -> void:
	var imp := LcnImpulse.new()
	assert_near(imp.value(), 0.0, 1.0e-6, "at rest it is zero")
	assert_false(imp.active())
	imp.kick(1.0, 0.5)
	assert_near(imp.value(), 1.0, 1.0e-4, "full on the frame it is kicked")
	assert_true(imp.active())
	imp.advance(0.25)
	assert_between(imp.value(), 0.05, 0.95, "decaying through the middle")
	imp.advance(0.30)
	assert_near(imp.value(), 0.0, 1.0e-6, "spent")
	assert_false(imp.active())


func test_strength_scales_the_peak() -> void:
	var soft := LcnImpulse.new()
	var hard := LcnImpulse.new()
	soft.kick(0.2, 0.4)
	hard.kick(1.0, 0.4)
	assert_lt(soft.value(), hard.value(), "a small kick is a small value")
	assert_near(soft.value(), 0.2, 1.0e-4)


func test_a_small_repeat_cannot_cut_a_large_event_short() -> void:
	# The bug this prevents: a rifle tick every frame ending a collapsing-building
	# rumble, because each new kick restarted the timer with its own short span.
	var imp := LcnImpulse.new()
	imp.kick(1.0, 1.0)
	imp.advance(0.2)
	imp.kick(0.05, 0.05)
	imp.advance(0.10)
	assert_true(imp.active(), "the long event is still running after the short one")
	assert_gt(imp.value(), 0.3, "and still loud")


func test_kicks_accumulate_but_stay_bounded() -> void:
	var imp := LcnImpulse.new()
	for _i: int in 20:
		imp.kick(0.5, 0.3)
		imp.advance(0.01)
	assert_le(imp.value(), 1.0001, "twenty kicks cannot exceed full scale")
	assert_gt(imp.value(), 0.4, "but they do add up")


## Hover is a state, not an event: it must hold while the cursor is there and
## only decay once the cursor leaves.
func test_hold_sustains_until_released() -> void:
	var imp := LcnImpulse.new()
	imp.hold(1.0, 0.1, LcnEase.Kind.QUART_OUT)
	imp.advance(0.1)
	var held: float = imp.value()
	assert_near(held, 1.0, 1.0e-4, "the attack finished and it holds")
	for _i: int in 100:
		imp.advance(0.05)
	assert_near(imp.value(), held, 1.0e-4, "five seconds later it is still held")
	imp.release(0.1)
	imp.advance(0.2)
	assert_near(imp.value(), 0.0, 1.0e-4, "and it lets go when told")


func test_hold_rises_over_the_attack_rather_than_snapping() -> void:
	var imp := LcnImpulse.new()
	imp.hold(1.0, 0.2, LcnEase.Kind.QUART_OUT)
	var at_zero: float = imp.value()
	imp.advance(0.05)
	var early: float = imp.value()
	assert_lt(at_zero, 0.5, "it starts low")
	assert_gt(early, at_zero, "and rises")


func test_holding_twice_does_not_restart_the_animation() -> void:
	var imp := LcnImpulse.new()
	imp.hold(1.0, 0.2)
	imp.advance(0.2)
	imp.hold(1.0, 0.2)
	assert_near(imp.value(), 1.0, 1.0e-4,
		"a hover that is re-asserted every frame must not stutter")


func test_remaining_runs_from_one_to_zero() -> void:
	var imp := LcnImpulse.new()
	imp.kick(1.0, 1.0)
	assert_near(imp.remaining01(), 1.0, 1.0e-4)
	imp.advance(0.5)
	assert_near(imp.remaining01(), 0.5, 0.01)
	imp.advance(0.6)
	assert_near(imp.remaining01(), 0.0, 1.0e-6)


func test_a_zero_kick_is_ignored() -> void:
	var imp := LcnImpulse.new()
	imp.kick(0.0, 0.5)
	assert_false(imp.active(), "nothing happened, so nothing should be drawn")
	imp.kick(-3.0, 0.5)
	assert_false(imp.active())


func test_reset_clears_everything() -> void:
	var imp := LcnImpulse.new()
	imp.hold(1.0, 0.2)
	imp.advance(0.2)
	imp.reset()
	assert_near(imp.value(), 0.0, 1.0e-6)
	assert_false(imp.active())
	assert_false(imp.sustained)


func test_the_same_kicks_produce_the_same_curve() -> void:
	var sample: Callable = func() -> Array:
		var imp := LcnImpulse.new()
		var out: Array = []
		imp.kick(0.8, 0.6)
		for i: int in 30:
			imp.advance(0.02)
			if i == 10:
				imp.kick(0.3, 0.2)
			out.append(snappedf(imp.value(), 0.000001))
		return out
	assert_deterministic(sample, "an impulse is pure math", 3)
