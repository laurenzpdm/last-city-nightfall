class_name LcnEntityRenderer
extends Node2D
## Buildings, props and people, in three batched passes. [P13], second pass.
##
## Pass order is the whole trick:
##   1. SHADOW  soft directional shadows, sheared by the sun's position in the
##              day cycle (or by the nearest fire after dark, which is when a
##              city like this actually has shadows).
##   2. GLOW    additive. Warm ground pools plus a rim pass — the sprite redrawn
##              offset toward its light source, so the lit edge burns and the far
##              edge stays cold. This is where the temperature reads.
##   3. MAIN    the sprites, y-sorted with the agents so people walk in front of
##              and behind buildings correctly, and each one tinted by the light
##              actually landing on it.
##
## PERFORMANCE. The first pass cost 37 ms of CPU and 797 draw calls for one frame
## of a 206-building city — a 27 fps ceiling before the simulation had run a
## single tick, and roughly 300 ms projected at the 1717-building stress city.
## Three things caused it and all three are fixed here:
##
##   * every sprite had its own texture, so every draw was a state change.
##     Everything now comes out of ONE atlas (LcnSpriteFactory.atlas), so a pass
##     is a handful of draw calls no matter how many buildings are in it.
##   * the visible set was rebuilt as an Array[Dictionary] every frame and sorted
##     with a GDScript lambda. It is now parallel packed arrays, sorted natively
##     on a packed key, and the sort only reruns when the set changes.
##   * shadows were three draws per building including two polygons. One
##     textured quad now does the whole job, in the same batch as everything else.
##
## LOD: below `LOD_ZOOM` the rim pass and the barrel are dropped and shadows
## collapse to a contact blob, because at that distance none of it is legible
## anyway. `stats()` reports what was actually drawn.

const TILE: int = 32
## Camera zoom under which detail passes are dropped.
const LOD_ZOOM: float = 0.42
const RIM_ZOOM: float = 0.30

var model: LcnWorldModel = null
var sprites: LcnSpriteFactory = null
var field: LcnTerrainField = null

var grade: Dictionary = {}
var view_rect: Rect2 = Rect2()
var alpha: float = 0.0
var zoom: float = 1.0
var draw_agents: bool = true

var _shadow: Node2D = null
var _glow: Node2D = null
var _main: Node2D = null

var _atlas: ImageTexture = null
var _regions: Dictionary[StringName, Rect2] = {}
var _glow_r: Rect2 = Rect2()
var _shadow_r: Rect2 = Rect2()
var _smear_r: Rect2 = Rect2()
var _barrel_r: Rect2 = Rect2()

var _visible_buildings: int = 0
var _visible_agents: int = 0
var _draw_us: int = 0
var _collect_us: int = 0
var _frozen: Dictionary[int, bool] = {}

## Per-frame scratch. Parallel arrays, reused between frames — the first pass
## allocated one Dictionary per visible building per frame and it showed.
var _vis: Array[Dictionary] = []
var _vis_rect: PackedVector2Array = PackedVector2Array()
var _srcs: Array[Dictionary] = []
var _src_buckets: Dictionary[int, PackedInt32Array] = {}
var _atlas_stamp: int = -1
var _logged_sprites: int = -1
## The frame's light rig, flattened out of the grade dictionary once. Evaluating
## LcnPalette.light_at per entity meant five dictionary probes per building per
## frame; at a few hundred entities that is real time for no information.
var _l_sun: Color = Color.WHITE
var _l_sky: Color = Color.WHITE
var _l_bnc: Color = Color.WHITE
var _l_key: float = 1.0
var _l_fill: float = 0.0
var _l_bounce: float = 0.0
var _l_wild: float = 0.0
## Source lookup grid cell, in world px. One bucket is a comfortable superset of
## the largest light radius, so _nearest_source only ever scans one bucket.
const BUCKET_PX: float = 256.0


## Inner pass nodes: they exist only to own a blend mode and a _draw callback.
class Pass extends Node2D:
	var host: LcnEntityRenderer = null
	var which: int = 0

	func _draw() -> void:
		if host != null:
			host.draw_pass(self, which)


func setup(world_model: LcnWorldModel, sprite_factory: LcnSpriteFactory) -> void:
	model = world_model
	sprites = sprite_factory
	_rebuild_atlas()

	_shadow = _make_pass("ShadowPass", 0, -40, false)
	_glow = _make_pass("GlowPass", 1, -20, true)
	_main = _make_pass("MainPass", 2, 0, false)


