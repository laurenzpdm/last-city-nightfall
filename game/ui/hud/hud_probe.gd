class_name LcnHudProbe
extends RefCounted
## The one place the HUD reads the simulation. [P17]
##
## Eleven systems are being written in parallel and the HUD must be useful when
## three of them exist and correct when all eleven do. So nothing here is called
## directly by name from a widget: every field is filled by asking the sim what
## it can answer, in this order —
##
##   1. the explicit method a part documented (`seconds_until_night()`),
##   2. the same value under any of the names a part might plausibly have used,
##   3. that part's own `metrics()` dictionary, which every SimSystem has,
##   4. a documented "unknown" state the widgets render as a dash.
##
## Missing is not zero. `has_population` is false when [P05] has not landed, and
## the vitals panel goes grey instead of confidently reporting a dead city.
##
## Cost: one refresh is a handful of dictionary reads and at most six
## `network_stats()` calls, and it happens ten times a second, not per frame.
## Shortfalls arrive on Bus.heat_shortfall rather than by scanning every network,
## so a base with two hundred grids costs the same as a base with two.

const REFRESH_HZ: float = 10.0
const SHORTFALL_MEMORY_TICKS: int = 60      ## 3 s — a grid stays "short" this long
const MAX_SHORT_NETWORKS: int = 6
const MAX_SCAN_NETWORKS: int = 48           ## ceiling on the fallback sweep
const SCAN_EVERY: int = 20                  ## and it runs at most once a second

## Materials the rail shows first, when the city has them. Anything else the
## registry knows about is appended alphabetically.
const ITEM_PRIORITY: Array[StringName] = [
	&"coal", &"scrap", &"iron_plate", &"steel_plate", &"stone",
	&"timber", &"gear", &"copper_coil", &"food",
]

# --- clock / weather ---------------------------------------------------------
var has_climate: bool = false
var day: int = 1
var phase: StringName = &"dawn"
var phase_label: String = "Dawn"
var is_night: bool = false
var seconds_to_night: float = -1.0
var seconds_to_dawn: float = -1.0
var day_progress: float = 0.0
var night_start_fraction: float = 0.68
var light_level: float = 0.0
var ambient_c: float = 0.0
var weather_label: String = ""
var weather: StringName = &"clear"
var wind: float = 0.0
var storm_intensity: float = 0.0
var storm_active: bool = false
var storm_title: String = ""
var seconds_to_storm: float = -1.0
var era_title: String = ""
var heat_loss_multiplier: float = 1.0

# --- heat --------------------------------------------------------------------
var has_heat: bool = false
var heat_supply: float = 0.0
var heat_demand: float = 0.0
var heat_delivered: float = 0.0
var heat_deficit: float = 0.0
var heat_loss: float = 0.0
var heat_buffer: float = 0.0
var heat_buffer_capacity: float = 0.0
var heat_networks: int = 0
var heat_frozen: int = 0
var heat_brownouts: int = 0
## Worst-first, at most MAX_SHORT_NETWORKS entries. Each is one whole
## `network_stats()` dictionary plus a `title` the player can read.
var short_networks: Array[Dictionary] = []

# --- population --------------------------------------------------------------
var has_population: bool = false
var population: int = 0
var sick: int = 0
var injured: int = 0
var dead: int = 0
var homeless: int = 0
var idle: int = 0
var freezing: int = 0
var hungry: int = 0
## Body warmth of the average citizen, 0..1. [P05] keeps needs on a 0..100
## scale; the HUD normalises once, here, so no widget has to know that.
var warmth01: float = 1.0
var morale01: float = 1.0
var health01: float = 1.0
var food_days: float = -1.0
var unrest01: float = 0.0

# --- society -----------------------------------------------------------------
var has_society: bool = false
var hope: float = 0.5
var discontent: float = 0.0
## What is moving the meters, strongest first: {key, label, text, rate, today}.
## [P06] writes the sentences; the HUD only has to show them.
var hope_reasons: Array[Dictionary] = []

# --- threat / combat ---------------------------------------------------------
var has_threat: bool = false
var wave_number: int = 0
var wave_seconds: float = -1.0
var wave_strength: float = 0.0
var wave_direction: Vector2 = Vector2.ZERO
var wave_origin: Vector2 = Vector2.ZERO
var wave_note: String = ""
var wave_phrase: String = ""
var wave_band: String = ""
var wave_known: bool = true
var wave_precision: int = 3
var wave_active: bool = false
var has_combat: bool = false
var enemies_alive: int = 0
var turrets_online: int = 0
var turrets_total: int = 0
var turret_uptime: float = 1.0

# --- build / economy ---------------------------------------------------------
var has_build: bool = false
var sites_pending: int = 0
var stalled_machines: int = 0
var stock: Dictionary[StringName, int] = {}
var stock_order: Array[StringName] = []

# --- research ----------------------------------------------------------------
var has_research: bool = false
var research_title: String = ""
var research_progress: float = 0.0

var trend: LcnHudTrend = LcnHudTrend.new()

var _climate: SimSystem = null
var _heat: SimSystem = null
var _build: SimSystem = null
var _citizens: SimSystem = null
var _society: SimSystem = null
var _threat: SimSystem = null
var _combat: SimSystem = null
var _research: SimSystem = null
var _production: SimSystem = null
var _logistics: SimSystem = null

var _bound_tick: int = -1
var _bound_seed: int = -1
var _last_refresh_tick: int = -1000
var _shortfalls: Dictionary[int, Array] = {}      ## nid -> [deficit, tick]
var _net_titles: Dictionary[int, String] = {}
var _net_title_version: int = -1
var _buffer_version: int = -1
var _scanned_tick: int = -1000
var _item_ids: Array[StringName] = []
var _items_scanned: bool = false
var _bus_wave: Array = []                          ## [wave, seconds, tick] from Bus
## instance id -> metrics(), valid for one refresh only.
var _metrics_cache: Dictionary[int, Dictionary] = {}


