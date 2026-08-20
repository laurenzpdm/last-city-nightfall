class_name LcnMetaRoot
extends CanvasLayer
## [P24] The meta layer: title screen, pause menu, settings, saves, confirms.
##
## Layer 80 (`LcnLayers.MODAL`) — the table reserves it for exactly this, and
## `game/boot.gd` calls `LcnLayers.enforce()` on every launch, so a disagreement
## here is corrected and named in the log rather than silently winning.
##
## ONE STACK, ONE INPUT PATH. Every screen is pushed onto `_stack`; the top of
## the stack gets every key first and Esc pops it. That is why "Esc goes back
## one step, from anywhere" is true in this part rather than being a convention
## each screen re-implements slightly differently — which is how a build ends up
## with a settings page you can only leave with the mouse.
##
## While anything is open the simulation is PAUSED and the previous speed is
## remembered, because a pause menu that lets the night keep coming is not a
## pause menu.
##
## What it does NOT do: it never opens itself during a harness run, a `--ui-tour`
## or a `--force-ui` suite. Those configurations exist to drive the rest of the
## build, and a modal that appears over them would break every other part's
## reachability checks. `tests/meta/run_meta_ui.tscn` opens it explicitly, which
## is a stronger test than an ambient one anyway.

const GROUP: StringName = &"lcn_meta"

signal screen_changed(id: StringName)

var style: LcnMetaStyle = null
var autosave: LcnAutosave = null

var _screens: Dictionary[StringName, LcnMetaScreen] = {}
var _stack: Array[LcnMetaScreen] = []
var _resume_speed: float = 1.0
var _was_running: bool = false
var _last_message: String = ""


func _init() -> void:
	name = "LcnMetaRoot"
	layer = LcnLayers.MODAL


func _ready() -> void:
	add_to_group(GROUP)
	process_mode = Node.PROCESS_MODE_ALWAYS
	style = LcnMetaStyle.new()

	# Settings the player set last time, put into effect before anything draws.
	Keybinds.install()
	Keybinds.restore(_settings())
	LcnDisplaySettings.apply_all()

	autosave = LcnAutosave.new()
	add_child(autosave)

	if _should_open_title():
		open_screen(&"main", {})
	Log.info("meta", "meta layer ready on canvas layer %d — %d save(s) on disk" % [
		layer, LcnSaveManager.slots().size()])


func _process(delta: float) -> void:
	if style != null and not _stack.is_empty():
		style.beat += delta
		_stack[_stack.size() - 1].queue_redraw()


## A player launch. Not a harness run, not the UI tour, not a suite driving the
## build with --force-ui.
func _should_open_title() -> bool:
	if Harness.active:
		return false
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.has("--no-menu") or args.has("--ui-tour") or args.has("--force-ui"):
		return false
	return DisplayServer.get_name() != "headless"


# =================================================================== stack ===

func is_open() -> bool:
	return not _stack.is_empty()


func current_screen() -> StringName:
	if _stack.is_empty():
		return &""
	return _stack[_stack.size() - 1].screen_id


func stack_ids() -> PackedStringArray:
	var out := PackedStringArray()
	for s: LcnMetaScreen in _stack:
		out.append(String(s.screen_id))
	return out


## The list on the top screen — what the reachability suite reads to prove a row
## is reachable rather than merely drawn.
func focused_row_id() -> StringName:
	if _stack.is_empty():
		return &""
	return _stack[_stack.size() - 1].list.focused_id()


## Pushes a screen. Returns it, or null when the id is unknown.
func open_screen(id: StringName, args: Dictionary = {}) -> LcnMetaScreen:
	var screen: LcnMetaScreen = _screen(id)
	if screen == null:
		Log.warn("meta", "no screen called '%s'" % id)
		return null
	if _stack.is_empty():
		_pause_the_world()
		_take_the_keyboard()
	elif _stack[_stack.size() - 1] == screen:
		screen.enter(args)
		return screen
	else:
		_stack[_stack.size() - 1].visible = false
		_stack[_stack.size() - 1].leave()
	if not _stack.has(screen):
		_stack.append(screen)
	screen.visible = true
	screen.enter(args)
	# First in the parent's child order is LAST to receive input; a screen that
	# has just opened must be first, so it goes to the back of the child list.
	move_child(screen, get_child_count() - 1)
	screen_changed.emit(id)
	return screen


