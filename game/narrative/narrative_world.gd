class_name NarrativeWorld
extends RefCounted
## One scan of Caldera Nine per second, flattened into the fact table.
##
## Every number an event may be caused by comes from here, and only from here.
## Systems are read through their public accessors and every one of them is
## optional: twenty parts are built in parallel, and an absent part must make an
## event impossible, never make it fire on a zero.
##
## `present` records which parts actually answered, so the run log can say
## "narrative reads climate, citizens, society, threat" instead of quietly
## triggering the famine beat because [P05] is not in the build and
## `population` therefore reads 0.
##
## COST. This is a walk over roughly sixty scalar accessors, once every twenty
## ticks. Nothing in here allocates per-building or per-citizen.

var facts: Dictionary[StringName, float] = {}
var text: Dictionary[StringName, String] = {}
var present: Dictionary[StringName, bool] = {}

var day_ticks: int = NarrativeDefs.DEFAULT_DAY_TICKS
var hour_ticks: int = NarrativeDefs.DEFAULT_DAY_TICKS / NarrativeDefs.HOURS_PER_DAY

var _climate: SimSystem = null
var _citizens: SimSystem = null
var _society: SimSystem = null
var _threat: SimSystem = null
var _combat: SimSystem = null
var _heat: SimSystem = null
var _build: SimSystem = null
var _production: SimSystem = null
var _logistics: SimSystem = null
var _research: SimSystem = null

var _deaths_at_dawn: int = 0
var _last_day: int = 0


func bind() -> void:
	_climate = Sim.get_system(&"climate")
	_citizens = Sim.get_system(&"citizens")
	_society = Sim.get_system(&"society")
	_threat = Sim.get_system(&"threat")
	_combat = Sim.get_system(&"combat")
	_heat = Sim.get_system(&"heat")
	_build = Sim.get_system(&"build")
	_production = Sim.get_system(&"production")
	_logistics = Sim.get_system(&"logistics")
	_research = Sim.get_system(&"research")
	present = {
		&"climate": _climate != null, &"citizens": _citizens != null,
		&"society": _society != null, &"threat": _threat != null,
		&"combat": _combat != null, &"heat": _heat != null,
		&"build": _build != null, &"production": _production != null,
		&"logistics": _logistics != null, &"research": _research != null,
	}
	if _climate != null:
		var secs: float = float(_climate.call("day_length_seconds"))
		if secs > 0.0:
			day_ticks = maxi(24, int(roundf(secs / SimClock.DT)))
	hour_ticks = maxi(1, day_ticks / NarrativeDefs.HOURS_PER_DAY)


func has(part: StringName) -> bool:
	return bool(present.get(part, false))


## Sorted list of the parts that answered. For the ready line in the log.
func source_list() -> String:
	var keys: Array = present.keys()
	keys.sort()
	var out: PackedStringArray = PackedStringArray()
	for k: StringName in keys:
		if present[k]:
			out.append(String(k))
	return "nothing yet" if out.is_empty() else ", ".join(out)


func fact(key: StringName) -> float:
	return float(facts.get(key, 0.0))


## Reads the whole city. Called once every NarrativeDefs.SAMPLE_EVERY ticks.
func read(tick: int, own: Dictionary) -> void:
	_read_sky(tick)
	_read_people()
	_read_meters()
	_read_dark()
	_read_machine()
	for k: StringName in own.keys():
		facts[k] = float(own[k])
	_fill_missing()


func _read_sky(tick: int) -> void:
	if _climate == null:
		facts[&"day"] = float(1 + tick / maxi(1, day_ticks))
		facts[&"hour"] = float((tick % maxi(1, day_ticks)) / maxi(1, hour_ticks))
		return
	var c: SimSystem = _climate
	var day: int = int(c.call("day"))
	facts[&"day"] = float(day)
	facts[&"hour"] = float((tick % maxi(1, day_ticks)) / maxi(1, hour_ticks))
	facts[&"phase"] = float(int(c.call("phase_index")))
	facts[&"is_night"] = 1.0 if bool(c.call("is_night")) else 0.0
	facts[&"is_deep_night"] = 1.0 if bool(c.call("is_deep_night")) else 0.0
	facts[&"temperature"] = float(c.call("ambient_temperature"))
	facts[&"severity"] = float(c.call("severity"))
	facts[&"era"] = float(int(c.call("era_index")))
	facts[&"storm_active"] = 1.0 if bool(c.call("is_storm_active")) else 0.0
	facts[&"storm_intensity"] = float(c.call("storm_intensity"))
	facts[&"wind"] = float(c.call("wind"))
	facts[&"visibility"] = float(c.call("visibility"))
	facts[&"snow_depth"] = float(c.call("snow_depth"))
	var until: float = float(c.call("seconds_until_storm"))
	facts[&"storm_hours"] = -1.0 if until < 0.0 else until / _seconds_per_hour()
	text[&"era"] = String(c.call("era_title"))
	text[&"weather"] = String(c.call("weather_label"))
	text[&"phase"] = String(c.call("phase_label"))
	var storm: Dictionary = c.call("next_storm")
	text[&"storm"] = String(storm.get("title", "")) if not storm.is_empty() \
		else String(c.call("storm_title"))
	if day != _last_day:
		_last_day = day
		_deaths_at_dawn = int(facts.get(&"deaths", 0.0))