func _init() -> void:
	if Engine.get_main_loop() != null:
		var bus: Node = _autoload(&"Bus")
		if bus != null:
			bus.connect(&"heat_shortfall", _on_heat_shortfall)
			bus.connect(&"wave_incoming", _on_wave_incoming)
			bus.connect(&"wave_started", _on_wave_started)
			bus.connect(&"wave_cleared", _on_wave_cleared)


## Drops every Bus subscription. MUST be called when the owner goes away: an
## autoload signal holds a reference to the callable, which holds this object,
## which is how a RefCounted subscribed to a global signal never dies.
func dispose() -> void:
	var bus: Node = _autoload(&"Bus")
	if bus == null:
		return
	for pair: Array in [[&"heat_shortfall", _on_heat_shortfall],
			[&"wave_incoming", _on_wave_incoming],
			[&"wave_started", _on_wave_started],
			[&"wave_cleared", _on_wave_cleared]]:
		if bus.is_connected(pair[0], pair[1]):
			bus.disconnect(pair[0], pair[1])


## Re-resolves every system pointer. Called on world_ready and whenever the tick
## counter goes backwards (a load, a new world, a test fixture restarting).
##
## A system pointer is only ever taken from a world that finished being built.
## `Sim.create_world` installs systems one at a time and calls `setup()` on them
## afterwards, so a world that died halfway (a part mid-edit, a bad content file)
## leaves half-constructed systems lying in `Sim.by_name` whose methods dereference
## null internals. Binding only to a live world is what keeps the HUD standing
## while eleven other parts are being written underneath it.
func bind() -> void:
	var sim: Node = _autoload(&"Sim")
	if sim == null or not bool(sim.get("alive")):
		_forget()
		return
	_climate = sim.call("get_system", &"climate") as SimSystem
	_heat = sim.call("get_system", &"heat") as SimSystem
	_build = sim.call("get_system", &"build") as SimSystem
	_citizens = sim.call("get_system", &"citizens") as SimSystem
	_society = sim.call("get_system", &"society") as SimSystem
	_threat = sim.call("get_system", &"threat") as SimSystem
	_combat = sim.call("get_system", &"combat") as SimSystem
	_research = sim.call("get_system", &"research") as SimSystem
	_production = sim.call("get_system", &"production") as SimSystem
	_logistics = sim.call("get_system", &"logistics") as SimSystem
	_net_titles.clear()
	_net_title_version = -1
	_buffer_version = -1
	_items_scanned = false
	_shortfalls.clear()
	# Only a different world invalidates the trends. Re-binding inside the same
	# world (a system arriving late) must not erase a minute of history.
	var rng: Node = _autoload(&"Rng")
	var world_seed: int = 0 if rng == null else int(rng.get("seed_value"))
	if world_seed != _bound_seed:
		_bound_seed = world_seed
		trend.reset()
	_bound_tick = _tick()


## Every system pointer dropped and every reading marked unknown. The HUD hides
## the panels rather than showing zeroes it cannot stand behind.
func _forget() -> void:
	_climate = null
	_heat = null
	_build = null
	_citizens = null
	_society = null
	_threat = null
	_combat = null
	_research = null
	_production = null
	_logistics = null
	has_climate = false
	has_heat = false
	has_build = false
	has_population = false
	has_society = false
	has_threat = false
	has_combat = false
	has_research = false
	short_networks.clear()
	stock.clear()
	stock_order.clear()
	_shortfalls.clear()
	_bound_tick = 0


## Pulls a fresh reading. Returns true when anything was actually re-read;
## `force` ignores the rate limit (used on selection changes and on alerts).
func refresh(force: bool = false) -> bool:
	var sim: Node = _autoload(&"Sim")
	if sim == null or not bool(sim.get("alive")):
		if has_heat or has_climate or has_build:
			_forget()
			return true
		return false
	var tick: int = _tick()
	if tick < _bound_tick or (_climate == null and _heat == null and _build == null):
		bind()
	var every: int = maxi(1, int(20.0 / REFRESH_HZ))
	if not force and tick - _last_refresh_tick < every:
		return false
	_last_refresh_tick = tick
	_metrics_cache.clear()
	_read_climate()
	_read_heat(tick)
	_read_population()
	_read_society()
	_read_threat(tick)
	_read_combat()
	_read_build()
	_read_research()
	_sample_trends()
	return true


# ======================================================================  clock =

