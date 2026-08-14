extends Node
## [C1] THE REACHABILITY SUITE — can a human actually get at any of this?
##
##   godot --headless --path . res://tests/boot/run_reachability.tscn
##
## This is the test that was missing. The build menu spent an entire phase as an
## orphan CanvasLayer: `tree.root.add_child()` from inside boot's `_ready` is
## refused by Godot, so the palette, the recipe browser, the tech tree, the
## blueprint library and the Book of Laws were never in the scene tree at all.
## 768 tests, a determinism replay and a perf gate were green throughout, because
## every one of them tested a system in isolation and not one of them asked the
## only question that matters to a player: **press the key — does the screen
## open?**
##
## So this suite runs the REAL `game/boot.tscn` in a REAL scene tree, and:
##
##   1. asserts every subsystem boot claims to have installed is_inside_tree(),
##   2. asserts boot's own report agrees, so a lying ready line is a failure,
##   3. asserts the canvas layer stack matches LcnLayers — in particular that
##      nothing drawn in WORLD space sits above the HUD, which is how world
##      badges ended up painted across the clock in three of seven screenshots,
##   4. pushes a real InputEventKey for every hotkey in the contract and asserts
##      the thing it should open reports itself open,
##   5. proves the number row still reaches sim speed with [P18]'s quickbar full,
##      which is the collision that silently disarmed time control after the
##      player's first building,
##   6. drives the Book of Laws down to Sim.submit_command and asserts [P06]
##      picked the law up — the ultimatum the society system issues is only a
##      demand if the player can answer it.
##
## Run as a SCENE, never with --script: the autoloads do not exist until the
## SceneTree has installed them (ARCHITECTURE.md §6.1).
##
## The line below is read by tools/check.sh, which passes these switches to this
## suite. Without `--force-ui` the self-installing parts decline, boot installs
## them itself in a different order, and half of what this file exists to catch
## becomes unable to fail — so the suite refuses to run at all rather than
## certify that order. See `_configuration_can_answer`.
## REQUIRES: --force-ui

const TAG: String = "reachability"
const BOOT_SCENE: String = "res://game/boot.tscn"
const SETTLE: int = 4

var _checks: int = 0
var _failures: PackedStringArray = PackedStringArray()
## Checks this configuration was not able to ask at all. NOT the same as passing:
## they downgrade the verdict to PARTIAL, which tools/check.sh refuses to read as
## green. A check that never ran is the exact shape of the bug this suite exists
## to catch, so it is never allowed to look like a pass.
var _unchecked: PackedStringArray = PackedStringArray()
var _out_dir: String = "res://artifacts/c1"

var _boot: Node = null
var _menu: Node = null
var _overlays: Node = null
var _play: Node = null
var _hud: Node = null
var _errors_at_start: int = 0


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out_dir = arg.substr(6)
	var watchdog := Timer.new()
	watchdog.wait_time = 120.0
	watchdog.one_shot = true
	watchdog.timeout.connect(_on_watchdog)
	add_child(watchdog)
	watchdog.start()
	call_deferred("_run")


func _on_watchdog() -> void:
	print("TESTS FAILED — the reachability suite timed out after 120 s")
	get_tree().quit(125)


func _run() -> void:
	await _boot_a_real_session()
	if _boot == null:
		_finish()
		return
	_suite_everything_is_in_the_tree()
	_suite_the_layer_stack()
	await _suite_every_screen_opens_on_its_key()
	await _suite_the_lenses()
	await _suite_time_control_survives_a_full_quickbar()
	await _suite_the_law_reaches_the_simulation()
	_suite_every_hud_panel_is_in_the_tree()
	await _suite_clicking_a_building_fills_the_selection_panel()
	await _suite_build_mode_reaches_the_ghost()
	_suite_the_pillars_exist()
	_finish()


# ==================================================================== boot ===

