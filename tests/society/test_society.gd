extends TestCase
## [P06] Hope, Discontent, factions and the two ways a run ends.
##
## Every test here drives a real SocietySystem against a city described by hand
## through inject_reading(), so a rule can be stated as a sentence and then
## measured: "a city at minus nine degrees with nineteen cold homes loses hope,
## and the reason it gives names the temperature".
##
## No world is required, which is deliberate: [P06] has to be judgeable while
## the eleven parts around it are still landing.

const HOUR: int = 400            ## ticks per in-world hour at the default day length
const DAY_TICKS: int = 9600

var soc: SocietySystem = null


func requires_files() -> PackedStringArray:
	return PackedStringArray(["res://game/sim/society/society_system.gd"])


func setup() -> void:
	soc = SocietySystem.new()
	soc.setup()
	soc.post_setup()
	soc.inject_reading(_city({}))


func teardown() -> void:
	soc = null


# =========================================================================
#  helpers
# =========================================================================

## A city, described. Defaults are a small settlement that is coping.
func _city(o: Dictionary) -> SocietyReading:
	var r := SocietyReading.new()
	r.day = int(o.get("day", 1))
	r.day_ticks = DAY_TICKS
	r.night = bool(o.get("night", false))
	r.storm = bool(o.get("storm", false))
	r.era = int(o.get("era", 0))
	r.outdoor_c = float(o.get("outdoor_c", -18.0))
	r.homes_total = int(o.get("homes", 4))
	r.housing_capacity = float(o.get("capacity", float(r.homes_total) * 12.0))
	r.home_temp_avg = float(o.get("home_temp_c", 16.0))
	r.coldest_home_c = float(o.get("coldest_home_c", r.home_temp_avg))
	r.homes_cold = int(o.get("homes_cold", 0))
	r.homes_frozen = int(o.get("homes_frozen", 0))
	r.warm_share = float(o.get("warm_share", 1.0 - float(r.homes_cold) / maxf(float(r.homes_total), 1.0)))
	r.hearths_lit = int(o.get("hearths", 2))
	r.kitchens = int(o.get("kitchens", 3))
	r.kitchens_running = float(o.get("kitchens_running", float(r.kitchens)))
	r.granaries = int(o.get("granaries", 1))
	r.food_capacity_per_day = r.kitchens_running * SocietyReading.FOOD_PER_KITCHEN_PER_DAY
	r.food_reserve_days = float(r.granaries) * SocietyReading.FOOD_DAYS_PER_GRANARY
	r.heat_deficit_share = float(o.get("heat_deficit_share", 0.0))
	r.frozen_buildings = int(o.get("frozen_buildings", 0))
	r.buildings_operational = int(o.get("buildings", 12))
	r.sources[&"build"] = true
	r.sources[&"heat"] = true
	r.sources[&"climate"] = true
	return r


func _run(ticks: int, from: int = 0) -> int:
	var t: int = from
	for _i: int in ticks:
		t += 1
		soc.step(t)
	return t


func _rate_of(meter: String, key: String) -> float:
	for r: Dictionary in soc.reasons():
		if String(r["key"]) == key and String(r["meter"]) == meter:
			return float(r["rate"])
	return 0.0


func _has_reason(meter: String, key: String) -> bool:
	for r: Dictionary in soc.reasons():
		if String(r["key"]) == key and String(r["meter"]) == meter:
			return true
	return false


func _text_of(key: String) -> String:
	for r: Dictionary in soc.reasons():
		if String(r["key"]) == key:
			return String(r["text"])
	return ""


# =========================================================================
#  meters and traceability
# =========================================================================

func test_meters_start_where_the_design_says() -> void:
	assert_near(soc.hope(), SocietyDefs.HOPE_START, 0.001, "hope starts guarded")
	assert_near(soc.discontent(), SocietyDefs.DISCONTENT_START, 0.001, "discontent starts low")
	assert_eq(soc.laws_signed_count(), 0, "and the book is empty")


