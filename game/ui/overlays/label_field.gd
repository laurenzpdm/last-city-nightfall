class_name LcnLabelField
extends RefCounted
## [P19] THE ONE GATE EVERY WORD DRAWN OVER THE WORLD HAS TO PASS.
##
## A critic counted ONE frame of `first_night` at zoom 0.70 and found 24
## temperature chips and 17 "no crew" chips printed through each other — "30°C"
## over "no crew", "27°C" over "building" — `SURVIVAL LINE -10°C` stamped three
## times onto one closed contour, and a vertical ladder of 22 identical
## "building" chips down the middle of the screen. Their words: *"it looks like
## a crash dump."* In `build.png` the world-space badge `= GRID 3 0/0 heat/s
## NO SOURCE` read straight through the clock panel and `| GRID 1 47/47 heat/s`
## landed on the "2:21" numeral — ARCHITECTURE.md §3 in one image: *a lens is
## paint on the ground, and the ground does not get to cover the clock.*
##
## Every one of those is the same defect. Each call site was individually
## reasonable — a temperature per building, a name per contour, a word per
## construction site — and each had its own private cap (`MAX_LABELS`,
## `LABELS_PER_LINE`, `shown < 14`), so no single number anywhere in this folder
## described what the player would actually be looking at. A per-call-site cap
## cannot see the frame. This can.
##
## So there is now exactly one arbiter. Nothing in `game/ui/overlays/` may put a
## word into world space except through `request()`, and `request()` answers with
## a reason when it says no. The reasons are counted, and the counts are asserted
## in `tests/overlays/run_lens_density.tscn` at zoom 0.50, 0.60 and 0.70 — the
## zooms the game is actually played at — because a chip count and an overlap
## count are the only things that settle an argument about clutter.
##
## FIVE RULES, IN ORDER. A word is drawn only if it survives all five.
##
##   1. ON SCREEN     a word off the edge is not a word.
##   2. NOT ON CHROME the HUD's rectangles arrive here in WORLD coordinates and
##                    are simply forbidden. Not "drawn under" — a translucent
##                    clock panel is a window, and the badge read through it.
##                    The pixels are spoken for.
##   3. NOT A REPEAT  a thing is named as many times as it is worth naming, and
##                    the caller declares that number. A closed contour is one
##                    thing; naming it three times is not three facts.
##   4. NOT ON A WORD nothing overlaps anything, including the glyphs and badges
##                    that reserved their pixels before the words were placed.
##   5. WITHIN BUDGET the frame has a word budget that falls with the zoom, and
##                    within it a RANK QUOTA, so an ambient chip can never crowd
##                    out a verdict no matter which lens asked first.
##
## Deterministic by construction: callers queue their words, the layer sorts them
## by rank and then by queue order, and this class walks that order. The same
## frame always keeps the same words — a lens that flickered its labels as the
## camera drifted would be worse than one that shows too many.

## What a word is FOR. The rank decides who gets crowded out first, and it is
## the only thing that does — a lens does not get priority for being a lens.
enum Rank {
	AMBIENT,    ## a reading that is nice to have: a temperature, a fuel %, an hp %
	FIGURE,     ## a number the player is comparing: crew 2/4, range, a cluster count
	IDENTITY,   ## the name of a thing: GRID 3, SURVIVAL LINE
	VERDICT,    ## what has gone wrong: FROZEN, OUT OF FUEL, AT CAPACITY
}

const RANK_COUNT: int = 4

## Share of the frame's word budget available to everything of THIS RANK OR
## LOWER. VERDICT is 1.0 by definition; the rest exist so that a screenful of
## thermometer readings can never be the reason a freeze warning has nowhere to
## go. This is the number that killed the ladder of 22 "building" chips: at zoom
## 0.70 the budget is 12 words, so AMBIENT gets 3 of them, ever.
const RANK_SHARE: Array[float] = [0.25, 0.5, 0.7, 1.0]

## Clear air demanded around every word, in SCREEN pixels. Two labels that merely
## touch are two labels a player has to untangle.
const GUTTER_PX: float = 3.0
## How far outside a HUD panel a word must stay, in SCREEN pixels.
const CHROME_MARGIN_PX: float = 6.0

## Why a word was refused. Counted per frame and reported by `stats()`.
enum Cull { OFFSCREEN, CHROME, REPEAT, OVERLAP, BUDGET }

const CULL_NAMES: Array[String] = ["offscreen", "chrome", "repeat", "overlap", "budget"]

