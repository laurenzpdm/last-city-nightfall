class_name LcnItemLayer
extends LcnItemDrawLayer
## [D2] EVERY ITEM ON EVERY BELT, AT ITS REAL SUB-TILE POSITION.
##
## This is the whole reason this part exists. [P03] has always known where each
## piece of coal is to a hundredth of a tile; `items_for_view()` has always
## handed that out in world pixels; nothing had ever drawn it. A factory that
## simulates its belts and renders none of them is a spreadsheet with weather.
##
## HOW IT IS BATCHED. Items are counting-sorted by kind into one flat position
## array — no per-frame allocation, no dictionary of growing arrays — and each
## run becomes ONE `canvas_item_add_triangle_array` with a single colour. That
## is at most one command per item kind on screen, whether ten items are moving
## or ten thousand. The silhouettes themselves are cached per (shape, radius) in
## `LcnItemArt`, so the per-item work is one Vector2 add per vertex.
##
## HOW IT MOVES BETWEEN TICKS. The simulation steps at 20 Hz; at 60 fps that is
## three frames per step, and an item that only moves on every third frame reads
## as a stutter rather than a flow. Each item is therefore advanced along its
## belt by `speed * DT * alpha` — the exact distance [P03] is about to move it —
## EXCEPT on a tile the classifier calls BACKED_UP, where nothing is going
## anywhere and extrapolating would make a jammed belt shimmer three pixels back
## and forth twenty times a second. That single exception is why the
## interpolation reads the flow state and not just the direction.
##
## HOW IT SURVIVES ZOOM. An item is drawn at its real size in world pixels, so a
## compressed belt genuinely looks compressed. Once a body would fall under about
## two screen pixels it is held at two — items merge into a stream rather than
## dissolving into single-pixel noise — and below the strategic threshold they
## fade out entirely while `LcnBeltFlowLayer` widens into flow ribbons in their
## place. The handover is a cross-fade across a deliberate band, not a pop.

## Never let a body fall under this on screen; under it, items stop being items
## and become sub-pixel dither.
const MIN_SCREEN_RADIUS: float = 2.15
## And never let one grow past this in the world, or a far-zoom belt turns into
## a caterpillar twice the width of its own tile.
const MAX_WORLD_RADIUS: float = 6.0
## Above this many bodies on screen the rim pass is dropped. Honest degradation:
## every item is still drawn, they just stop being outlined. A rim doubles the
## geometry, and past this count it is buying an outline nobody can resolve.
const RIM_BUDGET: int = 1200
## Rim size as a fraction of the body radius.
const RIM_GROWTH: float = 1.34

var items_drawn: int = 0
var kinds_drawn: int = 0
var rimmed: bool = false

## Kind -> slot, grown once per new item kind and kept for the life of the layer.
var _slot_of: Dictionary[StringName, int] = {}
var _kinds: Array[StringName] = []

var _counts: PackedInt32Array = PackedInt32Array()
var _starts: PackedInt32Array = PackedInt32Array()
var _cursor: PackedInt32Array = PackedInt32Array()
var _pos: PackedVector2Array = PackedVector2Array()
var _slot: PackedInt32Array = PackedInt32Array()
var _sorted: PackedVector2Array = PackedVector2Array()
var _soup: PackedVector2Array = PackedVector2Array()
var _one: PackedColorArray = PackedColorArray([Color.WHITE])


func _init() -> void:
	super()
	name = "BeltItems"
	var mat := CanvasItemMaterial.new()
	# Unshaded, but NOT additive: an ingot is an object lying on a belt, not a
	# light. It has to look like it is sitting there in the same world as the
	# belt, while still refusing to be graded into invisibility at night.
	mat.light_mode = CanvasItemMaterial.LIGHT_MODE_UNSHADED
	material = mat


## World radius one item body is drawn at, for this zoom. Public: the frame
## suite asserts the zoom policy against it instead of against pixels.
func body_radius() -> float:
	return clampf(maxf(LcnItemArt.BODY_RADIUS_PX, MIN_SCREEN_RADIUS / zoom),
		LcnItemArt.BODY_RADIUS_PX, MAX_WORLD_RADIUS)


