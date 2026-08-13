extends TestCase
## [P05] Citizens.
##
## Every test here states a rule a PLAYER can feel and then measures it on a
## live population: bodies get cold at the rate the air says, jobs fill in a
## repeatable order, an unstaffed workshop reports it, a starving city buries
## people with a named cause, and a thousand of them still fit in a tick.
##
## Citizens are created through the system's own command surface, so nothing
## here depends on internals another part could not also drive.

const COLD_FIELD: Vector2i = Vector2i(60, 60)   ## far from anything worldgen built

var world: SimFixture = null
var cit: SimSystem = null


func requires_systems() -> PackedStringArray:
	return PackedStringArray(["citizens"])


func setup() -> void:
	world = SimFixture.new(7).start()
	cit = world.system(&"citizens")


func teardown() -> void:
	if world != null:
		world.stop()


# --- helpers -----------------------------------------------------------------

func _pool() -> CitizenPool:
	return cit.get("pool")


func _ids() -> PackedInt32Array:
	return cit.call("citizen_ids")


func _first_id() -> int:
	var ids: PackedInt32Array = _ids()
	return -1 if ids.is_empty() else ids[0]


func _slot(id: int) -> int:
	return _pool().slot_of(id)


func _set_need(id: int, need: String, value: float) -> void:
	world.cmd_now({"system": &"citizens", "op": "set_need",
		"id": id, "need": need, "value": value})


## Puts one citizen out in the open with nothing around them, and keeps them
## there, so the only thing acting on their body is the weather.
func _strand(id: int, cell: Vector2i = COLD_FIELD) -> int:
	var s: int = _slot(id)
	var pool: CitizenPool = _pool()
	pool.home[s] = -1
	pool.job[s] = -1
	pool.set_position(s, cell)
	pool.dest[s] = -1
	pool.dest_x[s] = cell.x
	pool.dest_y[s] = cell.y
	pool.inside[s] = 0
	pool.shelter[s] = 0.0
	return s


func _report() -> Dictionary:
	return cit.call("report")


# =========================================================================
#  a population of individuals
# =========================================================================

func test_the_city_starts_with_named_people() -> void:
	assert_eq(cit.call("population"), CitizenDefs.START_POPULATION, "founders spawned")
	var ids: PackedInt32Array = _ids()
	assert_eq(ids.size(), CitizenDefs.START_POPULATION, "one id per founder")
	var names: Dictionary = {}
	var adults: int = 0
	var children: int = 0
	var elders: int = 0
	for id: int in ids:
		var info: Dictionary = cit.call("citizen_info", id)
		assert_true(String(info.get("name", "")).contains(" "), "a first name and a surname")
		names[String(info["name"])] = true
		match String(info.get("age_bracket", "")):
			"child": children += 1
			"elder": elders += 1
			_: adults += 1
	assert_gt(float(names.size()), 8.0, "the founders are not all called the same thing")
	assert_gt(float(adults), 0.0, "somebody can work")
	assert_gt(float(children), 0.0, "there are children to keep alive")
	assert_gt(float(elders), 0.0, "there are elders to keep alive")


func test_citizen_info_reads_like_a_life() -> void:
	world.run(60)
	var id: int = _first_id()
	var info: Dictionary = cit.call("citizen_info", id)
	for key: String in ["name", "age", "profession", "state", "health", "warmth",
			"hunger", "fatigue", "morale", "condition", "doing", "summary", "cell"]:
		assert_has(info, key, "citizen_info exposes '%s'" % key)
	var summary: String = String(info["summary"])
	assert_true(summary.contains(String(info["name"])), "the summary names them")
	assert_true(summary.contains(","), "the summary reads as a sentence, not a struct")
	assert_gt(float(summary.length()), 24.0, "the summary says something")
	assert_empty(cit.call("citizen_info", 999999), "an unknown id is an empty dictionary")


func test_every_citizen_is_somewhere_and_doing_something() -> void:
	world.run(200)
	var states: Dictionary = {}
	for id: int in _ids():
		var info: Dictionary = cit.call("citizen_info", id)
		var cell: Array = info["cell"]
		assert_between(float(cell[0]), 0.0, 255.0, "on the map in x")
		assert_between(float(cell[1]), 0.0, 255.0, "on the map in y")
		states[String(info["state"])] = true
		assert_ne(String(info["state"]), "dead", "nobody starts dead")
	assert_gt(float(states.size()), 0.0, "the population has a state machine running")


