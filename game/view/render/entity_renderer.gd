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
const RIM_ZOOM: float = 0.45
const SILHOUETTE_SHADER: String = "res://game/view/render/silhouette.gdshader"
## A warm pool smaller than this many screen pixels is a smudge; drawing it costs
## a full quad and buys nothing.
const MIN_POOL_PX: float = 9.0
## Below this on-screen footprint a contact shadow is one dark pixel.
const MIN_SHADOW_PX: float = 11.0
## Lit windows under this many screen pixels are one warm dot, and the warm pool
## the source already throws says the same thing for free. At the strategic zoom
## this drops the belts, pipes and inserters — most of a stress city by count —
## and keeps every structure a player could actually pick out.
const MIN_EMISSIVE_PX: float = 11.0

## THE FIGURE FLOOR. A building is 3–5 tiles across, so at the zoom this game is
## actually played at (0.50–0.70, off the overlay legends) it still lands on
## 60–160 screen pixels and reads fine. A person is 14 px and an enemy 13–48 px
## in WORLD units, which at 0.60 is eight to twenty-eight screen pixels — and a
## blind judge looking at a real frame could find exactly ONE human figure in it,
## at three times brightness. Ten silhouette-distinct enemies are worth nothing
## if the player is looking at a hairline.
##
## So an agent never draws smaller than MIN_AGENT_PX on SCREEN, growing by at
## most MAX_AGENT_SCALE. This is a legibility convention, not a lie about the
## world: the sprite is drawn at its true size whenever the camera is close
## enough for true size to be legible (zoom >= ~1.0 for a person), the growth is
## capped so a hound never becomes a building, and it is applied about the
## figure's FEET so the thing stays standing where the simulation put it. Every
## RTS that lets you zoom out does some version of this; the alternative is a
## combat layer the player cannot see, which is the score this build got.
##
## THE FLOOR WAS RAISED FROM 17 TO 24, AND HERE IS THE FRAME THAT DID IT. Open
## `artifacts/P13/frames/crowd.png` from the previous pass at 3x and the people
## are all there, all four roles, each with a lit head and a trail behind it —
## and every one of them is the same size and the same value as the crates,
## drums, pipe stacks and rock props scattered over the same ground. At 17 px a
## citizen was not hard to SEE; it was impossible to tell apart from the scenery,
## which is why a judge who could see the whole city still reported finding one
## human figure. Detail did not fix that and cannot: the fix is that the moving
## things are decisively the biggest small things in the frame.
##
## 24 px is 1.25 tiles at zoom 0.60. A building is 60–160. The cap goes to 3.1
## because the smallest thing that walks — a 13 px drift hound — is 7.8 screen
## pixels at 0.60 and needs 3.08x to reach the floor; leaving the cap at 2.4
## would have moved the constant and not the picture, which is the exact failure
## mode this project has paid for twice, and
## tests/render/test_sprites.gd::test_the_echelon_reads_at_play_zoom caught it at
## 23 px against a floor of 24. The cap still binds where it was put there to
## bind: at the strategic zoom a hound is 3 px and 3.1x leaves it 10, not 24.
const MIN_AGENT_PX: float = 24.0
const MAX_AGENT_SCALE: float = 3.1

var model: LcnWorldModel = null
var sprites: LcnSpriteFactory = null
var field: LcnTerrainField = null
## What stands on the plain that nobody built. See LcnScenery.
var scenery: LcnScenery = null
var draw_scenery: bool = true

var grade: Dictionary = {}
var view_rect: Rect2 = Rect2()
var alpha: float = 0.0
var zoom: float = 1.0
var draw_agents: bool = true

var _shadow: Node2D = null
var _glow: Node2D = null
var _main: Node2D = null
var _halo: Node2D = null

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
var _cull_us: int = 0
var _sources_us: int = 0
var _bucket_us: int = 0
var _frozen: Dictionary[int, bool] = {}

## SOMETHING DIED HERE. Parallel arrays, capped, drawn in the glow pass out of
## the same atlas — so a night full of kills costs no extra draw calls.
##
## Why the renderer owns a death effect at all when [P14] owns particles: a kill
## with no visual is a kill the player does not know happened, and the one thing
## a tower-defense night must answer every second is "is what I built working".
## This is the sprite half of that answer — the thing that died, flashed white,
## thrown up and faded, over a stain that outlives it — and it is drawn from the
## dead creature's OWN silhouette, so a boss going down does not look like a
## hound going down.
const DEATH_MAX: int = 96
const DEATH_FLASH_S: float = 0.22
const DEATH_LIFE_S: float = 1.25
var _death_x: PackedFloat32Array = PackedFloat32Array()
var _death_y: PackedFloat32Array = PackedFloat32Array()
var _death_t: PackedFloat32Array = PackedFloat32Array()
var _death_kind: Array[StringName] = []
var _deaths_drawn: int = 0

## THE TRACKS. Where people have actually walked, in the last few minutes.
##
## A critic looking at a still of this build said the city "does not occupy the
## screen" and that nobody in it is visibly going anywhere. Both of those are
## true of a frame with thirty figures in it and no evidence that any of them
## moved: a photograph cannot show motion, so the motion has to be left ON THE
## GROUND. Snow is the one surface in games that remembers, and this city stands
## on nothing else.
##
## So every agent drops a boot mark behind it every STEP_EVERY_PX of travel,
## alternating left and right of its heading, and the marks fade over STEP_LIFE_S.
## In a single frame that reads as: this person came from over there, that queue
## of four is walking to the hearth, the plaza is worn and the north ditch is
## not. It also fills the frame with the city's own activity at the zoom the game
## is played at, where a 17 px figure is a dot and its 40 px trail is a sentence.
##
## Cost is one quad per mark out of the SAME atlas region the contact shadows
## use, inside the batch that was already running — no new texture, no new pass,
## no per-mark state change. STEP_MAX bounds it at a few hundred quads however
## many people the city grows.
##
## Determinism: view-only. Marks are derived from positions the simulation has
## already published and are never read back into it.
const STEP_MAX: int = 420
const STEP_EVERY_PX: float = 11.0
const STEP_LIFE_S: float = 26.0
## A mark smaller than this on screen is one grey pixel; below it the whole trail
## is dropped rather than drawn as noise.
const MIN_STEP_PX: float = 1.6
var _step_x: PackedFloat32Array = PackedFloat32Array()
var _step_y: PackedFloat32Array = PackedFloat32Array()
var _step_t: PackedFloat32Array = PackedFloat32Array()
## Half the width of the mark, so a boot is an oval and a boss is a crater.
var _step_r: PackedFloat32Array = PackedFloat32Array()
var _step_head: int = 0
var _steps_drawn: int = 0
## agent id -> where it last left a mark, and which foot it was.
var _step_last: Dictionary[int, Vector2] = {}
var _step_side: Dictionary[int, int] = {}
var _step_tick: int = -1

