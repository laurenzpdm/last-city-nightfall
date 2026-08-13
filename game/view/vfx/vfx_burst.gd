class_name LcnVfxBurst
extends Node2D
## The transient particle buffer. [P14]
##
## Everything that happens ONCE — a muzzle flash, an impact, an explosion, a
## body coming apart, a pane of ice shattering, a flake landing — lives here
## rather than in a GPUParticles2D, for three reasons a critic can check:
##
##  1. **Exactness.** These effects must land on a coordinate the simulation
##     produced, at the instant it produced it. A GPU emitter spawns on its own
##     schedule and cannot be told "one particle, here, now".
##  2. **Count.** They are bursts. A shot is twenty particles for a fifth of a
##     second, not a stream, so the fixed GPU buffer a stream needs is waste.
##  3. **Draw calls.** Every particle in this buffer draws out of ONE texture
##     into ONE canvas item, which is exactly how [P13] draws 1700 buildings in
##     8 calls. A hundred separate emitters would be a hundred calls.
##
## The buffer is a fixed-size ring of packed arrays. It never allocates after
## construction and it never grows: when it is full the oldest particle is
## overwritten, so a fire-fight degrades by losing history rather than by
## dropping frames.
##
## Positions are WORLD pixels; this node lives under [LcnVfx] which lives under
## the renderer, and its own transform is identity.

## Particle shapes. The first four draw as textured quads out of the sheet; the
## last is a velocity-aligned line, which is what a tracer and a spark are.
enum Shape { SOFT, PUFF, CHIP, SHARD, STAR, RING, SPLAT, STREAK }

const _REGION: Array[Rect2] = [
	LcnVfxArt.R_DOT, LcnVfxArt.R_PUFF, LcnVfxArt.R_CHIP, LcnVfxArt.R_SHARD,
	LcnVfxArt.R_STAR, LcnVfxArt.R_RING, LcnVfxArt.R_SPLAT, LcnVfxArt.R_DOT,
]

var capacity: int = 0
var count: int = 0
## Set by [LcnVfx] every frame. Particles outside it are stepped but not drawn,
## which is cheaper than testing them at spawn and keeps a burst alive while the
## camera pans away and back.
var cull_rect: Rect2 = Rect2()

var _x: PackedFloat32Array = PackedFloat32Array()
var _y: PackedFloat32Array = PackedFloat32Array()
var _vx: PackedFloat32Array = PackedFloat32Array()
var _vy: PackedFloat32Array = PackedFloat32Array()
var _life: PackedFloat32Array = PackedFloat32Array()
var _life0: PackedFloat32Array = PackedFloat32Array()
var _size: PackedFloat32Array = PackedFloat32Array()
var _grow: PackedFloat32Array = PackedFloat32Array()
var _drag: PackedFloat32Array = PackedFloat32Array()
var _rise: PackedFloat32Array = PackedFloat32Array()
var _r: PackedFloat32Array = PackedFloat32Array()
var _g: PackedFloat32Array = PackedFloat32Array()
var _b: PackedFloat32Array = PackedFloat32Array()
var _a: PackedFloat32Array = PackedFloat32Array()
var _shape: PackedInt32Array = PackedInt32Array()

var _sheet: ImageTexture = null
var _drawn: int = 0
var _dropped: int = 0
var _wind: Vector2 = Vector2.ZERO
## Scratch buffers for the batched streak pass. Members, not locals, so a frame
## of drawing allocates nothing.
var _streak_pts: PackedVector2Array = PackedVector2Array()
var _streak_cols: PackedColorArray = PackedColorArray()


func configure(cap: int, additive: bool, z: int) -> void:
	capacity = maxi(1, cap)
	_sheet = LcnVfxArt.atlas()
	z_index = z
	z_as_relative = false
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	if additive:
		var m := CanvasItemMaterial.new()
		m.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		# Additive fire must not be crushed by the hour's CanvasModulate, or the
		# muzzle flash disappears exactly at the hour it is fired in.
		m.light_mode = CanvasItemMaterial.LIGHT_MODE_UNSHADED
		material = m
	_x.resize(capacity)
	_y.resize(capacity)
	_vx.resize(capacity)
	_vy.resize(capacity)
	_life.resize(capacity)
	_life0.resize(capacity)
	_size.resize(capacity)
	_grow.resize(capacity)
	_drag.resize(capacity)
	_rise.resize(capacity)
	_r.resize(capacity)
	_g.resize(capacity)
	_b.resize(capacity)
	_a.resize(capacity)
	_shape.resize(capacity)


## Emits one particle. `rise` is pixels/second of buoyancy (negative y), `grow`
## is pixels/second added to the radius, `drag` is the fraction of velocity kept
## per second. Everything is world-space.
func emit(pos: Vector2, vel: Vector2, life: float, size: float, col: Color,
		shape: int, drag: float = 0.55, rise: float = 0.0, grow: float = 0.0) -> void:
	var i: int = count
	if count >= capacity:
		# Full: overwrite the particle with the least life left, so what is lost
		# is the thing already fading rather than the thing just born.
		i = _weakest()
		_dropped += 1
	else:
		count += 1
	_x[i] = pos.x
	_y[i] = pos.y
	_vx[i] = vel.x
	_vy[i] = vel.y
	_life[i] = life
	_life0[i] = maxf(life, 0.0001)
	_size[i] = size
	_grow[i] = grow
	_drag[i] = drag
	_rise[i] = rise
	_r[i] = col.r
	_g[i] = col.g
	_b[i] = col.b
	_a[i] = col.a
	_shape[i] = shape


