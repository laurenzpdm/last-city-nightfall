extends TestCase
## [P17] HUD — everything the interface says, tested without a pixel.
##
## The HUD's job is to turn simulation state into sentences a human can act on.
## That transformation is pure and therefore testable: given these numbers, does
## it say the right thing, in the right order, with the right rounding, and does
## it shut up when nothing is wrong? Those are the assertions here.
##
## The panels themselves (layout, hot regions, tooltips, camera focus, scaling)
## need a real tree and are covered by tests/hud/run_hud_view.tscn.

const Format := preload("res://game/ui/hud/hud_format.gd")
const Trend := preload("res://game/ui/hud/hud_trend.gd")
const Alerts := preload("res://game/ui/hud/hud_alerts.gd")
const Probe := preload("res://game/ui/hud/hud_probe.gd")
const Style := preload("res://game/ui/hud/hud_style.gd")

var world: SimFixture = null
var _models: Array[LcnHudAlerts] = []


func suite_name() -> String:
	return "hud_logic"


func before_all() -> void:
	world = SimFixture.new(7)


func teardown() -> void:
	# Every alert model subscribes to the Bus, and an autoload signal holds the
	# callable that holds the model. Without this they pile up for the process.
	for m: LcnHudAlerts in _models:
		m.dispose()
	_models.clear()


func after_all() -> void:
	if world != null:
		world.stop()


## An alert model that will be unsubscribed when the test ends.
func _alerts() -> LcnHudAlerts:
	var a: LcnHudAlerts = Alerts.new()
	_models.append(a)
	return a


# ======================================================================  words =

func test_clock_format_is_one_format_everywhere() -> void:
	assert_eq(Format.clock(0.0), "0:00", "zero reads as a clock, not as a dash")
	assert_eq(Format.clock(7.4), "0:07")
	assert_eq(Format.clock(252.6), "4:13")
	assert_eq(Format.clock(-5.0), "0:00", "a negative countdown is zero, never -1:-5")
	assert_eq(Format.clock(3600.0), "60:00")


func test_rates_round_to_the_decision() -> void:
	assert_eq(Format.rate(14.237), "14", "nobody acts on the third decimal")
	assert_eq(Format.rate(9.44), "9.4", "under ten the decimal still matters")
	assert_eq(Format.rate(0.02), "0")
	assert_eq(Format.rate(1420.0), "1.4k")
	assert_eq(Format.signed_rate(-3.4), "-3.4")
	assert_eq(Format.signed_rate(12.0), "+12")
	assert_eq(Format.signed_rate(0.01), "0", "a rate this small is not movement")


func test_counts_and_stocks_stay_readable() -> void:
	assert_eq(Format.count(1420), "1,420")
	assert_eq(Format.count(-1420), "-1,420")
	assert_eq(Format.count(7), "7")
	assert_eq(Format.stock(940), "940")
	assert_eq(Format.stock(1400), "1.4k")
	assert_eq(Format.stock(21000), "21.0k")
	assert_eq(Format.stock(1200000), "1.2M")


func test_temperature_carries_its_unit() -> void:
	assert_eq(Format.temperature(-28.4), "-28°C")
	assert_eq(Format.temperature(0.2), "0°C")


func test_compass_says_a_direction_a_player_can_look_at() -> void:
	assert_eq(Format.compass(Vector2(1, 0)), "east")
	assert_eq(Format.compass(Vector2(0, -1)), "north")
	assert_eq(Format.compass(Vector2(1, -1).normalized()), "north-east")
	assert_eq(Format.compass(Vector2.ZERO), "all sides")
	assert_eq(Format.compass_short(Vector2(-1, 1).normalized()), "SW")