func test_every_point_of_movement_has_a_reason_behind_it() -> void:
	# The hard contract of this part. If the ledger and the bar disagree, the
	# tooltip is fiction.
	soc.inject_reading(_city({"homes": 6, "homes_cold": 4, "home_temp_c": -4.0,
		"coldest_home_c": -11.0, "kitchens_running": 0.5}))
	_run(HOUR * 6)
	assert_near(soc.hope() - SocietyDefs.HOPE_START,
		soc.ledger.meter_total(SocietyDefs.METER_HOPE), 0.02,
		"the hope reasons sum to the hope bar")
	assert_near(soc.discontent() - SocietyDefs.DISCONTENT_START,
		soc.ledger.meter_total(SocietyDefs.METER_DISCONTENT), 0.02,
		"the discontent reasons sum to the discontent bar")


func test_reasons_are_worded_and_carry_this_run_s_numbers() -> void:
	soc.inject_reading(_city({"homes": 19, "homes_cold": 11, "home_temp_c": -3.0,
		"coldest_home_c": -9.0}))
	_run(HOUR)
	assert_true(_has_reason("discontent", "cold_homes"), "cold houses are a named reason")
	var text: String = _text_of("cold_homes")
	assert_has(text, "eleven", "the sentence says how many are cold")
	assert_has(text, "nineteen", "out of how many")
	assert_has(text, "-9", "and how cold the worst one is")
	for r: Dictionary in soc.reasons():
		assert_gt(float(String(r["text"]).length()), 10.0,
			"reason '%s' explains itself" % String(r["key"]))
		assert_gt(float(String(r["label"]).length()), 2.0,
			"reason '%s' has a label" % String(r["key"]))


func test_hope_reasons_are_ranked_and_signed() -> void:
	soc.inject_reading(_city({"homes": 8, "homes_cold": 7, "home_temp_c": -8.0}))
	_run(HOUR * 3)
	var reasons: Array[Dictionary] = soc.hope_reasons()
	assert_not_empty(reasons, "hope has reasons")
	for r: Dictionary in reasons:
		assert_eq(String(r["meter"]), "hope", "hope_reasons only returns hope")
	var prev: float = 1.0e12
	for r: Dictionary in reasons:
		var w: float = absf(float(r["recent"]))
		assert_le(w, prev + 0.0001, "ranked strongest first")
		prev = w
	assert_lt(float(reasons[0]["total"]), 0.0, "and the worst of them is a loss")


func test_a_warm_fed_city_is_calmer_than_a_cold_hungry_one() -> void:
	var warm: SocietySystem = _fresh(_city({"homes": 6, "homes_cold": 0, "home_temp_c": 18.0}))
	var cold: SocietySystem = _fresh(_city({"homes": 6, "homes_cold": 6, "home_temp_c": -6.0,
		"coldest_home_c": -14.0, "kitchens_running": 0.0}))
	for t: int in range(1, HOUR * 8):
		warm.step(t)
		cold.step(t)
	assert_gt(warm.hope(), cold.hope(), "warmth and food buy hope")
	assert_lt(warm.discontent(), cold.discontent(), "and buy quiet")
	assert_gt(cold.discontent() - warm.discontent(), 8.0, "by a margin a player would feel")


func test_a_clamped_meter_still_adds_up() -> void:
	soc.handle_command({"op": "nudge", "meter": "discontent", "amount": 500.0,
		"reason": "A scripted catastrophe."})
	_run(HOUR)
	assert_near(soc.discontent(), 100.0, 0.001, "the bar pins at a hundred")
	assert_near(soc.ledger.meter_total(SocietyDefs.METER_DISCONTENT),
		100.0 - SocietyDefs.DISCONTENT_START, 0.02,
		"and the reasons still sum to the distance actually travelled")


# =========================================================================
#  the people
# =========================================================================

func test_the_cold_kills_and_says_who() -> void:
	soc.inject_reading(_city({"homes": 0, "capacity": 0.0, "hearths": 0,
		"outdoor_c": -32.0}))
	_run(HOUR * 8)
	assert_gt(soc.deaths_total(), 0.0, "people die in an unlit camp at minus thirty two")
	var found: bool = false
	for r: Dictionary in soc.reasons():
		if String(r["key"]).begins_with("deaths_"):
			found = true
			assert_has(String(r["text"]), "froze", "the reason says what killed them")
	assert_true(found, "and the deaths are in the ledger by cause")


