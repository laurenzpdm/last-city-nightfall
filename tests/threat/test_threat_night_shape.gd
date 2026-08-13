extends TestCase
## [C5] The shape of a night, and the guarantee that one always ends.
##
## Three findings from a real 24000-tick run are pinned here:
##
##   1. every packet of night one arrived on the same tick and the fight was
##      over in 264 of the night's 3264 ticks — the other 92% was silence;
##   2. wave two "ended" at dawn with a survivor left standing on the map, which
##      then held `live` above zero for ever;
##   3. the whole campaign fired 43 shots in three days, because the waves were
##      two orders of magnitude smaller than the wall they exist to test.

const HORIZON: int = 30

var world: SimFixture = null
var threat: SimSystem = null


func requires_systems() -> PackedStringArray:
	return PackedStringArray(["threat"])


func setup() -> void:
	world = SimFixture.new(31).start()
	threat = world.system(&"threat")


func teardown() -> void:
	if world != null:
		world.stop()


func _profile() -> ThreatProfile:
	return threat.call("profile") as ThreatProfile


func _plan() -> WavePlan:
	return threat.call("plan") as WavePlan


func _state() -> String:
	return String((threat.call("serialize") as Dictionary).get("state", ""))


## Runs until a wave is live, or gives up.
func _run_to_night(limit: int = 12000) -> bool:
	for _i: int in limit / 20:
		world.run(20)
		if _state() == "active":
			return true
	return false


# --- the rhythm ------------------------------------------------------------------

func test_a_night_arrives_in_pulses_not_in_one_blob() -> void:
	assert_true(_run_to_night(), "the fixture must reach a night")
	var p: WavePlan = _plan()
	assert_not_null(p, "there is a plan")
	if p.unit_count() <= 1:
		skip("a one-unit night cannot have a rhythm")
		return
	var moments: Dictionary = {}
	for g: WaveGroup in p.groups:
		moments[g.delay_ticks] = true
	assert_ge(float(moments.size()), 2.0,
		"a night with %d bodies in it must arrive at more than one moment" % p.unit_count())


func test_the_arrivals_are_spread_over_the_night_that_is_actually_being_fought() -> void:
	assert_true(_run_to_night(), "the fixture must reach a night")
	var p: WavePlan = _plan()
	var night: int = p.dawn_tick - p.night_start_tick
	if night <= 0 or p.groups.size() < 2:
		skip("no measurable night in this build")
		return
	var last: int = 0
	for g: WaveGroup in p.groups:
		last = maxi(last, g.delay_ticks)
	assert_gt(float(last), float(night) * 0.35,
		"the last packet must arrive deep into the night, not in its first third "
		+ "(last %d of %d ticks)" % [last, night])
	assert_lt(float(last), float(night),
		"but never after dawn, or it could not be fought at all")


func test_every_body_that_was_promised_still_arrives() -> void:
	# Splitting a wave into pulses must not lose or invent a single body: the
	# telegraph promised an exact roster at 0:15.
	assert_true(_run_to_night(), "the fixture must reach a night")
	var p: WavePlan = _plan()
	var by_kind: Dictionary = p.counts_by_kind()
	var total: int = 0
	for k: String in by_kind:
		total += int(by_kind[k])
	assert_eq(total, p.unit_count(), "the counts add back up exactly")
	assert_gt(float(total), 0.0, "and there is a night at all")


# --- a night always ends ----------------------------------------------------------

func test_a_night_always_ends_and_leaves_nothing_standing() -> void:
	assert_true(_run_to_night(), "the fixture must reach a night")
	var combat: SimSystem = world.system(&"combat")
	# Two full days: the night, the dawn, and the whole day after it.
	world.run(20000)
	assert_ne(_state(), "active", "the night is over")
	if combat == null:
		skip("no [P07] in this build to hold bodies")
		return
	assert_eq(int(combat.call("live_enemy_count")), 0,
		"and nothing of it is still fighting the day after — that leftover is the "
		+ "bug that froze the campaign on wave two")


