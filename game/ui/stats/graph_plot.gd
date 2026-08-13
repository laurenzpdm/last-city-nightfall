class_name LcnGraphPlot
extends Control
## The chart. One control, every graph in the game. [P20]
##
## Give it a [LcnStatTrack], a list of series to draw and a window, and it draws
## a Factorio-legible chart: shaded nights, "nice" gridlines, glowing curves, an
## optional area fill, annotation verticals for the laws and technologies that
## explain a bend, and a crosshair that reads every curve at the hovered moment.
##
## Three things make it readable rather than merely correct:
##
##   1. **Nights are shaded.** A survival game's chart has a rhythm, and the
##      rhythm is the day. Shading it first means the eye reads the shape before
##      it reads a number.
##   2. **Counters are differenced, not stored as rates.** A counter series
##      holds a lifetime total; the plot turns it into units per minute over a
##      short smoothing window. That keeps the whole-run track honest even after
##      it has halved its own resolution twice.
##   3. **The axis snaps to human numbers.** 0, 25, 50, 75 — never 0, 23.4,
##      46.8, because the second one is a chart nobody reads twice.
##
## Cost: the sampled curves are rebuilt only when the data signature changes,
## and `_draw` is a handful of polylines. An open graph over a settled city
## costs tens of microseconds a frame; `last_draw_usec` reports the real figure
## and `tests/stats/run_stats_view.tscn` fails the build if it climbs.

enum Mode { LEVEL, RATE, FLAG }

const MIN_PLOT_W: float = 80.0
const MIN_PLOT_H: float = 50.0
## Samples the rate smoother looks back over. Four samples of the fine track is
## two seconds — short enough to see a stall, long enough not to flicker.
const RATE_WINDOW: int = 4
const LINE_W: float = 2.0

signal hovered(index: int, tick: int)

var theme_ref: LcnStatsTheme = null
var track: LcnStatTrack = null
## {key, label, colour, mode, fill}
var entries: Array[Dictionary] = []
## {from_tick, to_tick, night} — drawn as shaded bands.
var bands: Array[Dictionary] = []
## {tick, kind, text} — drawn as labelled verticals.
var marks: Array[Dictionary] = []

## Newest N samples to show. -1 draws everything the track holds.
var window_samples: int = -1
## Force the value axis. NAN on either leaves it automatic.
var forced_min: float = NAN
var forced_max: float = NAN
## Baseline the fill drops to. Zero for a rate, the axis floor for a level.
var zero_baseline: bool = true
var show_legend: bool = true
var title: String = ""
var empty_note: String = "No samples yet."
var last_draw_usec: int = 0

var _hover: int = -1
var _curves: Array[PackedFloat32Array] = []
var _sig: String = ""
var _from: int = 0
var _count: int = 0
var _lo: float = 0.0
var _hi: float = 1.0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true


func setup(t: LcnStatsTheme) -> void:
	theme_ref = t


## Replaces the series list. Each entry is {key, label, colour, mode, fill}.
func set_entries(list: Array[Dictionary]) -> void:
	entries = list
	_sig = ""
	queue_redraw()


func add_entry(key: StringName, label: String, colour: Color, mode: int = Mode.LEVEL,
		fill: bool = false) -> void:
	entries.append({"key": key, "label": label, "colour": colour, "mode": mode,
		"fill": fill})
	_sig = ""
	queue_redraw()


func clear_entries() -> void:
	entries.clear()
	_sig = ""
	queue_redraw()


## Call when the underlying track has advanced. Cheap: it only invalidates.
func refresh() -> void:
	queue_redraw()


func plot_rect() -> Rect2:
	var t: LcnStatsTheme = _theme()
	var left: float = t.AXIS_L
	var top: float = t.AXIS_T + (18.0 if title != "" else 0.0)
	var bottom: float = t.AXIS_B + (16.0 if show_legend else 0.0)
	return Rect2(Vector2(left, top),
		Vector2(maxf(MIN_PLOT_W, size.x - left - 10.0),
			maxf(MIN_PLOT_H, size.y - top - bottom)))


## The sample index under a plot-space x, or -1.
func index_at(x: float) -> int:
	if _count <= 1:
		return -1
	var r: Rect2 = plot_rect()
	var f: float = clampf((x - r.position.x) / maxf(1.0, r.size.x), 0.0, 1.0)
	return _from + int(roundf(f * float(_count - 1)))


