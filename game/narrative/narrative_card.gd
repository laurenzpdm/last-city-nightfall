class_name LcnNarrativeCard
extends CanvasLayer
## [P22] The event card, and the ticker underneath it.
##
## WHY THIS EXISTS IN game/narrative/ AND NOT IN game/ui/
##
## Because a decision the player cannot reach is not a decision. This part
## produces dilemmas with a deadline on them; if nothing in the running game
## draws one, the deadline expires against nobody, the default option is taken
## by the machine, and the whole of [P22] is a log file. That happened to an
## entire build menu for a phase, so this part ships its own way of being seen.
##
## IT YIELDS. `LcnLayers` is the integrator's allocation table and this node is
## not in it; the moment [P17] or [P18] wants to draw events properly, they put
## a node in the group `lcn_narrative_presenter` and this stands down at install
## time and forever after. The API in narrative_api.gd is the same one they
## would use, so nothing about this card is load-bearing for the data.
##
## LAYER: `LcnLayers.NARRATIVE`, and the number is READ FROM THE TABLE rather
## than copied into this file. It used to say 78 here and 78 there, which is two
## places to change and one of them will be missed.
##
## THIS CARD DOES NOT STOP THE WORLD, SO IT DOES NOT GET THE TOP OF THE STACK.
## The old row put it at 78, above [P18]'s browsers (74) and [P20]'s stats (76),
## on the argument that a card is answered so it is on top. It is not on top: the
## clock keeps running behind it, the deadline expires whether it is read or not,
## and the player can ignore it — which is exactly what non-modal means. In
## `artifacts/ui_tour/shots/01_palette.png` that argument printed this card
## across the entire cost column of [P18]'s build palette, so a player could not
## read what a building cost while a story was on screen. Six of six tour frames.
##
## AND ORDER ALONE WAS NOT ENOUGH. [P18]'s palette is 982 px wide at 1920x1080
## and this card is 661; simply moving the card underneath leaves it sticking out
## from behind a panel, which is clutter rather than composition. So the card
## also STANDS DOWN — see `_work_surface_open()`. When the player has opened a
## surface deliberately, the story waits for them to close it. It is not
## discarded and it is not answered: the sim's deadline is untouched, and the
## card is on screen again the frame after Escape.
##
## THE ALTERNATIVE WAS PHOTOGRAPHED BEFORE IT WAS REJECTED. Reordering without
## standing down is in `artifacts/E3_probe/shots/01_palette.png`: 300 px of card
## hangs out of the right-hand side of the palette reading "still", "at is the",
## "miles that", "when the", and the card's title bleeds through the palette's
## own semi-transparent plate as a ghost across the building list. A torn
## fragment of a sentence is worse than no sentence.
##
## AND IT HAS A CONSEQUENCE IN [P18], WRITTEN DOWN SO IT IS NOT A SURPRISE.
## [P18]'s hover sheet stands down while a decision is on screen, keyed on
## [P17]'s solved `card` rect. With the card standing down first, that rect goes
## empty and the sheet comes back — correctly, there is no decision to outrank —
## and `tests/d7/run_layout_audit.tscn` then fails `palette x sheet` in four
## cases. The overlap is [P18]'s and it is the MOUSE-FOLLOW branch of
## `_place_tooltip()`, not the docked one: the sheet lands at
## `mouse + (18, 18)` = (978, 558) with the pointer parked at the centre of a
## 1920x1080 screen, and that is 35 px inside a palette running from x 24 to
## 1013. The docked branch exists precisely so "a tooltip that hides the list it
## describes" cannot happen; the world-hover branch clamps to the screen and to
## the stage floor but never to `left_block()`, which [P18] already computes for
## exactly this. It was never measurable before, because in the audit's build
## state there was always a card up and the sheet was always hidden.
##
## AND IT WAITS FOR THE NIGHT. THIS IS THE RULE, NOT A PLACEMENT.
##
## Three rounds running, this card sat over the middle of the screen at the exact
## moment the middle of the screen was the thing to look at, and three times it
## was MOVED rather than governed. `artifacts/CRIT/shots/assault.png`: "A Demand
## With a Date On It", dead centre, over a city with ten hostiles inside the
## perimeter. `artifacts/H3_base/shots/dusk.png` is the same defect one beat
## earlier and reads worse — the ATTENTION stack says "Attack in 25 seconds: a
## turret mount, on a pipe, on that side, before the number reaches zero" and
## this card is drawn across the side it means.
##
## So `LcnWorldWatch` answers one question — is the world being watched — and
## this presenter stands down for as long as the answer is yes, on the same
## `deferred` path a work surface already uses. Nothing is answered, discarded or
## expired: the deadline runs in the sim, and the card is back the frame the
## night ends. The player is TOLD, in one line at the top of the flavour feed
## (`_waiting_line`), which is low and left and out of the stage.
##
## `LcnHudStage` enforces the same rule over whatever presenter holds the group,
## so this standing down is the polite half of it and not the load-bearing half.
##
## INPUT. Mouse only, on real Buttons. Every key on the keyboard is claimed by
## somebody in `LcnLayers` and the number row is claimed twice, so a card that
## bound 1/2/3 to its options would silently fight the sim-speed keys.