## Binds the ground's data fields so entities can be lit by the same numbers the
## ground is lit by. Optional: without it they fall back to the grade alone.
func bind_field(f: LcnTerrainField) -> void:
	field = f


func _rebuild_atlas() -> void:
	var requests: Array = model.sprite_requests() if model != null else []
	var a: Dictionary = sprites.atlas(requests)
	_atlas = a["texture"]
	_regions = a["regions"]
	_glow_r = _regions.get(&"glow", Rect2())
	_shadow_r = _regions.get(&"shadow", Rect2())
	_smear_r = _regions.get(&"smear", Rect2())
	_barrel_r = _regions.get(&"barrel", Rect2())
	_atlas_stamp = model.building_stamp() if model != null else 0
	# Only announce a real repack. This runs whenever the building set changes,
	# and the factory returns the same sheet unless a footprint it has never seen
	# turned up — logging every call would be one line per placement.
	if _regions.size() != _logged_sprites:
		_logged_sprites = _regions.size()
		Log.info("render", "draw atlas: %s px, %d sprites — one texture for every entity pass" % [
			str(a["size"]), _regions.size()])


func _make_pass(pass_name: String, which: int, z: int, additive: bool) -> Node2D:
	var p := Pass.new()
	p.host = self
	p.which = which
	p.name = pass_name
	p.z_index = z
	p.z_as_relative = false
	p.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	if additive:
		var mat := CanvasItemMaterial.new()
		mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		# Additive light must not be crushed by the night CanvasModulate,
		# otherwise the warm pools vanish exactly when they matter most.
		mat.light_mode = CanvasItemMaterial.LIGHT_MODE_UNSHADED
		p.material = mat
	add_child(p)
	return p


## Called once per frame by WorldRenderer before the passes redraw.
func refresh(day_grade: Dictionary, view: Rect2, interp: float, camera_zoom: float = 1.0) -> void:
	grade = day_grade
	view_rect = view
	alpha = interp
	zoom = camera_zoom
	_cache_light_rig()
	_collect()
	_shadow.queue_redraw()
	_glow.queue_redraw()
	_main.queue_redraw()


## Flattens the grade's light rig into scalars, once, for the frame. Entities are
## treated as mostly-upward faces (up = 0.85): a top-down camera sees roofs.
func _cache_light_rig() -> void:
	if grade.is_empty():
		return
	const UP: float = 0.85
	var facing: float = lerpf(1.0 - UP, UP, clampf(float(grade["sun_height"]), 0.0, 1.0))
	_l_sun = grade["sun_col"]
	_l_sky = grade["sky_col"]
	_l_bnc = grade["bounce_col"]
	_l_key = float(grade["sun_energy"]) * (0.28 + 0.80 * facing)
	_l_fill = float(grade["sky_energy"]) * (0.70 + 0.30 * UP)
	_l_bounce = float(grade["bounce"]) * 0.60
	_l_wild = float(grade["wild"])


## One walk over the world per frame instead of three, with the sprite rect and
## the atlas region resolved once each.
func _collect() -> void:
	var t0: int = Time.get_ticks_usec()
	_vis.clear()
	if model == null:
		return
	if model.building_stamp() != _atlas_stamp:
		_rebuild_atlas()

	var pad: Rect2 = view_rect.grow(8.0)
	for b: Dictionary in model.buildings():
		var region: Rect2 = _regions.get(b["sprite"], Rect2())
		if region.size.x <= 0.0:
			continue
		var cell: Vector2i = b["cell"]
		var origin := Vector2(float(cell.x), float(cell.y)) * float(TILE) \
			+ Vector2(-LcnSpriteFactory.PAD, -LcnSpriteFactory.PAD - float(b["lift"]))
		var rect := Rect2(origin, region.size)
		if not pad.intersects(rect):
			continue
		_vis.append({"b": b, "rect": rect, "src": region})
	_visible_buildings = _vis.size()

	_srcs = model.heat_sources()
	_src_buckets.clear()
	for i: int in _srcs.size():
		var s: Dictionary = _srcs[i]
		var p: Vector2 = s["pos"]
		var r: float = float(s["radius"]) * 1.4
		var x0: int = int(floor((p.x - r) / BUCKET_PX))
		var x1: int = int(floor((p.x + r) / BUCKET_PX))
		var y0: int = int(floor((p.y - r) / BUCKET_PX))
		var y1: int = int(floor((p.y + r) / BUCKET_PX))
		for by: int in range(y0, y1 + 1):
			for bx: int in range(x0, x1 + 1):
				var key: int = bx * 73856093 ^ by * 19349663
				var arr: PackedInt32Array = _src_buckets.get(key, PackedInt32Array())
				arr.append(i)
				_src_buckets[key] = arr
	_collect_us = Time.get_ticks_usec() - t0


