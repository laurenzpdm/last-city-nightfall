class_name LcnStatusIcons
extends LcnOverlayLayer
## [P19] The always-on legibility layer. No key, no mode, no toggle.
##
## THE RULE: a healthy base is silent and a sick one is loud. Nothing is drawn
## over a building that is doing its job — no bars, no icons, no rings — so the
## art [P13] made stays the thing you look at. The moment something is wrong a
## badge appears over exactly that building, and only badges that mean "act now"
## pulse.
##
## Priority is strict, worst wins, one badge per building: a frozen workshop is
## not also told it has no crew. That is what keeps a failing district readable
## instead of a wall of icons.
##
## Zoom is handled honestly rather than by scaling everything down until it is
## invisible: past strategic zoom the badges CLUSTER, one marker per district
## with a count, so a whole city fits on screen and still reads.

const BADGE_LIMIT: int = 56
const CLUSTER_ZOOM: float = 1.9        ## world px per screen px past which we cluster
const CLUSTER_TILES: float = 12.0
const BADGE_PX: float = 11.0

var _glyphs: PackedVector2Array = PackedVector2Array()
var _glyph_cols: PackedColorArray = PackedColorArray()
var _clusters: Dictionary[Vector2i, int] = {}
var _cluster_worst: Dictionary[Vector2i, int] = {}
var _stall_reason: Dictionary[int, String] = {}
var _stall_tick: int = -1
## World-space rectangles of the badge labels already drawn THIS frame.
## See `_label_if_clear`.
var _label_rects: Array[Rect2] = []


func _init() -> void:
	super()
	name = "StatusIcons"


func _draw() -> void:
	if snap == null or snap.bld_count == 0:
		return
	var t0: int = Time.get_ticks_usec()
	_glyphs.clear()
	_glyph_cols.clear()
	_refresh_stalls()
	if wpp > CLUSTER_ZOOM:
		_draw_clustered()
	else:
		_draw_badges()
	if _glyphs.size() >= 2:
		draw_multiline_colors(_glyphs, _glyph_cols, stroke(1.8))
	draw_us = Time.get_ticks_usec() - t0


func _refresh_stalls() -> void:
	if snap.last_tick == _stall_tick:
		return
	_stall_tick = snap.last_tick
	_stall_reason.clear()
	if not snap.probe.has_stalls():
		return
	for s: Dictionary in snap.probe.stalls():
		_stall_reason[int(s.get("id", -1))] = String(s.get("reason", "stalled"))


# =========================================================================
# what is wrong with this building
# =========================================================================

## Worst problem for building row `i`, or Problem.NONE when it is fine.
func problem_of(i: int) -> int:
	var worst: int = LcnOverlayDefs.Problem.NONE
	var flags: int = snap.bld_flags[i]

	# A construction site is not a damaged building and not an understaffed one:
	# a fresh ghost starts at a fraction of full hp and has no crew by
	# definition. Badging it red was the difference between a base that reads
	# and a base covered in false alarms.
	if (flags & LcnOverlaySnapshot.B_GHOST) != 0:
		return LcnOverlayDefs.Problem.BUILDING if alt else LcnOverlayDefs.Problem.NONE
	if snap.bld_hp[i] < 0.55:
		worst = maxi(worst, LcnOverlayDefs.Problem.DAMAGED)
	# bld_workers is -1 until [P05] actually staffs anything.
	if snap.bld_need[i] > 0 and snap.bld_workers[i] >= 0 and snap.bld_workers[i] < snap.bld_need[i]:
		worst = maxi(worst, LcnOverlayDefs.Problem.NO_WORKER)

	var reason: String = _stall_reason.get(snap.bld_id[i], "")
	if reason != "":
		if reason.contains("output") or reason.contains("full") or reason.contains("blocked"):
			worst = maxi(worst, LcnOverlayDefs.Problem.OUTPUT_FULL)
		elif reason.contains("cold") or reason.contains("heat") or reason.contains("power"):
			pass   # the heat read below says it better, and says which pipe
		elif reason.contains("crew") or reason.contains("staff") or reason.contains("worker"):
			worst = maxi(worst, LcnOverlayDefs.Problem.NO_WORKER)
		else:
			worst = maxi(worst, LcnOverlayDefs.Problem.NO_INPUT)

	var row: int = snap.node_row.get(snap.bld_id[i], -1)
	if row >= 0:
		var hf: int = snap.node_flags[row]
		if (hf & LcnOverlayDefs.F_STARVED_FUEL) != 0:
			worst = maxi(worst, LcnOverlayDefs.Problem.NO_FUEL)
		if (hf & LcnOverlayDefs.F_CONSUMER) != 0 and (hf & LcnOverlayDefs.F_DISABLED) == 0:
			var served: float = snap.node_served[row]
			if (hf & LcnOverlayDefs.F_NO_NETWORK) != 0 or (hf & LcnOverlayDefs.F_UNREACHABLE) != 0:
				worst = maxi(worst, LcnOverlayDefs.Problem.UNPOWERED)
			elif served < 0.25:
				worst = maxi(worst, LcnOverlayDefs.Problem.NO_HEAT)
			elif served < 0.999:
				worst = maxi(worst, LcnOverlayDefs.Problem.BROWNOUT)
		if (hf & LcnOverlayDefs.F_FROZEN) != 0:
			worst = maxi(worst, LcnOverlayDefs.Problem.FROZEN)
	return worst