## The whole point: this is the real entry scene, not a hand-assembled fake.
func _boot_a_real_session() -> void:
	# THE CONFIGURATION GATE. Read this before changing it.
	#
	# Setting `force_install` here, in a deferred `_run`, is far too late to
	# reproduce the order a player gets. Every self-installing bootstrap
	# (`game/content/**/*_bootstrap.tres`) asks `LcnLayers.view_wanted()` while
	# Registry is still scanning, which is BEFORE boot's `_ready` — so with a
	# display, or with `--force-ui` on the command line, [P19]/[P15]/[P20]/[P22]
	# install themselves first and boot adopts them. Without either, they all
	# decline, boot installs them itself afterwards, and the whole tree comes out
	# in a different order with different owners for the number row.
	#
	# That is not a detail. In the second order the speed-key collision cannot
	# happen, so this suite printed `TESTS PASSED — 86 checks, 0 failures` for
	# exactly the invocation tools/check.sh used, while the same build with a
	# display attached failed three checks. A gate that only passes because it
	# was asked the easy question is the round-2 disease with a new address.
	#
	# So: refuse to run at all rather than certify the easy order.
	if not _configuration_can_answer():
		_ok(false, "run with --force-ui or a display: without either, the "
			+ "self-installing parts decline, boot installs them in a different "
			+ "order, and the reachable-keyboard checks cannot fail")
		return
	# One switch, read by boot and by every bootstrap, so a headless gate can
	# still build the interface it is supposed to be checking.
	LcnLayers.force_install = true
	_errors_at_start = Log.errors
	if not ResourceLoader.exists(BOOT_SCENE):
		_ok(false, "%s exists" % BOOT_SCENE)
		return
	var packed: PackedScene = load(BOOT_SCENE) as PackedScene
	_boot = packed.instantiate()
	add_child(_boot)
	await _settle(8)
	_menu = _boot.get(&"build_menu")
	_overlays = _boot.get(&"overlays")
	_play = _boot.get(&"play")
	_hud = _boot.get(&"hud")


## True when this process installs the view the way a player's does: either a
## real display server, or `--force-ui` present before Registry scans content.
func _configuration_can_answer() -> bool:
	if OS.get_cmdline_user_args().has("--force-ui"):
		return true
	return DisplayServer.get_name() != "headless"


## True when real frames exist, so mouse hit-testing and GUI focus are real.
func _has_display() -> bool:
	return DisplayServer.get_name() != "headless"


func _settle(frames: int) -> void:
	for _i: int in frames:
		await get_tree().process_frame


# ================================================================= suite 1 ===

func _suite_everything_is_in_the_tree() -> void:
	var report: Dictionary = _boot.get(&"install_report")
	_ok(not report.is_empty(), "boot published an install report")
	for key: StringName in report:
		var row: Dictionary = report[key]
		_ok(bool(row["ok"]), "%s installed (%s)" % [String(key), String(row["why"])])
	_ok(bool(_boot.call(&"view_ok")), "boot.view_ok() — every subsystem verified in-tree")

	# Belt and braces: ask the NODES, not the report that describes them.
	for pair: Array in [
		["renderer", _boot.get(&"renderer")], ["camera", _boot.get(&"camera")],
		["hud", _hud], ["overlays", _overlays], ["build_menu", _menu],
		["play shell", _play], ["input router", _boot.get(&"router")],
	]:
		var node: Node = pair[1]
		_ok(node != null and node.is_inside_tree(),
			"%s is a live node inside the scene tree" % String(pair[0]))

	_ok(Log.errors == _errors_at_start,
		"installing the view logged no errors (%d new)" % (Log.errors - _errors_at_start))


# ================================================================= suite 2 ===

