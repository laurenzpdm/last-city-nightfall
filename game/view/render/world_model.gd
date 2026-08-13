class_name LcnWorldModel
extends RefCounted
## Read-only view of the world for the renderer. [P13]
##
## This is the ONLY place that talks to the simulation. It never writes sim
## state, and every read is defensive: parts are built in parallel, so grid,
## heat, climate and build may each be absent, present-but-different, or arrive
## halfway through a session.
##
## OPTIONAL CONTRACT — a sim system that implements any of these gets richer
## rendering for free. Nothing breaks if it implements none of them.
##
##   grid    size() -> Vector2i                  world extent in tiles
##           terrain_at(Vector2i) -> int         terrain id
##           terrain_names() -> PackedStringArray  id -> name, for palette mapping
##           terrain_chunk(Vector2i, Vector2i) -> PackedByteArray   bulk read
##           snow_at(Vector2i) -> float          0..1 accumulation
##   climate day_fraction() -> float             0..1, 0 = midnight
##           phase() -> StringName               dawn / noon / dusk / night ...
##           temperature() -> float              ambient degrees C
##           storm_intensity() -> float          0..1
##   heat    temperature_at(Vector2i) -> float   local degrees C
##           heat_sources_for_view() -> Array[Dictionary]
##                                               {pos: Vector2, radius: float, intensity: float}
##   any     agents_for_view() -> Array[Dictionary]
##                                               {id: int, kind: StringName, pos: Vector2}
##
## Anything the sim does not provide is synthesised here so the art direction is
## always fully visible — see LcnPreviewWorld. `using_preview()` reports it and
## the renderer logs it, so a screenshot is never silently faked.

const TILE: int = 32
const CHUNK: int = 32

## Mirrors BuildTypes.State. Read as ints so this file never hard-depends on
## [P11]'s script; unknown values are treated as "finished and running".
const BUILD_GHOST: int = 0
const BUILD_CONSTRUCTING: int = 1
const BUILD_OPERATIONAL: int = 2
const BUILD_DISABLED: int = 3
const BUILD_FROZEN: int = 4
const BUILD_DECONSTRUCTING: int = 5

var preview: LcnPreviewWorld = null

var _grid: SimSystem = null
var _climate: SimSystem = null
var _heat: SimSystem = null
var _build: SimSystem = null
var _snow_cap: float = 1.0
var _phase_now: StringName = &""
var _phase_remaining: float = 0.0
var _phase_span: Dictionary[StringName, float] = {}
var _preview_dropped: bool = false

var _terrain_names: Dictionary[String, int] = {}
var _terrain_remap: Dictionary[int, int] = {}
var _remap_table: PackedByteArray = PackedByteArray()
var _has_bulk_terrain: bool = false
## [P01]'s WorldGrid, when the grid system exposes it. Chunks there hold terrain
## and snow as PackedByteArrays, which is the difference between reading a
## 65 536-tile map in one pass and calling terrain_at() 65 536 times.
var _world_grid: Object = null
var _snow_stamp: int = -1
var _building_stamp: int = 0
var _has_phase_clock: bool = false
var _has_heat_view: bool = false
var _agent_providers: Array[SimSystem] = []
## heat_sources() is asked for three times a frame by three different passes.
## Rebuilding it each time was the single biggest cost in the entity renderer.
var _sources_cache: Array[Dictionary] = []
var _sources_tick: int = -2

var _buildings: Dictionary[int, Dictionary] = {}
var _building_order: Array[int] = []
var _buildings_dirty: bool = true
var _cached_buildings: Array[Dictionary] = []

var _agents: Dictionary[int, Dictionary] = {}

var _terrain_cache: Dictionary[int, PackedByteArray] = {}
var _sprites: LcnSpriteFactory = null

## View-side accumulation clock, only used when nothing in the sim owns snow.
var _snow_phase: float = 0.35
var _last_tick: int = -1


func _init(sprites: LcnSpriteFactory) -> void:
	_sprites = sprites


