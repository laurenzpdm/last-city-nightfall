extends TestCase
## THE ONE LINE UNDER THE DAY NUMBER MUST NOT CONTRADICT THE WINDOW.
##
## [P17] draws a single caps line under "Day N" on the clock plate — the whole
## of what the interface says about where the city is in its story — and it gets
## the string by asking [P09] for `era_title()`. In all eleven photographic
## beats of a shipped run it read **THE LULL**, while [P22]'s chapter had turned
## over to `the_great_frost` and the plain outside was a Great Frost.
##
## Neither part was wrong on its own terms, which is why nothing caught it. The
## escalation curve is a schedule of DAYS and "The Lull" is correct arithmetic
## about day 3. But the player is not looking at a curve, they are looking at a
## whiteout, and a legibility layer that disagrees with the world outside the
## window is worse than an empty corner. [P09] now answers with the strongest
## TRUE thing — the storm while one is blowing, the curve otherwise — and keeps
## `escalation_title()` for the places that genuinely mean the curve.
##
## THIS LIVES IN tests/gate/ BECAUSE IT HAS NO OTHER HOME. It is a contract
## BETWEEN two parts: [P09] owns the string and [P17] owns the plate, so neither
## part's suite is the honest place for "these two must not contradict each
## other". The gate is where the contracts nobody owns alone are kept.
##
## HOW TO MAKE IT RED: make `ClimateSystem.era_title()` return
## `escalation_title()` unconditionally, which is what it did before this wave.
## `test_the_line_names_the_storm_while_one_is_blowing` fails. Verified.

const FORCE_STORM: Dictionary = {
	"system": "climate", "op": "force_storm",
	"intensity": 0.9, "duration_ticks": 2400, "title": "The First Great Frost",
}


func _climate() -> ClimateSystem:
	Rng.reset(7)
	var c := ClimateSystem.new()
	c.setup()
	c.step(1)
	return c


## Day one, nothing blowing: the line is the escalation beat, exactly as before.
func test_the_line_names_the_escalation_beat_on_a_quiet_day() -> void:
	var c: ClimateSystem = _climate()
	assert_false(c.is_storm_active(), "day one opened with a storm already blowing")
	assert_eq(c.era_title(), c.escalation_title(),
		"with nothing blowing, the line under the day number must be the escalation beat")
	assert_eq(c.era_title(), "The Lull",
		"day one of the shipped curve is 'The Lull' and the line does not say so")


## THE DEFECT, in one assertion. A Great Frost is on the city and the plate says
## the plain is quiet.
func test_the_line_names_the_storm_while_one_is_blowing() -> void:
	var c: ClimateSystem = _climate()
	c.handle_command(FORCE_STORM)
	var t: int = 1
	while t < 400 and not c.is_storm_active():
		t += 1
		c.step(t)
	assert_true(c.is_storm_active(),
		"force_storm did not put a storm on the city within 400 ticks — nothing below was tested")
	assert_eq(c.era_title(), "The First Great Frost",
		("a Great Frost is blowing and the line under the day number reads '%s'. "
		+ "That is the sentence a critic read on all eleven beats of a run.")
			% c.era_title())
	# ...and the curve is untouched underneath it, so nothing that keys off the
	# campaign beat changes behaviour.
	assert_eq(c.escalation_title(), "The Lull",
		"the escalation curve's own title moved when the weather did")
	assert_eq(String(c.era_key()), "the_lull",
		"era_key() is the campaign beat and must not follow the weather")
	assert_eq(c.era_index(), 0, "era_index() followed the weather")


## ...and it goes back. A storm that ends and leaves its name on the plate is
## the same defect pointing the other way.
func test_the_line_goes_back_when_the_storm_passes() -> void:
	var c: ClimateSystem = _climate()
	c.handle_command(FORCE_STORM)
	var t: int = 1
	while t < 400 and not c.is_storm_active():
		t += 1
		c.step(t)
	assert_true(c.is_storm_active(), "no storm was raised, so nothing below was tested")
	while t < 6000 and c.is_storm_active():
		t += 1
		c.step(t)
	assert_false(c.is_storm_active(), "the forced storm never ended inside 6000 ticks")
	assert_eq(c.era_title(), c.escalation_title(),
		"the storm has passed and its name is still under the day number")


## [P17]'s `LcnHudProbe` asks for these by name and falls back to an empty
## string when they are absent, so a rename here would blank the clock plate in
## silence rather than break the build.
func test_the_names_the_hud_asks_for_still_exist() -> void:
	var c: ClimateSystem = _climate()
	for method: String in ["era_title", "era_key", "era_index", "escalation_title",
			"phase_of_day", "phase_label", "day", "is_storm_active", "storm_title"]:
		assert_true(c.has_method(method),
			"ClimateSystem has lost `%s()`, which the HUD asks for by name" % method)
