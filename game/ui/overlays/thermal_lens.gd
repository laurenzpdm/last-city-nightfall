class_name LcnThermalLens
extends LcnOverlayLayer
## [P19] Lens 3 — WHERE CAN THE CITY ACTUALLY LIVE.
##
## The warmth field is the most physical thing the simulation owns: every
## radiator stamps a smoothstep falloff into a sparse per-tile dictionary and
## overlapping sources add, which is precisely why a good city plan looks dense.
## None of that was visible.
##
## Here it becomes one smooth gradient over the ground, drawn as a SINGLE
## textured quad (one texel per tile, linear-filtered, one draw call at any
## zoom), plus two traced isolines:
##
##   SURVIVAL  the temperature below which a working building starts freezing
##   COMFORT   the temperature below which every building starts costing extra
##
## Inside the survival line the city lives. Outside it, it dies. A player should
## be able to plan a district by looking at where that line runs.

const SURVIVAL_C: float = -10.0    ## HeatDef.ACTIVE_FREEZE_C
const COMFORT_C: float = 10.0      ## HeatSystem.COMFORT_C
const FIELD_ALPHA: float = 0.78
## Degrees above ambient at which the field reaches full opacity.
const SOFT_RANGE: float = 9.0
## Opacity where the ground is exactly at outside air — a hint, not a sheet.
const FLOOR_ALPHA: float = 0.10
const LABELS_PER_LINE: int = 3

var _tex: ImageTexture = null
var _img: Image = null
var _img_w: int = 0
var _img_h: int = 0
var _contour: PackedVector2Array = PackedVector2Array()
var _line: PackedVector2Array = PackedVector2Array()


func _init() -> void:
	super()
	name = "ThermalLens"
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR


func _draw() -> void:
	if snap == null or snap.warm_w < 2:
		return
	var t0: int = Time.get_ticks_usec()
	_paint_field()
	_draw_isoline(SURVIVAL_C, "SURVIVAL LINE  %.0f C" % SURVIVAL_C, pal.ice(), 3.2, 0.0)
	_draw_isoline(COMFORT_C, "COMFORT  +%.0f C" % COMFORT_C, pal.good(), 2.0, 9.0)
	_draw_cold_marks()
	draw_us = Time.get_ticks_usec() - t0


## One quad, one texture, one draw call — at every zoom level, for any size of
## city. The linear filter does the smoothing that a per-tile rect grid cannot.
func _paint_field() -> void:
	var w: int = snap.warm_w
	var h: int = snap.warm_h
	if w < 2 or h < 2:
		return
	if _img == null or _img_w != w or _img_h != h:
		_img = Image.create_empty(w, h, false, Image.FORMAT_RGBA8)
		_img_w = w
		_img_h = h
		_tex = ImageTexture.create_from_image(_img)
	# Alpha rides on how far the tile is FROM the outside air, not on its absolute
	# temperature. Painting the whole viewport at ambient turned the snow into a
	# flat blue sheet and buried the art; this way the field only exists where the
	# heat network actually changed something, and the warm island pops.
	var base: float = snap.ambient_c
	for y: int in h:
		var row: int = y * w
		for x: int in w:
			var v: float = snap.warm[row + x]
			var c: Color = pal.thermal_color(v)
			var lift: float = clampf(absf(v - base) / SOFT_RANGE, 0.0, 1.0)
			c.a = FLOOR_ALPHA + (1.0 - FLOOR_ALPHA) * (lift * lift * (3.0 - 2.0 * lift))
			_img.set_pixel(x, y, c)
	_tex.update(_img)

	# Half-texel shift: sample i sits AT origin + i*step, but a stretched texture
	# puts texel i's centre at (i + 0.5). Without this the whole field, and the
	# isoline traced from it, is drawn half a sample south-east of the truth.
	var half: float = float(snap.warm_step) * TILE * 0.5
	var r: Rect2 = snap.warm_rect()
	draw_texture_rect(_tex, Rect2(r.position - Vector2(half, half), r.size), false,
		Color(1.0, 1.0, 1.0, FIELD_ALPHA * (1.15 if pal.high_contrast else 1.0)))


func _draw_isoline(level: float, text: String, c: Color, width_px: float, dash: float) -> void:
	_contour.clear()
	LcnOverlayGeometry.contour(snap.warm, snap.warm_w, snap.warm_h, level, _contour)
	if _contour.is_empty():
		return
	_line.clear()
	var scale: float = float(snap.warm_step) * TILE
	var origin: Vector2 = Vector2(snap.warm_origin) * TILE
	var i: int = 0
	while i + 1 < _contour.size():
		var a: Vector2 = origin + _contour[i] * scale
		var b: Vector2 = origin + _contour[i + 1] * scale
		if dash > 0.0:
			LcnOverlayGeometry.dashes(a, b, dash, dash * 0.7, 0.0, _line)
		else:
			_line.append(a)
			_line.append(b)
		i += 2
	if _line.size() < 2:
		return
	var cols := PackedColorArray()
	cols.resize(_line.size() / 2)
	cols.fill(LcnOverlayPalette.with_a(c, 0.95))
	# Drawn twice: a dark casing under a bright core, so the line survives both
	# the pale end of the ramp and the dark end.
	var casing := PackedColorArray()
	casing.resize(cols.size())
	casing.fill(Color(0.02, 0.03, 0.05, 0.8))
	draw_multiline_colors(_line, casing, stroke(width_px + 2.2))
	draw_multiline_colors(_line, cols, stroke(width_px))
	_label_line(text, c)


## Puts the name of the line ON the line, a few times, where it is on screen.
func _label_line(text: String, c: Color) -> void:
	var placed: int = 0
	var stride: int = maxi(2, (_line.size() / 2) / (LABELS_PER_LINE + 1))
	var i: int = 0
	var last: Vector2 = Vector2(-99999.0, -99999.0)
	while i + 1 < _line.size() and placed < LABELS_PER_LINE:
		var p: Vector2 = _line[i]
		if view.has_point(p) and p.distance_to(last) > px(260.0):
			plate(p + Vector2(px(8.0), -px(9.0)), text, 14.0, c)
			last = p
			placed += 1
		i += stride * 2


## Structures standing outside the survival line, so "this district is doomed"
## is a thing you can see instead of a thing you deduce.
func _draw_cold_marks() -> void:
	var pts := PackedVector2Array()
	var shown: int = 0
	for i: int in snap.node_count:
		if shown >= 60:
			break
		if (snap.node_flags[i] & LcnOverlayDefs.F_CONDUIT) != 0:
			continue
		var r: Rect2 = snap.node_rect(i)
		if not visible_rect(r):
			continue
		var here: float = _temperature_at(snap.node_x[i] + snap.node_w[i] / 2,
			snap.node_y[i] + snap.node_h[i] / 2)
		if here > SURVIVAL_C:
			continue
		shown += 1
		LcnOverlayGeometry.brackets(r.grow(px(2.0)), px(8.0), pts)
	if pts.size() >= 2:
		var cols := PackedColorArray()
		cols.resize(pts.size() / 2)
		cols.fill(LcnOverlayPalette.with_a(pal.ice(), 0.9))
		draw_multiline_colors(pts, cols, stroke(2.0))


func _temperature_at(cx: int, cy: int) -> float:
	var x: int = (cx - snap.warm_origin.x) / snap.warm_step
	var y: int = (cy - snap.warm_origin.y) / snap.warm_step
	if x < 0 or y < 0 or x >= snap.warm_w or y >= snap.warm_h:
		return snap.ambient_c
	return snap.warm[y * snap.warm_w + x]
