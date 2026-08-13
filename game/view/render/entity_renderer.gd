class_name LcnEntityRenderer
extends Node2D
## Buildings, props and people, drawn in three batched passes. [P13]
##
## Pass order is the whole trick:
##   1. SHADOW  long cast shadows on the ground, direction and length driven by
##              the sun's position in the day cycle (or by the nearest fire at
##              night, which is when a city like this actually has shadows).
##   2. GLOW    additive. Warm ground pools plus a rim pass — the sprite redrawn
##              offset toward its light source, so the lit edge burns and the
##              far edge stays cold. This is where the temperature reads.
##   3. MAIN    the sprites themselves, y-sorted with the agents so people walk
##              in front of and behind buildings correctly.
##
## Every pass is one CanvasItem with one _draw(), not a node per entity.

const TILE: int = 32

var model: LcnWorldModel = null
var sprites: LcnSpriteFactory = null

var grade: Dictionary = {}
var view_rect: Rect2 = Rect2()
var alpha: float = 0.0
var draw_agents: bool = true

var _shadow: Node2D = null
var _glow: Node2D = null
var _main: Node2D = null
var _glow_tex: ImageTexture = null

var _visible_buildings: int = 0
var _visible_agents: int = 0
var _draw_us: int = 0
var _frozen: Dictionary[int, bool] = {}

## Per-frame scratch, built once in refresh() and read by all three passes.
## Rebuilding it per pass was ~0.18 ms of CPU per visible building per frame,
## which is a hard ceiling at a few hundred entities — not a tuning knob.
var _vis: Array[Dictionary] = []
var _srcs: Array[Dictionary] = []
var _src_buckets: Dictionary[int, PackedInt32Array] = {}
## Source lookup grid cell, in world px. One bucket is a comfortable superset of
## the largest light radius, so _nearest_source only ever scans nine buckets.
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
	_glow_tex = LcnSpriteFactory.glow_texture(256)

	_shadow = _make_pass("ShadowPass", 0, -40, false)
	_glow = _make_pass("GlowPass", 1, -20, true)
	_main = _make_pass("MainPass", 2, 0, false)


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
func refresh(day_grade: Dictionary, view: Rect2, interp: float) -> void:
	grade = day_grade
	view_rect = view
	alpha = interp
	_collect()
	_shadow.queue_redraw()
	_glow.queue_redraw()
	_main.queue_redraw()


## One walk over the world per frame instead of three, with the sprite rect and
## the sprite record resolved once each.
func _collect() -> void:
	_vis = []
	if model == null:
		return
	for b: Dictionary in model.buildings():
		var sp: Dictionary = sprites.building(b["arch"])
		var tex: ImageTexture = sp["texture"]
		var cell: Vector2i = b["cell"]
		var scale: float = float(b.get("scale", 1.0))
		var origin := Vector2(float(cell.x), float(cell.y)) * float(TILE) + (sp["offset"] as Vector2) * scale
		var rect := Rect2(origin, Vector2(tex.get_size()) * scale)
		if not view_rect.intersects(rect):
			continue
		_vis.append({"b": b, "rect": rect, "sp": sp})
	_visible_buildings = _vis.size()

	_srcs = model.heat_sources()
	_src_buckets = {}
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
	}


# -------------------------------------------------------------------- draw ---

func draw_pass(ci: CanvasItem, which: int) -> void:
	if model == null or grade.is_empty():
		return
	var t0: int = Time.get_ticks_usec()
	match which:
		0: _draw_shadows(ci)
		1: _draw_glow(ci)
		2: _draw_main(ci)
	if which == 0:
		_draw_us = 0
	_draw_us += Time.get_ticks_usec() - t0


## Where a building's sprite lands on screen. The archetype sprite is scaled so
## its baked footprint covers the building's real footprint, which is how one
## generator drawing serves both a 3x2 coal plant and a 5x5 hearth.
## Public so [P18]'s build cursor and [P19]'s overlays hit-test the same shape.
func sprite_rect(b: Dictionary) -> Rect2:
	var sp: Dictionary = sprites.building(b["arch"])
	var tex: ImageTexture = sp["texture"]
	var cell: Vector2i = b["cell"]
	var scale: float = float(b.get("scale", 1.0))
	var origin := Vector2(float(cell.x), float(cell.y)) * float(TILE) + (sp["offset"] as Vector2) * scale
	return Rect2(origin, Vector2(tex.get_size()) * scale)


# --- pass 1: shadows ---------------------------------------------------------