const GROUP: StringName = &"lcn_narrative_presenter"
const LAYER: int = LcnLayers.NARRATIVE

const CARD_W: float = 620.0
const MARGIN: float = 28.0
const PAD: float = 20.0
const FEED_LINES: int = 4
const REFRESH_SECONDS: float = 0.2

var _root: Control = null
var _panel: PanelContainer = null
var _column: VBoxContainer = null
var _kicker: Label = null
var _title: Label = null
var _lede: Label = null
var _body: RichTextLabel = null
var _because: VBoxContainer = null
## The "BECAUSE" heading and the rule above it, kept so both can be hidden when
## there is nothing under them. A heading with no rows is worse than no heading.
var _because_head: Label = null
var _because_rule: Control = null
var _options: VBoxContainer = null
var _clock: Label = null
## The flavour feed's PLATE. `LcnHudStage` places whatever Control is named
## "Ticker", so the plate carries the name and the prose inside it does not.
var _ticker_plate: PanelContainer = null
## The prose itself. Still called `_ticker` and still a Label, because
## `tests/narrative/test_reachable.gd` reads `_ticker.text` to prove that what the
## city is saying reaches the screen — renaming it would have turned a real check
## into a nil.
var _ticker: Label = null

var _showing: String = ""
var _signature: String = ""
var _accum: float = 0.0
## True while a card exists but is standing down for a surface the player opened.
## `LcnHudStage` republishes this so [P17] can say so somewhere if it wants to;
## nothing else in the build depends on it.
var deferred: bool = false
## True while the flavour feed actually has a line in it. Published for
## `LcnHudStage`, which owns where the plate goes and therefore also owns the
## `visible` flag on it — see `_refresh_ticker()`.
var ticker_has_lines: bool = false
## Why the world is being watched, as a `LcnWorldWatch.Watch`. `NONE` means a
## card may stand. Published so `LcnHudStage` can say in one word why it is
## holding a presenter down, and so a test can read the rule's answer instead of
## inferring it from a hidden panel.
var watch: int = LcnWorldWatch.Watch.NONE


func _ready() -> void:
	name = "LcnNarrativeCard"
	layer = LAYER
	add_to_group(GROUP)
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	_refresh()