func mark_frozen(id: int, is_frozen: bool) -> void:
	if is_frozen:
		_frozen[id] = true
	else:
		_frozen.erase(id)


func stats() -> Dictionary:
	return {
		"visible_buildings": _visible_buildings,
		"visible_agents": _visible_agents,
		"draw_us": _draw_us,
		"collect_us": _collect_us,
		"atlas_sprites": _regions.size(),
	}


# -------------------------------------------------------------------- draw ---

func draw_pass(ci: CanvasItem, which: int) -> void:
	if model == null or grade.is_empty() or _atlas == null:
		return
	var t0: int = Time.get_ticks_usec()
	match which:
		0: _draw_shadows(ci)
		1: _draw_glow(ci)
		2: _draw_main(ci)
	if which == 0:
		_draw_us = 0
	_draw_us += Time.get_ticks_usec() - t0


## Where a building's sprite lands on screen.
## Public so [P18]'s build cursor and [P19]'s overlays hit-test the same shape.
func sprite_rect(b: Dictionary) -> Rect2:
	var region: Rect2 = _regions.get(b.get("sprite", &""), Rect2())
	var cell: Vector2i = b["cell"]
	var origin := Vector2(float(cell.x), float(cell.y)) * float(TILE) \
		+ Vector2(-LcnSpriteFactory.PAD, -LcnSpriteFactory.PAD - float(b.get("lift", 0.0)))
	return Rect2(origin, region.size)


## The light landing on a building, from the same rig the ground shader uses —
## see LcnPalette.light_at, which this is the flattened inline form of.
func _light_for(centre: Vector2, warm: float) -> Color:
	var city: float = 1.0
	var heat: float = warm
	if field != null:
		var cell := Vector2i(int(centre.x / float(TILE)), int(centre.y / float(TILE)))
		city = field.city_at(cell)
		heat = maxf(heat, field.heat_at(cell))
	var b: float = _l_bounce * clampf(city, 0.0, 1.0)
	var dark: float = 1.0 - _l_wild * (1.0 - clampf(city * 1.7, 0.0, 1.0))
	var w: float = clampf(heat, 0.0, 1.0) * 0.34
	return Color(
		(_l_sun.r * _l_key + _l_sky.r * _l_fill + _l_bnc.r * b) * dark + LcnPalette.WARM_EDGE.r * w,
		(_l_sun.g * _l_key + _l_sky.g * _l_fill + _l_bnc.g * b) * dark + LcnPalette.WARM_EDGE.g * w,
		(_l_sun.b * _l_key + _l_sky.b * _l_fill + _l_bnc.b * b) * dark + LcnPalette.WARM_EDGE.b * w,
		1.0)


# --- pass 1: shadows ---------------------------------------------------------

