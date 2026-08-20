class_name LcnHudStage
extends Node
## THE STAGE DIRECTOR. Keeps the middle of the screen — where the city is — from
## being the least considered part of it. [D7 composition]
##
## Three jobs, all of them composition and none of them content. The third one
## is new and it is the only one that is a RULE rather than a placement — see
## THE GOVERNOR at the bottom of this file: a card that stops the world may not
## be on screen while the world needs watching. Three rounds running, a story
## card covered the thing the player needed to look at, and three times it was
## moved instead of being governed. Moving a rectangle answers "where"; it has
## never once answered "whether".
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
## THE YIELDING runs the other way and is implemented, not described: [P22]'s
## card stands itself down while a work surface is open
## (`narrative_card.gd::_work_surface_open`), and this file republishes that as
## `card_deferred`. It stands itself down for the night too
## (`LcnWorldWatch`), and THAT one this file does not merely republish — it
## enforces it, on whatever node holds the presenter group, because the group is
## a seam and a rule that lives only inside the part it governs leaves when that
## part is replaced.
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
## THE RULE THIS FILE NOW ENFORCES, not merely reports. `LcnWorldWatch.Watch`,
## and anything but `NONE` means no presenter gets the stage this frame.
var withheld_watch: int = LcnWorldWatch.Watch.NONE
## True on any frame this file took the stage away from a presenter that wanted
## it. Distinct from `card_deferred`, which is [P22] standing down of its own
## accord: this one is the governor firing, and a test that cannot tell those two
## apart cannot tell a rule from a coincidence.
var card_withheld: bool = false

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
	_withhold()
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
		# A ZERO-HEIGHT SLOT IS AN INSTRUCTION, NOT AN ABSENCE, and the two used
		# to arrive here as the same empty rectangle.
		#
		# `LcnHudLayout.solve()` emits `ticker` ONLY inside `if card_size !=
		# ZERO`, and when the card is tall enough to reach the stage floor it
		# emits it with height 0 — the solver's own way of saying "flavour
		# yields this frame". `_fallback_ticker_slot()` was added later for the
		# opposite case, a run with no card at all, and it cannot see which of
		# the two it is being asked about. So in exactly the frames the solver
		# said YIELD, the feed was handed a fresh slot on the stage floor and
		# drawn straight across the bottom of the card:
		# `artifacts/play1/shots/third_day_city.png` — four lines about the
		# sledway and the gate bar over the last paragraph, the BECAUSE block
		# and the Read button of [P22]'s ENDING card.
		#
		# A card on screen answers the question the fallback exists to ask.
		if card.size.x > 1.0:
			_ticker.visible = false
			ticker_rect = Rect2()
			return
		want = _fallback_ticker_slot()
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
	# A FEED WITH NOTHING IN IT IS NOT A FEED. This function owns `visible` on
	# the plate, so [P22] hiding an empty one lasted exactly until the next
	# frame — the plate came back as a rimmed 730 x 105 rectangle with no text
	# in it, over the middle of the city. [P22] publishes whether it has a line;
	# placing something empty is the one case where the answer is "nowhere".
	if _presenter != null and not bool(_presenter.get(&"ticker_has_lines")):
		blocked = true
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


# ==========================================================================
#  THE GOVERNOR
# ==========================================================================

## A CARD THAT STOPS THE WORLD MAY NOT BE ON SCREEN WHILE THE WORLD NEEDS
## WATCHING — enforced here, on whatever node holds `lcn_narrative_presenter`,
## every frame, at priority 100.
##
## WHY IT IS HERE AS WELL AS IN [P22]. `narrative_card.gd` already stands itself
## down for the same rule and that is the right place for the behaviour: it owns
## the prose, it owns the feed the waiting line goes into, and it can be polite
## about it. But the presenter group is a SEAM — its own header invites [P17] or
## [P18] to take it over — and a rule that lives only inside the thing it governs
## leaves with that thing. This file is the stage director; "what may stand on
## the stage, and when" is the one question it exists to answer. So the rule is
## asserted here against the rectangle, not against a part.
##
## It hides, it never draws and it never answers. `dismiss_current()` would take
## the first option of a dilemma the player never read, and `queue_free()` would
## destroy a decision with a deadline on it; `visible = false` costs the card
## nothing and gives the stage back. The presenter's own 5 Hz `_refresh()` sets
## `visible = true` again whenever it disagrees, and this runs after it every
## frame, so the last write in the frame is this one — which is the same
## priority-100 argument the placement above already rests on.
##
## THE CONSEQUENCE THAT MAKES IT VISIBLE IN THE SHIPPED FRAME, and it is worth
## naming because it is what a critic actually sees: `card_size` goes to zero,
## so [P17]'s solver stops reserving the stage centre, and `card_visible()` goes
## false, so [P17]'s SCRIM — a 52% deep-blue wash over the whole city, drawn on
## the HUD layer and therefore present in `*.world.png` as well as in the shipped
## shot — comes off the city at the same instant. The card is stripped from the
## world capture by the shutter; the scrim never was. Half of what was wrong with
## `artifacts/CRIT/shots/assault.world.png` was the scrim, and nothing about
## moving a rectangle would ever have touched it.
##
## `tests/d7/run_fight_frames.gd` is the gate, and it reads the PNGs an ordinary
## `tools/run_visual.sh --scenario=first_night` writes. Not this member, not a
## private scene, not a rig this file could flatter.
func _withhold() -> void:
	withheld_watch = LcnWorldWatch.watch()
	card_withheld = false
	var why: String = LcnWorldWatch.because(withheld_watch)
	if why == "" and _grading():
		why = "the night is being graded"
	if why == "":
		return
	if _panel != null and _panel.visible:
		_panel.visible = false
		card_withheld = true
		if not _said:
			_said = true
			Log.info("hud", ("the stage is the player's while %s — %s stands down "
				+ "and comes back when the night is over")
				% [why, _presenter.name if _presenter != null else "the story card"])
	# The ticker is not a modal: it is one plate, low and left, off the stage,
	# and it is where the waiting line lives. It keeps its slot.


