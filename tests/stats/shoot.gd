extends SceneTree
## Screenshot rig for [P20]. NOT a test suite — the runner never sees it, because
## its name matches neither `test_*.gd` nor `run_*.gd` nor a scene.
##
##   /Applications/Godot.app/Contents/MacOS/Godot --path . --resolution 1920x1080 \
##       --script tests/stats/shoot.gd
##
## It boots the REAL game (world, renderer, camera, HUD, build menu, play shell),
## builds a factory, runs a full day and a full night through the real
## simulation, then opens the statistics screen and photographs every tab. Every
## number and every curve in those frames came out of the running world.
##
## Autoloads are named through the tree rather than referenced directly: this
## file is the entry script, and an entry script compiles before the autoloads
## exist (ARCHITECTURE.md §6.1).

const OUT_DIR: String = "res://artifacts/p20/shots"
const BOOT: String = "res://game/boot.tscn"
## Night starts at tick 8256 of a 9600-tick day.
const DUSK: int = 8100
const DEEP_NIGHT: int = 8900
const DAWN: int = 9900

var _boot: Node = null
var _stats: Node = null
var _shots: int = 0


func _initialize() -> void:
	_run()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	_boot = (load(BOOT) as PackedScene).instantiate()
	root.add_child(_boot)
	await process_frame
	await process_frame

	# The rig jumps to exact ticks, so a frame is reproducible.
	_node("SimClock").call("set_manual", true)
	_stats = _tree_stats()
	if _stats == null:
		print("shoot: no statistics screen in the tree — nothing to photograph")
		quit(1)
		return

	_build_a_factory()
	_advance(DUSK)
	await _settle(6)

	# --- the production screen, over the whole run ------------------------
	_stats.call("show_tab", 0)
	_stats.call("set_window", &"run")
	await _settle(8)
	await _shot("01_production_whole_run")

	# --- the same screen, last minute, with the crosshair open ------------
	_stats.call("set_window", &"fine")
	await _settle(6)
	_hover_plot(0, 0.62)
	await _settle(4)
	await _shot("02_production_last_minute")

	# --- heat, over the whole run, with the night shaded ------------------
	_advance(DEEP_NIGHT - DUSK)
	await _settle(6)
	_stats.call("show_tab", 1)
	_stats.call("set_window", &"run")
	await _settle(8)
	await _shot("03_heat_the_shape_of_the_night")

	# --- society, annotated with the laws and the technologies ------------
	_stats.call("show_tab", 2)
	await _settle(8)
	_hover_plot(2, 0.5)
	await _settle(4)
	await _shot("04_society_annotated")

	# --- dawn: the after-action report ------------------------------------
	_advance(DAWN - DEEP_NIGHT)
	await _settle(10)
	_stats.call("show_tab", 3)
	await _settle(8)
	await _shot("05_night_report")

	# --- accessibility: bigger interface, bigger type ---------------------
	var settings: Node = _node("Settings")
	settings.call("set_value", "graphics", "ui_scale", 1.25)
	settings.call("set_value", "accessibility", "font_scale", 1.25)
	_stats.call("_relayout")
	_stats.call("show_tab", 0)
	_stats.call("set_window", &"mid")
	await _settle(8)
	await _shot("06_scaled_up")

	settings.call("set_value", "graphics", "ui_scale", 1.0)
	settings.call("set_value", "accessibility", "font_scale", 1.0)
	_stats.call("_relayout")
	_stats.call("show_tab", 1)
	_stats.call("set_window", &"mid")
	await _settle(8)
	await _shot("07_heat_last_hour")

	print("shots written: %d -> %s" % [_shots, OUT_DIR])
	quit(0)


# ==================================================================  world ==

## A drill on a seam, smelters to eat what it digs, a sorter and a workshop —
## enough of a chain that the production table has tiers in it.
func _build_a_factory() -> void:
	var sim: Node = _node("Sim")
	var c: Vector2i = _core_cell()
	var place := func(kind: String, cell: Vector2i) -> void:
		sim.call("submit_command", {"system": &"build", "op": "place", "kind": kind,
			"cell": [cell.x, cell.y], "rot": 0, "free": true, "instant": true})
	place.call("ore_drill", c + Vector2i(6, -8))
	place.call("ore_drill", c + Vector2i(-8, -8))
	place.call("ore_drill", c + Vector2i(11, -12))
	place.call("scrap_collector", c + Vector2i(9, -4))
	place.call("scrap_collector", c + Vector2i(-11, -4))
	place.call("smelter", c + Vector2i(4, 8))
	place.call("smelter", c + Vector2i(-6, 8))
	place.call("rubble_sorter", c + Vector2i(8, 8))
	place.call("workshop", c + Vector2i(-2, 14))
	place.call("workshop", c + Vector2i(6, 14))
	place.call("coal_generator", c + Vector2i(-7, 14))
	place.call("heat_accumulator", c + Vector2i(2, -6))
	place.call("turret_mount", c + Vector2i(-14, 9))
	_advance(2)


func _core_cell() -> Vector2i:
	var grid: Object = _node("Sim").call("get_system", &"grid")
	if grid != null and grid.has_method("core_cell"):
		return grid.call("core_cell")
	return Vector2i(128, 128)


# ===============================================================  plumbing ==

func _node(n: String) -> Node:
	return root.get_node_or_null(NodePath(n))


func _tree_stats() -> Node:
	return get_first_node_in_group(&"lcn_stats")


func _advance(ticks: int) -> void:
	_node("SimClock").call("advance", maxi(0, ticks))


## Fakes a mouse hover over the middle of a screen's chart so the crosshair and
## its read-out can be photographed. The screen's own code path runs; only the
## event is synthetic.
func _hover_plot(tab: int, fraction: float) -> void:
	var screens: Array = _stats.get("screens")
	if tab < 0 or tab >= screens.size():
		return
	var plot: Control = (screens[tab] as Object).get("plot")
	if plot == null:
		return
	var r: Rect2 = plot.call("plot_rect")
	var event := InputEventMouseMotion.new()
	event.position = Vector2(r.position.x + r.size.x * fraction,
		r.position.y + r.size.y * 0.5)
	plot.call("_gui_input", event)


func _settle(frames: int) -> void:
	for _i: int in frames:
		await process_frame


func _shot(shot_name: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	var img: Image = root.get_texture().get_image()
	img.save_png(ProjectSettings.globalize_path("%s/%s.png" % [OUT_DIR, shot_name]))
	_shots += 1
	print("shot %s" % shot_name)
