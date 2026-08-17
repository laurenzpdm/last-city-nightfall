extends TestCase
## [P24] The menu is not allowed to state a fact about a city it cannot check.
##
## THE FRAME THIS SUITE WAS WRITTEN FROM. A critic photographed the title screen
## and read back:
##
##     Continue — Dawn of day 4  ·  0 alive.
##
## Two separate defects in one line. `LcnSaveManager.describe_world()` seeded
## `pop = 0` and wrote it into every header whether or not [P05] was in the
## world, so "no citizens system" and "a city of nobody" arrived at the reader as
## the same integer; and `Continue` resumed the newest file on disk without ever
## asking whether there was anything left in it. Both are the same mistake — the
## interface asserting something it has not established — and the rule the HUD
## already follows is the fix: a panel that cannot compute a figure says nothing,
## and it never says zero.
##
## WHAT WOULD MAKE THIS SUITE RED:
##   * putting a `0` default back on `header.get("population", …)` anywhere —
##     `describe_slot` immediately starts printing "0 alive" again;
##   * `describe_world()` writing `population` / `hope` unconditionally — the
##     absent-key tests below go red because the key is present and zero;
##   * pointing the title screen back at `most_recent()` — the dead city is
##     offered as somewhere to carry on;
##   * `souls_words` collapsing "no figure" and "zero" back into one branch.
##
## Verified the hard way rather than assumed: with the old `describe_slot` body
## pasted back over the new one in a scratch copy, `test_a_header_with_no_count`
## and `test_an_ended_city` both fail on the string they print.

const LIVING: String = "menu_zero_alive"
const ENDED: String = "menu_zero_dead"

var world: SimFixture


func requires_systems() -> PackedStringArray:
	return PackedStringArray(["citizens"])


func setup() -> void:
	world = SimFixture.new(7).start()


func teardown() -> void:
	world.stop()
	var _a: bool = LcnSaveManager.delete(LcnSaveSlots.scratch(LIVING))
	var _b: bool = LcnSaveManager.delete(LcnSaveSlots.scratch(ENDED))


# ============================================================ the three cases ===

## The one distinction the old code could not make.
func test_a_missing_count_and_a_count_of_zero_are_not_the_same_answer() -> void:
	assert_eq(LcnSaveManager.souls_of({}), -1,
		"a header with no population key does not know how many are alive")
	assert_eq(LcnSaveManager.souls_of({"population": 0}), 0,
		"a header that recorded zero knows the answer, and it is zero")
	assert_eq(LcnSaveManager.souls_of({"population": 18}), 18, "and eighteen is eighteen")


func test_a_header_with_no_count_says_nothing_about_the_living() -> void:
	var head: Dictionary = {"name": "Dawn of day 4", "day": 4,
		"saved_unix": int(Time.get_unix_time_from_system())}
	var line: String = LcnSaveManager.describe_slot(head)
	assert_false(line.contains("alive"),
		"a save that never recorded a population does not claim one: '%s'" % line)
	assert_false(line.contains("no one left"),
		"and it does not declare the city dead either — it does not know: '%s'" % line)
	assert_eq(LcnSaveManager.souls_words(head), "", "the clause is simply absent")
	assert_true(line.contains("just now"),
		"the rest of the line is unchanged: '%s'" % line)


func test_an_ended_city_says_so_in_words_rather_than_as_a_tally() -> void:
	var head: Dictionary = {"name": "Dawn of day 4", "day": 4, "population": 0,
		"saved_unix": int(Time.get_unix_time_from_system())}
	var line: String = LcnSaveManager.describe_slot(head)
	assert_false(line.contains("0 alive"),
		"'0 alive' is a tally of a city that is not there: '%s'" % line)
	assert_true(line.contains("no one left"),
		"an empty city is described as one: '%s'" % line)


func test_a_living_city_still_counts_normally() -> void:
	var head: Dictionary = {"name": "Kettle Row", "day": 3, "population": 18,
		"saved_unix": int(Time.get_unix_time_from_system())}
	var line: String = LcnSaveManager.describe_slot(head)
	assert_true(line.contains("18 alive"), "eighteen souls are eighteen souls: '%s'" % line)
	assert_true(line.contains("day 3"), "and the day is still there: '%s'" % line)


