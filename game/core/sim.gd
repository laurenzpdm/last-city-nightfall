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
		var scr: Script = load(path)
		var s: SimSystem = scr.new()
		systems.append(s)
		by_name[s.system_name()] = s

	systems.sort_custom(func(a: SimSystem, b: SimSystem) -> bool: return a.order < b.order)
	for s: SimSystem in systems:
		s.setup()
	for s: SimSystem in systems:
		s.post_setup()

	alive = true
	Log.info("sim", "world created, seed=%d, systems=%d" % [world_seed, systems.size()])
	Bus.world_ready.emit()


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
	for s: SimSystem in systems:
		if s.enabled:
			s.step(tick)


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
