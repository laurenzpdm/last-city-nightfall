class_name LcnControlsSettings
extends LcnMetaScreen
## [P24] Key rebinding — every action, grouped by what it belongs to.
##
## It does NOT own the action map. [P16]'s [Keybinds] already defines every
## action, matches with exact modifiers, refuses colliding rebinds and stores
## overrides in `Settings.gameplay["keybinds"]`. This screen is the surface for
## it, and it adds exactly one rule of its own:
##
##   **A rebind goes through `LcnLayers.key_is_reserved()`, not around it.**
##
## The number row is arbitrated by `LcnInputRouter` before any panel sees it —
## 1/2/3 are sim speed and 4/5/6 are lenses — so a player who binds "rotate" to
## 4 would get a key that appears bound, reads back as bound, and does nothing,
## because the router consumed it two frames earlier. Asking the InputMap
## whether 4 is free is not the same question and gives the wrong answer: the
## InputMap does not know about the router. This screen asks the table.
##
## Esc always cancels a capture and is never bindable — it is the key that gets
## a player out of a menu they do not understand, and a build where it can be
## reassigned has a state a player cannot leave.

const CTX_TITLES: Array[String] = [
	"moving the view", "pointing at things", "building", "time", "lenses", "the game",
]

var _capturing: StringName = &""
var _message: String = ""
var _message_tone: StringName = &"warn"


func _init() -> void:
	# GDScript does not call a base _init() when the subclass declares one, and
	# without this the list this screen draws is null.
	super()
	screen_id = &"controls"
	title = "CONTROLS"
	panel_width = 0.52
	panel_max_height = 0.84
	foot_lines = 4.6
	footer = "↑↓ move   Enter rebind   Del clear   Esc back"


func enter(args: Dictionary) -> void:
	_capturing = &""
	_message = ""
	Keybinds.install()
	super.enter(args)


func leave() -> void:
	_stop_capture()


func refresh() -> void:
	var rows: Array[Dictionary] = []
	var last_ctx: int = -1
	for action: StringName in Keybinds.actions():
		var ctx: int = Keybinds.context_of(action)
		if ctx != last_ctx:
			last_ctx = ctx
			rows.append({"kind": LcnMetaList.Kind.HEADER, "id": StringName("h_%d" % ctx),
				"label": CTX_TITLES[ctx] if ctx < CTX_TITLES.size() else Keybinds.context_name(ctx)})
		rows.append({
			"kind": LcnMetaList.Kind.KEYBIND, "id": action,
			"label": Keybinds.label(action),
			"value_text": Keybinds.binding_label(action),
			"capturing": _capturing == action,
			"hint": "changed from the default" if Keybinds.is_overridden(action) else "",
		})
	rows.append({"kind": LcnMetaList.Kind.HEADER, "id": &"h_reset", "label": "all of it"})
	rows.append({"kind": LcnMetaList.Kind.ACTION, "id": &"__reset",
		"label": "Put every key back the way it was"})
	list.set_rows(rows)
	list.accepts_input = _capturing == &""
	relayout()


# ---------------------------------------------------------------- capture ----

func handle_any(event: InputEvent) -> bool:
	if _capturing == &"":
		return false
	# Releases and echoes are not bindings. Without this the Enter that STARTED
	# the capture arrives again as its own release and binds Enter to itself.
	var key := event as InputEventKey
	if key != null:
		if not key.pressed or key.echo:
			return true
		if key.keycode == KEY_ESCAPE:
			_stop_capture()
			_say("left as it was", &"warn")
			return true
		_try_bind(key)
		return true
	var mb := event as InputEventMouseButton
	if mb != null:
		if not mb.pressed:
			return true
		_try_bind(mb)
		return true
	return event is InputEventMouseMotion


func handle_key(event: InputEventKey) -> bool:
	if _capturing != &"":
		return true
	if event.pressed and (event.keycode == KEY_DELETE or event.keycode == KEY_BACKSPACE):
		var action: StringName = list.focused_id()
		if Keybinds.has(action):
			Keybinds.clear_bindings(action)
			Keybinds.persist(_settings())
			_say("%s is bound to nothing now" % Keybinds.label(action), &"warn")
			refresh()
		return true
	return super.handle_key(event)


