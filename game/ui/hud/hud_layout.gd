class_name LcnHudLayout
extends RefCounted
## WHERE EVERY PIECE OF CHROME GOES. One solver, three folders, no constants
## tuned against one screenshot at one resolution. [D7 composition]
##
## THE PROBLEM THIS EXISTS TO KILL
##
## Five panels used to pick their own corner and every neighbour was a constant
## somebody measured off a 1920x1080 frame once. `LcnOverlayLegend` carried
## `BOTTOM_CLEARANCE = 108` with a comment saying it had been measured against
## the real stores shelf; [P18]'s hotkey rail sat at `BOTTOM_LEFT + (18, -26)`
## and drew straight through that same shelf; the stores shelf itself grew a chip
## at a time until at 1280 wide it ran off the screen. Three parts, three private
## opinions about the same forty pixels, and nothing that could be checked.
##
## So this is a PURE FUNCTION. Give it the viewport, the ui scale, what state the
## game is in and how big each panel measured itself, and it hands back a screen
## rectangle for every piece of chrome in the build. Nothing here reads a node,
## a signal, a setting or a clock, which is why `tests/d7/run_layout_audit.tscn`
## can solve every resolution in a millisecond and assert that no two rectangles
## overlap — and why a regression shows up as a failing number rather than as a
## screenshot somebody has to notice.
##
## THE FRAME IS A PROSCENIUM. Chrome lives in a border, the centre is the stage,
## and the city is on the stage. Reading order, deliberately, is three columns:
##
##   left rail    POWER and PROBLEMS   heat grid, then attention
##   top centre   TIME                 the clock, the only thing above the stage
##   right rail   PEOPLE and THREAT    the people, the wave, then what you clicked
##   bottom rail  STOCK                legend, hotkeys, stores
##
## The selection panel used to sit alone in the bottom-right corner. It now joins
## the end of the right rail, because "who is this, and is it going to survive
## the night" is the same question as the two panels above it — and because a
## corner given back to the world is worth more than a corner filled.
##
## THREE STATES, THREE COMPOSITIONS. A HUD identical during a quiet afternoon and
## during an assault is not helping:
##
##   LULL   the clock leads. Everything else recedes; the eye is meant to end up
##          on the city, having learned how long it has.
##   BUILD  stores lead — build mode is spending. The left rail SLIDES RIGHT out
##          from under [P18]'s palette instead of being covered by it.
##   NIGHT  heat and attention lead, the wave panel lights up, and the stores
##          shelf recedes and sheds chips: you cannot build your way out of
##          tonight, so the shelf stops competing for the eye.
##
## Every consumer works in SCREEN pixels. [P17]'s HUD is authored in design
## pixels on a CanvasLayer scaled by `ui_scale`, so it divides what it gets back
## by `ui_scale`; [P18] and [P19] draw unscaled and use the rects as they come.

## What the composition is answering to. Derived by `state_for`, never guessed.
enum State { LULL, BUILD, NIGHT }

const STATE_NAMES: Array[String] = ["lull", "build", "night"]

## Design-space margins. Multiplied by ui_scale on the way out.
const MARGIN: float = 16.0
const GAP: float = 10.0
## Clear air between the bottom rail's three stacked strips.
const STRIP_GAP: float = 8.0
## The stage never gets narrower than this fraction of the viewport, whatever the
## rails would like. Below it the rails give ground instead — a HUD that eats the
## game at 1280x720 is a HUD nobody plays at 1280x720.
const MIN_STAGE_FRACTION: float = 0.34
## The share of the SCREEN AREA the world keeps at ui_scale 1.0. It is a
## DESIGNER's promise, not a player's: `tests/d7/run_layout_audit.tscn` asserts
## it at the default scale, and deliberately does not at scales the player chose
## for themselves. See the note in `LcnHud._relayout` about why capping an
## accessibility setting to protect a layout target is the wrong way round.
const MIN_STAGE_AREA: float = 0.30


## The state the composition should be in. `build_mode` is the play shell holding
## a ghost or a build panel being open; `night` is [P09]'s night or a wave that
## has already started. Night wins: an assault during a build is an assault.
static func state_for(night: bool, under_attack: bool, build_mode: bool) -> int:
	if night or under_attack:
		return State.NIGHT
	if build_mode:
		return State.BUILD
	return State.LULL


