extends TestCase
## [P08] Threat Director — the budget curve, the campaign's dramaturgy, and the
## synchronisation with [P09]'s Great Frost calendar.
##
## These tests are written against BEHAVIOUR a player can feel: night one is
## small, night three is the first real one, night four is quieter than night
## three, the biggest nights land on the coldest nights, and the same seed
## always produces the same campaign.

const HORIZON: int = 40

var world: SimFixture = null
var threat: SimSystem = null


func requires_systems() -> PackedStringArray:
	return PackedStringArray(["threat"])


func setup() -> void:
	world = SimFixture.new(7).start()
	threat = world.system(&"threat")


func teardown() -> void:
	if world != null:
		world.stop()


# --- helpers -----------------------------------------------------------------

func _profile() -> ThreatProfile:
	return threat.call("profile") as ThreatProfile


## The budget the director WOULD compose for a night, holding everything except
## the curve itself steady. Pure function, so a curve regression is a diff.
func _budget_for(night: int, signature: float = 0.0, pressure: float = 1.0) -> float:
	var schedule: WaveSchedule = _schedule()
	var b: Dictionary = WaveBudget.compute(_profile(), schedule, night, 0, signature, pressure)
	return float(b["total"])


func _schedule() -> WaveSchedule:
	var s := WaveSchedule.new()
	s.build(_profile(), _storms())
	return s


## The Great Frost calendar, read from [P09] exactly the way the director does.
func _storms() -> Dictionary[int, Dictionary]:
	var out: Dictionary[int, Dictionary] = {}
	var climate: SimSystem = world.system(&"climate")
	if climate == null or not climate.has_method("profile"):
		return out
	var prof: Object = climate.call("profile")
	if prof == null or not prof.has_method("frost_for_day"):
		return out
	for d: int in range(1, HORIZON + 1):
		var f: Variant = prof.call("frost_for_day", d)
		if typeof(f) == TYPE_DICTIONARY and not (f as Dictionary).is_empty():
			out[d] = {
				"title": String((f as Dictionary).get("title", "")),
				"intensity": float((f as Dictionary).get("intensity", 1.0)),
			}
	return out


# --- the curve ----------------------------------------------------------------

func test_curve_is_monotone_in_the_long_run() -> void:
	# Night to night the curve dips (that is the point of a lull), but every
	# five-night window must be strictly heavier than the one before it or the
	# campaign is not escalating.
	var window: Array[float] = []
	for n: int in range(1, 26):
		window.append(_budget_for(n))
	for i: int in range(5, 21, 5):
		var before: float = 0.0
		var after: float = 0.0
		for k: int in 5:
			before += window[i - 5 + k]
			after += window[i + k] if i + k < window.size() else window[window.size() - 1]
		assert_gt(after, before, "window at night %d must outweigh the one before" % i)


func test_night_one_is_a_teaching_night() -> void:
	var b1: float = _budget_for(1)
	assert_le(b1, 12.0, "night 1 must be a handful, not a fight")
	assert_eq(ThreatDefs.band_key(b1), &"handful", "night 1 reads as a handful")
	assert_gt(_budget_for(3), b1 * 3.0, "night 3 must be unmistakably bigger than night 1")


func test_the_false_lull_is_real() -> void:
	var schedule: WaveSchedule = _schedule()
	var found: int = 0
	for n: int in range(2, HORIZON):
		if not schedule.is_set_piece(n - 1) or schedule.is_set_piece(n):
			continue
		found += 1
		assert_lt(_budget_for(n), _budget_for(n - 1) * 0.8,
			"night %d follows a set piece and must be a real drop" % n)
		assert_lt(schedule.lull_factor(n), 1.0, "night %d must carry a lull factor" % n)
	assert_gt(float(found), 2.0, "the campaign must contain several false lulls")


func test_set_pieces_tower_over_their_neighbours() -> void:
	var schedule: WaveSchedule = _schedule()
	for n: int in schedule.set_piece_nights():
		if n < 2 or n >= HORIZON:
			continue
		assert_gt(_budget_for(n), _budget_for(n - 1) * 1.3,
			"set piece on night %d must dwarf the night before" % n)


func test_budget_is_a_pure_function_of_its_inputs() -> void:
	var produce: Callable = func() -> Array:
		var out: Array = []
		for n: int in range(1, HORIZON):
			out.append(snappedf(_budget_for(n, 42.0, 1.1), 0.0001))
		return out
	assert_deterministic(produce, "the same night, twice, must cost the same")


func test_curve_is_bounded() -> void:
	var p: ThreatProfile = _profile()
	for n: int in [50, 80, 120, 200]:
		assert_le(p.base_budget(n), p.budget_ceiling,
			"night %d must respect the authored ceiling" % n)


