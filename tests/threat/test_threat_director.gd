extends TestCase
## [P08] Threat Director — the live system: telegraphing, the wave lifecycle,
## adaptation bounds, and the contracts the HUD is built on.
##
## The rule these tests exist to defend: **the player is never surprised by
## anything except the details.** A wave is announced before it arrives, from a
## direction that is named out loud, at a size that is stated in words, and the
## multiplier that decided that size is readable at every moment.

var world: SimFixture = null
var threat: SimSystem = null


func requires_systems() -> PackedStringArray:
	return PackedStringArray(["threat"])


func setup() -> void:
	world = SimFixture.new(5).start()
	threat = world.system(&"threat")


func teardown() -> void:
	if world != null:
		world.stop()


func _profile() -> ThreatProfile:
	return threat.call("profile") as ThreatProfile


func _preview() -> Dictionary:
	return threat.call("next_wave_preview")


func _serialize() -> Dictionary:
	return threat.call("serialize")


## Runs until night, or until `limit` ticks have passed.
func _run_to_night(limit: int = 12000) -> bool:
	var climate: SimSystem = world.system(&"climate")
	for _i: int in limit / 20:
		world.run(20)
		if climate != null and bool(climate.call("is_night")):
			return true
		if String(_serialize().get("state", "")) == "active":
			return true
	return false


# --- the contracts the HUD is built on ------------------------------------------

func test_threat_level_is_a_bounded_number_at_every_moment() -> void:
	for _i: int in 60:
		world.run(100)
		var lvl: float = float(threat.call("threat_level"))
		assert_between(lvl, 0.0, 1.0, "threat_level must stay 0..1 at tick %d" % world.tick())


func test_preview_exists_from_the_first_tick() -> void:
	var p: Dictionary = _preview()
	assert_eq(int(p["wave"]), 1, "the first night is planned before the first tick")
	assert_has(p, "strength_label", "the HUD needs a word, not only a number")
	assert_has(p, "pressure_band", "the band is published on every preview")
	assert_has(p, "reasons", "and so is the reason the night is that size")
	assert_eq(p["pressure_band"], _profile_band(), "the band shown is the band used")


func _profile_band() -> String:
	var p: ThreatProfile = _profile()
	return "%.2f..%.2f" % [p.adapt_min, p.adapt_max]


func test_the_preview_is_redacted_until_it_is_earned() -> void:
	var early: Dictionary = _preview()
	assert_eq(int(early["precision"]), -1, "nothing is known before the first warning")
	assert_false(bool(early["known"]), "and it says so")
	assert_has_not(early, "composition", "and certainly not the roster")
	assert_has_not(early, "vectors", "nor the exact gate")
	assert_has_not(early, "directions", "nor even a direction")
	assert_true(_run_to_night(), "the fixture must reach a night")
	var late: Dictionary = _preview()
	assert_true(bool(late["known"]), "by nightfall the plain has shown itself")
	assert_has(late, "directions", "and named the roads it is on")
	assert_has(late, "composition", "and stated what is on them")


func test_precision_climbs_rung_by_rung() -> void:
	var seen: Array[int] = []
	var climate: SimSystem = world.system(&"climate")
	for _i: int in 600:
		world.run(20)
		var p: Dictionary = _preview()
		var prec: int = int(p["precision"])
		if seen.is_empty() or prec != seen[seen.size() - 1]:
			seen.append(prec)
		if climate != null and bool(climate.call("is_night")):
			break
	assert_gt(float(seen.size()), 2.0, "the ladder must have rungs: saw %s" % str(seen))
	for i: int in range(1, seen.size()):
		assert_ge(float(seen[i]), float(seen[i - 1]),
			"precision must never go backwards: %s" % str(seen))
	assert_ge(float(seen[seen.size() - 1]), 2.0,
		"by nightfall the player must know more than a direction")


func test_the_warning_ladder_fires_before_the_night() -> void:
	var fired: Array[Dictionary] = []
	var bus: Node = TestEnv.bus()
	var probe: Callable = func(w: int, secs: float) -> void:
		fired.append({"wave": w, "secs": secs})
	bus.wave_incoming.connect(probe)
	var reached: bool = _run_to_night()
	bus.wave_incoming.disconnect(probe)
	assert_true(reached, "the fixture must reach a night")
	assert_ge(float(fired.size()), float(_profile().warning_offsets_ticks.size()),
		"every rung of the ladder must reach the Bus")
	for i: int in range(1, fired.size()):
		assert_le(float(fired[i]["secs"]), float(fired[i - 1]["secs"]),
			"each warning must be closer to nightfall than the last")
	assert_gt(float(fired[0]["secs"]), 60.0,
		"the first warning must leave the player real time to act")