func _gui_input(event: InputEvent) -> void:
	var motion := event as InputEventMouseMotion
	if motion != null:
		var i: int = index_at(motion.position.x)
		if i != _hover:
			_hover = i
			hovered.emit(i, 0 if track == null else track.tick_at(i))
			queue_redraw()
		return
	if event is InputEventMouseButton and not (event as InputEventMouseButton).pressed:
		return


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT and _hover != -1:
		_hover = -1
		queue_redraw()


# ===================================================================  draw ===

func _draw() -> void:
	var t0: int = Time.get_ticks_usec()
	var t: LcnStatsTheme = _theme()
	var r: Rect2 = plot_rect()
	t.plate(self, Rect2(Vector2.ZERO, size), t.PLOT_BG, t.RIM_SOFT)
	if title != "":
		t.caps(self, Vector2(t.AXIS_L, t.fs(t.FS_SMALL) + 2.0), title,
			t.fs(t.FS_SMALL), t.TEXT_DIM)

	if track == null or track.sample_count() < 2 or entries.is_empty():
		t.text_centre(self, size.x * 0.5, size.y * 0.5, empty_note,
			t.fs(t.FS_BODY), t.TEXT_FAINT)
		last_draw_usec = Time.get_ticks_usec() - t0
		return

	_rebuild()
	_draw_bands(t, r)
	_draw_grid(t, r)
	_draw_curves(t, r)
	_draw_marks(t, r)
	_draw_crosshair(t, r)
	if show_legend:
		_draw_legend(t)
	last_draw_usec = Time.get_ticks_usec() - t0


## Recomputes the plotted values only when something actually changed.
func _rebuild() -> void:
	var n: int = track.sample_count()
	_count = n if window_samples <= 0 else mini(n, window_samples)
	_from = n - _count
	var sig: String = "%d/%d/%d/%d/%d" % [track.latest_tick, n, _count, entries.size(), track.stride]
	if sig == _sig:
		return
	_sig = sig
	_curves.clear()
	var lo: float = INF
	var hi: float = -INF
	for e: Dictionary in entries:
		var curve: PackedFloat32Array = _sample_entry(e)
		_curves.append(curve)
		for v: float in curve:
			lo = minf(lo, v)
			hi = maxf(hi, v)
	if lo == INF:
		lo = 0.0
		hi = 1.0
	if zero_baseline:
		lo = minf(lo, 0.0)
	if is_finite(forced_min):
		lo = forced_min
	if is_finite(forced_max):
		hi = forced_max
	if hi - lo < 0.000001:
		hi = lo + 1.0
	# A hair of headroom, so a curve that touches its own maximum is not clipped
	# by the top rim and misread as flat.
	_lo = lo
	_hi = hi + (hi - lo) * 0.08


func _sample_entry(e: Dictionary) -> PackedFloat32Array:
	var s: LcnStatSeries = track.series(e["key"])
	var out := PackedFloat32Array()
	out.resize(_count)
	if s == null:
		out.fill(0.0)
		return out
	var mode: int = int(e.get("mode", Mode.LEVEL))
	if mode != Mode.RATE:
		for i: int in _count:
			out[i] = s.at(_from + i)
		return out
	var per: float = 60.0 / maxf(0.001, track.sample_seconds())
	for i: int in _count:
		var idx: int = _from + i
		var back: int = maxi(0, idx - RATE_WINDOW)
		var steps: int = idx - back
		if steps <= 0:
			out[i] = 0.0
			continue
		out[i] = maxf(0.0, (s.at(idx) - s.at(back)) * per / float(steps))
	return out


func _draw_bands(t: LcnStatsTheme, r: Rect2) -> void:
	for b: Dictionary in bands:
		var a: float = _x_of_tick(r, int(b["from_tick"]))
		var z: float = _x_of_tick(r, int(b["to_tick"]))
		if z <= r.position.x or a >= r.position.x + r.size.x:
			continue
		a = maxf(a, r.position.x)
		z = minf(z, r.position.x + r.size.x)
		if z - a < 1.0:
			continue
		draw_rect(Rect2(Vector2(a, r.position.y), Vector2(z - a, r.size.y)),
			t.NIGHT_BAND, true)
		draw_line(Vector2(a, r.position.y), Vector2(a, r.position.y + r.size.y),
			t.NIGHT_EDGE, 1.0)
		if z - a > 44.0:
			t.text_centre(self, (a + z) * 0.5, r.position.y + t.fs(t.FS_TINY) + 3.0,
				"NIGHT %d" % int(b.get("night", 0)), t.fs(t.FS_TINY), t.TEXT_FAINT)