## Binds to whatever exists right now. Safe to call again after world_ready.
func attach() -> void:
	_grid = Sim.get_system(&"grid")
	_climate = Sim.get_system(&"climate")
	_heat = Sim.get_system(&"heat")
	_build = Sim.get_system(&"build")
	_terrain_cache.clear()
	_terrain_remap.clear()
	_agent_providers.clear()
	_world_grid = null
	if _grid != null and _grid.has_method("world"):
		var wg: Variant = _grid.call("world")
		if wg is Object and (wg as Object).has_method("chunk_by_coord"):
			_world_grid = wg
	_has_bulk_terrain = _grid != null and _grid.has_method("terrain_chunk")
	_has_phase_clock = _climate != null and _climate.has_method("phase_of_day") \
		and _climate.has_method("phase_progress")
	_has_heat_view = _heat != null and _heat.has_method("heat_sources_for_view")
	_sources_tick = -1
	_sources_cache = []

	if _grid != null:
		var cap: Variant = _grid.get("snow_cap")
		_snow_cap = maxf(1.0, float(cap)) if typeof(cap) == TYPE_INT or typeof(cap) == TYPE_FLOAT else 1.0
		_map_terrain_ids()

	for s: SimSystem in Sim.systems:
		if s.has_method("agents_for_view"):
			_agent_providers.append(s)

	if _grid == null:
		if preview == null:
			preview = LcnPreviewWorld.new(Rng.seed_value)
			preview.generate()
		Log.info("render", "no grid system — rendering the preview world (%s)" % str(preview.size))
	else:
		Log.info("render", "bound to grid: %s tiles, snow_cap=%.0f, terrain ids mapped=%d" % [
			str(world_size()), _snow_cap, _terrain_remap.size(),
		])
	_sync_buildings_from_sim()


## Terrain ids are an ordered enum owned by [P01]. Read the id -> name table at
## runtime (never at parse time) so a rename there degrades to "everything is
## snow" instead of failing to compile this file.
func _map_terrain_ids() -> void:
	var names: PackedStringArray = PackedStringArray()
	if _grid.has_method("terrain_names"):
		names = _grid.call("terrain_names")
	if names.is_empty():
		var scr: Script = load("res://game/sim/grid/grid.gd")
		if scr != null:
			var consts: Dictionary = scr.get_script_constant_map()
			var raw: Variant = consts.get("TERRAIN_NAMES", null)
			if typeof(raw) == TYPE_ARRAY:
				for v: Variant in (raw as Array):
					names.append(str(v))
	for i: int in names.size():
		_terrain_remap[i] = _terrain_from_name(names[i])
	# Flat 256-entry lookup: the bulk terrain read hits this once per tile and a
	# Dictionary probe per tile is 65 536 hash lookups on a map load.
	_remap_table.resize(256)
	_remap_table.fill(LcnPalette.Terrain.SNOW)
	for i: int in mini(names.size(), 256):
		_remap_table[i] = _terrain_remap.get(i, LcnPalette.Terrain.SNOW)


## Adopts every building the build system already knows about. Bus signals cover
## everything placed after this point; this covers everything placed before.
func _sync_buildings_from_sim() -> void:
	if _build == null:
		return
	var data: Dictionary = _build.serialize()
	var list: Variant = data.get("buildings", [])
	if typeof(list) != TYPE_ARRAY:
		return
	var n: int = 0
	for e: Variant in (list as Array):
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = e
		var cell: Variant = d.get("cell", null)
		var c := Vector2i.ZERO
		if typeof(cell) == TYPE_ARRAY and (cell as Array).size() >= 2:
			c = Vector2i(int((cell as Array)[0]), int((cell as Array)[1]))
		elif typeof(cell) == TYPE_VECTOR2I:
			c = cell
		else:
			continue
		drop_preview_buildings()
		add_building(int(d.get("id", 0)), StringName(str(d.get("kind", ""))), c)
		set_building_state(int(d.get("id", 0)), int(d.get("state", 2)))
		n += 1
	if n > 0:
		Log.info("render", "adopted %d existing structures from the build system" % n)


static func _terrain_from_name(raw: String) -> int:
	var n: String = raw.to_lower()
	if n.contains("deep") and n.contains("snow"):
		return LcnPalette.Terrain.SNOW_DEEP
	if n.contains("snow") or n.contains("drift"):
		return LcnPalette.Terrain.SNOW
	if n.contains("ice") or n.contains("frost") or n.contains("glacier"):
		return LcnPalette.Terrain.ICE
	if n.contains("water") or n.contains("lake") or n.contains("sea") or n.contains("river"):
		return LcnPalette.Terrain.WATER_FROZEN
	if n.contains("rock") or n.contains("stone") or n.contains("cliff") or n.contains("mountain"):
		return LcnPalette.Terrain.ROCK
	if n.contains("gravel") or n.contains("scree") or n.contains("ore") or n.contains("coal"):
		return LcnPalette.Terrain.GRAVEL
	if n.contains("geo") or n.contains("thermal") or n.contains("vent") or n.contains("fumarole"):
		return LcnPalette.Terrain.ASH_FIELD
	if n.contains("ash") or n.contains("soot") or n.contains("burn"):
		return LcnPalette.Terrain.ASH_FIELD
	if n.contains("ridge") or n.contains("crag") or n.contains("boulder"):
		return LcnPalette.Terrain.ROCK
	if n.contains("chasm") or n.contains("crevasse") or n.contains("pit") or n.contains("void"):
		return LcnPalette.Terrain.WATER_FROZEN
	if n.contains("wreck") or n.contains("hulk"):
		return LcnPalette.Terrain.RUBBLE
	if n.contains("pav") or n.contains("road") or n.contains("floor") or n.contains("concrete"):
		return LcnPalette.Terrain.PAVED
	if n.contains("rubble") or n.contains("ruin") or n.contains("debris"):
		return LcnPalette.Terrain.RUBBLE
	return LcnPalette.Terrain.SNOW


