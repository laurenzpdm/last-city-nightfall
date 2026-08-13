class_name LcnAudioProbe
extends RefCounted
## [P23] The one place the mix reads the simulation.
##
## Five times a second, never per frame, and never through `Sim.collect_metrics()`
## — that call asks eleven systems to build eleven dictionaries, and the mix
## needs fourteen numbers. Everything is asked for by the method the owning part
## documented, guarded by `has_method`, with a metrics fallback and finally a
## documented default. A part that has not landed leaves its flag false and the
## layer that depends on it stays silent rather than mixing zeroes.
##
## Nothing here writes to the simulation, and nothing here is read by it.

const POLL_HZ: float = 5.0

# --- climate -----------------------------------------------------------------
var has_climate: bool = false
var is_night: bool = false
var is_deep_night: bool = false
var light: float = 1.0             ## 0 dark, 1 noon
var wind: float = 0.0              ## raw, in whatever units [P09] uses
var wind01: float = 0.0            ## normalised for the mix
var storm01: float = 0.0
var visibility: float = 1.0
var day: int = 1

# --- heat / the hearth -------------------------------------------------------
var has_heat: bool = false
var hearth01: float = 1.0          ## how well the fire is doing, 0..1
var hearth_pos: Vector2 = Vector2.ZERO
var has_hearth_pos: bool = false
var heat_deficit01: float = 0.0
var frozen_buildings: int = 0

# --- the factory -------------------------------------------------------------
var has_production: bool = false
var machines: int = 0
var machines_active: int = 0
var factory01: float = 1.0         ## fraction of the factory that is running
var belts_moving: bool = false

# --- threat / combat ---------------------------------------------------------
var has_threat: bool = false
var threat01: float = 0.0
var wave_active: bool = false
var has_combat: bool = false
var enemies_alive: int = 0

# --- society -----------------------------------------------------------------
var has_society: bool = false
var hope01: float = 0.5
var population: int = 0

var polls: int = 0
var last_poll_usec: int = 0

var _sim: Node = null
var _climate: SimSystem = null
var _heat: SimSystem = null
var _build: SimSystem = null
var _production: SimSystem = null
var _logistics: SimSystem = null
var _threat: SimSystem = null
var _combat: SimSystem = null
var _society: SimSystem = null
var _accum: float = 0.0
var _bound_seed: int = -0x7FFFFFFF
var _hearth_search_tick: int = -10000


func bind() -> void:
	_sim = _autoload(&"Sim")
	_climate = null
	_heat = null
	_build = null
	_production = null
	_logistics = null
	_threat = null
	_combat = null
	_society = null
	if _sim == null or not bool(_sim.get("alive")):
		return
	_climate = _sim.call("get_system", &"climate") as SimSystem
	_heat = _sim.call("get_system", &"heat") as SimSystem
	_build = _sim.call("get_system", &"build") as SimSystem
	_production = _sim.call("get_system", &"production") as SimSystem
	_logistics = _sim.call("get_system", &"logistics") as SimSystem
	_threat = _sim.call("get_system", &"threat") as SimSystem
	_combat = _sim.call("get_system", &"combat") as SimSystem
	_society = _sim.call("get_system", &"society") as SimSystem
	has_hearth_pos = false
	_hearth_search_tick = -10000
	var rng: Node = _autoload(&"Rng")
	_bound_seed = 0 if rng == null else int(rng.get("seed_value"))


## Advances the poll timer and re-reads when it comes due. Returns true when
## anything was actually read this call.
func update(delta: float) -> bool:
	_accum += delta
	if _accum < 1.0 / POLL_HZ:
		return false
	_accum = 0.0
	var sim: Node = _autoload(&"Sim")
	if sim == null or not bool(sim.get("alive")):
		has_climate = false
		has_heat = false
		has_production = false
		has_threat = false
		has_combat = false
		has_society = false
		return true
	# A new world (a load, a restart, a test fixture) invalidates every pointer.
	var rng: Node = _autoload(&"Rng")
	var seed_now: int = 0 if rng == null else int(rng.get("seed_value"))
	if sim != _sim or seed_now != _bound_seed or _climate == null:
		bind()
	var t0: int = Time.get_ticks_usec()
	_read_climate()
	_read_heat()
	_read_factory()
	_read_threat()
	_read_society()
	last_poll_usec = Time.get_ticks_usec() - t0
	polls += 1
	return true


# =================================================================== reading =

func _read_climate() -> void:
	has_climate = _climate != null
	if not has_climate:
		return
	is_night = bool(_ask_bool(_climate, &"is_night", false))
	is_deep_night = bool(_ask_bool(_climate, &"is_deep_night", false))
	light = clampf(_ask(_climate, &"light_level", "light", 1.0), 0.0, 1.0)
	wind = _ask(_climate, &"wind", "wind", 0.0)
	storm01 = clampf(_ask(_climate, &"storm_intensity", "storm_intensity", 0.0), 0.0, 1.0)
	visibility = clampf(_ask(_climate, &"visibility", "visibility", 1.0), 0.0, 1.0)
	day = int(_ask(_climate, &"day", "day", 1.0))
	# [P09] reports wind in its own units and has changed them once already, so
	# the mix normalises against the value it has actually seen rather than
	# against a constant somebody has to remember to update.
	var scale: float = maxf(1.0, absf(wind))
	wind01 = clampf(absf(wind) / maxf(6.0, scale * 0.5), 0.0, 1.0)
	# A whiteout is wind you cannot see through. Either term can drive the howl.
	storm01 = maxf(storm01, 1.0 - visibility)


