extends Node
## [P20] The statistics screens, in a real tree, over a real world.
##
##   godot --headless --path . res://tests/stats/run_stats_view.tscn
##
## Run as a SCENE, never with `--script`: an entry script compiles before the
## autoloads exist, prints nothing and exits 0 (ARCHITECTURE.md §6.1).
##
## What it proves, in order:
##
##   1. the screen is IN THE SCENE TREE after the real boot seam runs, on the
##      layer `LcnLayers` reserves for it, and G opens it — the question nobody
##      asked while the build menu spent a phase as an orphan;
##   2. every screen lays out inside the frame at 1x, at 1.5x interface scale
##      and at 1.5x type, with no panel hanging off an edge;
##   3. the charts are drawn from real recorded history and every curve has a
##      label, a colour and a legend entry;
##   4. the bottleneck sentence names the item [P04] actually reports machines
##      stalled on — the one piece of judgement this part makes;
##   5. a real night, simulated end to end, produces an after-action report with
##      a verdict, a closest call and non-zero totals in it;
##   6. an open screen refreshes in microseconds, and the recorder's amortised
##      cost over the whole run is under its budget;
##   7. nothing in any of the above wrote a single Log.error.

const TAG: String = "stats-tests"
const BOOT_SCENE: String = "res://game/boot.tscn"
const SETTLE: int = 3
## One in-world day is 9600 ticks and night starts at 8256, so this reaches the
## dawn after the first night with room to spare.
const TICKS_TO_DAWN: int = 9900

var _checks: int = 0
var _failures: PackedStringArray = PackedStringArray()
var _out_dir: String = "res://artifacts/p20"

var _boot: Node = null
var _stats: LcnStats = null
var _errors_at_start: int = 0


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out_dir = arg.substr(6)
	var watchdog := Timer.new()
	watchdog.wait_time = 180.0
	watchdog.one_shot = true
	watchdog.timeout.connect(_on_watchdog)
	add_child(watchdog)
	watchdog.start()
	call_deferred("_run")


func _on_watchdog() -> void:
	print("TESTS FAILED — the stats view suite timed out after 180 s")
	get_tree().quit(125)


func _run() -> void:
	await _boot_a_real_session()
	if _stats == null:
		_finish()
		return
	await _suite_it_is_reachable()
	await _suite_the_night()
	_suite_the_charts_have_data()
	_suite_the_bottleneck_is_named()
	_suite_the_report_reads_as_a_story()
	await _suite_layout_survives_accessibility_scaling()
	await _suite_it_costs_nothing_to_have_open()
	_suite_it_logged_nothing()
	_finish()


# ==================================================================== boot ===

func _boot_a_real_session() -> void:
	LcnLayers.force_install = true
	SimClock.set_manual(true)
	_errors_at_start = Log.errors
	if not ResourceLoader.exists(BOOT_SCENE):
		_ok(false, "%s exists" % BOOT_SCENE)
		return
	_boot = (load(BOOT_SCENE) as PackedScene).instantiate()
	add_child(_boot)
	await _settle(8)
	_stats = get_tree().get_first_node_in_group(LcnStats.GROUP) as LcnStats


# ================================================================= suite 1 ===

## The question that was never asked: press the key — does the screen open?
func _suite_it_is_reachable() -> void:
	_ok(_stats != null, "a statistics screen exists at all")
	if _stats == null:
		return
	_ok(_stats.is_inside_tree(), "and it is IN THE SCENE TREE, not an orphan")
	_ok(_stats.layer == LcnLayers.STATS,
		"on layer %d, where the allocation table puts it (it is on %d)" % [
			LcnLayers.STATS, _stats.layer])
	_ok(_stats.layer > LcnLayers.BUILD_MENU,
		"above the build menu, because a full-screen report has to cover the palette")
	_ok(_stats.layer < LcnLayers.MODAL,
		"and below the modal band, because a tutorial gate has to cover the report")
	_ok(not _stats.follow_viewport_enabled,
		"it draws in screen space, so it can never paint a world badge over the clock")
	_ok(not _stats.is_open, "it starts closed")

	await _press(KEY_G)
	_ok(_stats.is_open, "G opens it")
	await _press(KEY_ESCAPE)
	_ok(not _stats.is_open, "Escape closes it")
	await _press(KEY_P)
	_ok(_stats.is_open, "and P opens it too, because that is what Factorio taught them")

	# Every screen has to be reachable from the keyboard, not only from a click.
	var seen: Array[String] = []
	for _i: int in _stats.screens.size():
		seen.append(_stats.screens[_stats.tab].screen_title())
		await _press(KEY_TAB)
	_ok(seen.size() == _stats.screens.size(), "Tab walks every screen")
	for title: String in ["Production", "Heat", "Society", "Night report"]:
		_ok(seen.has(title), "'%s' is one of them" % title)

	# A closed screen must be invisible to the keyboard, or it eats keys that
	# belong to the camera and the build menu.
	await _press(KEY_ESCAPE)
	_ok(not _stats.is_open, "closed again")
	var before: int = _stats.tab
	await _press(KEY_TAB)
	_ok(_stats.tab == before, "a closed screen does not swallow Tab")