func problem_color(p: int) -> Color:
	match LcnOverlayDefs.problem_severity(p):
		2:
			return pal.ice() if p == LcnOverlayDefs.Problem.FROZEN else pal.bad()
		1:
			return pal.warn()
	return pal.info()


# =========================================================================
# drawing
# =========================================================================

## A badge label, unless another one is already standing there.
##
## THE BADGES SURVIVE A CROWD AND THE WORDS BESIDE THEM DO NOT. One badge per
## building is the rule this whole file is built on, and it holds — but with ALT
## down every badge also prints its problem in words, and a row of construction
## sites is a row of overlapping words. `artifacts/play1/shots/assault.png`, the
## reference frame the art and UI parts grade against, has a strip across the top
## of the city reading "building building buildinginginging": eleven true labels
## rendered into one false one. The ALT reading is exactly the moment a player is
## leaning in to find out what is wrong, and it is the moment the layer stops
## being able to tell them.
##
## The badge itself still draws — the circle, the ring and the glyph survive a
## crowd, and their colour is the severity. Only the WORD is dropped, and only
## when the pixels it wants are already spoken for. Deterministic: the loop walks
## buildings in index order, so the same frame always keeps the same labels.
func _label_if_clear(at: Vector2, text: String, size_px: float, c: Color) -> void:
	if font == null or text == "":
		return
	var s: int = maxi(8, int(round(size_px)))
	var size: Vector2 = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, s)
	# `label()` puts the BASELINE at `at`, so the box hangs above it.
	var box := Rect2(at - Vector2(0.0, size.y * 0.8 * wpp),
		Vector2(size.x * wpp, size.y * wpp))
	for taken: Rect2 in _label_rects:
		if taken.intersects(box):
			return
	_label_rects.append(box)
	label(at, text, size_px, c)


func _draw_badges() -> void:
	var beat: float = LcnOverlayGeometry.pulse(time_s, 1.1, pal.reduce_motion)
	_label_rects.clear()
	var shown: int = 0
	for i: int in snap.bld_count:
		if shown >= BADGE_LIMIT:
			break
		var r: Rect2 = snap.bld_rect(i)
		if not visible_rect(r.grow(TILE)):
			continue
		var p: int = problem_of(i)
		if p == LcnOverlayDefs.Problem.NONE:
			continue
		shown += 1
		var sev: int = LcnOverlayDefs.problem_severity(p)
		var c: Color = problem_color(p)
		var radius: float = px(BADGE_PX) * (1.0 + (0.12 * beat if sev >= 1 else 0.0))
		# Above the building, never on it.
		var at := Vector2(r.get_center().x, r.position.y - radius - px(4.0))
		if sev >= 2:
			draw_circle(at, radius * 1.85, LcnOverlayPalette.with_a(c, pal.fill(0.10 + 0.10 * beat)))
		draw_circle(at, radius, Color(0.035, 0.05, 0.078, 0.94))
		LcnOverlayGeometry.ring(at, radius, 20, _glyphs)
		var rim: Color = LcnOverlayPalette.with_a(c, 0.5 + 0.5 * beat if sev >= 1 else 0.85)
		for _k: int in 20:
			_glyph_cols.append(rim)
		_glyph(p, at, radius * 0.62, c)
		if alt or p == LcnOverlayDefs.Problem.FROZEN:
			_label_if_clear(at + Vector2(radius + px(4.0), px(4.0)),
				LcnOverlayDefs.problem_label(p), 12.0, c)
		if p == LcnOverlayDefs.Problem.BUILDING:
			_progress_arc(at, radius * 0.8, snap.bld_progress[i], c)