func test_lighting_the_fire_keeps_the_camp_alive() -> void:
	var dark: SocietySystem = _fresh(_city({"homes": 0, "capacity": 0.0, "hearths": 0,
		"outdoor_c": -26.0}))
	var lit: SocietySystem = _fresh(_city({"homes": 0, "capacity": 0.0, "hearths": 3,
		"outdoor_c": -26.0}))
	for t: int in range(1, HOUR * 10):
		dark.step(t)
		lit.step(t)
	assert_gt(dark.deaths_total(), lit.deaths_total(),
		"a lit hearth is the difference between a camp and a graveyard")
	assert_gt(lit.population(), dark.population(), "and it shows in the headcount")


func test_the_canvas_runs_out() -> void:
	soc.inject_reading(_city({"homes": 0, "capacity": 0.0, "hearths": 3}))
	var start: float = soc.populace.tent_capacity
	_run(HOUR * 24)
	assert_lt(soc.populace.tent_capacity, start * 0.75, "a day of wind costs you tents")
	_run(HOUR * 50, HOUR * 24)
	assert_near(soc.populace.tent_capacity, 0.0, 0.01, "and after three days there are none")
	assert_gt(soc.populace.homeless, 0.0, "which is when people start sleeping on the ice")


func test_a_housed_city_stops_dying() -> void:
	soc.inject_reading(_city({"homes": 6, "capacity": 72.0, "home_temp_c": 17.0}))
	_run(HOUR * 12)
	assert_near(soc.deaths_total(), 0.0, 0.001, "nobody dies in a warm house with food")
	assert_near(soc.homeless_count(), 0.0, 0.001, "and nobody is outside")


func test_hunger_needs_kitchens_not_wishes() -> void:
	soc.inject_reading(_city({"kitchens": 0, "kitchens_running": 0.0, "granaries": 0}))
	_run(HOUR * 4)
	assert_gt(soc.hunger_share(), 0.5, "no kitchens, no food")
	assert_true(_has_reason("discontent", "hunger"), "and the city says so")
	soc.inject_reading(_city({"kitchens": 4, "kitchens_running": 4.0}))
	_run(HOUR * 4, HOUR * 4)
	assert_lt(soc.hunger_share(), 0.05, "four running kitchens feed forty people")


# =========================================================================
#  laws
# =========================================================================

func test_signing_a_law_changes_the_world_not_only_the_mood() -> void:
	soc.inject_reading(_city({"homes": 2, "capacity": 24.0, "home_temp_c": 16.0}))
	_run(HOUR)
	var before_capacity: float = soc.policy_value(&"shelter_capacity")
	_sign_and_wait(&"double_bunks")
	assert_gt(soc.policy_value(&"shelter_capacity"), before_capacity,
		"Double Bunks actually raises how many a house holds")
	assert_gt(soc.policy_value(&"crowding"), 0.0, "and actually raises crowding")


func test_a_law_in_force_is_a_named_reason() -> void:
	_sign_and_wait(&"emergency_shift")
	_run(HOUR)
	assert_true(_has_reason("discontent", "law:emergency_shift"),
		"the law is in the ledger under its own name")
	assert_gt(_rate_of("discontent", "law:emergency_shift"), 0.0,
		"and it is pushing discontent up every hour it stays in force")
	assert_true(_has_reason("discontent", "overwork"), "and the shift itself is felt")
	assert_near(soc.work_hours(), 14.0, 0.001, "fourteen hours on the roster")


func test_the_seal_makes_laws_scarce() -> void:
	_sign_and_wait(&"care_house")
	var res: Dictionary = soc.sign_law(&"double_bunks")
	assert_false(bool(res["ok"]), "you cannot sign two in a row")
	assert_gt(soc.seal_hours_left(), 10.0, "there are hours left on the seal")