func test_ids_never_reach_the_player() -> void:
	assert_eq(Format.titleize("warmth_radiator"), "Warmth Radiator")
	assert_eq(Format.titleize(""), "—")
	var hearth: String = Format.building_title(&"the_hearth")
	assert_ne(hearth, "the_hearth", "the registry has a display name; use it")
	assert_true(hearth.length() > 0)
	assert_eq(Format.building_title(&"not_a_real_building"), "Not A Real Building",
		"an unknown id still reads as words, never as a file name")


func test_in_words_rounds_to_something_speakable() -> void:
	assert_eq(Format.in_words(2.0), "now")
	assert_eq(Format.in_words(41.0), "in 40 seconds")
	assert_eq(Format.in_words(95.0), "in 2 minutes")
	assert_eq(Format.in_words(61.0), "in 60 seconds")


## The exact complaint that started this part: the solver knows which tile choked
## which consumers, and the HUD has to say it in English.
func test_bottleneck_becomes_a_sentence() -> void:
	var capacity: Dictionary = {
		"node": 12, "kind": "heat_pipe", "cell": [131, 128],
		"reason": "capacity", "load": 40.0, "capacity": 40.0, "consumers": 6,
	}
	var s: String = Format.bottleneck_sentence(capacity)
	assert_has(s, "(131, 128)", "a player has to be able to find the tile")
	assert_has(s, "6 buildings", "how many it is starving is the stake")
	assert_has_not(s, "heat_pipe", "the id is a file name, not a sentence")
	assert_eq(Format.bottleneck_sentence({"reason": "supply"}),
		"there is not enough heat being made")
	assert_has(Format.bottleneck_sentence({"reason": "unreachable"}), "connects")
	assert_eq(Format.bottleneck_sentence({}), "", "no bottleneck, no sentence")


# =====================================================================  trends =

func test_trend_reads_a_rising_stock() -> void:
	var t: LcnHudTrend = Trend.new()
	for i: int in 10:
		t.sample(&"iron", 100.0 + float(i) * 20.0, float(i) * 2.0)
	assert_near(t.per_minute(&"iron"), 600.0, 1.0, "20 per 2 s is 600 a minute")
	assert_eq(t.direction(&"iron"), 1)
	assert_eq(t.seconds_to_zero(&"iron"), -1.0, "a rising stock has no deadline")


func test_trend_reads_a_falling_stock_as_a_deadline() -> void:
	var t: LcnHudTrend = Trend.new()
	for i: int in 10:
		t.sample(&"coal", 1000.0 - float(i) * 50.0, float(i) * 2.0)
	assert_lt(t.per_minute(&"coal"), 0.0)
	assert_eq(t.direction(&"coal"), -1)
	assert_near(t.seconds_to_zero(&"coal"), 22.0, 1.0,
		"550 left at 25 a second is 22 seconds of city")


func test_trend_ignores_samples_faster_than_its_cadence() -> void:
	var t: LcnHudTrend = Trend.new()
	assert_true(t.sample(&"x", 1.0, 0.0), "the first sample always lands")
	assert_false(t.sample(&"x", 2.0, 0.5), "half a second is not a new sample")
	assert_true(t.sample(&"x", 3.0, 2.0))
	assert_eq(t.samples(&"x"), 2)


func test_trend_forgets_a_rewound_clock() -> void:
	var t: LcnHudTrend = Trend.new()
	for i: int in 6:
		t.sample(&"stone", 500.0 - float(i) * 10.0, float(i) * 2.0)
	assert_ne(t.per_minute(&"stone"), 0.0)
	t.sample(&"stone", 500.0, 0.0)
	assert_eq(t.samples(&"stone"), 1, "a new world is not a collapse in stone")
	assert_eq(t.per_minute(&"stone"), 0.0)


func test_trend_needs_three_points_before_it_claims_anything() -> void:
	var t: LcnHudTrend = Trend.new()
	t.sample(&"y", 10.0, 0.0)
	t.sample(&"y", 0.0, 2.0)
	assert_eq(t.per_minute(&"y"), 0.0, "two points is a rumour, not a trend")