# ================================================================= suite 2 ===

## A whole night, simulated, so the report is written from a night that actually
## happened rather than from a fixture that says it did.
func _suite_the_night() -> void:
	var opening: Array[Dictionary] = (load("res://game/boot.gd") as Script) \
		.call("opening_commands", _core_cell())
	for cmd: Dictionary in opening:
		Sim.submit_command(cmd)
	SimClock.advance(1)
	# Something to make and something to burn, so the production screen has a
	# line on it rather than a flat zero.
	for extra: Dictionary in _industry(_core_cell()):
		Sim.submit_command(extra)
	SimClock.advance(2)

	var t0: int = Time.get_ticks_msec()
	for _i: int in TICKS_TO_DAWN:
		SimClock.advance(1)
	Log.info(TAG, "simulated %d ticks in %d ms" % [TICKS_TO_DAWN, Time.get_ticks_msec() - t0])
	await _settle(4)

	_ok(_stats.journal.night_count() >= 1,
		"the journal saw a night (%d)" % _stats.journal.night_count())
	_ok(not _stats.reports().is_empty(),
		"and an after-action report was written (%d)" % _stats.reports().size())
	_ok(_stats.recorder.fine.sample_count() > 100,
		"the fine track filled (%d samples)" % _stats.recorder.fine.sample_count())
	_ok(_stats.recorder.run.sample_count() > 5,
		"and so did the whole-run track (%d samples)" % _stats.recorder.run.sample_count())
	_stats.set_open(true)


# ================================================================= suite 3 ===

func _suite_the_charts_have_data() -> void:
	for i: int in _stats.screens.size():
		_stats.set_tab(i)
		var s: LcnStatsScreen = _stats.screens[i]
		s.refresh()
		if s.plot == null:
			continue
		_ok(s.plot.track != null, "%s bound its chart to a track" % s.screen_title())
		_ok(not s.plot.entries.is_empty(), "%s plots at least one curve" % s.screen_title())
		for e: Dictionary in s.plot.entries:
			_ok(String(e["label"]) != "", "every curve on %s is labelled" % s.screen_title())
			_ok((e["colour"] as Color).a > 0.5, "and has a visible colour")
		_ok(s.plot.track.sample_count() > 2,
			"%s has something to draw (%d samples)" % [s.screen_title(),
				s.plot.track.sample_count()])

	# Night shading is the thing that makes the run readable at a glance.
	var heat: LcnHeatScreen = _stats.screens[LcnStats.TAB_HEAT] as LcnHeatScreen
	_stats.set_tab(LcnStats.TAB_HEAT)
	_stats.set_window(LcnStatsRecorder.T_RUN)
	heat.refresh()
	_ok(not heat.plot.bands.is_empty(),
		"the heat chart shades the night (%d band(s))" % heat.plot.bands.size())
	for band: Dictionary in heat.plot.bands:
		_ok(int(band["to_tick"]) > int(band["from_tick"]), "and every band has width")

	# Society is where the annotations live: a bend needs a cause next to it.
	var society: LcnSocietyScreen = _stats.screens[LcnStats.TAB_SOCIETY] as LcnSocietyScreen
	_stats.set_tab(LcnStats.TAB_SOCIETY)
	society.refresh()
	_ok(not society.plot.marks.is_empty() or _stats.journal.marks.is_empty(),
		"the society chart annotates what happened (%d mark(s) of %d)" % [
			society.plot.marks.size(), _stats.journal.marks.size()])


# ================================================================= suite 4 ===

