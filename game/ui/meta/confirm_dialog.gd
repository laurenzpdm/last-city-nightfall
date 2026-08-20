class_name LcnConfirmDialog
extends LcnMetaScreen
## [P24] "Are you sure." Shown for anything that destroys something a player
## cannot get back: overwriting a save, deleting one, abandoning a run, quitting.
##
## Two rules it follows and most confirm dialogs do not:
##
##   1. **Cancel is focused.** Enter on a dialog you did not read does the safe
##      thing. The destructive entry is one deliberate keypress away, and it is
##      the only red thing on the screen.
##   2. **It names what is at stake in the game's own terms** — "day 12, 28
##      alive, saved an hour ago" — not "Slot 3". A player deletes a slot id
##      without thinking and does not delete a city they remember.
##
## `accessibility/hold_to_confirm` turns the destructive entry into a hold: the
## same guard for a player whose hands do not always press once.

const HOLD_SECONDS: float = 0.9

var body: String = ""
var confirm_text: String = "Yes"
var cancel_text: String = "No"
var detail: String = ""
## Echoed back to whoever opened the dialog.
var action: String = ""
var payload: Dictionary = {}

var _hold: float = 0.0
var _holding: bool = false


func _init() -> void:
	# GDScript does not call a base _init() when the subclass declares one, and
	# without this the list this screen draws is null.
	super()
	screen_id = &"confirm"
	panel_width = 0.36
	footer = "↑↓ move   Enter choose   Esc back"


func enter(args: Dictionary) -> void:
	title = String(args.get("title", "Are you sure"))
	body = String(args.get("body", ""))
	detail = String(args.get("detail", ""))
	confirm_text = String(args.get("confirm", "Yes"))
	cancel_text = String(args.get("cancel", "No"))
	action = String(args.get("action", ""))
	payload = args.get("payload", {})
	subtitle = ""
	_hold = 0.0
	_holding = false
	refresh()
	# Cancel first, and focused. See rule 1.
	var _ok: bool = list.focus_id(&"cancel")


func refresh() -> void:
	var rows: Array[Dictionary] = []
	rows.append({"kind": LcnMetaList.Kind.NOTE, "id": &"body", "label": body})
	if detail != "":
		rows.append({"kind": LcnMetaList.Kind.NOTE, "id": &"detail", "label": detail})
	rows.append({"kind": LcnMetaList.Kind.ACTION, "id": &"cancel", "label": cancel_text})
	rows.append({"kind": LcnMetaList.Kind.ACTION, "id": &"confirm",
		"label": confirm_text + (("   (hold Enter)") if _hold_required() else "")})
	list.set_rows(rows)
	relayout()


func _hold_required() -> bool:
	var s: Node = _settings()
	if s == null:
		return false
	return bool(s.call("get_value", "accessibility", "hold_to_confirm", false))


func handle_key(event: InputEventKey) -> bool:
	# A hold is only a hold when the option asked for one; otherwise Enter is a
	# press, because making everybody hold a key is not accessibility.
	if _hold_required() and list.focused_id() == &"confirm" \
			and (event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER or event.keycode == KEY_SPACE):
		if event.pressed:
			_holding = true
			set_process(true)
			return true
		_holding = false
		_hold = 0.0
		queue_redraw()
		return true
	return super.handle_key(event)


func _process(delta: float) -> void:
	if not _holding:
		set_process(false)
		return
	_hold += delta
	queue_redraw()
	if _hold >= HOLD_SECONDS:
		_holding = false
		_hold = 0.0
		set_process(false)
		_fire()


func _on_row_activated(id: StringName) -> void:
	if id == &"cancel":
		request_close.emit()
		return
	if id == &"confirm":
		if _hold_required():
			return
		_fire()


func _fire() -> void:
	request_screen.emit(&"__confirmed", {"action": action, "payload": payload})


func draw_extra(panel: Rect2) -> void:
	if not _holding:
		return
	var t: float = clampf(_hold / HOLD_SECONDS, 0.0, 1.0)
	var bar := Rect2(panel.position + Vector2(LcnMetaList.PAD, panel.size.y - 8.0),
		Vector2((panel.size.x - LcnMetaList.PAD * 2.0) * t, 3.0))
	draw_rect(bar, style.accent(), true)


func _settings() -> Node:
	return get_tree().root.get_node_or_null(NodePath("Settings")) if is_inside_tree() else null
