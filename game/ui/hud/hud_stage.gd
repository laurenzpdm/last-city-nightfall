class_name LcnHudStage
extends Node
## THE STAGE DIRECTOR. Keeps the middle of the screen — where the city is — from
## being the least considered part of it. [D7 composition]
##
## Two jobs, both of them composition and neither of them content:
##
##   1. It PLACES [P22]'s dilemma card. The card is [P22]'s: its prose, its
##      options, its deadline and its buttons are none of this file's business.
##      Where it sits is, because where it sits is a relationship with seven
##      other panels and [P22] cannot see any of them. The card used to be
##      centred on the WINDOW at `0.22 * height`, which put it over the hearth at
##      launch and over the assault at midnight. It is now centred on the STAGE —
##      the rectangle `LcnHudLayout` leaves free between the rails — and clamped
##      above the bottom rail.
##
##   2. It DIMS THE WORLD behind the card. A 660 px panel floating on a lit city
##      reads as clutter; the same panel over a scrimmed city reads as a
##      question. The scrim is drawn on the HUD layer (`LcnLayers.HUD`), which is
##      under [P22]'s card (`LcnLayers.NARRATIVE`) and over the world, so it
##      lands exactly between them without either part needing to know about the
##      other. Both numbers are read off the table rather than written here: the
##      card moved from 78 to 66 in the wave that stopped it covering [P18]'s
##      browsers, and a header carrying its own copy of a layer number is how
##      that kind of move goes stale.
##
##   3. THE SHEET SUPPRESSION, AND THE MEMBER THAT ACTUALLY DRIVES IT.
##      This header used to say the card drove "the suppression of [P18]'s
##      world-hover sheet" and attribute it to `card_visible()`, which has
##      exactly one caller — the scrim. The claim was half wrong in the way that
##      is worse than being wrong: the BEHAVIOUR exists and is [P18]'s
##      `_place_tooltip()` standing its inspection sheet down while a decision is
##      on screen; what it reads is not `card_visible()` but `card_size` — this
##      file's measurement of the card, through [P17]'s solver, arriving as
##      `solved_rect(&"card")`. So the sentence is now written against the member
##      a reader can follow, because a true sentence pointing at the wrong
##      function sends the next person looking in the wrong file.
##
##      IT IS LOAD-BEARING IN BOTH DIRECTIONS AND THAT MATTERS NOW. When the
##      card stands down for a work surface (below), `card_size` goes to zero,
##      `solved_rect(&"card")` goes empty, and [P18]'s sheet comes back — which
##      is right, because with the card gone there is no decision for an
##      inspection to outrank. It also unmasked a defect in [P18]: the
##      world-hover sheet follows the mouse, and with an open palette under the
##      pointer it is drawn on top of the palette —
##      `tests/d7/run_layout_audit.tscn` now fails four cases on
##      `palette x sheet`. That pair could never have been measured before,
##      because in the one state the audit drives with the palette open there was
##      always a card up and the sheet was always hidden. See E3's report: the
##      fix belongs in `_place_tooltip()`, which already computes `left_block()`
##      for this exact purpose and never applies it to the mouse-follow branch.
##
## THE YIELDING THAT THIS WAVE ADDED runs the other way and is implemented, not
## described: [P22]'s card stands itself down while a work surface is open
## (`narrative_card.gd::_work_surface_open`), and this file republishes that as
## `card_deferred`.
##
## HOW IT REACHES THE CARD, AND WHY THAT IS NOT A FOLDER VIOLATION
##
## `LcnNarrativeCard` publishes itself in the group `lcn_narrative_presenter` and
## its own header names that group as the seam another part takes it over
## through. This file uses the seam in the gentler direction: it does not take
## the group (that would silence [P22] and make this part responsible for drawing
## dilemmas), it finds the node the group already holds and sets `position` on
## the one visible `PanelContainer` under it. No path, no private member, no file
## in `game/narrative/` touched.
##
## It runs at `process_priority = 100`, after [P22]'s own 5 Hz `_layout()`, so the
## last write in a frame is this one and there is no fight to see. If [P22] ever
## restructures and there is no PanelContainer to find, everything here becomes a
## no-op and the card goes back to sitting wherever [P22] puts it — the one thing
## it must never do is stop the card being drawn.