# =====================================================================  alerts =

func _probe_with_heat(deficit: float, starved: int, reason: String) -> LcnHudProbe:
	var p: LcnHudProbe = Probe.new()
	p.has_heat = true
	p.heat_demand = 100.0
	p.heat_delivered = 100.0 - deficit
	p.heat_deficit = deficit
	p.short_networks = [{
		"id": 5, "title": "the Hearth grid", "deficit": deficit, "demand": 100.0,
		"starved": starved, "brownouts": 0,
		"worst_bottleneck": {
			"node": 12, "kind": "heat_pipe", "cell": [131, 128], "reason": reason,
			"load": 40.0, "capacity": 40.0, "consumers": starved,
		},
	}]
	return p


func test_a_shortfall_is_written_not_dumped() -> void:
	var a: LcnHudAlerts = _alerts()
	a.refresh(_probe_with_heat(14.2, 6, "capacity"), 10.0)
	assert_eq(a.entries.size(), 1)
	var e: Dictionary = a.entries[0]
	assert_eq(String(e["head"]), "The Hearth grid is 14 heat short")
	assert_has_not(String(e["head"]), "Network 5", "the sim's own wording never ships")
	assert_has(String(e["body"]), "(131, 128)")
	assert_has(String(e["fix"]), "booster pump", "an alert without a fix is a complaint")
	assert_eq(e["focus"], Vector2(131.5, 128.5) * 32.0,
		"clicking it has to land the camera on the tile")


func test_a_rounding_artefact_never_becomes_an_alert() -> void:
	var a: LcnHudAlerts = _alerts()
	a.refresh(_probe_with_heat(0.2, 0, "capacity"), 10.0)
	assert_empty(a.entries, "'short 0 heat/s' is noise, and noise is not shown")


func test_a_small_shortfall_that_starves_someone_is_still_shown() -> void:
	var a: LcnHudAlerts = _alerts()
	a.refresh(_probe_with_heat(0.2, 2, "capacity"), 10.0)
	assert_eq(a.entries.size(), 1)
	assert_has(String((a.entries[0] as Dictionary)["head"]), "browning out")


func test_frozen_buildings_are_one_line_not_six() -> void:
	var p: LcnHudProbe = Probe.new()
	p.has_heat = true
	p.heat_frozen = 6
	var a: LcnHudAlerts = _alerts()
	a.refresh(p, 10.0)
	assert_eq(a.entries.size(), 1)
	assert_eq(String((a.entries[0] as Dictionary)["head"]), "6 buildings have frozen solid")
	assert_eq(int((a.entries[0] as Dictionary)["count"]), 6)


func test_worst_first_and_stable() -> void:
	var p: LcnHudProbe = Probe.new()
	p.has_heat = true
	p.heat_frozen = 1                      # WARN
	p.has_population = true
	p.population = 40
	p.freezing = 20                        # CRITICAL
	p.sick = 3                             # WARN
	var a: LcnHudAlerts = _alerts()
	a.refresh(p, 10.0)
	assert_ge(float(a.entries.size()), 3.0)
	assert_eq(int((a.entries[0] as Dictionary)["sev"]), Style.Sev.CRITICAL)
	assert_has(String((a.entries[0] as Dictionary)["head"]), "freezing")
	var first_pass: PackedStringArray = _keys_of(a)
	a.refresh(p, 10.5)
	assert_eq(_keys_of(a), first_pass, "an unchanged city must not reshuffle its list")


func _keys_of(a: LcnHudAlerts) -> PackedStringArray:
	var out := PackedStringArray()
	for e: Dictionary in a.entries:
		out.append(String(e["key"]))
	return out


func test_an_alert_disappears_when_the_cause_does() -> void:
	var p: LcnHudProbe = _probe_with_heat(14.0, 6, "supply")
	var a: LcnHudAlerts = _alerts()
	a.refresh(p, 10.0)
	assert_not_empty(a.entries)
	p.short_networks.clear()
	p.heat_deficit = 0.0
	a.refresh(p, 11.0)
	assert_empty(a.entries, "derived alerts are state, not history")


