class_name LcnOverlayProbe
extends RefCounted
## [P19] Duck-typed reader for the systems that may or may not exist yet.
##
## Twelve parts are being written in parallel. An overlay that hard-referenced
## [P03] logistics or [P07] combat would either fail to parse while they land or
## draw an empty lens with no explanation — which reads as "everything is fine"
## and is the exact failure this part exists to prevent. So every optional read
## goes through here: the probe resolves a system once, remembers which of
## several plausible method names it actually offers, and reports honestly when
## nobody answers.
##
## THE CONTRACTS IT UNDERSTANDS (first match wins):
##
##   logistics   belts_for_view() -> Array[Dictionary]
##                 {cell, rot, saturation | load, tier, tunnel}
##               belt_report() / belts_for_view() are both accepted
##               saturation_of(cell) / saturation_at(cell) -> float
##   production  machine_ids() -> PackedInt32Array  +  stall_of(id) -> Dictionary
##                 {reason, item, state, rate, ...}; empty reason = running
##               stalled_machines() -> Array is accepted as a shortcut
##   combat      turret_readout() -> Array[Dictionary] {id, weapon, idle, ...}
##               weapon reach comes from Registry("weapons").range_tiles, so no
##               combat internals are touched
##   citizens    workers_at(id) / staffing_of(id) -> the real crew of a building
##
## Everything here is READ-ONLY by construction: only accessors are called, and
## nothing is written back.

## Their rot is 0 east, 1 south, 2 west, 3 north; ours is 0 east, 1 west,
## 2 south, 3 north (see LcnOverlayDefs.DIR_VECTORS).
const ROT_TO_DIR: Array[int] = [0, 2, 1, 3]

var logistics: SimSystem = null
var production: SimSystem = null
var combat: SimSystem = null
var citizens: SimSystem = null
var threat: SimSystem = null

var _belt_source: SimSystem = null
var _belt_method: StringName = &""
var _sat_source: SimSystem = null
var _sat_method: StringName = &""
var _stall_list: SimSystem = null
var _stall_ids: bool = false
var _range_cache: Dictionary[StringName, float] = {}
var _bound: bool = false


## Resolves everything once. Safe to call again after a world reload.
func bind() -> void:
	logistics = Sim.get_system(&"logistics")
	production = Sim.get_system(&"production")
	combat = Sim.get_system(&"combat")
	citizens = Sim.get_system(&"citizens")
	threat = Sim.get_system(&"threat")
	_range_cache.clear()

	_belt_source = null
	_belt_method = &""
	for sys: SimSystem in [logistics, production]:
		if sys == null:
			continue
		for m: StringName in [&"belts_for_view", &"belt_report", &"belt_cells"]:
			if sys.has_method(m):
				_belt_source = sys
				_belt_method = m
				break
		if _belt_source != null:
			break

	_sat_source = null
	_sat_method = &""
	for sys2: SimSystem in [logistics, production]:
		if sys2 == null:
			continue
		for m2: StringName in [&"saturation_of", &"saturation_at"]:
			if sys2.has_method(m2):
				_sat_source = sys2
				_sat_method = m2
				break
		if _sat_source != null:
			break

	_stall_list = null
	_stall_ids = false
	if production != null and production.has_method(&"machine_ids") and production.has_method(&"stall_of"):
		_stall_list = production
		_stall_ids = true
	elif production != null and production.has_method(&"stalled_machines"):
		_stall_list = production
	_bound = true


func bound() -> bool:
	return _bound


func has_logistics() -> bool:
	return _belt_source != null


func has_stalls() -> bool:
	return _stall_list != null


func has_citizens() -> bool:
	return citizens != null


func has_combat() -> bool:
	return combat != null