## How loud each panel is in each state, 0..1. Read by `LcnHudWidget.emphasis`,
## which turns it into plate light and panel alpha. The numbers are a priority
## order made explicit rather than a taste: in every column, exactly one thing is
## at 1.0 and the eye is supposed to land on it first.
const EMPHASIS: Dictionary = {
	"lull": {
		"clock": 1.0, "heat": 0.55, "alerts": 0.85, "vitals": 0.5,
		"wave": 0.4, "stores": 0.75, "selection": 0.85,
	},
	"build": {
		"clock": 0.65, "heat": 0.7, "alerts": 0.85, "vitals": 0.4,
		"wave": 0.4, "stores": 1.0, "selection": 0.85,
	},
	"night": {
		"clock": 0.8, "heat": 1.0, "alerts": 1.0, "vitals": 0.6,
		"wave": 1.0, "stores": 0.45, "selection": 0.8,
	},
}


## Emphasis for one panel in one state. Unknown names read 0.7 rather than 0 —
## a panel this table has never heard of must still be visible.
static func emphasis_of(state: int, panel: String) -> float:
	var row: Dictionary = EMPHASIS.get(STATE_NAMES[clampi(state, 0, 2)], {}) as Dictionary
	return float(row.get(panel, 0.7))


## How many stock chips the shelf may show. The shelf recedes at night, and at
## every resolution it is also capped by the width it actually has: nine chips at
## 126 design px is 1160 px of shelf, which does not fit on a 1280 screen and
## never did.
static func chip_budget(state: int, view_width: float, ui: float, chip_w: float,
		pad: float) -> int:
	var hard_cap: int = 5 if state == State.NIGHT else 9
	var usable: float = view_width - 2.0 * MARGIN * ui - pad * 2.0 * ui
	var fits: int = int(floorf(usable / maxf(1.0, chip_w * ui)))
	return clampi(mini(hard_cap, fits), 1, 9)