func _build() -> void:
	_root = Control.new()
	_root.name = "Root"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_panel = PanelContainer.new()
	_panel.name = "Card"
	_panel.add_theme_stylebox_override("panel", _plate(Color(0.043, 0.055, 0.086, 0.96),
		Color(0.62, 0.42, 0.22, 0.85)))
	_panel.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(_panel)

	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_left", int(PAD))
	pad.add_theme_constant_override("margin_right", int(PAD))
	pad.add_theme_constant_override("margin_top", int(PAD))
	pad.add_theme_constant_override("margin_bottom", int(PAD))
	_panel.add_child(pad)

	_column = VBoxContainer.new()
	_column.add_theme_constant_override("separation", 9)
	pad.add_child(_column)

	_kicker = _label("", 12, Color(0.78, 0.55, 0.30))
	_column.add_child(_kicker)

	_title = _label("", 24, Color(0.94, 0.93, 0.90))
	_column.add_child(_title)

	_lede = _label("", 15, Color(0.80, 0.82, 0.86))
	_column.add_child(_lede)

	_body = RichTextLabel.new()
	_body.bbcode_enabled = false
	_body.fit_content = true
	_body.scroll_active = false
	_body.custom_minimum_size = Vector2(CARD_W, 0.0)
	_body.add_theme_font_size_override("normal_font_size", 14)
	_body.add_theme_color_override("default_color", Color(0.74, 0.76, 0.80))
	# Label defaults to IGNORE in Godot 4; RichTextLabel defaults to STOP. This
	# one is prose with no links and no selection, so the default made the body
	# text the GUI's hover target over the middle of the screen — the header of
	# this file says "mouse only, on real Buttons" and this is the line that
	# makes that true.
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_column.add_child(_body)

	_because_rule = _rule()
	_column.add_child(_because_rule)

	_because_head = _label("BECAUSE", 11, Color(0.55, 0.60, 0.68))
	_column.add_child(_because_head)
	_because = VBoxContainer.new()
	_because.add_theme_constant_override("separation", 2)
	_column.add_child(_because)

	_clock = _label("", 12, Color(0.85, 0.45, 0.32))
	_column.add_child(_clock)

	_options = VBoxContainer.new()
	_options.add_theme_constant_override("separation", 8)
	_column.add_child(_options)

	# THE FLAVOUR FEED GETS A PLATE AND A WORD WRAP.
	#
	# It used to be a bare Label with a text shadow, 12 px, `AUTOWRAP_OFF`, laid
	# straight on the caldera floor: four lines of unplated small type over a
	# moving, lit, ember-strewn background, at the one type size in the build that
	# has no plate under it. In `artifacts/CRIT/shots/dawn.png` it runs from the
	# stage's left wall to x≈1100, over the city, through [P19]'s world badges,
	# and the last line ends where the box does rather than where the sentence
	# does — an unwrapped line has nowhere to go but out of its own rectangle.
	#
	# A shadow is not a substitute for a background: it raises the letters off the
	# ground and does nothing for the twenty per cent of the glyph that is the
	# ground. So: the same plate the card uses at a lower opacity, a real margin,
	# 13 px, and WORD_SMART wrapping so a sentence ends on a word. The plate is
	# what `LcnHudStage` positions, and `_grow_up()` there fits it to its own
	# prose instead of to a constant.
	_ticker_plate = PanelContainer.new()
	_ticker_plate.name = "Ticker"
	_ticker_plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ticker_plate.add_theme_stylebox_override("panel", _plate(
		Color(0.043, 0.055, 0.086, 0.72), Color(0.38, 0.42, 0.50, 0.55)))
	var tpad := MarginContainer.new()
	tpad.add_theme_constant_override("margin_left", 12)
	tpad.add_theme_constant_override("margin_right", 12)
	tpad.add_theme_constant_override("margin_top", 8)
	tpad.add_theme_constant_override("margin_bottom", 8)
	tpad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ticker_plate.add_child(tpad)
	_ticker = Label.new()
	_ticker.name = "TickerText"
	_ticker.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_ticker.add_theme_font_size_override("font_size", 13)
	_ticker.add_theme_color_override("font_color", Color(0.74, 0.77, 0.83))
	_ticker.add_theme_constant_override("line_spacing", 3)
	_ticker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tpad.add_child(_ticker)
	_root.add_child(_ticker_plate)


func _process(delta: float) -> void:
	_accum += delta
	if _accum < REFRESH_SECONDS:
		return
	_accum = 0.0
	_refresh()


# =========================================================================
#  drawing
# =========================================================================

func _refresh() -> void:
	if not Sim.alive:
		_panel.visible = false
		deferred = false
		watch = LcnWorldWatch.Watch.NONE
		return
	_layout()
	var card: Dictionary = Narrative.current()
	# ASKED BEFORE THE FEED IS BUILT, because a held card puts a line INTO the
	# feed and `_refresh_ticker()` is what writes it. This used to run the other
	# way round and the waiting line was always one poll — 200 ms — stale.
	watch = LcnWorldWatch.Watch.NONE if card.is_empty() else LcnWorldWatch.watch()
	# THE STORY WAITS FOR A SURFACE THE PLAYER OPENED. Not answered, not
	# discarded, not shrunk to a stub that would need a rectangle of its own in
	# [P17]'s solver and in the overlap audit — just held, with the deadline still
	# running in the sim where it belongs.
	#
	# AND IT WAITS FOR THE NIGHT, which is the same yielding pointed at the one
	# surface the player did NOT open on purpose. `LcnWorldWatch` is the rule and
	# the whole of its argument is in that file; what belongs here is only that
	# this presenter obeys it, and that the player is told rather than robbed —
	# see the waiting line in `_refresh_ticker()`.
	deferred = _work_surface_open() or watch != LcnWorldWatch.Watch.NONE
	_refresh_ticker(card)
	if card.is_empty():
		_panel.visible = false
		deferred = false
		watch = LcnWorldWatch.Watch.NONE
		_showing = ""
		_signature = ""
		return
	if deferred:
		_panel.visible = false
		return
	_panel.visible = true
	# The countdown moves; the card does not. Rebuilding the whole thing every
	# time the clock ticks would destroy and recreate the option Buttons under
	# the player's cursor several times a second, which is both wasteful and a
	# real way to eat a click on a decision with a deadline on it.
	_clock_text(card)
	var sig: String = "%s|%d" % [String(card.get("id", "")), int(card.get("seq", 0))]
	if sig == _signature:
		return
	_signature = sig
	_draw_card(card)