func _read_climate() -> void:
	has_climate = _climate != null
	if not has_climate:
		return
	day = int(_ask(_climate, [&"day"], ["day"], float(day)))
	phase = StringName(String(_ask_str(_climate, [&"phase_of_day", &"phase"], ["phase"], "dawn")))
	phase_label = String(_ask_str(_climate, [&"phase_label"], [], LcnHudFormat.titleize(String(phase))))
	is_night = bool(_call_or(_climate, &"is_night", phase == &"night" or phase == &"deep_night"))
	seconds_to_night = _ask(_climate, [&"seconds_until_night"], ["seconds_to_night"], -1.0)
	seconds_to_dawn = _ask(_climate, [&"seconds_until_dawn"], [], -1.0)
	day_progress = _ask(_climate, [&"day_progress"], [], 0.0)
	light_level = _ask(_climate, [&"light_level"], ["light"], 0.0)
	ambient_c = _ask(_climate, [&"ambient_temperature"], ["ambient_temp"], ambient_c)
	weather = StringName(_ask_str(_climate, [&"weather"], ["weather"], "clear"))
	weather_label = _ask_str(_climate, [&"weather_label"], [], LcnHudFormat.titleize(String(weather)))
	wind = _ask(_climate, [&"wind"], ["wind"], 0.0)
	storm_intensity = _ask(_climate, [&"storm_intensity"], ["storm_intensity"], 0.0)
	storm_active = bool(_call_or(_climate, &"is_storm_active", storm_intensity > 0.01))
	storm_title = _ask_str(_climate, [&"storm_title"], [], "")
	seconds_to_storm = _ask(_climate, [&"seconds_until_storm"], [], -1.0)
	era_title = _ask_str(_climate, [&"era_title"], [], "")
	heat_loss_multiplier = _ask(_climate, [&"heat_loss_multiplier"], ["heat_loss_mult"], 1.0)
	var daylight: float = _ask(_climate, [&"daylight_seconds"], [], 0.0)
	var whole_day: float = _ask(_climate, [&"day_length_seconds"], [], 0.0)
	if whole_day > 1.0:
		night_start_fraction = clampf(daylight / whole_day, 0.05, 0.98)


## Seconds until the thing that matters next: nightfall while it is day, dawn
## while it is night. Negative when climate is absent.
func countdown_seconds() -> float:
	if not has_climate:
		return -1.0
	return seconds_to_dawn if is_night else seconds_to_night


func countdown_label() -> String:
	if not has_climate:
		return "—"
	return "SUNRISE IN" if is_night else "NIGHTFALL IN"


# =======================================================================  heat =

func _on_heat_shortfall(network_id: int, deficit: float) -> void:
	_shortfalls[network_id] = [deficit, _tick()]


func _read_heat(tick: int) -> void:
	has_heat = _heat != null
	short_networks.clear()
	if not has_heat:
		return
	var t: Dictionary = {}
	if _heat.has_method("totals"):
		t = _heat.call("totals")
	else:
		t = _metrics(_heat)
	heat_supply = float(t.get("supply", 0.0))
	heat_demand = float(t.get("demand", 0.0))
	heat_delivered = float(t.get("delivered", 0.0))
	heat_deficit = float(t.get("deficit", 0.0))
	heat_loss = float(t.get("loss", 0.0))
	heat_buffer = float(t.get("buffer", 0.0))
	heat_networks = int(t.get("networks", 0))
	heat_frozen = int(t.get("frozen", 0))
	heat_brownouts = int(t.get("brownouts", 0))

	if not _heat.has_method("network_stats"):
		return
	var ids: Array = _shortfalls.keys()
	ids.sort()
	var live: Array[Dictionary] = []
	for nid: int in ids:
		var rec: Array = _shortfalls[nid]
		if tick - int(rec[1]) > SHORTFALL_MEMORY_TICKS:
			_shortfalls.erase(nid)
			continue
		var stats: Dictionary = _heat.call("network_stats", nid)
		if stats.is_empty() or float(stats.get("deficit", 0.0)) <= 0.05:
			continue
		stats["title"] = network_title(nid)
		live.append(stats)
	live.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("deficit", 0.0)) > float(b.get("deficit", 0.0)))
	for s: Dictionary in live:
		if short_networks.size() < MAX_SHORT_NETWORKS:
			short_networks.append(s)
	# The signal-driven path only learns about a grid when [P02] next announces
	# it — at most once a second per network, and never at all while the clock is
	# paused. When the totals say heat is missing and no announcement has arrived,
	# go and look. Bounded, throttled, and only on the unhappy path.
	if short_networks.is_empty() and heat_deficit > 0.5 \
			and tick - _scanned_tick >= SCAN_EVERY:
		_scanned_tick = tick
		_scan_for_shortfalls()
	_read_buffer_capacity()


## One sweep of the network list, worst first. Runs only when the city is short
## of heat and nothing has said which grid it is.
func _scan_for_shortfalls() -> void:
	if not _heat.has_method("network_ids"):
		return
	var ids: PackedInt32Array = _heat.call("network_ids")
	var found: Array[Dictionary] = []
	var looked: int = 0
	for nid: int in ids:
		looked += 1
		if looked > MAX_SCAN_NETWORKS:
			break
		var stats: Dictionary = _heat.call("network_stats", nid)
		if stats.is_empty() or float(stats.get("deficit", 0.0)) <= 0.05:
			continue
		stats["title"] = network_title(nid)
		found.append(stats)
	found.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("deficit", 0.0)) > float(b.get("deficit", 0.0)))
	for f: Dictionary in found:
		if short_networks.size() >= MAX_SHORT_NETWORKS:
			break
		short_networks.append(f)


## Total thermal storage the city owns, summed from the heat definitions. Only
## recomputed when the graph changes shape — a buffer's capacity cannot move
## without a building being placed or removed, and that always bumps the version.
func _read_buffer_capacity() -> void:
	var graph: Object = _heat.call("graph") if _heat.has_method("graph") else null
	if graph == null:
		heat_buffer_capacity = maxf(heat_buffer_capacity, heat_buffer)
		return
	var version: int = int(graph.get("version"))
	if version == _buffer_version:
		return
	_buffer_version = version
	var total: float = 0.0
	var nodes: Dictionary = _heat.get("nodes")
	for id: int in nodes:
		var def: Object = (nodes[id] as Object).get("def")
		if def != null:
			total += float(def.get("storage"))
	heat_buffer_capacity = total