func _draw_shadows(ci: CanvasItem) -> void:
	var dir: Vector2 = grade["shadow_dir"]
	var len_mul: float = grade["shadow_len"]
	var col: Color = grade["shadow"]
	var a: float = grade["shadow_alpha"]
	var srcs: Array[Dictionary] = _srcs
	var night: float = clampf((float(grade["light_energy"]) - 0.7) / 0.9, 0.0, 1.0)

	for entry: Dictionary in _vis:
		var b: Dictionary = entry["b"]
		var state: int = int(b.get("state", LcnWorldModel.BUILD_OPERATIONAL))
		if state == LcnWorldModel.BUILD_GHOST:
			continue
		var sp: Dictionary = entry["sp"]
		var lift: float = float(sp["lift"]) * float(b.get("scale", 1.0))
		if lift < 8.0:
			continue
		var tiles: Vector2i = b["tiles"]
		var cell: Vector2i = b["cell"]
		var foot := Rect2(
			Vector2(float(cell.x), float(cell.y)) * float(TILE),
			Vector2(float(tiles.x), float(tiles.y)) * float(TILE))

		# After dark the dominant light is the nearest fire, not the sun.
		var use_dir: Vector2 = dir
		if night > 0.05:
			var nearest: Dictionary = _nearest_source(srcs, foot.get_center())
			if not nearest.is_empty():
				var away: Vector2 = (foot.get_center() - (nearest["pos"] as Vector2))
				if away.length() > 4.0:
					use_dir = dir.lerp(away.normalized(), night * 0.85).normalized()

		var length: float = lift * len_mul
		ci.draw_colored_polygon(_shadow_hull(foot, use_dir * length), Color(col.r, col.g, col.b, a * 0.55))
		ci.draw_colored_polygon(_shadow_hull(foot, use_dir * length * 0.45), Color(col.r, col.g, col.b, a * 0.62))
		# Contact darkening keeps the building anchored to the ground.
		ci.draw_texture_rect(LcnSpriteFactory.shadow_texture(96),
			Rect2(foot.position - Vector2(6.0, 4.0), foot.size + Vector2(12.0, 10.0)),
			false, Color(col.r, col.g, col.b, a * 0.9))

	if not draw_agents:
		return
	for ag: Dictionary in model.agents(alpha):
		var p: Vector2 = ag["pos"]
		if not view_rect.grow(24.0).has_point(p):
			continue
		ci.draw_texture_rect(LcnSpriteFactory.shadow_texture(96),
			Rect2(p - Vector2(7.0, 4.0), Vector2(14.0, 8.0)), false,
			Color(col.r, col.g, col.b, a * 0.8))


static func _shadow_hull(r: Rect2, o: Vector2) -> PackedVector2Array:
	var a := r.position
	var b := Vector2(r.end.x, r.position.y)
	var c := r.end
	var d := Vector2(r.position.x, r.end.y)
	if o.x >= 0.0:
		if o.y >= 0.0:
			return PackedVector2Array([a, b, b + o, c + o, d + o, d])
		return PackedVector2Array([a, a + o, b + o, c + o, c, d])
	if o.y >= 0.0:
		return PackedVector2Array([a, b, c, c + o, d + o, a + o])
	return PackedVector2Array([a + o, b + o, b, c, d, d + o])


func _nearest_source(_srcs_unused: Array[Dictionary], p: Vector2) -> Dictionary:
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
	var srcs: Array[Dictionary] = _srcs

	# Warm pools on the ground. Light2D does the physical lighting; this pass
	# adds the bloomy core that makes a fire feel hot rather than merely bright.
	for s: Dictionary in srcs:
		var pos: Vector2 = s["pos"]
		var radius: float = float(s["radius"]) * 0.8
		if not view_rect.grow(radius).has_point(pos):
			continue
		var intensity: float = float(s["intensity"])
		var flicker: float = 1.0 + sin(SimClock.seconds() * 3.1 + float(s.get("seed", 0)) * 0.37) * 0.055
		var col: Color = LcnPalette.heat_light_color(intensity)
		var strength: float = clampf(0.16 * intensity * energy * flicker, 0.0, 0.85)
		ci.draw_texture_rect(_glow_tex,
			Rect2(pos - Vector2(radius, radius), Vector2(radius * 2.0, radius * 2.0)),
			false, Color(col.r, col.g, col.b, strength))

	# Rim light: the sprite redrawn offset toward its light. The main pass then
	# covers everything but the lit crescent.
	for entry: Dictionary in _vis:
		var b: Dictionary = entry["b"]
		if _frozen.has(int(b["id"])):
			continue
		var sp: Dictionary = entry["sp"]
		var centre: Vector2 = b["centre"]
		var src: Dictionary = _nearest_source(srcs, centre)
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
		ci.draw_texture_rect(sp["texture"],
			Rect2(rect.position + toward * 2.0 - Vector2(0.0, 1.0), rect.size), false,
			Color(col2.r, col2.g, col2.b, clampf(rim * energy * 0.55, 0.0, 0.7)))


