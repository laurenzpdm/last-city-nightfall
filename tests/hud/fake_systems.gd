class_name LcnHudFakeSystems
extends RefCounted
## Stand-in simulation systems for the parts that are still being written. [P17]
##
## The HUD has to be correct on the day [P05] citizens, [P06] society and [P08]
## threat land, and it has to be honest before they do. These fakes are the
## contract written down: they implement the optional methods LcnHudProbe looks
## for, with the shapes those parts are most likely to ship, so a test can prove
## the whole vitals / wave / selection path works end to end today and a screenshot
## can show what it looks like.
##
## They are never registered by Sim.create_world — a test or the screenshot rig
## installs them by hand into Sim.by_name. Nothing in a real run touches this file.


## Registers a system under a name on the live Sim, exactly as if the part had
## shipped. Returns the system so a test can drive it.
static func install(system: SimSystem, system_key: StringName) -> SimSystem:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return system
	var sim: Node = tree.root.get_node_or_null(NodePath("Sim"))
	if sim == null:
		return system
	var by_name: Dictionary = sim.get("by_name")
	if by_name.has(system_key):
		return by_name[system_key]
	var systems: Array = sim.get("systems")
	system.setup()
	systems.append(system)
	by_name[system_key] = system
	return system


static func uninstall(system_key: StringName) -> void:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return
	var sim: Node = tree.root.get_node_or_null(NodePath("Sim"))
	if sim == null:
		return
	var by_name: Dictionary = sim.get("by_name")
	var existing: Variant = by_name.get(system_key)
	if existing == null:
		return
	by_name.erase(system_key)
	var systems: Array = sim.get("systems")
	var idx: int = systems.find(existing)
	if idx >= 0:
		systems.remove_at(idx)


## [P05]-shaped: explicit accessors plus citizen_info(), the contract the brief
## names for the selection panel.
class FakeCitizens extends SimSystem:
	var pop: int = 42
	var ill: int = 0
	var lost: int = 0
	var cold: int = 0
	var starving: int = 0
	var without_work: int = 0

	func system_name() -> StringName:
		return &"citizens"

	func population() -> int:
		return pop

	func sick_count() -> int:
		return ill

	func dead_count() -> int:
		return lost

	func freezing_count() -> int:
		return cold

	func hungry_count() -> int:
		return starving

	func idle_count() -> int:
		return without_work

	func citizen_info(id: int) -> Dictionary:
		if id < 90000:
			return {}
		return {
			"name": "Citizen %d" % (id - 90000),
			"task": "hauling coal",
			"job": "stoker",
			"home": "housing block",
			"warmth": 0.42,
			"health": 0.8,
			"cell": Vector2i(126, 130),
			"problem": "The walk from home to work crosses cold ground.",
		}

	func workplace_info(_building_id: int) -> Dictionary:
		return {"workers": 2, "required": 4}

	func metrics() -> Dictionary:
		return {"population": pop, "sick": ill, "dead": lost}


## [P06]-shaped: hope and discontent as 0..1 floats.
class FakeSociety extends SimSystem:
	var hope_value: float = 0.62
	var discontent_value: float = 0.18

	func system_name() -> StringName:
		return &"society"

	func hope() -> float:
		return hope_value

	func discontent() -> float:
		return discontent_value

	func metrics() -> Dictionary:
		return {"hope": hope_value, "discontent": discontent_value}


## [P08]-shaped: the next_wave_preview() the brief names, including the awkward
## cases the probe has to survive — a direction given as a word, an origin given
## as a cell pair.
class FakeThreat extends SimSystem:
	var wave: int = 3
	var seconds: float = 74.0
	var strength: float = 0.55
	var direction: Variant = "north-east"
	var origin: Variant = [152, 104]
	var note: String = "Frost-touched, drawn to the warmth."

	func system_name() -> StringName:
		return &"threat"

	func next_wave_preview() -> Dictionary:
		return {
			"wave": wave, "seconds": seconds, "strength": strength,
			"direction": direction, "origin": origin, "note": note,
		}

	func metrics() -> Dictionary:
		return {"wave": wave, "seconds_to_wave": seconds}


## [P06]/[P05] with nothing but metrics(): the probe must still read it. This is
## the "a part shipped without the accessor we hoped for" case.
class MetricsOnlyCitizens extends SimSystem:
	func system_name() -> StringName:
		return &"citizens"

	func metrics() -> Dictionary:
		return {"population": 17, "sick": 3, "dead": 5}


## [P04]-shaped production, for the selection panel's recipe and stall lines.
class FakeProduction extends SimSystem:
	var stalled: int = 2

	func system_name() -> StringName:
		return &"production"

	func building_info(_id: int) -> Dictionary:
		return {"recipe": "steel_plate", "progress": 0.4, "stall_reason": "no_input"}

	func metrics() -> Dictionary:
		return {"stalled": stalled}
