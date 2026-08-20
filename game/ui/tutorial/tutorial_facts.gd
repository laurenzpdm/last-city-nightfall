class_name LcnTutorialFacts
extends RefCounted
## [P21] One scan of the running city, flattened into the table the lessons are
## written against.
##
## THE RULE THIS FILE EXISTS TO ENFORCE: a tutorial step ends because the
## simulation says so, never because a timer expired. Every clause in every
## lesson resolves against a key in here, every key in here is pulled out of a
## live SimSystem through its public accessor, and a key nobody answered for
## reads 0 with `present` recording why. That is the same discipline [P22] uses
## for its 68-key fact table (game/narrative/narrative_world.gd) and it is here
## for the same reason: a step that completes on a countdown teaches the player
## that the game is a slideshow.
##
## Every system is optional. Twenty parts are built in parallel and an absent
## part must make a lesson IMPOSSIBLE to complete, never make it complete on a
## zero — so `networks <= 1` is false when there is no heat system at all, and
## the lesson simply never retires.
##
## COST. Roughly forty scalar accessors plus one walk over the building roster,
## four times a second on the interface thread. Nothing here allocates per
## citizen and nothing here writes to the simulation.

## Every key a lesson may name. A clause naming anything else is refused at load
## by `LcnTutorialLesson.validate()` and the content suite goes red — a typo in
## a threshold must not silently read `Dictionary.get`'s default forever.
const KEYS: Array[StringName] = [
	# the sky
	&"day", &"phase", &"temperature", &"is_night", &"night_seconds", &"dawn_seconds",
	# the grid
	&"networks", &"heat_supply", &"heat_demand", &"heat_deficit", &"frozen",
	&"brownouts", &"hearth_temp", &"off_grid", &"pipes", &"buildings",
	# the people
	&"population", &"avg_warmth", &"avg_morale", &"homeless", &"food_days",
	&"deaths", &"deaths_cold", &"rations_made", &"grain_stock", &"ration_stock",
	&"food_machines",
	# the dark
	&"wave", &"wave_seconds", &"waves_cleared", &"enemies_alive",
	&"turrets", &"warm_turrets", &"turret_uptime",
	# the hands
	&"belts", &"placed_by_player", &"line_fed_burners", &"fuel_by_porter",
	&"porters", &"coal_stock", &"coal_seconds",
]

## Keys printed as a duration rather than a number.
const SECONDS_KEYS: Array[StringName] = [
	&"night_seconds", &"dawn_seconds", &"wave_seconds", &"coal_seconds",
]
## Keys printed as yes / no.
const BOOL_KEYS: Array[StringName] = [&"is_night"]
## Keys printed as a temperature.
const TEMP_KEYS: Array[StringName] = [&"temperature", &"hearth_temp"]
## Keys printed as a percentage of 100.
const PERCENT_KEYS: Array[StringName] = [&"avg_warmth", &"avg_morale"]

## Short label for the live read-out strip under a lesson.
const LABELS: Dictionary[StringName, String] = {
	&"networks": "networks", &"frozen": "frozen", &"off_grid": "off the mains",
	&"heat_deficit": "short by", &"hearth_temp": "hearth", &"temperature": "outside",
	&"population": "people", &"avg_warmth": "warmth", &"food_days": "food",
	&"rations_made": "rations", &"grain_stock": "grain", &"deaths_cold": "cold deaths",
	&"wave_seconds": "they arrive", &"warm_turrets": "warm guns",
	&"turrets": "guns", &"enemies_alive": "on the field",
	&"turret_uptime": "uptime", &"waves_cleared": "nights held",
	&"coal_stock": "coal", &"coal_seconds": "coal lasts",
	&"fuel_by_porter": "carried by hand", &"belts": "belt tiles",
	&"line_fed_burners": "fed by belt", &"porters": "porters",
	&"night_seconds": "dark in", &"homeless": "homeless",
}

const CMP_OPS: Array[String] = ["<=", ">=", "==", "!=", "<", ">"]