## One dictionary per belt tile: {cell, load 0..1, dir (our index or -1),
## stalled, tunnel}. Empty when no logistics system answers.
func belts() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if _belt_source == null:
		return out
	var raw: Variant = _belt_source.call(_belt_method)
	if typeof(raw) != TYPE_ARRAY:
		return out
	for entry: Variant in raw as Array:
		if typeof(entry) != TYPE_DICTIONARY:
			var c2: Vector2i = _to_cell(entry)
			out.append({"cell": c2, "load": saturation_of(c2), "dir": -1,
				"stalled": false, "tunnel": false})
			continue
		var d: Dictionary = entry
		var cell: Vector2i = _to_cell(d.get("cell", d.get("pos", Vector2i.ZERO)))
		var load: float = clampf(float(d.get("saturation", d.get("load", 0.0))), 0.0, 1.0)
		var dir: int = -1
		if d.has("dir"):
			dir = int(d["dir"])
		elif d.has("rot"):
			dir = ROT_TO_DIR[posmod(int(d["rot"]), 4)]
		out.append({
			"cell": cell,
			"load": load,
			"dir": dir,
			# A belt at capacity is a belt that has stopped moving, which is the
			# thing a player must see. 0.98 rather than 1.0 because a moving belt
			# never quite reports full.
			"stalled": bool(d.get("stalled", d.get("backed_up", load >= 0.98))),
			"tunnel": bool(d.get("tunnel", false)),
		})
	return out


func saturation_of(cell: Vector2i) -> float:
	if _sat_source == null:
		return 0.0
	var v: Variant = _sat_source.call(_sat_method, cell)
	if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
		return clampf(float(v), 0.0, 1.0)
	return 0.0


## One dictionary per stalled machine: {id, reason, item}. Machines that are
## running are not in the list.
func stalls() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if _stall_list == null:
		return out
	if not _stall_ids:
		var raw: Variant = _stall_list.call(&"stalled_machines")
		if typeof(raw) == TYPE_ARRAY:
			for entry: Variant in raw as Array:
				if typeof(entry) == TYPE_DICTIONARY:
					var e: Dictionary = entry
					out.append({"id": int(e.get("id", -1)),
						"reason": String(e.get("reason", "stalled")),
						"item": String(e.get("item", ""))})
				elif typeof(entry) == TYPE_INT:
					out.append({"id": int(entry), "reason": "stalled", "item": ""})
		return out
	var ids: Variant = _stall_list.call(&"machine_ids")
	if typeof(ids) != TYPE_PACKED_INT32_ARRAY:
		return out
	for id: int in ids as PackedInt32Array:
		var info: Variant = _stall_list.call(&"stall_of", id)
		if typeof(info) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = info
		var reason: String = String(d.get("reason", ""))
		if reason == "":
			continue
		out.append({"id": id, "reason": reason, "item": String(d.get("item", ""))})
	return out


## Weapon reach in TILES for a turret kind, read from the weapon definition
## rather than from [P07]'s internals. -1 when the kind carries no weapon.
func weapon_range(weapon_id: StringName) -> float:
	if weapon_id == &"":
		return -1.0
	if _range_cache.has(weapon_id):
		return _range_cache[weapon_id]
	var reach: float = -1.0
	if Registry.has("weapons", weapon_id):
		var res: Resource = Registry.get_item("weapons", weapon_id)
		if res != null and "range_tiles" in res:
			var v: Variant = res.get("range_tiles")
			if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
				reach = float(v)
	_range_cache[weapon_id] = reach
	return reach


## Real crew on a building, or -1 when nobody staffs anything yet. Without this
## the always-on layer badges every workshop in the city with "no crew" for the
## whole time [P05] has not landed, which is noise, not legibility.
func workers_at(building_id: int) -> int:
	if citizens == null:
		return -1
	for m: StringName in [&"workers_at", &"assigned_to"]:
		if citizens.has_method(m):
			var v: Variant = citizens.call(m, building_id)
			if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
				return int(v)
	return -1


static func _to_cell(v: Variant) -> Vector2i:
	match typeof(v):
		TYPE_VECTOR2I:
			return v
		TYPE_VECTOR2:
			var f: Vector2 = v
			return Vector2i(int(f.x), int(f.y))
		TYPE_ARRAY:
			var a: Array = v
			if a.size() >= 2:
				return Vector2i(int(a[0]), int(a[1]))
		TYPE_DICTIONARY:
			var d: Dictionary = v
			return Vector2i(int(d.get("x", 0)), int(d.get("y", 0)))
	return Vector2i.ZERO