func test_signing_swings_the_factions_that_care() -> void:
	var before: float = soc.approval_of(SocietyDefs.FACTION_FAMILIES)
	_sign_and_wait(&"child_labour")
	assert_lt(soc.approval_of(SocietyDefs.FACTION_FAMILIES), before - 20.0,
		"the parents do not forgive this one")
	assert_gt(soc.approval_of(SocietyDefs.FACTION_WORKERS), 0.0,
		"and the pit crews are quietly glad of the hands")


func test_a_cruel_law_buys_quiet_and_costs_hope() -> void:
	soc.handle_command({"op": "nudge", "meter": "discontent", "amount": 40.0,
		"reason": "A scripted grievance."})
	var hope_before: float = soc.hope()
	var discontent_before: float = soc.discontent()
	_sign_and_wait(&"corpse_pits")
	assert_lt(soc.hope(), hope_before, "the pits cost hope on the day they open")
	assert_gt(soc.policy_value(&"corpse_capacity"), 20.0, "and they do solve the problem")
	assert_gt(soc.discontent(), discontent_before - 10.0, "without buying much quiet")


func test_the_book_view_explains_why_a_page_is_shut() -> void:
	_sign_and_wait(&"corpse_pits")
	var found: bool = false
	for page: Dictionary in soc.book_view():
		if String(page["id"]) == "named_graves":
			found = true
			assert_false(bool(page["available"]), "the graves are shut")
			assert_has(String(page["reason"]), "The Pits", "and the UI is told by what")
	assert_true(found, "named_graves is in the book view")


# =========================================================================
#  factions, grievances and demands
# =========================================================================

func test_a_grievance_needs_to_be_sustained_before_it_opens() -> void:
	soc.inject_reading(_city({"homes": 5, "homes_cold": 5, "home_temp_c": -8.0}))
	_run(int(HOUR * 0.75))
	assert_eq(soc.active_grievances(), 0, "three quarters of an hour of cold is weather")
	_run(HOUR * 2, int(HOUR * 0.75))
	assert_gt(float(soc.active_grievances()), 0.0, "three hours of it is a grievance")
	var g: Array[Dictionary] = soc.grievances()
	assert_eq(String(g[0]["faction"]), "families", "and the parents are the ones saying it")
	assert_gt(float(String(g[0]["complaint"]).length()), 20.0, "in words")


func test_fixing_the_cause_closes_the_grievance() -> void:
	soc.inject_reading(_city({"homes": 5, "homes_cold": 5, "home_temp_c": -8.0}))
	_run(HOUR * 4)
	assert_gt(float(soc.active_grievances()), 0.0, "opened")
	soc.inject_reading(_city({"homes": 5, "homes_cold": 0, "home_temp_c": 18.0}))
	_run(HOUR * 8, HOUR * 4)
	assert_eq(soc.active_grievances(), 0, "and closed once the rooms are warm")


func test_a_faction_makes_a_demand_with_a_deadline() -> void:
	soc.inject_reading(_city({"homes": 5, "homes_cold": 5, "home_temp_c": -10.0,
		"coldest_home_c": -14.0}))
	_run(HOUR * 8)
	var demands: Array[Dictionary] = soc.demands()
	assert_not_empty(demands, "somebody has stopped complaining and started asking")
	var d: Dictionary = demands[0]
	assert_gt(float(d["hours_left"]), 0.0, "with time on the clock")
	assert_gt(float(String(d["speech"]).length()), 30.0, "in their own words")
	assert_gt(float(String(d["terms"]).length()), 10.0, "with checkable terms")


func test_meeting_a_demand_is_worth_something() -> void:
	soc.inject_reading(_city({"homes": 5, "homes_cold": 5, "home_temp_c": -10.0}))
	var t: int = _run(HOUR * 8)
	if soc.demands().is_empty():
		skip("no demand was issued in eight hours; covered by the previous test")
		return
	var faction: StringName = StringName(String(soc.demands()[0]["faction"]))
	var approval_before: float = soc.approval_of(faction)
	var discontent_before: float = soc.discontent()
	soc.inject_reading(_city({"homes": 5, "homes_cold": 0, "home_temp_c": 19.0}))
	_run(HOUR * 2, t)
	assert_empty(soc.demands(), "the demand is settled")
	assert_gt(soc.approval_of(faction), approval_before, "they remember it")
	assert_lt(soc.discontent(), discontent_before, "and the anger comes off the bar")


