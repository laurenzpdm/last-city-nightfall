class_name LcnTerrainRenderer
extends Node2D
## Chunk-streaming ground renderer. [P13]
##
## Three TileMapLayers — base terrain, snow accumulation, decals (ice fracture /
## industrial soot / trodden path). TileMapLayer batches and culls internally, so
## the whole ground is a handful of draw calls no matter how big the map is, and
## there is never a Node2D per tile.
##
## Only chunks inside the padded view rect are resident. On a 500x500 world that
## is roughly 24 chunks (~25k tiles) instead of 250k, and panning costs one or
## two chunk loads per frame. `stats()` reports the real numbers and the renderer
## logs them, so the performance claim is measured rather than asserted.

const CHUNK: int = 32
const TILE: int = 32
## Extra chunks kept resident around the view so panning never shows a gap.
const MARGIN_CHUNKS: int = 1
const UNLOAD_SLACK: int = 2
## Reload a chunk once the world's snow depth has drifted this far from the
## value it was baked with.
const SNOW_REBAKE_EPS: float = 0.07

var model: LcnWorldModel = null

var base_layer: TileMapLayer = null
var snow_layer: TileMapLayer = null
var decal_layer: TileMapLayer = null

var atlas: LcnTerrainAtlas = null

var _loaded: Dictionary[Vector2i, float] = {}
var _last_load_ms: float = 0.0
var _total_load_ms: float = 0.0
var _chunks_loaded: int = 0
var _cells_written: int = 0


func setup(world_model: LcnWorldModel) -> void:
	model = world_model
	atlas = LcnTerrainAtlas.new()
	atlas.build()

	base_layer = _make_layer("Base", -100)
	snow_layer = _make_layer("Snow", -98)
	decal_layer = _make_layer("Decals", -96)
	# Slightly translucent decals keep soot and cracks from reading as stickers.
	decal_layer.modulate = Color(1, 1, 1, 0.92)


func _make_layer(layer_name: String, z: int) -> TileMapLayer:
	var l := TileMapLayer.new()
	l.name = layer_name
	l.tile_set = atlas.tile_set
	l.z_index = z
	l.z_as_relative = false
	# Linear filtering with a padded atlas: smooth when zoomed out, no bleeding.
	l.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	add_child(l)
	return l


# ------------------------------------------------------------------ streaming --

## Keeps the chunks covering `view` resident. `budget` caps loads per call so a
## camera jump costs a couple of frames instead of one long hitch; pass a large
## budget (or -1) when a frame must be complete, e.g. before a screenshot.
func stream(view: Rect2, budget: int = 4) -> void:
	if model == null:
		return
	var span: float = float(CHUNK * TILE)
	var c0 := Vector2i(
		int(floor(view.position.x / span)) - MARGIN_CHUNKS,
		int(floor(view.position.y / span)) - MARGIN_CHUNKS)
	var c1 := Vector2i(
		int(floor(view.end.x / span)) + MARGIN_CHUNKS,
		int(floor(view.end.y / span)) + MARGIN_CHUNKS)

	var world: Vector2i = model.world_size()
	var max_c := Vector2i(
		int(ceil(float(world.x) / float(CHUNK))) - 1,
		int(ceil(float(world.y) / float(CHUNK))) - 1)
	c0.x = maxi(c0.x, 0)
	c0.y = maxi(c0.y, 0)
	c1.x = mini(c1.x, max_c.x)
	c1.y = mini(c1.y, max_c.y)

	var snow_now: float = _world_snow_phase()
	var left: int = budget if budget >= 0 else 1 << 30
	var t0: int = Time.get_ticks_usec()
	for cy: int in range(c0.y, c1.y + 1):
		for cx: int in range(c0.x, c1.x + 1):
			if left <= 0:
				break
			var key := Vector2i(cx, cy)
			var baked: float = _loaded.get(key, -1.0)
			if baked >= 0.0 and absf(baked - snow_now) < SNOW_REBAKE_EPS:
				continue
			_load_chunk(key, snow_now)
			left -= 1
	_last_load_ms = float(Time.get_ticks_usec() - t0) / 1000.0
	_total_load_ms += _last_load_ms

	# Drop chunks well outside the view so memory does not creep on a big map.
	var keep := Rect2i(
		c0 - Vector2i(UNLOAD_SLACK, UNLOAD_SLACK),
		(c1 - c0) + Vector2i(1 + UNLOAD_SLACK * 2, 1 + UNLOAD_SLACK * 2))
	for key2: Vector2i in _loaded.keys():
		if not keep.has_point(key2):
			_unload_chunk(key2)


func _world_snow_phase() -> float:
	# One representative sample is enough to notice the field has drifted.
	return model.snow_at(model.world_size() / 2)


