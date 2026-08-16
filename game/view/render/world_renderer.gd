class_name WorldRenderer
extends Node2D
## The renderer. [P13] Reads the simulation, never writes it.
##
## Structure:
##   LcnTerrainRenderer   the ground: ONE shaded quad over a small data plane
##                        (LcnTerrainField). No tiles, no chunk streaming.
##   LcnEntityRenderer    shadow / additive-warmth / sprite passes, all three
##                        drawing out of ONE atlas so a pass is a few draw calls
##   LcnLightRig          hour cast + pooled warm Light2Ds
##   LcnPostProcess       grade, bloom, vignette, grain, cold split, heat shimmer
##
## SECOND PASS, in one paragraph. Everything the first pass got wrong was
## structural. Terrain repeated because it was four baked tile images, and seamed
## because snow was baked into a tile at the moment its chunk loaded; both are
## gone because no tile and no chunk is drawn any more. Night was a void because
## a CanvasModulate multiplied the whole frame down; darkness is now made per
## surface by the light rig in LcnPalette, which the ground shader and the entity
## tint both evaluate, so the settlement keeps a moonlight floor and the plain
## beyond it does not. Dusk was a colour filter because the key had no elevation;
## it has one now and rakes across drifts. And entity drawing cost 37 ms at 206
## buildings because every sprite was its own texture; one atlas took the same
## frame to 2.4 ms and 8 draw calls. Measurements are in the log, per stage, per
## frame — see _log_frame_cost — and at stress-city scale in
## tests/render/render_perf.tscn.
##
## Movement is interpolated with SimClock.alpha, so agents move smoothly at
## 60fps on top of a 20Hz simulation.
##
## For other view/ui parts:
##   const P := preload("res://game/view/render/palette.gd")   # the palette
##   var r: WorldRenderer = get_tree().get_first_node_in_group(&"lcn_world_renderer")
##   r.current_grade()      # the hour's colour grade, for matching UI tint
##   r.tile_size()          # 32
##   r.view_rect()          # visible world rect in pixels
##
## The renderer owns a fallback Camera2D only when nothing else has one, and
## removes it the moment [P16] adds a real camera.

const TILE: int = 32
const GROUP: StringName = &"lcn_world_renderer"

var model: LcnWorldModel = null
var sprites: LcnSpriteFactory = null
var terrain: LcnTerrainRenderer = null
var entities: LcnEntityRenderer = null
var lights: LcnLightRig = null
var post: LcnPostProcess = null

var _grade: Dictionary = {}
var _view: Rect2 = Rect2()
var _camera: Camera2D = null
var _owns_camera: bool = false
var _frames: int = 0
var _first_frame: bool = true
var _camera_check: float = 0.0
var _bench_done: bool = false
var _frame_us_avg: float = 0.0
var _zoom: float = 1.0
var _ground_us: int = 0
var _light_us: int = 0


func _ready() -> void:
	add_to_group(GROUP)
	name = "WorldRenderer"
	z_index = 0

	var t0: int = Time.get_ticks_msec()
	sprites = LcnSpriteFactory.new()
	# Warm the sprite cache up front: baking mid-game would hitch, and the disk
	# cache makes this free on every launch after the first.
	for arch: StringName in LcnSpriteFactory.archetypes():
		sprites.building(arch)
	for kind: StringName in LcnSpriteFactory.AGENT_KINDS:
		sprites.agent(kind)
	for ek: StringName in LcnSpriteFactory.ENEMY_KINDS:
		sprites.agent(ek)
	sprites.turret_barrel()

	model = LcnWorldModel.new(sprites)

	terrain = LcnTerrainRenderer.new()
	terrain.name = "Terrain"
	add_child(terrain)
	terrain.setup(model)

	entities = LcnEntityRenderer.new()
	entities.name = "Entities"
	add_child(entities)
	entities.setup(model, sprites)
	entities.bind_field(terrain.field)

	lights = LcnLightRig.new()
	lights.name = "Lights"
	add_child(lights)
	lights.setup()

	post = LcnPostProcess.new()
	post.name = "Post"
	add_child(post)
	post.setup()

	Log.info("render", "%s (%d ms)" % [LcnArtCache.report(), Time.get_ticks_msec() - t0])

	Bus.world_created.connect(_on_world_created)
	Bus.world_ready.connect(_on_world_ready)
	Bus.tick_advanced.connect(_on_tick)
	Bus.building_placed.connect(_on_building_placed)
	Bus.building_removed.connect(_on_building_removed)
	Bus.building_state_changed.connect(_on_building_state)
	Bus.building_froze.connect(_on_building_froze)
	Bus.enemy_spawned.connect(_on_enemy_spawned)
	Bus.enemy_killed.connect(_on_enemy_killed)

	if Sim.alive:
		_on_world_ready()