## The stack that decides what covers what. A world badge must never be able to
## paint over the clock, and no header comment is allowed to be the authority.
func _suite_the_layer_stack() -> void:
	var rows: Array[Dictionary] = LcnLayers.audit(get_tree())
	var seen: Dictionary[StringName, int] = {}
	for row: Dictionary in rows:
		if bool(row["known"]):
			seen[row["key"]] = int(row["actual"])
			_ok(bool(row["ok"]), "%s sits on layer %d as the table says" % [
				String(row["key"]), int(row["expected"])])
	for key: StringName in [&"post", &"overlay_world", &"hud", &"overlay_ui", &"build_menu"]:
		_ok(seen.has(key), "the table's '%s' layer exists in the running tree" % String(key))

	_ok(LcnLayers.violations(get_tree()).is_empty(),
		"no canvas layer violates the allocation table")
	if seen.has(&"overlay_world") and seen.has(&"hud"):
		_ok(seen[&"overlay_world"] < seen[&"hud"],
			"world-space overlays (%d) draw UNDER the HUD (%d)" % [
				seen[&"overlay_world"], seen[&"hud"]])
	if seen.has(&"build_menu") and seen.has(&"overlay_ui"):
		_ok(seen[&"build_menu"] > seen[&"overlay_ui"],
			"an open panel (%d) is not stabbed through by the lens legend (%d)" % [
				seen[&"build_menu"], seen[&"overlay_ui"]])


# ================================================================= suite 3 ===

## THE test. Press the key a player would press; assert the screen opened.
func _suite_every_screen_opens_on_its_key() -> void:
	if _menu == null:
		_ok(false, "there is a build menu to open at all")
		return
	# [P18] remembers what the player left open across sessions, so a suite that
	# assumed a clean desk read a CLOSE as a failed OPEN. Clear the desk first.
	await _close_everything()
	for screen: Dictionary in LcnLayers.SCREENS:
		var id: StringName = screen["id"]
		var key: int = int(screen["key"])
		var label: String = String(screen["label"])
		await _press(key)
		_ok(_panel_open(id), "%s opens on %s" % [label, OS.get_keycode_string(key)])
		await _press(KEY_ESCAPE)
		_ok(not _panel_open(id), "%s closes on Escape" % label)

	# Screens that are not [P18] panels but owe the player the same contract.
	for extra: Dictionary in LcnLayers.EXTRA_SCREENS:
		var node: Node = get_tree().get_first_node_in_group(extra["group"])
		var owner: String = String(extra["owner"])
		var label2: String = String(extra["label"])
		if node == null:
			# Not landed yet is a fact worth stating, not a failure to invent.
			print("  (not in this build yet: %s [%s])" % [label2, owner])
			continue
		var key2: int = int(extra["key"])
		await _press(key2)
		_ok(bool(node.get(extra["flag"])),
			"%s opens on %s" % [label2, OS.get_keycode_string(key2)])
		await _press(KEY_ESCAPE)
		_ok(not bool(node.get(extra["flag"])), "%s closes on Escape" % label2)


func _close_everything() -> void:
	if _menu == null or not _menu.has_method(&"open_panels"):
		return
	for _i: int in 8:
		if (_menu.call(&"open_panels") as Array).is_empty():
			return
		await _press(KEY_ESCAPE)
	_ok(false, "Escape can close every panel it opened")


func _panel_open(id: StringName) -> bool:
	if _menu == null or not _menu.has_method(&"panel"):
		return false
	var p: Object = _menu.call(&"panel", id)
	return p != null and p.has_method(&"is_open") and bool(p.call(&"is_open"))


# ================================================================= suite 4 ===

func _suite_the_lenses() -> void:
	if _overlays == null:
		_ok(false, "the readability lenses are installed")
		return
	for key: int in LcnLayers.RESERVED_LENS:
		await _press(key)
		var mode: int = int(_overlays.get(&"mode"))
		_ok(mode > 0, "%s turns a lens on (mode %d)" % [OS.get_keycode_string(key), mode])
		await _press(key)
		_ok(int(_overlays.get(&"mode")) == 0,
			"%s turns it off again" % OS.get_keycode_string(key))
	# F1 travels a different road entirely: [P16]'s InputMap action, the camera,
	# then Bus. If that road is broken, only a key press finds out.
	await _press(KEY_F1)
	_ok(int(_overlays.get(&"mode")) > 0, "F1 reaches a lens through the camera's action map")
	await _press(KEY_F1)


# ================================================================= suite 5 ===

