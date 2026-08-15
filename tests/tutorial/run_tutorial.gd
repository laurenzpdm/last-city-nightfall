extends Node
## [P21] THE TUTORIAL REACHABILITY SUITE — is the guide on screen, and does the
## SIMULATION move it?
##
##   xvfb-run -a $GODOT --path . tests/tutorial/run_tutorial.tscn -- --force-ui
##
## Run as a SCENE, never with --script: the autoloads do not exist until the
## SceneTree has installed them (ARCHITECTURE.md §6.1).
## REQUIRES: --force-ui
##
## WHAT THIS SUITE IS FOR. This project has already shipped a build menu that
## passed 768 tests while being an orphan node no human could open, and a
## reachability suite that printed TESTS PASSED in the one configuration the
## gate used. So every check below is written to be answerable only by the
## running game:
##
##   * the guide is asked whether it is IN THE TREE and VISIBLE, never whether a
##     constructor returned;
##   * the "it does not advance on a timer" check runs SIXTY SECONDS of
##     simulation past the opening lesson and asserts the panel has not moved —
##     it is the one check that goes red the instant anyone replaces a condition
##     with a countdown;
##   * the "the world advances it" check submits the same build commands a
##     player's drag submits, then asserts the guide moved on;
##   * Skip is pressed as a REAL MOUSE CLICK at the button's real screen
##     coordinates when a display exists, and reported UNCHECKED when it does
##     not, because a headless pass there would only mean "a signal fired in a
##     world with no pixels".
##
## The strongest form of this suite is the one a critic can run: delete
## game/ui/tutorial/tutorial_root.gd and every check in suite 1 goes red,
## because boot then prints NOT REACHABLE YET and there is nothing to find.

const BOOT_SCENE: String = "res://game/boot.tscn"
const SETTLE: int = 4
const GROUP: StringName = &"lcn_tutorial"
const FIRST_LESSON: StringName = &"01_the_pipes_reach_or_nothing_does"
const SECOND_LESSON: StringName = &"02_the_larder_is_all_there_is"
const MEMORY_SCRATCH: String = "user://tutorial_suite_scratch.cfg"

## One minute of simulation. Long enough that any timer anyone might smuggle
## into this part would have fired several times over.
const TIMER_PROOF_TICKS: int = 1200

## The floor under the check count. A run that asks fewer questions than this
## did not get far enough to have tested anything, whatever it printed.
const MIN_CHECKS: int = 40

var _checks: int = 0
var _failures: PackedStringArray = PackedStringArray()
var _unchecked: PackedStringArray = PackedStringArray()
var _out_dir: String = "res://artifacts/p21"

var _boot: Node = null
var _tut: Node = null
var _errors_at_start: int = 0
var _opening_facts: Dictionary = {}


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out_dir = arg.substr(6)
	var watchdog := Timer.new()
	watchdog.wait_time = 240.0
	watchdog.one_shot = true
	watchdog.timeout.connect(_on_watchdog)
	add_child(watchdog)
	watchdog.start()
	call_deferred("_run")


func _on_watchdog() -> void:
	print("TESTS FAILED — the tutorial suite timed out after 240 s")
	get_tree().quit(125)


func _run() -> void:
	await _boot_a_real_session()
	if _tut == null:
		# NOT an early exit with whatever count we happened to reach. The first
		# version of this file returned here silently and printed
		# "TESTS PASSED — 0 checks" against a tree with tutorial_root.gd
		# DELETED, which is the precise disease this project has already shipped
		# three times: a suite that certifies an absence.
		_ok(false, "the tutorial put a node in group '%s' — boot says it is NOT "
			% String(GROUP) + "REACHABLE YET, so there is nothing on screen to teach anyone")
		_finish()
		return
	_suite_the_guide_is_installed_and_on_screen()
	_suite_the_content_is_usable()
	_suite_it_opens_on_the_cold()
	await _suite_time_alone_does_not_advance_it()
	await _suite_the_simulation_advances_it()
	await _suite_the_night_jumps_the_queue()
	_suite_it_does_not_cover_the_city()
	await _suite_skip_is_a_real_button()
	await _suite_a_harness_run_gets_nothing()
	_suite_memory_round_trips()
	_finish()


# ==================================================================== boot ===