## Zoomed out: one marker per district, with how many things are wrong in it.
## The alternative — shrinking every badge — produces a screen of unreadable
## confetti, which is the failure mode this whole part exists to avoid.
func _draw_clustered() -> void:
	_clusters.clear()
	_cluster_worst.clear()
	var size: float = CLUSTER_TILES * TILE
	for i: int in snap.bld_count:
		var r: Rect2 = snap.bld_rect(i)
		if not visible_rect(r.grow(size)):
			continue
		var p: int = problem_of(i)
		if p <= LcnOverlayDefs.Problem.BUILDING:
			continue
		var key: Vector2i = LcnOverlayGeometry.cluster_key(r.get_center(), size)
		_clusters[key] = _clusters.get(key, 0) + 1
		_cluster_worst[key] = maxi(_cluster_worst.get(key, 0), p)
	var keys: Array = _clusters.keys()
	keys.sort()
	var beat: float = LcnOverlayGeometry.pulse(time_s, 0.9, pal.reduce_motion)
	var shown: int = 0
	for k: Vector2i in keys:
		if shown >= BADGE_LIMIT:
			break
		shown += 1
		var p2: int = _cluster_worst[k]
		var c: Color = problem_color(p2)
		var at := Vector2(float(k.x) + 0.5, float(k.y) + 0.5) * size
		var radius: float = px(13.0) * (1.0 + 0.1 * beat)
		draw_circle(at, radius * 1.7, LcnOverlayPalette.with_a(c, pal.fill(0.12)))
		draw_circle(at, radius, Color(0.035, 0.05, 0.078, 0.94))
		LcnOverlayGeometry.ring(at, radius, 20, _glyphs)
		for _j: int in 20:
			_glyph_cols.append(LcnOverlayPalette.with_a(c, 0.9))
		label(at - Vector2(px(5.0), -px(5.0)), str(_clusters[k]), 15.0, c)


func _progress_arc(at: Vector2, radius: float, t: float, c: Color) -> void:
	var steps: int = 18
	var span: float = TAU * clampf(t, 0.0, 1.0)
	if span <= 0.01:
		return
	var prev: Vector2 = at + Vector2(0.0, -radius)
	for i: int in range(1, steps + 1):
		var a: float = -PI * 0.5 + span * float(i) / float(steps)
		var p: Vector2 = at + Vector2(cos(a), sin(a)) * radius
		_glyphs.append(prev)
		_glyphs.append(p)
		_glyph_cols.append(LcnOverlayPalette.with_a(c, 0.9))
		prev = p


# =========================================================================
# glyphs — line art, batched into the same draw call as the badge rims
# =========================================================================

func _glyph(p: int, at: Vector2, r: float, c: Color) -> void:
	var before: int = _glyphs.size()
	match p:
		LcnOverlayDefs.Problem.FROZEN:
			_snowflake(at, r)
		LcnOverlayDefs.Problem.NO_HEAT:
			_bolt(at, r)
			_slash(at, r * 1.25)
		LcnOverlayDefs.Problem.BROWNOUT:
			_bolt(at, r)
		LcnOverlayDefs.Problem.UNPOWERED:
			_unplugged(at, r)
		LcnOverlayDefs.Problem.NO_FUEL:
			_flame(at, r)
			_slash(at, r * 1.25)
		LcnOverlayDefs.Problem.NO_WORKER:
			_person(at, r)
		LcnOverlayDefs.Problem.NO_INPUT:
			_inbox(at, r)
		LcnOverlayDefs.Problem.OUTPUT_FULL:
			_full_box(at, r)
		LcnOverlayDefs.Problem.DAMAGED:
			_crack(at, r)
		_:
			_hammer(at, r)
	for _k: int in (_glyphs.size() - before) / 2:
		_glyph_cols.append(c)


func _seg(a: Vector2, b: Vector2) -> void:
	_glyphs.append(a)
	_glyphs.append(b)


func _snowflake(at: Vector2, r: float) -> void:
	for i: int in 3:
		var a: float = PI * float(i) / 3.0
		var d := Vector2(cos(a), sin(a)) * r
		_seg(at - d, at + d)
		var tipa: Vector2 = at + d
		var tipb: Vector2 = at - d
		var n := Vector2(-d.y, d.x).normalized() * r * 0.34
		_seg(tipa, tipa - d.normalized() * r * 0.36 + n)
		_seg(tipa, tipa - d.normalized() * r * 0.36 - n)
		_seg(tipb, tipb + d.normalized() * r * 0.36 + n)
		_seg(tipb, tipb + d.normalized() * r * 0.36 - n)


func _bolt(at: Vector2, r: float) -> void:
	var a := at + Vector2(r * 0.35, -r)
	var b := at + Vector2(-r * 0.35, r * 0.05)
	var cpt := at + Vector2(r * 0.30, r * 0.05)
	var d := at + Vector2(-r * 0.30, r)
	_seg(a, b)
	_seg(b, cpt)
	_seg(cpt, d)


