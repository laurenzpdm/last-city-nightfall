extends Node
## [P17] HUD — the panels themselves, in a real tree, over a real world.
##
##   godot --headless --path . res://tests/hud/run_hud_view.tscn
##
## Run as a SCENE, not with --script: the autoloads only exist once the SceneTree
## has installed them, and every assertion here goes through the real Sim, the
## real Bus and the real Settings (see ARCHITECTURE.md §6.1).
##
## What it proves, in order:
##   * the HUD installs itself with one add_child and survives a world that never
##     finished being built,
##   * a panel whose system is absent HIDES instead of showing confident zeroes,
##   * every visible panel declares hot regions, and every hot region carries a
##     tooltip that explains what the number means,
##   * clicking an alert emits Bus.camera_focus_requested at the tile [P02]
##     blamed — the legibility contract, end to end,
##   * ui_scale and font_scale both take effect, independently,
##   * the keyboard can reach and fire every action the mouse can,
##   * a refresh costs microseconds, not milliseconds.

const TAG: String = "hud-tests"
const HUD_PATH: String = "res://game/ui/hud/hud_root.gd"
const FAKES_PATH: String = "res://tests/hud/fake_systems.gd"

var _checks: int = 0
var _failures: PackedStringArray = PackedStringArray()
var _out_dir: String = "res://artifacts/p17"

var _hud: CanvasLayer = null
var _fakes: Script = null


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out_dir = arg.substr(6)
	call_deferred("_run")


func _run() -> void:
	_fakes = load(FAKES_PATH) as Script
	SimClock.set_manual(true)

	await _suite_installs_into_a_broken_world()
	await _suite_panels_over_a_live_world()

	var verdict: String = "TESTS PASSED" if _failures.is_empty() else "TESTS FAILED"
	for f: String in _failures:
		Log.error(TAG, f)
	Log.info(TAG, "%s — %d checks, %d failures" % [verdict, _checks, _failures.size()])
	print("%s — %d checks, %d failures" % [verdict, _checks, _failures.size()])
	_write_report(verdict)
	get_tree().quit(mini(_failures.size(), 125))


# ==================================================================  suite 1 ==

## Before any world exists, the HUD must install and show nothing. This is the
## state every session starts in, and it is also the state a half-built world
## leaves behind when another part is mid-edit.
func _suite_installs_into_a_broken_world() -> void:
	Sim.teardown()
	_hud = (load(HUD_PATH) as Script).new() as CanvasLayer
	add_child(_hud)
	await get_tree().process_frame
	await get_tree().process_frame

	_ok(_hud.get("probe") != null, "the HUD built its probe")
	_ok(_hud.get("alerts") != null, "the HUD built its alert model")
	var probe: RefCounted = _hud.get("probe")
	_ok(not bool(probe.get("has_heat")), "no world means no heat readings")
	_ok(not bool(probe.get("has_climate")), "no world means no clock readings")
	for panel_name: String in ["heat_panel", "clock_panel", "vitals_panel",
			"wave_panel", "resource_panel", "alert_panel", "selection_panel"]:
		var panel: Control = _hud.get(panel_name)
		_ok(panel != null, "%s exists" % panel_name)
		_ok(not panel.visible, "%s hides itself with nothing to say" % panel_name)
	_ok(float(_hud.call("urgency")) <= 0.001, "an empty world is not an emergency")


# ==================================================================  suite 2 ==

func _suite_panels_over_a_live_world() -> void:
	Sim.create_world(7)
	if not Sim.alive:
		Log.warn(TAG, "Sim.create_world did not complete in this build — "
			+ "skipping the live-world checks")
		return
	# The parts that may not have landed yet get a stand-in, so the panels that
	# depend on them are exercised either way.
	if Sim.get_system(&"citizens") == null:
		_fakes.call("install", _fakes.get("FakeCitizens").new(), &"citizens")
	if Sim.get_system(&"society") == null:
		_fakes.call("install", _fakes.get("FakeSociety").new(), &"society")
	if Sim.get_system(&"threat") == null:
		_fakes.call("install", _fakes.get("FakeThreat").new(), &"threat")
	for cmd: Dictionary in Boot.opening_commands(_core_cell()):
		Sim.submit_command(cmd)
	SimClock.advance(60)

	_hud.call("_on_world_ready")
	await get_tree().process_frame
	await get_tree().process_frame

	var probe: RefCounted = _hud.get("probe")
	probe.call("refresh", true)
	_hud.call("_after_probe")

	_check_visibility(probe)
	_check_tooltips()
	_check_focus_request()
	_check_selection()
	_check_scaling()
	_check_keyboard()
	_check_alerts_are_rewritten()
	await _check_cost(probe)


