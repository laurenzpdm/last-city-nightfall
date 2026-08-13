class_name LcnInputRouter
extends Node
## The arbiter for keys that more than one part claimed. INTEGRATOR-OWNED.
##
## Three parts wrote correct code and produced a broken keyboard. [P16] bound
## 1/2/3 to sim speed through the InputMap and reads them in `_unhandled_input`.
## [P18]'s quickbar reads 1..0 in `_input`, which runs first, so it wins — but
## only once the quickbar has entries, and it starts empty, which is why every
## test and every screenshot run saw the speed keys working and a player would
## lose them the moment they placed their first building. [P19] claims any bare
## number the InputMap has not taken, so it owns 4/5/6 — unless [P18] is in the
## tree after it, in which case the winner depends on `add_child` order.
##
## A keyboard whose behaviour depends on scene-tree order is not a keyboard.
## This node is installed by boot as the front-most `_input` receiver, takes the
## keys listed in `LcnLayers` and dispatches them itself:
##
##   SPACE  pause / resume        → camera.toggle_pause()
##   1 2 3  sim speed             → camera.set_sim_speed()
##   4 5 6  lens 4, 5, 6          → overlay root.set_mode()
##
## Everything else falls through untouched, so [P18] keeps 7/8/9/0, every panel
## hotkey and every text field behave exactly as they did.
##
## It refuses to fire while a text field has focus — a player typing "smelter 4"
## into the palette's search box is searching, not switching lenses.

## Freeze, Logistics, Coverage — the three lenses [P19] puts on bare 4/5/6.
## Held as plain ints so game/play/ does not have to compile against [P19].
const LENS_FOR_KEY: Dictionary[int, int] = {KEY_4: 4, KEY_5: 5, KEY_6: 6}

signal routed(key: int, target: StringName)

var camera: Node = null
var overlay: Node = null

## Every key this node consumed, newest last. The reachability suite reads it.
var trace: Array[StringName] = []


func _ready() -> void:
	name = "InputRouter"
	# Panels and the pause menu must not be able to lock the keyboard out.
	process_mode = Node.PROCESS_MODE_ALWAYS


## Boot hands over what it installed. Either may be null; a missing part turns
## its keys back into fall-through rather than swallowing them.
func bind(cam: Node, overlay_root: Node) -> void:
	camera = cam
	overlay = overlay_root


func _input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.ctrl_pressed or key.meta_pressed or key.alt_pressed:
		return
	if _typing():
		return
	var code: int = key.physical_keycode
	if code == KEY_SPACE:
		if _pause():
			_consume(key, &"pause")
		return
	var speed_index: int = LcnLayers.RESERVED_TIME.find(code)
	if speed_index >= 0:
		if _speed(LcnLayers.SPEED_STEPS[speed_index]):
			_consume(key, &"speed")
		return
	if LENS_FOR_KEY.has(code):
		if _lens(LENS_FOR_KEY[code]):
			_consume(key, &"lens")


func _consume(key: InputEventKey, target: StringName) -> void:
	trace.append(target)
	routed.emit(key.physical_keycode, target)
	var vp: Viewport = get_viewport()
	if vp != null:
		vp.set_input_as_handled()


## A focused LineEdit/TextEdit owns the keyboard. Anything else does not.
func _typing() -> bool:
	var vp: Viewport = get_viewport()
	if vp == null:
		return false
	var focus: Control = vp.gui_get_focus_owner()
	return focus is LineEdit or focus is TextEdit


func _pause() -> bool:
	if camera == null or not camera.has_method(&"toggle_pause"):
		return false
	camera.call(&"toggle_pause")
	return true


func _speed(speed: float) -> bool:
	if camera == null or not camera.has_method(&"set_sim_speed"):
		return false
	camera.call(&"set_sim_speed", speed)
	return true


func _lens(mode: int) -> bool:
	if overlay == null or not overlay.has_method(&"set_mode"):
		return false
	var current: int = int(overlay.get(&"mode"))
	overlay.call(&"set_mode", 0 if current == mode else mode)
	return true