func _draw_grid(t: LcnStatsTheme, r: Rect2) -> void:
	var step: float = LcnStatsTheme.nice_step(_hi - _lo, 4)
	var v: float = ceil(_lo / step) * step
	var size_small: int = t.fs(t.FS_TINY)
	while v <= _hi + step * 0.01:
		var y: float = _y_of(r, v)
		if y >= r.position.y - 1.0 and y <= r.position.y + r.size.y + 1.0:
			var col: Color = t.GRID_ZERO if absf(v) < step * 0.001 else t.GRID
			draw_line(Vector2(r.position.x, y), Vector2(r.position.x + r.size.x, y), col, 1.0)
			t.text_right(self, r.position.x - 6.0, y + float(size_small) * 0.36,
				LcnStatsTheme.axis_label(v, step), size_small, t.TEXT_FAINT)
		v += step

	# Time axis: four verticals, labelled with the world clock.
	var divisions: int = 4
	for i: int in range(divisions + 1):
		var f: float = float(i) / float(divisions)
		var x: float = r.position.x + r.size.x * f
		if i > 0 and i < divisions:
			draw_line(Vector2(x, r.position.y), Vector2(x, r.position.y + r.size.y),
				t.GRID, 1.0)
		var tick: int = track.tick_at(_from + int(roundf(f * float(maxi(1, _count - 1)))))
		var label: String = LcnStatsTheme.ticks_as_clock(tick)
		var align: float = 0.0 if i == 0 else (-1.0 if i == divisions else -0.5)
		var w: float = t.text_width(label, size_small)
		t.text(self, Vector2(x + align * w, r.position.y + r.size.y + size_small + 5.0),
			label, size_small, t.TEXT_FAINT)
	draw_rect(r, t.RIM_SOFT, false, 1.0)


func _draw_curves(t: LcnStatsTheme, r: Rect2) -> void:
	for i: int in _curves.size():
		var e: Dictionary = entries[i]
		var curve: PackedFloat32Array = _curves[i]
		if curve.size() < 2:
			continue
		var colour: Color = e["colour"]
		var pts := PackedVector2Array()
		pts.resize(curve.size())
		for j: int in curve.size():
			pts[j] = Vector2(_x_of_index(r, j), _y_of(r, curve[j]))
		if bool(e.get("fill", false)):
			_draw_fill(r, pts, colour)
		t.glow_line(self, pts, colour, LINE_W)


## The area under a curve, faded downward. Drawn as one polygon with per-vertex
## colours: a gradient without a shader and without a texture.
func _draw_fill(r: Rect2, pts: PackedVector2Array, colour: Color) -> void:
	var base_y: float = clampf(_y_of(r, maxf(0.0, _lo)), r.position.y, r.position.y + r.size.y)
	var poly := PackedVector2Array()
	var cols := PackedColorArray()
	for p: Vector2 in pts:
		poly.append(p)
		cols.append(Color(colour.r, colour.g, colour.b, 0.26))
	for i: int in range(pts.size() - 1, -1, -1):
		poly.append(Vector2(pts[i].x, base_y))
		cols.append(Color(colour.r, colour.g, colour.b, 0.02))
	if poly.size() >= 3:
		draw_polygon(poly, cols)


func _draw_marks(t: LcnStatsTheme, r: Rect2) -> void:
	if marks.is_empty():
		return
	var small: int = t.fs(t.FS_TINY)
	var lane: int = 0
	var last_x: float = -1000.0
	for m: Dictionary in marks:
		var x: float = _x_of_tick(r, int(m["tick"]))
		if x < r.position.x or x > r.position.x + r.size.x:
			continue
		var colour: Color = LcnStatsJournal.kind_colour(int(m["kind"]))
		t.dashed_v(self, x, r.position.y, r.position.y + r.size.y,
			Color(colour.r, colour.g, colour.b, 0.55), 4.0, 1.0)
		draw_circle(Vector2(x, r.position.y + r.size.y), 2.5, colour)
		# Labels stack into three lanes so two events a second apart do not
		# overprint each other into an unreadable smear.
		if x - last_x < 90.0:
			lane = (lane + 1) % 3
		else:
			lane = 0
		last_x = x
		var text: String = String(m["text"])
		var w: float = t.text_width(text, small)
		var tx: float = clampf(x + 4.0, r.position.x, r.position.x + r.size.x - w - 4.0)
		var ty: float = r.position.y + 12.0 + float(lane) * (float(small) + 4.0)
		t.pill(self, Rect2(Vector2(tx - 3.0, ty - float(small)),
			Vector2(w + 6.0, float(small) + 5.0)),
			Color(t.PANEL.r, t.PANEL.g, t.PANEL.b, 0.86),
			Color(colour.r, colour.g, colour.b, 0.55))
		t.text(self, Vector2(tx, ty), text, small, colour)