const PRESENTER_GROUP: StringName = &"lcn_narrative_presenter"

## Where the card should go this frame, in SCREEN pixels. Written by LcnHud from
## the solver; ZERO size means "no card is up".
var slot: Rect2 = Rect2()
## Where the ticker should go. Same contract.
var ticker_slot: Rect2 = Rect2()

## Measured screen size of the card that is actually up, or ZERO. LcnHud reads
## this to feed the solver, so the slot is computed against the real card rather
## than against a constant that would go stale the first time [P22] writes a
## longer dilemma.
var card_size: Vector2 = Vector2.ZERO
## Screen rect the card actually occupies after placement. The audit reads this.
var card_rect: Rect2 = Rect2()
## Screen rect [P22]'s flavour ticker actually occupies, or ZERO when it is not
## on screen. Published so the audit has a rectangle to fail on: until this
## existed the suite's allow-list named four pairs involving `ticker` and NOTHING
## IN THE BUILD EVER PUBLISHED ONE, so all four were exemptions from a check that
## could not run.
var ticker_rect: Rect2 = Rect2()
## True while [P22] has a card it is holding back because the player has a work
## surface open. Republished here so [P17] can put "a decision is waiting" in the
## attention stack if it ever wants to; nothing reads it yet, and this comment
## says so rather than claiming a consumer that does not exist.
var card_deferred: bool = false

var _presenter: CanvasLayer = null
var _panel: Control = null
var _ticker: Control = null
var _warned: bool = false


func _init() -> void:
	name = "HudStage"
	process_priority = 100
	process_mode = Node.PROCESS_MODE_ALWAYS


## True while [P22] has a card on screen. One caller, and this comment names it
## rather than implying a constituency: [P17]'s scrim. What [P18] reads to stand
## its hover sheet down is `card_size`, not this.
func card_visible() -> bool:
	return _panel != null and _panel.visible and _panel.size.x > 1.0


## Clear air between the bottom of a card and the top of the flavour feed.
const TICKER_CLEARANCE: float = 10.0


func _process(_delta: float) -> void:
	_find()
	card_deferred = _presenter != null and bool(_presenter.get(&"deferred"))
	if _panel == null or not _panel.visible:
		card_size = Vector2.ZERO
		card_rect = Rect2()
		_place_ticker(Rect2())
		return
	card_size = _panel.size
	if slot.size.x > 1.0:
		# `position` and not the layer's `offset`: the offset would drag the
		# ticker along with the card, and the ticker's problem is the opposite one
		# — it belongs low and left, not wherever the card happens to be.
		_panel.position = slot.position
		card_rect = Rect2(slot.position, _panel.size)
	else:
		card_rect = Rect2(_panel.global_position, _panel.size)
	_place_ticker(card_rect)


