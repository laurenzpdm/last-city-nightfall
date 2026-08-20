class_name LcnAccessSettings
extends LcnMetaScreen
## [P24] Accessibility, treated as a feature of this game in particular.
##
## This game encodes its central fact — warm versus cold — in colour, which is
## exactly the axis a red-green deficiency does not separate. That is why the
## colourblind setting here is not a checkbox: [P19]'s lenses swap their whole
## ramp per deficiency and carry a dash pattern and a glyph per channel so no
## reading depends on hue at all, and [P17]'s HUD remaps the three status hues.
## Both of them already read `Settings.accessibility`; this screen is where a
## player sets it, and the swatch strip below the list is where they can SEE the
## difference before they leave the menu.
##
## The tokens written here — off / protan / deutan / tritan / mono — are the
## short forms, chosen because they are the ones BOTH consumers understand.
## [P19] also accepts the long names (`protanopia`…); [P17] matches `tritan`
## exactly and nothing else, so writing "tritanopia" would silently give a
## tritan player the red-green remap instead of theirs.
##
## Text scaling is separate from interface scaling on purpose: `font_scale`
## grows the type without inflating the panels, and every row height in this
## part is derived from the type size rather than being a constant, which is
## what stops 160 % text from clipping out of its row.

const CB_VALUES: Array[String] = ["off", "protan", "deutan", "tritan", "mono"]
const CB_TEXT: Dictionary[String, String] = {
	"off": "off",
	"protan": "protanopia — red-weak",
	"deutan": "deuteranopia — green-weak",
	"tritan": "tritanopia — blue-weak",
	"mono": "monochrome",
}
const CB_WHAT: Dictionary[String, String] = {
	"off": "warm/cold as authored",
	"protan": "good readings go cyan; lenses use the Okabe-Ito set",
	"deutan": "good readings go cyan; lenses use the Okabe-Ito set",
	"tritan": "caution goes magenta; the thermal ramp becomes teal-red",
	"mono": "every lens falls back to pure luminance and its dash pattern",
}


func _init() -> void:
	# GDScript does not call a base _init() when the subclass declares one, and
	# without this the list this screen draws is null.
	super()
	screen_id = &"access"
	title = "ACCESSIBILITY"
	panel_width = 0.52
	panel_max_height = 0.78
	# The proof strip lives under the rows; give it the room rather than letting
	# it draw over them.
	foot_lines = 7.0