func using_preview() -> bool:
	return _grid == null


# -------------------------------------------------------------------- world --

func world_size() -> Vector2i:
	if _grid != null:
		if _grid.has_method("map_size"):
			return _grid.call("map_size")
		if _grid.has_method("size"):
			return _grid.call("size")
		var v: Variant = _grid.get("size")
		if typeof(v) == TYPE_VECTOR2I:
			return v
		var w: Variant = _grid.get("width")
		var h: Variant = _grid.get("height")
		if typeof(w) == TYPE_INT and typeof(h) == TYPE_INT:
			return Vector2i(int(w), int(h))
	if preview != null:
		return preview.size
	return Vector2i(256, 256)


## True when [P01] hands out its chunk arrays, which lets the ground read the
## whole map in one pass instead of one call per tile.
func has_bulk_chunks() -> bool:
	return _world_grid != null


## Version counter of one 32x32 terrain chunk. Bumped by [P01] whenever anything
## in it changes; the ground uses it to skip untouched chunks entirely.
func terrain_chunk_version(chunk: Vector2i) -> int:
	if _world_grid == null:
		return 0
	var c: Object = _world_grid.call("chunk_by_coord", chunk.x, chunk.y)
	if c == null:
		return 0
	return int(c.get("version"))


## Raw snow bytes for one 32x32 chunk, row-major. Empty when the sim owns no
## snow, in which case the caller falls back to the view-side field.
func snow_chunk(origin: Vector2i) -> PackedByteArray:
	if _world_grid != null:
		var c: Object = _world_grid.call("chunk_by_coord", origin.x / CHUNK, origin.y / CHUNK)
		if c != null:
			var raw: Variant = c.get("snow")
			if raw is PackedByteArray and (raw as PackedByteArray).size() >= CHUNK * CHUNK:
				return raw
	return _synth_snow_chunk(origin)


## View-side snow for one chunk, used when nothing in the sim owns accumulation.
## Deliberately the same shape as the grid's: 0..255 against snow_cap.
func _synth_snow_chunk(origin: Vector2i) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(CHUNK * CHUNK)
	var terrain: PackedByteArray = terrain_chunk(origin)
	for y: int in CHUNK:
		for x: int in CHUNK:
			var i: int = y * CHUNK + x
			var cell := Vector2i(origin.x + x, origin.y + y)
			if not LcnPalette.terrain_takes_snow(int(terrain[i])):
				out[i] = 0
				continue
			var base: float = _snow_phase
			if int(terrain[i]) == LcnPalette.Terrain.PAVED:
				base *= 0.55
			var nz: float = LcnNoise.fbm(float(cell.x) * 0.055, float(cell.y) * 0.055, 4242, 3)
			out[i] = clampi(int(clampf(base * (0.45 + nz * 1.1), 0.0, 1.0) * 255.0), 0, 255)
	return out


func snow_cap() -> float:
	return _snow_cap


## Bumped whenever the set of structures changes. The ground's city-ambience
## field only rebuilds when this moves.
func building_stamp() -> int:
	return _building_stamp


