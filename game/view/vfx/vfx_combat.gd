class_name LcnVfxCombat
extends Node2D
## Muzzles, tracers, impacts and deaths. [P14]
##
## THE RULE THIS PART EXISTS TO KEEP: a tracer is never an animation played at a
## gun. Every shot on screen is the shot the simulation fired, at the position
## the simulation put it, arriving when the simulation says it arrives.
##
##   * A **hitscan** weapon resolves in the same tick it fires, so its tracer is
##     a beam drawn from muzzle to aim point, alive for TRACER_LIFE and gone.
##   * A **projectile** weapon spends real time crossing the gap — that is a
##     design decision in [ProjectilePool], not a flourish — so its tracer is
##     read out of [method CombatSystem.projectile_render_buffer] every frame
##     and drawn where the shell actually is. Lead a fast hound badly and you
##     can watch the round pass behind it.
##   * A **cone** weapon holds a burning wedge open and pays for it every tick.
##     [P07] re-announces it every CONE_SIGNAL_TICKS, so the cone here is held
##     for CONE_LIFE, which is longer than that gap, and it does not strobe.
##
## The weapon's own `tracer_color` and `tracer_width` are read off [WeaponDef],
## so retuning a gun in a .tres retunes how it looks without touching this file.
##
## Deaths differ by enemy family (see [constant LcnVfxTuning.DEATH_STYLE]): a
## frost-thing comes apart in shards, a cinder-thing bursts and gutters, a beast
## drops in ash. A player should be able to tell what died out of the corner of
## an eye.

const TILE: float = 32.0
## How far a shell may be from where it was predicted to be and still count as
## the same shell. A round crosses ~15 px in a 60 fps frame at 28 tiles/s.
const TRACK_TOLERANCE_PX: float = 40.0
## Impacts resolved from shell tracking in one frame. A cap, because the visual
## harness advances hundreds of ticks between frames and a whole barrage can
## land inside one of them.
const MAX_IMPACTS_PER_FRAME: int = 10

## One live beam: a hitscan tracer, a muzzle flash or a flamethrower cone.
class Beam extends RefCounted:
	var a: Vector2 = Vector2.ZERO
	var b: Vector2 = Vector2.ZERO
	var life: float = 0.0
	var life0: float = 1.0
	var width: float = 2.0
	var col: Color = Color.WHITE
	var kind: int = 0          ## 0 tracer, 1 muzzle, 2 cone
	var half_angle: float = 0.0

var burst_add: LcnVfxBurst = null
var burst_mix: LcnVfxBurst = null

var _beams: Array[Beam] = []
var _combat: SimSystem = null
var _has_shells: bool = false
var _has_readout: bool = false
## turret id -> {col, width, delivery, cone, splash, reach}
var _weapon: Dictionary[int, Dictionary] = {}
## enemy id -> kind, so a death knows what it is a death of.
var _enemy_kind: Dictionary[int, StringName] = {}
var _frames: int = 0
var _rng := RandomNumberGenerator.new()
var _view: Rect2 = Rect2()
var _shots: int = 0
var _kills: int = 0
var _impacts: int = 0
var _shells_drawn: int = 0
var _calm: bool = false

## This frame's shells, and last frame's, for impact resolution.
var _shell_n: int = 0
var _sx: PackedFloat32Array = PackedFloat32Array()
var _sy: PackedFloat32Array = PackedFloat32Array()
var _svx: PackedFloat32Array = PackedFloat32Array()
var _svy: PackedFloat32Array = PackedFloat32Array()
var _sown: PackedInt32Array = PackedInt32Array()
var _prev_n: int = 0
var _px: PackedFloat32Array = PackedFloat32Array()
var _py: PackedFloat32Array = PackedFloat32Array()
var _pvx: PackedFloat32Array = PackedFloat32Array()
var _pvy: PackedFloat32Array = PackedFloat32Array()
var _pown: PackedInt32Array = PackedInt32Array()
## Scratch buffers for the batched line pass.
var _line_pts: PackedVector2Array = PackedVector2Array()
var _line_cols: PackedColorArray = PackedColorArray()


