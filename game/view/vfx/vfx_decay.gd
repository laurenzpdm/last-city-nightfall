class_name LcnVfxDecay
extends Node2D
## Damage, frost and things coming apart. [P14]
##
## Three reads, all of them the player's own fault and all of them visible
## before the alert fires — which is the whole point. A HUD warning is a
## sentence; a building with frost climbing up it is a fact.
##
##   **Damage smoke.** A structure that has lost health smokes, harder the more
##   it has lost. Driven off [method BuildingInstance.health_ratio], on a slow
##   sweep, so a wall being chewed through announces itself from across the map.
##
##   **Frost creep.** [P02] freezes a building when its network gives up on it,
##   and [Bus] says so once. Between "cold" and "frozen" there is nothing on
##   screen at all today. This grows real rime over the silhouette of anything
##   the heat system has stopped serving, so a district going dark is something
##   you watch happen rather than something you are told about.
##
##   **Ice shatter.** A frozen structure that is destroyed does not fall down;
##   it breaks. The burst is shards, not masonry.
##
## Everything here is drawn or emitted off a cached list rebuilt every
## DECAY_REFRESH_FRAMES frames — never per frame, and never over the whole city.

## Frost is fully grown after this many seconds of being unserved.
const FROST_GROW_SECONDS: float = 26.0
## Frost thaws back four times faster than it grows. Rescuing a district has to
## feel like a rescue.
const FROST_THAW_RATE: float = 4.0
## Structures tracked for frost at once.
const FROST_MAX: int = 64
## Structures smoking at once (they share the damage-smoke emitter).
const DAMAGE_MAX: int = 24
## Power factor at or below which a served building counts as freezing.
const COLD_AT: float = 0.34

var smoke: LcnVfxPointField = null

var _model: LcnWorldModel = null
var _build: SimSystem = null
var _heat: SimSystem = null
var _has_power: bool = false

## building id -> {pos, size, growth 0..1, frozen}
var _frost: Dictionary[int, Dictionary] = {}
var _smoke_pts: PackedVector2Array = PackedVector2Array()
var _burst_mix: LcnVfxBurst = null
var _burst_add: LcnVfxBurst = null
var _frames: int = 0
var _view: Rect2 = Rect2()
var _damaged: int = 0
var _rng := RandomNumberGenerator.new()
## Freeze announcements that arrived before the sweep had seen the structure.
var _pending_frozen: Dictionary[int, bool] = {}
## Scratch buffers for the batched frost-arm pass.
var _arm_pts: PackedVector2Array = PackedVector2Array()
var _arm_cols: PackedColorArray = PackedColorArray()


func setup(model: LcnWorldModel, add_buffer: LcnVfxBurst, mix_buffer: LcnVfxBurst) -> void:
	_model = model
	_burst_add = add_buffer
	_burst_mix = mix_buffer
	_rng.seed = 0x0FF1CE
	z_index = 8
	z_as_relative = false
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR

	smoke = LcnVfxPointField.new()
	smoke.name = "DamageSmoke"
	add_child(smoke)
	smoke.configure({
		"amount": LcnVfxTuning.DAMAGE_AMOUNT, "lifetime": LcnVfxTuning.DAMAGE_LIFETIME,
		"texture": LcnVfxArt.texture("puff"), "z": 25,
		"direction": Vector2.UP, "spread_deg": 24.0,
		"speed_min": 18.0, "speed_max": 44.0, "gravity": Vector2(0.0, -16.0),
		"damping": 0.4, "scale_min": 0.22, "scale_max": 0.55,
		"ramp": LcnVfxArt.ramp([
			Color(0.10, 0.09, 0.09, 0.0), Color(0.10, 0.09, 0.09, 0.62),
			Color(0.32, 0.30, 0.30, 0.30), Color(0.42, 0.40, 0.40, 0.0)] as Array[Color]),
		"turbulence": true, "turb_strength": 1.2, "turb_scale": 2.0,
	})

	Bus.building_froze.connect(_on_froze)
	Bus.building_removed.connect(_on_removed)
	Bus.world_created.connect(_on_world_created)


func bind_sim() -> void:
	_build = Sim.get_system(&"build")
	_heat = Sim.get_system(&"heat")
	_has_power = _heat != null and _heat.has_method("power_factor") \
		and _heat.has_method("has_building")