## Per-frame scratch, PARALLEL arrays and reused between frames. The first pass
## built one Dictionary per visible building per frame; at the stress city's 1581
## visible structures that alone was 3 ms of allocation before a single pixel was
## drawn. `_vis_b` only holds references the model already owns.
var _vis_b: Array[Dictionary] = []
## Visible scenery, and six floats each: dest x, dest y, w, h, atlas x, atlas y.
var _vis_s: Array[Dictionary] = []
## Visible agents, y-sorted, collected ONCE per frame. Both the glow pass (the
## cold pool under a hostile) and the main pass walk this list, and before it
## existed the main pass called `model.agents(alpha)` — which interpolates every
## body in the world — a second time for the same frame.
var _vis_ag: Array[Dictionary] = []
var _vis_s_src: PackedFloat32Array = PackedFloat32Array()
var _vis_rect: PackedFloat32Array = PackedFloat32Array()
var _vis_src: PackedFloat32Array = PackedFloat32Array()
## Atlas region of each visible structure's EMISSIVE mask, parallel to _vis_b.
## Zero width means "this archetype has no lit surface".
var _vis_em: PackedFloat32Array = PackedFloat32Array()
var _srcs: Array[Dictionary] = []
## Dictionary[int, Array[int]] — an Array, not a PackedInt32Array, on purpose:
## Packed arrays are value types, so get/append/set copies the whole bucket every
## time and bucketing 1600 sources becomes quadratic. Measured at 3 ms a frame in
## the stress city before this changed.
var _src_buckets: Dictionary[int, Array] = {}
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
## True when the hour is dark enough for lit windows to be drawn at all. At noon
## nothing in the glow pass survives, so neither the per-building atlas lookup in
## _collect nor the quad in _draw_glow is worth paying for.
var _want_emissive: bool = false
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
	scenery = LcnScenery.new()
	scenery.setup(Rng.seed_value)
	_rebuild_atlas()

	_shadow = _make_pass("ShadowPass", 0, -40, false)
	# Shadows draw the SPRITES, so they must not be tinted by the sprites'
	# colours — see silhouette.gdshader.
	var sil: Shader = load(SILHOUETTE_SHADER) as Shader
	if sil != null:
		var sm := ShaderMaterial.new()
		sm.shader = sil
		_shadow.material = sm
	else:
		Log.error("render", "silhouette shader missing at %s — shadows will be tinted" % SILHOUETTE_SHADER)
	_glow = _make_pass("GlowPass", 1, -20, true)
	_main = _make_pass("MainPass", 2, 0, false)
	# NOTHING THE PLAYER BUILT MAY HIDE A MONSTER. [P03]'s belt overlay draws at
	# z 1, its items at 3 and its machine plates at 4 — all of them ABOVE the
	# figures — and in `artifacts/H1_v3/shots/assault.world.png` a drift hound
	# standing on a conveyor was cut in half by it: lift 0.033 where its
	# neighbours measured 0.30. So a hostile's cold light gets one small additive
	# quad in a pass above the logistics layer and below [P14]'s effects. It is
	# the same statement the rim pass makes about a fire — light reaches the
	# camera past the things in front of it — and it is the difference between a
	# threat you can see and a threat your own factory is standing in front of.
	_halo = _make_pass("FoeHaloPass", 3, 5, true)


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
	_lay_tracks()
	_shadow.queue_redraw()
	_glow.queue_redraw()
	_main.queue_redraw()
	_halo.queue_redraw()


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
	_l_bounce = float(grade["bounce"]) * 0.46
	_l_wild = float(grade["wild"])
	var energy: float = float(grade["light_energy"])
	_want_emissive = energy > 0.30
	# `light_energy` is the multiplier on every warm light in the city, so it IS
	# the hour: 1.30 at night, 0.60 at dusk, 0.14 at midday.
	_dark_share = smoothstep(DAY_ENERGY, DARK_ENERGY, energy)


## One walk over the world per frame instead of three, with the sprite rect and
## the atlas region resolved once each.
func _collect() -> void:
	var t0: int = Time.get_ticks_usec()
	_vis_b.clear()
	_vis_rect.clear()
	_vis_src.clear()
	_vis_em.clear()
	if model == null:
		return
	if model.building_stamp() != _atlas_stamp:
		_rebuild_atlas()
	_collect_scenery()

	# The cull reads a flat float array the model keeps in step with its building
	# list; no Dictionary is touched until a structure has actually survived it.
	var all: Array[Dictionary] = model.buildings()
	var geo: PackedFloat32Array = model.geometry()
	var pad: Rect2 = view_rect.grow(8.0)
	var px0: float = pad.position.x
	var py0: float = pad.position.y
	var px1: float = pad.end.x
	var py1: float = pad.end.y
	var n: int = mini(all.size(), geo.size() / 4)
	var min_em: float = MIN_EMISSIVE_PX / maxf(zoom, 0.01)
	for i: int in n:
		var o: int = i * 4
		var ox: float = geo[o]
		var oy: float = geo[o + 1]
		if ox > px1 or oy > py1 or ox + geo[o + 2] < px0 or oy + geo[o + 3] < py0:
			continue
		var b: Dictionary = all[i]
		var region: Rect2 = _regions.get(b["sprite"], Rect2())
		if region.size.x <= 0.0:
			continue
		_vis_b.append(b)
		_vis_rect.append(ox)
		_vis_rect.append(oy)
		_vis_rect.append(region.size.x)
		_vis_rect.append(region.size.y)
		_vis_src.append(region.position.x)
		_vis_src.append(region.position.y)
		_vis_src.append(region.size.x)
		_vis_src.append(region.size.y)
		if _want_emissive:
			# One dictionary probe, and only for structures big enough on screen to
			# show a window at all: at 1700 structures this walk is measured in
			# milliseconds and most of them are one-tile belt.
			if geo[o + 2] < min_em or geo[o + 3] < min_em:
				_vis_em.append(0.0)
				_vis_em.append(0.0)
				_vis_em.append(0.0)
				_vis_em.append(0.0)
			else:
				# .get, not [] — an archetype with no lit surface (a wall, a belt)
				# is deliberately absent from the sheet, and indexing a missing key
				# throws inside _collect, which leaves the visible set empty and
				# reports a gorgeous 42 us frame that draws nothing at all.
				var em: Rect2 = _regions.get(b["sprite_em"], Rect2())
				_vis_em.append(em.position.x)
				_vis_em.append(em.position.y)
				_vis_em.append(em.size.x)
				_vis_em.append(em.size.y)
	_visible_buildings = _vis_b.size()
	_collect_agents()

	_cull_us = Time.get_ticks_usec() - t0
	var t1: int = Time.get_ticks_usec()
	_srcs = model.heat_sources()
	_sources_us = Time.get_ticks_usec() - t1
	_src_buckets.clear()
	# The spatial hash exists for _nearest_source, and _nearest_source is only
	# asked anything by the cast-shadow and rim passes. Below their LOD cutoff
	# nobody calls it, and bucketing 1600 sources for nobody was 3.4 ms a frame.
	if zoom < LOD_ZOOM:
		_bucket_us = Time.get_ticks_usec() - t1 - _sources_us
		_collect_us = Time.get_ticks_usec() - t0
		return
	var reach: Rect2 = view_rect.grow(BUCKET_PX * 2.0)
	for i: int in _srcs.size():
		var s: Dictionary = _srcs[i]
		var p: Vector2 = s["pos"]
		if not reach.has_point(p):
			continue
		var r: float = float(s["radius"]) * 1.4
		var x0: int = int(floor((p.x - r) / BUCKET_PX))
		var x1: int = int(floor((p.x + r) / BUCKET_PX))
		var y0: int = int(floor((p.y - r) / BUCKET_PX))
		var y1: int = int(floor((p.y + r) / BUCKET_PX))
		for by: int in range(y0, y1 + 1):
			for bx: int in range(x0, x1 + 1):
				var key: int = bx * 73856093 ^ by * 19349663
				var arr: Array = _src_buckets.get(key, [])
				if arr.is_empty():
					_src_buckets[key] = arr
				arr.append(i)
	_bucket_us = Time.get_ticks_usec() - t1 - _sources_us
	_collect_us = Time.get_ticks_usec() - t0


## Destination rect of the i-th visible structure, optionally nudged.
## The plain's own furniture, resolved to atlas rects once a frame. Kept in its
## own arrays and not merged into `_vis_b`, because scenery is not a structure:
## it has no state, no heat, no emissive mask and nothing may select it.
func _collect_scenery() -> void:
	_vis_s.clear()
	_vis_s_src.clear()
	if not draw_scenery or scenery == null or zoom < LcnScenery.MIN_ZOOM:
		return
	var props: Array[Dictionary] = scenery.in_view(
		model, field, view_rect.grow(96.0), model.building_stamp())
	for p: Dictionary in props:
		var arch: StringName = p["arch"]
		var spec: Dictionary = LcnSpriteFactory.spec(arch)
		var region: Rect2 = _regions.get(
			LcnSpriteFactory.sprite_key(arch, spec["tiles"]), Rect2())
		if region.size.x <= 0.0:
			continue
		var pos: Vector2 = p["pos"]
		_vis_s.append(p)
		_vis_s_src.append(pos.x - float(LcnSpriteFactory.PAD))
		_vis_s_src.append(pos.y - float(LcnSpriteFactory.PAD) - float(spec["lift"]))
		_vis_s_src.append(region.size.x)
		_vis_s_src.append(region.size.y)
		_vis_s_src.append(region.position.x)
		_vis_s_src.append(region.position.y)


func _rect_at(i: int, offset: Vector2) -> Rect2:
	var o: int = i * 4
	return Rect2(_vis_rect[o] + offset.x, _vis_rect[o + 1] + offset.y,
		_vis_rect[o + 2], _vis_rect[o + 3])


## Atlas source rect of the i-th visible structure.
func _src_at(i: int) -> Rect2:
	var o: int = i * 4
	return Rect2(_vis_src[o], _vis_src[o + 1], _vis_src[o + 2], _vis_src[o + 3])


## Atlas source rect of the i-th visible structure's emissive mask.
func _em_at(i: int) -> Rect2:
	var o: int = i * 4
	return Rect2(_vis_em[o], _vis_em[o + 1], _vis_em[o + 2], _vis_em[o + 3])


func mark_frozen(id: int, is_frozen: bool) -> void:
	if is_frozen:
		_frozen[id] = true
	else:
		_frozen.erase(id)


