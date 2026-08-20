class_name LcnSettingsIndex
extends LcnMetaScreen
## [P24] The four doors: display, sound, controls, accessibility.
##
## Four screens rather than one long list with headings, because the controls
## page alone is thirty rows and a player looking for the text size should not
## have to walk past every key in the game to find it.


func _init() -> void:
	# GDScript does not call a base _init() when the subclass declares one, and
	# without this the list this screen draws is null.
	super()
	screen_id = &"settings"
	title = "SETTINGS"
	panel_width = 0.34


func refresh() -> void:
	var rows: Array[Dictionary] = []
	rows.append({"kind": LcnMetaList.Kind.ACTION, "id": &"display", "label": "Display",
		"hint": "window, resolution, frame cap, interface scale"})
	rows.append({"kind": LcnMetaList.Kind.ACTION, "id": &"audio", "label": "Sound",
		"hint": "the four gains the game mixes under"})
	rows.append({"kind": LcnMetaList.Kind.ACTION, "id": &"controls", "label": "Controls",
		"hint": "every key, rebindable"})
	rows.append({"kind": LcnMetaList.Kind.ACTION, "id": &"access", "label": "Accessibility",
		"hint": "colour vision, text size, motion, holding instead of pressing"})
	list.set_rows(rows)
	relayout()


func _on_row_activated(id: StringName) -> void:
	request_screen.emit(id, {})
