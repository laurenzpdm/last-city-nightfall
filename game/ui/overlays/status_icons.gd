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
## invisible. Three thresholds, all measured in SCREEN pixels so that the rule is
## about what the player can actually resolve rather than about the city:
##
##   badges closer than 27 px MERGE into one marker with a count
##   badges of the same problem within 220 px share ONE word
##   past `CLUSTER_ZOOM` the whole thing becomes one marker per district
##
## and every word this layer wants goes through `LcnLabelField` along with every
## word the active lens wants, because the player is looking at one frame.

const BADGE_LIMIT: int = 56
const CLUSTER_ZOOM: float = 1.9        ## world px per screen px past which we cluster
const CLUSTER_TILES: float = 12.0
const BADGE_PX: float = 11.0
## Two badges closer than this on SCREEN are one marker with a count. It is the
## zoom, not the city, that decides: at 1.6 nothing merges and every building
## keeps its own badge; at 0.50 a district answers with one mark.
const BADGE_MERGE_PX: float = 27.0
## Badges of the same problem within this many SCREEN px share one word.
const WORD_CLUSTER_PX: float = 220.0

var _glyphs: PackedVector2Array = PackedVector2Array()
var _glyph_cols: PackedColorArray = PackedColorArray()
var _clusters: Dictionary[Vector2i, int] = {}
var _cluster_worst: Dictionary[Vector2i, int] = {}
var _stall_reason: Dictionary[int, String] = {}
var _stall_tick: int = -1
## Merged badge markers for this frame, in building index order.
var _mark_at: Array[Vector2] = []
var _mark_problem: PackedInt32Array = PackedInt32Array()
var _mark_count: PackedInt32Array = PackedInt32Array()
var _mark_progress: PackedFloat32Array = PackedFloat32Array()
## The pixels each marker owns — its disc plus the count printed on it. Words go
## outside this, never through it.
var _mark_claim: Array[Rect2] = []
## Every badge position seen, and the marker it belongs to. Merging is SINGLE
## LINKAGE over these — a new badge joins if it is close to ANY member, not only
## to the first one — which is what collapses a ladder of evenly spaced sites
## instead of halving it.
var _link_at: Array[Vector2] = []
var _link_mark: PackedInt32Array = PackedInt32Array()
## Spatial index over `_link_at`, so merging is O(buildings) rather than
## O(buildings x badges) and stays deterministic: cells are visited in a fixed
## order and buildings are walked in index order.
var _mark_grid: Dictionary[Vector2i, PackedInt32Array] = {}
var _clustered: bool = false


func _init() -> void:
	super()
	name = "StatusIcons"


## THE MARKS ARE DECIDED AND THEIR PIXELS CLAIMED HERE, NOT IN `_draw()`.
##
## Every layer's `sync()` runs before any layer's `_draw()`, and that ordering is
## the root's to control. Draw order is not: it is a property of the canvas item
## tree, and when the lens happened to paint first, its verdicts were placed
## against a field that had not yet been told where the badges were — and
## `= GRID 5 0/12 heat/s NO SOURCE` came out straight across three of them. A
## correctness rule that depends on which node the engine walks first is not a
## rule. So the reservation happens at sync, unconditionally, before the first
## word of the frame can be requested by anybody.
func sync(s: LcnOverlaySnapshot, p: LcnOverlayPalette, v: Rect2, world_per_px: float,
		t: float, alt_held: bool, detail_level: int, f: LcnLabelField = null) -> void:
	super.sync(s, p, v, world_per_px, t, alt_held, detail_level, f)
	if snap == null or snap.bld_count == 0:
		return
	_refresh_stalls()
	_clustered = wpp > CLUSTER_ZOOM
	if _clustered:
		_collect_clusters()
	else:
		_collect_marks()
	for claim: Rect2 in _mark_claim:
		reserve(claim)


func _draw() -> void:
	if snap == null or snap.bld_count == 0:
		return
	var t0: int = Time.get_ticks_usec()
	_glyphs.clear()
	_glyph_cols.clear()
	if _clustered:
		_draw_clustered()
	else:
		_draw_badges()
	if _glyphs.size() >= 2:
		draw_multiline_colors(_glyphs, _glyph_cols, stroke(1.8))
	flush_labels()
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