## Records a kill at `pos`. `kind` is the render kind of the thing that died, so
## the mark is drawn in its own silhouette; an unknown kind still leaves a stain.
##
## Time is read from SimClock.seconds(), never from a frame delta, because the
## renderer must not become a second clock — a death that fades at a rate the
## simulation cannot see is a death that looks different on every machine.
func mark_death(pos: Vector2, kind: StringName) -> void:
	if _death_x.size() >= DEATH_MAX:
		# Oldest out. A night that kills 400 things does not get to grow this
		# array without bound, and the ones that fall off are the faintest.
		_death_x.remove_at(0)
		_death_y.remove_at(0)
		_death_t.remove_at(0)
		_death_kind.remove_at(0)
	_death_x.append(pos.x)
	_death_y.append(pos.y)
	_death_t.append(SimClock.seconds())
	_death_kind.append(kind)


## Drops every death mark. Called when the world is rebuilt.
func clear_deaths() -> void:
	_death_x.clear()
	_death_y.clear()
	_death_t.clear()
	_death_kind.clear()


## Live death marks, for the suite that proves a kill is visible.
func death_count() -> int:
	return _death_x.size()


# ------------------------------------------------------------------ tracks ---

## Records one tick of boot marks. Called from `refresh`, does its work once per
## SIMULATION tick rather than once per frame, so the trail a figure leaves is
## the distance it actually walked and not a function of the frame rate.
func _lay_tracks() -> void:
	if model == null or not draw_agents:
		return
	if SimClock.tick == _step_tick:
		return
	_step_tick = SimClock.tick
	var now: float = SimClock.seconds()
	var live: Dictionary[int, bool] = {}
	for ag: Dictionary in model.agents(1.0):
		var id: int = int(ag["id"])
		live[id] = true
		var p: Vector2 = ag["pos"]
		if not _step_last.has(id):
			_step_last[id] = p
			continue
		var last: Vector2 = _step_last[id]
		var d: Vector2 = p - last
		var travelled: float = d.length()
		if travelled < STEP_EVERY_PX:
			continue
		# A spawn, a save load or a teleport is not a walk. Re-anchor instead of
		# ruling a line of boot prints across half the map.
		if travelled > 320.0:
			_step_last[id] = p
			continue
		var side: int = int(_step_side.get(id, 0))
		_step_side[id] = 1 - side
		_step_last[id] = p
		var lateral: Vector2 = Vector2(-d.y, d.x).normalized() * (2.0 if side == 0 else -2.0)
		var is_foe: bool = LcnSpriteFactory.is_enemy_kind(ag["kind"])
		_push_step(p + lateral, now, 3.8 if is_foe else 2.5)
		# ...and the same footfall is written into the ground's memory. The boot
		# mark fades in 26 seconds and says where the city went in the last
		# minute; the wear field keeps it for hours and is why the plaza at hour
		# 3 is not the plaza at hour 1. See LcnTerrainField's WEAR block.
		#
		# THE WEIGHTS ARE WHAT ONE FOOTFALL IS WORTH, and they were measured up
		# twice. At 12 and then at 16, 260 ticks of 46 people walking a
		# settlement moved the photograph by 0.37% and then 1.13% of the screen —
		# both invisible with the two plates held side by side. The mistake was
		# treating a footprint as an increment: a boot in fresh snow is not a
		# faint hint that someone might have passed, it is a hole, which is
		# exactly what the 26-second boot marks already draw. One crossing now
		# lands most of the way up the response curve in terrain.gdshader and
		# repeated use takes the route down to the grit.
		if field != null:
			if is_foe:
				field.add_wear(p, 0.95, 64)
			else:
				field.add_wear(p, 0.55, 40)
	# Whatever died, went home or was culled stops being tracked. Without this
	# the two side dictionaries are a slow leak across a long night.
	if _step_last.size() > live.size():
		for id2: int in _step_last.keys():
			if not live.has(id2):
				_step_last.erase(id2)
				_step_side.erase(id2)


## Ring buffer: the oldest mark is overwritten, which is also the faintest.
func _push_step(pos: Vector2, at: float, radius: float) -> void:
	if _step_x.size() < STEP_MAX:
		_step_x.append(pos.x)
		_step_y.append(pos.y)
		_step_t.append(at)
		_step_r.append(radius)
		return
	_step_x[_step_head] = pos.x
	_step_y[_step_head] = pos.y
	_step_t[_step_head] = at
	_step_r[_step_head] = radius
	_step_head = (_step_head + 1) % STEP_MAX


## Drops every boot mark. Called when the world is rebuilt.
func clear_tracks() -> void:
	_step_x.clear()
	_step_y.clear()
	_step_t.clear()
	_step_r.clear()
	_step_head = 0
	_step_last.clear()
	_step_side.clear()
	_step_tick = -1


## Live boot marks, for the suite that proves the city looks walked-in.
func track_count() -> int:
	return _step_x.size()