## How far back the coal burn rate is measured, in ticks. Ten seconds: long
## enough that one porter's delivery does not read as a trend, short enough that
## "it runs out in a minute" is still true when the player reads it.
const RATE_WINDOW_TICKS: int = 200

var facts: Dictionary[StringName, float] = {}
var text: Dictionary[StringName, String] = {}
var present: Dictionary[StringName, bool] = {}

## False until a live world has actually been read. EVERY clause is false while
## it is false, and that is not a nicety: an unread table answers 0 to every
## key, "networks <= 1" is true of 0, and the first lesson would retire itself
## before the player's first frame and be written into `user://tutorial.cfg` as
## taught. A condition that cannot be evaluated must never look like a pass.
var ready_to_answer: bool = false

## Cells worth pointing at. focus key -> cell. Filled by the scan, never authored.
var focus_cells: Dictionary[StringName, Vector2i] = {}

var _climate: SimSystem = null
var _heat: SimSystem = null
var _build: SimSystem = null
var _citizens: SimSystem = null
var _threat: SimSystem = null
var _combat: SimSystem = null
var _logistics: SimSystem = null
var _production: SimSystem = null

var _coal_samples: Array[Vector2i] = []


## Re-reads which parts are actually in this world. Called on Bus.world_ready.
func bind() -> void:
	_climate = Sim.get_system(&"climate")
	_heat = Sim.get_system(&"heat")
	_build = Sim.get_system(&"build")
	_citizens = Sim.get_system(&"citizens")
	_threat = Sim.get_system(&"threat")
	_combat = Sim.get_system(&"combat")
	_logistics = Sim.get_system(&"logistics")
	_production = Sim.get_system(&"production")
	present = {
		&"climate": _climate != null, &"heat": _heat != null,
		&"build": _build != null, &"citizens": _citizens != null,
		&"threat": _threat != null, &"combat": _combat != null,
		&"logistics": _logistics != null, &"production": _production != null,
	}
	_coal_samples.clear()
	facts.clear()
	text.clear()
	focus_cells.clear()
	ready_to_answer = false


## Sorted list of the parts that answered. For the ready line in the log.
func source_list() -> String:
	var keys: Array = present.keys()
	keys.sort()
	var out: PackedStringArray = PackedStringArray()
	for k: StringName in keys:
		if present[k]:
			out.append(String(k))
	return "nothing yet" if out.is_empty() else ", ".join(out)


func has_part(part: StringName) -> bool:
	return bool(present.get(part, false))


func fact(key: StringName) -> float:
	return float(facts.get(key, 0.0))


static func has_key(key: StringName) -> bool:
	return KEYS.has(key)


# =========================================================================
#  the scan
# =========================================================================

## Reads the whole city. Cheap enough for four calls a second.
func read() -> void:
	if not Sim.alive:
		return
	focus_cells.clear()
	_read_sky()
	_read_grid()
	_read_people()
	_read_dark()
	_read_hands()
	for k: StringName in KEYS:
		if not facts.has(k):
			facts[k] = 0.0
	# `Bus.world_ready` fires from inside Sim.create_world(), BEFORE boot seeds
	# the opening settlement — so for one frame the city is genuinely empty, the
	# heat system reports zero networks, and "networks <= 1" is true of a city
	# that does not exist yet. It retired the first lesson before the player's
	# first frame and wrote it to disk as taught. The table answers nothing until
	# the world has been stepped at least once and something stands in it.
	ready_to_answer = SimClock.tick >= 1 and facts[&"buildings"] >= 1.0


func _read_sky() -> void:
	if _climate == null:
		return
	facts[&"day"] = float(int(_climate.call("day")))
	facts[&"phase"] = float(int(_climate.call("phase_index")))
	facts[&"temperature"] = float(_climate.call("ambient_temperature"))
	facts[&"is_night"] = 1.0 if bool(_climate.call("is_night")) else 0.0
	facts[&"night_seconds"] = maxf(0.0, float(_climate.call("seconds_until_night")))
	facts[&"dawn_seconds"] = maxf(0.0, float(_climate.call("seconds_until_dawn")))
	text[&"phase"] = String(_climate.call("phase_label"))
	text[&"weather"] = String(_climate.call("weather_label"))


