class_name LcnOverlayLayer
extends Node2D
## [P19] Base class for every world-space lens.
##
## Holds the frame context the root hands down (snapshot, palette, view rect,
## zoom, animation clock) and the reusable draw buffers. Buffers are members,
## not locals: a lens that allocates a fresh PackedVector2Array per frame
## allocates a megabyte a second at 60 fps, and this layer draws every frame the
## player has an overlay up.
##
## Sizing rule for the whole part: **every stroke, glyph and label is specified
## in SCREEN pixels and divided by zoom on the way out**, so a lens is exactly
## as readable at strategic zoom as it is with your nose on a pipe.

const TILE: float = 32.0

var snap: LcnOverlaySnapshot = null
var pal: LcnOverlayPalette = null
var view: Rect2 = Rect2()
## World units per screen pixel — 1.0 / camera zoom.
var wpp: float = 1.0
## Seconds of wall time since the overlay came up. View-side only; the sim never
## sees it, so it cannot perturb a replay.
var time_s: float = 0.0
## The player is holding the detail key.
var alt: bool = false
var detail: int = 1

var font: Font = null
var draw_us: int = 0

## THE ARBITER EVERY WORD GOES THROUGH. One instance is shared by the status
## layer and the active lens, because the player sees one frame, not two layers
## — the previous per-layer rectangle lists is exactly why a freeze lens
## temperature could be printed over a status layer "no crew".
var field: LcnLabelField = null

var _lines: PackedVector2Array = PackedVector2Array()
var _cols: PackedColorArray = PackedColorArray()
## Words asked for this frame, drawn at flush_labels() in rank order.
var _words: Array[Dictionary] = []
var _word_seq: int = 0


func _init() -> void:
	z_as_relative = false
	font = ThemeDB.fallback_font


## Called by the root once per frame before queue_redraw().
func sync(s: LcnOverlaySnapshot, p: LcnOverlayPalette, v: Rect2, world_per_px: float,
		t: float, alt_held: bool, detail_level: int, f: LcnLabelField = null) -> void:
	snap = s
	pal = p
	view = v
	wpp = maxf(0.0001, world_per_px)
	time_s = t
	alt = alt_held
	detail = detail_level
	if f != null:
		field = f
	_words.clear()
	_word_seq = 0


## Screen px -> world px.
func px(screen_px: float) -> float:
	return screen_px * wpp


func stroke(screen_px: float) -> float:
	return pal.stroke(screen_px, wpp)


func visible_rect(r: Rect2) -> bool:
	return view.intersects(r)


# --- batched line drawing --------------------------------------------------
#
# push_lines() accumulates; flush_lines() emits ONE draw_multiline_colors for
# everything pushed since the last flush. A lens that issues a draw call per
# ring would spend more time in the driver than in the simulation it explains.

## Appends every segment already in `pts` with one colour.
func push_lines(pts: PackedVector2Array, c: Color) -> void:
	var base: int = _lines.size()
	_lines.resize(base + pts.size())
	_cols.resize(_lines.size() / 2)
	for i: int in pts.size():
		_lines[base + i] = pts[i]
	var from: int = base / 2
	for j: int in range(from, _lines.size() / 2):
		_cols[j] = c


## One draw call for everything pushed since the last flush.
func flush_lines(width: float) -> void:
	if _lines.size() < 2:
		return
	draw_multiline_colors(_lines, _cols, width)
	_lines.clear()
	_cols.clear()


# --- text ------------------------------------------------------------------
#
# NOTHING IN THIS FOLDER DRAWS A WORD DIRECTLY ANY MORE. A lens QUEUES what it
# would like to say with `word()` and the queue is settled once, at the end of
# the frame, by `flush_labels()`. Two things fall out of that and neither was
# achievable while each call site drew as it went:
#
#   * every word in the frame is ranked against every other word in the frame,
#     across layers, so a thermometer reading cannot be the reason a freeze
#     warning had nowhere to go — the old code placed in draw order, and draw
#     order is an accident of which loop a lens happens to run first;
#   * words land ON TOP of the lines and marks of every lens, because the queue
#     is flushed last. Before this, a plate drawn mid-loop was over-struck by
#     the pipes drawn after it.

## Queue a word. Nothing is drawn until `flush_labels()`, and whether it is drawn
## at all is `LcnLabelField`'s decision.
##
## `rank`   LcnLabelField.Rank — what this word is FOR, which is what decides who
##          gets crowded out. See that file.
## `copies` how many times this `key` is worth saying in one frame.
## `key`    what is being named, when that is not the text. Two chips reading
##          "building ×22" and "building ×3" name the same thing.
## `plated` a solid plate behind it, for a verdict that has to survive any
##          background. Plain words carry a halo instead.
## `anchors` are further places the SAME word would be just as true — the second
## and third tile of a heat grid, when the northernmost one is behind the clock.
## They are tried in order after the first, before the word is given up on.
func word(at: Vector2, text: String, size_px: float, c: Color, rank: int,
		copies: int = 1, key: String = "", plated: bool = false,
		centered: bool = false, anchors: PackedVector2Array = PackedVector2Array()) -> void:
	if font == null or text == "":
		return
	var all := PackedVector2Array([at])
	all.append_array(anchors)
	_words.append({
		"at": at, "anchors": all, "text": text, "size": size_px, "color": c,
		"rank": rank, "copies": copies, "key": key, "plated": plated,
		"centered": centered, "seq": _word_seq,
	})
	_word_seq += 1


## Reserve pixels without spending a word — a badge disc, a gauge, a glyph. The
## words placed afterwards will go somewhere else.
func reserve(box: Rect2) -> void:
	if field != null:
		field.reserve(box)