func _load_chunk(chunk: Vector2i, snow_now: float) -> void:
	var origin := chunk * CHUNK
	var terrain: PackedByteArray = model.terrain_chunk(origin)
	var n: int = CHUNK * CHUNK
	var snow := PackedFloat32Array()
	var soot := PackedFloat32Array()
	var temp := PackedFloat32Array()
	snow.resize(n)
	soot.resize(n)
	temp.resize(n)
	model.fill_overlay_fields(origin, CHUNK, snow, soot, temp)

	for y: int in CHUNK:
		for x: int in CHUNK:
			var i: int = y * CHUNK + x
			var cell := Vector2i(origin.x + x, origin.y + y)
			var kind: int = int(terrain[i])
			var variant: int = int(LcnNoise.hash3(cell.x, cell.y, 1234) * 4.0) & 3
			base_layer.set_cell(cell, atlas.source_id, LcnTerrainAtlas.base_coords(kind, variant), 0)

			var depth: float = snow[i]
			if depth > 0.12:
				var level: int = 1 if depth < 0.42 else (2 if depth < 0.74 else 3)
				snow_layer.set_cell(cell, atlas.source_id,
					LcnTerrainAtlas.snow_coords(level, variant + 1), 0)
			else:
				snow_layer.erase_cell(cell)

			# Priority: soot beats frost beats footpath. Only one decal per tile,
			# because two stacked overlays turn the ground to mud.
			var s: float = soot[i]
			var t: float = temp[i]
			if s > 0.18:
				# Proportional, not binary. The old `if s > 0.22 -> full strength`
				# stamp meant any cluster of industry read as one solid black disc
				# with the roads, walls and citizens inside it invisible.
				var soot_level: int = 1 if s < 0.42 else (2 if s < 0.72 else 3)
				decal_layer.set_cell(cell, atlas.source_id,
					LcnTerrainAtlas.soot_coords(soot_level, variant + 2), 0)
			elif t < -34.0 and (kind == LcnPalette.Terrain.ICE
					or kind == LcnPalette.Terrain.WATER_FROZEN
					or kind == LcnPalette.Terrain.ROCK):
				decal_layer.set_cell(cell, atlas.source_id,
					LcnTerrainAtlas.crack_coords(variant + 3), 0)
			elif kind == LcnPalette.Terrain.PAVED and depth < 0.35:
				decal_layer.set_cell(cell, atlas.source_id,
					LcnTerrainAtlas.path_coords(variant), 0)
			else:
				decal_layer.erase_cell(cell)

	_loaded[chunk] = snow_now
	_chunks_loaded += 1
	_cells_written += n


func _unload_chunk(chunk: Vector2i) -> void:
	var origin := chunk * CHUNK
	for y: int in CHUNK:
		for x: int in CHUNK:
			var cell := Vector2i(origin.x + x, origin.y + y)
			base_layer.erase_cell(cell)
			snow_layer.erase_cell(cell)
			decal_layer.erase_cell(cell)
	_loaded.erase(chunk)


## Drops every resident chunk. Used when the world is recreated.
func clear_all() -> void:
	base_layer.clear()
	snow_layer.clear()
	decal_layer.clear()
	_loaded.clear()


# ---------------------------------------------------------------- diagnostics --

func stats() -> Dictionary:
	return {
		"resident_chunks": _loaded.size(),
		"resident_cells": _loaded.size() * CHUNK * CHUNK,
		"last_load_ms": _last_load_ms,
		"total_load_ms": _total_load_ms,
		"chunks_loaded": _chunks_loaded,
		"cells_written": _cells_written,
	}


## Streams the entire world once and reports the cost, then restores the normal
## resident set. This is the honest answer to "is it fast at 500x500?" —
## it is the real code path, not an estimate.
func benchmark_full_map(view: Rect2) -> Dictionary:
	var world: Vector2i = model.world_size()
	var cw: int = int(ceil(float(world.x) / float(CHUNK)))
	var ch: int = int(ceil(float(world.y) / float(CHUNK)))
	clear_all()
	var snow_now: float = _world_snow_phase()
	var t0: int = Time.get_ticks_usec()
	for cy: int in ch:
		for cx: int in cw:
			_load_chunk(Vector2i(cx, cy), snow_now)
	var total_ms: float = float(Time.get_ticks_usec() - t0) / 1000.0
	var cells: int = cw * ch * CHUNK * CHUNK
	var out: Dictionary = {
		"world": "%dx%d" % [world.x, world.y],
		"chunks": cw * ch,
		"cells": cells,
		"total_ms": total_ms,
		"ms_per_chunk": total_ms / float(maxi(1, cw * ch)),
		"us_per_cell": total_ms * 1000.0 / float(maxi(1, cells)),
	}
	clear_all()
	stream(view, -1)
	out["resident_chunks_after"] = _loaded.size()
	out["resident_cells_after"] = _loaded.size() * CHUNK * CHUNK
	return out
