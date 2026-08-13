class_name LcnTerrainRenderer
extends Node2D
## The ground, as one shaded quad. [P13], second pass.
##
## WHAT CHANGED AND WHY. The first pass streamed 32x32 chunks of baked 32px tiles
## into three TileMapLayers. A critic looking at the actual frames named the two
## things that produced: the snow read as a mosaic of four repeating tile images,
## and the map was cut by hard chunk-aligned seams, because snow depth was baked
## INTO a tile at the moment its chunk happened to load and neighbouring chunks
## had loaded at different points in the snowfall.
##
## Both defects are structural, so the structure went. There is now exactly one
## draw call for the entire ground: a quad over the visible rect with
## `terrain.gdshader` on it, fed by LcnTerrainField's data textures. There is no
## tile image to repeat and no chunk to seam, and the surface is generated at the
## pixel the camera is looking at, so it holds up at every zoom.
##
## It is also very much cheaper. The old path rebaked up to 30 chunks in a frame
## whenever the world's snow drifted past a threshold, at ~3 ms per chunk; see
## `stats()` and the PERF lines in the log for the measured numbers.

const CHUNK: int = 32
const TILE: int = 32
const SHADER_PATH: String = "res://game/view/render/terrain.gdshader"
## How much world beyond the camera the quad covers, so a fast pan never shows
## an unshaded edge for a frame.
const OVERSCAN: float = 96.0
## Snow chunks refreshed per frame. Snow moves at a few depth units per second;
## a full sweep of a 256x256 map at this budget takes about a quarter of a second
## and costs ~0.05 ms a frame.
const SNOW_BUDGET: int = 3

var model: LcnWorldModel = null
var field: LcnTerrainField = null
var ground_material: ShaderMaterial = null

var _quad: Node2D = null
var _white: ImageTexture = null
var _rect: Rect2 = Rect2()
var _detail: float = 1.0
var _pending_chunks: Array[Vector2i] = []
var _source_cooldown: int = 0
var _city_cooldown: int = 0
var _buildings_stamp: int = -1
var _ready_ok: bool = false

var _update_us: int = 0
var _frames: int = 0


## Inner node whose only job is to own the shader material and one _draw().
class Quad extends Node2D:
	var host: LcnTerrainRenderer = null

	func _draw() -> void:
		if host != null:
			host.draw_ground(self)


func setup(world_model: LcnWorldModel) -> void:
	model = world_model
	field = LcnTerrainField.new()

	var shader: Shader = load(SHADER_PATH) as Shader
	if shader == null:
		Log.error("render", "ground shader missing at %s — the world will not draw" % SHADER_PATH)
		return
	ground_material = ShaderMaterial.new()
	ground_material.shader = shader

	var img: Image = Image.create(1, 1, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 1, 1, 1))
	_white = ImageTexture.create_from_image(img)

	_quad = Quad.new()
	(_quad as Quad).host = self
	_quad.name = "Ground"
	_quad.z_index = -100
	_quad.z_as_relative = false
	_quad.material = ground_material
	_quad.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	add_child(_quad)
	_ready_ok = true


## Binds the field to the world's actual size. Safe to call again on world reload.
func bind_world() -> void:
	if not _ready_ok or model == null:
		return
	field.setup(model.world_size(), model.snow_cap())
	ground_material.set_shader_parameter("kind_tex", field.kind_tex)
	ground_material.set_shader_parameter("snow_tex", field.snow_tex)
	ground_material.set_shader_parameter("heat_tex", field.heat_tex)
	ground_material.set_shader_parameter("soot_tex", field.soot_tex)
	ground_material.set_shader_parameter("city_tex", field.city_tex)
	ground_material.set_shader_parameter("noise_tex", field.noise_tex)
	ground_material.set_shader_parameter("pal_tex", field.palette_tex)
	ground_material.set_shader_parameter("map_px", Vector2(field.size) * float(TILE))
	ground_material.set_shader_parameter("snow_scale", field.snow_scale)
	ground_material.set_shader_parameter("snow_mid", _v3(LcnPalette.SNOW_MID))
	ground_material.set_shader_parameter("snow_lit", _v3(LcnPalette.SNOW_LIT))
	ground_material.set_shader_parameter("snow_shadow", _v3(LcnPalette.SNOW_SHADOW))
	ground_material.set_shader_parameter("ash_col", _v3(LcnPalette.ASH))
	ground_material.set_shader_parameter("warm_col", _v3(LcnPalette.WARM_EDGE))
	_buildings_stamp = -1
	_source_cooldown = 0
	_city_cooldown = 0
	var n: int = field.refresh_kind(model)
	field.refresh_snow(model, 1 << 20, [])
	Log.info("render", "ground bound: %s tiles, %d terrain chunks read, field %d KB" % [
		str(field.size), n, int(field.stats()["bytes"]) / 1024])