## Said once per session, not once per frame. A rule that fires forty times a
## second is a rule nobody reads in a log.
var _said: bool = false


## WHERE THE FEED GOES WHEN THERE IS NO CARD TO PUT IT UNDER.
##
## [P17]'s solver emits a `ticker` rectangle only inside `if card_size != ZERO` —
## the feed was written as the thing that lives UNDER a dilemma and yields to it,
## so with no dilemma there was nothing to place it against and it was simply not
## placed. That was harmless for as long as a card was up in every frame this
## build ever produced, and it stopped being harmless the moment the rule above
## started taking the card off the stage for whole nights: the waiting line that
## explains where the decision went had nowhere to be drawn, so in
## `artifacts/H3_fix/shots/dusk.png` the card was correctly gone and the player
## was told nothing at all.
##
## So this file — which is the one that knows the card is not there — asks [P17]
## for the STAGE and puts the feed on its floor, which is exactly where the
## solver would have put it. Asked through the `lcn_hud_chrome` group and the
## public `solved_rect`, the same seam [P18] uses, so it holds for any [P17].
##
## THE HEIGHT IS A FLOOR, NOT A MEASUREMENT, and that is why it is allowed to be
## a fraction rather than the solver's `96 * ui_scale`: `_grow_up` immediately
## refits the plate to its own prose between this and twice this. Getting it
## wrong costs a few pixels of empty plate, never a line of text outside its box.
func _fallback_ticker_slot() -> Rect2:
	var tree: SceneTree = get_tree()
	if tree == null:
		return Rect2()
	var stage: Rect2 = Rect2()
	for node: Node in tree.get_nodes_in_group(&"lcn_hud_chrome"):
		if node.has_method(&"solved_rect"):
			stage = node.call(&"solved_rect", &"stage") as Rect2
			break
	if stage.size.x <= 1.0 or stage.size.y <= 1.0:
		return Rect2()
	# A STRIP, NOT A BOX. The solver's own slot is a 96 px band because it was
	# sized for four sentences of flavour under a dilemma; what stands here is
	# ONE line with a deadline on it, and `_grow_up` will take exactly the height
	# that line needs between this and twice it. Sized as a box instead, the
	# first version of this put a 400 x 135 plate of prose in the lower middle of
	# `artifacts/H3_fix2/shots/assault.png` — the card at a third of the height,
	# which is the defect, not the fix.
	var h: float = clampf(stage.size.y * 0.05, 40.0, 90.0)
	return Rect2(Vector2(stage.position.x, stage.end.y - h),
		Vector2(maxf(200.0, stage.size.x * 0.62), h))


## THE AFTER-ACTION MOMENT, AND WHY IT IS THE SAME RULE.
##
## [P20]'s night report is the screen that says what the night cost: the verdict,
## what the city made, what it lost, and the one thing that nearly ended it. It
## is raised on its own at dawn. It is the second half of the same contract the
## rule above enforces — a night the player cannot watch and cannot afterwards
## READ is a night that happened to somebody else.
##
## [P22] already stands its card down for an open [P20] screen, politely, through
## `_work_surface_open()`. This is the same enforcement argument as the watch: the
## presenter group is a seam, the politeness leaves with the part that implements
## it, and "what may stand on the stage" is this file's question. The layer table
## puts STATS at 76 and NARRATIVE at 66, so the report is never literally covered
## — what this stops is the SCRIM, which is drawn at 65 under both of them and
## would otherwise sit a 52% deep-blue wash over the city behind a report about
## that city, on the say-so of a card nobody can see.
##
## Asked by group and public method, never by node path: with [P20] absent this
## is false and nothing changes.
func _grading() -> bool:
	var tree: SceneTree = get_tree()
	if tree == null:
		return false
	for stats: Node in tree.get_nodes_in_group(&"lcn_stats"):
		if bool(stats.get(&"is_open")):
			return true
	return false