## THE SOLVER.
##
## `view`   viewport size in screen pixels
## `ui`     Settings graphics/ui_scale
## `state`  one of State
## `sizes`  measured LOGICAL sizes of [P17]'s panels, keyed by name. A panel that
##          is not in the dictionary is not on screen and gets no rectangle.
## `extra`  {"card": Vector2 logical card size or ZERO,
##           "legend": Vector2 screen legend size or ZERO,
##           "rail": Vector2 screen lens-rail size or ZERO,
##           "hint": Vector2 screen hotkey-rail size or ZERO,
##           "left_block": float, screen px of left edge an open build panel owns}
##
## Returns every rectangle in SCREEN pixels, plus `stage` — the rectangle the
## world is allowed to have to itself.
static func solve(view: Vector2, ui: float, state: int, sizes: Dictionary,
		extra: Dictionary = {}) -> Dictionary:
	var s: float = maxf(0.25, ui)
	var m: float = roundf(MARGIN * s)
	var g: float = roundf(GAP * s)
	var out: Dictionary = {}

	var legend_size: Vector2 = extra.get("legend", Vector2.ZERO)
	var hint_size: Vector2 = extra.get("hint", Vector2.ZERO)
	var rail_size: Vector2 = extra.get("rail", Vector2.ZERO)
	var card_size: Vector2 = extra.get("card", Vector2.ZERO)
	var left_block: float = float(extra.get("left_block", 0.0))

	# ---------------------------------------------------------- bottom rail --
	# Solved first and upward, because everything in it is anchored to the bottom
	# edge and everything above it needs to know where its ceiling is.
	var bottom: float = view.y - m
	if sizes.has("stores"):
		var sw: float = minf((sizes["stores"] as Vector2).x * s, view.x - 2.0 * m)
		var sh: float = (sizes["stores"] as Vector2).y * s
		out["stores"] = Rect2(m, bottom - sh, sw, sh)
		bottom -= sh + STRIP_GAP
	if hint_size != Vector2.ZERO:
		out["hint"] = Rect2(m, bottom - hint_size.y, hint_size.x, hint_size.y)
		# The overlay's one-line "F1-6 overlays / ALT details" reminder shares the
		# hotkey rail's baseline on the opposite side. Same strip, same eye level,
		# and neither of them is ever again on top of the shelf.
		out["lens_hint"] = Rect2(view.x - m - hint_size.x, bottom - hint_size.y,
			hint_size.x, hint_size.y)
		bottom -= hint_size.y + STRIP_GAP
	elif legend_size != Vector2.ZERO:
		out["lens_hint"] = Rect2(view.x - m - 200.0, bottom - 18.0, 200.0, 18.0)
	if legend_size != Vector2.ZERO:
		var lw: float = minf(legend_size.x, view.x - 2.0 * m)
		# Height clamped to the room the bottom rail actually has left, for the
		# same reason the right column's panels are: a reservation larger than
		# the screen is not a reservation, and [P19] reads this rectangle as its
		# authority for how many rows it may print.
		var lh: float = minf(legend_size.y, maxf(0.0, bottom - m))
		out["legend"] = Rect2(m, bottom - lh, lw, lh)
		bottom -= lh + STRIP_GAP
	# Toasts and the play shell's ghost line live centred just above whatever the
	# bottom rail ended up being.
	out["footer_ceiling"] = Rect2(m, bottom - 1.0, view.x - 2.0 * m, 1.0)

	# ------------------------------------------------------------ left rail --
	# In BUILD, [P18]'s palette owns the left flank — it is 982 px wide at
	# 1920x1080, half the screen. The first version of this solver slid [P17]'s
	# left rail out from under it, which put the heat panel at x = 1016 and left
	# a stage of 23%: the chrome had eaten the game. So the rule is a decision,
	# not a nudge. If the rail can still slide and leave a stage, it slides; if it
	# cannot, it MIGRATES to the right column and the composition becomes
	#
	#   left = what you are placing · right = the state of the city · bottom = the cost
	#
	# which is the reading order a player in build mode actually wants.
	var left_stack: Array[String] = ["heat", "alerts"]
	var right_stack: Array[String] = ["vitals", "wave"]
	var left_x: float = m
	if state == State.BUILD and left_block > 0.0:
		var rail_w: float = 0.0
		for k0: String in left_stack:
			if sizes.has(k0):
				rail_w = maxf(rail_w, (sizes[k0] as Vector2).x * s)
		var right_reserve: float = 0.0
		for k0b: String in right_stack:
			if sizes.has(k0b):
				right_reserve = maxf(right_reserve, (sizes[k0b] as Vector2).x * s)
		if left_block + g + rail_w + g + right_reserve \
				> view.x * (1.0 - MIN_STAGE_FRACTION):
			left_stack = []
			right_stack = ["vitals", "wave", "heat", "alerts"]
		else:
			left_x = maxf(m, left_block + g)
	var left_y: float = m
	for k: String in left_stack:
		if not sizes.has(k):
			continue
		var ls: Vector2 = (sizes[k] as Vector2) * s
		var room: float = maxf(0.0, bottom - left_y - g)
		out[k] = Rect2(left_x, left_y, ls.x, minf(ls.y, room))
		if k == "alerts":
			out["alerts_max_h"] = Rect2(0.0, 0.0, 0.0, room / s)
		left_y += minf(ls.y, room) + g
	# TWO left edges, and the difference between them is a design decision.
	#
	#   hud_left   where [P17]'s own panels end. Nothing this solver PLACES may
	#              cross it, because everything it places is status.
	#   stage_edge where the WORLD's clear space begins, which also respects
	#              [P18]'s palette.
	#
	# The clock and [P22]'s card centre on `hud_left`, so a nine-hundred-pixel
	# build browser cannot squeeze them into a 365 px gap and out the other side
	# into the people panel. A browser is a list the player opened and can close;
	# a decision with a deadline on it and the clock that says how long the city
	# has are not negotiable with it.
	var hud_left: float = m
	for k1: String in left_stack:
		if out.has(k1):
			hud_left = maxf(hud_left, (out[k1] as Rect2).end.x)
	var left_edge: float = hud_left
	if state == State.BUILD and left_block > 0.0:
		left_edge = maxf(left_edge, left_block)

	# ----------------------------------------------------------- right rail --
	# One reading column: the people, the wave, then what you clicked. The
	# selection panel used to sit alone in the bottom-right corner, where it and
	# the stores shelf fought over the same pixels below 1600 wide and where it
	# covered the city's south-east quarter for no reason at all.
	var right_w: float = 0.0
	for k2: String in right_stack + ["selection"]:
		if sizes.has(k2):
			right_w = maxf(right_w, (sizes[k2] as Vector2).x * s)
	right_w = maxf(right_w, rail_size.x)
	var right_x: float = view.x - m - right_w
	var right_y: float = m
	# The lens rail's height is reserved BEFORE the panels that would otherwise
	# grow into it. Reserving it afterwards is how a tall selection panel and a
	# six-row lens rail ended up on the same 160 px.
	var rail_reserve: float = (rail_size.y + g) if rail_size != Vector2.ZERO else 0.0
	var right_floor: float = bottom - rail_reserve
	for k3: String in right_stack:
		if not sizes.has(k3):
			continue
		var sz: Vector2 = (sizes[k3] as Vector2) * s
		# No `maxf(60 * s, …)` floor here, for the third and last time in this
		# file: a widget-side or solver-side minimum that outranks the room the
		# column actually has does not protect the panel, it just moves the
		# overlap somewhere the solver cannot see. Measured at ui 1.6 with the
		# left rail migrated, the 96 px floor put the attention stack 96 px past
		# the bottom rail and straight through [P19]'s overlay reminder.
		var room3: float = maxf(0.0, right_floor - right_y - g)
		var h3: float = minf(sz.y, room3)
		out[k3] = Rect2(view.x - m - sz.x, right_y, sz.x, h3)
		if k3 == "alerts":
			out["alerts_max_h"] = Rect2(0.0, 0.0, 0.0, room3 / s)
		right_y += h3 + g
	if sizes.has("selection"):
		var ss: Vector2 = (sizes["selection"] as Vector2) * s
		# NO minimum height here. An earlier version floored this at `90 * ui`,
		# which at ui 1.6 is 144 px — larger than the room the lens rail's
		# reservation had left, so the floor quietly cancelled the reservation and
		# the rail was drawn back through the panel. A guaranteed minimum that
		# overrides a guaranteed reservation is not a guarantee; it is two.
		var room2: float = maxf(0.0, right_floor - right_y - g)
		var sel_h: float = minf(ss.y, room2)
		out["selection"] = Rect2(view.x - m - ss.x, right_y, ss.x, sel_h)
		out["selection_max_h"] = Rect2(0.0, 0.0, 0.0, room2 / s)
		right_y += sel_h + g
	if rail_size != Vector2.ZERO:
		var rail_top: float = clampf(right_y, m, maxf(m, bottom - rail_size.y))
		out["rail"] = Rect2(view.x - m - rail_size.x, rail_top, rail_size.x, rail_size.y)
		# The rail is a hotkey reminder and the selection panel is an answer, so
		# when the column genuinely cannot hold both the rail keeps its place at
		# the foot of the column and the panel above it gives up the pixels. The
		# panel clips honestly; the two never share one.
		if out.has("selection"):
			var sel: Rect2 = out["selection"]
			if sel.end.y > rail_top - g:
				var trimmed: float = maxf(0.0, rail_top - g - sel.position.y)
				out["selection"] = Rect2(sel.position, Vector2(sel.size.x, trimmed))
				out["selection_max_h"] = Rect2(0.0, 0.0, 0.0, trimmed / s)

	# ------------------------------------------------------------ top centre --
	# The clock is centred on the STAGE, not on the window. On an ultrawide the
	# window centre and the stage centre are the same place; at 1280 with both
	# rails out they are not, and centring on the window is what walks a 500 px
	# clock into a 372 px heat panel.
	# The rails are HARD edges for anything the solver PLACES. The stage may be
	# widened past them so the world has somewhere to breathe — the world is drawn
	# underneath the chrome and does not mind — but a panel centred on a widened
	# stage walks straight into the rail it was widened past, which is how a
	# 500 px clock ended up 28,000 px² inside the people panel in build mode.
	var wall_left: float = hud_left + g
	var wall_right: float = minf(right_x, view.x - m) - g
	var stage_left: float = left_edge + g
	var stage_right: float = wall_right
	var min_stage: float = view.x * MIN_STAGE_FRACTION
	if stage_right - stage_left < min_stage:
		var slack: float = (min_stage - (stage_right - stage_left)) * 0.5
		stage_left = maxf(m, stage_left - slack)
		stage_right = minf(view.x - m, stage_right + slack)
	var stage_cx: float = (stage_left + stage_right) * 0.5
	var panel_cx: float = (wall_left + wall_right) * 0.5
	var top: float = m
	if sizes.has("clock"):
		var cs: Vector2 = (sizes["clock"] as Vector2) * s
		var cx: float = clampf(panel_cx - cs.x * 0.5, wall_left,
			maxf(wall_left, wall_right - cs.x))
		out["clock"] = Rect2(roundf(cx), roundf(m * 0.6), cs.x, cs.y)
		top = (out["clock"] as Rect2).end.y + g

	out["stage"] = Rect2(stage_left, top, maxf(0.0, stage_right - stage_left),
		maxf(0.0, bottom - top))

	# ------------------------------------------------------------- the card --
	# [P22]'s dilemma card. It is the one thing allowed on the stage, because it
	# is the one thing that is asking the player a question — and it is centred on
	# the stage rather than on the window, which is what stops it landing on the
	# selection panel and on the clock at the same time.
	if card_size != Vector2.ZERO:
		var cw: float = card_size.x
		var ch: float = card_size.y
		var stage: Rect2 = out["stage"]
		# The ticker gets the stage floor, so the card is placed against a stage
		# that is already that much shorter. Biased up rather than centred: a card
		# hanging from the clock reads as an answer to it.
		var ticker_h: float = 96.0 * s
		var card_room: float = maxf(120.0, stage.size.y - ticker_h - g)
		var cy: float = stage.position.y + maxf(0.0, (card_room - ch) * 0.30)
		if ch >= card_room:
			cy = stage.position.y
		# Centred between the RAILS, then pushed inside them if it is wider than
		# the gap. A card is a question and it may cover the city; it may not
		# cover the panels that say whether the city is still alive.
		var card_x: float = clampf(panel_cx - cw * 0.5, wall_left,
			maxf(wall_left, wall_right - cw))
		out["card"] = Rect2(roundf(card_x), roundf(cy), cw, ch)
		# The ticker is [P22]'s flavour feed: prose on the world with a shadow and
		# no plate, and it draws ABOVE the card in [P22]'s own tree order. Left
		# where it was it ran straight across the middle of a dilemma and out the
		# other side — four lines of "the care house has an empty bed in it" laid
		# over the question the player was being asked to answer.
		#
		# So it gets the floor of the stage, always, and the card above is placed
		# against a stage already shortened by exactly this much. When the card is
		# tall enough to reach the floor anyway the ticker is given ZERO height,
		# which `LcnHudStage` reads as "do not draw" — flavour is the thing that
		# yields, every time.
		var t_top: float = stage.end.y - ticker_h
		out["ticker"] = Rect2(stage_left, t_top,
			maxf(200.0, (stage_right - stage_left) * 0.62),
			ticker_h if cy + ch <= t_top - g else 0.0)
	return out