func _on_world_created(_seed_value: int) -> void:
	_frost.clear()
	_smoke_pts.clear()
	_pending_frozen.clear()


## [P02] can freeze a structure the sweep has not seen yet (it is off screen, or
## the sweep is two frames away). Remember the fact, and let the next sweep pick
## it up, rather than dropping it.
func _on_froze(id: int) -> void:
	_pending_frozen[id] = true
	var e: Dictionary = _frost.get(id, {})
	if not e.is_empty():
		e["frozen"] = true


## A structure leaving the world while it is iced over shatters. One that is
## simply demolished does not — the difference is what tells a player whether
## they lost that wall or chose to move it.
func _on_removed(id: int, cell: Vector2i) -> void:
	var e: Dictionary = _frost.get(id, {})
	_frost.erase(id)
	_pending_frozen.erase(id)
	if e.is_empty() or float(e.get("growth", 0.0)) < 0.35:
		return
	var pos: Vector2 = e.get("pos", Vector2(float(cell.x) * 32.0 + 16.0,
		float(cell.y) * 32.0 + 16.0))
	_shatter(pos, float(e.get("size", 24.0)))


func _shatter(pos: Vector2, size: float) -> void:
	for i: int in 16:
		var a: float = TAU * float(i) / 16.0 + _rng.randf_range(-0.2, 0.2)
		var v: Vector2 = Vector2(cos(a), sin(a) * 0.75) * _rng.randf_range(60.0, 260.0)
		_burst_mix.emit(pos, v, _rng.randf_range(0.5, 1.2),
			_rng.randf_range(2.5, 6.0) * clampf(size / 32.0, 0.6, 2.0),
			LcnVfxTuning.ICE.lerp(LcnVfxTuning.ICE_PALE, _rng.randf()),
			LcnVfxBurst.Shape.SHARD, 0.32)
	_burst_add.emit(pos, Vector2.ZERO, 0.34, size * 0.5, Color(0.70, 0.90, 1.0, 0.85),
		LcnVfxBurst.Shape.RING, 0.9, 0.0, size * 5.0)
	_burst_add.emit(pos, Vector2.ZERO, 0.26, size * 0.35, Color(0.60, 0.85, 1.0, 0.5),
		LcnVfxBurst.Shape.SOFT, 0.9, 8.0, size * 0.9)


func update(dt: float, view: Rect2, wind: Vector2, quality: float) -> void:
	_view = view
	_frames += 1
	if _frames % LcnVfxTuning.DECAY_REFRESH_FRAMES == 1:
		_rescan(view)
	_advance_frost(dt)
	smoke.set_view(view)
	smoke.set_wind(wind, 0.7, Vector2(0.0, -16.0))
	smoke.set_points(_smoke_pts)
	smoke.set_density(clampf(float(_smoke_pts.size()) / 6.0, 0.0, 1.0)
		* clampf(quality, 0.0, 1.0))
	queue_redraw()


## Rebuilds the damaged and the freezing lists. This is the only place the whole
## building table is walked, and it is walked once every DECAY_REFRESH_FRAMES.
func _rescan(view: Rect2) -> void:
	_smoke_pts.clear()
	_damaged = 0
	if _build == null or not _build.has_method("all_buildings"):
		return
	var grown: Rect2 = view.grow(96.0)
	var seen: Dictionary[int, bool] = {}
	var scanned: int = 0
	for b: Variant in _build.call("all_buildings"):
		var inst: BuildingInstance = b as BuildingInstance
		if inst == null or not inst.is_complete():
			continue
		var pos: Vector2 = inst.world_center()
		if not grown.has_point(pos):
			continue
		scanned += 1
		if scanned > LcnVfxTuning.SOURCE_SCAN_MAX:
			break
		var hurt: float = 1.0 - inst.health_ratio()
		if hurt > LcnVfxTuning.DAMAGE_AT and _smoke_pts.size() < DAMAGE_MAX:
			_damaged += 1
			_smoke_pts.append(pos + Vector2(0.0, -10.0))
		# The pending flag covers the window between [P02] announcing a freeze
		# and this sweep coming round; it is consumed the first time the sweep
		# sees the structure, after which the instance's own state is the truth.
		var frozen: bool = inst.state == BuildTypes.State.FROZEN
		if _pending_frozen.has(inst.id):
			_pending_frozen.erase(inst.id)
			frozen = true
		var cold: bool = frozen
		if not cold and _has_power and bool(_heat.call("has_building", inst.id)):
			cold = float(_heat.call("power_factor", inst.id)) <= COLD_AT
		if not cold:
			continue
		seen[inst.id] = true
		if _frost.size() >= FROST_MAX and not _frost.has(inst.id):
			continue
		var e: Dictionary = _frost.get(inst.id, {"growth": 0.0})
		e["pos"] = pos
		var r: Rect2i = inst.rect()
		e["size"] = float(maxi(r.size.x, r.size.y)) * 16.0 + 8.0
		e["frozen"] = frozen
		e["cold"] = true
		_frost[inst.id] = e
	# Anything that was freezing and is not in this sweep is thawing.
	for id: int in _frost.keys():
		if not seen.has(id):
			(_frost[id] as Dictionary)["cold"] = false