func _slash(at: Vector2, r: float) -> void:
	_seg(at + Vector2(-r * 0.75, -r * 0.75), at + Vector2(r * 0.75, r * 0.75))


func _unplugged(at: Vector2, r: float) -> void:
	_seg(at + Vector2(-r, -r * 0.5), at + Vector2(-r * 0.2, -r * 0.5))
	_seg(at + Vector2(-r, r * 0.5), at + Vector2(-r * 0.2, r * 0.5))
	_seg(at + Vector2(-r * 0.2, -r * 0.75), at + Vector2(-r * 0.2, r * 0.75))
	_seg(at + Vector2(r * 0.2, -r * 0.75), at + Vector2(r * 0.2, r * 0.75))
	_seg(at + Vector2(r * 0.2, -r * 0.5), at + Vector2(r, -r * 0.5))
	_seg(at + Vector2(r * 0.2, r * 0.5), at + Vector2(r, r * 0.5))


func _flame(at: Vector2, r: float) -> void:
	_seg(at + Vector2(0.0, -r), at + Vector2(r * 0.7, r * 0.25))
	_seg(at + Vector2(r * 0.7, r * 0.25), at + Vector2(0.0, r))
	_seg(at + Vector2(0.0, r), at + Vector2(-r * 0.7, r * 0.25))
	_seg(at + Vector2(-r * 0.7, r * 0.25), at + Vector2(0.0, -r))


func _person(at: Vector2, r: float) -> void:
	var head: Vector2 = at + Vector2(0.0, -r * 0.55)
	for i: int in 8:
		var a0: float = TAU * float(i) / 8.0
		var a1: float = TAU * float(i + 1) / 8.0
		_seg(head + Vector2(cos(a0), sin(a0)) * r * 0.34,
			head + Vector2(cos(a1), sin(a1)) * r * 0.34)
	_seg(at + Vector2(0.0, -r * 0.16), at + Vector2(0.0, r * 0.55))
	_seg(at + Vector2(-r * 0.6, r * 0.1), at + Vector2(r * 0.6, r * 0.1))
	_seg(at + Vector2(0.0, r * 0.55), at + Vector2(-r * 0.45, r))
	_seg(at + Vector2(0.0, r * 0.55), at + Vector2(r * 0.45, r))


func _inbox(at: Vector2, r: float) -> void:
	_seg(at + Vector2(-r, r * 0.15), at + Vector2(-r, r))
	_seg(at + Vector2(-r, r), at + Vector2(r, r))
	_seg(at + Vector2(r, r), at + Vector2(r, r * 0.15))
	_seg(at + Vector2(0.0, -r), at + Vector2(0.0, r * 0.25))
	_seg(at + Vector2(0.0, r * 0.25), at + Vector2(-r * 0.42, -r * 0.2))
	_seg(at + Vector2(0.0, r * 0.25), at + Vector2(r * 0.42, -r * 0.2))


func _full_box(at: Vector2, r: float) -> void:
	_seg(at + Vector2(-r, -r * 0.25), at + Vector2(r, -r * 0.25))
	_seg(at + Vector2(-r, -r * 0.25), at + Vector2(-r, r))
	_seg(at + Vector2(r, -r * 0.25), at + Vector2(r, r))
	_seg(at + Vector2(-r, r), at + Vector2(r, r))
	_seg(at + Vector2(-r * 0.75, -r), at + Vector2(r * 0.75, -r))


func _crack(at: Vector2, r: float) -> void:
	_seg(at + Vector2(-r * 0.2, -r), at + Vector2(r * 0.3, -r * 0.25))
	_seg(at + Vector2(r * 0.3, -r * 0.25), at + Vector2(-r * 0.35, r * 0.2))
	_seg(at + Vector2(-r * 0.35, r * 0.2), at + Vector2(r * 0.2, r))


func _hammer(at: Vector2, r: float) -> void:
	_seg(at + Vector2(-r * 0.8, -r * 0.45), at + Vector2(r * 0.2, -r * 0.45))
	_seg(at + Vector2(-r * 0.8, -r * 0.45), at + Vector2(-r * 0.8, r * 0.1))
	_seg(at + Vector2(r * 0.2, -r * 0.45), at + Vector2(r * 0.2, r * 0.1))
	_seg(at + Vector2(-r * 0.8, r * 0.1), at + Vector2(r * 0.2, r * 0.1))
	_seg(at + Vector2(-r * 0.3, r * 0.1), at + Vector2(r * 0.55, r))