## The visible world rectangle this frame.
var view: Rect2 = Rect2()
## World units per screen pixel.
var wpp: float = 1.0
## The most words that may be drawn this frame. See `budget_for`.
var budget: int = 12
## Rectangles, IN WORLD SPACE, that belong to the interface. Nothing is drawn
## into one. Filled by `LcnOverlayRoot` from [P17]'s `chrome_rects()`.
var chrome: Array[Rect2] = []

## Everything occupying pixels this frame: placed words AND reserved marks.
var boxes: Array[Rect2] = []
## The subset of `boxes` that are words, in the order they were placed.
var chips: Array[Rect2] = []
var chip_texts: PackedStringArray = PackedStringArray()
var chip_ranks: PackedInt32Array = PackedInt32Array()
## Where each chip sits in `boxes`, so the audit below can skip a rectangle
## intersecting itself without guessing from geometry.
var chip_slot: PackedInt32Array = PackedInt32Array()

## OFF turns rule 2 through 5 into a no-op while still recording every box, so a
## suite can measure what the frame WOULD have been. It is how
## `run_lens_density.tscn` proves its own assertions are load-bearing: with the
## arbiter bypassed the same frame reports 41 chips and 26 overlaps, and every
## assertion in that suite goes red. Never false in a running game.
var enforce: bool = true

var _rank_used: PackedInt32Array = PackedInt32Array()
var _key_used: Dictionary[String, int] = {}
var _culls: PackedInt32Array = PackedInt32Array()


func _init() -> void:
	_rank_used.resize(RANK_COUNT)
	_culls.resize(Cull.size())


## The word budget for a camera zoom. Falls with the zoom because the thing that
## changes when a player zooms out is not how much text fits — it is how much
## text is USEFUL. At 0.50 the player is reading the shape of a city and wants a
## handful of verdicts on it; at 1.60 they are reading one workshop.
##
## The numbers: 10 words at 0.50, 11 at 0.60, 12 at 0.70. The frame the critic
## counted had 41.
static func budget_for(zoom: float) -> int:
	return clampi(int(round(4.0 + 12.0 * maxf(zoom, 0.0))), 5, 20)


## How many words of `rank` or below may stand in a frame of `budget` words.
static func quota_for(budget_n: int, rank: int) -> int:
	var r: int = clampi(rank, 0, RANK_COUNT - 1)
	return maxi(1, int(ceil(float(budget_n) * RANK_SHARE[r])))


## Start a frame. Everything placed since the last call is forgotten.
func begin(visible_world: Rect2, world_per_px: float, budget_n: int,
		chrome_world: Array[Rect2]) -> void:
	view = visible_world
	wpp = maxf(0.0001, world_per_px)
	budget = maxi(1, budget_n)
	chrome = chrome_world
	boxes.clear()
	chips.clear()
	chip_texts.clear()
	chip_ranks.clear()
	chip_slot.clear()
	_key_used.clear()
	for i: int in RANK_COUNT:
		_rank_used[i] = 0
	for j: int in _culls.size():
		_culls[j] = 0


## Take these pixels without spending a word. Badges, glyph discs and gauges use
## it, so a lens verdict can never be printed across the icon it is explaining.
func reserve(box: Rect2) -> void:
	boxes.append(box.grow(GUTTER_PX * wpp * 0.5))


## Ask for a word at one place. Returns true when the caller may draw it there.
##
## `key`    what is being named, for rule 3. Two chips reading "no crew ×7" and
##          "no crew ×3" are the same key and a caller that wants both must say
##          so with `copies`. Defaults to the text itself.
## `copies` how many times this key is worth saying in one frame. One, for
##          anything that is one thing.
func request(box: Rect2, text: String, rank: int, copies: int = 1,
		key: String = "") -> bool:
	return place([box] as Array[Rect2], text, rank, copies, key) >= 0


## Ask for a word, offering several places to put it. The first candidate that
## survives all five rules wins; the index of it comes back, or -1.
##
## A WORD THAT MATTERS SHOULD MOVE, NOT VANISH. `= GRID 5 0/12 heat/s NO SOURCE`
## anchors above the northernmost tile of its grid, which is exactly where the
## status layer puts that tile's badge — so the badge claimed the pixels, the
## rule refused the word, and the heat network lens went silent about one of its
## two grids over a city where one of them had no source at all. The place is
## negotiable. The fact is not.
##
## Only the LAST failure is counted, so the cull tally reads as "why this word is
## not on screen" rather than "how hard we looked for a gap".
func place(candidates: Array[Rect2], text: String, rank: int, copies: int = 1,
		key: String = "") -> int:
	if text == "" or candidates.is_empty():
		return -1
	var r: int = clampi(rank, 0, RANK_COUNT - 1)
	var id: String = key if key != "" else text
	var last: int = Cull.OFFSCREEN
	for i: int in candidates.size():
		var box: Rect2 = candidates[i]
		var padded: Rect2 = box.grow(GUTTER_PX * wpp * 0.5)
		var why: int = _refuse(box, padded, id, r, copies)
		if why < 0:
			chip_slot.append(boxes.size())
			boxes.append(padded)
			chips.append(box)
			chip_texts.append(text)
			chip_ranks.append(r)
			_rank_used[r] += 1
			_key_used[id] = _key_used.get(id, 0) + 1
			return i
		last = why
	_culls[last] += 1
	return -1