func _read_grid() -> void:
	if _heat != null:
		var t: Dictionary = _heat.call("totals")
		facts[&"networks"] = float(int(t.get("networks", 0)))
		facts[&"heat_supply"] = float(t.get("supply", 0.0))
		facts[&"heat_demand"] = float(t.get("demand", 0.0))
		facts[&"heat_deficit"] = float(t.get("deficit", 0.0))
		facts[&"frozen"] = float(int(t.get("frozen", 0)))
		facts[&"brownouts"] = float(int(t.get("brownouts", 0)))
	if _build == null:
		return
	facts[&"buildings"] = float(int(_build.call("building_count")))
	# One walk over the roster, and it answers three questions at once: how much
	# pipe stands, which structures the mains do not reach, and where to point.
	var pipes: int = 0
	var off_grid: int = 0
	var worst_turret: Vector2i = Vector2i.MAX
	var worst_turret_served: float = 2.0
	var first_orphan: Vector2i = Vector2i.MAX
	var orphan_name: String = ""
	var burner: Vector2i = Vector2i.MAX
	var hearth_temp: float = 0.0
	for b: Object in _build.call("running_buildings") as Array:
		var kind: StringName = StringName(String(b.get("kind")))
		var cell: Vector2i = b.get("cell")
		var def: Object = b.get("def")
		if kind == &"heat_pipe" or kind == &"heat_pipe_insulated" or kind == &"heat_trunk_main":
			pipes += 1
			continue
		if _heat == null or not bool(_heat.call("has_building", int(b.get("id")))):
			continue
		var id: int = int(b.get("id"))
		var served: float = float(_heat.call("served_of", id))
		if kind == &"the_hearth":
			hearth_temp = float(_heat.call("temperature_of", id))
		var wants_heat: bool = def != null and float(def.get("heat_consumed")) > 0.0
		if wants_heat and served <= 0.01:
			off_grid += 1
			if first_orphan == Vector2i.MAX:
				first_orphan = cell
				orphan_name = String(def.get("display_name")) if def != null else String(kind)
		if def != null and bool(def.call("has_tag", &"turret")) and served < worst_turret_served:
			worst_turret_served = served
			worst_turret = cell
		if def != null and bool(def.call("has_tag", &"burner")) and burner == Vector2i.MAX:
			burner = cell
	facts[&"pipes"] = float(pipes)
	facts[&"off_grid"] = float(off_grid)
	facts[&"hearth_temp"] = hearth_temp
	text[&"orphan"] = orphan_name
	if first_orphan != Vector2i.MAX:
		focus_cells[&"orphan"] = first_orphan
	if worst_turret != Vector2i.MAX:
		focus_cells[&"turret"] = worst_turret
	if burner != Vector2i.MAX:
		focus_cells[&"burner"] = burner


func _read_people() -> void:
	if _citizens != null:
		facts[&"population"] = float(int(_citizens.call("population")))
		facts[&"avg_warmth"] = float(_citizens.call("average_warmth"))
		facts[&"avg_morale"] = float(_citizens.call("average_morale"))
		facts[&"homeless"] = float(int(_citizens.call("homeless_count")))
		facts[&"food_days"] = float(_citizens.call("food_days_remaining"))
		facts[&"deaths"] = float(int(_citizens.call("dead_total")))
		var toll: Dictionary = _citizens.call("death_toll")
		facts[&"deaths_cold"] = float(int(toll.get("cold", 0)))
	if _production != null:
		facts[&"rations_made"] = float(int(_production.call("produced_total", &"ration")))
	if _build != null:
		var stock: Object = _build.get("stock")
		if stock != null:
			facts[&"grain_stock"] = float(int(stock.call("count", &"grain")))
			facts[&"ration_stock"] = float(int(stock.call("count", &"ration")))
		var kitchens: int = (_build.call("buildings_of_kind", &"field_kitchen") as Array).size()
		kitchens += (_build.call("buildings_of_kind", &"rubble_sorter") as Array).size()
		facts[&"food_machines"] = float(kitchens)