## THE FLAVOUR FEED YIELDS TO THE QUESTION, AND IT YIELDS AGAINST THE CARD THAT
## IS ACTUALLY ON SCREEN.
##
## The solver already gives the ticker zero height when the card it was solved
## against would reach the stage floor. That is the right rule and it was not
## enough, because the card's height is [P22]'s content and changes the instant a
## longer dilemma arrives — a poll before the solver hears about it. Measured at
## the dusk beat of `first_night` in `artifacts/d7/fixed_1920/shots/dusk.png`:
## the solve reserved the ticker against a 437 px card, "The Clerk Wants an
## Answer" came up 597 px tall, and four lines of "the care house has an empty
## bed in it" were printed straight across the two options the player was being
## asked to choose between.
##
## So the decision is made here, every frame, against the rectangle the card
## really occupies — this node is the only thing in the build that can see both.
## AND IT IS FITTED TO ITS OWN PROSE, NOT TO A CONSTANT.
##
## The slot the solver hands down is a fixed 96 px band. [P22]'s feed is four
## sentences of variable length that now WRAP inside a plate, so its real height
## is between one line and eight and is not knowable anywhere but here, after the
## Control has measured itself. Writing `size = want.size` on it produced the
## defect in `artifacts/CRIT/shots/dawn.png` from the other direction: prose
## hanging out of the bottom of a box that had been told how tall to be.
##
## So the plate keeps the slot's WIDTH and its FLOOR, and grows upward into the
## stage. Upward, because down is [P17]'s stores shelf and there is nothing to
## negotiate with there — and because a feed pinned to the stage floor stays put
## as lines arrive instead of jittering a line-height every few seconds.
func _place_ticker(card: Rect2) -> void:
	if _ticker == null:
		ticker_rect = Rect2()
		return
	var want: Rect2 = ticker_slot
	if want.size.x <= 1.0 or want.size.y <= 1.0:
		_ticker.visible = false
		ticker_rect = Rect2()
		return
	var grown: Rect2 = _grow_up(want)
	# Measured against the GROWN rectangle, so a feed that got taller yields to
	# the card instead of climbing into it. Flavour is the thing that gives way.
	var blocked: bool = card.size.x > 1.0 \
		and card.end.y + TICKER_CLEARANCE > grown.position.y \
		and card.end.x > grown.position.x and card.position.x < grown.end.x
	_ticker.visible = not blocked
	if not _ticker.visible:
		ticker_rect = Rect2()
		return
	_ticker.position = grown.position
	_ticker.size = grown.size
	ticker_rect = grown


## The slot's width and floor, the plate's own height. Never taller than the slot
## it was given plus the room the solver left above it — a feed is never allowed
## to become the tallest thing on the stage.
const TICKER_MAX_GROWTH: float = 2.0


func _grow_up(want: Rect2) -> Rect2:
	_ticker.custom_minimum_size = Vector2(want.size.x, 0.0)
	_ticker.size = Vector2(want.size.x, 0.0)
	var need: float = _ticker.get_combined_minimum_size().y
	var h: float = clampf(need, want.size.y, want.size.y * TICKER_MAX_GROWTH)
	return Rect2(Vector2(want.position.x, want.end.y - h), Vector2(want.size.x, h))


## Re-acquires the presenter whenever it is missing. Cheap: a group lookup and,
## only when the presenter changed, one walk of its children.
func _find() -> void:
	if is_instance_valid(_presenter) and _presenter.is_inside_tree() \
			and is_instance_valid(_panel):
		return
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	var node: Node = tree.get_first_node_in_group(PRESENTER_GROUP)
	_presenter = node as CanvasLayer
	_panel = null
	_ticker = null
	if _presenter == null:
		return
	_ticker = _named_control(_presenter)
	_panel = _first_of_class(_presenter, "PanelContainer", _ticker) as Control
	if _panel == null and not _warned:
		_warned = true
		Log.info("hud", "the narrative presenter has no panel to place — "
			+ "[P22] draws its own card wherever it likes")


## `skip` is the ticker, and it exists because [P22]'s flavour feed became a
## PanelContainer of its own when it got a plate. Tree order alone still gives
## the right answer — the card is added first — but "the right answer as long as
## nobody reorders two lines in another part's `_build()`" is the shape of a bug
## that only shows up in a screenshot, and this file has already shipped one.
func _first_of_class(from: Node, cls: String, skip: Node = null) -> Node:
	for child: Node in from.get_children():
		if child == skip:
			continue
		if child.is_class(cls):
			return child
		var found: Node = _first_of_class(child, cls, skip)
		if found != null:
			return found
	return null


## [P22] names its flavour feed "Ticker" — the PLATE carries the name, not the
## Label inside it, because the plate is the rectangle that has to be placed. A
## name is a weaker handle than a class, so this is allowed to come back null and
## cost nothing.
func _named_control(from: Node) -> Control:
	for child: Node in from.get_children():
		if child is Control and String(child.name) == "Ticker":
			return child as Control
		var found: Control = _named_control(child)
		if found != null:
			return found
	return null
