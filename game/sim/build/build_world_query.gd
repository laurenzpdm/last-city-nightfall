class_name BuildWorldQuery
extends RefCounted
## Read-only adapter between construction and the ground it stands on, plus the
## one write construction owes the world: claiming a footprint.
##
## [P01] grid owns terrain, bounds, deposits and occupancy. This part must stay
## playable when that system is absent (early development, isolated unit tests)
## and must not break when it changes shape, so the binding is done by **probing
## for a method and checking its arity** at world creation rather than by
## compiling against another part's class. What actually got bound is written to
## the log, so a signature drift is one visible line instead of a silent
## fallback to permissive.
##
## Terrain and deposit ids come back from the grid as ints. The build schema
## speaks in names (&"rock", &"vent"), so the name tables are read once out of
## the grid's own script constants — one lookup, no hardcoded duplicate of
## another part's enum.

## Half-width of the playable area assumed while no grid system exists.
const FALLBACK_HALF_EXTENT: int = 512
## Terrain or deposit id meaning "the world could not answer". Rules that need
## the answer are skipped rather than guessed at.
const UNKNOWN: StringName = &""
## Where the shared terrain/deposit name tables live.
const GRID_SCRIPT: String = "res://game/sim/grid/grid.gd"

var _grid: SimSystem = null
## The tile store behind the grid system, when it exposes one.
var _tiles: Object = null

var _m_in_bounds: String = ""
var _m_buildable: String = ""
var _m_terrain: String = ""
var _m_resource: String = ""
var _m_flat: String = ""
var _m_height: String = ""
var _m_occupy: String = ""
var _m_release: String = ""
var _occupy_argc: int = 0

var _terrain_names: Array = []
var _resource_names: Array = []


## Binds against the grid system, or leaves the permissive fallback in place.
func bind(grid: SimSystem) -> void:
	_grid = grid
	_tiles = null
	_m_in_bounds = ""
	_m_buildable = ""
	_m_terrain = ""
	_m_resource = ""
	_m_flat = ""
	_m_height = ""
	_m_occupy = ""
	_m_release = ""
	_occupy_argc = 0
	if grid == null:
		return

	# The tile store answers bounds and buildability directly and cheaply.
	var world_accessor: String = _find(grid, ["world", "tiles", "get_grid"], 0)
	if world_accessor != "":
		var obj: Variant = grid.call(world_accessor)
		if typeof(obj) == TYPE_OBJECT and obj != null:
			_tiles = obj

	var bounds_host: Object = _tiles if _tiles != null else grid
	_m_in_bounds = _find(bounds_host, ["in_bounds", "is_in_bounds", "contains_cell"], 1)
	_m_buildable = _find(bounds_host, ["is_buildable_terrain", "is_buildable", "can_build_on"], 1)

	_m_terrain = _find(grid, ["terrain_at", "get_terrain", "terrain_id_at"], 1)
	_m_resource = _find(grid, ["resource_kind_at", "ore_at", "get_ore", "resource_at", "deposit_at"], 1)
	_m_flat = _find(grid, ["is_flat", "is_level"], 1)
	_m_height = _find(grid, ["elevation_at", "height_at", "get_height"], 1)

	# Footprint claim: prefer the rect form the grid actually offers.
	_m_occupy = _find(grid, ["occupy"], 4)
	_occupy_argc = 4
	if _m_occupy == "":
		_m_occupy = _find(grid, ["occupy", "claim"], 3)
		_occupy_argc = 3
	if _m_occupy == "":
		_m_occupy = _find(grid, ["set_occupied", "mark_occupied", "occupy_cell"], 2)
		_occupy_argc = 2
	_m_release = _find(grid, ["release", "clear_occupied", "release_cell", "unmark_occupied"], 1)

	_load_name_tables()


## Reads the grid's own terrain and deposit name tables, so this part never keeps
## a second copy of another part's enum that could drift out of step.
func _load_name_tables() -> void:
	_terrain_names = []
	_resource_names = []
	if not ResourceLoader.exists(GRID_SCRIPT):
		return
	var scr: Script = load(GRID_SCRIPT)
	if scr == null:
		return
	var consts: Dictionary = scr.get_script_constant_map()
	var t: Variant = consts.get("TERRAIN_NAMES", [])
	if typeof(t) == TYPE_ARRAY:
		_terrain_names = t
	var r: Variant = consts.get("RES_NAMES", [])
	if typeof(r) == TYPE_ARRAY:
		_resource_names = r