## Terrain ids for a whole chunk, in row-major order. Cached; this is the call
## the ground makes and the reason 500x500 stays affordable.
func terrain_chunk(origin: Vector2i) -> PackedByteArray:
	var key: int = origin.x * 100003 + origin.y
	var hit: PackedByteArray = _terrain_cache.get(key, PackedByteArray())
	if not hit.is_empty():
		return hit
	var out := PackedByteArray()
	out.resize(CHUNK * CHUNK)
	if _world_grid != null and not _remap_table.is_empty():
		var c: Object = _world_grid.call("chunk_by_coord", origin.x / CHUNK, origin.y / CHUNK)
		if c != null:
			var raw2: Variant = c.get("terrain")
			if raw2 is PackedByteArray and (raw2 as PackedByteArray).size() >= CHUNK * CHUNK:
				var src: PackedByteArray = raw2
				for i: int in CHUNK * CHUNK:
					out[i] = _remap_table[src[i]]
				_terrain_cache[key] = out
				return out
	if _has_bulk_terrain:
		var raw: PackedByteArray = _grid.call("terrain_chunk", origin, Vector2i(CHUNK, CHUNK))
		if raw.size() >= CHUNK * CHUNK:
			for i: int in CHUNK * CHUNK:
				out[i] = _terrain_remap.get(int(raw[i]), LcnPalette.Terrain.SNOW)
			_terrain_cache[key] = out
			return out
	var bounds: Vector2i = world_size()
	for y: int in CHUNK:
		for x: int in CHUNK:
			var cell := Vector2i(origin.x + x, origin.y + y)
			var t: int = LcnPalette.Terrain.SNOW
			if cell.x >= 0 and cell.y >= 0 and cell.x < bounds.x and cell.y < bounds.y:
				t = _terrain_single(cell)
			out[y * CHUNK + x] = t
	_terrain_cache[key] = out
	return out


func _terrain_single(cell: Vector2i) -> int:
	if _grid != null:
		if _grid.has_method("terrain_at"):
			return _terrain_remap.get(int(_grid.call("terrain_at", cell)), LcnPalette.Terrain.SNOW)
		if _grid.has_method("get_terrain"):
			return _terrain_remap.get(int(_grid.call("get_terrain", cell)), LcnPalette.Terrain.SNOW)
	if preview != null:
		return preview.terrain_at(cell)
	return LcnPalette.Terrain.SNOW


func terrain_at(cell: Vector2i) -> int:
	var origin := Vector2i(
		int(floor(float(cell.x) / float(CHUNK))) * CHUNK,
		int(floor(float(cell.y) / float(CHUNK))) * CHUNK)
	var data: PackedByteArray = terrain_chunk(origin)
	return int(data[(cell.y - origin.y) * CHUNK + (cell.x - origin.x)])


# --------------------------------------------------------------- atmosphere --

## Where each named climate phase sits on the palette's 0..1 day loop.
## [P09] owns six phases; the palette owns nine colour keyframes. This table is
## the join between them, and it is the reason dawn looks like dawn and not like
## "somewhere in the first third of the day".
const PHASE_ARC: Dictionary[StringName, Vector2] = {
	&"dawn": Vector2(0.235, 0.335),
	&"morning": Vector2(0.335, 0.500),
	&"afternoon": Vector2(0.500, 0.700),
	&"dusk": Vector2(0.700, 0.800),
	&"night": Vector2(0.800, 0.920),
	&"deep_night": Vector2(0.920, 1.235),
}


## Normalised time of day. 0 = midnight, 0.25 dawn, 0.5 noon, 0.75 dusk.
##
## [P09] owns six named phases; the palette owns nine colour keyframes on a 0..1
## loop. PHASE_ARC is the join, and phase_progress() is what places us inside the
## current arc. Both names are part of the climate contract, so this is a real
## handshake and not a guess.
func day_fraction() -> float:
	if _has_phase_clock:
		var ph: StringName = StringName(str(_climate.call("phase_of_day")))
		if PHASE_ARC.has(ph):
			var arc: Vector2 = PHASE_ARC[ph]
			var within: float = clampf(float(_climate.call("phase_progress")), 0.0, 1.0)
			return fposmod(lerpf(arc.x, arc.y, within), 1.0)
	if _climate != null:
		for m: String in ["day_fraction", "time_of_day", "day_t", "normalized_time"]:
			if _climate.has_method(m):
				return fposmod(float(_climate.call(m)), 1.0)
		if PHASE_ARC.has(_phase_now):
			var arc2: Vector2 = PHASE_ARC[_phase_now]
			var span: float = maxf(0.001, _phase_span.get(_phase_now, 1.0))
			var within2: float = clampf(1.0 - _phase_remaining / span, 0.0, 1.0)
			return fposmod(lerpf(arc2.x, arc2.y, within2), 1.0)
		var s: Dictionary = _climate.serialize()
		for k: String in ["day_fraction", "time_of_day", "day_t", "phase_t"]:
			if s.has(k):
				return fposmod(float(s[k]), 1.0)
	# No climate yet: run a brisk view-side cycle so the whole grade is visible
	# inside a short harness run instead of sitting on one lighting state.
	return fposmod(0.22 + SimClock.seconds() / 40.0, 1.0)


func phase() -> StringName:
	if _phase_now != &"":
		return _phase_now
	return LcnPalette.phase_at(day_fraction())