## "the Hearth grid", "the Coal Generator grid" — a name a player can point at,
## derived from the biggest producer actually on the network. Cached until the
## graph changes shape.
func network_title(nid: int) -> String:
	if _heat == null:
		return "grid %d" % nid
	var graph: Object = _heat.call("graph") if _heat.has_method("graph") else null
	if graph == null:
		return "grid %d" % nid
	var version: int = int(graph.get("version"))
	if version != _net_title_version:
		_net_titles.clear()
		_net_title_version = version
	var cached: String = _net_titles.get(nid, "")
	if cached != "":
		return cached
	var members: Dictionary = graph.get("members")
	var ids: PackedInt32Array = members.get(nid, PackedInt32Array())
	var nodes: Dictionary = _heat.get("nodes")
	var best_id: int = -1
	var best_out: float = -1.0
	var hungriest: int = -1
	var most_demand: float = -1.0
	for id: int in ids:
		var node: Object = nodes.get(id)
		if node == null:
			continue
		var def: Object = node.get("def")
		if def == null:
			continue
		var out: float = float(def.get("output"))
		if out > best_out:
			best_out = out
			best_id = id
		var want: float = float(def.get("demand"))
		if want > most_demand:
			most_demand = want
			hungriest = id
	var title: String = "grid %d" % nid
	if best_id >= 0 and best_out > 0.0:
		title = _grid_name(String((nodes[best_id] as Object).get("kind")), "grid")
	elif hungriest >= 0 and most_demand > 0.0:
		# No generator on it at all: name it after what is waiting to be fed,
		# which is also the thing the player has to go and look at.
		title = _grid_name(String((nodes[hungriest] as Object).get("kind")), "run")
	_net_titles[nid] = title
	return title


## "the Hearth grid", "the Warmth Radiator run". "The Hearth" already carries its
## article, and "the The Hearth grid" is not something a person would say.
func _grid_name(kind: String, suffix: String) -> String:
	var name: String = LcnHudFormat.building_title(StringName(kind))
	if name.to_lower().begins_with("the "):
		return "%s %s" % [name, suffix]
	return "the %s %s" % [name, suffix]


## World position of the tile that is choking a network, for the camera jump.
func network_focus(stats: Dictionary) -> Vector2:
	var worst: Dictionary = stats.get("worst_bottleneck", {})
	var raw: Variant = worst.get("cell", null)
	if raw is Array and (raw as Array).size() >= 2:
		var arr: Array = raw as Array
		return Vector2(float(arr[0]) + 0.5, float(arr[1]) + 0.5) * 32.0
	return Vector2.ZERO


# =================================================================  population =

func _read_population() -> void:
	has_population = _citizens != null
	if not has_population:
		return
	population = int(_ask(_citizens, [&"population", &"alive", &"citizen_count"],
		["population", "alive", "citizens", "pop"], 0.0))
	sick = int(_ask(_citizens, [&"sick_count", &"sick"], ["sick", "ill"], 0.0))
	injured = int(_ask(_citizens, [&"injured_count"], ["injured"], 0.0))
	dead = int(_ask(_citizens, [&"dead_total", &"dead_count", &"dead", &"deaths"],
		["dead_total", "dead", "deaths", "died"], 0.0))
	homeless = int(_ask(_citizens, [&"homeless_count", &"homeless"], ["homeless"], 0.0))
	var employed: int = int(_ask(_citizens, [&"employed_count"], ["employed"], -1.0))
	idle = int(_ask(_citizens, [&"idle_count", &"unemployed"],
		["idle", "unemployed", "jobless"], -1.0))
	if idle < 0:
		idle = maxi(0, population - employed) if employed >= 0 else 0
	warmth01 = _normal01(_ask(_citizens, [&"average_warmth"], ["avg_warmth"], 100.0))
	morale01 = _normal01(_ask(_citizens, [&"average_morale"], ["avg_morale"], 100.0))
	health01 = _normal01(_ask(_citizens, [&"average_health"], ["avg_health"], 100.0))
	unrest01 = _normal01(_ask(_citizens, [&"unrest_pressure"], ["unrest"], 0.0))
	food_days = _ask(_citizens, [&"food_days_remaining"], ["food_days"], -1.0)
	# [P05] tracks warmth as a need, not as a headcount, so the "how many are
	# freezing" number only exists when a part actually offers one. Without it
	# the city-wide average carries the same warning — see `city_is_cold()`.
	freezing = int(_ask(_citizens, [&"freezing_count", &"cold_count"],
		["freezing", "cold"], 0.0))
	hungry = int(_ask(_citizens, [&"hungry_count", &"starving_count"],
		["hungry", "starving"], 0.0))


## True when the average citizen is cold enough to start getting sick.
## [P05]'s own threshold, normalised: below 40 of 100 warmth is where the harm
## begins, below 12 is where it kills.
func city_is_cold() -> bool:
	return has_population and population > 0 and warmth01 < 0.40


func city_is_freezing() -> bool:
	return has_population and population > 0 and warmth01 < 0.12


func _read_society() -> void:
	has_society = _society != null
	if not has_society:
		return
	hope = _normal01(_ask(_society, [&"hope"], ["hope"], 0.5))
	discontent = _normal01(_ask(_society, [&"discontent"], ["discontent"], 0.0))
	hope_reasons.clear()
	if _society.has_method("reasons"):
		var raw: Array = _society.call("reasons", 3)
		for r: Dictionary in raw:
			hope_reasons.append(r)


## Society may express hope as 0..1 or as 0..100. Both are common; guess once,
## from the value, and never show 5000%.
func _normal01(v: float) -> float:
	if v > 1.001:
		return clampf(v / 100.0, 0.0, 1.0)
	return clampf(v, 0.0, 1.0)


# =====================================================================  threat =

func _on_wave_incoming(wave: int, seconds_until: float) -> void:
	_bus_wave = [wave, seconds_until, _tick()]