func test_a_wave_starts_and_ends() -> void:
	assert_true(_run_to_night(), "the fixture must reach a night")
	assert_eq(String(_serialize()["state"]), "active", "night means an active wave")
	var report: Dictionary = threat.call("current_wave_report")
	assert_eq(int(report["wave"]), 1, "the live report names the night being fought")
	# Run past dawn.
	world.run(6000)
	var s: Dictionary = _serialize()
	assert_ge(float(s["waves_survived"]), 1.0, "a night always ends")
	var post: Dictionary = threat.call("last_wave_report")
	assert_eq(int(post["wave"]), 1, "and leaves a post-mortem behind")
	assert_has(post, "outcome", "with the numbers it was measured on")
	assert_has(post, "comfort", "and the comfort those produced")
	assert_has(post["outcome"], "spawned", "including what was actually sent")


func test_the_night_that_arrives_is_the_night_that_was_promised() -> void:
	# A box, not a plain local: a GDScript lambda captures locals BY VALUE, so a
	# probe that assigns to an outer variable silently records nothing.
	var box: Array = []
	var bus: Node = TestEnv.bus()
	var probe: Callable = func(key: StringName, payload: Dictionary) -> void:
		if key == ThreatDefs.KEY_WARNING and int(payload.get("precision", 0)) >= 3:
			box.append(payload.duplicate(true))
	bus.narrative_event.connect(probe)
	var reached: bool = _run_to_night()
	bus.narrative_event.disconnect(probe)
	assert_true(reached, "the fixture must reach a night")
	assert_not_empty(box, "the last warning must state the full composition")
	if box.is_empty():
		return
	var promised: Dictionary = box[box.size() - 1]
	var arrived: Dictionary = threat.call("plan").call("counts_by_kind")
	var told: Dictionary = (promised["preview"] as Dictionary).get("composition", {})
	assert_eq(told, arrived, "what was promised at 0:15 must be what walks in at 0:00")


# --- adaptation, and its declared bounds -----------------------------------------

func test_pressure_can_never_leave_the_band() -> void:
	var p: ThreatProfile = _profile()
	var tracker := PressureTracker.new(p)
	# Fifty flawless nights, then fifty catastrophic ones. Neither may push the
	# multiplier outside what the profile publicly declares.
	for _i: int in 50:
		tracker.record({"spawned": 40, "killed": 40, "structures_lost": 0,
			"closest_cells": 200, "night_ticks": 3000, "heat_ok_ticks": 3000})
		assert_between(tracker.pressure, p.adapt_min, p.adapt_max, "after a good night")
	assert_near(tracker.pressure, p.adapt_max, 0.0001, "a dominant player reaches the ceiling")
	for _j: int in 50:
		tracker.record({"spawned": 40, "killed": 0, "structures_lost": 30,
			"closest_cells": 0, "night_ticks": 3000, "heat_ok_ticks": 0})
		assert_between(tracker.pressure, p.adapt_min, p.adapt_max, "after a bad night")
	assert_near(tracker.pressure, p.adapt_min, 0.0001, "a losing player reaches the floor")


func test_adaptation_moves_slowly_enough_to_be_fair() -> void:
	var p: ThreatProfile = _profile()
	var tracker := PressureTracker.new(p)
	var before: float = tracker.pressure
	tracker.record({"spawned": 40, "killed": 40, "structures_lost": 0,
		"closest_cells": 200, "night_ticks": 3000, "heat_ok_ticks": 3000})
	assert_le(absf(tracker.pressure - before), p.adapt_rate * PressureTracker.RELIEF_BIAS + 0.0001,
		"one night must never swing the campaign")
	assert_gt(tracker.pressure, before, "but a comfortable night must move it")


func test_relief_is_faster_than_punishment() -> void:
	var p: ThreatProfile = _profile()
	var up := PressureTracker.new(p)
	var down := PressureTracker.new(p)
	var good: Dictionary = {"spawned": 10, "killed": 10, "structures_lost": 0,
		"closest_cells": 200, "night_ticks": 100, "heat_ok_ticks": 100}
	var bad: Dictionary = {"spawned": 10, "killed": 0, "structures_lost": 20,
		"closest_cells": 0, "night_ticks": 100, "heat_ok_ticks": 0}
	up.record(good)
	down.record(bad)
	assert_gt(absf(down.pressure - 1.0), absf(up.pressure - 1.0),
		"a player being taken apart gets help sooner than a coasting one gets punished")