## ONE MARK PER THING THE PLAYER CARES ABOUT, NOT ONE PER TILE.
##
## The old rule was one badge per building, and it is a good rule right up until
## the badges are closer together on screen than a badge is wide. In
## `artifacts/CRIT/shots/assault.world.png` — the reference frame the art and UI
## parts grade against — it produced a VERTICAL LADDER of 22 identical
## "building" chips down the centre of the screen. A critic's word for the frame
## was "a crash dump", and they were right: 22 marks carrying one fact between
## them is not 22 facts, it is one fact printed 22 times.
##
## So the badges MERGE by screen distance. Two problems closer than
## `BADGE_MERGE_PX` become one marker with a count, worst problem winning, and
## because the threshold is in SCREEN pixels the behaviour falls out of the zoom:
## at 1.60 nothing merges and every building keeps its own badge, at 0.50 a whole
## district answers with one mark and a number. Nothing is hidden — the count is
## on the marker — and the pass is deterministic, walking buildings in index
## order over a fixed-order cell grid, so the same frame always merges the same
## way and a drifting camera does not make the marks flicker.
## How far a merged marker may reach from where it started, as a multiple of
## `BADGE_MERGE_PX`. Single linkage with no leash chains across a contiguous city
## and answers a screenful of trouble with one dot; four badge-widths keeps a
## marker to something a player can point at.
const MARK_EXTENT: float = 4.0


func _collect_marks() -> void:
	_mark_at.clear()
	_mark_problem.clear()
	_mark_count.clear()
	_mark_progress.clear()
	_mark_claim.clear()
	_link_at.clear()
	_link_mark.clear()
	_mark_grid.clear()
	var merge: float = px(BADGE_MERGE_PX)
	var leash: float = merge * MARK_EXTENT
	var radius: float = px(BADGE_PX)
	for i: int in snap.bld_count:
		var r: Rect2 = snap.bld_rect(i)
		if not visible_rect(r.grow(TILE)):
			continue
		var p: int = problem_of(i)
		if p == LcnOverlayDefs.Problem.NONE:
			continue
		var at := Vector2(r.get_center().x, r.position.y - radius - px(4.0))
		var into: int = _nearest_mark(at, merge, leash)
		if into < 0 and _mark_at.size() < BADGE_LIMIT:
			into = _mark_at.size()
			_mark_at.append(at)
			_mark_problem.append(p)
			_mark_count.append(0)
			_mark_progress.append(snap.bld_progress[i])
			_mark_claim.append(Rect2())
		if into < 0:
			continue
		_mark_count[into] += 1
		if p > _mark_problem[into]:
			_mark_problem[into] = p
			_mark_progress[into] = snap.bld_progress[i]
		_mark_claim[into] = _claim_of(_mark_at[into], radius * 1.12, _mark_count[into])
		var key: Vector2i = LcnOverlayGeometry.cluster_key(at, merge)
		var bucket: PackedInt32Array = _mark_grid.get(key, PackedInt32Array())
		bucket.append(_link_at.size())
		_mark_grid[key] = bucket
		_link_at.append(at)
		_link_mark.append(into)


## The pixels a marker owns: its disc at its LARGEST (the pulse makes the rim
## breathe, and a claim that shrank with the beat would let a word in on the down
## stroke) plus room for the count printed beside the glyph.
func _claim_of(at: Vector2, radius: float, count: int) -> Rect2:
	var box := Rect2(at - Vector2(radius, radius) * 1.15, Vector2(radius, radius) * 2.3)
	if count > 1:
		box.size.x += px(20.0)
	return box


## The marker of the closest badge already placed within `merge` world units,
## provided that marker's origin is still within `leash`. -1 for a new marker.
func _nearest_mark(at: Vector2, merge: float, leash: float) -> int:
	var key: Vector2i = LcnOverlayGeometry.cluster_key(at, merge)
	var best: int = -1
	var best_d: float = merge * merge
	for dy: int in [-1, 0, 1]:
		for dx: int in [-1, 0, 1]:
			var bucket: PackedInt32Array = _mark_grid.get(key + Vector2i(dx, dy),
				PackedInt32Array())
			for k: int in bucket:
				var d: float = _link_at[k].distance_squared_to(at)
				if d >= best_d:
					continue
				var m: int = _link_mark[k]
				if _mark_at[m].distance_to(at) > leash:
					continue
				best_d = d
				best = m
	return best


func _draw_badges() -> void:
	var beat: float = LcnOverlayGeometry.pulse(time_s, 1.1, pal.reduce_motion)
	for m: int in _mark_at.size():
		var p: int = _mark_problem[m]
		var n: int = _mark_count[m]
		var sev: int = LcnOverlayDefs.problem_severity(p)
		var c: Color = problem_color(p)
		var radius: float = px(BADGE_PX) * (1.0 + (0.12 * beat if sev >= 1 else 0.0))
		var at: Vector2 = _mark_at[m]
		if sev >= 2:
			draw_circle(at, radius * 1.85, LcnOverlayPalette.with_a(c, pal.fill(0.10 + 0.10 * beat)))
		draw_circle(at, radius, Color(0.035, 0.05, 0.078, 0.94))
		LcnOverlayGeometry.ring(at, radius, 20, _glyphs)
		var rim: Color = LcnOverlayPalette.with_a(c, 0.5 + 0.5 * beat if sev >= 1 else 0.85)
		for _k: int in 20:
			_glyph_cols.append(rim)
		_glyph(p, at, radius * 0.62, c)
		if p == LcnOverlayDefs.Problem.BUILDING and n == 1:
			_progress_arc(at, radius * 0.8, _mark_progress[m], c)
		if n > 1:
			mark_text(at + Vector2(radius * 0.7, -radius * 0.45), "%d" % n, 12.0, c)
	_draw_mark_words()