func _draw_shadows(ci: CanvasItem) -> void:
	var dir: Vector2 = grade["shadow_dir"]
	var len_mul: float = grade["shadow_len"]
	var col: Color = grade["shadow"]
	var a: float = grade["shadow_alpha"]
	var night: float = clampf(float(grade["bounce"]), 0.0, 1.0)
	var detailed: bool = zoom >= LOD_ZOOM and _smear_r.size.x > 0.0

	# TWO loops on purpose. draw_texture_rect_region and draw_polygon are different
	# canvas primitives, and alternating them per building ends the batch every
	# time — 2N draw calls instead of 2. Every blob first, then every smear.
	var contact := Color(col.r, col.g, col.b, a * 0.85)
	for entry: Dictionary in _vis:
		var b: Dictionary = entry["b"]
		if int(b.get("state", LcnWorldModel.BUILD_OPERATIONAL)) == LcnWorldModel.BUILD_GHOST:
			continue
		var tiles: Vector2i = b["tiles"]
		var cell: Vector2i = b["cell"]
		ci.draw_texture_rect_region(_atlas,
			Rect2(Vector2(float(cell.x), float(cell.y)) * float(TILE) - Vector2(6.0, 4.0),
				Vector2(float(tiles.x), float(tiles.y)) * float(TILE) + Vector2(12.0, 10.0)),
			_shadow_r, contact)

	if draw_agents and detailed:
		for ag: Dictionary in model.agents(alpha):
			var p: Vector2 = ag["pos"]
			if not view_rect.grow(24.0).has_point(p):
				continue
			ci.draw_texture_rect_region(_atlas,
				Rect2(p - Vector2(7.0, 4.0), Vector2(14.0, 8.0)), _shadow_r,
				Color(col.r, col.g, col.b, a * 0.8))

	if not detailed:
		return
	var smear := Color(col.r, col.g, col.b, a * 0.70)
	var smear_cols := PackedColorArray([smear, smear, smear, smear])
	var smear_uvs := PackedVector2Array([
		_uv(_smear_r, 0.0, 0.0), _uv(_smear_r, 1.0, 0.0),
		_uv(_smear_r, 1.0, 1.0), _uv(_smear_r, 0.0, 1.0)])
	for entry2: Dictionary in _vis:
		var b2: Dictionary = entry2["b"]
		if int(b2.get("state", LcnWorldModel.BUILD_OPERATIONAL)) == LcnWorldModel.BUILD_GHOST:
			continue
		var lift: float = float(b2["lift"])
		if lift < 8.0:
			continue
		var tiles2: Vector2i = b2["tiles"]
		var cell2: Vector2i = b2["cell"]
		var foot := Rect2(
			Vector2(float(cell2.x), float(cell2.y)) * float(TILE),
			Vector2(float(tiles2.x), float(tiles2.y)) * float(TILE))

		# After dark the dominant light is the nearest fire, not the sun.
		var use_dir: Vector2 = dir
		if night > 0.05:
			var nearest: Dictionary = _nearest_source(foot.get_center())
			if not nearest.is_empty():
				var away: Vector2 = foot.get_center() - (nearest["pos"] as Vector2)
				if away.length() > 4.0:
					use_dir = dir.lerp(away.normalized(), night * 0.85).normalized()

		# One sheared, textured quad: bright at the foot of the building, gone at
		# the tip. Same texture as everything else, so this stays batched.
		var o: Vector2 = use_dir * (lift * len_mul)
		var side: Vector2 = Vector2(-use_dir.y, use_dir.x) * (foot.size.x * 0.42)
		var p0: Vector2 = foot.get_center() - side + Vector2(0.0, foot.size.y * 0.34)
		var p1: Vector2 = foot.get_center() + side + Vector2(0.0, foot.size.y * 0.34)
		ci.draw_polygon(
			PackedVector2Array([p0, p1, p1 + o + side * 0.35, p0 + o - side * 0.35]),
			smear_cols, smear_uvs, _atlas)


## Atlas pixel coordinates for a normalised point in a region. draw_polygon takes
## UVs in TEXTURE PIXELS, not 0..1.
static func _uv(region: Rect2, u: float, v: float) -> Vector2:
	return region.position + Vector2(region.size.x * u, region.size.y * v)


func _nearest_source(p: Vector2) -> Dictionary:
	var key: int = int(floor(p.x / BUCKET_PX)) * 73856093 ^ int(floor(p.y / BUCKET_PX)) * 19349663
	var candidates: PackedInt32Array = _src_buckets.get(key, PackedInt32Array())
	var best: Dictionary = {}
	var best_score: float = -1.0
	for i: int in candidates:
		var s: Dictionary = _srcs[i]
		var d: float = (s["pos"] as Vector2).distance_to(p)
		var r: float = float(s["radius"])
		if d > r * 1.4:
			continue
		var score: float = float(s["intensity"]) * (1.0 - d / (r * 1.4))
		if score > best_score:
			best_score = score
			best = s
	return best


# --- pass 2: additive warmth -------------------------------------------------

