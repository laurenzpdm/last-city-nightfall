extends SceneTree
## Screenshot rig for [P17]. NOT a test suite — the runner never sees it, because
## its name matches neither `test_*.gd` nor `run_*.gd` nor a scene.
##
##   /Applications/Godot.app/Contents/MacOS/Godot --path . --resolution 1920x1080 \
##       --script tests/hud/shoot.gd
##
## It boots the REAL game (game/boot.tscn: world, renderer, camera, play shell),
## hides the integrator's placeholder HUD, installs LcnHud over the top and drives
## the city into the states the HUD is supposed to survive — calm day, dusk, a
## grid that has lost its generator, a selection, the accessibility scale — saving
## a PNG at each. Every number in those frames came out of the running simulation.
##
## Autoloads are named through the tree rather than directly: this file is the
## entry script, and an entry script is compiled before the autoloads exist.

const OUT_DIR: String = "res://artifacts/p17/shots"
const BOOT: String = "res://game/boot.tscn"

var _hud: CanvasLayer = null
var _boot: Node = null
var _shots: int = 0


func _initialize() -> void:
	_run()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	root.get_viewport().transparent_bg = false

	_boot = (load(BOOT) as PackedScene).instantiate()
	root.add_child(_boot)
	await process_frame
	await process_frame

	_hide_placeholder_hud()
	_install_hud()
	# Manual clock: the rig jumps to exact ticks so a frame is reproducible.
	_node("SimClock").call("set_manual", true)

	await _settle(6)
	await _shot("01_day_calm")

	# The sun goes down. Same city, more urgency in the frame.
	_advance(5200)
	await _settle(6)
	await _shot("02_dusk")

	# Give the parts that have not landed yet a stand-in, so the vitals, wave and
	# crew panels can be photographed against a real contract.
	var fakes: Script = load("res://tests/hud/fake_systems.gd") as Script
	var citizens: SimSystem = fakes.call("install", fakes.get("FakeCitizens").new(), &"citizens")
	var society: SimSystem = fakes.call("install", fakes.get("FakeSociety").new(), &"society")
	var threat: SimSystem = fakes.call("install", fakes.get("FakeThreat").new(), &"threat")
	fakes.call("install", fakes.get("FakeProduction").new(), &"production")
	_hud.get("probe").call("bind")
	_advance(20)
	await _settle(6)
	await _shot("03_full_readout")

	# Select something and prove the panel answers "what is it doing".
	var id: int = _first_building_of(&"housing_block")
	if id > 0:
		_hud.call("select", id)
	await _settle(4)
	await _shot("04_selection")

	# Now break the city: switch the hearth off. Demand stays, supply goes, the
	# solver starts attributing bottlenecks and buildings begin to freeze.
	var hearth: int = _first_building_of(&"the_hearth")
	if hearth > 0:
		_node("Sim").call("submit_command",
			{"system": &"build", "op": "set_enabled", "id": hearth, "on": false})
	citizens.set("cold", 9)
	citizens.set("ill", 4)
	citizens.set("lost", 2)
	society.set("hope_value", 0.17)
	society.set("discontent_value", 0.72)
	threat.set("seconds", 26.0)
	_advance(2400)
	await _settle(8)
	await _shot("05_city_dying")

	# The tooltip, on the number a player would actually interrogate.
	_hover_first_hot(_hud.get("heat_panel"))
	await _settle(30)
	await _shot("06_tooltip")

	# Accessibility: bigger interface, bigger type, no motion.
	var settings: Node = _node("Settings")
	settings.call("set_value", "graphics", "ui_scale", 1.35)
	settings.call("set_value", "accessibility", "font_scale", 1.25)
	settings.call("set_value", "accessibility", "reduce_motion", true)
	settings.call("set_value", "accessibility", "high_contrast_overlays", true)
	_hud.call("_relayout")
	await _settle(6)
	await _shot("07_scaled_up")

	print("shots written: %d -> %s" % [_shots, OUT_DIR])
	quit(0)


# ==================================================================  plumbing ==

func _node(n: String) -> Node:
	return root.get_node_or_null(NodePath(n))


func _hide_placeholder_hud() -> void:
	for child: Node in _boot.get_children():
		if child is CanvasLayer and child.get_class() == "CanvasLayer" \
				and String(child.name) == "PlayHud":
			(child as CanvasLayer).visible = false


func _install_hud() -> void:
	var script: Script = load("res://game/ui/hud/hud_root.gd") as Script
	_hud = script.new() as CanvasLayer
	root.add_child(_hud)


func _advance(ticks: int) -> void:
	_node("SimClock").call("advance", ticks)


func _settle(frames: int) -> void:
	for _i: int in frames:
		await process_frame


func _shot(shot_name: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	var img: Image = root.get_texture().get_image()
	var path: String = "%s/%s.png" % [OUT_DIR, shot_name]
	img.save_png(ProjectSettings.globalize_path(path))
	_shots += 1
	print("shot %s" % shot_name)


func _first_building_of(kind: StringName) -> int:
	var sim: Node = _node("Sim")
	var build: SimSystem = sim.call("get_system", &"build") as SimSystem
	if build == null:
		return -1
	var list: Array = build.call("buildings_of_kind", kind)
	if list.is_empty():
		return -1
	return int((list[0] as Object).get("id"))


## Fakes a mouse hover over a panel's first hot region so the tooltip can be
## photographed. The HUD's own code path runs; only the event is synthetic.
func _hover_first_hot(widget: Control) -> void:
	if widget == null or widget.get("hot") == null:
		return
	var hot: Array = widget.get("hot")
	if hot.is_empty():
		return
	var rect: Rect2 = hot[0]["rect"]
	var event := InputEventMouseMotion.new()
	event.position = rect.position + rect.size * 0.5
	widget.call("_gui_input", event)