func _read_dark() -> void:
	if _threat != null:
		facts[&"wave"] = float(int(_threat.call("wave")))
		facts[&"wave_seconds"] = maxf(0.0, float(_threat.call("seconds_until_wave")))
		facts[&"waves_cleared"] = float(int(_threat.call("waves_cleared")))
	if _combat != null:
		facts[&"enemies_alive"] = float(int(_combat.call("live_enemy_count")))
		facts[&"turrets"] = float(int(_combat.call("turret_count")))
		facts[&"turret_uptime"] = float(_combat.call("turret_uptime"))
	facts[&"warm_turrets"] = float(_count_warm_turrets())


## A turret that is finished, switched on and actually drawing warmth off the
## grid. `combat.turret_count()` counts posts in the snow as well, and the whole
## lesson is that those two numbers are different.
func _count_warm_turrets() -> int:
	if _build == null or _heat == null:
		return 0
	var n: int = 0
	for b: Object in _build.call("buildings_with_tag", &"turret") as Array:
		if not bool(b.call("is_running")):
			continue
		var id: int = int(b.get("id"))
		if not bool(_heat.call("has_building", id)):
			continue
		if float(_heat.call("served_of", id)) > 0.5 and not bool(_heat.call("is_frozen", id)):
			n += 1
	return n


func _read_hands() -> void:
	if _logistics != null:
		var t: Dictionary = _logistics.call("totals")
		facts[&"belts"] = float(int(t.get("belts", 0)))
		facts[&"placed_by_player"] = float(int(t.get("placed_by_player", 0)))
		facts[&"line_fed_burners"] = float(int(t.get("line_fed_burners", 0)))
		facts[&"fuel_by_porter"] = float(int(t.get("fuel_by_porter", 0)))
		facts[&"porters"] = float(int(t.get("porters", 0)))
	if _build != null:
		var stock: Object = _build.get("stock")
		if stock != null:
			facts[&"coal_stock"] = float(int(stock.call("count", &"coal")))
	facts[&"coal_seconds"] = _seconds_of_coal()


## "Coal runs out in 50 seconds" — measured off the store, not off a table, so
## it stays true when the player builds a second generator. Negative means the
## pile is holding or growing, and the read-out says so in words instead.
func _seconds_of_coal() -> float:
	var now: int = SimClock.tick
	var stock: int = int(fact(&"coal_stock"))
	_coal_samples.append(Vector2i(now, stock))
	while _coal_samples.size() > 2 and now - _coal_samples[0].x > RATE_WINDOW_TICKS:
		_coal_samples.remove_at(0)
	if _coal_samples.size() < 2:
		return -1.0
	var oldest: Vector2i = _coal_samples[0]
	var elapsed: float = float(now - oldest.x) * SimClock.DT
	if elapsed < 1.0:
		return -1.0
	var burned: float = float(oldest.y - stock)
	if burned <= 0.0:
		return -1.0
	return float(stock) / (burned / elapsed)


# =========================================================================
#  clauses
# =========================================================================

## "networks <= 1" against the live table. A clause naming an unknown key is
## FALSE, never true: an unreadable condition must never retire a lesson.
func holds(clause: String) -> bool:
	if not ready_to_answer:
		return false
	var parsed: Dictionary = parse(clause)
	if parsed.is_empty():
		return false
	var key: StringName = parsed["key"]
	if not KEYS.has(key):
		return false
	var lhs: float = fact(key)
	var rhs: float = float(parsed["value"])
	match String(parsed["op"]):
		"<=": return lhs <= rhs
		">=": return lhs >= rhs
		"<": return lhs < rhs
		">": return lhs > rhs
		"==": return is_equal_approx(lhs, rhs)
		"!=": return not is_equal_approx(lhs, rhs)
	return false


func all_hold(clauses: Array[String]) -> bool:
	if clauses.is_empty():
		return false
	for c: String in clauses:
		if not holds(c):
			return false
	return true