## The words beside the marks — one per PROBLEM per neighbourhood, never one per
## building. "no crew ×7" is the fact; seven chips reading "no crew" is the same
## fact, seven times, in each other's way.
##
## How many neighbourhoods may each speak at once is decided by the zoom: close
## in, three chips of the same problem are three places to look at; at strategic
## zoom the city answers once with a total.
func _draw_mark_words() -> void:
	if _mark_at.is_empty():
		return
	var cell: float = px(WORD_CLUSTER_PX)
	var groups: Dictionary[Vector3i, int] = {}   ## (problem, cell x, cell y) -> count
	var anchor: Dictionary[Vector3i, Vector2] = {}
	var seq: Dictionary[Vector3i, int] = {}
	var order: Array[Vector3i] = []
	for m: int in _mark_at.size():
		var p: int = _mark_problem[m]
		if not (alt or LcnOverlayDefs.problem_severity(p) >= 2):
			continue
		var k: Vector2i = LcnOverlayGeometry.cluster_key(_mark_at[m], cell)
		var g := Vector3i(p, k.x, k.y)
		if not groups.has(g):
			groups[g] = 0
			# Clear of the marker's own claim, which is wider when the marker is
			# carrying a count. A word placed inside it was refused for
			# overlapping the very mark it belongs to, and the whole layer went
			# silent — 33 marks and not one word, which reads as "nothing is
			# wrong" over a city with three buildings frozen solid.
			var claim: Rect2 = _mark_claim[m] if m < _mark_claim.size() \
				else Rect2(_mark_at[m], Vector2.ZERO)
			anchor[g] = Vector2(claim.position.x + claim.size.x + px(4.0),
				_mark_at[m].y + px(4.0))
			seq[g] = order.size()
			order.append(g)
		groups[g] = groups[g] + _mark_count[m]
	# Loudest first, then the order they were met, so the frame is stable.
	order.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		var sa: int = LcnOverlayDefs.problem_severity(a.x)
		var sb: int = LcnOverlayDefs.problem_severity(b.x)
		if sa != sb:
			return sa > sb
		return seq[a] < seq[b])
	var copies: int = 1 if wpp >= 1.0 else 3
	for g: Vector3i in order:
		var p2: int = g.x
		var n: int = groups[g]
		var text: String = LcnOverlayDefs.problem_label(p2)
		if n > 1:
			text += "  ×%d" % n
		var sev: int = LcnOverlayDefs.problem_severity(p2)
		word(anchor[g], text, 12.0, problem_color(p2),
			LcnLabelField.Rank.FIGURE if sev >= 2 else LcnLabelField.Rank.AMBIENT,
			copies, LcnOverlayDefs.problem_label(p2))


## Zoomed out: one marker per district, with how many things are wrong in it.
## The alternative — shrinking every badge — produces a screen of unreadable
## confetti, which is the failure mode this whole part exists to avoid.
func _collect_clusters() -> void:
	_clusters.clear()
	_cluster_worst.clear()
	_mark_at.clear()
	_mark_problem.clear()
	_mark_count.clear()
	_mark_progress.clear()
	_mark_claim.clear()
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
	var radius: float = px(13.0) * 1.1
	for k: Vector2i in keys:
		if _mark_at.size() >= BADGE_LIMIT:
			break
		var at := Vector2(float(k.x) + 0.5, float(k.y) + 0.5) * size
		_mark_at.append(at)
		_mark_problem.append(_cluster_worst[k])
		_mark_count.append(_clusters[k])
		_mark_progress.append(0.0)
		_mark_claim.append(Rect2(at - Vector2(radius, radius) * 1.2,
			Vector2(radius, radius) * 2.4))


func _draw_clustered() -> void:
	var beat: float = LcnOverlayGeometry.pulse(time_s, 0.9, pal.reduce_motion)
	for m: int in _mark_at.size():
		var c: Color = problem_color(_mark_problem[m])
		var at: Vector2 = _mark_at[m]
		var radius: float = px(13.0) * (1.0 + 0.1 * beat)
		draw_circle(at, radius * 1.7, LcnOverlayPalette.with_a(c, pal.fill(0.12)))
		draw_circle(at, radius, Color(0.035, 0.05, 0.078, 0.94))
		LcnOverlayGeometry.ring(at, radius, 20, _glyphs)
		for _j: int in 20:
			_glyph_cols.append(LcnOverlayPalette.with_a(c, 0.9))
		# The count is inside the disc the marker claimed at sync, so it costs no
		# word: a number on a mark is part of the mark, not a chip beside it.
		mark_text(at - Vector2(px(5.0), -px(5.0)), str(_mark_count[m]), 15.0, c)


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