func test_only_a_recorded_zero_stops_a_save_being_resumable() -> void:
	assert_false(LcnSaveManager.is_resumable({}), "there is nothing to resume in nothing")
	assert_false(LcnSaveManager.is_resumable({"population": 0, "day": 4}),
		"a city with nobody in it is not somewhere to carry on")
	assert_true(LcnSaveManager.is_resumable({"population": 1, "day": 4}),
		"one survivor is still a city")
	assert_true(LcnSaveManager.is_resumable({"day": 4}),
		"a build that cannot count people does not get to declare the city dead")


# ================================================== against the world and disk ===

## The other half: the header has to CARRY the figure when the world can answer,
## or the readers above would be papering over a live bug instead of a missing
## system.
func test_a_live_world_records_the_population_it_actually_has() -> void:
	world.run(200)
	var head: Dictionary = LcnSaveManager.describe_world()
	assert_true(head.has("population"),
		"[P05] is in this build, so the header carries a count")
	var cit: SimSystem = Sim.get_system(&"citizens")
	assert_not_null(cit, "the fixture has a citizens system")
	assert_eq(int(head["population"]), int(cit.metrics().get("population", -1)),
		"and it is the count the simulation is holding, not a default")
	assert_true(head.has("day"), "the climate answered too")


## Continue walks past an ended city to the last one that still has people in it.
## Written through real files rather than a stubbed list, because `slots()` reads
## the disk and the ordering it applies is half of what is being tested.
func test_continue_reaches_past_a_dead_city_to_a_living_one() -> void:
	world.run(200)
	var payload: Dictionary = Sim.serialize()
	var live_slot: String = LcnSaveSlots.scratch(LIVING)
	var dead_slot: String = LcnSaveSlots.scratch(ENDED)
	# STAMPED IN THE NEAR FUTURE, AND THAT IS THE POINT OF THE STAGING.
	# `user://saves/` is one directory per MACHINE (see LcnSaveSlots), so the
	# real autosaves of whatever else is running here are also in this list. The
	# condition under test is "the NEWEST save on disk is an ended city", and
	# these two timestamps are what puts this suite's own pair at the front of
	# `slots()` on a shared box instead of hoping nobody else wrote one.
	var soon: int = int(Time.get_unix_time_from_system()) + 300
	assert_eq(_write(live_slot, "Kettle Row", 3, 18, soon, payload), OK,
		"the older, living save is on disk")
	assert_eq(_write(dead_slot, "Dawn of day 4", 4, 0, soon + 300, payload), OK,
		"the newer, ended save is on disk")

	var newest: Dictionary = LcnSaveManager.most_recent()
	assert_eq(String(newest.get("slot", "")), dead_slot,
		"the browser still sees the ended city, and sees it first")
	var resume: Dictionary = LcnSaveManager.most_recent_playable()
	assert_eq(String(resume.get("slot", "")), live_slot,
		"but Continue resumes the last city that still had somebody in it")
	assert_false(LcnSaveManager.describe_slot(newest).contains("0 alive"),
		"and the ended city is never described as a count of zero")


## And when every file on disk is a city that fell, there is no Continue at all —
## the row is absent rather than pointing at nothing.
func test_when_every_save_is_an_ended_city_there_is_nothing_to_continue() -> void:
	var all: Array[Dictionary] = LcnSaveManager.slots()
	var living: int = 0
	for head: Dictionary in all:
		if LcnSaveManager.is_resumable(head):
			living += 1
	# The machine may carry another agent's saves; this asserts the RULE against
	# whatever is actually there, which is stronger than asserting an empty disk.
	var resume: Dictionary = LcnSaveManager.most_recent_playable()
	if living == 0:
		assert_true(resume.is_empty(),
			"%d save(s) on disk, none of them a living city, so no Continue row" % all.size())
	else:
		assert_true(LcnSaveManager.is_resumable(resume),
			"whatever Continue points at, it has people in it")


func _write(slot: String, display: String, day: int, pop: int, when: int,
		payload: Dictionary) -> int:
	return LcnSaveFile.write(slot, {
		"name": display, "day": day, "population": pop, "phase": "dawn",
		"tick": SimClock.tick, "seed": str(Rng.seed_value), "city": "Caldera Nine",
		"saved_unix": when, "autosave": false,
	}, payload, PackedByteArray())