func _draw_crosshair(t: LcnStatsTheme, r: Rect2) -> void:
	if _hover < _from or _hover >= _from + _count or _count < 2:
		return
	var j: int = _hover - _from
	var x: float = _x_of_index(r, j)
	t.dashed_v(self, x, r.position.y, r.position.y + r.size.y,
		Color(t.ACCENT.r, t.ACCENT.g, t.ACCENT.b, 0.55), 3.0, 1.0)

	var small: int = t.fs(t.FS_SMALL)
	var lines: Array[Dictionary] = []
	lines.append({"label": LcnStatsTheme.ticks_as_clock(track.tick_at(_hover)),
		"value": "", "colour": t.TEXT_BRIGHT})
	for i: int in _curves.size():
		var curve: PackedFloat32Array = _curves[i]
		if j >= curve.size():
			continue
		draw_circle(Vector2(x, _y_of(r, curve[j])), 3.0, entries[i]["colour"])
		lines.append({"label": String(entries[i]["label"]),
			"value": LcnStatsTheme.compact(curve[j]), "colour": entries[i]["colour"]})

	var w: float = 0.0
	for l: Dictionary in lines:
		w = maxf(w, t.text_width(String(l["label"]), small)
			+ t.text_width(String(l["value"]), small) + 22.0)
	var h: float = float(lines.size()) * (float(small) + 5.0) + 8.0
	var bx: float = x + 12.0
	if bx + w > r.position.x + r.size.x:
		bx = x - w - 12.0
	bx = clampf(bx, r.position.x + 2.0, maxf(r.position.x + 2.0, r.position.x + r.size.x - w - 2.0))
	var by: float = clampf(r.position.y + 8.0, r.position.y, r.position.y + r.size.y - h)
	t.pill(self, Rect2(Vector2(bx, by), Vector2(w, h)),
		Color(t.PANEL_HEAD.r, t.PANEL_HEAD.g, t.PANEL_HEAD.b, 0.95), t.RIM)
	var y: float = by + float(small) + 4.0
	for l2: Dictionary in lines:
		t.text(self, Vector2(bx + 7.0, y), String(l2["label"]), small, l2["colour"])
		t.text_right(self, bx + w - 7.0, y, String(l2["value"]), small, t.TEXT)
		y += float(small) + 5.0


func _draw_legend(t: LcnStatsTheme) -> void:
	var small: int = t.fs(t.FS_SMALL)
	var y: float = size.y - 4.0
	var x: float = t.AXIS_L
	for i: int in entries.size():
		var e: Dictionary = entries[i]
		var label: String = String(e["label"])
		var w: float = t.text_width(label, small)
		if x + w + 20.0 > size.x:
			break
		t.swatch(self, Rect2(Vector2(x, y - float(small) + 1.0), Vector2(9.0, 9.0)),
			e["colour"])
		t.text(self, Vector2(x + 13.0, y), label, small, t.TEXT_DIM)
		x += w + 26.0


# ===============================================================  geometry ===

func _x_of_index(r: Rect2, j: int) -> float:
	if _count <= 1:
		return r.position.x
	return r.position.x + r.size.x * float(j) / float(_count - 1)


func _x_of_tick(r: Rect2, tick: int) -> float:
	if track == null or _count <= 1:
		return r.position.x
	var a: int = track.tick_at(_from)
	var b: int = track.tick_at(_from + _count - 1)
	if b <= a:
		return r.position.x
	return r.position.x + r.size.x * clampf(float(tick - a) / float(b - a), 0.0, 1.0)


func _y_of(r: Rect2, v: float) -> float:
	var f: float = (v - _lo) / maxf(0.000001, _hi - _lo)
	return r.position.y + r.size.y * (1.0 - clampf(f, 0.0, 1.0))


func _theme() -> LcnStatsTheme:
	if theme_ref == null:
		theme_ref = LcnStatsTheme.new()
	return theme_ref