## One log line describing what the adapter actually managed to bind.
func describe() -> String:
	if _grid == null:
		return "no grid system; permissive fallback (half-extent %d)" % FALLBACK_HALF_EXTENT
	var parts: PackedStringArray = PackedStringArray()
	parts.append("tiles=%s" % ("yes" if _tiles != null else "no"))
	parts.append("bounds=%s" % _label(_m_in_bounds))
	parts.append("buildable=%s" % _label(_m_buildable))
	parts.append("terrain=%s" % _label(_m_terrain))
	parts.append("deposits=%s" % _label(_m_resource))
	parts.append("flat=%s" % _label(_m_flat if _m_flat != "" else _m_height))
	parts.append("claim=%s/%d" % [_label(_m_occupy), _occupy_argc])
	parts.append("names=%d/%d" % [_terrain_names.size(), _resource_names.size()])
	return " ".join(parts)


func has_grid() -> bool:
	return _grid != null


## Is the cell inside the world at all?
func in_bounds(cell: Vector2i) -> bool:
	if _m_in_bounds != "":
		var host: Object = _tiles if _tiles != null else _grid
		return bool(host.call(_m_in_bounds, cell))
	return absi(cell.x) <= FALLBACK_HALF_EXTENT and absi(cell.y) <= FALLBACK_HALF_EXTENT


## Can a structure stand on this cell — solid ground, not a ridge or a chasm?
## Deliberately ignores claims: this part keeps its own occupancy, which also
## covers ghosts the grid does not know about yet.
func is_buildable(cell: Vector2i) -> bool:
	if not in_bounds(cell):
		return false
	if _m_buildable != "":
		var host: Object = _tiles if _tiles != null else _grid
		return bool(host.call(_m_buildable, cell))
	return true


## Terrain name under a cell, or UNKNOWN when the world cannot say.
func terrain_at(cell: Vector2i) -> StringName:
	if _grid == null or _m_terrain == "":
		return UNKNOWN
	return _name_of(_grid.call(_m_terrain, cell), _terrain_names, "terrain")


## Deposit name under a cell, &"none" for bare ground, UNKNOWN when unanswerable.
func ore_at(cell: Vector2i) -> StringName:
	if _grid == null or _m_resource == "":
		return UNKNOWN
	var name: StringName = _name_of(_grid.call(_m_resource, cell), _resource_names, "deposit")
	return UNKNOWN if name == &"none" else name


## Is every cell of a footprint on the same level? Unknown terrain answers true,
## because a rule nobody can evaluate must not block the player.
func is_flat(cells: Array[Vector2i]) -> bool:
	if _grid == null or cells.is_empty():
		return true
	if _m_flat != "":
		for c: Vector2i in cells:
			if not bool(_grid.call(_m_flat, c)):
				return false
		return true
	if _m_height != "":
		var first: int = int(_grid.call(_m_height, cells[0]))
		for c: Vector2i in cells:
			if int(_grid.call(_m_height, c)) != first:
				return false
	return true


## Claims a finished building's footprint with the grid, so pathing routes around
## it. Non-rectangular footprints claim their bounding rectangle.
func claim(rect: Rect2i, building_id: int, blocks_movement: bool) -> void:
	if _grid == null or _m_occupy == "":
		return
	match _occupy_argc:
		4:
			_grid.call(_m_occupy, rect.position, rect.size, building_id, blocks_movement)
		3:
			_grid.call(_m_occupy, rect.position, rect.size, building_id)
		2:
			for y: int in range(rect.position.y, rect.end.y):
				for x: int in range(rect.position.x, rect.end.x):
					_grid.call(_m_occupy, Vector2i(x, y), building_id)


## Releases whatever a building had claimed.
func unclaim(rect: Rect2i, building_id: int) -> void:
	if _grid == null or _m_release == "":
		return
	# The rect form releases by id; the per-cell form needs the cells themselves.
	if _m_occupy != "" and _occupy_argc >= 3:
		_grid.call(_m_release, building_id)
		return
	for y: int in range(rect.position.y, rect.end.y):
		for x: int in range(rect.position.x, rect.end.x):
			_grid.call(_m_release, Vector2i(x, y))


func _name_of(raw: Variant, table: Array, prefix: String) -> StringName:
	if typeof(raw) == TYPE_STRING or typeof(raw) == TYPE_STRING_NAME:
		return StringName(String(raw))
	var idx: int = int(raw)
	if idx >= 0 and idx < table.size():
		return StringName(String(table[idx]))
	return StringName("%s_%d" % [prefix, idx])


static func _label(m: String) -> String:
	return m if m != "" else "-"


## Finds the first candidate the object actually implements with `argc` declared
## arguments. Arity is checked so a same-named method of a different shape is
## ignored rather than called wrongly.
static func _find(obj: Object, candidates: Array, argc: int) -> String:
	if obj == null:
		return ""
	var arities: Dictionary[String, int] = {}
	for entry: Dictionary in obj.get_method_list():
		var n: String = String(entry.get("name", ""))
		if arities.has(n):
			continue
		arities[n] = (entry.get("args", []) as Array).size()
	for c: Variant in candidates:
		var name: String = String(c)
		if arities.has(name) and arities[name] == argc:
			return name
	return ""