func _seconds_per_hour() -> float:
	return maxf(0.001, float(hour_ticks) * SimClock.DT)


func _read_people() -> void:
	if _citizens == null:
		return
	var p: SimSystem = _citizens
	facts[&"population"] = float(int(p.call("population")))
	facts[&"deaths"] = float(int(p.call("dead_total")))
	facts[&"deaths_today"] = maxf(0.0, facts[&"deaths"] - float(_deaths_at_dawn))
	facts[&"homeless"] = float(int(p.call("homeless_count")))
	facts[&"sick"] = float(int(p.call("sick_count")))
	facts[&"injured"] = float(int(p.call("injured_count")))
	facts[&"avg_warmth"] = float(p.call("average_warmth"))
	facts[&"avg_morale"] = float(p.call("average_morale"))
	facts[&"avg_health"] = float(p.call("average_health"))
	facts[&"unrest"] = float(p.call("unrest_pressure"))
	facts[&"food_days"] = float(p.call("food_days_remaining"))
	var toll: Dictionary = p.call("death_toll")
	facts[&"deaths_cold"] = float(int(toll.get("cold", 0)))
	facts[&"deaths_starvation"] = float(int(toll.get("starvation", 0)))
	facts[&"deaths_illness"] = float(int(toll.get("illness", 0)))
	facts[&"deaths_injury"] = float(int(toll.get("injury", 0)))
	facts[&"deaths_exhaustion"] = float(int(toll.get("exhaustion", 0)))


func _read_meters() -> void:
	if _society == null:
		return
	var s: SimSystem = _society
	facts[&"hope"] = float(s.call("hope"))
	facts[&"discontent"] = float(s.call("discontent"))
	facts[&"hope_rate"] = float(s.call("hope_rate"))
	facts[&"discontent_rate"] = float(s.call("discontent_rate"))
	facts[&"laws_signed"] = float(int(s.call("laws_signed_count")))
	facts[&"grievances"] = float(int(s.call("active_grievances")))
	var dem: Array = s.call("demands")
	facts[&"demands"] = float(dem.size())
	facts[&"hunger_share"] = float(s.call("hunger_share"))
	if _citizens == null:
		facts[&"population"] = float(s.call("population"))
		facts[&"deaths"] = float(s.call("deaths_total"))
		facts[&"sick"] = float(s.call("sick_count"))
		facts[&"homeless"] = float(s.call("homeless_count"))
	var worst: float = 100.0
	var worst_name: String = ""
	for f: Dictionary in s.call("factions") as Array:
		var a: float = float(f.get("approval", 0.0))
		if a < worst:
			worst = a
			worst_name = String(f.get("name", ""))
	facts[&"worst_approval"] = worst
	text[&"angriest"] = worst_name
	if not dem.is_empty():
		var d: Dictionary = dem[0]
		text[&"demand"] = String(d.get("terms", ""))
		text[&"demand_faction"] = String(d.get("faction_name", ""))


func _read_dark() -> void:
	if _threat != null:
		var t: SimSystem = _threat
		facts[&"wave"] = float(int(t.call("wave")))
		facts[&"waves_cleared"] = float(int(t.call("waves_cleared")))
		facts[&"threat_pressure"] = float(t.call("pressure"))
		facts[&"wave_seconds"] = float(t.call("seconds_until_wave"))
	if _combat == null:
		return
	var c: SimSystem = _combat
	facts[&"enemies_alive"] = float(int(c.call("live_enemy_count")))
	facts[&"turrets"] = float(int(c.call("turret_count")))
	facts[&"turret_uptime"] = float(c.call("turret_uptime"))


