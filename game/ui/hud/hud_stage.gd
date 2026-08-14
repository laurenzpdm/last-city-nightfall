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
##      launch, over the assault at midnight, and through whatever [P18]'s
##      world-hover sheet was showing. It is now centred on the STAGE — the
##      rectangle `LcnHudLayout` leaves free between the rails — and clamped
##      above the bottom rail.
##
##   2. It DIMS THE WORLD behind the card. A 660 px panel floating on a lit city
##      reads as clutter; the same panel over a scrimmed city reads as a
##      question. The scrim is drawn on the HUD layer (65), which is under
##      [P22]'s card (78) and over the world, so it lands exactly between them
##      without either part needing to know about the other.
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

var _presenter: CanvasLayer = null
var _panel: Control = null
var _ticker: Control = null
var _warned: bool = false


func _init() -> void:
	name = "HudStage"
	process_priority = 100
	process_mode = Node.PROCESS_MODE_ALWAYS


## True while [P22] has a card on screen. Drives the HUD's scrim and the
## suppression of [P18]'s world-hover sheet.
func card_visible() -> bool:
	return _panel != null and _panel.visible and _panel.size.x > 1.0


func _process(_delta: float) -> void:
	_find()
	if _panel == null:
		card_size = Vector2.ZERO
		card_rect = Rect2()
		return
	if not _panel.visible:
		card_size = Vector2.ZERO
		card_rect = Rect2()
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
	if _ticker != null and ticker_slot.size.x > 1.0:
		# Zero reserved height means the card reached the stage floor and there is
		# nowhere for flavour to go. Hiding it is the honest outcome: the
		# alternative is prose printed over a question.
		_ticker.visible = ticker_slot.size.y > 1.0
		if _ticker.visible:
			_ticker.position = ticker_slot.position
			_ticker.size = ticker_slot.size


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
	_panel = _first_of_class(_presenter, "PanelContainer") as Control
	_ticker = _named_label(_presenter)
	if _panel == null and not _warned:
		_warned = true
		Log.info("hud", "the narrative presenter has no panel to place — "
			+ "[P22] draws its own card wherever it likes")


func _first_of_class(from: Node, cls: String) -> Node:
	for child: Node in from.get_children():
		if child.is_class(cls):
			return child
		var found: Node = _first_of_class(child, cls)
		if found != null:
			return found
	return null


## [P22] names its flavour feed "Ticker". A name is a weaker handle than a class,
## so this one is allowed to come back null and cost nothing.
func _named_label(from: Node) -> Control:
	for child: Node in from.get_children():
		if child is Label and String(child.name) == "Ticker":
			return child as Control
		var found: Control = _named_label(child)
		if found != null:
			return found
	return null