## The one piece of judgement this part makes. It has to agree with [P04].
func _suite_the_bottleneck_is_named() -> void:
	var screen: LcnProductionScreen = _stats.screens[LcnStats.TAB_PRODUCTION] as LcnProductionScreen
	_stats.set_tab(LcnStats.TAB_PRODUCTION)
	_stats.set_window(LcnStatsRecorder.T_MID)
	screen.refresh()
	_ok(not screen.model.rows().is_empty(),
		"the table has rows (%d)" % screen.model.rows().size())
	_ok(screen.model.headline() != "", "and a sentence above it")
	_ok(screen.model.headline().length() > 24,
		"a sentence, not a word: '%s'" % screen.model.headline())

	var production: SimSystem = Sim.get_system(&"production")
	if production == null:
		return
	var starved: Dictionary[StringName, int] = {}
	for entry: Dictionary in production.call("stalled_machines"):
		if StringName(String(entry.get("reason", ""))) != &"missing_input":
			continue
		var item := StringName(String(entry.get("item", "")))
		if String(item) != "":
			starved[item] = starved.get(item, 0) + 1
	var worst: StringName = &""
	var worst_n: int = 0
	for item2: StringName in starved:
		if starved[item2] > worst_n:
			worst_n = starved[item2]
			worst = item2
	Log.info(TAG, "verdict: %s" % screen.model.headline())
	if worst_n > 0:
		_ok(screen.model.bottleneck() == worst,
			"the screen blames '%s', which is what %d stalled machine(s) are waiting for (it said '%s')" % [
				worst, worst_n, screen.model.bottleneck()])
		_ok(screen.model.headline().contains(LcnStatsDefs.item_label(worst)),
			"and it says the name out loud: '%s'" % screen.model.headline())
	else:
		_ok(screen.model.bottleneck() == &"",
			"nothing is starved, so nothing is blamed")

	# Every row has to carry the four numbers the table promises.
	for row: Dictionary in screen.model.rows():
		for key: String in ["made", "used", "stock", "net"]:
			_ok(row.has(key), "row '%s' carries %s" % [String(row["item"]), key])
		_ok(String(row["verdict"]) != "",
			"row '%s' says what is wrong with it" % String(row["item"]))


# ================================================================= suite 5 ===

func _suite_the_report_reads_as_a_story() -> void:
	var reports: Array[Dictionary] = _stats.reports()
	if reports.is_empty():
		_ok(false, "there is a report to read")
		return
	var r: Dictionary = reports[reports.size() - 1]
	Log.info(TAG, "night %d: %s — %s" % [int(r["night"]), String(r["verdict"]),
		String(r["closest_call"])])
	_ok(int(r["night"]) >= 1, "the report knows which night it is")
	_ok(float(r["seconds"]) > 30.0,
		"and how long it lasted (%.0f s)" % float(r["seconds"]))
	_ok(String(r["verdict"]) != "", "it reaches a verdict")
	_ok(String(r["closest_call"]).length() > 40,
		"it says what nearly went wrong, in a sentence: '%s'" % String(r["closest_call"]))
	_ok(String(r["headline"]).contains("Night"), "and its headline names the night")
	for key: String in ["produced", "consumed", "heat", "combat", "society", "city", "events"]:
		_ok(r.has(key), "the report carries its '%s' block" % key)
	var heat: Dictionary = r["heat"]
	_ok(float(heat["min_buffer"]) <= float(heat["start_buffer"]) + 0.001,
		"the buffer low point is not above where the night started")
	_ok(float(heat["deficit_seconds"]) <= float(r["seconds"]) + 1.0,
		"the grid cannot have been short for longer than the night was")
	var society: Dictionary = r["society"]
	_ok(float(society["hope_low"]) <= float(society["hope_start"]) + 0.001,
		"and hope's low point is not above where it started")


# ================================================================= suite 6 ===

## A chart that clips its own axis at 1.5x type is a chart nobody can read.
func _suite_layout_survives_accessibility_scaling() -> void:
	for pair: Array in [[1.0, 1.0], [1.35, 1.0], [1.0, 1.5], [1.35, 1.5]]:
		Settings.set_value("graphics", "ui_scale", float(pair[0]))
		Settings.set_value("accessibility", "font_scale", float(pair[1]))
		_stats._relayout()
		await _settle(2)
		var logical: Vector2 = Vector2(get_viewport().get_visible_rect().size) \
			/ maxf(0.01, float(pair[0]))
		var label: String = "%.2fx interface, %.2fx type" % [pair[0], pair[1]]
		for i: int in _stats.screens.size():
			_stats.set_tab(i)
			var s: LcnStatsScreen = _stats.screens[i]
			s.refresh()
			var name_s: String = s.screen_title()
			_ok(s.size.x > 200.0 and s.size.y > 120.0,
				"%s has room to draw at %s" % [name_s, label])
			_ok(s.global_position.x >= -1.0 and s.global_position.y >= -1.0,
				"%s starts on screen at %s" % [name_s, label])
			_ok(s.global_position.x + s.size.x <= logical.x + 1.0,
				"%s ends on screen horizontally at %s" % [name_s, label])
			_ok(s.global_position.y + s.size.y <= logical.y + 1.0,
				"%s ends on screen vertically at %s" % [name_s, label])
			if s.plot == null:
				continue
			var r: Rect2 = s.plot.plot_rect()
			_ok(r.size.x > 60.0 and r.size.y > 40.0,
				"%s keeps a usable plot area at %s (%.0fx%.0f)" % [
					name_s, label, r.size.x, r.size.y])
			_ok(r.position.x + r.size.x <= s.plot.size.x + 1.0,
				"%s's axis fits inside its own chart at %s" % [name_s, label])
	Settings.set_value("graphics", "ui_scale", 1.0)
	Settings.set_value("accessibility", "font_scale", 1.0)
	_stats._relayout()
	await _settle(2)