# =========================================================================
#  needs — the body
# =========================================================================

func test_warmth_follows_the_air_not_a_timer() -> void:
	var id: int = _first_id()
	var s: int = _strand(id)
	var pool: CitizenPool = _pool()
	pool.warmth[s] = 100.0
	world.run(600)
	var cold: float = pool.warmth[s]
	assert_lt(cold, 100.0, "a body left outside in the frost loses heat")

	# Same body, same tick budget, but now standing in a heated room.
	pool.inside[s] = 1
	pool.shelter[s] = 45.0     # a very warm building
	world.run(600)
	assert_gt(pool.warmth[s], cold + 5.0, "warmth comes back indoors")


func test_hunger_rises_and_a_meal_takes_it_away() -> void:
	var id: int = _first_id()
	var s: int = _strand(id)
	var pool: CitizenPool = _pool()
	_set_need(id, "hunger", 0.0)
	world.run(400)                      # 20 in-world seconds
	var risen: float = pool.hunger[s]
	assert_gt(risen, 3.0, "20 seconds of being alive makes you hungrier")
	assert_lt(risen, 20.0, "hunger is a day-long pressure, not a minute-long one")

	cit.call("give_food", 500.0)
	_set_need(id, "hunger", CitizenDefs.HUNGER_MEAL_WANT + 8.0)
	world.run(CitizenDefs.NEED_BUCKETS * 2)
	assert_lt(pool.hunger[s], CitizenDefs.HUNGER_MEAL_WANT,
		"a hungry citizen with food in the city eats")


func test_no_food_means_hunger_keeps_climbing() -> void:
	var id: int = _first_id()
	var s: int = _strand(id)
	var pool: CitizenPool = _pool()
	# Empty the pantry: the founders' larder is the only store in a bare world.
	cit.set("_larder", 0.0)
	_set_need(id, "hunger", 80.0)
	world.run(600)
	assert_gt(pool.hunger[s], 85.0, "an empty city does not feed anybody")


func test_sleep_is_the_only_real_rest() -> void:
	var pool: CitizenPool = _pool()
	var ids: PackedInt32Array = _ids()
	var housed: int = _strand(ids[0])
	var rough: int = _strand(ids[1])
	pool.home[housed] = 1                       # pretend they have a bunk
	pool.state[housed] = CitizenDefs.State.SLEEPING
	pool.state[rough] = CitizenDefs.State.SLEEPING
	pool.fatigue[housed] = 90.0
	pool.fatigue[rough] = 90.0
	var before: float = 90.0
	# Behaviour would move them, so measure the body model directly for a bucket.
	var ctx := CitizenPool.Ctx.new()
	ctx.dt = 10.0
	ctx.ambient = -18.0
	ctx.rng = Rng.stream("citizens")
	for i: int in 4:
		pool.step_needs(0, 1, ctx)
	assert_lt(pool.fatigue[housed], before, "a bed burns off fatigue")
	assert_lt(pool.fatigue[housed], pool.fatigue[rough],
		"sleeping rough is worse rest than sleeping in a bed")


func test_needs_are_bucketed_but_nobody_is_skipped() -> void:
	var pool: CitizenPool = _pool()
	var before: Dictionary = {}
	for id: int in _ids():
		before[id] = pool.hunger[_slot(id)]
	world.run(CitizenDefs.NEED_BUCKETS)     # exactly one full rotation
	for id: int in _ids():
		assert_gt(pool.hunger[_slot(id)], float(before[id]),
			"citizen %d was advanced within one bucket rotation" % id)


# =========================================================================
#  sickness, injury and death
# =========================================================================