func _on_row_activated(id: StringName) -> void:
	if id == &"__reset":
		request_screen.emit(&"confirm", {
			"title": "Put every key back",
			"body": "Every rebinding you have made goes away.",
			"confirm": "Put them back", "cancel": "Keep mine",
			"action": "reset_keybinds"})
		return
	if not Keybinds.has(id):
		return
	_capturing = id
	_message = ""
	refresh()


func _stop_capture() -> void:
	if _capturing == &"":
		return
	_capturing = &""
	refresh()


## A key as it comes off a real keyboard carries BOTH a physical code and a
## virtual one. Every default in [Keybinds] carries only the physical code, and
## `Keybinds.event_signature()` compares the whole dictionary — so a captured
## `B` (physical B, keycode B) did not match the default `build` binding
## (physical B, keycode 0) and `conflicts()` came back empty. Rebinding "rotate"
## to B was accepted, and the player then had two actions on one key with the
## settings screen insisting there was no clash.
##
## Storing the physical code alone is also the right binding to store: it is
## what keeps WASD under the same fingers on AZERTY and QWERTZ.
static func _normalise(event: InputEvent) -> InputEvent:
	var key := event as InputEventKey
	if key == null:
		return event
	var out := InputEventKey.new()
	out.physical_keycode = key.physical_keycode if key.physical_keycode != 0 else key.keycode
	out.keycode = KEY_NONE
	out.alt_pressed = key.alt_pressed
	out.shift_pressed = key.shift_pressed
	if key.command_or_control_autoremap:
		out.command_or_control_autoremap = true
	else:
		out.ctrl_pressed = key.ctrl_pressed
		out.meta_pressed = key.meta_pressed
	return out


func _try_bind(raw: InputEvent) -> void:
	var event: InputEvent = _normalise(raw)
	var action: StringName = _capturing
	var key := event as InputEventKey
	if key != null:
		var code: int = int(key.physical_keycode if key.physical_keycode != 0 else key.keycode)
		if LcnLayers.key_is_reserved(code) and not _owns_reserved(action, code):
			_stop_capture()
			_say("%s is reserved — the router takes it before any screen sees it" % (
				Keybinds.event_label(event)), &"bad")
			return
	var clash: Array[StringName] = Keybinds.conflicts(action, event)
	if not clash.is_empty():
		var names: PackedStringArray = PackedStringArray()
		for other: StringName in clash:
			names.append(Keybinds.label(other))
		_stop_capture()
		_say("%s is already %s" % [Keybinds.event_label(event), " and ".join(names)], &"bad")
		return
	if not Keybinds.rebind(action, event, 0):
		_stop_capture()
		_say("that cannot be bound", &"bad")
		return
	Keybinds.persist(_settings())
	_stop_capture()
	_say("%s is now %s" % [Keybinds.label(action), Keybinds.event_label(event)], &"good")


## The only actions allowed to hold a reserved key are the ones the reservation
## exists for: sim speed on 1/2/3. Nothing may take 4/5/6 — those belong to the
## lens root, which is not an InputMap action at all.
func _owns_reserved(action: StringName, code: int) -> bool:
	match code:
		KEY_1:
			return action == &"speed_1"
		KEY_2:
			return action == &"speed_2"
		KEY_3:
			return action == &"speed_3"
	return false


func reset_all_bindings() -> void:
	Keybinds.reset_all()
	Keybinds.persist(_settings())
	_say("every key is back where it started", &"good")
	refresh()


func _say(text: String, tone: StringName) -> void:
	_message = text
	_message_tone = tone
	queue_redraw()


func draw_extra(panel: Rect2) -> void:
	if _message == "":
		return
	style.text(self, Vector2(panel.position.x + LcnMetaList.PAD,
		panel.end.y - float(style.fs(LcnMetaStyle.FS_SMALL)) * 2.6),
		_message, LcnMetaStyle.FS_SMALL, style.status(_message_tone))


func _settings() -> Node:
	if not is_inside_tree():
		return null
	return get_tree().root.get_node_or_null(NodePath("Settings"))