# ------------------------------------------------------------------ sim hooks --

func _on_world_created(_seed_value: int) -> void:
	if terrain != null:
		terrain.clear_all()
	if entities != null:
		# A new world does not inherit the last one's dead, its footprints or the
		# rocks that were standing on the last one's plain.
		entities.clear_deaths()
		entities.clear_tracks()
		if entities.scenery != null:
			entities.scenery.setup(Rng.seed_value)
	_first_frame = true


func _on_world_ready() -> void:
	model.attach()
	if model.building_count() == 0:
		model.ensure_preview_settlement(_core_cell())
	terrain.clear_all()
	terrain.bind_world()
	entities.bind_field(terrain.field)
	# The plain's furniture is read off the terrain, and the terrain has just
	# been rebound to a different world.
	if entities.scenery != null:
		entities.scenery.setup(Rng.seed_value)
	if terrain.field != null:
		post.bind_heat_field(terrain.field.heat_tex,
			Vector2(terrain.field.size) * float(TILE))
	_first_frame = true
	_ensure_camera()
	if _owns_camera and _camera != null:
		var c: Vector2 = _city_centre()
		_camera.position = c
	# Report what is ON SCREEN, not what the terrain came from. `using_preview()`
	# is about the ground; saying "source=sim" while every visible structure is a
	# placeholder is the one log line a reviewer would have trusted.
	Log.info("render", "world ready: %d structures (%s), %d agents, terrain=%s" % [
		model.building_count(),
		"PLACEHOLDERS" if model.showing_preview_settlement() else "real",
		model.agent_count(),
		"preview" if model.using_preview() else "sim",
	])


func _on_tick(tick: int) -> void:
	model.advance(tick)


func _on_building_placed(id: int, kind: StringName, cell: Vector2i) -> void:
	model.drop_preview_buildings()
	model.add_building(id, kind, cell)
	_invalidate_ground_near(cell)


func _on_building_removed(id: int, cell: Vector2i) -> void:
	model.remove_building(id)
	_invalidate_ground_near(cell)


func _on_building_state(id: int, state: int) -> void:
	model.set_building_state(id, state)


func _on_building_froze(id: int) -> void:
	entities.mark_frozen(id, true)


## The kind on this signal is the enemy's REAL id (`CombatEnemyDef.id`), which is
## one of ash_spitter, cinder_leech, drift_hound, frost_shade, hoarfrost_breaker,
## keener, pale_stalker, permafrost_borer, rime_sapper, the_long_cold.
##
## It used to be reduced here with
##     &"brute" if String(kind).to_lower().contains("brute") else &"swarm"
## and NOT ONE of those ten contains "brute" — so every enemy in the game, from a
## 30 hp hound to a 9000 hp boss, drew the same eighteen pixels. The mapping was
## not crude, it was never true for any input the simulation can produce.
func _on_enemy_spawned(id: int, kind: StringName, pos: Vector2) -> void:
	model.set_agent(id, LcnSpriteFactory.agent_arch(kind), pos)


func _on_enemy_killed(id: int, pos: Vector2) -> void:
	# Read the kind BEFORE dropping it: the death mark is drawn in the shape of
	# the thing that died, and a boss going down must not look like a hound.
	entities.mark_death(pos, model.agent_kind(id))
	model.remove_agent(id)


## New construction changes snow melt and soot, so the ground under and around
## it has to catch up this frame rather than on the next round-robin sweep.
func _invalidate_ground_near(cell: Vector2i) -> void:
	terrain.invalidate_near(cell)


# --------------------------------------------------------------------- frame --