func _on_wave_started(wave: int, _strength: float) -> void:
	_bus_wave = [wave, 0.0, _tick()]
	wave_active = true


func _on_wave_cleared(_wave: int) -> void:
	wave_active = false
	_bus_wave = []


## [P08]'s preview if it has one, the Bus countdown if it does not, nothing if
## neither. `wave_seconds` is negative when there is nothing to show.
##
## [P08] REDACTS this dictionary by how much scouting the player has earned
## (`known` / `precision`), and the HUD honours that: an unscouted wave shows a
## countdown and no direction, because inventing one would be lying to the player
## about information the game deliberately withheld.
func _read_threat(tick: int) -> void:
	has_threat = _threat != null
	wave_seconds = -1.0
	if has_threat and _threat.has_method("next_wave_preview"):
		var p: Dictionary = _threat.call("next_wave_preview")
		if not p.is_empty():
			wave_number = int(p.get("wave", p.get("index", wave_number)))
			wave_seconds = float(p.get("seconds_until", p.get("seconds",
				p.get("eta", p.get("time", -1.0)))))
			wave_strength = float(p.get("strength", p.get("power", p.get("threat", 0.0))))
			wave_known = bool(p.get("known", true))
			wave_precision = int(p.get("precision", 3))
			wave_note = String(p.get("title", p.get("note",
				p.get("description", p.get("label", "")))))
			wave_phrase = String(p.get("direction_phrase", ""))
			wave_band = String(p.get("strength_label", p.get("pressure_band", "")))
			wave_active = bool(p.get("active", wave_active))
			wave_direction = Vector2.ZERO
			wave_origin = Vector2.ZERO
			_read_vectors(p)
			if wave_direction == Vector2.ZERO:
				wave_direction = _to_vector(p.get("direction",
					p.get("dir", p.get("bearing", null))))
			if wave_origin == Vector2.ZERO:
				wave_origin = _to_vector(p.get("origin",
					p.get("from", p.get("spawn", null))), 32.0)
			if wave_direction == Vector2.ZERO and wave_origin != Vector2.ZERO:
				wave_direction = (wave_origin - _core_world()).normalized()
			if not wave_known:
				wave_direction = Vector2.ZERO
				wave_origin = Vector2.ZERO
	if wave_seconds < 0.0 and _bus_wave.size() == 3:
		var elapsed: float = float(tick - int(_bus_wave[2])) * 0.05
		wave_number = int(_bus_wave[0])
		wave_seconds = maxf(0.0, float(_bus_wave[1]) - elapsed)
	if has_threat and wave_seconds < 0.0:
		wave_number = int(_ask(_threat, [&"wave", &"wave_number"], ["wave", "wave_number"],
			float(wave_number)))
		wave_seconds = _ask(_threat, [&"seconds_until_wave"],
			["seconds_to_wave", "next_wave_seconds"], -1.0)
		wave_strength = _ask(_threat, [&"wave_strength", &"pressure"],
			["strength", "pressure"], wave_strength)


## The heaviest approach lane, and where it comes in. [P08] hands out a
## `vectors` array once the player has scouted enough to see one; the biggest
## share is the one the HUD points at.
func _read_vectors(p: Dictionary) -> void:
	var raw: Variant = p.get("vectors", null)
	if raw is Array and not (raw as Array).is_empty():
		var best: Dictionary = {}
		var best_share: float = -1.0
		for v: Dictionary in raw as Array:
			var share: float = float(v.get("share", 1.0))
			if share > best_share:
				best_share = share
				best = v
		if not best.is_empty():
			wave_direction = _compass_vector(String(best.get("compass",
				best.get("label", ""))))
			wave_origin = _to_vector(best.get("entry", best.get("choke", null)), 32.0)
			if wave_direction == Vector2.ZERO and wave_origin != Vector2.ZERO:
				wave_direction = (wave_origin - _core_world()).normalized()
			return
	var labels: Variant = p.get("directions", null)
	if labels is Array and not (labels as Array).is_empty():
		wave_direction = _compass_vector(String((labels as Array)[0]))


func _read_combat() -> void:
	has_combat = _combat != null
	if not has_combat:
		return
	enemies_alive = int(_ask(_combat, [&"enemy_count", &"enemies_alive"],
		["enemies_alive", "enemies", "alive"], 0.0))
	turrets_total = int(_ask(_combat, [&"turret_count"], ["turrets"], 0.0))
	turret_uptime = clampf(_ask(_combat, [&"turret_uptime"], ["turret_uptime"], 1.0),
		0.0, 1.0)
	turrets_online = int(_ask(_combat, [&"turrets_online"], ["turrets_online"],
		roundf(float(turrets_total) * turret_uptime)))
	if enemies_alive > 0:
		wave_active = true


# ======================================================================  build =

func _read_build() -> void:
	has_build = _build != null
	if not has_build:
		return
	sites_pending = int(_ask(_build, [], ["sites", "pending"], 0.0))
	if _production != null:
		stalled_machines = int(_ask(_production, [], ["stalled"], 0.0))
	_read_stock()


## Materials come from whichever system currently owns the ledger. [P11]'s
## BuildStock already routes to [P03]/[P04] when they take over, so asking it is
## always the right answer — we only have to work out WHICH items exist, and the
## honest source for that is every cost line in the registry.
func _read_stock() -> void:
	if not _items_scanned:
		_scan_items()
	stock.clear()
	stock_order.clear()
	var ledger: Object = _build.get("stock")
	if ledger == null:
		return
	for id: StringName in _item_ids:
		var n: int = int(ledger.call("count", id))
		stock[id] = n
		stock_order.append(id)