# ================================================================= suite 7 ===

func _suite_it_costs_nothing_to_have_open() -> void:
	var samples: int = 120
	var worst: float = 0.0
	for i: int in _stats.screens.size():
		_stats.set_tab(i)
		var s: LcnStatsScreen = _stats.screens[i]
		var t0: int = Time.get_ticks_usec()
		for _j: int in samples:
			s.invalidate()
			s.refresh()
		var us: float = float(Time.get_ticks_usec() - t0) / float(samples)
		worst = maxf(worst, us)
		Log.info(TAG, "%s refresh: %.0f us" % [s.screen_title(), us])
		_ok(us < 4000.0, "%s refreshes in under 4 ms (%.0f us)" % [s.screen_title(), us])

	# Recording is charged against the tick, not the frame, and it is the number
	# that has to be near zero because it is paid whether or not anyone looks.
	var rec_us: float = _stats.recorder.microseconds_per_tick()
	Log.info(TAG, "recorder %.1f us/tick over %d ticks, %.0f KB, worst screen %.0f us" % [
		rec_us, TICKS_TO_DAWN, float(_stats.recorder.memory_bytes()) / 1024.0, worst])
	print("  recorder %.1f us/tick  ·  history %.0f KB  ·  worst screen refresh %.0f us" % [
		rec_us, float(_stats.recorder.memory_bytes()) / 1024.0, worst])
	_ok(rec_us < LcnStatsRecorder.BUDGET_US_PER_TICK,
		"recording costs %.1f us a tick against a %.0f us budget" % [
			rec_us, LcnStatsRecorder.BUDGET_US_PER_TICK])
	_ok(_stats.recorder.memory_bytes() < 400000,
		"the whole history is %.0f KB" % (float(_stats.recorder.memory_bytes()) / 1024.0))

	# And a closed screen costs literally nothing per frame.
	_stats.set_open(false)
	var t1: int = Time.get_ticks_usec()
	for _k: int in 60:
		await get_tree().process_frame
	Log.info(TAG, "closed idle frame: %.0f us" % (float(Time.get_ticks_usec() - t1) / 60.0))


# ================================================================= suite 8 ===

func _suite_it_logged_nothing() -> void:
	_ok(Log.errors == _errors_at_start,
		"the whole run logged no errors (%d new)" % (Log.errors - _errors_at_start))


# ================================================================ plumbing ===

## A drill on a seam and a smelter to eat what it digs, so the production screen
## has a real chain on it. Placed FREE and INSTANT through the same command path
## a scenario uses.
func _industry(c: Vector2i) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var place := func(kind: String, cell: Vector2i) -> void:
		out.append({"system": &"build", "op": "place", "kind": kind,
			"cell": [cell.x, cell.y], "rot": 0, "free": true, "instant": true})
	place.call("ore_drill", c + Vector2i(6, -8))
	place.call("ore_drill", c + Vector2i(-8, -8))
	place.call("scrap_collector", c + Vector2i(9, -4))
	place.call("smelter", c + Vector2i(4, 8))
	place.call("smelter", c + Vector2i(-6, 8))
	place.call("rubble_sorter", c + Vector2i(8, 8))
	place.call("workshop", c + Vector2i(-2, 14))
	return out


func _core_cell() -> Vector2i:
	var grid: SimSystem = Sim.get_system(&"grid")
	if grid != null and grid.has_method("core_cell"):
		return grid.call("core_cell")
	return Vector2i(128, 128)


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


func _settle(frames: int) -> void:
	for _i: int in frames:
		await get_tree().process_frame


func _ok(condition: bool, what: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("FAIL %s" % what)


func _finish() -> void:
	var verdict: String = "TESTS PASSED" if _failures.is_empty() else "TESTS FAILED"
	for f: String in _failures:
		print("  %s" % f)
	print("%s — %d checks, %d failures" % [verdict, _checks, _failures.size()])
	_write_report(verdict)
	get_tree().quit(mini(_failures.size(), 125))


func _write_report(verdict: String) -> void:
	var base: String = ProjectSettings.globalize_path(_out_dir)
	DirAccess.make_dir_recursive_absolute(base)
	var payload: Dictionary = {
		"part": "P20", "verdict": verdict,
		"checks": _checks, "failed": _failures.size(), "failures": _failures,
	}
	if _stats != null:
		payload["recorder_us_per_tick"] = snappedf(
			_stats.recorder.microseconds_per_tick(), 0.01)
		payload["history_bytes"] = _stats.recorder.memory_bytes()
		payload["reports"] = _stats.reports()
		payload["journal"] = _stats.journal.marks
	var f := FileAccess.open(base + "/stats_view_tests.json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(payload, "  "))