func setup(add_buffer: LcnVfxBurst, mix_buffer: LcnVfxBurst) -> void:
	burst_add = add_buffer
	burst_mix = mix_buffer
	z_index = 30
	z_as_relative = false
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	var m := CanvasItemMaterial.new()
	m.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	m.light_mode = CanvasItemMaterial.LIGHT_MODE_UNSHADED
	material = m
	# The view never touches Rng: that stream belongs to the simulation and
	# drawing from it here would move a replay. This one is ours alone.
	_rng.seed = 0x5CA1AB1E
	Bus.turret_fired.connect(_on_turret_fired)
	Bus.enemy_spawned.connect(_on_enemy_spawned)
	Bus.enemy_killed.connect(_on_enemy_killed)
	Bus.structure_damaged.connect(_on_structure_damaged)
	Bus.world_created.connect(_on_world_created)


func bind_sim() -> void:
	_combat = Sim.get_system(&"combat")
	_has_shells = _combat != null and _combat.has_method("projectile_render_buffer")
	_has_readout = _combat != null and _combat.has_method("turret_readout")
	_weapon.clear()


func _on_world_created(_seed_value: int) -> void:
	_beams.clear()
	_enemy_kind.clear()
	_weapon.clear()
	_prev_n = 0
	_shell_n = 0


func update(dt: float, view: Rect2, calm: bool) -> void:
	_view = view
	_calm = calm
	_frames += 1
	if _has_readout and _frames % LcnVfxTuning.WEAPON_REFRESH_FRAMES == 1:
		_refresh_weapons()
	var i: int = _beams.size() - 1
	while i >= 0:
		var bm: Beam = _beams[i]
		bm.life -= dt
		if bm.life <= 0.0:
			_beams.remove_at(i)
		i -= 1
	_shells_drawn = 0
	_read_shells(dt)
	queue_redraw()


# ------------------------------------------------------------------ signals --

func _on_enemy_spawned(id: int, kind: StringName, _pos: Vector2) -> void:
	if _enemy_kind.size() > LcnVfxTuning.ENEMY_MEMORY_MAX:
		# A wave is hundreds. If the table ever runs away it is because kills are
		# not arriving, and losing the oldest entries costs a death style, not a
		# frame.
		_enemy_kind.clear()
	_enemy_kind[id] = kind


func _on_enemy_killed(id: int, pos: Vector2) -> void:
	var kind: StringName = _enemy_kind.get(id, &"")
	_enemy_kind.erase(id)
	_kills += 1
	if not _visible_at(pos, 96.0):
		return
	match LcnVfxTuning.death_style(kind):
		&"ice":
			_death_ice(pos)
		&"ember":
			_death_ember(pos)
		_:
			_death_beast(pos)


func _on_turret_fired(id: int, from: Vector2, to: Vector2) -> void:
	_shots += 1
	if not (_visible_at(from, 160.0) or _visible_at(to, 160.0)):
		return
	var w: Dictionary = _weapon_for(id)
	var col: Color = w.get("col", Color(1.0, 0.72, 0.36))
	var width: float = float(w.get("width", 1.6))
	var delivery: String = String(w.get("delivery", "projectile"))
	var dir: Vector2 = (to - from)
	if dir.length_squared() < 0.01:
		dir = Vector2.RIGHT
	dir = dir.normalized()

	if delivery == "cone":
		var cone := Beam.new()
		cone.a = from
		cone.b = to
		cone.life = LcnVfxTuning.CONE_LIFE
		cone.life0 = LcnVfxTuning.CONE_LIFE
		cone.col = col
		cone.width = width
		cone.kind = 2
		cone.half_angle = deg_to_rad(float(w.get("cone", 30.0)))
		_push(cone)
		# A flamethrower throws burning gas, not a beam: the cone is the read,
		# the embers inside it are why it looks hot.
		var n: int = 3 if _calm else 7
		for k: int in n:
			var spread: float = _rng.randf_range(-cone.half_angle, cone.half_angle)
			var reach: float = from.distance_to(to) * _rng.randf_range(0.25, 1.0)
			var v: Vector2 = dir.rotated(spread) * reach * _rng.randf_range(1.1, 1.8)
			burst_add.emit(from + dir.rotated(spread) * 10.0, v,
				_rng.randf_range(0.25, 0.5), _rng.randf_range(4.0, 9.0),
				col.lerp(LcnVfxTuning.EMBER_HOT, _rng.randf()),
				LcnVfxBurst.Shape.SOFT, 0.25, 26.0, 14.0)
		return

	_muzzle(from, dir, col, width)
	if delivery == "hitscan":
		var tr := Beam.new()
		tr.a = from
		tr.b = to
		tr.life = LcnVfxTuning.TRACER_LIFE
		tr.life0 = LcnVfxTuning.TRACER_LIFE
		tr.col = col
		tr.width = width
		tr.kind = 0
		_push(tr)
		_impact(to, -dir, col, float(w.get("splash", 0.0)))
	# A projectile shot needs no tracer here: the shell is in the sim and it is
	# drawn where the sim has it, in _draw().