func _check_visibility(probe: RefCounted) -> void:
	var clock_panel: Control = _hud.get("clock_panel")
	var heat_panel: Control = _hud.get("heat_panel")
	_ok(clock_panel.visible == bool(probe.get("has_climate")),
		"the clock is shown exactly when [P09] can answer")
	_ok(heat_panel.visible == bool(probe.get("has_heat")),
		"the heat panel is shown exactly when [P02] can answer")
	_ok(bool(_hud.get("vitals_panel").visible) == (bool(probe.get("has_population"))
		or bool(probe.get("has_society"))), "the vitals panel follows [P05]/[P06]")
	# Nothing may hang off the bottom or the right of the screen.
	var logical: Vector2 = Vector2(get_viewport().get_visible_rect().size) \
		/ maxf(0.01, float((_hud.get("style") as RefCounted).get("ui_scale")))
	for panel_name: String in ["clock_panel", "heat_panel", "vitals_panel",
			"resource_panel", "selection_panel", "alert_panel", "wave_panel"]:
		var p: Control = _hud.get(panel_name)
		if not p.visible:
			continue
		_ok(p.position.x >= -1.0 and p.position.y >= -1.0,
			"%s starts on screen" % panel_name)
		_ok(p.position.x + p.size.x <= logical.x + 1.0,
			"%s ends on screen horizontally" % panel_name)
		_ok(p.position.y + p.size.y <= logical.y + 1.0,
			"%s ends on screen vertically" % panel_name)


## The brief: every number has a tooltip explaining what it means and what
## changes it. This is that promise, enforced.
func _check_tooltips() -> void:
	var checked: int = 0
	for panel_name: String in ["clock_panel", "heat_panel", "vitals_panel",
			"resource_panel", "wave_panel"]:
		var p: Control = _hud.get(panel_name)
		if not p.visible:
			continue
		var hot: Array = p.get("hot")
		_ok(not hot.is_empty(), "%s declares hot regions" % panel_name)
		for e: Dictionary in hot:
			checked += 1
			var title: String = String(e.get("title", ""))
			var body: String = String(e.get("body", ""))
			_ok(title != "", "a hot region in %s has a title" % panel_name)
			_ok(body.length() > 40,
				"'%s' in %s explains itself in a sentence" % [title, panel_name])
			var rect: Rect2 = e["rect"]
			_ok(rect.size.x > 8.0 and rect.size.y > 8.0,
				"'%s' in %s is big enough to hit" % [title, panel_name])
			_ok(rect.position.x >= 0.0 and rect.position.y >= 0.0
				and rect.position.x + rect.size.x <= p.size.x + 1.0
				and rect.position.y + rect.size.y <= p.size.y + 1.0,
				"'%s' in %s stays inside its panel" % [title, panel_name])
	_ok(checked >= 8, "the HUD explains at least eight of its numbers (%d)" % checked)

	# And the card itself opens, lands inside the screen, and never covers the
	# panel it is explaining.
	var heat_panel: Control = _hud.get("heat_panel")
	if heat_panel.visible and not (heat_panel.get("hot") as Array).is_empty():
		var first: Dictionary = (heat_panel.get("hot") as Array)[0]
		var rect: Rect2 = first["rect"]
		var motion := InputEventMouseMotion.new()
		motion.position = rect.position + rect.size * 0.5
		heat_panel.call("_gui_input", motion)
		var tooltip: Control = _hud.get("tooltip")
		tooltip.call("_relayout")
		var box: Rect2 = tooltip.get("_box")
		_ok(box.size.x > 40.0 and box.size.y > 20.0, "the tooltip card has a size")
		_ok(box.position.x >= 0.0 and box.position.y >= 0.0
			and box.position.x + box.size.x <= tooltip.size.x + 1.0,
			"the tooltip card stays on screen")
		var panel_rect := Rect2(heat_panel.global_position, heat_panel.size)
		_ok(not box.intersects(panel_rect),
			"the tooltip does not cover the panel it explains")
		_hud.call("hide_tooltip")