func _clock_text(card: Dictionary) -> void:
	var hours: float = float(card.get("hours_left", 0.0))
	var has_options: bool = not (card.get("options", []) as Array).is_empty()
	_clock.visible = hours > 0.0 and has_options
	if _clock.visible:
		_clock.text = "%.1f hours before this decides itself." % hours


func _draw_card(card: Dictionary) -> void:
	var id: String = String(card.get("id", ""))
	var category: String = String(card.get("category", "report"))
	_showing = id
	_kicker.text = _kicker_for(category, int(card.get("day", 1)),
		String(card.get("era", "")))
	_title.text = String(card.get("title", ""))
	_lede.text = String(card.get("lede", ""))
	_body.text = String(card.get("body", ""))

	for child: Node in _because.get_children():
		child.queue_free()
	var prose: String = String(card.get("cause_prose", ""))
	if prose != "":
		_because.add_child(_label(prose, 12, Color(0.70, 0.66, 0.58)))
	for line: Variant in card.get("causes", []):
		# "·", not "- ": every cause under BECAUSE is a written sentence, and a
		# hyphen in front of a sentence is a bullet from a markdown file that
		# escaped into a piece of fiction. Nothing else in this interface writes
		# a list that way.
		_because.add_child(_label("·  " + String(line), 12, Color(0.62, 0.68, 0.76)))
	# A CARD WITH NOTHING TO EXPLAIN SAYS NOTHING, rather than printing a heading
	# over empty space. The opening beat is the case: it is the first card in the
	# game and it has no cause, because nothing caused it.
	var has_cause: bool = _because.get_child_count() > 0
	if _because_head != null:
		_because_head.visible = has_cause
	if _because_rule != null:
		_because_rule.visible = has_cause
	_because.visible = has_cause

	var opts: Array = card.get("options", [])
	for child: Node in _options.get_children():
		child.queue_free()
	if opts.is_empty():
		_options.add_child(_button("Read", StringName(id), -1))
		return
	for raw: Variant in opts:
		var o: Dictionary = raw
		var block := VBoxContainer.new()
		block.add_theme_constant_override("separation", 2)
		block.add_child(_button(String(o.get("label", "")), StringName(id),
			int(o.get("index", 0))))
		var body: String = String(o.get("body", ""))
		if body != "":
			block.add_child(_label(body, 12, Color(0.70, 0.73, 0.78)))
		var cost: String = String(o.get("cost", ""))
		if cost != "":
			block.add_child(_label("COSTS  " + cost, 12, Color(0.86, 0.47, 0.36)))
		var gain: String = String(o.get("gain", ""))
		if gain != "":
			block.add_child(_label("GAINS  " + gain, 12, Color(0.52, 0.74, 0.56)))
		_options.add_child(block)


## The line stamped across the top of every card: the day, and what KIND of
## thing this is — a decision, the dead, a report from outside.
##
## A story beat used to be stamped "THE WINTER", which is the only entry in this
## list that is not a kind of card, reads like the name of an act, and sat four
## hundred pixels under [P09]'s era plate on the clock reading THE LULL. Two
## names for the chapter of the game you are in, on screen together, disagreeing.
## A beat now carries the SAME era the clock does, so the card is stamped with
## the date-line rather than arguing with it.
func _kicker_for(category: String, day: int, era: String) -> String:
	match category:
		"beat":
			if era != "":
				return "DAY %d   %s" % [day, era.to_upper()]
			return "DAY %d   THE WINTER" % day
		"dilemma": return "DAY %d   A DECISION" % day
		"obituary": return "DAY %d   THE DEAD" % day
		"scout": return "DAY %d   FROM OUTSIDE" % day
	return "DAY %d   REPORT" % day