# --- pass 3: sprites ---------------------------------------------------------

func _draw_main(ci: CanvasItem) -> void:
	var entries: Array[Dictionary] = []
	for entry: Dictionary in _vis:
		var b: Dictionary = entry["b"]
		var cell: Vector2i = b["cell"]
		var tiles: Vector2i = b["tiles"]
		entries.append({"y": float(cell.y + tiles.y) * float(TILE), "b": b,
			"rect": entry["rect"], "sp": entry["sp"]})

	_visible_agents = 0
	if draw_agents:
		for ag: Dictionary in model.agents(alpha):
			var p: Vector2 = ag["pos"]
			if not view_rect.grow(32.0).has_point(p):
				continue
			_visible_agents += 1
			entries.append({"y": p.y, "a": ag})

	entries.sort_custom(func(x: Dictionary, y: Dictionary) -> bool:
		return float(x["y"]) < float(y["y"]))

	var frost: Color = LcnPalette.ICE_BLUE
	for e: Dictionary in entries:
		if e.has("b"):
			var b2: Dictionary = e["b"]
			var sp: Dictionary = e["sp"]
			var rect: Rect2 = e["rect"]
			var state2: int = int(b2.get("state", LcnWorldModel.BUILD_OPERATIONAL))
			var tint := Color(1, 1, 1, 1)
			if _frozen.has(int(b2["id"])) or state2 == LcnWorldModel.BUILD_FROZEN:
				tint = Color(frost.r * 0.85 + 0.15, frost.g * 0.85 + 0.15, frost.b * 0.9 + 0.1, 1.0)
			elif state2 == LcnWorldModel.BUILD_DISABLED:
				tint = Color(0.62, 0.66, 0.74, 1.0)
			elif state2 == LcnWorldModel.BUILD_DECONSTRUCTING:
				tint = Color(1.0, 0.72, 0.62, 0.75)
			if state2 == LcnWorldModel.BUILD_GHOST or state2 == LcnWorldModel.BUILD_CONSTRUCTING:
				_draw_site(ci, b2, rect, state2)
			else:
				ci.draw_texture_rect(sp["texture"], rect, false, tint)
				if b2["arch"] == &"turret":
					_draw_barrel(ci, b2, rect)
		else:
			var ag2: Dictionary = e["a"]
			var s: Dictionary = sprites.agent(ag2["kind"])
			var tex: ImageTexture = s["texture"]
			var pos: Vector2 = (ag2["pos"] as Vector2) + (s["offset"] as Vector2)
			# Sub-pixel snapping keeps 14px figures from shimmering as they walk.
			pos = Vector2(round(pos.x), round(pos.y))
			ci.draw_texture_rect(tex, Rect2(pos, tex.get_size()), false)


## A planned or half-built structure: surveyed footprint, scaffold uprights and
## a ghost of the finished silhouette. The player should always be able to read
## what is coming and how far along it is.
func _draw_site(ci: CanvasItem, b: Dictionary, rect: Rect2, state: int) -> void:
	var tiles: Vector2i = b["tiles"]
	var cell: Vector2i = b["cell"]
	var foot := Rect2(
		Vector2(float(cell.x), float(cell.y)) * float(TILE),
		Vector2(float(tiles.x), float(tiles.y)) * float(TILE))
	var accent: Color = LcnPalette.CAUTION if state == LcnWorldModel.BUILD_CONSTRUCTING else LcnPalette.STEEL_LIGHT
	var sp: Dictionary = sprites.building(b["arch"])
	ci.draw_texture_rect(sp["texture"], rect, false,
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


func _draw_barrel(ci: CanvasItem, b: Dictionary, rect: Rect2) -> void:
	var bar: Dictionary = sprites.turret_barrel()
	var tex: ImageTexture = bar["texture"]
	var pivot: Vector2 = bar["pivot"]
	# Guns face away from the city centre; a defensive line should look aimed.
	var centre: Vector2 = b["centre"]
	var world_mid := Vector2(model.world_size()) * float(TILE) * 0.5
	var away: Vector2 = centre - world_mid
	var ang: float = away.angle() if away.length() > 1.0 else 0.0
	ang += sin(SimClock.seconds() * 0.4 + float(b["seed"]) * 0.11) * 0.22
	var mount: Vector2 = rect.position + Vector2(rect.size.x * 0.5, rect.size.y - 46.0 * float(b.get("scale", 1.0)))
	var bscale: float = float(b.get("scale", 1.0))
	ci.draw_set_transform(mount, ang, Vector2(bscale, bscale))
	ci.draw_texture_rect(tex, Rect2(-pivot, tex.get_size()), false)
	ci.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