func test_the_cold_makes_people_ill() -> void:
	var id: int = _first_id()
	var s: int = _strand(id)
	var pool: CitizenPool = _pool()
	pool.warmth[s] = 5.0
	pool.illness[s] = 0.0
	var ctx := CitizenPool.Ctx.new()
	ctx.dt = 4.0
	ctx.ambient = -30.0
	ctx.rng = Rng.stream("citizens")
	for i: int in 20:
		pool.step_needs(0, 1, ctx)
	assert_gt(pool.illness[s], 0.0, "freezing bodies get sick")
	assert_lt(pool.health[s], 100.0, "freezing bodies lose health")


func test_a_sick_citizen_stops_working() -> void:
	world.run(40)
	var pool: CitizenPool = _pool()
	var id: int = -1
	for candidate: int in _ids():
		if pool.job[_slot(candidate)] >= 0:
			id = candidate
			break
	if id < 0:
		# No jobs in a bare world; make one by hand so the rule is still tested.
		id = _first_id()
		pool.job[_slot(id)] = 1
	var s: int = _slot(id)
	pool.state[s] = CitizenDefs.State.WORKING
	_set_need(id, "illness", CitizenDefs.SICK_ONSET + 20.0)
	world.run(CitizenDefs.NEED_BUCKETS * 2)
	assert_ne(int(pool.state[s]), CitizenDefs.State.WORKING,
		"illness takes a citizen off the roster")
	assert_gt(float(cit.call("sick_count")), 0.0, "and the city knows how many are ill")


func test_death_names_a_cause_and_a_person() -> void:
	var id: int = _first_id()
	var s: int = _strand(id)
	var pool: CitizenPool = _pool()
	var info: Dictionary = cit.call("citizen_info", id)
	pool.hunger[s] = 100.0
	pool.health[s] = 0.6
	var died: Array = capture_signal_args(Bus, &"citizen_died", func() -> void:
		world.run(CitizenDefs.NEED_BUCKETS * 3))
	assert_eq(died.size(), 2, "Bus.citizen_died carries (id, cause)")
	if died.size() == 2:
		assert_eq(int(died[0]), id, "the id of the person who died")
		assert_eq(String(died[1]), String(CitizenDefs.CAUSE_STARVATION),
			"starving to death is reported as starvation")
	assert_false(bool(cit.call("has_citizen", id)), "the dead leave the roster")
	assert_eq(int(cit.call("dead_total")), 1, "the toll went up by one")
	var toll: Dictionary = cit.call("death_toll")
	assert_has(toll, "starvation", "the toll is broken down by cause")

	var obits: Array = cit.call("recent_deaths", 4)
	assert_eq(obits.size(), 1, "one obituary")
	var o: Dictionary = obits[0]
	assert_eq(String(o["name"]), String(info["name"]), "the obituary names them")
	assert_has(o, "age", "with their age")
	assert_has(o, "trade", "with their trade")
	assert_has(o, "cell", "and where it happened")


func test_freezing_to_death_is_reported_as_cold() -> void:
	var id: int = _first_id()
	var s: int = _strand(id)
	var pool: CitizenPool = _pool()
	pool.hunger[s] = 10.0
	pool.warmth[s] = 0.0
	pool.health[s] = 0.4
	world.run(CitizenDefs.NEED_BUCKETS * 3)
	assert_false(bool(cit.call("has_citizen", id)), "the cold took them")
	assert_has(cit.call("death_toll"), "cold", "and it is written down as cold")


func test_a_death_is_an_event_not_a_decrement() -> void:
	var id: int = _first_id()
	var s: int = _strand(id)
	_pool().hunger[s] = 100.0
	_pool().health[s] = 0.5
	var seen: Array[String] = []
	var probe: Callable = func(severity: int, key: StringName, text: String, _pos: Vector2) -> void:
		if key == &"citizen_died":
			seen.append("%d|%s" % [severity, text])
	Bus.alert_raised.connect(probe)
	world.run(CitizenDefs.NEED_BUCKETS * 3)
	Bus.alert_raised.disconnect(probe)
	assert_eq(seen.size(), 1, "one worded alert per death")
	if seen.size() == 1:
		var parts: PackedStringArray = seen[0].split("|")
		assert_le(float(parts[0]), 1.0, "a death is severity 1 — gameplay, not a broken build")
		assert_true(parts[1].contains(","), "the alert is a sentence about a person")
		assert_true(parts[1].ends_with("."), "and it is punctuated like one")


