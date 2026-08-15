class_name LcnSaveBrowser
extends LcnMetaScreen
## [P24] The slot browser, in both directions: saving into a slot and loading
## out of one.
##
## A slot is a row with a picture of the city, the name, the day it reached, how
## many were alive and when it was written. That list is not decoration: it is
## the only way a player picks the right save six hours later, and "Slot 3,
## 14:22" is not enough to tell two runs apart.
##
##   Enter    save into / load out of the focused slot
##   Del      delete it, through the confirm dialog
##   Esc      back
##
## Overwriting an existing slot and deleting one both go through
## [LcnConfirmDialog]. Writing a NEW slot does not — nothing is destroyed, and a
## confirm on a harmless action is how a player learns to dismiss the one that
## matters.

var mode: String = "load"   ## "load" or "save"

var _rows_by_id: Dictionary[StringName, Dictionary] = {}


func _init() -> void:
	# GDScript does not call a base _init() when the subclass declares one, and
	# without this the list this screen draws is null.
	super()
	screen_id = &"saves"
	panel_width = 0.58
	panel_max_height = 0.82


func enter(args: Dictionary) -> void:
	mode = String(args.get("mode", "load"))
	title = "SAVE THE CITY" if mode == "save" else "LOAD A CITY"
	subtitle = "caldera nine"
	footer = "↑↓ move   Enter %s   Del delete   Esc back" % ("save" if mode == "save" else "load")
	refresh()


func refresh() -> void:
	_rows_by_id.clear()
	var rows: Array[Dictionary] = []
	if mode == "save":
		rows.append({"kind": LcnMetaList.Kind.ACTION, "id": &"__new",
			"label": "A new save", "hint": "writes %s" % LcnSaveManager.next_free_slot()})
	var slots: Array[Dictionary] = LcnSaveManager.slots()
	if slots.is_empty():
		rows.append({"kind": LcnMetaList.Kind.NOTE, "id": &"__none",
			"label": "Nothing saved yet." if mode == "save" else "There is nothing to load."})
	for head: Dictionary in slots:
		var slot: String = String(head.get("slot", ""))
		var id := StringName("slot_" + slot)
		_rows_by_id[id] = head
		var thumb_bytes: PackedByteArray = LcnSaveFile.read_header_and_thumb(slot).get("thumbnail", PackedByteArray())
		rows.append({
			"kind": LcnMetaList.Kind.SLOT, "id": id,
			"label": String(head.get("name", slot)),
			"sub": LcnSaveManager.describe_slot(head),
			"right": ("autosave" if bool(head.get("autosave", false)) else "")
				+ ("  %s" % _size_text(int(head.get("world_bytes", 0)))),
			"thumbnail": LcnSaveManager.thumbnail_texture(thumb_bytes),
			"empty_text": "no picture",
		})
	list.set_rows(rows)
	relayout()


func handle_key(event: InputEventKey) -> bool:
	if event.pressed and (event.keycode == KEY_DELETE or event.keycode == KEY_BACKSPACE):
		var head: Dictionary = _rows_by_id.get(list.focused_id(), {})
		if head.is_empty():
			return true
		request_screen.emit(&"confirm", {
			"title": "Delete this city",
			"body": "%s — day %d, %d alive." % [
				String(head.get("name", "")), int(head.get("day", 1)),
				int(head.get("population", 0))],
			"detail": "There is no other copy of it.",
			"confirm": "Delete", "cancel": "Keep",
			"action": "delete_slot", "payload": {"slot": String(head.get("slot", ""))}})
		return true
	return super.handle_key(event)


func _on_row_activated(id: StringName) -> void:
	if id == &"__new":
		request_screen.emit(&"__save_to", {"slot": LcnSaveManager.next_free_slot(), "name": ""})
		return
	var head: Dictionary = _rows_by_id.get(id, {})
	if head.is_empty():
		return
	var slot: String = String(head.get("slot", ""))
	if mode == "load":
		request_screen.emit(&"__load_from", {"slot": slot})
		return
	request_screen.emit(&"confirm", {
		"title": "Write over this save",
		"body": "%s — day %d, %d alive." % [
			String(head.get("name", "")), int(head.get("day", 1)),
			int(head.get("population", 0))],
		"detail": "What is in it now will be gone.",
		"confirm": "Write over it", "cancel": "Keep it",
		"action": "save_to", "payload": {"slot": slot, "name": String(head.get("name", ""))}})


static func _size_text(bytes: int) -> String:
	if bytes <= 0:
		return ""
	if bytes < 1024 * 1024:
		return "%d kB" % int(round(float(bytes) / 1024.0))
	return "%.1f MB" % (float(bytes) / 1048576.0)