## AN EMPTY PLATE IS NOT A QUIET FEED, IT IS A BUG WITH A BORDER ON IT.
##
## The feed says nothing at all for the first minutes of a run and again in every
## gap between lines, and the plate was drawn regardless: a 730 x 105 rounded
## rectangle, rimmed and tinted, laid over the middle of the city with no text in
## it (`artifacts/play_tour/shots/08_lens_5.png`, and again under the build
## palette in `01_palette.png`). It reads as a panel that failed to load.
##
## `LcnHudStage` already treats a zero-height ticker as "do not draw" and places
## the card against a taller stage when there is nothing here, so hiding the
## plate costs nothing and gives the frame back to the world.
func _refresh_ticker(card: Dictionary = {}) -> void:
	var out: PackedStringArray = PackedStringArray()
	# THE WAITING LINE. A modal that vanishes with no trace is a bug the player
	# reports; a modal that leaves a sentence behind is a rule they learn. It
	# goes FIRST because it is the only line here with a deadline on it, and it
	# is written only for the watch — a card held for a browser the player opened
	# themselves needs no explanation, they are looking at the reason.
	if watch != LcnWorldWatch.Watch.NONE and not card.is_empty():
		out.append(_waiting_line(card))
	# AND DURING A WATCH IT IS THAT LINE AND NOTHING ELSE. This is the "shrinks
	# to a ticker" half of the rule and it has to be taken literally: four
	# sentences about the kitchen, laid across the city while ten hostiles are
	# inside the perimeter, is the same defect as the card at a third of the
	# height. One line, because one line is the only thing here with a deadline
	# on it. The feed comes back with the card, when the night is over.
	if watch == LcnWorldWatch.Watch.NONE:
		for row: Dictionary in Narrative.feed(FEED_LINES):
			var text: String = String(row.get("text", "")).strip_edges()
			if text != "":
				out.append(text)
	_ticker.text = "\n".join(out)
	ticker_has_lines = not out.is_empty()
	_ticker_plate.visible = ticker_has_lines


## One sentence: what is waiting, how long it has, and why it is not on screen.
## The hours come from the same `hours_left` the card's own countdown prints, so
## a player who watched the number on the card sees it keep moving in the feed
## rather than a decision that appears to have been taken away from them.
func _waiting_line(card: Dictionary) -> String:
	var title: String = String(card.get("title", "")).strip_edges()
	if title == "":
		title = "A decision"
	var hours: float = float(card.get("hours_left", 0.0))
	var has_options: bool = not (card.get("options", []) as Array).is_empty()
	var when: String = " — %.1f h left" % hours if (hours > 0.0 and has_options) else ""
	return "Waiting: \u201c%s\u201d%s. Held while %s." % [
		title, when, LcnWorldWatch.because(watch)]


## True when the player has a surface open that they opened on purpose: any of
## [P18]'s browsers, [P20]'s statistics screen, or [P24]'s modal stack.
##
## Asked by GROUP and by public method, never by node path or private flag —
## `game/narrative/` may not reach into `game/ui/`, and a state a part can only
## reach by cheating is a state the game does not have. Every one of these
## lookups is allowed to come back null: with none of those parts installed this
## returns false and the card behaves exactly as it did before.
func _work_surface_open() -> bool:
	var tree: SceneTree = get_tree()
	if tree == null:
		return false
	var menu: Node = tree.get_first_node_in_group(&"lcn_build_menu")
	if menu != null and menu.has_method(&"open_panels") \
			and not (menu.call(&"open_panels") as Array).is_empty():
		return true
	for stats: Node in tree.get_nodes_in_group(&"lcn_stats"):
		if bool(stats.get(&"is_open")):
			return true
	for meta: Node in tree.get_nodes_in_group(&"lcn_meta"):
		if meta.has_method(&"is_open") and bool(meta.call(&"is_open")):
			return true
	return false