func _boot_a_real_session() -> void:
	if not OS.get_cmdline_user_args().has("--force-ui") \
			and DisplayServer.get_name() == "headless":
		_ok(false, "run with --force-ui or a display: without either the view is "
			+ "never built and this suite cannot fail")
		return
	LcnLayers.force_install = true
	# A tutorial is stateful across sessions BY DESIGN, so a suite that inherits
	# the developer's own progress file would quietly test a course with four
	# lessons already crossed off. Start from a player who has never played.
	_wipe_player_memory()
	_errors_at_start = Log.errors
	var packed: PackedScene = load(BOOT_SCENE) as PackedScene
	_boot = packed.instantiate()
	add_child(_boot)
	await _settle(12)
	_tut = get_tree().get_first_node_in_group(GROUP)


func _wipe_player_memory() -> void:
	var mem := LcnTutorialMemory.new()
	mem.forget_everything()


func _settle(frames: int) -> void:
	for _i: int in frames:
		await get_tree().process_frame


## Runs the simulation the way the game does, letting the interface breathe in
## between: the guide polls four times a second and a burst of ticks with no
## frames would never give it a chance to notice anything.
func _run_ticks(n: int, frames_every: int = 100) -> void:
	var done: int = 0
	while done < n:
		var chunk: int = mini(frames_every, n - done)
		SimClock.advance(chunk)
		done += chunk
		await _settle(2)
	await _settle(SETTLE)


# ================================================================= suite 1 ===

func _suite_the_guide_is_installed_and_on_screen() -> void:
	var report: Dictionary = _boot.get(&"install_report")
	_ok(report.has(&"tutorial"), "boot's install report names the tutorial at all")
	if report.has(&"tutorial"):
		var row: Dictionary = report[&"tutorial"]
		_ok(bool(row["ok"]), "boot installed the tutorial (%s)" % String(row["why"]))
	_ok(_tut != null and _tut.is_inside_tree(),
		"the tutorial is a live node inside the scene tree")
	# THE TABLE SAYS WHICH LAYER, NOT THIS FILE. It asserted `LcnLayers.MODAL`
	# because that is where the table put the guide when this suite was written —
	# on 80, shared with [P24]'s menus, which is a slot two parts had taken and
	# nothing could police. The guide has 79 of its own now. Reading the row keeps
	# this check pointed at the contract instead of at a number that has to be
	# edited in two places whenever the allocation moves.
	_ok(_tut is CanvasLayer and int(_tut.get(&"layer")) == LcnLayers.TUTORIAL,
		"the tutorial sits on the layer the table gives it, %d (actual %d)" % [
			LcnLayers.TUTORIAL, int(_tut.get(&"layer"))])
	_ok(LcnLayers.TUTORIAL != LcnLayers.MODAL,
		"the guide does not share a canvas layer with [P24]'s modal stack")
	_ok(bool(_tut.get(&"active")), "the tutorial is running, not stood down")
	_ok(bool(_tut.call(&"is_showing")), "a lesson is on screen on the first frames")
	_ok(LcnLayers.violations(get_tree()).is_empty(),
		"adding the tutorial did not break the canvas layer table")
	_ok(Log.errors == _errors_at_start,
		"installing the tutorial logged no errors (%d new)" % (Log.errors - _errors_at_start))


# ================================================================= suite 2 ===

## Content, checked against the LIVE fact table rather than against a copy of
## it: a lesson naming a fact nobody measures can never be completed by any
## player who will ever play this game, and that must be a red suite.
func _suite_the_content_is_usable() -> void:
	var course: Object = _tut.get(&"course")
	var facts: Object = _tut.get(&"facts")
	_ok(course != null and facts != null, "the guide has a course and a fact table")
	if course == null or facts == null:
		return
	var lessons: Array = course.get(&"lessons")
	_ok(lessons.size() >= 5,
		"the course covers the four pillars and the night (%d lessons)" % lessons.size())

	var finals: int = 0
	var last_order: int = -999999
	for raw: Variant in lessons:
		var lesson: LcnTutorialLesson = raw
		var problems: PackedStringArray = lesson.validate()
		_ok(problems.is_empty(), "lesson '%s' validates (%s)" % [
			String(lesson.id), "; ".join(problems)])
		for text: String in [lesson.headline, lesson.body, lesson.action]:
			var unknown: PackedStringArray = facts.call(&"unknown_tokens", text)
			_ok(unknown.is_empty(), "lesson '%s' uses only tokens the sim answers (%s)" % [
				String(lesson.id), ", ".join(unknown)])
		_ok(lesson.order >= last_order, "lesson '%s' sorts after the one before it" % String(lesson.id))
		last_order = lesson.order
		if lesson.final_card:
			finals += 1
	_ok(finals == 1, "exactly one closing card (%d)" % finals)
	if finals == 1 and not lessons.is_empty():
		_ok((lessons[lessons.size() - 1] as LcnTutorialLesson).final_card,
			"the closing card sorts last")

	# EVERY lesson must be OPEN in a fresh city. A lesson whose condition is
	# already true on the first morning is silently retired and teaches nobody
	# anything — which is exactly how a tutorial passes a test and still fails a
	# beginner.
	for raw2: Variant in lessons:
		var l2: LcnTutorialLesson = raw2
		if l2.final_card:
			continue
		_ok(not bool(l2.call(&"is_done", facts)),
			"lesson '%s' still has something to teach in a fresh city" % String(l2.id))