## Pops the top screen. Returns true when something was closed.
func close_top() -> bool:
	if _stack.is_empty():
		return false
	var top: LcnMetaScreen = _stack.pop_back()
	top.visible = false
	top.leave()
	if _stack.is_empty():
		_resume_the_world()
		screen_changed.emit(&"")
		return true
	var below: LcnMetaScreen = _stack[_stack.size() - 1]
	below.visible = true
	below.enter({})
	move_child(below, get_child_count() - 1)
	screen_changed.emit(below.screen_id)
	return true


func close_all() -> void:
	while not _stack.is_empty():
		var _did: bool = close_top()


func _screen(id: StringName) -> LcnMetaScreen:
	if _screens.has(id):
		return _screens[id]
	var screen: LcnMetaScreen = null
	match id:
		&"main": screen = LcnMainMenu.new()
		&"pause": screen = LcnPauseMenu.new()
		&"settings": screen = LcnSettingsIndex.new()
		&"display": screen = LcnDisplaySettings.new()
		&"audio": screen = LcnAudioSettings.new()
		&"controls": screen = LcnControlsSettings.new()
		&"access": screen = LcnAccessSettings.new()
		&"saves": screen = LcnSaveBrowser.new()
		&"confirm": screen = LcnConfirmDialog.new()
	if screen == null:
		return null
	screen.name = "Screen_%s" % id
	screen.visible = false
	screen.attach_style(style)
	add_child(screen)
	screen.request_close.connect(func() -> void: var _c: bool = close_top())
	screen.request_screen.connect(_on_request_screen)
	_screens[id] = screen
	return screen


# =================================================================== input ===

func _input(event: InputEvent) -> void:
	if _stack.is_empty():
		return
	var top: LcnMetaScreen = _stack[_stack.size() - 1]
	if top.handle_any(event):
		get_viewport().set_input_as_handled()
		return
	var key := event as InputEventKey
	if key == null:
		return
	if not key.pressed:
		# Swallow the release of a key we consumed, so a rebind capture does not
		# see its own Enter come back the other way round.
		get_viewport().set_input_as_handled()
		return
	if key.keycode == KEY_ESCAPE:
		if top.screen_id == &"main":
			# The title screen is the bottom of the world. Esc does not leave it.
			get_viewport().set_input_as_handled()
			return
		var _c: bool = close_top()
		get_viewport().set_input_as_handled()
		return
	if top.handle_key(key):
		get_viewport().set_input_as_handled()
		return
	# Anything else is swallowed while a modal is up. A build menu opening
	# behind a pause screen is the class of bug this stack exists to prevent.
	get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if not _stack.is_empty():
		return
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if Keybinds.event_is(event, &"quick_save"):
		quick_save()
		get_viewport().set_input_as_handled()
		return
	if Keybinds.event_is(event, &"quick_load"):
		quick_load()
		get_viewport().set_input_as_handled()
		return
	if key.keycode == KEY_ESCAPE:
		# Last in the chain on purpose: [P18] closes its panels on Esc first and
		# marks the event handled, so the pause menu only opens when Esc had
		# nothing else to do — which is what a player means by it.
		var _s: LcnMetaScreen = open_screen(&"pause", {})
		get_viewport().set_input_as_handled()


# ================================================================ commands ===

func _on_request_screen(id: StringName, args: Dictionary) -> void:
	match id:
		&"__new_game":
			close_all()
			new_game()
		&"__continue":
			_load_and_close(String(args.get("slot", "")))
		&"__load_from":
			_load_and_close(String(args.get("slot", "")))
		&"__save_to":
			_save_and_close(String(args.get("slot", "")), String(args.get("name", "")))
		&"__confirmed":
			_confirmed(String(args.get("action", "")), args.get("payload", {}))
		_:
			var _s: LcnMetaScreen = open_screen(id, args)