func _scan_items() -> void:
	_items_scanned = true
	var seen: Dictionary[StringName, bool] = {}
	var reg: Node = _autoload(&"Registry")
	if reg != null:
		for res: Resource in reg.call("all", "buildings"):
			for field: String in ["cost", "upkeep"]:
				if not (field in res):
					continue
				var d: Dictionary = res.get(field)
				for k: StringName in d.keys():
					seen[k] = true
			if "heat_fuel" in res:
				var fuel: StringName = StringName(String(res.get("heat_fuel")))
				if fuel != &"":
					seen[fuel] = true
	for k2: StringName in ITEM_PRIORITY:
		seen[k2] = true
	var rest: Array = seen.keys()
	rest.sort()
	_item_ids.clear()
	for p: StringName in ITEM_PRIORITY:
		if seen.has(p):
			_item_ids.append(p)
			seen.erase(p)
	var remaining: Array = seen.keys()
	remaining.sort()
	for k3: StringName in remaining:
		_item_ids.append(k3)


func _read_research() -> void:
	has_research = _research != null
	if not has_research:
		return
	research_title = LcnHudFormat.titleize(_ask_str(_research,
		[&"current_title", &"current_research"], ["current", "research"], ""))
	research_progress = clampf(_ask(_research, [&"research_progress", &"progress"],
		["progress"], 0.0), 0.0, 1.0)


# =====================================================================  trends =

func _sample_trends() -> void:
	var now: float = _seconds()
	for id: StringName in stock_order:
		trend.sample(id, float(stock[id]), now)
	trend.sample(&"__heat_buffer", heat_buffer, now)
	trend.sample(&"__heat_deficit", heat_deficit, now)
	trend.sample(&"__population", float(population), now)
	trend.sample(&"__hope", hope, now)


# ==================================================================  selection =

## Everything the selection panel knows how to say about one building, gathered
## from whichever systems can answer. Empty when the id is not a building.
func describe_building(id: int) -> Dictionary:
	if _build == null or id < 0:
		return {}
	var b: Object = _build.call("get_building", id)
	if b == null:
		return {}
	var kind: StringName = StringName(String(b.get("kind")))
	var cell: Vector2i = b.get("cell")
	var out: Dictionary = {
		"id": id,
		"kind": kind,
		"title": LcnHudFormat.building_title(kind),
		"cell": cell,
		"world": b.call("world_center"),
		"state": int(b.get("state")),
		"enabled": bool(b.get("enabled")),
		"hp": float(b.get("hp")),
		"max_hp": float(b.get("max_hp")),
		"progress": float(b.call("progress_ratio")),
		"workers": int(b.get("workers")),
		"lines": [] as Array[Dictionary],
		"problems": [] as Array[String],
	}
	var def: Object = b.get("def")
	if def != null:
		out["description"] = String(def.get("description"))
		out["workers_required"] = int(def.get("workers_required"))
		out["residents"] = int(def.get("residents"))
	_describe_heat(id, out)
	_describe_work(id, out)
	return out


func _describe_heat(id: int, out: Dictionary) -> void:
	if _heat == null or not bool(_heat.call("has_building", id)):
		return
	var lines: Array[Dictionary] = out["lines"]
	var problems: Array[String] = out["problems"]
	var state: int = int(_heat.call("state_of", id))
	var served: float = float(_heat.call("served_of", id))
	var temp: float = float(_heat.call("temperature_of", id))
	var nid: int = int(_heat.call("network_of", id))
	out["heat_state"] = state
	out["served"] = served
	out["network"] = nid
	lines.append({
		"label": "Heat", "value": LcnHudFormat.percent(served),
		"good": clampf(served, 0.0, 1.0),
		"tip": "How much of the heat this building asked for actually arrived. "
			+ "Below 100% it works more slowly; at 0% it stops and starts to freeze.",
	})
	lines.append({
		"label": "Inside", "value": LcnHudFormat.temperature(temp),
		"good": clampf(inverse_lerp(-20.0, 12.0, temp), 0.0, 1.0),
		"tip": "The temperature inside this building. It falls when heat stops "
			+ "arriving and the building freezes solid when it gets low enough.",
	})
	if nid >= 0:
		lines.append({
			"label": "Grid", "value": network_title(nid), "good": 1.0,
			"tip": "The heat network this building is wired into. Everything on one "
				+ "network shares the same supply.",
		})
	if state == 3:
		problems.append("It is frozen solid. It does nothing until it thaws.")
	elif not bool(out.get("enabled", true)):
		problems.append("You switched it off.")
	elif served < 0.999:
		var why: Dictionary = _heat.call("bottleneck_of", id)
		var sentence: String = LcnHudFormat.bottleneck_sentence(why)
		if sentence == "":
			sentence = "the grid does not make enough heat"
		problems.append("Only %s of its heat arrives: %s." % [
			LcnHudFormat.percent(served), sentence])
		if not why.is_empty() and why.has("cell"):
			var arr: Array = why["cell"]
			out["problem_focus"] = Vector2(float(arr[0]) + 0.5, float(arr[1]) + 0.5) * 32.0