func refresh() -> void:
	var s: Node = _settings()
	if s == null:
		return
	var rows: Array[Dictionary] = []
	rows.append({"kind": LcnMetaList.Kind.HEADER, "id": &"h_colour", "label": "colour"})
	var cb: String = String(s.call("get_value", "accessibility", "colorblind_mode", "off"))
	if not CB_VALUES.has(cb):
		cb = "off"
	var cb_values: Array = []
	for v: String in CB_VALUES:
		cb_values.append(v)
	rows.append({"kind": LcnMetaList.Kind.CHOICE, "id": &"colorblind_mode",
		"label": "Colour vision", "values": cb_values, "value": cb,
		"value_text": CB_TEXT.get(cb, cb), "hint": CB_WHAT.get(cb, "")})
	rows.append({"kind": LcnMetaList.Kind.TOGGLE, "id": &"high_contrast_overlays",
		"label": "High contrast", "value": bool(s.call("get_value", "accessibility", "high_contrast_overlays", false)),
		"hint": "heavier plate, brighter ink, thicker lens strokes"})

	rows.append({"kind": LcnMetaList.Kind.HEADER, "id": &"h_text", "label": "text"})
	var fs_v: float = float(s.call("get_value", "accessibility", "font_scale", 1.0))
	rows.append({"kind": LcnMetaList.Kind.SLIDER, "id": &"font_scale", "label": "Text size",
		"min": 0.8, "max": 1.6, "step": 0.05, "value": fs_v,
		"value_text": "%d%%" % int(round(fs_v * 100.0)),
		"hint": "grows the type only — the panels stay where they are"})

	rows.append({"kind": LcnMetaList.Kind.HEADER, "id": &"h_motion", "label": "motion"})
	rows.append({"kind": LcnMetaList.Kind.TOGGLE, "id": &"reduce_motion",
		"label": "Reduce motion", "value": bool(s.call("get_value", "accessibility", "reduce_motion", false)),
		"hint": "no shake, no hit-stop, no pulsing; travel becomes a cut"})
	var shake: float = float(s.call("get_value", "graphics", "screen_shake", 1.0))
	rows.append({"kind": LcnMetaList.Kind.SLIDER, "id": &"screen_shake", "label": "Screen shake",
		"min": 0.0, "max": 1.0, "step": 0.1, "value": shake,
		"value_text": "off" if shake <= 0.0 else "%d%%" % int(round(shake * 100.0)),
		"enabled": not bool(s.call("get_value", "accessibility", "reduce_motion", false))})

	rows.append({"kind": LcnMetaList.Kind.HEADER, "id": &"h_hands", "label": "hands"})
	rows.append({"kind": LcnMetaList.Kind.TOGGLE, "id": &"hold_to_confirm",
		"label": "Hold instead of press", "value": bool(s.call("get_value", "accessibility", "hold_to_confirm", false)),
		"on_text": "hold", "off_text": "press",
		"hint": "anything that destroys a save is held for a moment, not pressed once"})
	var delay: float = float(s.call("get_value", "gameplay", "tooltip_delay", 0.35))
	rows.append({"kind": LcnMetaList.Kind.SLIDER, "id": &"tooltip_delay", "label": "Tooltip delay",
		"min": 0.0, "max": 1.5, "step": 0.05, "value": delay,
		"value_text": "instant" if delay <= 0.0 else "%.2f s" % delay})
	rows.append({"kind": LcnMetaList.Kind.TOGGLE, "id": &"edge_scroll", "label": "Edge scrolling",
		"value": bool(s.call("get_value", "gameplay", "edge_scroll", true))})
	list.set_rows(rows)
	relayout()


func _on_row_changed(id: StringName, value: Variant) -> void:
	var s: Node = _settings()
	if s == null:
		return
	var section: String = "accessibility"
	if id == &"screen_shake":
		section = "graphics"
	elif id == &"tooltip_delay" or id == &"edge_scroll":
		section = "gameplay"
	s.call("set_value", section, String(id), value)
	s.call("save_to_disk")
	if style != null:
		style.refresh_from_settings()
	refresh()


## The proof strip. Whatever the player just chose is drawn here in the colours
## the game will actually use, at the text size they just set, with the glyph
## that carries the same meaning when the colour cannot.
func draw_extra(panel: Rect2) -> void:
	var y: float = panel.end.y - float(style.fs(LcnMetaStyle.FS_SMALL)) * 4.6
	var x: float = panel.position.x + LcnMetaList.PAD
	var w: float = (panel.size.x - LcnMetaList.PAD * 2.0) / 3.0
	var kinds: Array[StringName] = [&"good", &"warn", &"bad"]
	var words: Array[String] = ["warm", "thin", "freezing"]
	var glyphs: Array[String] = ["·", "!", "!!!"]
	for i: int in 3:
		var swatch := Rect2(Vector2(x + w * float(i), y), Vector2(w - 10.0, 10.0))
		draw_rect(swatch, style.status(kinds[i]), true)
		style.text(self, Vector2(swatch.position.x, y + float(style.fs(LcnMetaStyle.FS_SMALL)) * 1.9),
			"%s %s" % [glyphs[i], words[i]], LcnMetaStyle.FS_SMALL, style.status(kinds[i]))


func _settings() -> Node:
	if not is_inside_tree():
		return null
	return get_tree().root.get_node_or_null(NodePath("Settings"))