## [P18]'s quickbar takes 1..0 from `_input`, which runs before [P16]'s
## `_unhandled_input`, so the moment the quickbar had entries the speed keys
## stopped working — and the quickbar starts EMPTY, which is why every test and
## every screenshot run saw them working. Fill it, then press the keys.
func _suite_time_control_survives_a_full_quickbar() -> void:
	var catalog: Object = _menu.get(&"catalog") if _menu != null else null
	var filled: int = 0
	if catalog != null and catalog.has_method(&"note_used") and catalog.has_method(&"view"):
		for e: Object in (catalog.call(&"view", &"__all", "") as Array):
			catalog.call(&"note_used", e.get(&"id"))
			filled += 1
			if filled >= 10:
				break
	# `_ok(true, ...)` stood here. The whole premise of this suite is "with a FULL
	# quickbar", so an empty one does not make the speed keys safe — it makes the
	# next four assertions meaningless. Assert the premise.
	_ok(filled > 0,
		"quickbar loaded with %d entr(ies) before the speed keys are tried" % filled)

	SimClock.start()
	await _press(KEY_2)
	_ok(is_equal_approx(SimClock.speed, 2.0),
		"2 is still fast-forward with a full quickbar (speed=%.1f)" % SimClock.speed)
	await _press(KEY_3)
	_ok(is_equal_approx(SimClock.speed, 3.0), "3 is still very fast (speed=%.1f)" % SimClock.speed)
	await _press(KEY_1)
	_ok(is_equal_approx(SimClock.speed, 1.0), "1 is still normal speed (speed=%.1f)" % SimClock.speed)
	var was_running: bool = SimClock.running
	await _press(KEY_SPACE)
	_ok(SimClock.running != was_running, "Space still pauses the clock")
	await _press(KEY_SPACE)


# ================================================================= suite 6 ===

## The society system issues ultimatums that demand a law. This walks the whole
## path a player walks: open the Book, press the button, and watch [P06] pick it
## up out of the command queue.
func _suite_the_law_reaches_the_simulation() -> void:
	var society: SimSystem = Sim.get_system(&"society")
	if society == null:
		_ok(false, "[P06] society is in this build, so its ultimatums can be answered")
		return
	if _menu == null:
		_ok(false, "the Book of Laws is reachable")
		return
	var panel: Object = _menu.call(&"panel", &"laws")
	_ok(panel != null, "the Book of Laws panel exists")
	if panel == null:
		return
	var model: Object = _menu.get(&"laws")
	_ok(model != null and int(model.call(&"signed_count")) >= 0, "the Book has a model behind it")

	var candidate: StringName = _first_signable(model)
	_ok(String(candidate) != "", "the Book offers at least one law that can be signed")
	if String(candidate) == "":
		return
	# Emitted by the panel's own "Sign it" button. Same signal, same handler,
	# same command — the only thing skipped is the mouse.
	panel.emit_signal(&"sign_requested", candidate)
	SimClock.advance(1)
	await _settle(SETTLE)
	var pending: StringName = society.call(&"pending_law")
	_ok(String(pending) == String(candidate),
		"pressing Sign put '%s' in front of the room ([P06] pending='%s')" % [
			String(candidate), String(pending)])


func _first_signable(model: Object) -> StringName:
	if model == null or not model.has_method(&"chapters"):
		return &""
	for chapter: StringName in (model.call(&"chapters") as Array):
		for law: Object in (model.call(&"laws_in", chapter) as Array):
			# Status 0 is OPEN in LcnLawModel.Status.
			if int(law.get(&"status")) == 0:
				return law.get(&"id")
	return &""


# ================================================================= suite 7 ===

## The alert stack and the selection panel are the two screens with no hotkey:
## they appear because the world did something. If they are not in the tree,
## nothing announces it — which is the same failure with a quieter symptom.
func _suite_every_hud_panel_is_in_the_tree() -> void:
	if _hud == null:
		_ok(false, "there is a HUD")
		return
	for panel_name: String in ["clock_panel", "heat_panel", "vitals_panel", "wave_panel",
			"resource_panel", "alert_panel", "selection_panel", "tooltip"]:
		var p: Node = _hud.get(StringName(panel_name))
		_ok(p != null and p.is_inside_tree(), "the HUD's %s is in the tree" % panel_name)