# ================================================================= suite 3 ===

func _suite_it_opens_on_the_cold() -> void:
	var facts: Object = _tut.get(&"facts")
	_ok(StringName(String(_tut.call(&"current_id"))) == FIRST_LESSON,
		"the guide opens on the cold, not on a welcome (showing '%s')" % String(
			_tut.call(&"current_id")))
	# The pressure the first lesson is written against has to be REAL in the
	# world boot hands the player, or the lesson is fiction.
	var networks: float = float(facts.call(&"fact", &"networks"))
	_ok(networks >= 2.0,
		"the opening settlement really does stand on more than one heat network (%d)" % int(networks))
	_ok(float(facts.call(&"fact", &"temperature")) <= -10.0,
		"it really is lethal outside (%.1f C)" % float(facts.call(&"fact", &"temperature")))
	_ok(float(facts.call(&"fact", &"rations_made")) == 0.0,
		"nothing in the opening city makes food yet")
	_ok(float(facts.call(&"fact", &"line_fed_burners")) == 0.0,
		"nothing in the opening city is fed by a belt yet")
	_opening_facts = {"networks": networks}


# ================================================================= suite 4 ===

## THE anti-timer check. Sixty seconds of simulation go past with the player
## doing nothing about the pipes; the guide must not have moved a millimetre.
func _suite_time_alone_does_not_advance_it() -> void:
	var before: StringName = StringName(String(_tut.call(&"current_id")))
	SimClock.set_manual(true)
	await _run_ticks(TIMER_PROOF_TICKS)
	var after: StringName = StringName(String(_tut.call(&"current_id")))
	_ok(after == before,
		"%d ticks (%.0f s) of doing nothing did NOT advance the guide ('%s' -> '%s')" % [
			TIMER_PROOF_TICKS, float(TIMER_PROOF_TICKS) * SimClock.DT,
			String(before), String(after)])
	_ok(bool(_tut.call(&"is_showing")), "the guide is still on screen a minute in")
	# And the world it is complaining about really did get worse on its own.
	var facts: Object = _tut.get(&"facts")
	_ok(float(facts.call(&"fact", &"frozen")) >= 1.0,
		"the structures off the mains froze by themselves (%d frozen) — the cold is the teacher" % (
			int(facts.call(&"fact", &"frozen"))))


# ================================================================= suite 5 ===

## The other half: the guide moves the moment the SIMULATION says the lesson is
## over, through the same command path a player's click-and-drag takes.
func _suite_the_simulation_advances_it() -> void:
	var grid: SimSystem = Sim.get_system(&"grid")
	var heat: SimSystem = Sim.get_system(&"heat")
	if grid == null or heat == null:
		_ok(false, "there is a grid and a heat network to join up")
		return
	var c: Vector2i = grid.call("core_cell")
	# Exactly what the player does with B, Heat Pipe and a few drags: run the
	# mains out to the two structures boot left stranded. The dog-leg at x+13
	# is not decoration — the storage yard boot places at x+10 sits across the
	# straight route south, and a player has to go round it too.
	for run: Array in [
		[c + Vector2i(12, -1), c + Vector2i(12, -9)], [c + Vector2i(12, -9), c + Vector2i(13, -9)],
		[c + Vector2i(12, 3), c + Vector2i(13, 3)], [c + Vector2i(13, 3), c + Vector2i(13, 9)],
	]:
		Sim.submit_command({"system": &"build", "op": "place_line", "kind": "heat_pipe",
			"from": [run[0].x, run[0].y], "to": [run[1].x, run[1].y],
			"free": true, "instant": true})
	await _run_ticks(200, 20)
	var networks: int = int((heat.call("totals") as Dictionary).get("networks", 99))
	_ok(networks <= 1, "joining the mains left ONE heat network (%d)" % networks)
	if networks > 1:
		_name_the_strays(heat)
		return
	_ok(StringName(String(_tut.call(&"current_id"))) == SECOND_LESSON,
		"the guide moved on the moment the grid became one network (showing '%s')" % String(
			_tut.call(&"current_id")))
	var course: Object = _tut.get(&"course")
	_ok((course.get(&"retired") as Array).has(FIRST_LESSON),
		"the first lesson is recorded as retired by the city, not by a clock")