## Paint text immediately, without asking the field, for a number that is PART OF
## A MARK this layer has already reserved — the "×7" inside a merged badge. It is
## not a chip competing for the frame's attention, it is the mark saying how many
## things it stands for, and a mark that could not say so would be worse than no
## merging at all. `at` is the baseline, as everywhere else in this folder.
func mark_text(at: Vector2, text: String, size_px: float, c: Color) -> void:
	if font == null or text == "":
		return
	_paint_label(_label_box(at, text, size_px, false), text, size_px, c)


## Settle the frame's words. Highest rank first, and within a rank the order they
## were asked for, so the same frame always keeps the same words: a lens whose
## labels flickered as the camera drifted would be worse than one that shows too
## many. Call this at the END of `_draw()`.
func flush_labels() -> void:
	if _words.is_empty():
		return
	if field == null:
		field = LcnLabelField.new()
		field.begin(view, wpp, LcnLabelField.budget_for(1.0 / wpp), [])
	_words.sort_custom(_by_rank)
	for w: Dictionary in _words:
		var plated: bool = bool(w["plated"])
		var centered: bool = bool(w["centered"])
		var tries: Array[Rect2] = []
		for a: Vector2 in (w["anchors"] as PackedVector2Array):
			var box: Rect2 = _plate_box(a, w["text"], w["size"], centered) if plated \
				else _label_box(a, w["text"], w["size"], centered)
			tries.append_array(_candidates(box, int(w["rank"])))
		var took: int = field.place(tries, String(w["text"]), int(w["rank"]),
			int(w["copies"]), String(w["key"]))
		if took < 0:
			continue
		if plated:
			_paint_plate(tries[took], String(w["text"]), float(w["size"]), w["color"])
		else:
			_paint_label(tries[took], String(w["text"]), float(w["size"]), w["color"])
	_words.clear()


## Where a word may go, best place first. Anything worth more than an ambient
## reading gets a short ladder of alternatives rather than being dropped: the
## anchor a lens computes is where the word WANTS to be, and it is usually
## exactly where the status layer has already put a badge for the same building.
## An ambient chip has no ladder — a temperature that had to be shoved three rows
## up the screen is no longer a temperature reading, it is a puzzle.
func _candidates(box: Rect2, rank: int) -> Array[Rect2]:
	var out: Array[Rect2] = [box]
	if rank <= LcnLabelField.Rank.AMBIENT:
		return out
	var h: float = box.size.y
	var w: float = box.size.x
	for d: Vector2 in [Vector2(0.0, -h * 1.5), Vector2(0.0, h * 1.6),
			Vector2(0.0, -h * 3.0), Vector2(-w * 0.55, -h * 1.5),
			Vector2(w * 0.55, -h * 1.5), Vector2(0.0, h * 3.2)]:
		out.append(Rect2(box.position + d, box.size))
	return out


static func _by_rank(a: Dictionary, b: Dictionary) -> bool:
	if int(a["rank"]) != int(b["rank"]):
		return int(a["rank"]) > int(b["rank"])
	return int(a["seq"]) < int(b["seq"])


## The world rectangle a plain word occupies. `at` is the BASELINE, so the box
## hangs above it.
func _label_box(at: Vector2, text: String, size_px: float, centered: bool) -> Rect2:
	var s: int = maxi(8, int(round(size_px)))
	var m: Vector2 = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, s)
	var pos: Vector2 = at - Vector2(m.x * 0.5 * wpp if centered else 0.0, m.y * 0.8 * wpp)
	return Rect2(pos, m * wpp)


func _plate_box(at: Vector2, text: String, size_px: float, centered: bool) -> Rect2:
	var s: int = maxi(8, int(round(size_px)))
	var m: Vector2 = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, s)
	var w: float = (m.x + 12.0) * wpp
	var h: float = (float(s) + 6.0) * wpp
	return Rect2(at - Vector2(w * 0.5 if centered else 0.0, 0.0), Vector2(w, h))


## A word that stays the same size on screen at every zoom, with a dark halo so
## it survives both the snow and the night.
func _paint_label(box: Rect2, text: String, size_px: float, c: Color) -> void:
	var s: int = maxi(8, int(round(size_px)))
	draw_set_transform(box.position + Vector2(0.0, box.size.y * 0.8), 0.0, Vector2(wpp, wpp))
	var outline: int = 6 if pal.high_contrast else 4
	font.draw_string_outline(get_canvas_item(), Vector2.ZERO, text,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, s, outline, Color(0.0, 0.0, 0.0, 0.9))
	font.draw_string(get_canvas_item(), Vector2.ZERO, text,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, s, c)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## A word with a solid plate behind it, for the few callouts that must be
## readable over any background — bottleneck verdicts, network badges.
func _paint_plate(box: Rect2, text: String, size_px: float, c: Color) -> void:
	var s: int = maxi(8, int(round(size_px)))
	draw_rect(box, Color(0.02, 0.035, 0.063, 0.88), true)
	draw_rect(box, LcnOverlayPalette.with_a(c, 0.9), false, stroke(1.5))
	draw_set_transform(box.position + Vector2(6.0, float(s) * 0.82 + 3.0) * wpp,
		0.0, Vector2(wpp, wpp))
	font.draw_string(get_canvas_item(), Vector2.ZERO, text,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, s, c)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## Width the plate above would occupy, in world px.
func plate_width(text: String, size_px: float) -> float:
	if font == null:
		return 0.0
	var s: int = maxi(8, int(round(size_px)))
	return (font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, s).x + 12.0) * wpp