## Whatever [P04] production and [P05] citizens can say about this building.
## Both are optional; the panel simply gets shorter without them.
##
## [P04] publishes `stall_of(id)` — {reason, item, recipe, rate, staffing,
## heat_factor, progress} — as its overlay contract, and it answers the selection
## panel's question exactly: what is it making, how fast, and what is stopping it.
func _describe_work(id: int, out: Dictionary) -> void:
	var lines: Array[Dictionary] = out["lines"]
	var problems: Array[String] = out["problems"]
	var info: Dictionary = {}
	if _production != null and _production.has_method("stall_of"):
		info = _production.call("stall_of", id)
	elif _production != null and _production.has_method("building_info"):
		info = _production.call("building_info", id)
	if not info.is_empty():
		var recipe: String = String(info.get("recipe", ""))
		if recipe != "":
			lines.append({
				"label": "Making", "value": LcnHudFormat.item_title(StringName(recipe)),
				"good": 1.0,
				"tip": "The recipe this machine is set to. Its speed is the slowest "
					+ "of its heat, its crew and its supply of inputs.",
			})
		if info.has("rate"):
			var rate: float = float(info["rate"])
			lines.append({
				"label": "Speed", "value": LcnHudFormat.percent(rate),
				"good": clampf(rate, 0.0, 1.0),
				"tip": "How fast it is actually running against its rated speed. "
					+ "Heat, crew and cold each cap it independently.",
			})
		if info.has("progress") and float(info["progress"]) > 0.0:
			lines.append({
				"label": "Progress",
				"value": LcnHudFormat.percent(float(info["progress"])),
				"good": 1.0, "tip": "How far along the current craft is.",
			})
		var stall: String = String(info.get("reason", info.get("stall_reason", "")))
		if stall != "":
			problems.append(_stall_sentence(stall, String(info.get("item", ""))))
	_describe_crew(id, out)


## [P04] names its stalls in machine language. This is the translation.
func _stall_sentence(reason: String, item: String) -> String:
	var what: String = LcnHudFormat.item_title(StringName(item)).to_lower()
	match reason:
		"no_input", "starved", "missing_input":
			return "It has run out of %s." % (what if item != "" else "inputs")
		"output_full", "blocked", "backed_up":
			return "Its output is full — nothing is taking the %s away." % (
				what if item != "" else "product")
		"no_recipe", "idle":
			return "No recipe is set, so it is doing nothing."
		"no_heat", "cold", "frozen":
			return "It is too cold to work."
		"no_staff", "understaffed", "no_workers":
			return "Nobody is working here."
		"no_power":
			return "It is not getting the heat it needs to run."
	return "It is stalled: %s." % LcnHudFormat.titleize(reason).to_lower()


## Crew, from whichever accessor [P05] ships.
func _describe_crew(id: int, out: Dictionary) -> void:
	if _citizens == null:
		return
	var lines: Array[Dictionary] = out["lines"]
	var problems: Array[String] = out["problems"]
	var required: int = int(out.get("workers_required", 0))
	var workers: int = -1
	if _citizens.has_method("workers_at"):
		workers = int(_citizens.call("workers_at", id))
	elif _citizens.has_method("workplace_info"):
		var w: Dictionary = _citizens.call("workplace_info", id)
		if not w.is_empty():
			workers = int(w.get("workers", 0))
			required = maxi(required, int(w.get("required", 0)))
	if workers < 0 or (required <= 0 and workers <= 0):
		return
	lines.append({
		"label": "Crew",
		"value": "%d / %d" % [workers, required] if required > 0 else str(workers),
		"good": 1.0 if required <= 0 or workers >= required else float(workers) / float(required),
		"tip": "Citizens working here against the number it needs to run at full "
			+ "speed. A half-staffed building works at half pace.",
	})
	if required > 0 and workers < required:
		problems.append("It is short of crew: %d of the %d it needs." % [workers, required])


## [P05]'s citizen_info if it exists. Empty otherwise, and the panel says so
## rather than inventing a person.
func describe_citizen(id: int) -> Dictionary:
	if _citizens == null or id < 0:
		return {}
	if _citizens.has_method("has_citizen") and not bool(_citizens.call("has_citizen", id)):
		return {}
	for method: StringName in [&"citizen_info", &"describe_citizen", &"info_for"]:
		if _citizens.has_method(method):
			var d: Dictionary = _citizens.call(method, id)
			if not d.is_empty():
				d["id"] = id
				return d
	return {}


## The BUILDING id under a map cell, or -1. Buildings and citizens number
## themselves independently, so the two lookups stay separate: an id on its own
## is meaningless without knowing which system minted it.
func entity_at_cell(cell: Vector2i) -> int:
	if _build != null and _build.has_method("entity_at_cell"):
		return int(_build.call("entity_at_cell", cell))
	return -1


## The CITIZEN id standing on a cell, or -1.
func citizen_at_cell(cell: Vector2i) -> int:
	if _citizens != null and _citizens.has_method("citizen_at_cell"):
		return int(_citizens.call("citizen_at_cell", cell))
	return -1


# =====================================================================  stress =

## 0 calm, 1 the city is dying. The single number the whole HUD reads to decide
## how loud to be. Every term is something the player can actually fix.
func stress() -> float:
	var worst: float = 0.0
	if has_heat and heat_demand > 0.001:
		worst = maxf(worst, clampf(heat_deficit / maxf(1.0, heat_demand) * 2.2, 0.0, 1.0))
	if heat_frozen > 0:
		worst = maxf(worst, clampf(0.45 + float(heat_frozen) * 0.08, 0.0, 1.0))
	if has_population and population > 0:
		worst = maxf(worst, clampf(float(freezing + sick) / float(population) * 2.0, 0.0, 1.0))
		# Warmth is the killer, and [P05] reports it as a need rather than a
		# headcount: 0.40 is where citizens start falling sick, 0.12 is where
		# the cold starts taking their health.
		worst = maxf(worst, clampf(inverse_lerp(0.45, 0.10, warmth01), 0.0, 1.0))
		if food_days >= 0.0:
			worst = maxf(worst, clampf(inverse_lerp(1.5, 0.0, food_days), 0.0, 1.0) * 0.9)
	if has_society:
		worst = maxf(worst, clampf((0.35 - hope) * 2.5, 0.0, 1.0))
		worst = maxf(worst, clampf((discontent - 0.55) * 2.2, 0.0, 1.0))
	if wave_seconds >= 0.0:
		worst = maxf(worst, clampf(inverse_lerp(90.0, 10.0, wave_seconds), 0.0, 1.0) * 0.8)
	if wave_active and enemies_alive > 0:
		worst = maxf(worst, 0.75)
	if storm_active:
		worst = maxf(worst, 0.35 + storm_intensity * 0.35)
	return clampf(worst, 0.0, 1.0)