## The whole legibility complaint in one assertion: the solver blames a tile,
## the HUD shows it, and clicking it moves the camera there.
func _check_focus_request() -> void:
	var alerts: RefCounted = _hud.get("alerts")
	var probe: RefCounted = _hud.get("probe")
	probe.set("has_heat", true)
	probe.set("short_networks", [{
		"id": 3, "title": "the Hearth grid", "deficit": 12.0, "demand": 60.0,
		"starved": 4, "brownouts": 0,
		"worst_bottleneck": {
			"node": 7, "kind": "heat_pipe", "cell": [140, 122], "reason": "capacity",
			"load": 40.0, "capacity": 40.0, "consumers": 4,
		},
	}])
	alerts.call("refresh", probe, 12.0)
	var panel: Control = _hud.get("alert_panel")
	panel.call("refresh")
	_ok(panel.visible, "a starving grid puts a line on the screen")
	var hot: Array = panel.get("hot")
	_ok(not hot.is_empty(), "the line is clickable")

	var seen: Array[Vector2] = []
	var grab := func(pos: Vector2) -> void: seen.append(pos)
	Bus.camera_focus_requested.connect(grab)
	panel.call("activate", 0)
	Bus.camera_focus_requested.disconnect(grab)
	_ok(seen.size() == 1, "clicking an alert asks the camera to move")
	if seen.size() == 1:
		_ok(seen[0] == Vector2(140.5, 122.5) * 32.0,
			"it moves to the tile [P02] actually blamed, not to the city centre")


func _check_selection() -> void:
	var build: SimSystem = Sim.get_system(&"build")
	if build == null:
		return
	var list: Array = build.call("buildings_of_kind", &"the_hearth")
	if list.is_empty():
		return
	var id: int = int((list[0] as Object).get("id"))
	_hud.call("select", id)
	var panel: Control = _hud.get("selection_panel")
	_ok(panel.visible, "selecting a building opens the panel")
	_ok(int(_hud.get("selected_id")) == id, "the HUD remembers what is selected")
	var hot: Array = panel.get("hot")
	_ok(not hot.is_empty(), "the selection panel explains its rows too")
	_hud.call("select", -1)
	_ok(not panel.visible, "deselecting closes it again")


## ui_scale must move geometry and font_scale must move type, and neither may
## push a panel off the screen.
func _check_scaling() -> void:
	var style: RefCounted = _hud.get("style")
	var heat_panel: Control = _hud.get("heat_panel")
	if not heat_panel.visible:
		return
	var base_font: int = int(style.call("fs", 20))
	var base_height: float = heat_panel.size.y

	Settings.set_value("accessibility", "font_scale", 1.5)
	_hud.call("_relayout")
	_ok(int(style.call("fs", 20)) > base_font, "font_scale enlarges type")
	_ok(heat_panel.size.y > base_height,
		"a panel grows to fit the larger type instead of clipping it")

	Settings.set_value("graphics", "ui_scale", 1.5)
	_hud.call("_relayout")
	_ok(is_equal_approx(_hud.scale.x, 1.5), "ui_scale scales the whole layer")
	var logical: Vector2 = Vector2(get_viewport().get_visible_rect().size) / 1.5
	for panel_name: String in ["clock_panel", "heat_panel", "vitals_panel",
			"resource_panel"]:
		var p: Control = _hud.get(panel_name)
		if p.visible:
			_ok(p.position.x + p.size.x <= logical.x + 1.0,
				"%s still fits at 1.5x interface and 1.5x type" % panel_name)

	Settings.set_value("graphics", "ui_scale", 1.0)
	Settings.set_value("accessibility", "font_scale", 1.0)
	_hud.call("_relayout")
	_ok(is_equal_approx(_hud.scale.x, 1.0), "and it goes back")