## Prints what is still off the mains and where. A failure that names the tile
## is a failure someone can fix; "networks 2" is a failure someone re-runs.
func _name_the_strays(heat: SimSystem) -> void:
	var build: SimSystem = Sim.get_system(&"build")
	if build == null:
		return
	for b: Object in build.call("all_buildings") as Array:
		var id: int = int(b.get("id"))
		if not bool(heat.call("has_building", id)):
			continue
		if String(b.get("kind")).begins_with("heat_pipe"):
			continue
		if int(heat.call("network_of", id)) == 1:
			continue
		print("    still stranded: %s #%d at %s on net %d" % [
			String(b.get("kind")), id, str(b.get("cell")), int(heat.call("network_of", id))])


# ================================================================= suite 6 ===

## The night does not wait for the food chain. When something is actually on the
## field the guide must be talking about that and nothing else.
func _suite_the_night_jumps_the_queue() -> void:
	var threat: SimSystem = Sim.get_system(&"threat")
	var combat: SimSystem = Sim.get_system(&"combat")
	if threat == null or combat == null:
		_skip("the night jumps the queue", "no threat or combat system in this build")
		return
	var guard: int = 0
	while int(combat.call("live_enemy_count")) <= 0 and guard < 120:
		guard += 1
		await _run_ticks(100, 100)
	var alive: int = int(combat.call("live_enemy_count"))
	if alive <= 0:
		_skip("the night jumps the queue",
			"nothing reached the city inside %d ticks of simulation" % (guard * 100))
		return
	var showing: StringName = StringName(String(_tut.call(&"current_id")))
	_ok(String(showing).find("night") >= 0 or String(showing).find("comes") >= 0,
		"with %d on the field the guide is on a night lesson, not on grain (showing '%s')" % [
			alive, String(showing)])


# ================================================================= suite 7 ===

## A guide that covers the city is worse than no guide. The reachability suite
## clicks the hearth at the centre of the screen; nothing here may sit on it,
## and nothing here except the two buttons may eat a click at all.
func _suite_it_does_not_cover_the_city() -> void:
	var vp: Vector2 = Vector2(get_viewport().get_visible_rect().size)
	var rect: Rect2 = _tut.call(&"panel_rect")
	_ok(rect.size.x > 0.0, "the guide has a real rectangle on screen (%s)" % str(rect))
	_ok(not rect.has_point(vp * 0.5),
		"the guide does not cover the middle of the screen, where the city is (%s vs %s)" % [
			str(rect), str(vp * 0.5)])
	# The strip grows with the copy. A lesson body that doubles in length pushes
	# its top edge up into the city, and on a 1280x720 window that is the middle
	# of the screen — so the budget is a gate, not a hope.
	_ok(rect.size.y <= vp.y * 0.32,
		"the guide is a strip, not a wall: %.0f px of %.0f (%.0f%%)" % [
			rect.size.y, vp.y, 100.0 * rect.size.y / maxf(1.0, vp.y)])
	var stoppers: Array[String] = []
	_collect_stoppers(_tut, stoppers)
	_ok(stoppers.size() <= 2,
		"only the buttons eat clicks; everything else lets the world through (%s)" % ", ".join(
			stoppers))


func _collect_stoppers(node: Node, out: Array[String]) -> void:
	var c := node as Control
	if c != null and c.mouse_filter == Control.MOUSE_FILTER_STOP and c.is_visible_in_tree():
		out.append("%s [%s]" % [c.name, c.get_class()])
	for child: Node in node.get_children():
		_collect_stoppers(child, out)


# ================================================================= suite 8 ===