## Samples the climate phase clock. Called every tick so the in-phase fraction
## stays accurate even in a harness run that only renders a handful of frames.
func _sample_phase() -> void:
	if _climate == null or not _climate.has_method("phase_of_day"):
		return
	_phase_now = StringName(str(_climate.call("phase_of_day")))
	if _climate.has_method("seconds_until_phase_change"):
		_phase_remaining = maxf(0.0, float(_climate.call("seconds_until_phase_change")))
		# The longest remaining time ever seen inside a phase is its duration.
		if _phase_remaining > _phase_span.get(_phase_now, 0.0):
			_phase_span[_phase_now] = _phase_remaining


## Ambient air temperature in degrees C.
func ambient_temperature() -> float:
	if _climate != null:
		for m: String in ["ambient_temperature", "temperature", "air_temperature"]:
			if _climate.has_method(m):
				return float(_climate.call(m))
		var s: Dictionary = _climate.serialize()
		for k: String in ["temperature", "ambient", "air_temp"]:
			if s.has(k):
				return float(s[k])
	# Cold nights, merely freezing days.
	var d: float = day_fraction()
	return lerpf(-48.0, -12.0, clampf(sin(d * TAU - PI * 0.5) * 0.5 + 0.5, 0.0, 1.0))


func storm() -> float:
	if _climate != null:
		for m: String in ["storm_intensity", "storm", "blizzard"]:
			if _climate.has_method(m):
				return clampf(float(_climate.call(m)), 0.0, 1.0)
		if _climate.has_method("weather_intensity"):
			return clampf(float(_climate.call("weather_intensity")), 0.0, 1.0)
	return 0.0


## Temperature at a tile, taking every heat source into account. Drives the ice
## overlay, the cold chromatic shift and the warm rim on buildings.
func temperature_at(cell: Vector2i) -> float:
	if _heat != null and _heat.has_method("temperature_at"):
		return float(_heat.call("temperature_at", cell))
	var pos := Vector2(float(cell.x) * TILE + 16.0, float(cell.y) * TILE + 16.0)
	var t: float = ambient_temperature()
	for src: Dictionary in heat_sources():
		var d: float = (src["pos"] as Vector2).distance_to(pos)
		var r: float = float(src["radius"])
		if d > r:
			continue
		var f: float = 1.0 - d / r
		t += 70.0 * float(src["intensity"]) * f * f
	return t


## 0..1 snow depth on a tile. Real data if the grid owns it, otherwise a
## view-side field that thins near heat and thickens overnight.
func snow_at(cell: Vector2i) -> float:
	if _grid != null and _grid.has_method("snow_at"):
		return clampf(float(_grid.call("snow_at", cell)) / _snow_cap, 0.0, 1.0)
	var terrain: int = terrain_at(cell)
	if not LcnPalette.terrain_takes_snow(terrain):
		return 0.0
	var base: float = _snow_phase
	if terrain == LcnPalette.Terrain.PAVED:
		base *= 0.55
	var n: float = LcnNoise.fbm(float(cell.x) * 0.055, float(cell.y) * 0.055, 4242, 3)
	var depth: float = clampf(base * (0.45 + n * 1.1), 0.0, 1.0)
	# Melt-back around anything hot. This is the readability payoff: warm places
	# are visibly bare, cold places are visibly buried.
	var pos := Vector2(float(cell.x) * TILE + 16.0, float(cell.y) * TILE + 16.0)
	for src: Dictionary in heat_sources():
		var d: float = (src["pos"] as Vector2).distance_to(pos)
		var r: float = float(src["radius"]) * 0.85
		if d < r:
			depth *= clampf(d / r, 0.0, 1.0)
	return depth