func _on_structure_damaged(_id: int, amount: float, pos: Vector2) -> void:
	if not _visible_at(pos, 64.0):
		return
	_impacts += 1
	var n: int = clampi(int(1.0 + amount * 0.12), 1, 6 if _calm else 12)
	for i: int in n:
		var v: Vector2 = Vector2(_rng.randf_range(-1.0, 1.0),
			_rng.randf_range(-1.0, -0.2)).normalized() * _rng.randf_range(45.0, 150.0)
		burst_mix.emit(pos, v, _rng.randf_range(0.4, 0.9), _rng.randf_range(1.6, 3.4),
			LcnVfxTuning.ASH.lerp(LcnPalette.STEEL, _rng.randf() * 0.6),
			LcnVfxBurst.Shape.CHIP, 0.35)
	burst_mix.emit(pos + Vector2(0.0, -6.0), Vector2(0.0, -14.0),
		1.5, 9.0, Color(LcnVfxTuning.SMOKE_DARK.r, LcnVfxTuning.SMOKE_DARK.g,
			LcnVfxTuning.SMOKE_DARK.b, 0.45),
		LcnVfxBurst.Shape.PUFF, 0.5, 26.0, 12.0)


# ------------------------------------------------------------------- effects --

func _muzzle(at: Vector2, dir: Vector2, col: Color, width: float) -> void:
	var f := Beam.new()
	f.a = at
	f.b = at + dir * LcnVfxTuning.MUZZLE_LEN * clampf(width * 0.6, 0.6, 2.2)
	f.life = LcnVfxTuning.MUZZLE_LIFE
	f.life0 = LcnVfxTuning.MUZZLE_LIFE
	f.col = col.lerp(LcnVfxTuning.EMBER_HOT, 0.55)
	f.width = width * 3.4
	f.kind = 1
	_push(f)
	var n: int = 2 if _calm else 5
	for i: int in n:
		var v: Vector2 = dir.rotated(_rng.randf_range(-0.5, 0.5)) \
			* _rng.randf_range(120.0, 340.0)
		burst_add.emit(at, v, _rng.randf_range(0.08, 0.22), _rng.randf_range(1.2, 2.6),
			LcnVfxTuning.SPARK, LcnVfxBurst.Shape.STREAK, 0.15)