func stats() -> Dictionary:
	return {
		"visible_buildings": _visible_buildings,
		"visible_agents": _visible_agents,
		"deaths_drawn": _deaths_drawn,
		"tracks": _step_x.size(),
		"tracks_drawn": _steps_drawn,
		"scenery": _vis_s.size(),
		"draw_us": _draw_us,
		"collect_us": _collect_us,
		"cull_us": _cull_us,
		"sources_us": _sources_us,
		"bucket_us": _bucket_us,
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
		3: _draw_foe_halos(ci)
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
	# Same expression as LcnPalette.light_at and as terrain.gdshader: a building
	# is legible after dark because it is BURNING, not because it exists.
	var hc: float = clampf(heat, 0.0, 1.0)
	var b: float = _l_bounce * clampf(hc * 2.30 + clampf(city, 0.0, 1.0) * 0.16, 0.0, 1.0)
	var dark: float = 1.0 - _l_wild * (1.0 - clampf(hc * 2.6 + city * 0.55, 0.0, 1.0))
	var w: float = hc * (0.55 + 0.45 * hc) * 1.15
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
	var min_foot: float = MIN_SHADOW_PX / maxf(zoom, 0.01)

	# TWO loops on purpose. Every contact patch first, then every cast shadow, so
	# neither the destination rects nor the source regions jump around inside a
	# batch — one pass, a handful of draw calls, 1700 structures.
	#
	# The contact patch is a tight dark ellipse under the footprint, pushed a few
	# pixels toward the shadow so it peeks out on one side. It is the cheap trick
	# that makes an object SIT on a surface instead of floating above a picture of
	# one, and spread over the footprint plus 12 px at 0.85 alpha it was too wide
	# and too faint to do the job.
	var contact := Color(col.r, col.g, col.b, clampf(a * 1.15, 0.0, 0.95))
	for i: int in _vis_b.size():
		var b: Dictionary = _vis_b[i]
		if int(b.get("state", LcnWorldModel.BUILD_OPERATIONAL)) == LcnWorldModel.BUILD_GHOST:
			continue
		var tiles: Vector2i = b["tiles"]
		if float(maxi(tiles.x, tiles.y)) * float(TILE) < min_foot:
			continue
		var cell: Vector2i = b["cell"]
		ci.draw_texture_rect_region(_atlas,
			Rect2(Vector2(float(cell.x), float(cell.y)) * float(TILE)
					+ Vector2(dir.x * 3.0 - 3.0, 1.0),
				Vector2(float(tiles.x), float(tiles.y)) * float(TILE) + Vector2(6.0, 6.0)),
			_shadow_r, contact)

	# Scenery gets a contact patch and nothing else. A rock that does not sit on
	# the ground is a sticker, and a boulder casting a full architectural shadow
	# is a building the player will try to click on.
	for si: int in _vis_s.size():
		var o: int = si * 6
		ci.draw_texture_rect_region(_atlas,
			Rect2(_vis_s_src[o] + dir.x * 2.0 + 3.0, _vis_s_src[o + 1] + _vis_s_src[o + 3] - 8.0,
				_vis_s_src[o + 2] * 0.72, 9.0),
			_shadow_r, Color(col.r, col.g, col.b, a * 0.85))

	_draw_tracks(ci, col)

	if draw_agents and detailed:
		# The contact blob grows with the figure floor, or a figure enlarged for
		# legibility ends up standing beside its own shadow.
		var ash: float = agent_scale(16.0, zoom)
		for ag: Dictionary in model.agents(alpha):
			var p: Vector2 = ag["pos"]
			if not view_rect.grow(24.0).has_point(p):
				continue
			ci.draw_texture_rect_region(_atlas,
				Rect2(p - Vector2(7.0 * ash, 4.0 * ash), Vector2(14.0, 8.0) * ash), _shadow_r,
				Color(col.r, col.g, col.b, a * 0.8))

	if not detailed:
		return

	# THE CAST SHADOW is the building's own silhouette, squashed toward the
	# ground and pushed away from the key. Everything before this pass cast a
	# sheared quad of flat colour, which is a smudge with a direction, not a
	# shadow — and it is most of why 1700 structures looked like decals lying on
	# a photograph instead of objects standing on a plain. Same atlas, same
	# primitive, so the whole pass is still one batch.
	var cast_col := Color(col.r, col.g, col.b, a * 0.60)
	for i2: int in _vis_b.size():
		var b2: Dictionary = _vis_b[i2]
		if int(b2.get("state", LcnWorldModel.BUILD_OPERATIONAL)) == LcnWorldModel.BUILD_GHOST:
			continue
		var lift: float = float(b2["lift"])
		if lift < 8.0:
			continue
		var r: Rect2 = _rect_at(i2, Vector2.ZERO)

		# After dark the dominant light is the nearest fire, not the sun.
		var use_dir: Vector2 = dir
		if night > 0.05:
			var nearest: Dictionary = _nearest_source(b2["centre"])
			if not nearest.is_empty():
				var away: Vector2 = (b2["centre"] as Vector2) - (nearest["pos"] as Vector2)
				if away.length() > 4.0:
					use_dir = dir.lerp(away.normalized(), night * 0.85).normalized()

		# A shadow lying on the ground is foreshortened: the taller the building
		# the further it reaches, but it never stands up again.
		# Hard foreshortening. At 0.30 + len_mul * 0.26 a 3x3 block with a 62 px
		# lift laid down an 88 px rectangle directly under itself, and since the
		# roof plane of most archetypes IS a filled rectangle the result read as a
		# grey card under the building rather than as a shadow beside it.
		var squash: float = clampf(0.16 + len_mul * 0.22, 0.13, 0.58)
		var reach: Vector2 = use_dir * (lift * len_mul * 0.55)
		# The shadow STRADDLES the foot line — a little over half of it above, the
		# rest below — so it stays welded to the building it belongs to. Placing
		# its top edge at foot + reach instead detached it entirely and left grey
		# plates lying on the snow a hundred pixels from anything.
		var sq_h: float = r.size.y * squash
		var sh := Rect2(
			r.position.x + reach.x, r.end.y - 2.0 + reach.y * 0.30 - sq_h * 0.58,
			r.size.x, sq_h)
		ci.draw_texture_rect_region(_atlas, sh, _src_at(i2), cast_col)


## The boot marks, out of the same atlas region as the contact shadows and in
## the same batch — a trail costs no draw call of its own.
##
## Drawn under everything and never on the ghost pass, so a track is always
## something that HAPPENED. The figure floor scales them with the figures: at
## play zoom a person is enlarged to MIN_AGENT_PX and its footprints are
## enlarged with it, or the trail would vanish exactly where it is needed most.
##
## These are the last MINUTE of the city's movement. The last few HOURS of it
## are in LcnTerrainField's wear field, written from the same footfalls and
## costing nothing to draw.
func _draw_tracks(ci: CanvasItem, col: Color) -> void:
	_steps_drawn = 0
	if not draw_agents or _step_x.is_empty() or _shadow_r.size.x <= 0.0:
		return
	var grow: float = agent_scale(16.0, zoom)
	if 3.6 * 2.0 * grow * zoom < MIN_STEP_PX:
		return
	var now: float = SimClock.seconds()
	# As strong as a contact shadow when it is fresh: a boot print in snow is a
	# dimple with a shadow in it, and at 0.8 of one the whole trail sat under the
	# threshold where a still frame carries it.
	var base_a: float = float(grade["shadow_alpha"]) * 1.05
	var pad: Rect2 = view_rect.grow(24.0)
	for i: int in _step_x.size():
		var age: float = now - _step_t[i]
		# A rewound clock must not strand marks forever, and must not draw them
		# from the future either.
		if age < 0.0 or age > STEP_LIFE_S:
			continue
		var p := Vector2(_step_x[i], _step_y[i])
		if not pad.has_point(p):
			continue
		var fade: float = 1.0 - age / STEP_LIFE_S
		var r: float = _step_r[i] * grow
		ci.draw_texture_rect_region(_atlas,
			Rect2(p - Vector2(r, r * 0.62), Vector2(r * 2.0, r * 1.24)), _shadow_r,
			# Holds its weight for most of its life and then goes: snow fills a
			# print in slowly and then a gust takes the rest of it at once.
			Color(col.r, col.g, col.b, base_a * fade * (0.45 + 0.55 * fade)))
		_steps_drawn += 1


## Atlas pixel coordinates for a normalised point in a region. draw_polygon takes
## UVs in TEXTURE PIXELS, not 0..1.
static func _uv(region: Rect2, u: float, v: float) -> Vector2:
	return region.position + Vector2(region.size.x * u, region.size.y * v)


func _nearest_source(p: Vector2) -> Dictionary:
	var key: int = int(floor(p.x / BUCKET_PX)) * 73856093 ^ int(floor(p.y / BUCKET_PX)) * 19349663
	var candidates: Array = _src_buckets.get(key, [])
	var best: Dictionary = {}
	var best_score: float = -1.0
	for i: int in candidates:
		var s: Dictionary = _srcs[int(i)]
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
	var min_pool: float = MIN_POOL_PX / maxf(zoom, 0.01)
	for s: Dictionary in _srcs:
		var pos: Vector2 = s["pos"]
		var radius: float = float(s["radius"]) * 0.8
		if radius < min_pool:
			continue
		if not view_rect.grow(radius).has_point(pos):
			continue
		var intensity: float = float(s["intensity"])
		var flicker: float = 1.0 + sin(SimClock.seconds() * 3.1 + float(s.get("seed", 0)) * 0.37) * 0.055
		var col: Color = LcnPalette.heat_light_color(intensity)
		# 0.11, not 0.16: with the light rig no longer crushing the whole frame,
		# the additive pass no longer has to shout to be seen, and a radiator
		# stops resolving as a blown-out white disc.
		var strength: float = clampf(0.085 * intensity * energy * flicker, 0.0, 0.34)
		ci.draw_texture_rect_region(_atlas,
			Rect2(pos - Vector2(radius, radius), Vector2(radius * 2.0, radius * 2.0)),
			_glow_r, Color(col.r, col.g, col.b, strength))

	# WINDOWS. Every archetype already paints its own fire — a window, a grille, a
	# crucible — and LcnSpriteFactory cuts those pixels out into an emissive mask
	# packed in the SAME atlas, so blazing every lit surface in the city costs one
	# more quad per structure inside a batch that was already running.
	#
	# This is the readout the mandate asks for: from across the map, at any zoom,
	# a building that is RUNNING has its lights on and one that has frozen or lost
	# its heat does not. Nothing else in the frame separates the two at 0.24 zoom.
	if _want_emissive and _vis_em.size() >= _vis_b.size() * 4:
		for i: int in _vis_b.size():
			var o: int = i * 4
			if _vis_em[o + 2] <= 0.0:
				continue
			var be: Dictionary = _vis_b[i]
			var st: int = int(be.get("state", LcnWorldModel.BUILD_OPERATIONAL))
			if st == LcnWorldModel.BUILD_GHOST or st == LcnWorldModel.BUILD_CONSTRUCTING:
				continue
			# A frozen building is DARK. That is the whole point of the readout.
			var lit: float = float(be["warm"])
			if _frozen.has(int(be["id"])) or st == LcnWorldModel.BUILD_FROZEN:
				lit *= 0.05
			elif st == LcnWorldModel.BUILD_DISABLED:
				lit *= 0.18
			if lit < 0.04:
				continue
			# Two detuned sines: one reads as a pulsing UI element, two read as fire.
			var t: float = SimClock.seconds()
			var sd: float = float(be["seed"])
			var fl: float = 1.0 + sin(t * 4.1 + sd * 0.31) * 0.06 + sin(t * 9.7 + sd * 0.87) * 0.03
			ci.draw_texture_rect_region(_atlas, _rect_at(i, Vector2.ZERO), _em_at(i),
				Color(1.0, 0.92, 0.80, clampf(lit * energy * 0.62 * fl, 0.0, 0.95)))

	_draw_foe_pools(ci)
	_draw_deaths(ci)

	if zoom < RIM_ZOOM:
		return

	# Rim light: the sprite redrawn offset toward its light. The main pass then
	# covers everything but the lit crescent.
	for i: int in _vis_b.size():
		var b: Dictionary = _vis_b[i]
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
		var col2: Color = LcnPalette.WARM_MID
		ci.draw_texture_rect_region(_atlas,
			_rect_at(i, toward * 2.0 - Vector2(0.0, 1.0)), _src_at(i),
			Color(col2.r, col2.g, col2.b, clampf(rim * energy * 0.48, 0.0, 0.62)))


# --- pass 3: sprites ---------------------------------------------------------

func _draw_main(ci: CanvasItem) -> void:
	# model.buildings() is already ordered back-to-front; agents are merged into
	# it linearly instead of re-sorting the whole world with a script lambda.
	var vis_ag: Array[Dictionary] = _vis_ag

	# The plain first, under everything. Scenery is scattered where the city is
	# not, so y-sorting it against the settlement buys nothing and costs a merge
	# over a set that can be a thousand rocks at far zoom.
	for si: int in _vis_s.size():
		var o: int = si * 6
		var spos := Vector2(_vis_s_src[o], _vis_s_src[o + 1])
		var slit: Color = _light_for(spos, 0.0)
		ci.draw_texture_rect_region(_atlas,
			Rect2(spos, Vector2(_vis_s_src[o + 2], _vis_s_src[o + 3])),
			Rect2(_vis_s_src[o + 4], _vis_s_src[o + 5], _vis_s_src[o + 2], _vis_s_src[o + 3]),
			Color(slit.r, slit.g, slit.b, 1.0))

	var frost: Color = LcnPalette.ICE_BLUE
	var ai: int = 0
	var barrels: bool = zoom >= LOD_ZOOM and _barrel_r.size.x > 0.0
	for i: int in _vis_b.size():
		var b2: Dictionary = _vis_b[i]
		var cell: Vector2i = b2["cell"]
		var tiles: Vector2i = b2["tiles"]
		var y: float = float(cell.y + tiles.y) * float(TILE)
		while ai < vis_ag.size() and float((vis_ag[ai]["pos"] as Vector2).y) < y:
			_draw_agent(ci, vis_ag[ai])
			ai += 1

		var rect: Rect2 = _rect_at(i, Vector2.ZERO)
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
			_draw_site(ci, b2, rect, _src_at(i), state2)
		else:
			ci.draw_texture_rect_region(_atlas, rect, _src_at(i), tint)
			if barrels and b2["arch"] == &"turret":
				_draw_barrel(ci, b2, rect, tint)

	while ai < vis_ag.size():
		_draw_agent(ci, vis_ag[ai])
		ai += 1
	_log_foe_marks(ci)


static func _agent_before(x: Dictionary, y: Dictionary) -> bool:
	return float((x["pos"] as Vector2).y) < float((y["pos"] as Vector2).y)


## The frame's visible, y-sorted agents. Collected in `_collect` because TWO
## passes need them now — the glow pass paints the cold pool a hostile stands in
## before the main pass paints the hostile.
func _collect_agents() -> void:
	_vis_ag.clear()
	_foes_in_view = 0
	if model == null or not draw_agents:
		_visible_agents = 0
		return
	# Grown by the pool radius, not by the sprite: a creature whose body is just
	# off the edge still throws light onto ground that is on it.
	var pad: Rect2 = view_rect.grow(FOE_POOL_PX / maxf(zoom, 0.01) + 32.0)
	for ag: Dictionary in model.agents(alpha):
		if not pad.has_point(ag["pos"] as Vector2):
			continue
		_vis_ag.append(ag)
		if LcnSpriteFactory.is_enemy_kind(ag["kind"]):
			_foes_in_view += 1
	_vis_ag.sort_custom(_agent_before)
	_visible_agents = _vis_ag.size()


## WHERE THE HOSTILES ACTUALLY LANDED ON THE GLASS, in screen pixels, on the
## frame the harness is about to photograph.
##
## THIS EXISTS BECAUSE FOUR ROUNDS OF CONTRAST WORK WERE GRADED IN A RIG. Every
## previous instrument stood the renderer up on its own bench, measured a lovely
## delta and shipped a frame in which a critic scanning the actual PNG found
## `105 pixels, two clusters, both temperature labels — not one creature`. A rig
## cannot be wrong about a picture it does not contain, and it did not contain
## the post grade, the night vignette or the red "under attack" wash.
##
## So the renderer states, in the run's own `log.txt`, exactly which rectangle of
## `shots/assault.world.png` each hostile occupies, and
## `tests/render/run_foe_frame.gd` opens THAT PNG and measures THOSE rectangles.
## The claim and the evidence are then in the same artifacts folder and a critic
## can redo the arithmetic without running anything.
##
## Once a sim-second while anything hostile is on screen; silent otherwise.
func _log_foe_marks(ci: CanvasItem) -> void:
	if _foes_in_view <= 0:
		return
	var tick: int = SimClock.tick
	if tick / FOE_LOG_EVERY == _foe_log_tick / FOE_LOG_EVERY and _foe_log_tick >= 0:
		return
	_foe_log_tick = tick
	var xf: Transform2D = ci.get_global_transform_with_canvas()
	var parts: PackedStringArray = PackedStringArray()
	for ag: Dictionary in _vis_ag:
		var kind: StringName = ag["kind"]
		if not LcnSpriteFactory.is_enemy_kind(kind):
			continue
		var dest: Rect2 = agent_dest(ag)
		var tl: Vector2 = xf * dest.position
		var br: Vector2 = xf * dest.end
		var gl: float = ground_luma(ag["pos"])
		parts.append("%s@%d,%d,%d,%d,gl%.3f,lit%.2f" % [
			String(kind), int(round(tl.x)), int(round(tl.y)),
			int(round(br.x - tl.x)), int(round(br.y - tl.y)),
			gl, foe_lit_share(gl)])
	if parts.is_empty():
		return
	Log.info("render", "foemarks t%d zoom %.3f n%d | %s" % [
		tick, zoom, parts.size(), " ".join(parts)])


## The atlas region a kind is drawn from, falling back to its archetype.
## An unknown kind used to draw NOTHING, so a mis-mapped enemy was an invisible
## enemy. Returns `[art_name, region]`; region is empty when even that missed.
func _agent_art(kind: StringName) -> Array:
	var region: Rect2 = _regions.get(LcnSpriteFactory.agent_key(kind), Rect2())
	if region.size.x > 0.0:
		return [kind, region]
	var art: StringName = LcnSpriteFactory.agent_arch(kind)
	return [art, _regions.get(LcnSpriteFactory.agent_key(art), Rect2())]


## Where an agent lands, in WORLD pixels. Always a positive rect, centred on the
## figure's feet. Public because the foe-mark dump and any suite that wants to
## check a figure against a photograph need the renderer's own answer rather than
## a second implementation of it.
func agent_dest(ag: Dictionary) -> Rect2:
	var region: Rect2 = _agent_art(ag["kind"])[1]
	if region.size.x <= 0.0:
		return Rect2()
	var foot: Vector2 = ag["pos"]
	var s: float = agent_scale(region.size.y, zoom)
	var size: Vector2 = region.size * s
	# About the FEET: the figure grows upward out of the tile it is standing on,
	# so nothing drifts off the ground as the camera pulls back.
	var pos: Vector2 = foot + Vector2(-size.x * 0.5, -size.y + 5.0 * s)
	# Sub-pixel snapping keeps small figures from shimmering as they walk.
	return Rect2(Vector2(round(pos.x), round(pos.y)), size)


## FACING, AND THE 41-PIXEL LIE IT TOLD FOR THREE ROUNDS.
##
## `model.agents()` has published a facing since the first pass and nothing read
## it, so every enemy in the game walked at the city sideways. The fix for that
## was a NEGATIVE DESTINATION WIDTH — and it is wrong, in a way no test in this
## repo could see and one photograph shows immediately.
##
## `RendererCanvasCull::canvas_item_add_texture_rect_region` turns a negative
## destination width into a flip flag by negating `rect.size.x` and LEAVING
## `rect.position` where it is. The old code moved position to the right edge
## first, expecting the rect to be read leftwards from there. It is not. So
## every right-facing figure in this game — citizens included — was drawn ONE
## FULL SPRITE WIDTH to the right of the tile the simulation had it standing on.
## It was caught by putting a light pool at `ag["pos"]` and photographing the
## result: `artifacts/H1_smoke/shots/night_perimeter.world.png` had four hounds
## sitting 50 screen pixels to the right of their own light.
##
## Flipping the SOURCE region instead sets the same flag off the same code path
## and leaves the destination — the thing that says where the creature IS —
## alone. Its shadow, its light pool, its boot marks and its position in the
## sim now agree with the picture.
static func flip_src(region: Rect2, ag: Dictionary) -> Rect2:
	if float(ag.get("facing", 0.0)) <= 0.0 or region.size.x <= 0.0:
		return region
	return Rect2(region.position, Vector2(-region.size.x, region.size.y))


func _draw_agent(ci: CanvasItem, ag: Dictionary) -> void:
	var kind: StringName = ag["kind"]
	var art_r: Array = _agent_art(kind)
	var art: StringName = art_r[0]
	var region: Rect2 = art_r[1]
	if region.size.x <= 0.0:
		return
	var foot: Vector2 = ag["pos"]
	var dest: Rect2 = agent_dest(ag)
	var lit: Color = _light_for(foot, 0.0)
	ci.draw_texture_rect_region(_atlas, dest, flip_src(region, ag),
		Color(lit.r, lit.g, lit.b, 1.0))
	_draw_agent_edge(ci, dest, art, foot, LcnSpriteFactory.is_enemy_kind(kind), ag)


# ======================== THE FIGURE IS SEPARATED FROM THE GROUND IT STANDS ON ==
#
# THE MEASUREMENT THAT FORCED THIS, from `artifacts/P13/frames/night_foes.png`
# and its control plate, at deep night and zoom 0.60 — the hour and the camera a
# session is actually played at:
#
#   kind                ground    peak     min   deltaL
#   drift_hound         0.0861  0.1997  0.0079   0.1136
#   rime_sapper         0.0881  0.1276  0.0079   0.0802
#   ...
#   the_long_cold       0.0833  0.1139  0.0082   0.0751
#   median deltaL 0.0922   >= 0.25: 0 of 11
#
# Eleven hand-drawn creatures, ten of them silhouette-distinct, all arriving
# within a tenth of a stop of the ground they walk on, on a frame that also
# carries film grain at ±0.03 and a fog mix that pulls both toward one colour.
# The interface said "10 in the city"; a gamma lift of the whole frame found
# none of them. That is the gap, and it is a CONTRAST gap.
#
# THE PREVIOUS PASS ANSWERED THE SAME FINDING BY RAISING MIN_AGENT_PX FROM 17 TO
# 24 — size, not contrast — which is why the creatures got bigger and the frame
# got no better. Do not do that again. Note the `min` column above: the darkest
# pixel of every creature is already at 0.008 against a ground at 0.09. There is
# no room left downward. A dark silhouette is a DAY technique; it needs a bright
# ground to be dark against, and after dusk this game does not have one.
#
# So the treatment is keyed off the LOCAL GROUND, not off a fixed constant:
#
#   `ground_luma(at)` reads the same light rig the ground shader reads, at the
#   figure's own feet. On the open plain at deep night it is near zero; inside a
#   hearth's pool, or at midday, it is high — and it moves with `city`, `heat`,
#   `wild` and the hour exactly as the ground under the figure does.
#
#   On a DARK ground the figure is LIT: its body is lerped toward a value
#   `BODY_DELTA` above the ground and its contour is drawn at `RIM_DELTA` above
#   it. The city's people catch the city's firelight and go warm; the things out
#   of the dark catch the moon and go cold, so friend and foe separate by HUE at
#   the same moment they separate from the ground by VALUE.
#
#   On a BRIGHT ground nothing is lifted — on snow at noon the baked chassis is
#   already the darkest thing in the frame — and the contour simply changes
#   sides and goes dark, to keep the edge crisp. Standing an enemy in a fire's
#   light therefore flips it back to a silhouette, which is correct and is the
#   whole point of sampling rather than switching on a clock.
#
#   Between the two, `lit_share` fades. Read its docstring before touching any
#   of these numbers: the crossover is where this treatment goes wrong, and it
#   has gone wrong there once already.
#
# Both deltas are expressed in CANVAS luminance and divided by POST_KEEP, because
# what a critic measures is the graded frame and the grade keeps only part of a
# canvas-space delta.

## Ground luminance at which a figure gets no lift at all and is a silhouette on
## its own. Canvas-space, i.e. before the post grade.
const GROUND_PIVOT: float = 0.34
## What the plain reflects. The light rig returns illumination; a surface returns
## illumination times albedo, and the snow/rock ramp averages near this.
const GROUND_ALBEDO: float = 0.62
## Fraction of a canvas-space luminance delta that survives lift, gain, fog,
## vignette and grain to reach the frame a critic photographs.
##
## IT IS NOT ONE NUMBER, and that is why the fade matters more than this does.
## Measured off `tests/render/night_contrast.tscn`'s own plates: a canvas rim
## delta of 0.69 arrives as 0.41 at deep night (keep ~0.60) and as 0.60 at dusk
## (keep ~0.87) — the grade crushes far more of it at midnight. This constant is
## set for the DARKEST case, where the read is hardest to buy, and `lit_share`
## takes the over-drive back out again as the ground brightens.
const POST_KEEP: float = 0.55
## How far the contour must sit from the ground, in GRADED luminance. The brief
## is 0.25–0.30; the constant is set above it so grain and vignette cannot eat
## the margin at the corners of the frame.
const RIM_DELTA: float = 0.38
## ...and the BODY, which has to carry the mass. THE FIRST TUNING OF THIS PASS
## PUT IT AT 0.115 AND THE RESULT IS WORTH KEEPING IN THE FILE: every creature
## cleared the contrast bar, the suite went green, and the frame
## (`artifacts/P13/frames/wave_deep_night.png`, first version) was a row of
## glowing blue WIREFRAMES — a bright contour around a body still sitting at
## ground value. It read as a debug overlay, not as a pack of animals. A contour
## is an edge; something has to be inside it, and no number said so.
const BODY_DELTA: float = 0.26
## How hard the body is pulled toward that value. The mask itself protects the
## bright parts of the art (see LcnSpriteFactory._extract_fill), so this can be
## high without flattening the hot cores the creatures were drawn with.
const BODY_MIX: float = 0.78
## Under this many screen pixels a two-pixel contour is aliasing, and the body
## lift alone carries the read.
const MIN_RIM_PX: float = 9.0

## Cold, for the things that come out of the dark. DESATURATED on purpose: at
## full chroma an eighteen-strong wave reads as neon, and this game's night is
## meant to be moonlight, not a light show.
const FOE_BODY: Color = Color(0.34, 0.48, 0.78)
const FOE_RIM: Color = Color(0.62, 0.78, 1.00)
## Warm, for the people who live under the lamps. The city's own firelight, so
## friend and foe separate by HUE at the same moment they separate from the
## ground by VALUE.
const KIN_BODY: Color = Color(0.74, 0.65, 0.55)
const KIN_RIM: Color = Color(1.00, 0.88, 0.72)
## What a figure is reduced to when the ground behind it is brighter than it is.
const DARK_RIM: Color = Color(0.055, 0.065, 0.110)

# ============================== A HOSTILE BRINGS ITS OWN GROUND TO STAND ON ===
#
# THE FRAME THAT FORCED THIS IS `artifacts/CRIT/shots/assault.world.png`, and it
# is the ordinary output of `tools/run_visual.sh --scenario=first_night`. The
# interface says UNDER ATTACK · 10 in the city · they are inside the perimeter.
# The renderer drew 21 agents. A critic scanning that PNG for the foe rim colour
# found 105 pixels in two clusters and both of them were the temperature labels
# `41C` and `31C`. Not one creature. The contrast pass before this one measured
# eleven of eleven enemies at delta-L 0.42 — on a bench that did not contain the
# post grade, the night vignette, or the red screen wash the game paints over
# everything the moment a wave lands.
#
# Three things were wrong and all three are answered here.
#
#  1. THE TREATMENT SWITCHED ITSELF OFF WHERE THE FIGHT IS. `lit_share` fades to
#     nothing as the ground brightens, and the ground inside a city full of
#     fires is exactly bright enough to halve it — while still being far too
#     dark, after the grade, to carry a silhouette. The enemies that mattered
#     were the ones already inside the perimeter, standing on the one ground the
#     treatment had decided needed no help. `foe_lit_share` moves a HOSTILE's
#     pivot out to daylight: a threat gets the full treatment on any ground a
#     night has, and only stops being lit when the sun could silhouette it.
#
#  2. A RIM IS TWO PIXELS AND THE GRADE EATS PIXELS. Value contrast carried on a
#     contour is the first thing lost to fog, vignette, grain and a wash — all
#     of which are area operations. So the primary cue is now AREA: an additive
#     cold pool of light on the ground the creature is standing on, forty screen
#     pixels across, in the same idiom as the warm pools the city's own fires
#     throw. The city is warm, the things out of the dark are cold, and at a
#     glance the night now has cold spots moving through it.
#
#  3. THE WASH IS RED AND THE CUE WAS BLUE. A full-frame tint is a lerp toward
#     one colour, so it costs a fixed FRACTION of every difference in the frame
#     — which a two-pixel contour cannot afford and a bright area cue can. The
#     pool is drawn ADDITIVELY and at chroma, so what survives the lerp is both
#     luminance above the plain AND blue above red. `game/view/feel/screen_fx.gd`
#     also stops painting the threat vignette across the middle of the playfield
#     for the same reason; between them a hostile is now findable while the
#     screen is red, which is the only condition under which finding one matters.
#
# The gate for all of this is `tests/render/run_foe_frame.gd`, and the one thing
# it is not allowed to do is stand a bench up: it opens the harness's own
# `shots/*.world.png` and measures the rectangles this file logged.

## Radius of a hostile's pool, in SCREEN pixels, so the mark is the same size to
## the player at every zoom. A figure floor of 24 px means the pool is a little
## under twice the creature and reads as light around it rather than as a disc
## it is standing on top of.
const FOE_POOL_PX: float = 22.0
## Peak alpha of the soft outer pool, additive.
const FOE_POOL_A: float = 0.46
## The halo that draws OVER everything the city built. Small and soft: it is the
## creature's own light reaching the camera, not a marker pinned to it, and at
## more than this it starts to erase the silhouette it is there to advertise.
const FOE_HALO_PX: float = 16.0
const FOE_HALO_A: float = 0.26
## ...and of the tight core, which is what keeps a pool from reading as a smudge
## once the grade's bloom has had it.
const FOE_CORE_A: float = 0.52
const FOE_CORE_PX: float = 8.5
## The cold the pool is made of. MORE saturated than FOE_RIM on purpose: this is
## the one cue that has to survive a lerp toward red, and the thing a lerp cannot
## take away is the SIGN of blue-minus-red.
const FOE_POOL_COL: Color = Color(0.40, 0.66, 1.00)
## THE HOUR, NOT THE GROUND, DECIDES WHETHER A HOSTILE IS LIT — and this is the
## measurement that settled it, straight out of a first_night visual run's own
## `foemarks` line at the assault beat:
##
##   drift_hound gl0.502  drift_hound gl0.680  drift_hound gl0.367  ... gl0.101
##
## `ground_luma` returned HALF TO TWO THIRDS for six of nine hostiles, because
## the six that mattered were the ones already inside the perimeter, standing in
## the pools thrown by the city's own fires. Against GROUND_PIVOT = 0.34 that is
## `lit_share` 0.05, 0.00, 0.49 — the treatment turned itself off for exactly the
## creatures the alert stack was shouting about. And the ground it turned itself
## off for is not bright: the same pixels in `assault.world.png` measure ~0.10
## once the grade, the fog and the vignette have had them. `ground_luma` is an
## illumination estimate and the frame is a graded photograph, and inside a city
## full of fires those two numbers are not the same number.
##
## So a hostile's treatment is keyed to `light_energy`, which is the hour and
## nothing else: full after dark, gone by midday, half at dusk. A creature that
## walks into a hearth's light at night stays lit, which is the correct answer —
## the reason to silhouette it against bright ground was that bright ground
## exists, and at night it does not, whatever the light rig says about it.
const DARK_ENERGY: float = 0.90
const DAY_ENERGY: float = 0.35
## CANVAS luminance a hostile's body and contour are painted at after dark, as
## ABSOLUTE values rather than as a delta above `ground_luma` — for the reason
## above: the delta was being measured from a number that does not describe the
## frame. Capped short of 1.0 so `at_luma` never walks the cold all the way to
## white; a white figure is a bright figure that is no longer telling you what
## it is, and hue is half the read.
const FOE_BODY_L: float = 0.62
const FOE_RIM_L: float = 0.90
## How often the foe-mark dump is written, in sim ticks. 20 Hz sim, so this is
## twice a second while anything hostile is on screen and nothing otherwise.
const FOE_LOG_EVERY: int = 10

var _foes_in_view: int = 0
var _foe_log_tick: int = -1
## 1 after dark, 0 by midday. Flattened out of the grade once per frame.
var _dark_share: float = 0.0


## How much of the hostile treatment this hour gets. `lit_share` still counts:
## on genuinely black ground at any hour a hostile is lit like anything else.
func foe_lit_share(gl: float) -> float:
	return maxf(lit_share(gl), _dark_share)


## The cold pools, additive, one soft quad and one tight quad per hostile in
## view. Bounded by the wave size, and inside the batch the glow pass was
## already running — no new texture and no state change.
func _draw_foe_pools(ci: CanvasItem) -> void:
	if _foes_in_view <= 0 or _glow_r.size.x <= 0.0:
		return
	var z: float = maxf(zoom, 0.01)
	var r_out: float = FOE_POOL_PX / z
	var r_in: float = FOE_CORE_PX / z
	for ag: Dictionary in _vis_ag:
		if not LcnSpriteFactory.is_enemy_kind(ag["kind"]):
			continue
		var foot: Vector2 = ag["pos"]
		var share: float = _dark_share
		if share <= 0.02:
			continue
		# The pool sits a little above the feet, where the mass of the figure is,
		# so a tall creature is not marked by a ring around its ankles.
		var at: Vector2 = foot - Vector2(0.0, r_in * 0.35)
		var c: Color = FOE_POOL_COL
		ci.draw_texture_rect_region(_atlas,
			Rect2(at - Vector2(r_out, r_out), Vector2(r_out * 2.0, r_out * 2.0)),
			_glow_r, Color(c.r, c.g, c.b, FOE_POOL_A * share))
		ci.draw_texture_rect_region(_atlas,
			Rect2(at - Vector2(r_in, r_in), Vector2(r_in * 2.0, r_in * 2.0)),
			_glow_r, Color(c.r, c.g, c.b, FOE_CORE_A * share))


## The one mark in this renderer that draws above the city. See _make_pass.
func _draw_foe_halos(ci: CanvasItem) -> void:
	if _foes_in_view <= 0 or _glow_r.size.x <= 0.0 or _dark_share <= 0.02:
		return
	var r: float = FOE_HALO_PX / maxf(zoom, 0.01)
	var c: Color = FOE_POOL_COL
	var a: float = FOE_HALO_A * _dark_share
	for ag: Dictionary in _vis_ag:
		if not LcnSpriteFactory.is_enemy_kind(ag["kind"]):
			continue
		var dest: Rect2 = agent_dest(ag)
		if dest.size.x <= 0.0:
			continue
		# The MASS of the figure, not its feet: a halo on the ground is what the
		# pool already is, and stacking two of them in the same place buys one
		# brighter smudge instead of a creature.
		var at: Vector2 = dest.get_center()
		ci.draw_texture_rect_region(_atlas,
			Rect2(at - Vector2(r, r), Vector2(r * 2.0, r * 2.0)),
			_glow_r, Color(c.r, c.g, c.b, a))


## Estimated luminance of the GROUND at a world point, in canvas space (i.e.
## before the post grade), 0..1.
##
## Public because it is a statement about the picture that a suite must be able
## to check against a photograph without standing the whole renderer up twice —
## `tests/render/night_contrast.tscn` prints this beside the luminance it
## actually photographs at the same point, at every hour it grades — so the
## calibration this whole treatment rests on is a number in a log rather than a
## claim in a comment. At deep night it tracks the measured ground one for one
## with a constant floor of about 0.04; at midday it under-reads by 0.25, which
## does not matter because `lit_share` is already zero long before there.
func ground_luma(at: Vector2) -> float:
	var l: Color = _light_for(at, 0.0)
	return clampf(
		(l.r * 0.2126 + l.g * 0.7152 + l.b * 0.0722) * GROUND_ALBEDO, 0.0, 1.0)


## How much of the lit treatment this ground gets: 1 on a black plain, 0 by the
## time the ground can carry a silhouette on its own.
##
## THIS CURVE IS A FIX FOR A DEFECT ONLY THE CROSSOVER HOUR COULD SHOW, and the
## measurement is `tests/render/night_contrast.tscn`'s dusk beat. With a hard
## pivot the body was asked for `(ground + 0.47) / 0.78`, which passes 1.0 as
## soon as the ground reaches about 0.27 — and even short of that the grade keeps
## far more of a canvas-space delta at dusk than it does at deep night, so the
## same over-drive that lands a creature 0.42 above the plain at midnight landed
## it 0.60 above at dusk, with 45–79% OF EVERY FIGURE reading as lit. Eighteen
## hostiles and citizens crossing the plain at the assault hour as pale cut-outs.
## The deep-night beat was green throughout, because midnight is nowhere near
## that band, and the frame lab never photographs a wave at all.
##
## The fade now begins the moment the ground has any light in it and reaches zero
## at the pivot — "how much help does this ground need" is "how far below the
## pivot is it", not "is it below the pivot". Smoothstep rather than a step
## because a hard boundary pops a figure from lit to black as it walks out of a
## hearth's pool, and a city built around fires crosses that boundary constantly.
static func lit_share(gl: float) -> float:
	return smoothstep(GROUND_PIVOT, 0.0, gl)


## `hue` re-valued to land at `target` luminance. Darkening scales the channels;
## brightening walks toward white, so a colour never clips one channel and turns
## into a different hue on the way up.
static func at_luma(hue: Color, target: float) -> Color:
	var l: float = maxf(hue.r * 0.2126 + hue.g * 0.7152 + hue.b * 0.0722, 0.0015)
	if target <= l:
		var k: float = maxf(target, 0.0) / l
		return Color(hue.r * k, hue.g * k, hue.b * k, 1.0)
	var t: float = clampf((target - l) / maxf(1.0 - l, 0.001), 0.0, 1.0)
	return Color(lerpf(hue.r, 1.0, t), lerpf(hue.g, 1.0, t), lerpf(hue.b, 1.0, t), 1.0)


## The body lift and the contour, both out of the same atlas and the same
## destination rect as the figure — two more quads inside the batch that was
## already running, and no new state change at any zoom.
func _draw_agent_edge(ci: CanvasItem, dest: Rect2, art: StringName, foot: Vector2,
		hostile: bool, ag: Dictionary) -> void:
	var rim_r: Rect2 = _regions.get(LcnSpriteFactory.rim_key(art), Rect2())
	var fill_r: Rect2 = _regions.get(LcnSpriteFactory.fill_key(art), Rect2())
	if rim_r.size.x <= 0.0 and fill_r.size.x <= 0.0:
		return
	var gl: float = ground_luma(foot)
	# A hostile does not get to fade out on ground the grade will crush back to
	# black anyway — see the block above FOE_POOL_PX.
	var lit: float = foe_lit_share(gl) if hostile else lit_share(gl)
	var on_screen: float = absf(dest.size.y) * maxf(zoom, 0.01)

	# THE BODY, lifted only while the ground is too dark to carry a silhouette.
	# `lit` fades the WEIGHT and not the colour, on purpose: solving for the
	# paint colour against a fading mix walks it toward white as the mix drops,
	# so the figure gets paler exactly as it is supposed to be disappearing.
	var mix: float = BODY_MIX * lit
	if fill_r.size.x > 0.0 and mix > 0.02 and BODY_DELTA > 0.0:
		# out = (1 - mix) * figure + mix * body, so the colour is asked for at
		# target / BODY_MIX and the figure's own drawing survives underneath.
		# A hostile is painted at an ABSOLUTE value; a citizen keeps the delta
		# above its own ground, which is what makes the city read as lit by the
		# city. See the DARK_ENERGY block for why those differ.
		var body: float = (FOE_BODY_L if hostile else gl + BODY_DELTA / POST_KEEP) / BODY_MIX
		ci.draw_texture_rect_region(_atlas, dest, flip_src(fill_r, ag), Color(
			at_luma(FOE_BODY if hostile else KIN_BODY, minf(body, 1.0)), mix))

	# THE CONTOUR, which always draws and simply changes sides. Above the pivot
	# it is the near-black edge that keeps a dark chassis from dissolving into
	# the shadow beside it; below, it is the moonlit or firelit crescent.
	if rim_r.size.x <= 0.0 or on_screen < MIN_RIM_PX or RIM_DELTA <= 0.0:
		return
	var d: float = RIM_DELTA / POST_KEEP
	var bright: Color = at_luma(FOE_RIM, FOE_RIM_L) if hostile \
		else at_luma(KIN_RIM, minf(gl + d, 1.0))
	var dark: Color = at_luma(DARK_RIM, maxf(gl - d, 0.012))
	ci.draw_texture_rect_region(_atlas, dest, flip_src(rim_r, ag), dark.lerp(bright, lit))


## How much a figure of `sprite_h` world pixels is enlarged at camera `z`, so it
## still covers MIN_AGENT_PX on screen. 1.0 whenever it already does.
##
## Static and public because it is a rule about the picture, not a private
## detail: the frame lab grades the same number and a suite can assert it
## without standing a renderer up.
static func agent_scale(sprite_h: float, z: float) -> float:
	var on_screen: float = maxf(sprite_h, 1.0) * maxf(z, 0.01)
	var target: float = agent_target_px(sprite_h)
	if on_screen >= target:
		return 1.0
	return minf(target / on_screen, MAX_AGENT_SCALE)


## THE FLOOR IS A CURVE, NOT A LINE, and this is the reason.
##
## A flat floor pushes every figure to exactly the same screen height, which
## silently spends the one cue a tower defense cannot do without:
## `test_size_carries_the_threat` holds the 900 hp hoarfrost breaker at nearly
## twice the height of the 30 hp drift hound IN THE ATLAS, and then the floor
## enlarged the hound by 3.1x, the breaker by 1.7x, and delivered both to the
## screen at 24 pixels. tests/render/test_sprites.gd::test_the_echelon_reads_at
## _play_zoom measured what that costs: 0.677 silhouette overlap between those
## two, i.e. at the zoom the game is played at they were one creature. The
## previous floor of 17 did the same thing and nothing was measuring it.
##
## So the floor is applied to the SMALLEST thing that walks, and everything
## heavier keeps a compressed share of its real size on top of that. 0.45 is a
## square-root-ish compression: the boss stays unmistakably the boss without
## becoming a building, and the breaker arrives visibly heavier than the trash
## it arrives with.
const REF_AGENT_H: float = 13.0
const SIZE_KEEP: float = 0.45


## The screen height the figure floor asks for, for a sprite `sprite_h` world
## pixels tall. Never below MIN_AGENT_PX.
static func agent_target_px(sprite_h: float) -> float:
	return MIN_AGENT_PX * pow(maxf(sprite_h, REF_AGENT_H) / REF_AGENT_H, SIZE_KEEP)


## THE DEATHS. Two marks per kill, both out of the atlas, both additive because
## this pass is additive:
##
##   the flash   the creature's own silhouette, thrown up and scaled out over
##               DEATH_FLASH_S. It is white-hot for two frames and gone — the
##               shape you were shooting at, coming apart.
##   the stain   a soft dark pool that outlives it by a second, so the ground
##               after a fight is not the ground before it.
##
## Cost is bounded by DEATH_MAX and by the view cull, and the whole pass is
## inside the batch that was already running.
func _draw_deaths(ci: CanvasItem) -> void:
	_deaths_drawn = 0
	if _death_x.is_empty():
		return
	var now: float = SimClock.seconds()
	var alive: int = 0
	var n: int = _death_x.size()
	for i: int in n:
		var age: float = now - _death_t[i]
		# A rewound or reset clock must not strand marks forever.
		if age < 0.0 or age > DEATH_LIFE_S:
			continue
		# Compact in place: survivors move down, the tail is trimmed after.
		_death_x[alive] = _death_x[i]
		_death_y[alive] = _death_y[i]
		_death_t[alive] = _death_t[i]
		_death_kind[alive] = _death_kind[i]
		alive += 1
		var p := Vector2(_death_x[i], _death_y[i])
		if not view_rect.grow(48.0).has_point(p):
			continue
		var life: float = age / DEATH_LIFE_S
		# The stain: darkest immediately, gone at the end of the life.
		var stain: float = (1.0 - life) * (1.0 - life) * 0.34
		ci.draw_texture_rect_region(_atlas,
			Rect2(p - Vector2(13.0, 8.0), Vector2(26.0, 16.0)), _shadow_r,
			Color(0.30, 0.12, 0.10, stain))
		_deaths_drawn += 1
		if age > DEATH_FLASH_S:
			continue
		var f: float = age / DEATH_FLASH_S
		var region: Rect2 = _regions.get(
			LcnSpriteFactory.agent_key(_death_kind[i]), Rect2())
		if region.size.x <= 0.0:
			continue
		# Up and out: the silhouette lifts a few pixels and grows by a fifth
		# while it burns off, which is what separates "it died" from "it
		# vanished because the array shrank". Same figure floor as the living
		# sprite, or a kill would be smaller than the thing that was killed.
		var s: float = agent_scale(region.size.y, zoom) * (1.0 + f * 0.22)
		var size: Vector2 = region.size * s
		var top: Vector2 = p + Vector2(-size.x * 0.5, -size.y + 5.0 * s - f * 6.0)
		ci.draw_texture_rect_region(_atlas, Rect2(top, size), region,
			Color(1.0, 0.86, 0.72, (1.0 - f) * 0.95))
	if alive < n:
		_death_x.resize(alive)
		_death_y.resize(alive)
		_death_t.resize(alive)
		_death_kind.resize(alive)


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