## Every pair of rectangles in `rects` that overlaps by more than `slack` pixels.
## Keys listed in `ignore` are skipped, and so is anything whose name ends in
## `_max_h` or is a band rather than a panel. Rows: {a, b, area, rect}.
##
## This is the whole point of the module: overlap stops being something a human
## has to notice in a screenshot and becomes a number a suite can fail on.
static func overlaps(rects: Dictionary, ignore: PackedStringArray = PackedStringArray(),
		slack: float = 1.0) -> Array[Dictionary]:
	var names: Array = []
	for k: Variant in rects.keys():
		var n: String = String(k)
		if n.ends_with("_max_h") or n == "stage" or n == "footer_ceiling":
			continue
		if ignore.has(n):
			continue
		names.append(n)
	names.sort()
	var bad: Array[Dictionary] = []
	for i: int in names.size():
		for j: int in range(i + 1, names.size()):
			var a: Rect2 = rects[names[i]]
			var b: Rect2 = rects[names[j]]
			var hit: Rect2 = a.intersection(b)
			if hit.size.x > slack and hit.size.y > slack:
				bad.append({"a": String(names[i]), "b": String(names[j]),
					"area": hit.size.x * hit.size.y, "rect": hit})
	bad.sort_custom(func(p: Dictionary, q: Dictionary) -> bool:
		return float(p["area"]) > float(q["area"]))
	return bad


## Rectangles that stick out of the viewport. Same contract as `overlaps`.
static func out_of_bounds(rects: Dictionary, view: Vector2,
		slack: float = 1.0) -> Array[Dictionary]:
	var bad: Array[Dictionary] = []
	var names: Array = []
	for k: Variant in rects.keys():
		var n: String = String(k)
		if n.ends_with("_max_h") or n == "stage" or n == "footer_ceiling":
			continue
		names.append(n)
	names.sort()
	for n2: String in names:
		var r: Rect2 = rects[n2]
		var over: float = maxf(maxf(-r.position.x, -r.position.y),
			maxf(r.end.x - view.x, r.end.y - view.y))
		if over > slack:
			bad.append({"name": n2, "by": over, "rect": r})
	return bad