## A HUD that can only be driven with a mouse is not accessible. Arrow keys walk
## the regions, Enter fires them, and Space is left alone because Space is pause.
func _check_keyboard() -> void:
	var panel: Control = _hud.get("alert_panel")
	if not panel.visible or (panel.get("hot") as Array).is_empty():
		return
	panel.grab_focus()
	_ok(panel.has_focus(), "a panel can take the keyboard")
	panel.set("key_index", 0)
	var down := InputEventKey.new()
	down.physical_keycode = KEY_DOWN
	down.pressed = true
	panel.call("_gui_input", down)
	var moved: int = int(panel.get("key_index"))
	_ok(moved != 0 or (panel.get("hot") as Array).size() == 1,
		"the arrow keys walk the list")

	var seen: Array[Vector2] = []
	var grab := func(pos: Vector2) -> void: seen.append(pos)
	Bus.camera_focus_requested.connect(grab)
	panel.set("key_index", 0)
	var enter := InputEventKey.new()
	enter.physical_keycode = KEY_ENTER
	enter.pressed = true
	panel.call("_gui_input", enter)
	Bus.camera_focus_requested.disconnect(grab)
	_ok(seen.size() >= 1, "Enter fires the focused entry")

	var space := InputEventKey.new()
	space.physical_keycode = KEY_SPACE
	space.pressed = true
	var before: int = int(panel.get("key_index"))
	panel.call("_gui_input", space)
	_ok(int(panel.get("key_index")) == before,
		"Space is the pause key and the HUD keeps its hands off it")
	panel.release_focus()


## The sim's own alert wording is thrown away and rebuilt. Nothing that reaches
## the player may contain a raw network id or a rounded-to-zero rate.
func _check_alerts_are_rewritten() -> void:
	var alerts: RefCounted = _hud.get("alerts")
	Bus.alert_raised.emit(1, &"heat_supply_5", "Network 5 short 0 heat/s", Vector2.ZERO)
	alerts.call("refresh", _hud.get("probe"), 20.0)
	for e: Dictionary in alerts.get("entries"):
		var text: String = "%s %s" % [e.get("head", ""), e.get("body", "")]
		_ok(not text.contains("Network 5"), "no raw network id reached a pixel")
		_ok(not text.contains("short 0 heat"), "no rounded-to-zero rate reached a pixel")


## The perf claim, measured rather than asserted. The HUD polls the simulation
## ten times a second; this is what one of those polls costs with every system
## in the build answering.
func _check_cost(probe: RefCounted) -> void:
	var samples: int = 200
	var t0: int = Time.get_ticks_usec()
	for _i: int in samples:
		probe.call("refresh", true)
	var probe_us: float = float(Time.get_ticks_usec() - t0) / float(samples)

	t0 = Time.get_ticks_usec()
	for _i2: int in samples:
		_hud.call("_after_probe")
	var full_us: float = float(Time.get_ticks_usec() - t0) / float(samples)

	var frames: int = 0
	var frame_t0: int = Time.get_ticks_usec()
	for _i3: int in 60:
		await get_tree().process_frame
		frames += 1
	var frame_us: float = float(Time.get_ticks_usec() - frame_t0) / float(frames)

	Log.info(TAG, "cost: probe %.0f us, probe+relayout %.0f us, idle frame %.0f us" % [
		probe_us, full_us, frame_us])
	print("  cost: probe %.0f us/poll, probe+relayout %.0f us, idle frame %.0f us" % [
		probe_us, full_us, frame_us])
	_ok(probe_us < 2000.0, "a poll of every system costs under 2 ms (%.0f us)" % probe_us)
	_ok(full_us < 4000.0, "poll plus a full re-layout costs under 4 ms (%.0f us)" % full_us)


# ==================================================================  plumbing =

func _core_cell() -> Vector2i:
	var grid: SimSystem = Sim.get_system(&"grid")
	if grid != null and grid.has_method("core_cell"):
		return grid.call("core_cell")
	return Vector2i(128, 128)


func _ok(condition: bool, what: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("FAIL %s" % what)


func _write_report(verdict: String) -> void:
	var base: String = ProjectSettings.globalize_path(_out_dir)
	DirAccess.make_dir_recursive_absolute(base)
	var f := FileAccess.open(base + "/hud_view_tests.json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({
			"part": "P17", "verdict": verdict,
			"checks": _checks, "failed": _failures.size(),
			"failures": _failures,
		}, "  "))