func test_chatter_goes_to_the_toast_lane() -> void:
	var a: LcnHudAlerts = _alerts()
	Bus.alert_raised.emit(0, &"climate_dusk", "Dusk falls over the city", Vector2.ZERO)
	a.refresh(Probe.new(), 5.0)
	assert_empty(a.entries, "severity 0 must never push a real problem off the list")
	assert_eq(a.toasts().size(), 1)
	assert_eq(String((a.toasts()[0] as Dictionary)["text"]), "Dusk falls over the city")


func test_the_hud_drops_wording_it_already_says_better() -> void:
	var a: LcnHudAlerts = _alerts()
	Bus.alert_raised.emit(1, &"heat_supply_5", "Network 5 short 0 heat/s", Vector2.ZERO)
	Bus.alert_raised.emit(1, &"building_froze", "Coal Generator froze at -31°C", Vector2.ZERO)
	a.refresh(Probe.new(), 5.0)
	assert_empty(a.entries, "both of those are rebuilt from the numbers instead")


func test_an_unknown_bus_alert_is_still_shown() -> void:
	var a: LcnHudAlerts = _alerts()
	Bus.alert_raised.emit(1, &"grid_cramped", "map is unusually closed in", Vector2(96, 64))
	a.refresh(Probe.new(), 5.0)
	assert_eq(a.entries.size(), 1, "a part the HUD has never heard of still gets a voice")
	assert_eq(String((a.entries[0] as Dictionary)["head"]), "Map is unusually closed in")


func test_bus_alerts_expire() -> void:
	var a: LcnHudAlerts = _alerts()
	Bus.alert_raised.emit(1, &"grid_cramped", "map is unusually closed in", Vector2.ZERO)
	a.refresh(Probe.new(), 5.0)
	assert_eq(a.entries.size(), 1)
	a.refresh(Probe.new(), 5.0 + Alerts.BUS_TTL_SECONDS + 1.0)
	assert_empty(a.entries)


func test_repeated_toasts_count_instead_of_stacking() -> void:
	var a: LcnHudAlerts = _alerts()
	for _i: int in 4:
		Bus.toast.emit("Cannot build there")
	a.refresh(Probe.new(), 1.0)
	assert_eq(a.toasts().size(), 1)
	assert_eq(int((a.toasts()[0] as Dictionary)["count"]), 4)


func test_the_end_of_the_world_outranks_everything() -> void:
	var a: LcnHudAlerts = _alerts()
	var p: LcnHudProbe = _probe_with_heat(30.0, 9, "supply")
	Bus.game_over.emit("the last generator went out")
	a.refresh(p, 5.0)
	assert_eq(String((a.entries[0] as Dictionary)["head"]), "The city is lost")
	assert_eq(a.worst_severity(), Style.Sev.CRITICAL)


func test_a_stock_running_out_is_a_deadline_not_a_number() -> void:
	var p: LcnHudProbe = Probe.new()
	p.has_build = true
	p.stock_order = [&"coal"]
	p.stock[&"coal"] = 600
	for i: int in 8:
		p.trend.sample(&"coal", 1000.0 - float(i) * 50.0, float(i) * 2.0)
	var a: LcnHudAlerts = _alerts()
	a.refresh(p, 20.0)
	assert_eq(a.entries.size(), 1)
	assert_has(String((a.entries[0] as Dictionary)["head"]), "Coal runs out")


func test_a_healthy_city_says_nothing_at_all() -> void:
	var p: LcnHudProbe = Probe.new()
	p.has_heat = true
	p.has_population = true
	p.has_society = true
	p.population = 40
	p.hope = 0.8
	p.discontent = 0.1
	p.heat_demand = 80.0
	p.heat_delivered = 80.0
	var a: LcnHudAlerts = _alerts()
	a.refresh(p, 5.0)
	assert_empty(a.entries, "calm when the city is healthy — that is the whole rule")
	assert_eq(a.worst_severity(), Style.Sev.CALM)