## Bulk fill of the three per-tile overlay fields for one chunk.
##
## Doing this per chunk instead of per tile is what keeps the ground layer
## affordable: heat sources and sooty buildings are filtered against the chunk
## bounds once, so the inner loop only touches the handful that can reach it.
func fill_overlay_fields(origin: Vector2i, n: int, out_snow: PackedFloat32Array,
		out_soot: PackedFloat32Array, out_temp: PackedFloat32Array) -> void:
	var rect := Rect2(Vector2(origin) * float(TILE), Vector2(float(n), float(n)) * float(TILE))
	var srcs: Array[Dictionary] = []
	for s: Dictionary in heat_sources():
		var r: float = float(s["radius"])
		if rect.grow(r).has_point(s["pos"]):
			srcs.append(s)
	var soots: Array[Dictionary] = []
	for b: Dictionary in buildings():
		var sr: float = float(b.get("soot_radius", 0.0))
		if sr > 0.0 and float(b.get("soot", 0.0)) > 0.0 and rect.grow(sr).has_point(b["centre"]):
			soots.append(b)

	var grid_snow: bool = _grid != null and _grid.has_method("snow_at")
	var heat_temp: bool = _heat != null and _heat.has_method("temperature_at")
	var ambient: float = ambient_temperature()

	for y: int in n:
		for x: int in n:
			var cell := Vector2i(origin.x + x, origin.y + y)
			var pos := Vector2(float(cell.x) * TILE + 16.0, float(cell.y) * TILE + 16.0)
			var i: int = y * n + x

			var temp: float = ambient
			if heat_temp:
				temp = float(_heat.call("temperature_at", cell))
			else:
				for s2: Dictionary in srcs:
					var d: float = (s2["pos"] as Vector2).distance_to(pos)
					var r2: float = float(s2["radius"])
					if d < r2:
						var f: float = 1.0 - d / r2
						temp += 70.0 * float(s2["intensity"]) * f * f
			out_temp[i] = temp

			var terrain: int = terrain_at(cell)
			var snow: float = 0.0
			if grid_snow:
				snow = clampf(float(_grid.call("snow_at", cell)) / _snow_cap, 0.0, 1.0)
			elif LcnPalette.terrain_takes_snow(terrain):
				var base: float = _snow_phase
				if terrain == LcnPalette.Terrain.PAVED:
					base *= 0.55
				var nz: float = LcnNoise.fbm(float(cell.x) * 0.055, float(cell.y) * 0.055, 4242, 3)
				snow = clampf(base * (0.45 + nz * 1.1), 0.0, 1.0)
				for s3: Dictionary in srcs:
					var d2: float = (s3["pos"] as Vector2).distance_to(pos)
					var r3: float = float(s3["radius"]) * 0.85
					if d2 < r3:
						snow *= clampf(d2 / r3, 0.0, 1.0)
			out_snow[i] = snow

			var soot: float = 0.0
			for b2: Dictionary in soots:
				var d3: float = (b2["centre"] as Vector2).distance_to(pos)
				var r4: float = float(b2["soot_radius"])
				if d3 < r4:
					var f2: float = 1.0 - d3 / r4
					soot += float(b2["soot"]) * f2 * f2
			out_soot[i] = clampf(soot, 0.0, 1.0)


## 0..1 industrial soot on a tile, derived from nearby industry.
func soot_at(cell: Vector2i) -> float:
	var pos := Vector2(float(cell.x) * TILE + 16.0, float(cell.y) * TILE + 16.0)
	var acc: float = 0.0
	for b: Dictionary in buildings():
		var w: float = float(b.get("soot", 0.0))
		if w <= 0.0:
			continue
		var d: float = (b["centre"] as Vector2).distance_to(pos)
		var r: float = float(b.get("soot_radius", 96.0))
		if d < r:
			var f: float = 1.0 - d / r
			acc += w * f * f
	return clampf(acc, 0.0, 1.0)


# ---------------------------------------------------------------- buildings --

## Every building the renderer knows about, sorted back-to-front.
## Keys: id, kind, arch, cell, tiles, centre, state, warm, soot, soot_radius.
func buildings() -> Array[Dictionary]:
	if not _buildings_dirty:
		return _cached_buildings
	# Native sort on a packed key array. `sort_custom` with a GDScript lambda was
	# ~1600 script calls per rebuild at 200 structures and showed up as a
	# millisecond of frame time every time a building changed state.
	var keys := PackedInt64Array()
	keys.resize(_building_order.size())
	for i: int in _building_order.size():
		var id: int = _building_order[i]
		var b: Dictionary = _buildings[id]
		var y: int = (b["cell"] as Vector2i).y + (b["tiles"] as Vector2i).y
		keys[i] = (int(y + 4096) << 32) | (id & 0xFFFFFFFF)
	keys.sort()
	_building_order.clear()
	_cached_buildings = []
	for k: int in keys:
		var id2: int = k & 0xFFFFFFFF
		_building_order.append(id2)
		_cached_buildings.append(_buildings[id2])
	_buildings_dirty = false
	return _cached_buildings