func test_comfort_reads_the_four_things_it_claims_to() -> void:
	var p: ThreatProfile = _profile()
	var t := PressureTracker.new(p)
	var base: Dictionary = {"spawned": 20, "killed": 20, "structures_lost": 0,
		"closest_cells": p.breach_radius * 3, "night_ticks": 100, "heat_ok_ticks": 100}
	var perfect: float = t.comfort_of(base)
	assert_near(perfect, 1.0, 0.001, "nothing lost, nothing through, nothing cold")
	for key: String in ["killed", "closest_cells", "structures_lost", "heat_ok_ticks"]:
		var worse: Dictionary = base.duplicate()
		match key:
			"killed": worse[key] = 0
			"closest_cells": worse[key] = 0
			"structures_lost": worse[key] = int(p.comfort_loss_scale)
			"heat_ok_ticks": worse[key] = 0
		assert_lt(t.comfort_of(worse), perfect, "'%s' must move comfort" % key)
	var disaster: Dictionary = {"spawned": 20, "killed": 0, "structures_lost": 40,
		"closest_cells": 0, "night_ticks": 100, "heat_ok_ticks": 0}
	assert_near(t.comfort_of(disaster), 0.0, 0.001, "everything wrong reads as zero")


func test_set_pressure_command_is_clamped_to_the_band() -> void:
	var p: ThreatProfile = _profile()
	world.cmd_now({"system": &"threat", "op": "set_pressure", "value": 9.0})
	assert_le(float(threat.call("pressure")), p.adapt_max, "no command may exceed the band")
	world.cmd_now({"system": &"threat", "op": "set_pressure", "value": -5.0})
	assert_ge(float(threat.call("pressure")), p.adapt_min, "nor undercut it")
	world.cmd_now({"system": &"threat", "op": "set_pressure", "value": 0.5})
	assert_near(float(threat.call("pressure")), (p.adapt_min + p.adapt_max) * 0.5, 0.001,
		"0..1 is read as a position inside the band")


# --- commands and state -----------------------------------------------------------

func test_peace_mode_stops_the_nights() -> void:
	world.cmd_now({"system": &"threat", "op": "peace", "on": true})
	world.run(11000)
	assert_eq(int(_serialize()["waves_started"]), 0, "peace means no wave ever starts")
	assert_true(bool(_serialize()["peace"]), "and it says so")


func test_force_wave_starts_one_immediately() -> void:
	world.cmd_now({"system": &"threat", "op": "force_wave"})
	assert_eq(String(_serialize()["state"]), "active", "a forced wave is live at once")
	assert_ge(float(_serialize()["waves_started"]), 1.0, "and counted")


func test_force_wave_scales_the_budget() -> void:
	var base: float = float(_preview()["strength"])
	world.cmd_now({"system": &"threat", "op": "force_wave", "strength": 3.0})
	assert_gt(float(threat.call("plan").get("budget")), 0.0, "a forced wave still has a budget")
	assert_gt(float(_serialize()["budget"]), base, "and the multiplier reached it")


func test_spawn_command_puts_something_on_the_map() -> void:
	var ids: Array[StringName] = Registry.ids("enemies")
	if ids.is_empty():
		skip("game/content/enemies/ is empty in this build")
		return
	world.cmd_now({"system": &"threat", "op": "spawn", "kind": String(ids[0]), "count": 3})
	assert_eq(String(_serialize()["state"]), "active", "a spawn opens a night")


func test_an_unknown_command_is_an_error_not_a_shrug() -> void:
	var run: Callable = func() -> void:
		world.cmd_now({"system": &"threat", "op": "definitely_not_an_op"})
	assert_throws(run, "unknown command op", "a broken script must turn a run red")


func test_state_survives_a_round_trip() -> void:
	world.run(3000)
	var before: Dictionary = _serialize()
	threat.call("deserialize", before)
	var after: Dictionary = _serialize()
	assert_eq(after["wave"], before["wave"], "the wave survives")
	assert_eq(after["pressure"], before["pressure"], "the pressure survives")
	assert_eq(after["pressure_band"], before["pressure_band"], "the band survives")
	assert_eq(after["waves_cleared"], before["waves_cleared"], "the tally survives")
	assert_eq((after["plan"] as Dictionary).get("composition"),
		(before["plan"] as Dictionary).get("composition"), "and so does tonight's roster")


func test_metrics_publish_the_contract() -> void:
	var m: Dictionary = threat.call("metrics")
	for key: String in ["wave", "threat_level", "budget", "waves_cleared", "pressure_band"]:
		assert_has(m, key, "metrics must publish '%s'" % key)
	assert_between(float(m["threat_level"]), 0.0, 1.0, "threat_level is 0..1")
	assert_eq(m["pressure_band"], _profile_band(), "the band in metrics is the band in force")


func test_serialize_is_json_safe() -> void:
	world.run(2000)
	var text: String = JSON.stringify(_serialize())
	assert_gt(float(text.length()), 100.0, "the state must actually serialize")
	assert_ne(JSON.parse_string(text), null, "and parse back")


# --- the whole system, twice ------------------------------------------------------

func test_two_identical_runs_produce_one_campaign() -> void:
	if world.system(&"threat") == null:
		skip("no threat system")
		return
	var diff: PackedStringArray = SimFixture.replay_diff(19, 400)
	assert_empty(diff, "same seed, same world: %s" % ", ".join(diff))