func _advance_frost(dt: float) -> void:
	var dead: Array[int] = []
	for id: int in _frost:
		var e: Dictionary = _frost[id]
		var g: float = float(e.get("growth", 0.0))
		if bool(e.get("cold", false)):
			var rate: float = 1.0 / FROST_GROW_SECONDS
			if bool(e.get("frozen", false)):
				rate *= 2.5
			g = minf(1.0, g + dt * rate)
		else:
			g -= dt * FROST_THAW_RATE / FROST_GROW_SECONDS
			if g <= 0.0:
				dead.append(id)
				continue
		e["growth"] = g
	for id: int in dead:
		_frost.erase(id)


func _draw() -> void:
	if _frost.is_empty():
		return
	var cull: Rect2 = _view.grow(64.0)
	var wide: bool = _view.size.x <= 1.0
	var dot: ImageTexture = LcnVfxArt.texture("dot")
	var ids: Array = _frost.keys()
	ids.sort()
	_arm_pts.clear()
	_arm_cols.clear()
	for id: int in ids:
		var e: Dictionary = _frost[id]
		var g: float = float(e.get("growth", 0.0))
		if g <= 0.02:
			continue
		var pos: Vector2 = e["pos"]
		if not wide and not cull.has_point(pos):
			continue
		var size: float = float(e.get("size", 24.0))
		# Rime grows from the edges inward: a pale sheet over the footprint, and
		# crystal arms reaching further out the longer the structure has been
		# left cold.
		var spread: float = size * (0.55 + 0.45 * g)
		draw_texture_rect(dot, Rect2(pos - Vector2(spread, spread) * 0.9,
			Vector2(spread, spread) * 1.8), false,
			Color(LcnVfxTuning.ICE.r, LcnVfxTuning.ICE.g, LcnVfxTuning.ICE.b, 0.20 * g))
		var arms: int = 8
		var h: int = (id * 2654435761) & 0xFFFF
		var col := Color(LcnVfxTuning.ICE_PALE.r, LcnVfxTuning.ICE_PALE.g,
			LcnVfxTuning.ICE_PALE.b, 0.42 * g)
		for i: int in arms:
			var a: float = TAU * float(i) / float(arms) + float(h % 71) * 0.02
			var reach: float = size * (0.35 + 0.75 * g) * (0.7 + 0.3 * float((h >> i) & 1))
			_arm_pts.append(pos)
			_arm_pts.append(pos + Vector2(cos(a), sin(a) * 0.65) * reach)
			# One colour per SEGMENT, not per point.
			_arm_cols.append(col)
	# Every crystal arm on the map in one command. Sixty-four freezing structures
	# is 512 line segments, and 512 draw calls would cost more than the city.
	if not _arm_pts.is_empty():
		draw_multiline_colors(_arm_pts, _arm_cols, 1.8)


func frost_count() -> int:
	return _frost.size()


func stats() -> Dictionary:
	var frozen: int = 0
	for id: int in _frost:
		if float((_frost[id] as Dictionary).get("growth", 0.0)) > 0.6:
			frozen += 1
	return {
		"frosting": _frost.size(),
		"iced": frozen,
		"damaged": _damaged,
		"smoke_points": _smoke_pts.size(),
	}