func _confirmed(action: String, payload: Dictionary) -> void:
	var _c: bool = close_top()   # the dialog itself
	match action:
		"quit_game":
			Log.info("meta", "quit requested from the menu")
			get_tree().quit(0)
		"to_title":
			close_all()
			var _t: LcnMetaScreen = open_screen(&"main", {})
		"delete_slot":
			var slot: String = String(payload.get("slot", ""))
			var _d: bool = LcnSaveManager.delete(slot)
			if not _stack.is_empty():
				_stack[_stack.size() - 1].refresh()
		"save_to":
			_save_and_close(String(payload.get("slot", "")), String(payload.get("name", "")))
		"reset_keybinds":
			var controls: LcnMetaScreen = _screens.get(&"controls")
			if controls != null:
				(controls as LcnControlsSettings).reset_all_bindings()


## A fresh city, through the same command path boot uses, so the opening a
## player gets from the menu is the opening a player gets on launch.
func new_game(world_seed: int = -1) -> void:
	var used: int = world_seed if world_seed >= 0 else _launch_seed()
	if Sim.alive and SimClock.tick <= 1 and used == _launch_seed():
		# Launch case: boot already built exactly this world one frame ago.
		# Regenerating it would cost a second of worldgen to produce the same map.
		SimClock.start()
		Log.info("meta", "new city — keeping the world boot just made (seed %d)" % used)
		return
	Sim.create_world(used)
	var boot_script: Script = load("res://game/boot.gd") as Script
	var build: SimSystem = Sim.get_system(&"build")
	var grid: SimSystem = Sim.get_system(&"grid")
	if boot_script != null and build != null and grid != null:
		var cell: Vector2i = grid.call("core_cell")
		for cmd: Dictionary in boot_script.call("opening_commands", cell):
			Sim.submit_command(cmd)
		SimClock.advance(1)
	SimClock.start()
	Log.info("meta", "new city, seed %d" % used)


func _launch_seed() -> int:
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--seed="):
			return int(a.substr(7))
	return 7


func quick_save() -> bool:
	var head: Dictionary = LcnSaveManager.save(LcnSaveManager.QUICKSAVE_SLOT, "Quick save")
	_announce("saved" if not head.is_empty() else "the city could not be saved")
	return not head.is_empty()


func quick_load() -> bool:
	if not LcnSaveManager.exists(LcnSaveManager.QUICKSAVE_SLOT):
		_announce("there is no quick save")
		return false
	var ok: bool = LcnSaveManager.load_slot(LcnSaveManager.QUICKSAVE_SLOT)
	_announce("loaded" if ok else "that save could not be read")
	return ok


func _save_and_close(slot: String, display_name: String) -> void:
	if slot == "":
		return
	var head: Dictionary = LcnSaveManager.save(slot, display_name)
	if head.is_empty():
		_announce("the city could not be saved")
		return
	_announce("saved — day %d" % int(head.get("day", 0)))
	close_all()


func _load_and_close(slot: String) -> void:
	if slot == "":
		return
	if not LcnSaveManager.load_slot(slot):
		_announce("that save could not be read")
		return
	close_all()
	SimClock.start()


func _announce(text: String) -> void:
	_last_message = text
	Log.info("meta", text)
	Bus.toast.emit(text)


func last_message() -> String:
	return _last_message


# =================================================================== world ===

## A modal has to be FIRST to see a key, and in Godot that means LAST in the
## tree: `_input` is delivered in reverse tree order.
##
## Being installed early is not enough. This part registers from
## `game/content/meta/`, and `Registry` scans directories alphabetically, so
## every bootstrap after "meta" — overlays, render, vfx, view — is added to the
## root AFTER this node and therefore sees every key BEFORE it. That is not
## hypothetical: with the rebinding screen waiting for a key, pressing 4 went to
## [P19]'s lens root, which consumed it, so the capture never ended and the very
## next keypress was bound to the action instead. Moving to the back of the
## child list on open costs nothing and settles it for every screen at once.
func _take_the_keyboard() -> void:
	var parent: Node = get_parent()
	if parent != null and parent.get_child(parent.get_child_count() - 1) != self:
		parent.move_child(self, parent.get_child_count() - 1)


func _pause_the_world() -> void:
	_was_running = SimClock.running
	_resume_speed = SimClock.speed
	SimClock.pause()


func _resume_the_world() -> void:
	SimClock.speed = _resume_speed
	if _was_running:
		SimClock.start()


func _settings() -> Node:
	if not is_inside_tree():
		return null
	return get_tree().root.get_node_or_null(NodePath("Settings"))