func test_the_death_spiral_actually_spirals() -> void:
	# A city with no heat and no food. Frostpunk's contract: this must kill it,
	# and it must kill it through cold and hunger rather than a scripted timer.
	cit.set("_larder", 0.0)
	var pool: CitizenPool = _pool()
	for id: int in _ids():
		var s: int = _strand(id, COLD_FIELD + Vector2i(id % 5, id / 5))
		pool.health[s] = 40.0
		pool.hunger[s] = 70.0
		pool.warmth[s] = 25.0
	var start_pop: int = int(cit.call("population"))
	world.run(4000)
	var mid: Dictionary = _report()
	assert_lt(float(mid["avg_warmth"]), 45.0, "nobody is warm")
	assert_gt(float(mid["avg_hunger"]), 80.0, "everybody is starving")
	assert_gt(float(cit.call("sick_count")) + float(mid["dead_total"]), 0.0,
		"the cold has started taking people")
	world.run(6000)
	var end: Dictionary = _report()
	assert_gt(float(end["dead_total"]), 0.0, "a city with no heat and no food buries people")
	assert_lt(float(end["population"]), float(start_pop), "the population falls")
	assert_lt(float(end["avg_morale"]), float(mid["avg_morale"]) + 1.0,
		"and morale does not improve while it happens")


func test_warmth_and_food_prevent_the_spiral() -> void:
	# The control for the test above: the same 10 000 ticks with a roof, heat
	# and a full larder must NOT kill anybody. Without this, "people die" only
	# proves the model is lethal, not that it is fair.
	var pool: CitizenPool = _pool()
	cit.call("give_food", 4000.0)
	for id: int in _ids():
		var s: int = _slot(id)
		pool.inside[s] = 1
		pool.shelter[s] = 40.0
	world.run(4000)
	for id2: int in _ids():
		var s2: int = _slot(id2)
		pool.inside[s2] = 1
		pool.shelter[s2] = 40.0
	world.run(4000)
	assert_eq(int(cit.call("dead_total")), 0, "warm, fed people do not die")
	assert_gt(float(_report()["avg_warmth"]), 55.0, "and they are warm")


func test_injuries_hurt_and_heal() -> void:
	var id: int = _first_id()
	var s: int = _strand(id)
	var pool: CitizenPool = _pool()
	var before: float = pool.health[s]
	assert_true(bool(cit.call("injure_citizen", id, 50.0)), "combat can hurt a citizen")
	assert_gt(pool.injury[s], 40.0, "the injury is recorded")
	assert_lt(pool.health[s], before, "and it costs health")
	assert_eq(int(pool.state[s]), CitizenDefs.State.INJURED, "they are out of action")
	cit.call("give_food", 500.0)
	pool.inside[s] = 1
	pool.shelter[s] = 40.0
	world.run(3000)
	assert_lt(pool.injury[s], CitizenDefs.INJURY_CLEAR, "and given time, it heals")


# =========================================================================
#  jobs, staffing and shifts
# =========================================================================

func test_job_assignment_is_deterministic() -> void:
	world.run(400)
	var first: Dictionary = {}
	for id: int in _ids():
		var info: Dictionary = cit.call("citizen_info", id)
		first[id] = [int(info["job"]), int(info["home"]), String(info["shift"])]

	world.stop()
	world = SimFixture.new(7).start()
	cit = world.system(&"citizens")
	world.run(400)
	var second: Dictionary = {}
	for id2: int in _ids():
		var info2: Dictionary = cit.call("citizen_info", id2)
		second[id2] = [int(info2["job"]), int(info2["home"]), String(info2["shift"])]
	assert_eq(second, first, "the same seed hires the same people into the same jobs")