func _draw() -> void:
	items_drawn = 0
	kinds_drawn = 0
	rimmed = false
	drawn = 0
	if read == null or read.items.is_empty() or item_fade <= 0.02:
		draw_us = 0
		return
	var t0: int = Time.get_ticks_usec()

	_gather()
	if items_drawn == 0:
		draw_us = Time.get_ticks_usec() - t0
		return
	_counting_sort()

	var r: float = body_radius()
	var ci: RID = get_canvas_item()
	# Detail follows what the screen can actually show. Under six pixels across,
	# every silhouette is the same four grey pixels, so they all collapse to a
	# quad — which is where most of the cost of a full factory goes.
	var on_screen_px: float = r * 2.0 * zoom
	rimmed = items_drawn <= RIM_BUDGET and on_screen_px >= LcnItemArt.SILHOUETTE_MIN_SCREEN_PX

	# Rims first, all of them, so a body is never outlined over its neighbour.
	if rimmed:
		for s: int in _kinds.size():
			if _counts[s] > 0:
				var look: Dictionary = LcnItemArt.look(_kinds[s])
				var rim_shape: int = LcnItemArt.shape_at(int(look["shape"]), on_screen_px)
				_emit(ci, LcnItemArt.triangles(rim_shape, r * RIM_GROWTH),
					_starts[s], _counts[s], _faded(look["rim"], 0.8))
	for s2: int in _kinds.size():
		if _counts[s2] <= 0:
			continue
		var look2: Dictionary = LcnItemArt.look(_kinds[s2])
		var shape: int = LcnItemArt.shape_at(int(look2["shape"]), on_screen_px)
		_emit(ci, LcnItemArt.triangles(shape, r), _starts[s2], _counts[s2],
			_faded(look2["fill"], 1.0))
		kinds_drawn += 1

	drawn = items_drawn
	draw_us = Time.get_ticks_usec() - t0


## Interpolates and culls every item, recording position and kind slot.
func _gather() -> void:
	var n: int = read.items.size()
	if _pos.size() < n:
		_pos.resize(n)
		_slot.resize(n)
	_counts.resize(_kinds.size())
	_counts.fill(0)
	var step: float = SimClock.DT * alpha
	var margin: float = TILE
	var w: int = 0
	for it: Dictionary in read.items:
		var pos: Vector2 = it["pos"]
		var cell := Vector2i(int(floor(pos.x / TILE)), int(floor(pos.y / TILE)))
		var bi: int = int(read.by_cell.get(cell, -1))
		if bi >= 0:
			var b: Dictionary = read.belts[bi]
			if int(b["state"]) != LcnItemFlowRead.Flow.BACKED_UP:
				pos += Vector2(LogiTypes.dir_vec(int(b["rot"]))) * (float(b["speed"]) * TILE * step)
		if not on_screen(pos, margin):
			continue
		var s: int = _slot_for(StringName(it["kind"]))
		_pos[w] = pos
		_slot[w] = s
		_counts[s] += 1
		w += 1
	items_drawn = w


## Positions laid out kind by kind, so each kind is one contiguous run.
func _counting_sort() -> void:
	var k: int = _kinds.size()
	_starts.resize(k)
	_cursor.resize(k)
	var running: int = 0
	for s: int in k:
		_starts[s] = running
		_cursor[s] = running
		running += _counts[s]
	if _sorted.size() < items_drawn:
		_sorted.resize(items_drawn)
	for i: int in items_drawn:
		var s2: int = _slot[i]
		_sorted[_cursor[s2]] = _pos[i]
		_cursor[s2] += 1


## One command: the same silhouette stamped at every position in one run.
func _emit(ci: RID, shape_tris: PackedVector2Array, from: int, count: int, col: Color) -> void:
	if count <= 0 or shape_tris.is_empty() or col.a <= 0.004:
		return
	var per: int = shape_tris.size()
	var need: int = per * count
	if _soup.size() != need:
		_soup.resize(need)
	var w: int = 0
	for i: int in count:
		var p: Vector2 = _sorted[from + i]
		for v: int in per:
			_soup[w + v] = shape_tris[v] + p
		w += per
	_one[0] = col
	RenderingServer.canvas_item_add_triangle_array(ci, PackedInt32Array(), _soup, _one)


func _slot_for(kind: StringName) -> int:
	if _slot_of.has(kind):
		return _slot_of[kind]
	var s: int = _kinds.size()
	_kinds.append(kind)
	_slot_of[kind] = s
	_counts.resize(_kinds.size())
	return s


func _faded(c: Color, mul: float) -> Color:
	return Color(c.r, c.g, c.b, c.a * mul * item_fade)