## Called by the renderer on Bus.building_placed, and by the preview world.
##
## The sprite archetype supplies the *shape*; the building definition supplies
## the *size* and the *heat*. A 5x5 hearth and a 3x2 coal generator therefore
## both draw as a generator, at their real footprints and with light output
## proportional to what they actually burn.
func add_building(id: int, kind: StringName, cell: Vector2i) -> void:
	var arch: StringName = LcnSpriteFactory.archetype_for(kind)
	var sp: Dictionary = _sprites.building(arch)
	var arch_tiles: Vector2i = sp["tiles"]
	var tiles: Vector2i = arch_tiles
	var heat_produced: float = 0.0
	var heat_radius_tiles: float = 0.0
	var def: Resource = _def_for(kind)
	if def != null:
		var sz: Variant = def.get("size")
		if typeof(sz) == TYPE_VECTOR2I and (sz as Vector2i).x > 0:
			tiles = sz
		heat_produced = float(def.get("heat_produced") if def.get("heat_produced") != null else 0.0)
		heat_radius_tiles = float(def.get("heat_radius") if def.get("heat_radius") != null else 0.0)

	var scale: float = float(tiles.x) / float(maxi(1, arch_tiles.x))
	var industrial: bool = arch in [&"foundry", &"heat_plant", &"generator", &"mine", &"workshop"]
	# Heat output is the honest source of warmth. Buildings that make none still
	# show a little window light if their archetype is a place people live.
	var warm: float = float(sp["warm"]) * 0.35
	if heat_produced > 0.0:
		warm = clampf(0.30 + heat_produced / 90.0, 0.0, 1.0)
	var radius: float = float(sp["light_radius"]) * scale
	if heat_radius_tiles > 0.0:
		radius = maxf(radius, heat_radius_tiles * float(TILE) * 1.35)

	_buildings[id] = {
		"id": id,
		"kind": kind,
		"arch": arch,
		"cell": cell,
		"tiles": tiles,
		"scale": scale,
		"centre": Vector2(float(cell.x) + float(tiles.x) * 0.5, float(cell.y) + float(tiles.y) * 0.5) * float(TILE),
		"state": BUILD_OPERATIONAL,
		"warm": warm,
		"base_warm": warm,
		"radius": radius,
		# Soot is a halo on the ground AROUND a chimney, not a blanket over the
		# district. Radius scaled to ~1.5 footprints and weight kept low enough
		# that a cluster of eight furnaces reads as grime, not as a crater.
		"soot": (0.34 + warm * 0.22) if industrial else 0.0,
		"soot_radius": float(maxi(tiles.x, tiles.y)) * TILE * (1.5 if industrial else 0.0),
		"seed": id * 2654435761 & 0xFFFF,
	}
	if not _building_order.has(id):
		_building_order.append(id)
	_buildings_dirty = true
	_building_stamp += 1


## BuildingDef for a kind, straight from the registry so this works whether or
## not the build system happens to be present.
func _def_for(kind: StringName) -> Resource:
	if _build != null and _build.has_method("def_of"):
		var d: Resource = _build.call("def_of", kind)
		if d != null:
			return d
	return Registry.get_item("buildings", kind)


## Removes the placeholder settlement the moment real construction shows up.
func drop_preview_buildings() -> void:
	if _preview_dropped:
		return
	_preview_dropped = true
	if preview == null:
		return
	var removed: int = 0
	for b: Dictionary in preview.buildings:
		var id: int = int(b["id"])
		if _buildings.has(id):
			_buildings.erase(id)
			_building_order.erase(id)
			removed += 1
	preview.buildings.clear()
	_agents.clear()
	_buildings_dirty = true
	_building_stamp += 1
	if removed > 0:
		Log.info("render", "real construction detected — dropped %d preview structures" % removed)


func remove_building(id: int) -> void:
	if not _buildings.has(id):
		return
	_buildings.erase(id)
	_building_order.erase(id)
	_buildings_dirty = true
	_building_stamp += 1


func set_building_state(id: int, state: int) -> void:
	if not _buildings.has(id):
		return
	var b: Dictionary = _buildings[id]
	b["state"] = state
	_buildings_dirty = true


func building_count() -> int:
	return _buildings.size()


## Warm light emitters. Real heat data when [P02] exposes it, otherwise derived
## from which buildings are hot enough to glow.
func heat_sources() -> Array[Dictionary]:
	if _sources_tick == _last_tick and not _buildings_dirty:
		return _sources_cache
	_sources_cache = _build_heat_sources()
	_sources_tick = _last_tick
	return _sources_cache


