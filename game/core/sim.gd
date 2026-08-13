extends Node
## Root of the simulation world. Holds every SimSystem, owns creation and teardown.
##
## Parts register their system here by adding a line to _SYSTEM_SCRIPTS below —
## this is the ONE shared list, kept tiny and append-only on purpose. Everything
## else (buildings, recipes, enemies, laws) registers by directory scan instead.

## Append-only. One line per part. Order in this array is irrelevant —
## SimSystem.order decides tick order.
const _SYSTEM_SCRIPTS: Array[String] = [
	"res://game/sim/climate/climate_system.gd",
	"res://game/sim/grid/grid_system.gd",
	"res://game/sim/heat/heat_system.gd",
	"res://game/sim/logistics/logistics_system.gd",
	"res://game/sim/production/production_system.gd",
	"res://game/sim/citizens/citizen_system.gd",
	"res://game/sim/society/society_system.gd",
	"res://game/sim/threat/threat_system.gd",
	"res://game/sim/combat/combat_system.gd",
	"res://game/sim/research/research_system.gd",
	"res://game/sim/build/build_system.gd",
]

var systems: Array[SimSystem] = []
var by_name: Dictionary[StringName, SimSystem] = {}
var alive: bool = false

var _commands: Array[Dictionary] = []

# --- per-system tick profiling ------------------------------------------------
# Nobody could attribute a millisecond of the tick budget to a system, so every
# optimisation argument was a guess. This measures it. It is wall-clock and it
# NEVER reaches serialize(), metrics() or any decision the sim makes, so a replay
# stays byte-identical with it on — tools/determinism.sh is the proof, not this
# comment. Cost is two Time.get_ticks_usec() calls per system per tick, ~0.5 us
# against a 24 ms tick, which is why it is on by default: attribution that is
# always there beats a knob nobody turns.
var profile_enabled: bool = true

var _prof_us: PackedInt64Array = PackedInt64Array()
var _prof_peak_us: PackedInt64Array = PackedInt64Array()
var _prof_calls: PackedInt64Array = PackedInt64Array()
var _prof_ticks: int = 0
var _prof_cmd_us: int = 0
var _prof_total_us: int = 0


## Creates a fresh world. Everything before this point is inert.
func create_world(world_seed: int) -> void:
	teardown()
	Rng.reset(world_seed)
	SimClock.reset()
	Bus.world_created.emit(world_seed)

	for path: String in _SYSTEM_SCRIPTS:
		if not ResourceLoader.exists(path):
			Log.debug("sim", "system not present yet: %s" % path)
			continue
		# A script that does not COMPILE loads as null, and `null.new()` used to
		# abort create_world half way through the list: the engine printed one
		# error nothing was counting, `alive` never became true, and the game
		# came up with a renderer, a HUD and no world at all — looking for all
		# the world like a rendering bug. Name the pillar that is missing and
		# keep building the rest, so the run says what is wrong on line one.
		var scr: Script = load(path) as Script
		if scr == null:
			Log.error("sim", "%s failed to compile — that whole pillar is ABSENT from this world" % path)
			continue
		var s: SimSystem = scr.new() as SimSystem
		if s == null:
			Log.error("sim", "%s did not produce a SimSystem — pillar ABSENT from this world" % path)
			continue
		systems.append(s)
		by_name[s.system_name()] = s

	# Sorted THREE times on purpose. A system may legitimately decide its order in
	# _init(), in setup() or while wiring itself in post_setup(); sorting only once
	# up front silently ticked heat behind logistics and production for a whole
	# phase, so every consumer read last tick's power factor. Re-sorting is O(n log n)
	# on eleven elements, once per world, and it makes the declared order true.
	_sort_by_order()
	for s: SimSystem in systems:
		s.setup()
	_sort_by_order()
	for s: SimSystem in systems:
		s.post_setup()
	_sort_by_order()

	alive = true
	profile_reset()
	Log.info("sim", "world created, seed=%d, systems=%d" % [world_seed, systems.size()])
	Bus.world_ready.emit()


## Tie-broken by system name so two parts claiming the same order still produce
## one stable, replayable tick sequence.
func _sort_by_order() -> void:
	systems.sort_custom(func(a: SimSystem, b: SimSystem) -> bool:
		if a.order != b.order:
			return a.order < b.order
		return String(a.system_name()) < String(b.system_name()))


func teardown() -> void:
	systems.clear()
	by_name.clear()
	_commands.clear()
	alive = false


## Typed accessor. `Sim.get_system(&"heat")` — returns null if the part is absent,
## so parts must tolerate a missing dependency during parallel development.
func get_system(n: StringName) -> SimSystem:
	return by_name.get(n)