## Per-frame update. `zoom` is the camera's scale (>1 is zoomed in), used to drop
## detail the player cannot see anyway.
func render(view: Rect2, grade: Dictionary, zoom: float, full: bool = false) -> void:
	if not _ready_ok or model == null or field.size == Vector2i.ZERO:
		return
	var t0: int = Time.get_ticks_usec()
	_frames += 1
	_rect = view.grow(OVERSCAN)
	_detail = clampf(inverse_lerp(0.28, 0.85, zoom), 0.0, 1.0)

	if _frames % 240 == 1 or full:
		field.refresh_kind(model)
	field.refresh_snow(model, (1 << 20) if full else SNOW_BUDGET, _pending_chunks)
	_pending_chunks.clear()

	_source_cooldown -= 1
	if _source_cooldown <= 0 or full:
		_source_cooldown = 6
		field.refresh_sources(model.heat_sources(), model.buildings())

	var stamp: int = model.building_stamp()
	_city_cooldown -= 1
	if (stamp != _buildings_stamp and _city_cooldown <= 0) or full:
		_buildings_stamp = stamp
		_city_cooldown = 20
		field.refresh_city(model.buildings())

	ground_material.set_shader_parameter("detail", _detail)
	ground_material.set_shader_parameter("time_s", SimClock.seconds())
	ground_material.set_shader_parameter("sun_dir", grade["sun_dir"])
	ground_material.set_shader_parameter("sun_col", _v3(grade["sun_col"]))
	ground_material.set_shader_parameter("sun_energy", float(grade["sun_energy"]))
	ground_material.set_shader_parameter("sun_height", float(grade["sun_height"]))
	ground_material.set_shader_parameter("sky_col", _v3(grade["sky_col"]))
	ground_material.set_shader_parameter("sky_energy", float(grade["sky_energy"]))
	ground_material.set_shader_parameter("bounce_col", _v3(grade["bounce_col"]))
	ground_material.set_shader_parameter("bounce", float(grade["bounce"]))
	ground_material.set_shader_parameter("wild", float(grade["wild"]))
	_quad.queue_redraw()
	_update_us = Time.get_ticks_usec() - t0


## Compatibility shim for callers that still speak the streaming API.
func stream(view: Rect2, budget: int = 4) -> void:
	render(view, LcnPalette.grade_at(model.day_fraction() if model != null else 0.5), 1.0, budget < 0)


func draw_ground(ci: CanvasItem) -> void:
	ci.draw_texture_rect(_white, _rect, false, Color(1, 1, 1, 1))


## New construction melts snow and lays soot; the ground under it has to catch up
## this frame, not on the next round-robin sweep.
func invalidate_near(cell: Vector2i) -> void:
	var c := Vector2i(cell.x / CHUNK, cell.y / CHUNK)
	for dy: int in range(-1, 2):
		for dx: int in range(-1, 2):
			var k := c + Vector2i(dx, dy)
			if not _pending_chunks.has(k):
				_pending_chunks.append(k)


func clear_all() -> void:
	_pending_chunks.clear()
	_buildings_stamp = -1


func detail_level() -> float:
	return _detail


static func _v3(c: Color) -> Vector3:
	return Vector3(c.r, c.g, c.b)


# ---------------------------------------------------------------- diagnostics --

func stats() -> Dictionary:
	var f: Dictionary = field.stats() if field != null else {}
	return {
		"update_us": _update_us,
		"detail": _detail,
		"draw_calls": 1,
		"field_kb": int(f.get("bytes", 0)) / 1024,
		"kind_us": int(f.get("kind_us", 0)),
		"snow_us": int(f.get("snow_us", 0)),
		"sources_us": int(f.get("sources_us", 0)),
		"city_us": int(f.get("city_us", 0)),
	}


## Rebuilds every field for the whole map once and reports the cost. This is the
## honest answer to "what does the ground cost at full map size?" — the old
## renderer's equivalent number was 190 ms for a 256x256 world.
func benchmark_full_map(_view: Rect2) -> Dictionary:
	var t0: int = Time.get_ticks_usec()
	field.refresh_kind(model)
	field.refresh_snow(model, 1 << 20, [])
	field.refresh_sources(model.heat_sources(), model.buildings())
	field.refresh_city(model.buildings())
	var total_ms: float = float(Time.get_ticks_usec() - t0) / 1000.0
	var cells: int = field.size.x * field.size.y
	return {
		"world": "%dx%d" % [field.size.x, field.size.y],
		"cells": cells,
		"total_ms": total_ms,
		"us_per_cell": total_ms * 1000.0 / float(maxi(1, cells)),
		"field_kb": int(field.stats()["bytes"]) / 1024,
	}
