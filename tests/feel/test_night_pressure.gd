extends TestCase
## The night pressure table. [P15]
##
## The feel layer darkens the frame by [P13]'s OWN name for the hour, so that the
## vignette and the colour grade can never disagree about what time it is. That
## only works if the two vocabularies actually match — and they did not: the
## first version matched on `&"evening"`, which the palette has never emitted,
## and deep night therefore carried no pressure at all. Nothing caught it,
## because a vignette that is missing looks exactly like a vignette that is
## subtle.
##
## This suite walks a whole day, hour by hour, and fails on any phase name the
## table does not know.


func test_every_hour_of_the_day_has_a_darkness() -> void:
	var seen: Dictionary[StringName, bool] = {}
	for step: int in 240:
		var t: float = float(step) / 240.0
		var phase: StringName = LcnPalette.phase_at(t)
		seen[phase] = true
		assert_ge(LcnFeel.darkness_for(phase), 0.0,
			"phase '%s' (t=%.3f) is in the pressure table" % [phase, t])
	assert_gt(seen.size(), 4, "and the day really does have several named hours (%d)" % seen.size())


func test_an_unknown_phase_is_reported_not_guessed() -> void:
	assert_lt(LcnFeel.darkness_for(&"a_phase_nobody_wrote"), 0.0,
		"a name the table has never heard of comes back negative, so the caller "
		+ "can tell 'no pressure' from 'no idea'")


func test_the_table_runs_dark_at_night_and_clear_at_noon() -> void:
	assert_near(LcnFeel.darkness_for(&"noon"), 0.0, 1.0e-6, "noon is not oppressive")
	assert_near(LcnFeel.darkness_for(&"deep_night"), 1.0, 1.0e-6, "deep night is")
	assert_gt(LcnFeel.darkness_for(&"night"), LcnFeel.darkness_for(&"dusk"),
		"and it gets darker as the night goes on, not lighter")
	assert_gt(LcnFeel.darkness_for(&"dusk"), LcnFeel.darkness_for(&"afternoon"))


## The pressure the player feels has to be a function of the hour and nothing
## else — no frame counter, no wall clock, no randomness.
func test_darkness_is_a_pure_function_of_the_hour() -> void:
	var sample: Callable = func() -> Array:
		var out: Array = []
		for step: int in 48:
			out.append(LcnFeel.darkness_for(LcnPalette.phase_at(float(step) / 48.0)))
		return out
	assert_deterministic(sample, "same hour, same darkness", 3)