func test_the_hard_timeout_can_end_a_night_nothing_else_can() -> void:
	var p: ThreatProfile = _profile()
	assert_gt(float(p.wave_hard_timeout_ticks), 0.0, "there is a ceiling at all")
	world.cmd_now({"system": &"threat", "op": "force_wave"})
	assert_eq(_state(), "active", "a wave is live")
	var errors: int = Log.errors
	# Longer than any night, and the watchdog is the only thing that can act.
	world.run(p.wave_hard_timeout_ticks + 200)
	assert_ne(_state(), "active", "a night that outlives its own ceiling is resolved")
	assert_gt(float(Log.errors), float(errors),
		"and it is an ERROR, because a night that runs that long is a bug, not weather")


func test_the_campaign_keeps_starting_nights() -> void:
	# waves_started sticking is exactly how "wave 3 never arrives" reads from
	# outside. Three campaign days must produce three nights.
	world.run(29000)
	var s: Dictionary = threat.call("serialize")
	assert_ge(float(s["waves_started"]), 3.0,
		"three days must have started three nights, not frozen on two")
	assert_ge(float(s["waves_survived"]), 2.0, "and the finished ones must be counted")


# --- the record a critic reads ------------------------------------------------------

func test_every_finished_night_leaves_a_row_with_the_numbers_in_it() -> void:
	world.run(20000)
	var nights: Array[Dictionary] = threat.call("nights")
	assert_not_empty(nights, "a finished night writes itself down")
	var row: Dictionary = nights[0]
	for key: String in ["night", "spawned", "killed", "withdrew", "shots_fired",
			"heat_spent", "damage_taken", "structures_lost", "cold_turrets", "verdict"]:
		assert_has(row, key, "the night's record carries '%s'" % key)
	assert_le(float(row["killed"]) + float(row["withdrew"]), float(row["spawned"]) + 0.001,
		"nothing may be killed AND have walked away")


func test_a_night_has_a_verdict_before_it_has_a_number() -> void:
	var held: int = ThreatDefs.verdict_of(
		{"spawned": 20, "killed": 20, "structures_lost": 0, "breached": false}, true, 0)
	var costly: int = ThreatDefs.verdict_of(
		{"spawned": 20, "killed": 20, "structures_lost": 3, "breached": false}, true, 0)
	var through: int = ThreatDefs.verdict_of(
		{"spawned": 20, "killed": 18, "structures_lost": 3, "breached": true}, false, 2)
	var overrun: int = ThreatDefs.verdict_of(
		{"spawned": 20, "killed": 2, "structures_lost": 9, "breached": true}, false, 18)
	assert_gt(float(held), float(costly), "a clean night reads better than an expensive one")
	assert_gt(float(costly), float(through), "and losing the line is worse again")
	assert_gt(float(through), float(overrun), "and being overrun is the worst of all")
	for i: int in [held, costly, through, overrun]:
		assert_ne(ThreatDefs.verdict_label(i), "", "every verdict has words a human wrote")


# --- the curve, against the wall it has to test ---------------------------------------

func test_the_curve_reaches_the_defence_it_exists_to_test() -> void:
	# The whole "43 shots in three days" finding in one assertion. Four burner
	# cannons sustain ~139 damage a second; a night is about 160 seconds. A wave
	# that cannot occupy a fraction of that is not a tower-defence night.
	var p: ThreatProfile = _profile()
	assert_le(p.base_budget(1), 12.0, "night one stays a teaching night")
	assert_ge(p.base_budget(3), 40.0, "night three has to be a real fight")
	assert_ge(p.base_budget(6), 120.0, "and by night six it has to be a siege")
	for n: int in range(2, HORIZON):
		assert_gt(p.base_budget(n), p.base_budget(n - 1),
			"the authored curve never goes backwards (night %d)" % n)