func _build_heat_sources() -> Array[Dictionary]:
	if _has_heat_view:
		var raw: Array = _heat.call("heat_sources_for_view")
		var out: Array[Dictionary] = []
		for e: Variant in raw:
			if typeof(e) == TYPE_DICTIONARY:
				out.append(e)
		# An empty answer is meaningful once the sim owns heat — nothing is lit.
		# But before any heat building is finished, fall through to the archetype
		# glow so a fresh world is not a black rectangle.
		if not out.is_empty():
			return out
	var derived: Array[Dictionary] = []
	var live: bool = _heat != null and _heat.has_method("power_factor") and _has_heat_view
	for b: Dictionary in buildings():
		var w: float = float(b["warm"])
		var state: int = int(b["state"])
		if state == BUILD_GHOST or state == BUILD_CONSTRUCTING:
			continue
		if state == BUILD_FROZEN or state == BUILD_DISABLED:
			w *= 0.12
		elif live and _heat.call("has_building", int(b["id"])):
			# A starved network visibly dims its own city. This is the single
			# most useful readability signal the renderer has. It is only applied
			# to buildings the heat system actually owns — asking it about a wall
			# used to return 0.0 and quietly extinguish the entire map.
			w *= clampf(0.35 + float(_heat.call("power_factor", int(b["id"]))) * 0.75, 0.0, 1.2)
		if w < 0.10:
			continue
		var sp: Dictionary = _sprites.building(b["arch"])
		derived.append({
			"pos": (b["centre"] as Vector2) + Vector2(0.0, -float(sp["lift"]) * float(b["scale"]) * 0.35),
			"radius": float(b["radius"]),
			"intensity": w,
			"seed": int(b["seed"]),
		})
	return derived


# ------------------------------------------------------------------- agents --

## Interpolated agent positions. Keys: id, kind, pos, facing.
func agents(alpha: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var keys: Array = _agents.keys()
	keys.sort()
	for id: int in keys:
		var a: Dictionary = _agents[id]
		var prev: Vector2 = a["prev"]
		var cur: Vector2 = a["cur"]
		var p: Vector2 = prev.lerp(cur, clampf(alpha, 0.0, 1.0))
		out.append({"id": id, "kind": a["kind"], "pos": p, "facing": signf((cur - prev).x)})
	return out


func agent_count() -> int:
	return _agents.size()


func set_agent(id: int, kind: StringName, pos: Vector2) -> void:
	var a: Dictionary = _agents.get(id, {})
	if a.is_empty():
		_agents[id] = {"kind": kind, "prev": pos, "cur": pos}
		return
	a["kind"] = kind
	a["prev"] = a["cur"]
	a["cur"] = pos


func remove_agent(id: int) -> void:
	_agents.erase(id)


## Pulls one tick of movement. Called from Bus.tick_advanced.
func advance(tick: int) -> void:
	if tick == _last_tick:
		return
	_last_tick = tick
	_sample_phase()

	# Snow builds overnight and in storms, and backs off through the day.
	var d: float = day_fraction()
	var night: float = clampf(1.0 - sin(d * TAU - PI * 0.5) * 0.5 - 0.5, 0.0, 1.0)
	var rate: float = lerpf(-0.00035, 0.00075, night) + storm() * 0.0022
	_snow_phase = clampf(_snow_phase + rate, 0.08, 1.0)

	if not _agent_providers.is_empty():
		var seen: Dictionary[int, bool] = {}
		for s: SimSystem in _agent_providers:
			var raw: Array = s.call("agents_for_view")
			for e: Variant in raw:
				if typeof(e) != TYPE_DICTIONARY:
					continue
				var d2: Dictionary = e
				var id: int = int(d2.get("id", -1))
				if id < 0:
					continue
				seen[id] = true
				set_agent(id, StringName(str(d2.get("kind", &"citizen"))), d2.get("pos", Vector2.ZERO))
		for id2: int in _agents.keys():
			if not seen.has(id2):
				_agents.erase(id2)
		return

	if preview != null:
		preview.step_agents(tick)
		for a: Dictionary in preview.agents:
			set_agent(int(a["id"]), a["kind"], a["pos"])


## Builds and adopts the placeholder settlement. Only ever called when the
## simulation has produced no structures of its own; the first real
## Bus.building_placed wipes it (see drop_preview_buildings).
func ensure_preview_settlement(core: Vector2i) -> void:
	if _preview_dropped or not _buildings.is_empty():
		return
	if preview == null:
		preview = LcnPreviewWorld.new(Rng.seed_value, world_size(), core)
		preview.generate()
	elif preview.buildings.is_empty():
		preview.generate()
	for b: Dictionary in preview.buildings:
		add_building(int(b["id"]), b["kind"], b["cell"])
	Log.warn("render", "no structures in the simulation — showing the [P13] preview settlement (%d placeholders around %s). Any real construction replaces it." % [
		_buildings.size(), str(preview.centre),
	])


func showing_preview_settlement() -> bool:
	return preview != null and not preview.buildings.is_empty()