func _read_machine() -> void:
	if _heat != null:
		var totals: Dictionary = _heat.call("totals")
		facts[&"heat_supply"] = float(totals.get("supply", 0.0))
		facts[&"heat_demand"] = float(totals.get("demand", 0.0))
		facts[&"heat_deficit"] = float(totals.get("deficit", 0.0))
		facts[&"networks"] = float(int(totals.get("networks", 0)))
		facts[&"frozen_buildings"] = float(int(totals.get("frozen", 0)))
	if _build != null:
		facts[&"buildings"] = float(int(_build.call("building_count")))
		var stock: Object = _build.get("stock")
		if stock != null:
			for item: StringName in NarrativeDefs.STOCK_ITEMS:
				facts[StringName("stock_" + String(item))] = float(int(stock.call("count", item)))
	if _production != null:
		# totals(), not stalled_machines(): the latter sorts every machine and
		# builds a worded Dictionary per stall, which is the right thing for a
		# panel that draws them and the wrong thing to do once a second for a
		# count. It was the largest single line in this system's tick.
		var pt: Dictionary = _production.call("totals")
		facts[&"machines"] = float(int(pt.get("machines", 0)))
		facts[&"stalled_machines"] = float(int(pt.get("stalled", 0)))
	if _logistics != null:
		var lt: Dictionary = _logistics.call("totals")
		facts[&"belt_lines"] = float(int(lt.get("belts", 0)))
		facts[&"items_moved"] = float(int(lt.get("hauled", 0)) + int(lt.get("items_on_belts", 0)))
	if _research != null:
		facts[&"research_done"] = float((_research.call("unlocked_ids") as Array).size())
		facts[&"researching"] = 1.0 if String(_research.call("active")) != "" else 0.0
		text[&"researching"] = String(_research.call("active"))


## Anything nobody answered for reads 0, and `present` records why. Filling the
## table completely matters: a condition on a missing key would otherwise depend
## on Dictionary.get's default rather than on a decision anyone made.
func _fill_missing() -> void:
	for k: StringName in NarrativeDefs.fact_keys():
		if not facts.has(k):
			facts[k] = 0.0


# =========================================================================
#  tokens for the writing
# =========================================================================

## {braces} an event body may use. Numbers come out already formatted, so an
## author never writes a format specifier and no line can ever produce
## "String formatting error" in the console.
func tokens() -> Dictionary:
	var out: Dictionary = {
		"city": NarrativeDefs.CITY_NAME,
		"City": NarrativeDefs.CITY_NAME,
		"nine": NarrativeDefs.CITY_SHORT,
	}
	for k: StringName in NarrativeDefs.fact_keys():
		out[String(k)] = NarrativeDefs.fact_value_text(k, fact(k))
	# Every declared text token, always, whether or not the part that fills it
	# has said anything yet. A token that only exists once some system has
	# spoken is a token that renders as a raw brace on day one.
	for k: StringName in NarrativeDefs.text_keys():
		var value: String = String(text.get(k, ""))
		out[String(k) + "_text"] = value if value.strip_edges() != "" \
			else String(NarrativeDefs.TEXTS[k])
	return out


## Replaces every {token} the world knows about. An unknown token is left
## standing on purpose: it shows up in the card, a human sees it, and a test
## catches it — which beats it silently becoming an empty gap in a sentence.
func fill(s: String) -> String:
	if s.find("{") < 0:
		return s
	var out: String = s
	var t: Dictionary = tokens()
	var keys: Array = t.keys()
	keys.sort()
	for k: String in keys:
		out = out.replace("{" + k + "}", String(t[k]))
	return out


## Every unknown {token} in a string. Used by the content test so a typo in a
## body is a red suite instead of a brace in the middle of a sentence.
func unknown_tokens(s: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var t: Dictionary = tokens()
	var i: int = s.find("{")
	while i >= 0:
		var j: int = s.find("}", i + 1)
		if j < 0:
			break
		var key: String = s.substr(i + 1, j - i - 1)
		if not t.has(key) and not out.has(key):
			out.append(key)
		i = s.find("{", j + 1)
	return out


func serialize() -> Dictionary:
	var out: Dictionary = {}
	for k: StringName in NarrativeDefs.fact_keys():
		out[String(k)] = snappedf(fact(k), 0.01)
	return out