func _draw_glow(ci: CanvasItem) -> void:
	var energy: float = grade["light_energy"]

	# Warm pools on the ground. Light2D does the physical lighting; this pass
	# adds the bloomy core that makes a fire feel hot rather than merely bright.
	for s: Dictionary in _srcs:
		var pos: Vector2 = s["pos"]
		var radius: float = float(s["radius"]) * 0.8
		if not view_rect.grow(radius).has_point(pos):
			continue
		var intensity: float = float(s["intensity"])
		var flicker: float = 1.0 + sin(SimClock.seconds() * 3.1 + float(s.get("seed", 0)) * 0.37) * 0.055
		var col: Color = LcnPalette.heat_light_color(intensity)
		# 0.11, not 0.16: with the light rig no longer crushing the whole frame,
		# the additive pass no longer has to shout to be seen, and a radiator
		# stops resolving as a blown-out white disc.
		var strength: float = clampf(0.11 * intensity * energy * flicker, 0.0, 0.62)
		ci.draw_texture_rect_region(_atlas,
			Rect2(pos - Vector2(radius, radius), Vector2(radius * 2.0, radius * 2.0)),
			_glow_r, Color(col.r, col.g, col.b, strength))

	if zoom < RIM_ZOOM:
		return

	# Rim light: the sprite redrawn offset toward its light. The main pass then
	# covers everything but the lit crescent.
	for entry: Dictionary in _vis:
		var b: Dictionary = entry["b"]
		if _frozen.has(int(b["id"])):
			continue
		var centre: Vector2 = b["centre"]
		var src: Dictionary = _nearest_source(centre)
		var warm: float = float(b["warm"])
		var rim: float = warm * 0.30
		var toward := Vector2(-0.55, -0.85)
		if not src.is_empty():
			var v: Vector2 = (src["pos"] as Vector2) - centre
			var d: float = v.length()
			var r: float = float(src["radius"])
			if d > 1.0:
				toward = v / d
			rim = maxf(rim, clampf(1.0 - d / r, 0.0, 1.0) * float(src["intensity"]) * 0.55)
		if rim < 0.02:
			continue
		var rect: Rect2 = entry["rect"]
		var col2: Color = LcnPalette.WARM_MID
		ci.draw_texture_rect_region(_atlas,
			Rect2(rect.position + toward * 2.0 - Vector2(0.0, 1.0), rect.size), entry["src"],
			Color(col2.r, col2.g, col2.b, clampf(rim * energy * 0.48, 0.0, 0.62)))


# --- pass 3: sprites ---------------------------------------------------------

func _draw_main(ci: CanvasItem) -> void:
	# model.buildings() is already ordered back-to-front; agents are merged into
	# it linearly instead of re-sorting the whole world with a script lambda.
	var ags: Array[Dictionary] = model.agents(alpha) if draw_agents else ([] as Array[Dictionary])
	var vis_ag: Array[Dictionary] = []
	var pad: Rect2 = view_rect.grow(32.0)
	for ag: Dictionary in ags:
		if pad.has_point(ag["pos"] as Vector2):
			vis_ag.append(ag)
	vis_ag.sort_custom(_agent_before)
	_visible_agents = vis_ag.size()

	var frost: Color = LcnPalette.ICE_BLUE
	var ai: int = 0
	var barrels: bool = zoom >= LOD_ZOOM and _barrel_r.size.x > 0.0
	for e: Dictionary in _vis:
		var b2: Dictionary = e["b"]
		var cell: Vector2i = b2["cell"]
		var tiles: Vector2i = b2["tiles"]
		var y: float = float(cell.y + tiles.y) * float(TILE)
		while ai < vis_ag.size() and float((vis_ag[ai]["pos"] as Vector2).y) < y:
			_draw_agent(ci, vis_ag[ai])
			ai += 1

		var rect: Rect2 = e["rect"]
		var state2: int = int(b2.get("state", LcnWorldModel.BUILD_OPERATIONAL))
		var lit: Color = _light_for(b2["centre"], float(b2["warm"]))
		var tint := Color(lit.r, lit.g, lit.b, 1.0)
		if _frozen.has(int(b2["id"])) or state2 == LcnWorldModel.BUILD_FROZEN:
			tint = Color(tint.r * (frost.r * 0.85 + 0.15), tint.g * (frost.g * 0.85 + 0.15),
				tint.b * (frost.b * 0.9 + 0.1), 1.0)
		elif state2 == LcnWorldModel.BUILD_DISABLED:
			tint = Color(tint.r * 0.62, tint.g * 0.66, tint.b * 0.74, 1.0)
		elif state2 == LcnWorldModel.BUILD_DECONSTRUCTING:
			tint = Color(tint.r, tint.g * 0.72, tint.b * 0.62, 0.75)
		if state2 == LcnWorldModel.BUILD_GHOST or state2 == LcnWorldModel.BUILD_CONSTRUCTING:
			_draw_site(ci, b2, rect, e["src"], state2)
		else:
			ci.draw_texture_rect_region(_atlas, rect, e["src"], tint)
			if barrels and b2["arch"] == &"turret":
				_draw_barrel(ci, b2, rect, tint)

	while ai < vis_ag.size():
		_draw_agent(ci, vis_ag[ai])
		ai += 1