# ======================================================================  style =

func test_urgency_moves_the_whole_interface() -> void:
	var s: LcnHudStyle = Style.new()
	s.high_contrast = false
	s.urgency = 0.0
	var calm: float = s.plate_alpha()
	s.urgency = 1.0
	assert_gt(s.plate_alpha(), calm, "an alarmed HUD is louder than a calm one")


func test_reduced_motion_stops_every_pulse() -> void:
	var s: LcnHudStyle = Style.new()
	s.reduce_motion = true
	s.beat = 1.234
	assert_eq(s.pulse(), 0.5)
	s.beat = 9.87
	assert_eq(s.pulse(3.0), 0.5, "nothing on screen may breathe when they asked it not to")


func test_font_scale_only_touches_type() -> void:
	var s: LcnHudStyle = Style.new()
	s.font_scale = 1.5
	assert_eq(s.fs(20), 30)
	s.font_scale = 0.7
	assert_ge(float(s.fs(10)), 8.0, "type never shrinks below legible")


func test_scratches_are_hashed_not_rolled() -> void:
	assert_eq(Style.hash01(7, 3), Style.hash01(7, 3), "the same panel wears the same marks")
	assert_ne(Style.hash01(7, 3), Style.hash01(8, 3))
	for i: int in 32:
		assert_between(Style.hash01(i, i * 3), 0.0, 1.0)


func test_colourblind_modes_separate_the_status_hues() -> void:
	var s: LcnHudStyle = Style.new()
	s.colorblind = &"deutan"
	var good: Color = s.health_colour(1.0)
	var bad: Color = s.health_colour(0.0)
	assert_gt(absf(good.b - bad.b), 0.25, "good and bad must differ in more than hue")


# ======================================================================  probe =

func test_probe_reports_nothing_without_a_world() -> void:
	world.stop()
	var p: LcnHudProbe = Probe.new()
	p.bind()
	p.refresh(true)
	assert_false(p.has_heat)
	assert_false(p.has_climate)
	assert_false(p.has_population)
	assert_eq(p.countdown_seconds(), -1.0)
	assert_eq(p.stress(), 0.0, "an absent world is not an emergency")


## A world that failed to finish building (a part mid-edit anywhere in the repo)
## is a skip, not a failure — and the probe is expected to report nothing at all
## rather than read half-constructed systems.
func _live_world() -> bool:
	if world.ensure().alive():
		return true
	skip("Sim.create_world did not complete in this build")
	return false


func test_probe_reads_the_live_world() -> void:
	if not _live_world():
		return
	world.run(40)
	var p: LcnHudProbe = Probe.new()
	p.bind()
	p.refresh(true)
	if world.has_system(&"climate"):
		assert_true(p.has_climate)
		assert_gt(p.countdown_seconds(), 0.0, "there is always a next deadline")
		assert_ne(p.phase_label, "")
		assert_between(p.night_start_fraction, 0.05, 0.98)
	if world.has_system(&"heat"):
		assert_true(p.has_heat)
		assert_ge(p.heat_demand, 0.0)
	if world.has_system(&"build"):
		assert_true(p.has_build)
		assert_not_empty(p.stock_order, "the rail derives its items from the registry")
		assert_has(p.stock_order, &"iron_plate")
	assert_between(p.stress(), 0.0, 1.0)