func _process(delta: float) -> void:
	if model == null:
		return
	var t0: int = Time.get_ticks_usec()
	_frames += 1

	_camera_check -= delta
	if _camera_check <= 0.0:
		_camera_check = 0.5
		_ensure_camera()
	if _owns_camera and _camera != null:
		_drive_tour_camera()

	_view = _compute_view()
	_zoom = _camera.zoom.x if _camera != null else _viewport_zoom()

	var day: float = model.day_fraction()
	_grade = LcnPalette.grade_at(day)

	var t_ground: int = Time.get_ticks_usec()
	terrain.render(_view, _grade, _zoom, _first_frame)
	_ground_us = Time.get_ticks_usec() - t_ground

	var t_light: int = Time.get_ticks_usec()
	lights.update(_grade, _view, model, bool(Settings.graphics.get("lights", true)))
	_light_us = Time.get_ticks_usec() - t_light

	entities.refresh(_grade, _view, SimClock.alpha, _zoom)
	post.apply(_grade, model.ambient_temperature(), get_viewport().get_visible_rect().size, _view)

	if _first_frame:
		_first_frame = false
		if Harness.active and Harness.visual and not _bench_done:
			_bench_done = true
			_run_perf_proof()

	# The entity pass draws deferred, so its cost is NOT inside _process. Add it in
	# or the line below reports a frame cost ~90x better than the cost it prints
	# two fields later on the same line.
	var us: float = float(Time.get_ticks_usec() - t0) + float(entities.stats()["draw_us"])
	_frame_us_avg = _frame_us_avg * 0.92 + us * 0.08 if _frames > 1 else us
	if _frames % 120 == 0 or (Harness.visual and _frames % 4 == 0):
		_log_frame_cost()


## Camera scale, whichever camera is current. [P16] owns the real one, so this
## reads it out of the canvas transform rather than reaching into its node.
func _viewport_zoom() -> float:
	var xf: Transform2D = get_viewport().get_canvas_transform()
	return maxf(0.01, xf.get_scale().x)


func _compute_view() -> Rect2:
	var vp: Viewport = get_viewport()
	var size: Vector2 = vp.get_visible_rect().size
	if _owns_camera and _camera != null:
		var zoom: Vector2 = _camera.zoom
		var world_size: Vector2 = size / zoom
		return Rect2(_camera.position - world_size * 0.5, world_size)
	var xf: Transform2D = vp.get_canvas_transform().affine_inverse()
	return xf * Rect2(Vector2.ZERO, size)


## Visible world rect in pixels. Other view parts can use this to cull.
func view_rect() -> Rect2:
	return _view


## The current hour's colour grade (see LcnPalette.grade_at).
func current_grade() -> Dictionary:
	return _grade


func tile_size() -> int:
	return TILE


func sprite_factory() -> LcnSpriteFactory:
	return sprites


func world_model() -> LcnWorldModel:
	return model


static func cell_at(world_pos: Vector2) -> Vector2i:
	return Vector2i(int(floor(world_pos.x / float(TILE))), int(floor(world_pos.y / float(TILE))))


# -------------------------------------------------------------------- camera --

## The grid's core cell if [P01] has one, otherwise the middle of the map.
func _core_cell() -> Vector2i:
	var grid: SimSystem = Sim.get_system(&"grid")
	if grid != null and grid.has_method("core_cell"):
		return grid.call("core_cell")
	return model.world_size() / 2


func _city_centre() -> Vector2:
	var b: Array[Dictionary] = model.buildings()
	if not b.is_empty():
		var sum := Vector2.ZERO
		for e: Dictionary in b:
			sum += e["centre"] as Vector2
		return sum / float(b.size())
	return Vector2(model.world_size()) * float(TILE) * 0.5


## Creates a camera only if the project has none, and stands down as soon as
## [P16] provides a real one.
func _ensure_camera() -> void:
	var foreign: Camera2D = _find_foreign_camera(get_tree().root)
	if foreign != null:
		if _owns_camera and _camera != null:
			Log.info("render", "external camera detected — releasing the fallback camera")
			_camera.queue_free()
			_camera = null
			_owns_camera = false
		return
	if _camera != null:
		return
	_camera = Camera2D.new()
	_camera.name = "FallbackCamera"
	_camera.zoom = Vector2(1.0, 1.0)
	_camera.position = _city_centre()
	_camera.enabled = true
	add_child(_camera)
	_camera.make_current()
	_owns_camera = true
	Log.info("render", "no camera in the scene — using the render fallback camera")


