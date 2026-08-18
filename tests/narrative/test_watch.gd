extends TestCase
## [P22] THE RULE ITSELF: a card that stops the world may not be on screen while
## the world needs watching.
##
## `LcnWorldWatch` is one function with an ORDER in it — breach outranks a set
## piece, a set piece outranks live bodies, live bodies outrank an active wave
## with nobody on the map yet, and all of them outrank the last stretch of the
## countdown. Every one of those rungs is a decision somebody will be tempted to
## reorder, so every one of them is a test.
##
## ── WHAT IS REAL HERE AND WHAT IS A STAND-IN, SAID PLAINLY ──────────────────
##
## `test_a_real_night_is_watched` drives an actual `first_night`-shaped world to
## an actual wave and asks the rule at the same instant it asks [P08]. Nothing is
## faked in it. It is the one that proves the rule is wired to the game.
##
## The rungs below it are driven through a stand-in system installed under the
## name `threat`, because reaching a BREACH or a set-piece night through the real
## director takes tens of thousands of ticks and would make the ordering of the
## rungs a function of the balance tables rather than of the rule. The stand-in
## answers the same three public methods with the same keys, and
## `test_the_stand_in_answers_what_the_real_one_answers` holds its dictionary
## against the real system's so it cannot quietly drift into testing a shape the
## game does not have.
##
## The rule's effect on the SHIPPED FRAME is not tested here and cannot be:
## `tests/d7/run_fight_frames.gd` reads the PNGs an ordinary visual run wrote.

var world: SimFixture


func setup() -> void:
	world = SimFixture.new(7).start()


func teardown() -> void:
	_uninstall()
	world.stop()


# =========================================================================
#  the real thing
# =========================================================================

## A quiet afternoon is not watched. If this ever goes red the rule has become
## "always on", which would take the story card out of the game entirely — the
## failure mode nobody would notice from a screenshot of an assault.
func test_a_quiet_world_is_not_watched() -> void:
	world.run(200)
	assert_eq(LcnWorldWatch.watch(), LcnWorldWatch.Watch.NONE,
		"the rule says the world needs watching on tick %d of day one, with no "
		% world.tick() + "wave anywhere near — the card would never be seen again")


## THE ONE WITH NOTHING FAKED IN IT. Runs the real director until it reports an
## active night, then asks the rule at that same instant.
func test_a_real_night_is_watched() -> void:
	var threat: SimSystem = world.system(&"threat")
	assert_not_null(threat, "no threat director in this world; the rule has "
		+ "nothing to read and this suite would pass by asserting nothing")
	var found: int = -1
	# Bounded: two full nights of the reference scenario. The first wave of
	# `first_night` lands around t4300. The state word is [P08]'s own
	# `ThreatDefs.WAVE_STATE_NAMES` and it is LOWER CASE — the first version of
	# this test asked for "ACTIVE", never matched, and said so out loud instead
	# of passing on an assertion that never ran. That is the whole reason the
	# precondition below is an assert and not an `if`.
	for _i: int in 400:
		world.run(50)
		if String((threat.call(&"metrics") as Dictionary).get("state", "")) == "active":
			found = world.tick()
			break
		if world.tick() > 12000:
			break
	assert_true(found > 0, "no wave ever went ACTIVE in 12000 ticks — the "
		+ "precondition for this test never happened, so it checked nothing")
	assert_ne(LcnWorldWatch.watch(), LcnWorldWatch.Watch.NONE,
		"[P08] says the night is ACTIVE at t%d and the rule says the world does "
		% found + "not need watching — this is the assault frame defect exactly")


## The countdown window, on the real director: the rule must be on BEFORE the
## first body arrives, because the frame that was worst was dusk — "Attack in 25
## seconds, a turret mount on that side, before the number reaches zero" with a
## 660 px card drawn across the side it meant.
func test_the_last_stretch_of_the_countdown_is_watched() -> void:
	var threat: SimSystem = world.system(&"threat")
	assert_not_null(threat, "no threat director in this world")
	var seen: bool = false
	for _i: int in 400:
		world.run(20)
		var p: Dictionary = threat.call(&"next_wave_preview") as Dictionary
		var until: float = float(p.get("seconds_until", -1.0))
		if bool(p.get("known", false)) and until > 0.0 \
				and until < LcnWorldWatch.LEAD_SECONDS and not bool(p.get("active", false)):
			seen = true
			assert_ne(LcnWorldWatch.watch(), LcnWorldWatch.Watch.NONE,
				"%.1f s before the wave lands and the stage is still the card's" % until)
			break
	assert_true(seen, "the run never passed through the last %.0f s of a countdown"
		% LcnWorldWatch.LEAD_SECONDS)


# =========================================================================
#  the rungs, in order
# =========================================================================

func test_live_bodies_are_an_assault() -> void:
	_install({"report": {"live": 3, "breached": false},
		"preview": {"active": true, "set_piece": false}})
	assert_eq(LcnWorldWatch.watch(), LcnWorldWatch.Watch.ASSAULT)


func test_an_active_wave_with_nobody_on_the_map_yet_is_still_an_assault() -> void:
	_install({"report": {"live": 0, "breached": false},
		"preview": {"active": true, "set_piece": false}})
	assert_eq(LcnWorldWatch.watch(), LcnWorldWatch.Watch.ASSAULT,
		"the first pack is walking in and the card is back on the stage")


