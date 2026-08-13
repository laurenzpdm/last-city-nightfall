class_name LcnTooltipView
extends PanelContainer
## [P18] Draws a LcnBuildFacts sheet.
##
## Deliberately dumb: it takes plain data and lays it out. All the intelligence
## — the live sim reads, the warnings, the derived heat behaviour — happens in
## LcnBuildFacts, which is why the interesting half of this feature is testable
## without a window.
##
## Reading order is fixed and it is the order a player needs it in:
##   name → what it is → WARNINGS → cost → the numbers.
## Warnings sit above the stats because a red line about no pipe reaching this
## tile is worth more than nine rows of correct throughput figures.

const WIDTH: float = 380.0

var _column: VBoxContainer = null
var _title: Label = null
var _subtitle: Label = null
var _description: Label = null
var _warnings: VBoxContainer = null
var _cost: VBoxContainer = null
var _sections: VBoxContainer = null
var _footer: Label = null
var _signature: String = ""
var _accent: Color = LcnUiStyle.ACCENT


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(WIDTH, 0.0)
	add_theme_stylebox_override(&"panel", LcnUiStyle.panel_box(false, true))
	_build()


func _build() -> void:
	_column = VBoxContainer.new()
	_column.add_theme_constant_override(&"separation", 4)
	_column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_column)

	_title = LcnUiStyle.label("", LcnUiStyle.FS_TITLE, LcnUiStyle.TEXT_BRIGHT)
	_column.add_child(_title)

	_subtitle = LcnUiStyle.label("", LcnUiStyle.FS_SMALL, LcnUiStyle.ACCENT)
	_column.add_child(_subtitle)

	_description = LcnUiStyle.label("", LcnUiStyle.FS_SMALL, LcnUiStyle.TEXT_DIM)
	_description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_description.custom_minimum_size = Vector2(WIDTH - LcnUiStyle.PAD * 2.0, 0.0)
	_column.add_child(_description)

	_warnings = _group()
	_cost = _group()
	_sections = _group()

	_footer = LcnUiStyle.label("", LcnUiStyle.FS_TINY, LcnUiStyle.TEXT_FAINT)
	_column.add_child(_footer)


func _group() -> VBoxContainer:
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0.0, 4.0)
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_column.add_child(spacer)
	var box := VBoxContainer.new()
	box.add_theme_constant_override(&"separation", 2)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_column.add_child(box)
	return box


## Feeds the view. Rebuilds only when the sheet actually changed — a tooltip that
## rebuilds forty labels every frame is how a UI eats a millisecond for nothing.
func set_sheet(sheet: Dictionary) -> void:
	var sig: String = _signature_of(sheet)
	if sig == _signature:
		return
	_signature = sig

	_title.text = String(sheet.get("title", "—"))
	_subtitle.text = String(sheet.get("subtitle", ""))
	_subtitle.visible = _subtitle.text != ""
	_description.text = String(sheet.get("description", ""))
	_description.visible = _description.text != ""
	var tint: Variant = sheet.get("tint", null)
	_accent = tint if typeof(tint) == TYPE_COLOR else LcnUiStyle.ACCENT
	_title.add_theme_color_override(&"font_color", LcnUiStyle.TEXT_BRIGHT)
	_subtitle.add_theme_color_override(&"font_color", _accent)

	_clear(_warnings)
	for raw: Variant in sheet.get("warnings", []):
		var w: Dictionary = raw
		_warnings.add_child(_warning_row(String(w.get("text", "")), int(w.get("tone", LcnUiStyle.Tone.WARN))))

	_clear(_cost)
	var cost: Dictionary = sheet.get("cost", {})
	var rows: Array = cost.get("rows", [])
	if not rows.is_empty():
		_cost.add_child(_heading("Cost"))
		for raw2: Variant in rows:
			var r: Dictionary = raw2
			var have: int = int(r.get("have", -1))
			var value: String = "%d" % int(r.get("need", 0))
			if have >= 0:
				value = "%d  of %s" % [int(r.get("need", 0)), LcnUiFormat.group(have)]
			_cost.add_child(_fact_row(String(r.get("label", "")), value, int(r.get("tone", 0))))
		if cost.has("build_label"):
			_cost.add_child(_fact_row("Build time", String(cost["build_label"]), LcnUiStyle.Tone.DIM))

	_clear(_sections)
	for raw3: Variant in sheet.get("sections", []):
		var section: Dictionary = raw3
		var section_rows: Array = section.get("rows", [])
		if section_rows.is_empty():
			continue
		_sections.add_child(_heading(String(section.get("heading", ""))))
		for raw4: Variant in section_rows:
			var row: Dictionary = raw4
			_sections.add_child(_fact_row(
				String(row.get("label", "")), String(row.get("value", "")),
				int(row.get("tone", LcnUiStyle.Tone.NEUTRAL))))

	_footer.text = String(sheet.get("footer", ""))
	_footer.visible = _footer.text != ""


func clear() -> void:
	set_sheet({"title": "—", "sections": [], "warnings": []})


func _clear(box: VBoxContainer) -> void:
	for child: Node in box.get_children():
		box.remove_child(child)
		child.queue_free()


func _heading(text: String) -> Control:
	var l: Label = LcnUiStyle.label(text.to_upper(), LcnUiStyle.FS_TINY, LcnUiStyle.TEXT_FAINT)
	return l


func _fact_row(label: String, value: String, tone: int) -> Control:
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override(&"separation", 8)
	var left: Label = LcnUiStyle.label(label, LcnUiStyle.FS_SMALL, LcnUiStyle.TEXT_DIM)
	left.custom_minimum_size = Vector2(118.0, 0.0)
	row.add_child(left)
	var right: Label = LcnUiStyle.label(value, LcnUiStyle.FS_SMALL, LcnUiStyle.tone_color(tone))
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(right)
	return row


func _warning_row(text: String, tone: int) -> Control:
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override(&"separation", 6)
	var colour: Color = LcnUiStyle.tone_color(tone)
	var bullet: Label = LcnUiStyle.label("!", LcnUiStyle.FS_SMALL, colour)
	bullet.custom_minimum_size = Vector2(10.0, 0.0)
	row.add_child(bullet)
	var body: Label = LcnUiStyle.label(text, LcnUiStyle.FS_SMALL, colour)
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.custom_minimum_size = Vector2(WIDTH - LcnUiStyle.PAD * 2.0 - 16.0, 0.0)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(body)
	return row


## Cheap content fingerprint. Two sheets with the same text are the same sheet.
static func _signature_of(sheet: Dictionary) -> String:
	var parts: PackedStringArray = PackedStringArray()
	parts.append(String(sheet.get("title", "")))
	parts.append(String(sheet.get("subtitle", "")))
	for raw: Variant in sheet.get("warnings", []):
		parts.append(String((raw as Dictionary).get("text", "")))
	var cost: Dictionary = sheet.get("cost", {})
	for raw2: Variant in cost.get("rows", []):
		var r: Dictionary = raw2
		parts.append("%s%d/%d" % [String(r.get("label", "")), int(r.get("need", 0)), int(r.get("have", -1))])
	parts.append(String(cost.get("build_label", "")))
	for raw3: Variant in sheet.get("sections", []):
		var s: Dictionary = raw3
		for raw4: Variant in s.get("rows", []):
			var row: Dictionary = raw4
			parts.append("%s=%s" % [String(row.get("label", "")), String(row.get("value", ""))])
	return "|".join(parts)