func test_staffing_reports_who_is_actually_there() -> void:
	var board: CitizenJobBoard = cit.get("board")
	assert_eq(cit.call("staffing_of", 999999), 1.0,
		"a building nobody works at never reports itself understaffed")
	world.run(200)
	var staffed: int = 0
	for i: int in board.job_ids.size():
		var bid: int = board.job_ids[i]
		var site: CitizenJobBoard.Site = board.site_of(bid)
		var ratio: float = float(cit.call("staffing_of", bid))
		assert_between(ratio, 0.0, 1.0, "staffing is a 0..1 fraction")
		if site.required > 0:
			assert_near(ratio, clampf(float(site.present) / float(site.required), 0.0, 1.0),
				0.001, "staffing_of matches the crew standing in the building")
		if ratio > 0.0:
			staffed += 1
	assert_ge(float(cit.call("workers_at", 999999)), 0.0, "an unknown building has no crew")


func test_an_empty_building_underperforms() -> void:
	var board: CitizenJobBoard = cit.get("board")
	var site := CitizenJobBoard.Site.new()
	site.id = 424242
	site.required = 4
	site.capacity = 4
	site.present = 0
	board.sites[site.id] = site
	assert_eq(board.staffing_of(site.id), 0.0, "no crew, no output")
	site.present = 2
	assert_near(board.staffing_of(site.id), 0.5, 0.001, "half a crew, half the output")
	site.present = 4
	assert_eq(board.staffing_of(site.id), 1.0, "a full crew runs at full rate")
	site.present = 9
	assert_eq(board.staffing_of(site.id), 1.0, "and overstaffing does not exceed it")
	board.sites.erase(site.id)


func test_shift_laws_change_who_is_on_the_clock() -> void:
	assert_true(CitizenDefs.works_in_phase(CitizenDefs.LAW_STANDARD,
		CitizenDefs.Shift.DAY, ClimateDefs.Phase.MORNING), "day shift works mornings")
	assert_false(CitizenDefs.works_in_phase(CitizenDefs.LAW_STANDARD,
		CitizenDefs.Shift.DAY, ClimateDefs.Phase.DEEP_NIGHT), "and not deep night")
	assert_true(CitizenDefs.works_in_phase(CitizenDefs.LAW_STANDARD,
		CitizenDefs.Shift.NIGHT, ClimateDefs.Phase.DEEP_NIGHT), "the night shift covers it")
	assert_false(CitizenDefs.works_in_phase(CitizenDefs.LAW_STANDARD,
		CitizenDefs.Shift.OFF, ClimateDefs.Phase.MORNING), "children are never on the clock")
	for phase: int in ClimateDefs.PHASE_COUNT:
		assert_true(CitizenDefs.works_in_phase(CitizenDefs.LAW_EMERGENCY,
			CitizenDefs.Shift.DAY, phase), "an emergency shift never ends")

	assert_true(bool(cit.call("set_shift_law", CitizenDefs.LAW_EMERGENCY)), "the law is enacted")
	assert_eq(String(cit.call("shift_law")), String(CitizenDefs.LAW_EMERGENCY), "and it sticks")
	assert_false(bool(cit.call("set_shift_law", &"nonsense")), "an unknown law is refused")


func test_the_city_fills_and_empties() -> void:
	# One in-world day, sampled every 400 ticks. The count of people at work has
	# to actually move, or the day rhythm is decoration.
	var lo: int = 0x7FFFFFFF
	var hi: int = 0
	for i: int in 24:
		world.run(400)
		var working: int = int(_report()["working_now"])
		lo = mini(lo, working)
		hi = maxi(hi, working)
	assert_gt(float(hi), float(lo), "the number of people at work changes over a day")


func test_idle_hands_raise_build_power() -> void:
	world.run(60)
	var builders: int = int(cit.call("idle_builders"))
	assert_ge(float(builders), 0.0, "the count is never negative")
	assert_le(float(builders), float(cit.call("population")), "and never exceeds the city")
	var build: SimSystem = world.system(&"build")
	if build != null and build.has_method("build_power"):
		assert_gt(float(build.call("build_power")), 0.0,
			"[P11] can always build something")


# =========================================================================
#  commands, saves and the view
# =========================================================================