func test_probe_describes_a_building_the_way_the_panel_needs_it() -> void:
	if not _live_world() or not world.has_system(&"build"):
		return
	world.cmd({
		"system": &"build", "op": "place", "kind": "the_hearth",
		"cell": [126, 126], "free": true, "instant": true,
	}).run(4)
	var build: SimSystem = world.system(&"build")
	var list: Array = build.call("buildings_of_kind", &"the_hearth")
	if list.is_empty():
		return
	var id: int = int((list[0] as Object).get("id"))
	var p: LcnHudProbe = Probe.new()
	p.bind()
	p.refresh(true)
	var info: Dictionary = p.describe_building(id)
	assert_not_empty(info)
	assert_ne(String(info["title"]), "the_hearth")
	assert_eq(int(info["id"]), id)
	assert_true(info.has("lines"))
	if world.has_system(&"heat"):
		assert_not_empty(info["lines"], "[P02] can answer, so the panel has rows")
		var labels: PackedStringArray = PackedStringArray()
		for l: Dictionary in info["lines"]:
			labels.append(String(l["label"]))
			assert_ne(String(l["tip"]), "", "every number carries its explanation")
		assert_has(labels, "Heat")


func test_probe_survives_a_system_that_only_has_metrics() -> void:
	if not _live_world():
		return
	var fakes: Script = load("res://tests/hud/fake_systems.gd") as Script
	fakes.call("uninstall", &"citizens")
	fakes.call("install", fakes.get("MetricsOnlyCitizens").new(), &"citizens")
	var p: LcnHudProbe = Probe.new()
	p.bind()
	p.refresh(true)
	assert_true(p.has_population)
	assert_eq(p.population, 17, "metrics() is the fallback every SimSystem has")
	assert_eq(p.sick, 3)
	fakes.call("uninstall", &"citizens")


func test_probe_reads_the_wave_preview_in_any_shape_a_part_might_ship() -> void:
	if not _live_world():
		return
	var fakes: Script = load("res://tests/hud/fake_systems.gd") as Script
	fakes.call("uninstall", &"threat")
	var threat: SimSystem = fakes.call("install", fakes.get("FakeThreat").new(), &"threat")
	var p: LcnHudProbe = Probe.new()
	p.bind()
	p.refresh(true)
	assert_true(p.has_threat)
	assert_near(p.wave_seconds, 74.0, 0.01)
	assert_eq(p.wave_number, 3)
	assert_near(p.wave_direction.x, 0.7071, 0.01, "'north-east' is a direction too")
	assert_lt(p.wave_direction.y, 0.0)
	assert_eq(p.wave_origin, Vector2(152, 104) * 32.0, "a cell pair is a position")
	threat.set("seconds", 8.0)
	p.refresh(true)
	assert_gt(p.stress(), 0.5, "eight seconds from a wave is not a calm HUD")
	fakes.call("uninstall", &"threat")


func test_probe_normalises_hope_however_society_expresses_it() -> void:
	if not _live_world():
		return
	var fakes: Script = load("res://tests/hud/fake_systems.gd") as Script
	fakes.call("uninstall", &"society")
	var society: SimSystem = fakes.call("install", fakes.get("FakeSociety").new(), &"society")
	var p: LcnHudProbe = Probe.new()
	p.bind()
	p.refresh(true)
	assert_near(p.hope, 0.62, 0.001)
	society.set("hope_value", 74.0)      # a part that ships 0..100
	p.refresh(true)
	assert_near(p.hope, 0.74, 0.001, "0..100 and 0..1 must both read as 74%")
	fakes.call("uninstall", &"society")


func test_stress_is_bounded_and_earned() -> void:
	var p: LcnHudProbe = Probe.new()
	assert_eq(p.stress(), 0.0)
	p.has_heat = true
	p.heat_demand = 100.0
	p.heat_deficit = 50.0
	assert_eq(p.stress(), 1.0, "half the city cold is as bad as it gets")
	var q: LcnHudProbe = Probe.new()
	q.has_heat = true
	q.heat_demand = 100.0
	q.heat_deficit = 2.0
	assert_between(q.stress(), 0.01, 0.2, "a 2% shortfall is a nudge, not an alarm")