func any_holds(clauses: Array[String]) -> bool:
	for c: String in clauses:
		if holds(c):
			return true
	return false


## {key, op, value} or {} when the clause is not three readable pieces.
## Static so the content suite can check every authored clause without a world.
static func parse(clause: String) -> Dictionary:
	var s: String = clause.strip_edges()
	for op: String in CMP_OPS:
		var at: int = s.find(op)
		if at <= 0:
			continue
		var key: String = s.substr(0, at).strip_edges()
		var rhs: String = s.substr(at + op.length()).strip_edges()
		if key == "" or not rhs.is_valid_float():
			continue
		return {"key": StringName(key), "op": op, "value": float(rhs)}
	return {}


# =========================================================================
#  words
# =========================================================================

## Every number a lesson may put in a sentence, already formatted. An author
## never writes a format specifier, so no line can produce "String formatting
## error" in front of a player on their first minute.
func tokens() -> Dictionary:
	var out: Dictionary = {"city": "Caldera Nine", "nine": "Nine"}
	for k: StringName in KEYS:
		out[String(k)] = value_text(k, fact(k))
	for k: StringName in text.keys():
		out[String(k) + "_text"] = String(text[k])
	return out


## Replaces every {token}. Scans the string once. An unknown token is LEFT
## STANDING on purpose: it shows up in the panel, a human sees it, and
## tests/tutorial catches it — which beats it becoming a silent gap in a
## sentence a new player is relying on.
func fill(s: String) -> String:
	var start: int = s.find("{")
	if start < 0:
		return s
	var t: Dictionary = tokens()
	var out: String = ""
	var cursor: int = 0
	while start >= 0:
		var close: int = s.find("}", start + 1)
		if close < 0:
			break
		var key: String = s.substr(start + 1, close - start - 1)
		if t.has(key):
			out += s.substr(cursor, start - cursor) + String(t[key])
			cursor = close + 1
		start = s.find("{", close + 1)
	return out + s.substr(cursor)


## Every {token} in a string that nothing answers for.
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


func value_text(key: StringName, v: float) -> String:
	if BOOL_KEYS.has(key):
		return "yes" if v >= 0.5 else "no"
	if TEMP_KEYS.has(key):
		return "%d°C" % int(roundf(v))
	if PERCENT_KEYS.has(key):
		return "%d%%" % int(roundf(v))
	if SECONDS_KEYS.has(key):
		return duration_text(v)
	# TWO NUMBERS FOR THE SAME LARDER, TWELVE HUNDRED PIXELS APART.
	# `artifacts/play_tour/shots/00_opening.png`: the guide's first card reads
	# "5.3 days left in the larder" and [P17]'s people panel, in the same frame,
	# reads "FOOD 5.5 days". Neither is wrong and a player cannot tell that —
	# they snap to different grids. `LcnHudFormat.days()` is the ONE wording the
	# rest of the interface uses (half-day steps, "half a day", "nothing"),
	# written for exactly this collision between a panel and an alert; the guide
	# is the third surface and it was quoting the raw float.
	if key == &"food_days":
		return LcnHudFormat.days(v)
	# Same argument for the grid. The hole goes through `shortfall()` because
	# that is the one rendering the heat panel, the attention row and [P19]'s
	# legend all now use; supply and demand are throughputs and take `rate()`.
	if key == &"heat_deficit":
		return LcnHudFormat.shortfall(v)
	if key == &"heat_supply" or key == &"heat_demand":
		return LcnHudFormat.rate(v)
	if key == &"turret_uptime":
		return "%d%%" % int(roundf(v * 100.0))
	return "%d" % int(roundf(v))


## Negative reads as "holding": a countdown that has stopped counting is news.
static func duration_text(seconds: float) -> String:
	if seconds < 0.0:
		return "holding"
	if seconds < 90.0:
		return "%d s" % int(roundf(seconds))
	var m: int = int(seconds) / 60
	var s: int = int(seconds) % 60
	return "%d min %02d s" % [m, s]


func label_of(key: StringName) -> String:
	return String(LABELS.get(key, String(key).replace("_", " ")))