func _impact(at: Vector2, back: Vector2, col: Color, splash_px: float) -> void:
	_impacts += 1
	var big: bool = splash_px >= LcnVfxTuning.EXPLOSION_AT_PX
	var sparks: int = LcnVfxTuning.EXPLOSION_SPARKS if big else LcnVfxTuning.IMPACT_SPARKS
	if _calm:
		sparks = int(float(sparks) * 0.5)
	for i: int in sparks:
		var v: Vector2 = back.rotated(_rng.randf_range(-1.1, 1.1)) \
			* _rng.randf_range(90.0, 420.0 if big else 260.0)
		burst_add.emit(at, v, _rng.randf_range(0.12, 0.42),
			_rng.randf_range(1.4, 3.6), col.lerp(LcnVfxTuning.SPARK, _rng.randf() * 0.7),
			LcnVfxBurst.Shape.STREAK, 0.2)
	if not big:
		burst_add.emit(at, Vector2.ZERO, 0.16, 9.0,
			Color(col.r, col.g, col.b, 0.85), LcnVfxBurst.Shape.STAR, 0.9, 0.0, -22.0)
		return
	# A splash weapon gets a shockwave, a fireball and masonry.
	burst_add.emit(at, Vector2.ZERO, 0.34, splash_px * 0.35,
		Color(1.0, 0.82, 0.55, 0.75), LcnVfxBurst.Shape.RING, 0.9, 0.0, splash_px * 2.4)
	burst_add.emit(at, Vector2.ZERO, 0.30, splash_px * 0.30,
		Color(1.0, 0.62, 0.28, 0.9), LcnVfxBurst.Shape.SOFT, 0.9, 10.0, splash_px * 0.7)
	var debris: int = LcnVfxTuning.EXPLOSION_DEBRIS if not _calm else 4
	for i: int in debris:
		var v2: Vector2 = Vector2(_rng.randf_range(-1.0, 1.0),
			_rng.randf_range(-1.0, 0.1)).normalized() * _rng.randf_range(80.0, 300.0)
		burst_mix.emit(at, v2, _rng.randf_range(0.5, 1.2), _rng.randf_range(1.8, 4.0),
			LcnVfxTuning.ASH, LcnVfxBurst.Shape.CHIP, 0.4)
	burst_mix.emit(at, Vector2(0.0, -20.0), 1.9, splash_px * 0.28,
		Color(LcnVfxTuning.SMOKE_DARK.r, LcnVfxTuning.SMOKE_DARK.g,
			LcnVfxTuning.SMOKE_DARK.b, 0.55),
		LcnVfxBurst.Shape.PUFF, 0.5, 30.0, splash_px * 0.5)


func _death_ice(at: Vector2) -> void:
	var n: int = 6 if _calm else 13
	for i: int in n:
		var a: float = TAU * float(i) / float(n) + _rng.randf_range(-0.3, 0.3)
		var v: Vector2 = Vector2(cos(a), sin(a) * 0.7) * _rng.randf_range(70.0, 230.0)
		burst_mix.emit(at, v, _rng.randf_range(0.45, 1.0), _rng.randf_range(2.5, 5.5),
			LcnVfxTuning.ICE.lerp(LcnVfxTuning.ICE_PALE, _rng.randf()),
			LcnVfxBurst.Shape.SHARD, 0.35)
	burst_add.emit(at, Vector2.ZERO, 0.26, 16.0, Color(0.72, 0.90, 1.0, 0.8),
		LcnVfxBurst.Shape.RING, 0.9, 0.0, 120.0)
	burst_add.emit(at, Vector2.ZERO, 0.30, 11.0, Color(0.62, 0.85, 1.0, 0.55),
		LcnVfxBurst.Shape.SOFT, 0.9, 12.0, 24.0)


func _death_ember(at: Vector2) -> void:
	var n: int = 8 if _calm else 18
	for i: int in n:
		var a: float = _rng.randf_range(0.0, TAU)
		var v: Vector2 = Vector2(cos(a), sin(a)) * _rng.randf_range(50.0, 200.0)
		burst_add.emit(at, v, _rng.randf_range(0.35, 1.0), _rng.randf_range(1.6, 3.6),
			LcnVfxTuning.EMBER_HOT.lerp(LcnVfxTuning.EMBER_DIM, _rng.randf()),
			LcnVfxBurst.Shape.SOFT, 0.4, 30.0)
	burst_add.emit(at, Vector2.ZERO, 0.24, 14.0, Color(1.0, 0.60, 0.24, 0.85),
		LcnVfxBurst.Shape.SOFT, 0.9, 6.0, 40.0)
	burst_mix.emit(at, Vector2(0.0, -18.0), 1.4, 8.0,
		Color(LcnVfxTuning.SMOKE_DARK.r, LcnVfxTuning.SMOKE_DARK.g,
			LcnVfxTuning.SMOKE_DARK.b, 0.42), LcnVfxBurst.Shape.PUFF, 0.5, 24.0, 16.0)


func _death_beast(at: Vector2) -> void:
	var n: int = 5 if _calm else 11
	for i: int in n:
		var a: float = _rng.randf_range(0.0, TAU)
		var v: Vector2 = Vector2(cos(a), sin(a) * 0.6) * _rng.randf_range(30.0, 120.0)
		burst_mix.emit(at, v, _rng.randf_range(0.5, 1.1), _rng.randf_range(2.0, 4.2),
			LcnVfxTuning.ASH.lerp(LcnPalette.SNOW_SHADOW, _rng.randf() * 0.55),
			LcnVfxBurst.Shape.CHIP, 0.3)
	burst_mix.emit(at, Vector2(0.0, -8.0), 0.9, 13.0,
		Color(LcnPalette.SNOW_SHADOW.r, LcnPalette.SNOW_SHADOW.g,
			LcnPalette.SNOW_SHADOW.b, 0.34), LcnVfxBurst.Shape.PUFF, 0.55, 14.0, 18.0)