## The ONLY way view/ and ui/ change simulation state. Queued, applied at the
## start of the next tick, so a click mid-frame cannot desync a replay.
func submit_command(cmd: Dictionary) -> void:
	_commands.append(cmd)


## Called by SimClock. Not for general use.
func _advance(tick: int) -> void:
	if not alive:
		return
	var t_tick0: int = Time.get_ticks_usec() if profile_enabled else 0
	if not _commands.is_empty():
		var pending: Array[Dictionary] = _commands.duplicate()
		_commands.clear()
		for c: Dictionary in pending:
			var target: SimSystem = by_name.get(c.get("system", &""))
			if target != null and target.has_method("handle_command"):
				target.call("handle_command", c)
			else:
				# ERROR, not warn. A command addressed to a system this build does
				# not have is a broken script, and a broken script that only warns
				# is how a scenario ends up three-quarters no-op and still exit 0.
				Log.error("sim", "command for absent system '%s' (op '%s') was dropped" % [
					str(c.get("system", "?")), str(c.get("op", "?"))])
	if not profile_enabled:
		for s: SimSystem in systems:
			if s.enabled:
				s.step(tick)
		return

	var n: int = systems.size()
	if _prof_us.size() != n:
		_prof_resize(n)
	_prof_cmd_us += Time.get_ticks_usec() - t_tick0
	_prof_ticks += 1
	for i: int in n:
		var s: SimSystem = systems[i]
		if not s.enabled:
			continue
		var t0: int = Time.get_ticks_usec()
		s.step(tick)
		var used: int = Time.get_ticks_usec() - t0
		_prof_us[i] += used
		_prof_calls[i] += 1
		if used > _prof_peak_us[i]:
			_prof_peak_us[i] = used
	_prof_total_us += Time.get_ticks_usec() - t_tick0


func _prof_resize(n: int) -> void:
	_prof_us.resize(n)
	_prof_peak_us.resize(n)
	_prof_calls.resize(n)


## Clears the profile counters. Called on world creation; call it again after a
## warm-up stretch when you only want the steady state measured.
func profile_reset() -> void:
	_prof_resize(systems.size())
	_prof_us.fill(0)
	_prof_peak_us.fill(0)
	_prof_calls.fill(0)
	_prof_ticks = 0
	_prof_cmd_us = 0
	_prof_total_us = 0


## Per-system tick cost since the last profile_reset(). Wall clock, in
## milliseconds, plus each system's share of the measured tick. Never feed this
## back into simulation state — it is an observation of the machine, not of the
## world.
func profile_report() -> Dictionary:
	var ticks: int = maxi(1, _prof_ticks)
	var rows: Array[Dictionary] = []
	var sum_us: int = 0
	for i: int in mini(systems.size(), _prof_us.size()):
		sum_us += _prof_us[i]
	var denom: float = float(maxi(1, sum_us + _prof_cmd_us))
	for i: int in mini(systems.size(), _prof_us.size()):
		var s: SimSystem = systems[i]
		rows.append({
			"system": String(s.system_name()),
			"order": s.order,
			"ms_per_tick": snappedf(float(_prof_us[i]) / float(ticks) / 1000.0, 0.0001),
			"peak_ms": snappedf(float(_prof_peak_us[i]) / 1000.0, 0.0001),
			"total_ms": snappedf(float(_prof_us[i]) / 1000.0, 0.1),
			"share": snappedf(float(_prof_us[i]) / denom, 0.0001),
			"ticked": _prof_calls[i],
		})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["ms_per_tick"]) > float(b["ms_per_tick"]))
	return {
		"ticks": _prof_ticks,
		"sim_ms_per_tick": snappedf(float(_prof_total_us) / float(ticks) / 1000.0, 0.0001),
		"systems_ms_per_tick": snappedf(float(sum_us) / float(ticks) / 1000.0, 0.0001),
		"commands_ms_per_tick": snappedf(float(_prof_cmd_us) / float(ticks) / 1000.0, 0.0001),
		"budget_ms": 1000.0 / float(SimClock.TICK_HZ),
		"systems": rows,
	}


func serialize() -> Dictionary:
	var out: Dictionary = {"tick": SimClock.tick, "seed": Rng.seed_value, "rng": Rng.snapshot()}
	var sys: Dictionary = {}
	for s: SimSystem in systems:
		sys[String(s.system_name())] = s.serialize()
	out["systems"] = sys
	return out


func collect_metrics() -> Dictionary:
	var out: Dictionary = {"tick": SimClock.tick}
	for s: SimSystem in systems:
		var m: Dictionary = s.metrics()
		for k: String in m:
			out["%s.%s" % [s.system_name(), k]] = m[k]
	return out
