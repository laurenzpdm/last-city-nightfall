class_name BuildingInstance
extends RefCounted
## One placed building. The runtime half of a BuildingDef.
##
## Other systems get these from `BuildSystem.get_building(id)` /
## `buildings_with_tag(...)` and are allowed to write the fields explicitly
## marked as owned by them (heat_stored, workers, hp via apply_damage).
## Everything else is the build system's to change.

## Stable id, unique for the lifetime of a world. Never reused, except by undo,
## which deliberately restores the original id so references survive.
var id: int = 0
## BuildingDef.id this instance was stamped from.
var kind: StringName = &""
## Minimum corner of the rotated footprint.
var cell: Vector2i = Vector2i.ZERO
## Quarter-turns clockwise, already folded through the def's symmetry.
var rot: int = 0
## BuildTypes.State
var state: int = BuildTypes.State.GHOST
## Current structural hit points. [P07] combat writes this via apply_damage().
var hp: float = 0.0
## Hit points at completion, cached from the def.
var max_hp: float = 1.0
## Build work accumulated, in ticks-of-work. Complete at def.build_time_ticks.
var progress: float = 0.0
## Demolition work accumulated, in ticks.
var deconstruct_progress: float = 0.0
## Materials actually delivered to the site so far.
var delivered: Dictionary[StringName, int] = {}
## Tick the ghost was created.
var placed_tick: int = 0
## Tick construction finished. -1 while unfinished.
var completed_tick: int = -1
## Player switch. False keeps a finished building idle without demolishing it.
var enabled: bool = true
## Citizens currently assigned. [P05] citizens owns this number.
var workers: int = 0
## Heat currently held in the building's own buffer. [P02] heat owns this number.
var heat_stored: float = 0.0
## Free-form per-instance settings that survive a blueprint round-trip:
## chosen recipe, storage filter, turret target priority.
var meta: Dictionary = {}

## Cached def. Re-resolved from Registry after a load, never serialized.
var def: BuildingDef = null
## Cached occupied cells, recomputed whenever cell or rot changes.
var cells: Array[Vector2i] = []


## Recomputes the footprint cache. Call after touching cell or rot.
func refresh_cells() -> void:
	if def == null:
		cells = [cell]
		return
	cells = def.cells_at(cell, rot)


## Bounding rectangle of the footprint, in cells.
func rect() -> Rect2i:
	if def == null:
		return Rect2i(cell, Vector2i.ONE)
	return def.rect_at(cell, rot)


## Centre of the building in world pixels, for the view and for combat targeting.
func world_center() -> Vector2:
	var s: Vector2i = def.effective_size(rot) if def != null else Vector2i.ONE
	return BuildTypes.world_center(cell, s)


## Finished, switched on and not frozen — i.e. actually doing its job.
func is_running() -> bool:
	return state == BuildTypes.State.OPERATIONAL and enabled


## Finished in the structural sense, whatever it is currently doing.
func is_complete() -> bool:
	return BuildTypes.state_is_complete(state)


## 0..1 construction progress. 1.0 for anything already finished.
func progress_ratio() -> float:
	if is_complete():
		return 1.0
	if def == null or def.build_time_ticks <= 0:
		return 0.0
	return clampf(progress / float(def.build_time_ticks), 0.0, 1.0)


## 0..1 structural integrity.
func health_ratio() -> float:
	return clampf(hp / maxf(1.0, max_hp), 0.0, 1.0)


## Fraction of full output this building can manage with the crew it has.
## Unstaffed buildings that need nobody return 1.0.
func staffing_ratio() -> float:
	if def == null or def.workers_required <= 0:
		return 1.0
	return clampf(float(workers) / float(def.workers_required), 0.0, 1.0)


## Materials still owed to the site before construction can start.
func missing_items() -> Dictionary[StringName, int]:
	var out: Dictionary[StringName, int] = {}
	if def == null:
		return out
	var need: Dictionary[StringName, int] = BuildTypes.to_items(def.cost)
	var keys: Array = need.keys()
	keys.sort()
	for k: StringName in keys:
		var short: int = need[k] - int(delivered.get(k, 0))
		if short > 0:
			out[k] = short
	return out


## True once every material the site needs is on site.
func fully_supplied() -> bool:
	return missing_items().is_empty()


## JSON-safe snapshot. Used by saves, the harness dump and the undo stack.
func to_dict() -> Dictionary:
	return {
		"id": id,
		"kind": String(kind),
		"cell": BuildTypes.cell_to_json(cell),
		"rot": rot,
		"state": state,
		"hp": hp,
		"max_hp": max_hp,
		"progress": progress,
		"deconstruct_progress": deconstruct_progress,
		"delivered": BuildTypes.items_to_json(delivered),
		"placed_tick": placed_tick,
		"completed_tick": completed_tick,
		"enabled": enabled,
		"workers": workers,
		"heat_stored": heat_stored,
		"meta": meta.duplicate(true),
	}


## Rebuilds an instance from to_dict(). `def_lookup` re-resolves the definition.
static func from_dict(data: Dictionary, definition: BuildingDef) -> BuildingInstance:
	var b := BuildingInstance.new()
	b.id = int(data.get("id", 0))
	b.kind = StringName(String(data.get("kind", "")))
	b.cell = BuildTypes.to_cell(data.get("cell", [0, 0]))
	b.rot = int(data.get("rot", 0))
	b.state = int(data.get("state", BuildTypes.State.GHOST))
	b.hp = float(data.get("hp", 1.0))
	b.max_hp = float(data.get("max_hp", 1.0))
	b.progress = float(data.get("progress", 0.0))
	b.deconstruct_progress = float(data.get("deconstruct_progress", 0.0))
	b.delivered = BuildTypes.to_items(data.get("delivered", {}))
	b.placed_tick = int(data.get("placed_tick", 0))
	b.completed_tick = int(data.get("completed_tick", -1))
	b.enabled = bool(data.get("enabled", true))
	b.workers = int(data.get("workers", 0))
	b.heat_stored = float(data.get("heat_stored", 0.0))
	var m: Variant = data.get("meta", {})
	b.meta = (m as Dictionary).duplicate(true) if typeof(m) == TYPE_DICTIONARY else {}
	b.def = definition
	b.refresh_cells()
	return b