func _find_foreign_camera(n: Node) -> Camera2D:
	for c: Node in n.get_children():
		if c is Camera2D and c != _camera:
			return c
		var found: Camera2D = _find_foreign_camera(c)
		if found != null:
			return found
	return null


## Harness-only framing tour. A screenshot run should show the art from several
## distances and several hours, not the same frame six times.
func _drive_tour_camera() -> void:
	if not (Harness.active and Harness.visual):
		return
	var centre: Vector2 = _city_centre()
	var keys: Array[Dictionary] = [
		{"t": 0.0, "off": Vector2(0.0, -60.0), "zoom": 1.05},
		{"t": 150.0, "off": Vector2(-340.0, -190.0), "zoom": 1.55},
		{"t": 300.0, "off": Vector2(260.0, 150.0), "zoom": 1.35},
		{"t": 420.0, "off": Vector2(0.0, 20.0), "zoom": 0.85},
		{"t": 520.0, "off": Vector2(-600.0, -600.0), "zoom": 1.25},
		{"t": 600.0, "off": Vector2(0.0, 0.0), "zoom": 0.52},
	]
	var t: float = float(SimClock.tick)
	var i: int = 0
	for k: int in range(keys.size() - 1):
		if t >= float(keys[k]["t"]) and t <= float(keys[k + 1]["t"]):
			i = k
			break
	if t >= float(keys[keys.size() - 1]["t"]):
		i = keys.size() - 2
	var a: Dictionary = keys[i]
	var b: Dictionary = keys[i + 1]
	var span: float = maxf(1.0, float(b["t"]) - float(a["t"]))
	var f: float = smoothstep(0.0, 1.0, clampf((t - float(a["t"])) / span, 0.0, 1.0))
	_camera.position = centre + (a["off"] as Vector2).lerp(b["off"] as Vector2, f)
	var z: float = lerpf(float(a["zoom"]), float(b["zoom"]), f)
	_camera.zoom = Vector2(z, z)
	_camera.force_update_scroll()


# --------------------------------------------------------------- diagnostics --

func _log_frame_cost() -> void:
	var ts: Dictionary = terrain.stats()
	var es: Dictionary = entities.stats()
	# `wear` is on this line because it is the one number in the renderer that is
	# supposed to CLIMB across a session — the ground's memory of where the
	# population went. A run whose wear stays at 0.0000 while agents walk is a
	# run where the city is not writing on the world, and that is invisible in a
	# single screenshot and obvious in the log.
	Log.info("render", "frame %.2f ms | ground %.2f (field %d KB, detail %.2f) | collect %.2f | draw %.2f | lights %.2f | %d bld %d scenery %d agents %d tracks %d lights | wear %.5f over %d footfalls | %d draw calls" % [
		_frame_us_avg / 1000.0,
		float(_ground_us) / 1000.0, int(ts["field_kb"]), float(ts["detail"]),
		float(es["collect_us"]) / 1000.0,
		float(es["draw_us"]) / 1000.0,
		float(_light_us) / 1000.0,
		int(es["visible_buildings"]), int(es["scenery"]), int(es["visible_agents"]),
		int(es["tracks_drawn"]), lights.active_lights(),
		float(ts.get("wear_mean", 0.0)), int(ts.get("wear_stamps", 0)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
	])


## Streams the entire world once and logs the real cost. Runs once per visual
## harness session so the "fast at 500x500" claim is a measurement in the log,
## not a promise in a comment.
func _run_perf_proof() -> void:
	var r: Dictionary = terrain.benchmark_full_map(_view)
	Log.info("render", "PERF full-map ground rebuild %s: %d cells in %.1f ms (%.3f us/cell), %d KB resident" % [
		r["world"], int(r["cells"]), float(r["total_ms"]), float(r["us_per_cell"]), int(r["field_kb"]),
	])
	Log.info("render", "PERF ground is one draw call for the whole world at any zoom")