static func _agent_before(x: Dictionary, y: Dictionary) -> bool:
	return float((x["pos"] as Vector2).y) < float((y["pos"] as Vector2).y)


func _draw_agent(ci: CanvasItem, ag: Dictionary) -> void:
	var region: Rect2 = _regions.get(LcnSpriteFactory.agent_key(ag["kind"]), Rect2())
	if region.size.x <= 0.0:
		return
	var pos: Vector2 = (ag["pos"] as Vector2) + Vector2(-region.size.x * 0.5, -region.size.y + 5.0)
	# Sub-pixel snapping keeps 14px figures from shimmering as they walk.
	pos = Vector2(round(pos.x), round(pos.y))
	var lit: Color = _light_for(ag["pos"], 0.0)
	ci.draw_texture_rect_region(_atlas, Rect2(pos, region.size), region,
		Color(lit.r, lit.g, lit.b, 1.0))


## A planned or half-built structure: surveyed footprint, scaffold uprights and
## a ghost of the finished silhouette. The player should always be able to read
## what is coming and how far along it is.
func _draw_site(ci: CanvasItem, b: Dictionary, rect: Rect2, src: Rect2, state: int) -> void:
	var tiles: Vector2i = b["tiles"]
	var cell: Vector2i = b["cell"]
	var foot := Rect2(
		Vector2(float(cell.x), float(cell.y)) * float(TILE),
		Vector2(float(tiles.x), float(tiles.y)) * float(TILE))
	var accent: Color = LcnPalette.CAUTION if state == LcnWorldModel.BUILD_CONSTRUCTING else LcnPalette.STEEL_LIGHT
	ci.draw_texture_rect_region(_atlas, rect, src,
		Color(accent.r, accent.g, accent.b, 0.24 if state == LcnWorldModel.BUILD_GHOST else 0.40))
	ci.draw_rect(foot, Color(accent.r, accent.g, accent.b, 0.10), true)
	ci.draw_rect(foot, Color(accent.r, accent.g, accent.b, 0.85), false, 1.5)
	for i: int in 4:
		var f: float = (float(i) + 0.5) / 4.0
		var x: float = lerpf(foot.position.x + 2.0, foot.end.x - 2.0, f)
		ci.draw_line(Vector2(x, foot.end.y), Vector2(x, foot.end.y - 10.0 - float(i % 2) * 5.0),
			Color(accent.r, accent.g, accent.b, 0.55), 1.5)
	if state == LcnWorldModel.BUILD_CONSTRUCTING:
		var bar := Rect2(foot.position.x + 2.0, foot.position.y - 6.0, foot.size.x - 4.0, 3.0)
		ci.draw_rect(bar, Color(0.04, 0.06, 0.10, 0.85), true)
		ci.draw_rect(Rect2(bar.position, Vector2(bar.size.x * clampf(float(b.get("progress", 0.4)), 0.0, 1.0), bar.size.y)),
			LcnPalette.WARM_MID, true)


func _draw_barrel(ci: CanvasItem, b: Dictionary, rect: Rect2, tint: Color) -> void:
	var pivot := Vector2(8.0, 9.0)
	# Guns face away from the city centre; a defensive line should look aimed.
	var centre: Vector2 = b["centre"]
	var world_mid := Vector2(model.world_size()) * float(TILE) * 0.5
	var away: Vector2 = centre - world_mid
	var ang: float = away.angle() if away.length() > 1.0 else 0.0
	ang += sin(SimClock.seconds() * 0.4 + float(b["seed"]) * 0.11) * 0.22
	var mount: Vector2 = rect.position + Vector2(rect.size.x * 0.5, rect.size.y - 46.0)
	ci.draw_set_transform(mount, ang, Vector2.ONE)
	ci.draw_texture_rect_region(_atlas, Rect2(-pivot, _barrel_r.size), _barrel_r, tint)
	ci.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