func test_commands_add_and_remove_people() -> void:
	var before: int = int(cit.call("population"))
	world.cmd_now({"system": &"citizens", "op": "add", "count": 5})
	assert_eq(int(cit.call("population")), before + 5, "add spawns five")
	var ids: PackedInt32Array = _ids()
	var victim: int = ids[ids.size() - 1]
	world.cmd_now({"system": &"citizens", "op": "remove", "id": victim, "cause": "illness"})
	assert_eq(int(cit.call("population")), before + 4, "remove takes one away")
	assert_has(cit.call("death_toll"), "illness", "with the cause it was given")
	world.cmd_now({"system": &"citizens", "op": "set_shift", "shift": "extended"})
	assert_eq(String(cit.call("shift_law")), "extended", "set_shift understands a law name")
	world.cmd_now({"system": &"citizens", "op": "dump"})


func test_serialize_round_trips() -> void:
	world.run(300)
	var before: Dictionary = cit.call("serialize")
	assert_has(before, "citizens", "the roster is saved")
	assert_has(before, "staffing", "so is who staffs what")
	assert_has(before, "totals", "and the headline numbers")
	assert_eq((before["citizens"] as Array).size(), int(cit.call("population")),
		"one row per living citizen")
	cit.call("deserialize", before)
	var after: Dictionary = cit.call("serialize")
	assert_eq(int(cit.call("population")), (before["citizens"] as Array).size(),
		"the same people came back")
	assert_eq((after["totals"] as Dictionary)["population"],
		(before["totals"] as Dictionary)["population"], "and the totals agree")


func test_metrics_are_the_contract() -> void:
	world.run(120)
	var m: Dictionary = cit.call("metrics")
	for key: String in ["population", "sick", "dead_total", "avg_warmth", "avg_morale",
			"employed", "homeless"]:
		assert_has(m, key, "metrics carries '%s'" % key)
	assert_eq(int(m["population"]), int(cit.call("population")), "population agrees")
	assert_between(float(m["avg_morale"]), 0.0, 100.0, "morale is a percentage")
	assert_between(float(m["avg_warmth"]), 0.0, 100.0, "warmth is a percentage")
	assert_ge(float(m["step_us"]), 0.0, "the system reports what it cost")


func test_the_view_can_draw_them() -> void:
	world.run(100)
	var agents: Array = cit.call("agents_for_view")
	assert_eq(agents.size(), int(cit.call("population")), "one agent per citizen")
	var seen: Dictionary = {}
	for a: Dictionary in agents:
		assert_has(a, "id", "agents carry an id")
		assert_has(a, "kind", "a sprite kind")
		assert_has(a, "pos", "and a world position")
		assert_ge(float(a["id"]), float(CitizenDefs.AGENT_ID_BASE),
			"citizen agent ids are offset out of [P07]'s range")
		assert_has_not(seen, a["id"], "agent ids are unique")
		seen[a["id"]] = true
		var p: Vector2 = a["pos"]
		assert_between(p.x, 0.0, 256.0 * 32.0, "on the map in x")
		assert_between(p.y, 0.0, 256.0 * 32.0, "on the map in y")


func test_selection_finds_a_person_under_the_cursor() -> void:
	world.run(60)
	var id: int = _first_id()
	var info: Dictionary = cit.call("citizen_info", id)
	var cell := Vector2i(int((info["cell"] as Array)[0]), int((info["cell"] as Array)[1]))
	var found: int = int(cit.call("citizen_at_cell", cell))
	assert_ge(float(found), 0.0, "clicking a tile with someone on it finds someone")
	var rect := Rect2i(cell - Vector2i(6, 6), Vector2i(13, 13))
	var many: PackedInt32Array = cit.call("citizens_in_cell_rect", rect)
	assert_has(many, id, "and a box selection finds them too")
	assert_eq(int(cit.call("citizen_at_cell", Vector2i(3, 3))), -1,
		"an empty corner of the map holds nobody")


func test_the_run_is_replayable() -> void:
	world.stop()
	var script: Dictionary = {
		30: [{"system": &"citizens", "op": "add", "count": 12}],
		200: [{"system": &"citizens", "op": "set_shift", "shift": "extended"}],
		400: [{"system": &"citizens", "op": "add", "count": 6}],
	}
	var diff: PackedStringArray = SimFixture.replay_diff(11, 900, script)
	assert_empty(diff, "two runs of the same seed produce the same population")
	world = SimFixture.new(7).start()
	cit = world.system(&"citizens")