# --- storm synchronisation ----------------------------------------------------

func test_every_great_frost_is_a_set_piece() -> void:
	var storms: Dictionary[int, Dictionary] = _storms()
	if storms.is_empty():
		skip("no [P09] climate in this build, so there is no storm calendar to sync to")
		return
	var schedule: WaveSchedule = _schedule()
	var days: Array = storms.keys()
	days.sort()
	for d: int in days:
		if d > HORIZON:
			continue
		assert_true(schedule.is_set_piece(d),
			"a Great Frost on day %d must be a set-piece night" % d)
		assert_true(schedule.is_storm_synced(d),
			"night %d must be marked as synchronised with the storm" % d)


func test_the_worst_night_lands_on_the_coldest_night() -> void:
	var storms: Dictionary[int, Dictionary] = _storms()
	if storms.is_empty():
		skip("no [P09] climate in this build")
		return
	var schedule: WaveSchedule = _schedule()
	var worst: int = 1
	for n: int in range(1, HORIZON):
		if _budget_for(n) > _budget_for(worst):
			worst = n
	assert_true(storms.has(worst),
		"the heaviest night inside the horizon (night %d) must be a Great Frost night" % worst)
	assert_true(schedule.is_storm_synced(worst), "and it must know that it is")


func test_a_storm_night_borrows_the_storm_s_name() -> void:
	var storms: Dictionary[int, Dictionary] = _storms()
	if storms.is_empty():
		skip("no [P09] climate in this build")
		return
	var schedule: WaveSchedule = _schedule()
	var days: Array = storms.keys()
	days.sort()
	var first: int = int(days[0])
	assert_eq(schedule.title_for(first), String(storms[first]["title"]),
		"the set piece is named after the storm the player already dreads")


func test_storm_intensity_scales_the_set_piece() -> void:
	var storms: Dictionary[int, Dictionary] = _storms()
	if storms.size() < 2:
		skip("need at least two scheduled storms to compare")
		return
	var days: Array = storms.keys()
	days.sort()
	var soft: int = int(days[0])
	var hard: int = int(days[days.size() - 1])
	var p: ThreatProfile = _profile()
	var schedule: WaveSchedule = _schedule()
	var soft_mult: float = float(WaveBudget.compute(p, schedule, soft, 0, 0.0, 1.0)["drama"])
	var hard_mult: float = float(WaveBudget.compute(p, schedule, hard, 0, 0.0, 1.0)["drama"])
	assert_gt(hard_mult, soft_mult, "a harder storm must carry a heavier night")
	assert_le(hard_mult, p.set_piece_multiplier + p.set_piece_storm_bonus + 0.001,
		"and never more than the profile allows")


func test_set_pieces_never_land_back_to_back() -> void:
	var schedule: WaveSchedule = _schedule()
	var nights: Array[int] = schedule.set_piece_nights()
	for i: int in range(1, nights.size()):
		assert_gt(float(nights[i] - nights[i - 1]), 1.0,
			"two set pieces on consecutive nights leaves no room for a lull")


# --- the heat hunger ----------------------------------------------------------

func test_a_warmer_city_summons_more_of_them() -> void:
	var cold: float = _budget_for(6, 0.0)
	var warm: float = _budget_for(6, 60.0)
	var blazing: float = _budget_for(6, 400.0)
	assert_gt(warm, cold, "heat is what draws them; more heat must mean more of them")
	assert_gt(blazing, warm, "and it must keep meaning that")


func test_the_heat_draw_saturates() -> void:
	var p: ThreatProfile = _profile()
	assert_near(WaveBudget.heat_factor(p, 0.0), 1.0, 0.0001, "a dark city draws nobody extra")
	assert_le(WaveBudget.heat_factor(p, 1.0e9), p.heat_draw_max,
		"success must never be suicide: the draw is capped")
	assert_near(WaveBudget.heat_factor(p, p.heat_reference),
		1.0 + (p.heat_draw_max - 1.0) * 0.5, 0.001,
		"at the reference output the draw is exactly halfway to the ceiling")


func test_the_reasons_name_every_multiplier() -> void:
	var schedule: WaveSchedule = _schedule()
	var b: Dictionary = WaveBudget.compute(_profile(), schedule, 12, 2, 90.0, 1.2)
	var text: String = " ".join(PackedStringArray(b["reasons"]))
	assert_gt(float((b["reasons"] as Array).size()), 3.0,
		"a night that had four things done to it owes the player four sentences")
	assert_has(text, "curve", "the base curve must be named")
	assert_has(text, "heat", "the heat draw must be named")
	assert_has(text, "band", "the adaptation band must be quoted verbatim")