## Where the card goes is not a taste question, it is the layer table's rule in
## two dimensions. [P17] owns the four corners: heat grid and attention upper
## left, the clock upper centre, the people and the wave upper right, stores
## along the bottom. The first version of this card sat on the right and put
## itself straight through the NEXT WAVE panel — the same class of mistake as a
## world badge over the clock, and just as visible in a screenshot.
##
## So: horizontally centred, below the clock, above the stores. The ticker goes
## down the left flank between [P17]'s attention stack and [P19]'s legend.
func _layout() -> void:
	var size: Vector2 = _root.size
	if size.x <= 0.0:
		size = Vector2(get_viewport().get_visible_rect().size)
	var width: float = CARD_W + PAD * 2.0
	_panel.custom_minimum_size = Vector2(width, 0.0)
	# The card's parent is a plain Control, so nothing shrinks the panel when the
	# content gets shorter: a two-option dilemma sets the height, the next beat
	# has four fewer paragraphs and one button, and the plate keeps the taller
	# rectangle. Measured in artifacts/play3/shots/deep_night.png — 230 px of
	# empty card under the Read button of "The First Night", directly after "The
	# Clerk Wants an Answer". Re-fitting here rather than in `_draw_card` because
	# the outgoing rows are queue_free()d and are still in the tree this frame.
	_panel.size = Vector2(width, _panel.get_combined_minimum_size().y)
	var top: float = size.y * 0.22
	var bottom_limit: float = size.y - MARGIN * 3.0 - _panel.size.y
	_panel.position = Vector2(roundf((size.x - width) * 0.5),
		roundf(clampf(top, MARGIN, maxf(MARGIN, bottom_limit))))
	# Fallback placement only: whenever [P17]'s stage director is in the tree it
	# overwrites both of these every frame from the solver, and it is the only
	# thing that can see the rest of the chrome. Width is set as a MINIMUM so the
	# plate wraps to it and then takes exactly the height its own prose needs —
	# a fixed 90 px box was how four lines of flavour ended up half in and half
	# out of their own rectangle.
	var t_w: float = maxf(200.0, size.x * 0.36)
	_ticker_plate.custom_minimum_size = Vector2(t_w, 0.0)
	_ticker_plate.size = Vector2(t_w, _ticker_plate.get_combined_minimum_size().y)
	_ticker_plate.position = Vector2(MARGIN, size.y * 0.55)


# =========================================================================
#  answering
# =========================================================================

## Answers whatever is on screen exactly the way the player's own buttons do: a
## card with nothing to decide is acknowledged, a dilemma takes its first option.
## Returns false when nothing was up.
##
## Public because this card is opaque to the mouse over the middle of the screen
## — correctly, it has buttons on it — which means anything driving the game
## without hands (the reachability suite, `--ui-tour`, a harness playthrough) has
## to be able to put it away through the same path a player uses, rather than by
## reaching past [P22] and hiding a node.
func dismiss_current() -> bool:
	var card: Dictionary = Narrative.current()
	if card.is_empty():
		return false
	var id: StringName = StringName(String(card.get("id", "")))
	if String(id) == "":
		return false
	var opts: Array = card.get("options", [])
	if opts.is_empty():
		Narrative.acknowledge(id)
	else:
		Narrative.choose(id, int((opts[0] as Dictionary).get("index", 0)))
	_signature = ""
	return true


func _on_pressed(id: StringName, option_index: int) -> void:
	if option_index < 0:
		Narrative.acknowledge(id)
	else:
		Narrative.choose(id, option_index)
	# The command is applied at the top of the next tick. Clear the signature so
	# the next refresh redraws whatever is underneath rather than leaving a card
	# on screen that the simulation has already taken off the pile.
	_signature = ""


# =========================================================================
#  small builders
# =========================================================================

func _label(text: String, size: int, colour: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(CARD_W, 0.0)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", colour)
	return l


func _button(text: String, id: StringName, option_index: int) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(CARD_W, 30.0)
	b.add_theme_font_size_override("font_size", 15)
	b.pressed.connect(_on_pressed.bind(id, option_index))
	return b


func _rule() -> Control:
	var r := ColorRect.new()
	r.color = Color(0.35, 0.30, 0.24, 0.7)
	r.custom_minimum_size = Vector2(CARD_W, 1.0)
	return r


func _plate(fill: Color, edge: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.border_color = edge
	sb.set_border_width_all(1)
	sb.border_width_left = 3
	sb.set_corner_radius_all(2)
	sb.content_margin_left = 0.0
	return sb