func test_a_set_piece_outranks_an_ordinary_assault() -> void:
	_install({"report": {"live": 6, "breached": false},
		"preview": {"active": true, "set_piece": true}})
	assert_eq(LcnWorldWatch.watch(), LcnWorldWatch.Watch.SET_PIECE)


func test_a_breach_outranks_everything() -> void:
	_install({"report": {"live": 6, "breached": true},
		"preview": {"active": true, "set_piece": true}})
	assert_eq(LcnWorldWatch.watch(), LcnWorldWatch.Watch.BREACH)


func test_a_set_piece_that_is_not_running_yet_does_not_hold_the_stage() -> void:
	# A night the director has PLANNED as a set piece is not a reason to take the
	# card away at noon. Only a set piece that is actually running is.
	_install({"report": {}, "preview": {"active": false, "set_piece": true,
		"known": true, "seconds_until": 900.0}})
	assert_eq(LcnWorldWatch.watch(), LcnWorldWatch.Watch.NONE)


func test_the_countdown_window_is_exactly_the_lead() -> void:
	_install({"report": {}, "preview": {"active": false, "known": true,
		"seconds_until": LcnWorldWatch.LEAD_SECONDS - 1.0}})
	assert_eq(LcnWorldWatch.watch(), LcnWorldWatch.Watch.INBOUND)
	_install({"report": {}, "preview": {"active": false, "known": true,
		"seconds_until": LcnWorldWatch.LEAD_SECONDS + 1.0}})
	assert_eq(LcnWorldWatch.watch(), LcnWorldWatch.Watch.NONE)


## A wave nobody has seen yet is not a reason to clear the stage: [P08] redacts
## the countdown by how much the player has scouted, and taking the card away on
## a number the game refuses to show them would be the interface knowing
## something the player is not allowed to know.
func test_an_unknown_countdown_does_not_hold_the_stage() -> void:
	_install({"report": {}, "preview": {"active": false, "known": false,
		"seconds_until": 5.0}})
	assert_eq(LcnWorldWatch.watch(), LcnWorldWatch.Watch.NONE)


## Every rung has a sentence for the player. A watch state with no `because` is a
## card that vanishes with no explanation.
func test_every_watched_state_says_why() -> void:
	for w: int in [LcnWorldWatch.Watch.INBOUND, LcnWorldWatch.Watch.ASSAULT,
			LcnWorldWatch.Watch.SET_PIECE, LcnWorldWatch.Watch.BREACH]:
		assert_ne(LcnWorldWatch.because(w), "",
			"%s has no sentence to show the player" % LcnWorldWatch.name_of(w))
	assert_eq(LcnWorldWatch.because(LcnWorldWatch.Watch.NONE), "")


# =========================================================================
#  the stand-in is held against the real one
# =========================================================================

## THE GUARD ON THE RUNGS ABOVE. If [P08] renames `breached`, drops `live` or
## stops publishing `set_piece`, the stand-in tests would all still pass while
## the rule read nothing in the running game. So the keys the rule depends on are
## asserted to exist on the REAL system, in the shape the stand-in imitates.
func test_the_stand_in_answers_what_the_real_one_answers() -> void:
	var threat: SimSystem = world.system(&"threat")
	assert_not_null(threat, "no threat director in this world")
	for m: StringName in [&"current_wave_report", &"next_wave_preview", &"metrics"]:
		assert_true(threat.has_method(m),
			"[P08] no longer answers %s(); the rule is reading nothing" % m)
	var preview: Dictionary = threat.call(&"next_wave_preview") as Dictionary
	for key: String in ["active", "set_piece", "known", "seconds_until"]:
		assert_true(preview.has(key),
			"next_wave_preview() no longer carries '%s'" % key)
	assert_true((threat.call(&"metrics") as Dictionary).has("live"),
		"threat metrics no longer carry 'live'")
	# `current_wave_report()` is empty unless a night is running, so its keys are
	# checked against the source of truth rather than against a quiet tick.
	var src: String = FileAccess.get_file_as_string(
		"res://game/sim/threat/threat_system.gd")
	for key: String in ["\"breached\"", "\"live\""]:
		assert_true(src.find(key) >= 0,
			"threat_system.gd no longer publishes %s anywhere" % key)


# ------------------------------------------------------------------ stand-in --

var _stub: SimSystem = null
var _real: SimSystem = null


func _install(answers: Dictionary) -> void:
	_uninstall()
	_real = Sim.by_name.get(&"threat")
	_stub = WatchStub.new()
	(_stub as WatchStub).answers = answers
	Sim.by_name[&"threat"] = _stub
	# [P07] must not answer over the top of the stand-in, or the ordering under
	# test would be [P07]'s and not the rule's.
	_real_combat = Sim.by_name.get(&"combat")
	Sim.by_name.erase(&"combat")


var _real_combat: SimSystem = null


func _uninstall() -> void:
	if _stub == null:
		return
	if _real != null:
		Sim.by_name[&"threat"] = _real
	else:
		Sim.by_name.erase(&"threat")
	if _real_combat != null:
		Sim.by_name[&"combat"] = _real_combat
	_stub = null
	_real = null
	_real_combat = null


class WatchStub extends SimSystem:
	var answers: Dictionary = {}

	func system_name() -> StringName:
		return &"threat"

	func current_wave_report() -> Dictionary:
		return answers.get("report", {})

	func next_wave_preview() -> Dictionary:
		return answers.get("preview", {})

	func metrics() -> Dictionary:
		return {"live": int((answers.get("report", {}) as Dictionary).get("live", 0))}