func _weakest() -> int:
	var worst: int = 0
	var worst_life: float = 1.0e9
	for i: int in count:
		if _life[i] < worst_life:
			worst_life = _life[i]
			worst = i
	return worst


## One integration step. `wind` is pixels/second and is applied to buoyant
## particles only — a masonry chip does not blow away, a smoke puff does.
func step(dt: float, wind: Vector2) -> void:
	_wind = wind
	var i: int = 0
	while i < count:
		var left: float = _life[i] - dt
		if left <= 0.0:
			count -= 1
			if i != count:
				_swap(i, count)
			continue
		_life[i] = left
		var buoy: float = _rise[i]
		# Only buoyant particles take the wind. A chip of masonry falls where it
		# was thrown; a puff of smoke goes where the storm sends it, and that is
		# the difference between debris and weather.
		var takes_wind: float = 0.0 if is_zero_approx(buoy) else 1.0
		var k: float = pow(clampf(_drag[i], 0.001, 1.0), dt)
		_vx[i] = _vx[i] * k + wind.x * (1.0 - k) * takes_wind
		_vy[i] = _vy[i] * k + wind.y * (1.0 - k) * takes_wind - buoy * dt
		_x[i] += _vx[i] * dt
		_y[i] += _vy[i] * dt
		_size[i] += _grow[i] * dt
		i += 1


func _swap(a: int, b: int) -> void:
	var t: float = _x[a]; _x[a] = _x[b]; _x[b] = t
	t = _y[a]; _y[a] = _y[b]; _y[b] = t
	t = _vx[a]; _vx[a] = _vx[b]; _vx[b] = t
	t = _vy[a]; _vy[a] = _vy[b]; _vy[b] = t
	t = _life[a]; _life[a] = _life[b]; _life[b] = t
	t = _life0[a]; _life0[a] = _life0[b]; _life0[b] = t
	t = _size[a]; _size[a] = _size[b]; _size[b] = t
	t = _grow[a]; _grow[a] = _grow[b]; _grow[b] = t
	t = _drag[a]; _drag[a] = _drag[b]; _drag[b] = t
	t = _rise[a]; _rise[a] = _rise[b]; _rise[b] = t
	t = _r[a]; _r[a] = _r[b]; _r[b] = t
	t = _g[a]; _g[a] = _g[b]; _g[b] = t
	t = _b[a]; _b[a] = _b[b]; _b[b] = t
	t = _a[a]; _a[a] = _a[b]; _a[b] = t
	var s: int = _shape[a]; _shape[a] = _shape[b]; _shape[b] = s


func clear() -> void:
	count = 0


func _draw() -> void:
	if _sheet == null or count == 0:
		return
	_drawn = 0
	var cull: Rect2 = cull_rect.grow(96.0)
	var use_cull: bool = cull.size.x > 1.0
	# Quads first, then lines: two runs of one primitive type batch better than
	# an interleaved stream of both.
	for i: int in count:
		var sh: int = _shape[i]
		if sh == Shape.STREAK:
			continue
		var px: float = _x[i]
		var py: float = _y[i]
		if use_cull and not cull.has_point(Vector2(px, py)):
			continue
		var f: float = clampf(_life[i] / _life0[i], 0.0, 1.0)
		var s: float = _size[i]
		draw_texture_rect_region(_sheet,
			Rect2(px - s, py - s, s * 2.0, s * 2.0), _REGION[sh],
			Color(_r[i], _g[i], _b[i], _a[i] * f))
		_drawn += 1
	# Streaks go out as ONE multiline command for the whole spray. Drawn as
	# individual lines they were one draw call each — measured at ~450 extra
	# calls for a single volley, which is more than the entire renderer spends
	# on a 1700-building city.
	_streak_pts.clear()
	_streak_cols.clear()
	for i: int in count:
		if _shape[i] != Shape.STREAK:
			continue
		var px2: float = _x[i]
		var py2: float = _y[i]
		if use_cull and not cull.has_point(Vector2(px2, py2)):
			continue
		var f2: float = clampf(_life[i] / _life0[i], 0.0, 1.0)
		var v := Vector2(_vx[i], _vy[i])
		var len_px: float = clampf(v.length() * 0.035, 3.0, 26.0) * (0.4 + f2 * 0.6)
		var dir: Vector2 = v.normalized() if v.length_squared() > 0.01 else Vector2.RIGHT
		var head := Vector2(px2, py2)
		_streak_pts.append(head)
		_streak_pts.append(head - dir * len_px)
		var col := Color(_r[i], _g[i], _b[i], _a[i] * f2)
		# draw_multiline_colors takes one colour per SEGMENT, not per point.
		_streak_cols.append(col)
		_drawn += 1
	if not _streak_pts.is_empty():
		draw_multiline_colors(_streak_pts, _streak_cols, 1.6)


func stats() -> Dictionary:
	return {"live": count, "drawn": _drawn, "capacity": capacity, "dropped": _dropped}