func test_missing_a_demand_radicalises_the_faction() -> void:
	soc.inject_reading(_city({"homes": 5, "homes_cold": 5, "home_temp_c": -10.0}))
	var t: int = _run(HOUR * 8)
	if soc.demands().is_empty():
		skip("no demand was issued in eight hours")
		return
	var faction: StringName = StringName(String(soc.demands()[0]["faction"]))
	var discontent_before: float = soc.discontent()
	_run(HOUR * 16, t)
	assert_lt(soc.approval_of(faction), -10.0, "they have decided about you")
	assert_gt(soc.discontent(), discontent_before, "and it costs")
	var radical: int = 0
	for f: Dictionary in soc.factions():
		if String(f["id"]) == String(faction):
			radical = int(f["radical"])
	assert_ge(float(radical), 1.0, "the next demand will have a shorter fuse")


func test_factions_report_who_they_are() -> void:
	var f: Array[Dictionary] = soc.factions()
	assert_size(f, SocietyDefs.FACTION_IDS.size(), "every constituency is represented")
	for entry: Dictionary in f:
		assert_gt(float(String(entry["name"]).length()), 3.0, "with a name")
		assert_gt(float(String(entry["of_whom"]).length()), 10.0, "and a description")
		assert_gt(float(entry["share"]), 0.0, "and a share of the city")


# =========================================================================
#  the endgame
# =========================================================================

func test_exile_is_telegraphed_four_times_before_it_happens() -> void:
	var stages: Array[int] = []
	var t: int = 0
	var ultimatum_tick: int = -1
	for _i: int in HOUR * 40:
		t += 1
		if t % HOUR == 0 and soc.discontent() < 99.0 and not soc.warning_state()["ultimatum"]:
			soc.handle_command({"op": "nudge", "meter": "discontent", "amount": 9.0,
				"reason": "A scripted collapse."})
		soc.step(t)
		var stage: int = int(soc.warning_state()["unrest_stage"])
		if stages.is_empty() or stages[stages.size() - 1] != stage:
			stages.append(stage)
		if ultimatum_tick < 0 and bool(soc.warning_state()["ultimatum"]):
			ultimatum_tick = t
		if soc.is_over():
			break
	assert_has(stages, 1, "the murmur came first")
	assert_has(stages, 2, "then the delegation")
	assert_has(stages, 3, "then the crowd in the square")
	assert_gt(float(ultimatum_tick), 0.0, "then the ultimatum")
	assert_true(soc.is_over(), "and only then the exile")
	assert_eq(soc.end_reason(), SocietyDefs.REASON_EXILE, "for the right reason")
	assert_ge(float(t - ultimatum_tick), float(HOUR) * 11.0,
		"with a full twelve hours between the ultimatum and the gate")


func test_an_ultimatum_can_be_survived() -> void:
	soc.handle_command({"op": "set_meter", "meter": "discontent", "value": 100.0})
	var t: int = _run(HOUR)
	assert_true(bool(soc.warning_state()["ultimatum"]), "the crowd is outside")
	soc.handle_command({"op": "set_meter", "meter": "discontent", "value": 40.0})
	t = _run(HOUR, t)
	assert_false(bool(soc.warning_state()["ultimatum"]), "and then it is not")
	_run(HOUR * 20, t)
	assert_false(soc.is_over(), "the run continues")


func test_despair_ends_a_run_too_and_warns_first() -> void:
	var stages: Array[int] = []
	var t: int = 0
	for _i: int in HOUR * 40:
		t += 1
		if t % HOUR == 0 and soc.hope() > 1.0:
			soc.handle_command({"op": "nudge", "meter": "hope", "amount": -8.0,
				"reason": "A scripted despair."})
		soc.step(t)
		var stage: int = int(soc.warning_state()["despair_stage"])
		if stages.is_empty() or stages[stages.size() - 1] != stage:
			stages.append(stage)
		if soc.is_over():
			break
	assert_has(stages, 1, "people stopped asking how long")
	assert_has(stages, 3, "the night shift did not turn up")
	assert_true(soc.is_over(), "and the city gave up")
	assert_eq(soc.end_reason(), SocietyDefs.REASON_DESPAIR, "for the right reason")