# ====================================================================  helpers =

func _core_world() -> Vector2:
	var sim: Node = _autoload(&"Sim")
	if sim == null:
		return Vector2.ZERO
	var grid: SimSystem = sim.call("get_system", &"grid") as SimSystem
	if grid == null or not grid.has_method("core_cell"):
		return Vector2.ZERO
	var c: Vector2i = grid.call("core_cell")
	return Vector2(c) * 32.0


func _to_vector(v: Variant, scale: float = 1.0) -> Vector2:
	if v == null:
		return Vector2.ZERO
	if v is Vector2:
		return (v as Vector2) * scale
	if v is Vector2i:
		return Vector2(v as Vector2i) * scale
	if v is Array and (v as Array).size() >= 2:
		var a: Array = v as Array
		return Vector2(float(a[0]), float(a[1])) * scale
	if v is String or v is StringName:
		return _compass_vector(String(v))
	return Vector2.ZERO


## Accepts "north", "NE", "south-west" — a threat director may well describe a
## lane in words, and words are exactly what the HUD wants back.
static func _compass_vector(word: String) -> Vector2:
	var w: String = word.to_lower().replace(" ", "").replace("-", "").replace("_", "")
	var table: Dictionary = {
		"n": Vector2(0, -1), "north": Vector2(0, -1),
		"s": Vector2(0, 1), "south": Vector2(0, 1),
		"e": Vector2(1, 0), "east": Vector2(1, 0),
		"w": Vector2(-1, 0), "west": Vector2(-1, 0),
		"ne": Vector2(1, -1), "northeast": Vector2(1, -1),
		"nw": Vector2(-1, -1), "northwest": Vector2(-1, -1),
		"se": Vector2(1, 1), "southeast": Vector2(1, 1),
		"sw": Vector2(-1, 1), "southwest": Vector2(-1, 1),
	}
	var v: Variant = table.get(w, null)
	if v == null:
		return Vector2.ZERO
	return (v as Vector2).normalized()


## A system's metrics(), built at most once per refresh and only if something
## actually had to fall back to it. `metrics()` is not free — [P04] rebuilds a
## per-item rate table inside it — so a system that answers its own accessors
## never pays for one.
func _metrics(sys: SimSystem) -> Dictionary:
	if sys == null:
		return {}
	var key: int = sys.get_instance_id()
	var cached: Variant = _metrics_cache.get(key)
	if cached != null:
		return cached
	var m: Dictionary = sys.metrics()
	_metrics_cache[key] = m
	return m


## Whether a system answers to a name. Measured against a memoised version and
## kept: Object.has_method is a native table lookup, and building a cache key
## for it costs more than the lookup does.
func _answers(sys: SimSystem, name: StringName) -> bool:
	return sys.has_method(name)


## Ask a system for a number: its own method first, then its metrics, then the
## fallback. This is the whole compatibility strategy in ten lines.
func _ask(sys: SimSystem, methods: Array, keys: Array, fallback: float) -> float:
	if sys == null:
		return fallback
	for name: StringName in methods:
		if _answers(sys, name):
			var v: Variant = sys.call(name)
			if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT or typeof(v) == TYPE_BOOL:
				return float(v)
	if keys.is_empty():
		return fallback
	var m: Dictionary = _metrics(sys)
	for k: String in keys:
		if m.has(k):
			var mv: Variant = m[k]
			if typeof(mv) == TYPE_FLOAT or typeof(mv) == TYPE_INT or typeof(mv) == TYPE_BOOL:
				return float(mv)
	return fallback


func _ask_str(sys: SimSystem, methods: Array, keys: Array, fallback: String) -> String:
	if sys == null:
		return fallback
	for name: StringName in methods:
		if _answers(sys, name):
			var v: Variant = sys.call(name)
			if typeof(v) == TYPE_STRING or typeof(v) == TYPE_STRING_NAME:
				return String(v)
	if keys.is_empty():
		return fallback
	var m: Dictionary = _metrics(sys)
	for k: String in keys:
		if m.has(k):
			var mv: Variant = m[k]
			if typeof(mv) == TYPE_STRING or typeof(mv) == TYPE_STRING_NAME:
				return String(mv)
	return fallback


func _call_or(sys: SimSystem, method: StringName, fallback: Variant) -> Variant:
	if sys != null and _answers(sys, method):
		return sys.call(method)
	return fallback


func _tick() -> int:
	var c: Node = _autoload(&"SimClock")
	return 0 if c == null else int(c.get("tick"))


func _seconds() -> float:
	var c: Node = _autoload(&"SimClock")
	return 0.0 if c == null else float(c.call("seconds"))


## A cell from whatever shape a part reports one in: Vector2i, or [x, y].
static func _to_cell_static(v: Variant) -> Vector2i:
	if v is Vector2i:
		return v as Vector2i
	if v is Array and (v as Array).size() >= 2:
		var a: Array = v as Array
		return Vector2i(int(a[0]), int(a[1]))
	return Vector2i.ZERO


static func _autoload(n: StringName) -> Node:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null(NodePath(n))