## Clicking a building is the only read-out path with no key on it. The click is
## a real mouse event so it travels camera → selection → Bus → HUD, exactly as a
## player's does.
func _suite_clicking_a_building_fills_the_selection_panel() -> void:
	var cam: Node = _boot.get(&"camera")
	if cam == null or _hud == null or not cam.has_method(&"world_to_screen"):
		_ok(false, "there is a camera and a HUD to select with")
		return
	var grid: SimSystem = Sim.get_system(&"grid")
	if grid == null:
		_ok(false, "there is a grid to point at")
		return
	# The hearth stands two tiles up and left of the core cell; aim at its middle.
	var core: Vector2i = grid.call("core_cell")
	var world: Vector2 = (Vector2(core) + Vector2(-1.0, -1.0)) * 32.0
	var screen: Vector2 = cam.call(&"world_to_screen", world)

	# Without a display there is no GUI hit-testing and no mouse focus, so a pass
	# here would only mean "nothing was in the way in a world with no pixels".
	if not _has_display():
		_skip("clicking the hearth fills the selection panel",
			"no display server: mouse hit-testing and GUI focus are not real here")
		return

	# A card, a panel or a tooltip over the hearth makes this click a UI click,
	# and the old assertion then blamed [P17]'s selection panel for it. That is
	# how "clicking the hearth fills the selection panel (id=-1)" was read as a
	# selection bug for a whole phase when the selection path was intact and
	# [P22]'s event card was simply sitting on top of the city. Clear what can be
	# cleared, then NAME whatever is left instead of guessing.
	await _dismiss_world_blockers()
	var blocker: String = _control_blocking(screen)
	_ok(blocker == "",
		"nothing covers the hearth at %s — a click there reaches the world (%s)" % [
			str(screen), blocker if blocker != "" else "clear"])

	await _click(screen)
	_ok(int(_hud.get(&"selected_id")) >= 0,
		"clicking the hearth fills the selection panel (id=%d)" % int(_hud.get(&"selected_id")))


## Anything that legitimately covers the world and can be put away by the player
## is put away, the way the player would. A presenter that will not close is left
## standing so `_control_blocking` names it.
func _dismiss_world_blockers() -> void:
	var card: Node = get_tree().get_first_node_in_group(&"lcn_narrative_presenter")
	if card != null and card.has_method(&"dismiss_current"):
		# Answering is a command, applied at the top of the next tick, and the
		# pile can hold more than one card.
		for _i: int in 8:
			if not bool(card.call(&"dismiss_current")):
				break
			SimClock.advance(1)
			await _settle(SETTLE)
	await _close_everything()


## The top-most Control that would eat a click at `point`, or "" when the world
## is reachable there. Mouse filters are respected: only STOP actually consumes.
func _control_blocking(point: Vector2) -> String:
	var hit: Control = null
	_find_blocker(get_tree().root, point, func(c: Control) -> void: hit = c)
	if hit == null:
		return ""
	return "%s [%s] at %s covers it" % [hit.name, hit.get_class(), str(hit.get_global_rect())]


func _find_blocker(node: Node, point: Vector2, report: Callable) -> void:
	var c := node as Control
	if c != null and c.is_visible_in_tree() \
			and c.mouse_filter == Control.MOUSE_FILTER_STOP \
			and c.get_global_rect().has_point(point):
		report.call(c)
	for child: Node in node.get_children():
		_find_blocker(child, point, report)