# ------------------------------------------------------------------ weapons --

func _weapon_for(turret_id: int) -> Dictionary:
	var w: Dictionary = _weapon.get(turret_id, {})
	if not w.is_empty():
		return w
	_refresh_weapons()
	return _weapon.get(turret_id, {})


## Reads the battery's own readout and the [WeaponDef] behind each gun, so the
## look of a shot is a property of the weapon rather than of this file.
func _refresh_weapons() -> void:
	if not _has_readout:
		return
	var rows: Array = _combat.call("turret_readout")
	var battery: Object = _combat.get("battery")
	for row: Variant in rows:
		if typeof(row) != TYPE_DICTIONARY:
			continue
		var r: Dictionary = row
		var id: int = int(r.get("id", -1))
		if id < 0:
			continue
		var entry: Dictionary = {"col": Color(1.0, 0.72, 0.36), "width": 1.6,
			"delivery": "projectile", "cone": 30.0, "splash": 0.0, "reach": 320.0}
		if battery != null and battery.has_method("weapon_of"):
			var def: WeaponDef = battery.call("weapon_of", StringName(r.get("weapon", "")))
			if def != null:
				entry["col"] = def.tracer_color
				entry["width"] = def.tracer_width
				entry["delivery"] = String(def.delivery)
				entry["cone"] = def.cone_degrees
				entry["splash"] = def.splash_radius * TILE
				entry["reach"] = def.range_tiles * TILE
		_weapon[id] = entry


func _push(b: Beam) -> void:
	if _beams.size() >= LcnVfxTuning.BEAM_MAX:
		_beams.remove_at(0)
	_beams.append(b)


func _visible_at(p: Vector2, pad: float) -> bool:
	if _view.size.x <= 1.0:
		return true
	return _view.grow(pad).has_point(p)


# --------------------------------------------------------------------- draw --

## One pass, three batches: cones as polygons (there are never many), every
## tracer, muzzle line and shell trail as ONE multiline, and the muzzle blooms
## as textured quads out of one sheet. Drawn as individual antialiased lines
## this cost a draw call per round in the air.
func _draw() -> void:
	_line_pts.clear()
	_line_cols.clear()
	for b: Beam in _beams:
		var f: float = clampf(b.life / b.life0, 0.0, 1.0)
		match b.kind:
			2:
				_draw_cone(b, f)
			1:
				_push_line(b.a, b.b, Color(b.col.r, b.col.g, b.col.b, b.col.a * f))
			_:
				# A tracer thins and dims rather than just fading, so a burst of
				# them reads as separate rounds instead of one smear.
				_push_line(b.a, b.b, Color(b.col.r, b.col.g, b.col.b, b.col.a * f * f))
	_gather_shells()
	if not _line_pts.is_empty():
		draw_multiline_colors(_line_pts, _line_cols, 2.0)
	# The blooms go last so they sit on top of their own tracers.
	var dot: ImageTexture = LcnVfxArt.texture("dot")
	for b2: Beam in _beams:
		if b2.kind != 1:
			continue
		var f2: float = clampf(b2.life / b2.life0, 0.0, 1.0)
		draw_texture_rect(dot, Rect2(b2.a - Vector2(15, 15) * f2, Vector2(30, 30) * f2),
			false, Color(b2.col.r, b2.col.g, b2.col.b, 0.9 * f2))


## draw_multiline_colors takes one colour per SEGMENT, so two points go in and
## one colour comes with them.
func _push_line(a: Vector2, b: Vector2, col: Color) -> void:
	_line_pts.append(a)
	_line_pts.append(b)
	_line_cols.append(col)


