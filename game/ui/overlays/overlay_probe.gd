class_name LcnOverlayProbe
extends RefCounted
## [P19] Duck-typed reader for the systems that may or may not exist yet.
##
## Eleven parts are being written in parallel. An overlay that hard-references
## [P03] logistics or [P07] combat would either fail to parse or draw an empty
## lens with no explanation. Instead every optional read goes through here:
## the probe resolves a system once, remembers which of several plausible method
## names it actually offers, and reports honestly when nobody answers — so the
## Logistics lens can say "no logistics system in this build" instead of lying
## with an empty screen.
##
## THE CONTRACTS. Any of these makes the matching lens light up:
##
##   logistics/production
##     belt_cells() -> Array[Vector2i] | PackedVector2Array
##     belt_report() -> Array[Dictionary]   {cell, load 0..1, dir, stalled, backed_up}
##     saturation_at(cell: Vector2i) -> float
##     stalled_machines() -> Array[Dictionary] | PackedInt32Array
##     machine_report(id: int) -> Dictionary {reason, input_starved, output_full}
##     request_fuel(...)                     (already used by [P02])
##
##   combat
##     turret_range(id: int) -> float
##     weapon_range_of(id: int) -> float
##
##   citizens
##     walk_radius() -> float
##     worker_range_of(id: int) -> float

var logistics: SimSystem = null
var production: SimSystem = null
var combat: SimSystem = null
var citizens: SimSystem = null
var threat: SimSystem = null

var _belt_source: SimSystem = null
var _belt_method: StringName = &""
var _sat_source: SimSystem = null
var _stall_source: SimSystem = null
var _stall_method: StringName = &""
var _range_source: SimSystem = null
var _range_method: StringName = &""
var _walk_radius: float = -1.0
var _bound: bool = false


## Resolves everything once. Safe to call again after a world reload.
func bind() -> void:
	logistics = Sim.get_system(&"logistics")
	production = Sim.get_system(&"production")
	combat = Sim.get_system(&"combat")
	citizens = Sim.get_system(&"citizens")
	threat = Sim.get_system(&"threat")

	_belt_source = null
	_belt_method = &""
	for sys: SimSystem in [logistics, production]:
		if sys == null:
			continue
		for m: StringName in [&"belt_report", &"belt_cells", &"belts_for_view"]:
			if sys.has_method(m):
				_belt_source = sys
				_belt_method = m
				break
		if _belt_source != null:
			break

	_sat_source = null
	for sys2: SimSystem in [logistics, production]:
		if sys2 != null and sys2.has_method(&"saturation_at"):
			_sat_source = sys2
			break

	_stall_source = null
	_stall_method = &""
	for sys3: SimSystem in [production, logistics]:
		if sys3 == null:
			continue
		for m2: StringName in [&"stalled_machines", &"stalled_report", &"stalls"]:
			if sys3.has_method(m2):
				_stall_source = sys3
				_stall_method = m2
				break
		if _stall_source != null:
			break

	_range_source = null
	_range_method = &""
	if combat != null:
		for m3: StringName in [&"turret_range", &"weapon_range_of", &"range_of"]:
			if combat.has_method(m3):
				_range_source = combat
				_range_method = m3
				break

	_walk_radius = -1.0
	if citizens != null and citizens.has_method(&"walk_radius"):
		var v: Variant = citizens.call(&"walk_radius")
		if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
			_walk_radius = float(v)
	_bound = true


func bound() -> bool:
	return _bound


func has_logistics() -> bool:
	return _belt_source != null or _sat_source != null


func has_stalls() -> bool:
	return _stall_source != null


func has_turret_ranges() -> bool:
	return _range_source != null


func has_walk_radius() -> bool:
	return _walk_radius > 0.0


func walk_radius() -> float:
	return _walk_radius


## One dictionary per belt tile: {cell: Vector2i, load: float, dir: int,
## stalled: bool}. Empty when no logistics system answers.
func belts() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if _belt_source == null:
		return out
	var raw: Variant = _belt_source.call(_belt_method)
	if typeof(raw) != TYPE_ARRAY:
		return out
	for entry: Variant in raw as Array:
		match typeof(entry):
			TYPE_DICTIONARY:
				var d: Dictionary = entry
				var cell: Vector2i = _to_cell(d.get("cell", d.get("pos", Vector2i.ZERO)))
				out.append({
					"cell": cell,
					"load": clampf(float(d.get("load", d.get("saturation", 0.0))), 0.0, 1.0),
					"dir": int(d.get("dir", -1)),
					"stalled": bool(d.get("stalled", false)),
					"backed_up": bool(d.get("backed_up", false)),
				})
			TYPE_VECTOR2I, TYPE_VECTOR2, TYPE_ARRAY:
				var c2: Vector2i = _to_cell(entry)
				out.append({
					"cell": c2, "load": saturation_at(c2), "dir": -1,
					"stalled": false, "backed_up": false,
				})
	return out


func saturation_at(cell: Vector2i) -> float:
	if _sat_source == null:
		return 0.0
	var v: Variant = _sat_source.call(&"saturation_at", cell)
	if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
		return clampf(float(v), 0.0, 1.0)
	return 0.0


## One dictionary per stalled machine: {id: int, reason: String}.
func stalls() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if _stall_source == null:
		return out
	var raw: Variant = _stall_source.call(_stall_method)
	if typeof(raw) == TYPE_PACKED_INT32_ARRAY:
		for id: int in raw as PackedInt32Array:
			out.append({"id": id, "reason": "stalled"})
		return out
	if typeof(raw) != TYPE_ARRAY:
		return out
	for entry: Variant in raw as Array:
		if typeof(entry) == TYPE_DICTIONARY:
			var d: Dictionary = entry
			out.append({
				"id": int(d.get("id", -1)),
				"reason": String(d.get("reason", d.get("why", "stalled"))),
			})
		elif typeof(entry) == TYPE_INT:
			out.append({"id": int(entry), "reason": "stalled"})
	return out


## Weapon reach of a turret in TILES, or -1 when nobody knows.
func turret_range(id: int) -> float:
	if _range_source == null:
		return -1.0
	var v: Variant = _range_source.call(_range_method, id)
	if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
		var r: float = float(v)
		if r > 0.0:
			return r
	return -1.0


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