func _suite_skip_is_a_real_button() -> void:
	var button: Button = _tut.get(&"skip_button")
	_ok(button != null and button.is_inside_tree(), "there is a Skip button in the tree")
	if button == null:
		return
	_ok(button.is_visible_in_tree() and button.size.x > 8.0,
		"the Skip button has real pixels (%s)" % str(button.get_global_rect()))

	if DisplayServer.get_name() == "headless":
		_skip("clicking Skip puts the guide away",
			"no display server: mouse hit-testing and GUI focus are not real here")
		button.pressed.emit()
	else:
		await _click(button.get_global_rect().get_center())
	await _settle(SETTLE)
	_ok(not bool(_tut.call(&"is_showing")), "the guide is gone after Skip")
	var memory: Object = _tut.get(&"memory")
	_ok(bool(memory.get(&"skipped")), "the skip is remembered in %s" % LcnTutorialMemory.PATH)
	_ok(FileAccess.file_exists(LcnTutorialMemory.PATH),
		"the skip was actually written to disk, so the next launch honours it")

	# And it comes back, so a mis-click is not permanent.
	_tut.call(&"restart")
	await _settle(SETTLE)
	_ok(bool(_tut.call(&"is_showing")), "the guide comes back when it is restarted")


func _click(at: Vector2) -> void:
	var move := InputEventMouseMotion.new()
	move.position = at
	move.global_position = at
	get_viewport().push_input(move, true)
	await _settle(2)
	for pressed: bool in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		ev.position = at
		ev.global_position = at
		get_viewport().push_input(ev, true)
		await _settle(2)
	await _settle(SETTLE)


# ================================================================= suite 9 ===

## A scripted run has no beginner in front of it, and every scenario replay and
## screenshot the art parts grade against must be identical with and without
## this part in the build.
func _suite_a_harness_run_gets_nothing() -> void:
	var was: bool = Harness.active
	Harness.active = true
	var probe: Node = (load("res://game/ui/tutorial/tutorial_root.gd") as Script).new()
	add_child(probe)
	await _settle(SETTLE)
	_ok(not bool(probe.get(&"active")), "a tutorial built during a harness run stands down")
	_ok(not bool(probe.get(&"visible")), "and draws nothing at all")
	_ok(not bool(probe.call(&"is_showing")), "and reports itself as not showing")
	probe.queue_free()
	Harness.active = was
	await _settle(2)


# ================================================================ suite 10 ===

func _suite_memory_round_trips() -> void:
	var a := LcnTutorialMemory.new(MEMORY_SCRATCH)
	a.forget_everything()
	a.remember(&"01_the_pipes_reach_or_nothing_does")
	a.remember(&"02_the_larder_is_all_there_is")
	var b := LcnTutorialMemory.new(MEMORY_SCRATCH)
	b.load_from_disk()
	_ok(b.was_taught(&"01_the_pipes_reach_or_nothing_does")
		and b.was_taught(&"02_the_larder_is_all_there_is"),
		"a lesson taught in one session is still taught in the next")
	_ok(not b.was_taught(&"05_you_cannot_click_fast_enough"),
		"and a lesson that was never reached is not")

	# A course loaded against that memory must resume, not restart.
	var course := LcnTutorialCourse.new(b)
	course.load_lessons()
	var facts: LcnTutorialFacts = _tut.get(&"facts")
	course.begin(facts)
	_ok(String(course.current_id()).find("01_") < 0 and String(course.current_id()).find("02_") < 0,
		"a returning player is not made to re-learn pipes (resumes on '%s')" % String(
			course.current_id()))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(MEMORY_SCRATCH))


# ================================================================ plumbing ===

func _ok(condition: bool, what: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("FAIL %s" % what)


func _skip(what: String, why: String) -> void:
	_unchecked.append("UNCHECKED %s — %s" % [what, why])


func _finish() -> void:
	# A suite that asked nothing has not passed anything. `_checks == 0` is the
	# shape every green-but-empty gate in this project's history had.
	if _checks < MIN_CHECKS:
		_failures.append("FAIL this suite only asked %d question(s); it is supposed to ask at "
			% _checks + "least %d, so a green here would mean nothing" % MIN_CHECKS)
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
	var f2 := FileAccess.open(base + "/tutorial.json", FileAccess.WRITE)
	if f2 != null:
		f2.store_string(JSON.stringify({
			"part": "P21", "verdict": verdict,
			"checks": _checks, "failed": _failures.size(), "unchecked": _unchecked.size(),
			"failures": _failures, "skipped": _unchecked,
			"display": DisplayServer.get_name(),
			"forced_ui": OS.get_cmdline_user_args().has("--force-ui"),
			"opening": _opening_facts,
		}, "  "))
	# A PARTIAL is not a pass: a check that could not run is the exact shape of
	# the bug this suite exists to catch.
	if not _failures.is_empty():
		get_tree().quit(mini(_failures.size(), 125))
		return
	get_tree().quit(0 if _unchecked.is_empty() else 126)