## A palette that cannot arm the ghost is a picture of buildings.
func _suite_build_mode_reaches_the_ghost() -> void:
	if _menu == null or _play == null:
		_ok(false, "the palette and the play shell are both installed")
		return
	var catalog: Object = _menu.get(&"catalog")
	var entries: Array = catalog.call(&"view", &"__all", "") if catalog != null else []
	_ok(not entries.is_empty(), "the palette lists something to build (%d)" % entries.size())
	if entries.is_empty():
		return
	# THE automation finding, as an assertion: belts were not BuildingDefs, so
	# they never reached the build catalogue, so there was no path at all from a
	# human to the logistics pillar. Typed exactly as a player would type it.
	var belts: Array = catalog.call(&"view", &"__all", "belt")
	_ok(not belts.is_empty(),
		"typing 'belt' into the palette finds something placeable (%d)" % belts.size())

	var kind: StringName = entries[0].get(&"id")
	_menu.call(&"_on_palette_picked", kind)
	await _settle(SETTLE)
	_ok(String(_menu.get(&"armed_kind")) == String(kind), "picking '%s' arms it" % String(kind))
	_ok(bool(_play.get(&"build_mode")), "arming a building puts the play shell in build mode")
	_ok(String(_play.get(&"kind")) == String(kind), "the ghost is the building that was picked")


# ================================================================= suite 8 ===

## Every pillar the build claims to have must actually be in the world. A system
## script that stops compiling used to abort create_world half way down the list
## and leave a game with a renderer, a HUD and no simulation behind them.
func _suite_the_pillars_exist() -> void:
	_ok(Sim.alive, "the simulation world is alive")
	for name: StringName in [&"climate", &"grid", &"heat", &"logistics", &"production",
			&"citizens", &"society", &"threat", &"combat", &"research", &"build"]:
		_ok(Sim.get_system(name) != null, "the '%s' pillar is in the world" % String(name))


# ================================================================ plumbing ===

func _press(code: int) -> void:
	var down := InputEventKey.new()
	down.physical_keycode = code
	down.keycode = code
	down.pressed = true
	get_viewport().push_input(down, true)
	var up := InputEventKey.new()
	up.physical_keycode = code
	up.keycode = code
	up.pressed = false
	get_viewport().push_input(up, true)
	await _settle(SETTLE)


func _click(at: Vector2) -> void:
	for pressed: bool in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		ev.position = at
		ev.global_position = at
		get_viewport().push_input(ev, true)
		await _settle(2)
	await _settle(SETTLE)


func _ok(condition: bool, what: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("FAIL %s" % what)


## A check this configuration cannot ask. It is counted, printed and carried into
## the verdict — never silently dropped, because a suite whose check COUNT moves
## with the environment is a suite that can quietly stop testing things.
func _skip(what: String, why: String) -> void:
	_unchecked.append("UNCHECKED %s — %s" % [what, why])


func _finish() -> void:
	var verdict: String = "TESTS FAILED"
	if _failures.is_empty():
		verdict = "TESTS PASSED, PARTIAL" if not _unchecked.is_empty() else "TESTS PASSED"
	for f: String in _failures:
		print("  %s" % f)
	for u: String in _unchecked:
		print("  %s" % u)
	print("%s — %d checks, %d failures, %d unchecked" % [
		verdict, _checks, _failures.size(), _unchecked.size()])
	var base: String = ProjectSettings.globalize_path(_out_dir)
	DirAccess.make_dir_recursive_absolute(base)
	var f := FileAccess.open(base + "/reachability.json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({
			"part": "C1", "verdict": verdict,
			"checks": _checks, "failed": _failures.size(),
			"unchecked": _unchecked.size(),
			"failures": _failures,
			"skipped": _unchecked,
			"display": DisplayServer.get_name(),
			"forced_ui": OS.get_cmdline_user_args().has("--force-ui"),
			"install_report": _boot.get(&"install_report") if _boot != null else {},
			"layers": _layer_summary(),
		}, "  "))
	# Non-zero on failure, and non-zero on a PARTIAL too: this suite is a gate,
	# and a gate that cannot answer the question has not passed it.
	if not _failures.is_empty():
		get_tree().quit(mini(_failures.size(), 125))
		return
	get_tree().quit(0 if _unchecked.is_empty() else 126)


func _layer_summary() -> Dictionary:
	var out: Dictionary = {}
	for row: Dictionary in LcnLayers.audit(get_tree()):
		out[String(row["key"])] = int(row["actual"])
	return out