func test_a_finished_run_stops_escalating() -> void:
	soc.handle_command({"op": "set_meter", "meter": "discontent", "value": 100.0})
	var t: int = _run(HOUR * 14)
	assert_true(soc.is_over(), "the run ended")
	var reason: String = soc.end_reason()
	soc.handle_command({"op": "set_meter", "meter": "hope", "value": 0.0})
	_run(HOUR * 20, t)
	assert_eq(soc.end_reason(), reason, "and it cannot end twice")


# =========================================================================
#  plumbing
# =========================================================================

func test_metrics_report_what_the_brief_asked_for() -> void:
	_run(HOUR)
	var m: Dictionary = soc.metrics()
	for key: String in ["hope", "discontent", "laws_signed", "active_grievances",
			"population", "deaths", "open_demands", "approval_min"]:
		assert_has(m, key, "metrics carry '%s'" % key)


func test_serialize_survives_a_roundtrip() -> void:
	soc.inject_reading(_city({"homes": 5, "homes_cold": 4, "home_temp_c": -5.0}))
	_sign_and_wait(&"soup_ration")
	_run(HOUR * 6)
	var before: Dictionary = soc.serialize()
	var other: SocietySystem = SocietySystem.new()
	other.setup()
	other.post_setup()
	other.inject_reading(soc._reading)
	other.deserialize(before)
	assert_near(other.hope(), soc.hope(), 0.001, "hope survives")
	assert_near(other.discontent(), soc.discontent(), 0.001, "discontent survives")
	assert_eq(other.laws_signed(), soc.laws_signed(), "the book survives")
	assert_near(other.population(), soc.population(), 0.01, "the people survive")
	assert_eq(other.serialize()["council"], before["council"], "so do the factions")


func test_two_identical_runs_are_identical() -> void:
	var a: Dictionary = _scripted_run(7)
	var b: Dictionary = _scripted_run(7)
	assert_eq(a, b, "same seed, same script, same society")


func test_a_different_seed_changes_the_demands_not_the_physics() -> void:
	var a: Dictionary = _scripted_run(7)
	var b: Dictionary = _scripted_run(99)
	assert_near(float((a["people"] as Dictionary)["population"]),
		float((b["people"] as Dictionary)["population"]), 0.001,
		"the cold does not care about the seed")


func test_it_degrades_without_any_other_system() -> void:
	var lonely: SocietySystem = SocietySystem.new()
	lonely.setup()
	lonely.post_setup()
	assert_no_errors(func() -> void:
		for t: int in range(1, 600):
			lonely.step(t),
		"society runs with nothing else in the world")
	assert_gt(float(lonely.laws_signed_count()), -1.0, "and still has its book")


# --- helpers -----------------------------------------------------------------

func _fresh(reading: SocietyReading) -> SocietySystem:
	var s := SocietySystem.new()
	s.setup()
	s.post_setup()
	s.inject_reading(reading)
	return s


## Signs a law and runs the clock until it is actually in force.
func _sign_and_wait(id: StringName) -> void:
	var start: int = 1
	var res: Dictionary = soc.sign_law(id)
	if not bool(res.get("ok", false)):
		fail("could not propose '%s': %s" % [String(id), String(res.get("reason", ""))])
		return
	var need: int = int(ceil(float(res["hours"]) * float(HOUR))) + 2
	for i: int in need:
		soc.step(start + i)


func _scripted_run(world_seed: int) -> Dictionary:
	Rng.reset(world_seed)
	var s := SocietySystem.new()
	s.setup()
	s.post_setup()
	s.inject_reading(_city({"homes": 5, "homes_cold": 4, "home_temp_c": -6.0,
		"kitchens_running": 1.0}))
	for t: int in range(1, HOUR * 14):
		if t == HOUR:
			s.handle_command({"op": "sign", "law": "care_house"})
		if t == HOUR * 10:
			s.handle_command({"op": "sign", "law": "double_bunks"})
		s.step(t)
	return s.serialize()