## The first rule this box breaks, or -1 when it breaks none. The order is the
## order in the header, and it is also the order of usefulness to a reader: a
## word off the edge is a different bug from a word that ran out of budget.
func _refuse(box: Rect2, padded: Rect2, id: String, rank: int, copies: int) -> int:
	if not view.intersects(box):
		return Cull.OFFSCREEN
	if not enforce:
		return -1
	var margin: float = CHROME_MARGIN_PX * wpp
	for panel: Rect2 in chrome:
		if panel.grow(margin).intersects(box):
			return Cull.CHROME
	if _key_used.get(id, 0) >= maxi(1, copies):
		return Cull.REPEAT
	for taken: Rect2 in boxes:
		if taken.intersects(padded):
			return Cull.OVERLAP
	if chips.size() >= budget or _used_at_or_below(rank) >= quota_for(budget, rank):
		return Cull.BUDGET
	return -1


func _used_at_or_below(rank: int) -> int:
	var n: int = 0
	for i: int in range(0, rank + 1):
		n += _rank_used[i]
	return n


# =========================================================================
# what a critic (or a test) reads instead of a claim
# =========================================================================

## Pairs of occupied rectangles that intersect WHERE AT LEAST ONE IS A WORD. The
## whole point of this class is that this is ZERO, on every frame, at every zoom.
## Computed by brute force over what was actually placed rather than trusted from
## the placement path — a rule that checks itself with the code that enforced it
## has proved nothing.
##
## Two MARKS are allowed to touch. Two badges 20 px apart are two icons a player
## reads as a pair, and the merge pass in `LcnStatusIcons` is what decides when
## they should stop being two. A word crossing anything is the defect: "30°C"
## over "no crew" is not a pair, it is a smear.
func overlap_count() -> int:
	var n: int = 0
	for i: int in chips.size():
		var mine: int = chip_slot[i]
		var padded: Rect2 = boxes[mine]
		for j: int in boxes.size():
			# A rectangle always intersects itself; counting that would report
			# every frame as broken.
			if j == mine:
				continue
			if boxes[j].intersects(padded):
				n += 1
	return n


## Placed words standing on a piece of the interface. Also always zero, and also
## measured after the fact rather than asserted from the rule.
func chrome_hits() -> int:
	var n: int = 0
	for c: Rect2 in chips:
		for panel: Rect2 in chrome:
			if panel.intersects(c):
				n += 1
				break
	return n


## The most times any one string appears in this frame.
func worst_repeat() -> int:
	var counts: Dictionary[String, int] = {}
	var worst: int = 0
	for t: String in chip_texts:
		var n: int = counts.get(t, 0) + 1
		counts[t] = n
		worst = maxi(worst, n)
	return worst


## How many times `text` was drawn this frame.
func count_of(text: String) -> int:
	var n: int = 0
	for t: String in chip_texts:
		if t == text:
			n += 1
	return n


func stats() -> Dictionary:
	var out: Dictionary = {
		"chips": chips.size(),
		"budget": budget,
		"marks": boxes.size() - chips.size(),
		"overlaps": overlap_count(),
		"chrome_hits": chrome_hits(),
		"worst_repeat": worst_repeat(),
	}
	for i: int in _culls.size():
		out["culled_" + CULL_NAMES[i]] = _culls[i]
	return out


## One line for the log, so a run says what the frame held without a screenshot.
func summary() -> String:
	return "%d/%d chips · %d marks · %d overlaps · %d on chrome · worst repeat %d · culled %d off %d chrome %d repeat %d overlap %d budget" % [
		chips.size(), budget, boxes.size() - chips.size(), overlap_count(),
		chrome_hits(), worst_repeat(),
		_culls[Cull.OFFSCREEN], _culls[Cull.CHROME], _culls[Cull.REPEAT],
		_culls[Cull.OVERLAP], _culls[Cull.BUDGET]]
