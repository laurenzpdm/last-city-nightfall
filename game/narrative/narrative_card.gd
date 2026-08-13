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
## LAYER 78. Between [P20]'s stats (76) and the modal slot (80): a card that
## stops the winter has to cover a panel, and it must not cover a tutorial gate
## or a pause menu. The node name is not in `LcnLayers.SLOTS`, so `enforce()`
## leaves it alone rather than correcting it to somebody else's number.
##
## INPUT. Mouse only, on real Buttons. Every key on the keyboard is claimed by
## somebody in `LcnLayers` and the number row is claimed twice, so a card that
## bound 1/2/3 to its options would silently fight the sim-speed keys.

const GROUP: StringName = &"lcn_narrative_presenter"
const LAYER: int = 78

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
var _options: VBoxContainer = null
var _clock: Label = null
var _ticker: Label = null

var _showing: String = ""
var _signature: String = ""
var _accum: float = 0.0


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
	_column.add_child(_body)

	_column.add_child(_rule())

	var because_head := _label("BECAUSE", 11, Color(0.55, 0.60, 0.68))
	_column.add_child(because_head)
	_because = VBoxContainer.new()
	_because.add_theme_constant_override("separation", 2)
	_column.add_child(_because)

	_clock = _label("", 12, Color(0.85, 0.45, 0.32))
	_column.add_child(_clock)

	_options = VBoxContainer.new()
	_options.add_theme_constant_override("separation", 8)
	_column.add_child(_options)

	_ticker = _label("", 12, Color(0.72, 0.75, 0.82))
	_ticker.name = "Ticker"
	_ticker.autowrap_mode = TextServer.AUTOWRAP_OFF
	# The ticker floats over the world, not over a plate, and the caldera floor
	# goes from near-black at night to a bright warm grey at midday. A shadow is
	# cheaper than a panel and keeps the line readable on both.
	_ticker.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.85))
	_ticker.add_theme_constant_override("shadow_offset_x", 1)
	_ticker.add_theme_constant_override("shadow_offset_y", 1)
	_ticker.add_theme_constant_override("shadow_outline_size", 3)
	_root.add_child(_ticker)


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
		return
	_layout()
	_refresh_ticker()
	var card: Dictionary = Narrative.current()
	if card.is_empty():
		_panel.visible = false
		_showing = ""
		_signature = ""
		return
	var sig: String = "%s|%d|%.1f" % [String(card.get("id", "")),
		int(card.get("seq", 0)), float(card.get("hours_left", 0.0))]
	if sig == _signature:
		return
	_signature = sig
	_panel.visible = true
	_draw_card(card)


func _draw_card(card: Dictionary) -> void:
	var id: String = String(card.get("id", ""))
	var category: String = String(card.get("category", "report"))
	_showing = id
	_kicker.text = _kicker_for(category, int(card.get("day", 1)))
	_title.text = String(card.get("title", ""))
	_lede.text = String(card.get("lede", ""))
	_body.text = String(card.get("body", ""))

	for child: Node in _because.get_children():
		child.queue_free()
	var prose: String = String(card.get("cause_prose", ""))
	if prose != "":
		_because.add_child(_label(prose, 12, Color(0.70, 0.66, 0.58)))
	for line: Variant in card.get("causes", []):
		_because.add_child(_label("- " + String(line), 12, Color(0.62, 0.68, 0.76)))

	var hours: float = float(card.get("hours_left", 0.0))
	var opts: Array = card.get("options", [])
	_clock.visible = hours > 0.0 and not opts.is_empty()
	if _clock.visible:
		_clock.text = "%.1f hours before this decides itself." % hours

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


func _kicker_for(category: String, day: int) -> String:
	match category:
		"beat": return "DAY %d   THE WINTER" % day
		"dilemma": return "DAY %d   A DECISION" % day
		"obituary": return "DAY %d   THE DEAD" % day
		"scout": return "DAY %d   FROM OUTSIDE" % day
	return "DAY %d   REPORT" % day


func _refresh_ticker() -> void:
	var lines: Array[Dictionary] = Narrative.feed(FEED_LINES)
	var out: PackedStringArray = PackedStringArray()
	for row: Dictionary in lines:
		out.append(String(row.get("text", "")))
	_ticker.text = "\n".join(out)


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
	var top: float = size.y * 0.22
	var bottom_limit: float = size.y - MARGIN * 3.0 - _panel.size.y
	_panel.position = Vector2(roundf((size.x - width) * 0.5),
		roundf(clampf(top, MARGIN, maxf(MARGIN, bottom_limit))))
	_ticker.position = Vector2(MARGIN, size.y * 0.55)
	_ticker.size = Vector2(size.x * 0.36, 90.0)


# =========================================================================
#  answering
# =========================================================================

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