func _read_heat() -> void:
	has_heat = _heat != null
	if not has_heat:
		return
	var m: Dictionary = _metrics(_heat)
	var supply: float = float(m.get("total_supply", 0.0))
	var demand: float = float(m.get("total_demand", 0.0))
	var deficit: float = float(m.get("deficit", 0.0))
	frozen_buildings = int(m.get("frozen_buildings", 0))
	heat_deficit01 = 0.0 if demand <= 0.01 else clampf(deficit / demand, 0.0, 1.0)
	# The hearth's health is the served fraction of the grid it anchors, pulled
	# down hard by anything frozen. It is deliberately the most sensitive reading
	# in this file: the fire weakening is the thing the player must feel first.
	var served: float = 1.0 if demand <= 0.01 else clampf(supply / demand, 0.0, 1.0)
	var freeze_penalty: float = clampf(float(frozen_buildings) * 0.12, 0.0, 0.7)
	hearth01 = clampf(served * (1.0 - freeze_penalty), 0.0, 1.0)
	_find_hearth()


## Where the fire is. Looked up rarely — the hearth is unique and does not move,
## so this is a roster scan once, not a scan per frame.
func _find_hearth() -> void:
	if has_hearth_pos or _build == null:
		return
	var tick: int = _tick()
	if tick - _hearth_search_tick < 40:
		return
	_hearth_search_tick = tick
	if not _build.has_method("buildings_of_kind"):
		return
	var found: Array = _build.call("buildings_of_kind", &"the_hearth")
	if found.is_empty():
		return
	var b: Object = found[0]
	if b == null or not b.has_method("world_center"):
		return
	hearth_pos = b.call("world_center")
	has_hearth_pos = true


func _read_factory() -> void:
	has_production = _production != null
	if has_production:
		var m: Dictionary = _metrics(_production)
		machines = int(m.get("machines", 0))
		machines_active = int(m.get("active_machines", 0))
		var stalled: int = int(m.get("stalled", 0))
		if machines > 0:
			factory01 = clampf(float(machines_active) / float(machines), 0.0, 1.0)
			# A stall is worse than an idle: it means something the player built
			# is asking for help. Weight it so the machine bus closes further.
			factory01 *= clampf(1.0 - float(stalled) / float(machines) * 0.6, 0.0, 1.0)
		else:
			factory01 = 1.0
	else:
		machines = 0
		machines_active = 0
		factory01 = 1.0
	belts_moving = false
	if _logistics != null:
		var lm: Dictionary = _metrics(_logistics)
		# Honest by construction: this build moves zero items on zero belt lines,
		# so the belt family stays silent instead of pretending to a factory the
		# player has not got. The day [P03] moves an item it is audible.
		belts_moving = float(lm.get("items_moved", 0.0)) > 0.0 \
			or float(lm.get("throughput", 0.0)) > 0.0


func _read_threat() -> void:
	has_threat = _threat != null
	if has_threat:
		threat01 = clampf(_ask(_threat, &"threat_level", "threat_level", 0.0), 0.0, 1.0)
	has_combat = _combat != null
	if has_combat:
		enemies_alive = int(_ask(_combat, &"enemies_alive", "enemies_alive", 0.0))
	wave_active = enemies_alive > 0


func _read_society() -> void:
	has_society = _society != null
	if not has_society:
		return
	var m: Dictionary = _metrics(_society)
	hope01 = clampf(float(m.get("hope", 0.5)), 0.0, 1.0)
	population = int(m.get("population", 0))


# ==================================================================== asking =

## Method first, then that system's own metrics(), then the documented default.
func _ask(sys: SimSystem, method: StringName, metric: String, fallback: float) -> float:
	if sys == null:
		return fallback
	if sys.has_method(method):
		var v: Variant = sys.call(method)
		if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
			return float(v)
	if metric != "":
		var m: Dictionary = _metrics(sys)
		if m.has(metric):
			var mv: Variant = m[metric]
			if typeof(mv) == TYPE_FLOAT or typeof(mv) == TYPE_INT:
				return float(mv)
	return fallback


func _ask_bool(sys: SimSystem, method: StringName, fallback: bool) -> bool:
	if sys == null or not sys.has_method(method):
		return fallback
	return bool(sys.call(method))


var _metric_cache: Dictionary[int, Dictionary] = {}


## metrics() is cheap but not free, and four readers want the same dictionary in
## the same poll. Valid for one poll only.
func _metrics(sys: SimSystem) -> Dictionary:
	if sys == null:
		return {}
	var id: int = sys.get_instance_id()
	var cached: Dictionary = _metric_cache.get(id, {})
	if not cached.is_empty() and int(cached.get("__poll", -1)) == polls:
		return cached
	var m: Dictionary = sys.metrics()
	m["__poll"] = polls
	_metric_cache[id] = m
	return m


func _autoload(n: StringName) -> Node:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null(NodePath(String(n)))


func _tick() -> int:
	var clock: Node = _autoload(&"SimClock")
	return 0 if clock == null else int(clock.get("tick"))


func report() -> Dictionary:
	return {
		"polls": polls,
		"poll_usec": last_poll_usec,
		"night": is_night,
		"light": snappedf(light, 0.001),
		"wind01": snappedf(wind01, 0.001),
		"storm01": snappedf(storm01, 0.001),
		"hearth01": snappedf(hearth01, 0.001),
		"factory01": snappedf(factory01, 0.001),
		"machines": machines,
		"machines_active": machines_active,
		"belts_moving": belts_moving,
		"threat01": snappedf(threat01, 0.001),
		"enemies_alive": enemies_alive,
		"hope01": snappedf(hope01, 0.001),
		"frozen": frozen_buildings,
		"systems_seen": {
			"climate": has_climate, "heat": has_heat, "production": has_production,
			"threat": has_threat, "combat": has_combat, "society": has_society,
		},
	}