func _draw_cone(b: Beam, f: float) -> void:
	var rel: Vector2 = b.b - b.a
	var reach: float = rel.length()
	if reach < 1.0:
		return
	var base: float = atan2(rel.y, rel.x)
	var steps: int = 9
	var pts := PackedVector2Array()
	var cols := PackedColorArray()
	pts.append(b.a)
	cols.append(Color(b.col.r, b.col.g, b.col.b, 0.55 * f))
	for i: int in steps + 1:
		var a: float = base - b.half_angle + 2.0 * b.half_angle * float(i) / float(steps)
		pts.append(b.a + Vector2(cos(a), sin(a)) * reach)
		cols.append(Color(b.col.r, b.col.g, b.col.b, 0.0))
	draw_polygon(pts, cols)


## Live shells, straight out of [ProjectilePool]. Travel time, lead error and
## all — what is drawn here IS the round the simulation is flying, at the
## position the simulation has it at this instant.
func _gather_shells() -> void:
	var n: int = _shell_n
	if n <= 0:
		return
	var pad: Rect2 = _view.grow(64.0)
	var wide: bool = _view.size.x <= 1.0
	for i: int in n:
		var p := Vector2(_sx[i], _sy[i])
		if not wide and not pad.has_point(p):
			continue
		var w: Dictionary = _weapon.get(_sown[i], {})
		var col: Color = w.get("col", Color(1.0, 0.72, 0.36))
		var v := Vector2(_svx[i], _svy[i])
		var dir: Vector2 = v.normalized() if v.length_squared() > 0.01 else Vector2.RIGHT
		var tail: Vector2 = p - dir * clampf(v.length() * 0.045, 6.0, 30.0)
		_push_line(tail, p, Color(col.r, col.g, col.b, 0.16))
		_push_line(p - dir * 7.0, p, col)
		_shells_drawn += 1


## Every shell that was in the air last frame and is not in the air now has
## RESOLVED — [ProjectilePool] settles a round on arrival, dealing its direct
## damage and its splash. So the impact belongs exactly where the shell was
## about to be, and nowhere else. Matching by predicted position rather than by
## id is forced on us: the pool's render buffer carries no ids, and inventing an
## impact at the muzzle instead would put the spark on the gun.
func _resolve_shell_impacts(dt: float) -> void:
	var claimed := PackedByteArray()
	claimed.resize(_shell_n)
	var made: int = 0
	for i: int in _prev_n:
		if made >= MAX_IMPACTS_PER_FRAME:
			break
		var v := Vector2(_pvx[i], _pvy[i])
		var pred := Vector2(_px[i] + v.x * dt, _py[i] + v.y * dt)
		var best: int = -1
		var best_d: float = TRACK_TOLERANCE_PX * TRACK_TOLERANCE_PX
		for j: int in _shell_n:
			if claimed[j] == 1 or _sown[j] != _pown[i]:
				continue
			var dx: float = _sx[j] - pred.x
			var dy: float = _sy[j] - pred.y
			var d2: float = dx * dx + dy * dy
			if d2 < best_d:
				best_d = d2
				best = j
		if best >= 0:
			claimed[best] = 1
			continue
		var w: Dictionary = _weapon.get(_pown[i], {})
		var dir: Vector2 = v.normalized() if v.length_squared() > 0.01 else Vector2.RIGHT
		if _visible_at(pred, 64.0):
			_impact(pred, -dir, w.get("col", Color(1.0, 0.72, 0.36)),
				float(w.get("splash", 0.0)))
			made += 1
	_prev_n = _shell_n
	_px = _sx.duplicate()
	_py = _sy.duplicate()
	_pvx = _svx.duplicate()
	_pvy = _svy.duplicate()
	_pown = _sown.duplicate()


func _read_shells(dt: float) -> void:
	if not _has_shells:
		return
	var buf: Dictionary = _combat.call("projectile_render_buffer")
	_shell_n = int(buf.get("count", 0))
	_sx = buf["x"]
	_sy = buf["y"]
	_svx = buf["vx"]
	_svy = buf["vy"]
	_sown = buf["owner"]
	_resolve_shell_impacts(dt)


func stats() -> Dictionary:
	return {
		"beams": _beams.size(),
		"shells": _shells_drawn,
		"shots_seen": _shots,
		"kills_seen": _kills,
		"impacts": _impacts,
		"weapons_known": _weapon.size(),
		"enemies_tracked": _enemy_kind.size(),
	}
