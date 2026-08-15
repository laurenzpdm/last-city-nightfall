extends Node
## Automated-run driver. Inert unless --harness is on the command line.
##
## This is the thing that lets a critic judge the ACTUAL BUILD instead of a
## builder's summary: it plays a scripted scenario against the real simulation
## and writes out state, per-tick metrics, the log, and real screenshots.
##
##   godot --headless -- --harness --scenario=first_night --ticks=12000 --out=artifacts/a
##   godot          -- --harness --visual --scenario=first_night --out=artifacts/vis
##
## A visual run QUITS when the last shot is written, exactly like a headless one.
## Pass --stay-open when a human wants to keep playing the scenario afterwards.

signal finished()

var active: bool = false
var visual: bool = false
var stay_open: bool = false

var _scenario: Dictionary = {}
var _out_dir: String = "res://artifacts/run"
var _ticks: int = 6000
var _seed: int = 7
var _sample_every: int = 20
var _script_by_tick: Dictionary[int, Array] = {}
var _shots_by_tick: Dictionary[int, String] = {}
var _metric_keys: PackedStringArray = PackedStringArray()
var _metric_rows: Array[PackedStringArray] = []
var _checkpoints: Dictionary = {}
var _errors: PackedStringArray = PackedStringArray()
## Tick the run ended on, and why. -1 while the city is still somebody's.
##
## THE RUN CAN END LONG BEFORE THE TICK BUDGET DOES, AND THE ARTIFACTS DID NOT
## SAY SO. `LcnPlayController` stops the clock on `Bus.game_over` for a human,
## and deliberately not here — `SimClock` is manual in a harness run, so a
## scenario replays to its last tick whatever happens, which is what keeps
## determinism cheap. What was missing is the sentence saying it happened.
##
## Measured on `economy_60min`: the council was put out of its own gate at
## t=31000, [P22] wrote the epilogue "The City Did Not Stand", and the harness
## then simulated 41,000 further ticks — four more days, four more waves
## (including one of 172 units), eight children dead of fever — and wrote a
## `final` state of a city that had been over for two thirds of the run, with
## `errors: []` and nothing anywhere in `state.json` to say which two thirds.
## Every critic reading those artifacts is reading a corpse and grading a city.
var _end_tick: int = -1
var _end_reason: String = ""


func _ready() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.has("--harness"):
		return
	active = true
	visual = args.has("--visual")
	stay_open = args.has("--stay-open")
	Log.capture = true
	Log.min_level = Log.Level.DEBUG
	for a: String in args:
		if a.begins_with("--scenario="):
			_load_scenario(a.substr(11))
		elif a.begins_with("--ticks="):
			_ticks = int(a.substr(8))
		elif a.begins_with("--seed="):
			_seed = int(a.substr(7))
		elif a.begins_with("--out="):
			_out_dir = a.substr(6)
		elif a.begins_with("--sample="):
			_sample_every = maxi(1, int(a.substr(9)))
	call_deferred("_run")


func _load_scenario(name: String) -> void:
	var path: String = name if name.begins_with("res://") else "res://tests/scenarios/%s.json" % name
	if not FileAccess.file_exists(path):
		push_error("harness: no scenario at %s" % path)
		return
	var txt: String = FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("harness: scenario %s is not valid JSON" % path)
		return
	_scenario = parsed
	_seed = int(_scenario.get("seed", _seed))
	_ticks = int(_scenario.get("ticks", _ticks))
	_sample_every = maxi(1, int(_scenario.get("sample_every", _sample_every)))
	for entry: Dictionary in _scenario.get("script", []):
		var t: int = int(entry.get("tick", 0))
		var arr: Array = _script_by_tick.get(t, [])
		arr.append(entry.get("cmd", {}))
		_script_by_tick[t] = arr
	for shot: Dictionary in _scenario.get("shots", []):
		_shots_by_tick[int(shot.get("tick", 0))] = String(shot.get("name", "shot"))


func _run() -> void:
	var t0: int = Time.get_ticks_msec()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_out_dir))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_out_dir + "/shots"))

	SimClock.set_manual(true)
	Sim.create_world(_seed)
	Bus.alert_raised.connect(_on_alert)
	Bus.game_over.connect(_on_game_over)

	var checkpoint_every: int = maxi(1, _ticks / 8)
	for t: int in range(1, _ticks + 1):
		for cmd: Dictionary in _script_by_tick.get(t, []):
			Sim.submit_command(cmd)
		SimClock.advance(1)
		if t % _sample_every == 0:
			_sample()
		if t % checkpoint_every == 0:
			_checkpoints[str(t)] = Sim.serialize()
		if visual and _shots_by_tick.has(t):
			await _shoot(_shots_by_tick[t])

	var wall_ms: int = Time.get_ticks_msec() - t0
	# A logged error IS a run error. Counting only severity>=2 Bus alerts meant
	# the gate could never fire: nothing in the build emits above severity 1.
	#
	# TOTAL, not a delta from the start of the tick loop. The delta version
	# excluded everything that happened before `_run` — which is to say the
	# entire installation of the view and the entire construction of the world.
	# Boot can now report "the build menu is not in the scene tree" as an ERROR,
	# and under the old arithmetic the harness would still have exited 0.
	var logged: int = Log.errors
	if logged > 0:
		_errors.append("%d error(s) written to the log" % logged)
	# The engine's own count of nodes that exist and are in no tree. A settled
	# run has none; anything above zero was built and then dropped — which is
	# the general shape of the orphan-CanvasLayer bug, without needing a list of
	# subsystems to keep up to date.
	var orphans: int = int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	if orphans > 0:
		_errors.append("%d orphan node(s) at the end of the run" % orphans)
	var allowed: int = int((_scenario.get("expects", {}) as Dictionary).get("max_errors", 0))
	var failed: bool = _errors.size() > allowed
	_write_outputs(wall_ms)
	var ending: String = ""
	if _end_tick >= 0:
		ending = " — THE RUN ENDED AT t%d (%s) and %d tick(s) were simulated after it" % [
			_end_tick, _end_reason, _ticks - _end_tick]
	Log.info("harness", "done in %d ms (%d ticks), %d error(s), allowed %d%s" % [
		wall_ms, _ticks, _errors.size(), allowed, ending])
	finished.emit()
	if visual and stay_open:
		Log.info("harness", "--stay-open: the window is yours")
		return
	get_tree().quit(1 if failed else 0)


func _sample() -> void:
	var m: Dictionary = Sim.collect_metrics()
	if _metric_keys.is_empty():
		var keys: Array = m.keys()
		keys.sort()
		_metric_keys = PackedStringArray(keys)
	var row := PackedStringArray()
	for k: String in _metric_keys:
		row.append(str(m.get(k, "")))
	_metric_rows.append(row)


func _shoot(name: String) -> void:
	# Two frames, not one: the first lets _process see the new sim state and
	# stream in any terrain the camera just moved onto, the second draws it.
	# Shooting after a single frame photographs the previous tick.
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	_save(get_viewport().get_texture().get_image(), name)
	Log.info("harness", "shot %s" % name)

	# A card sitting over the middle of the screen is what a player sees, so the
	# shot above keeps it. But [P22]'s event cards are opaque and undismissed for
	# the whole of an automated run — nobody is here to press Read — so EVERY
	# frame this tour produced was a photograph of a panel rather than of the
	# game. A critic judging the build by its screenshots was judging the modal.
	#
	# So take the world as well, with the modal layers hidden for the capture and
	# restored immediately. Presentation only: NarrativeCard.dismiss_current()
	# exists and would be the honest way to put a card away, but it answers a
	# dilemma by taking its first option, and a visual run that makes a decision a
	# headless run of the same scenario does not would break determinism — the
	# rule this whole harness exists to protect.
	var hidden: Array[CanvasLayer] = _hide_modal_layers()
	if hidden.is_empty():
		return
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	_save(get_viewport().get_texture().get_image(), name + ".world")
	for cl: CanvasLayer in hidden:
		cl.visible = true
	Log.info("harness", "shot %s.world — %d modal layer(s) held back" % [name, hidden.size()])


func _save(img: Image, name: String) -> void:
	if img == null:
		Log.error("harness", "shot %s: the viewport handed back no image" % name)
		return
	img.save_png(ProjectSettings.globalize_path("%s/shots/%s.png" % [_out_dir, name]))


## Everything at or above [LcnLayers.NARRATIVE] draws over the city rather than
## as part of it. Selecting by LAYER rather than by node name means a part that
## lands a new modal after this was written is covered without touching this
## file — which matters, because [P21]'s tutorial is landing in this same wave.
func _hide_modal_layers() -> Array[CanvasLayer]:
	var hidden: Array[CanvasLayer] = []
	for cl: CanvasLayer in _all_canvas_layers(get_tree().root):
		if cl.visible and cl.layer >= LcnLayers.NARRATIVE:
			cl.visible = false
			hidden.append(cl)
	return hidden


func _all_canvas_layers(from: Node) -> Array[CanvasLayer]:
	var out: Array[CanvasLayer] = []
	for child: Node in from.get_children():
		var cl := child as CanvasLayer
		if cl != null:
			out.append(cl)
		out.append_array(_all_canvas_layers(child))
	return out


func _on_alert(severity: int, key: StringName, text: String, _pos: Vector2) -> void:
	if severity >= 2:
		_errors.append("[t%d] %s: %s" % [SimClock.tick, key, text])


## The city stopped being anybody's. Recorded once — a run can raise it twice
## (the hearth falls and then the last citizen dies) and the moment that matters
## is the first one.
func _on_game_over(reason: String) -> void:
	if _end_tick >= 0:
		return
	_end_tick = SimClock.tick
	_end_reason = reason
	Log.info("harness", ("THE RUN IS OVER at t%d (%s). The clock is manual in a "
		+ "harness run, so the remaining ticks still replay — everything after "
		+ "this line is a city with nobody running it.") % [_end_tick, reason])


func _write_outputs(wall_ms: int) -> void:
	var base: String = ProjectSettings.globalize_path(_out_dir)

	var sf := FileAccess.open(base + "/state.json", FileAccess.WRITE)
	if sf != null:
		sf.store_string(JSON.stringify({
			"scenario": _scenario.get("name", "adhoc"),
			"seed": _seed, "ticks": _ticks,
			"wall_ms": wall_ms,
			# Top level, beside "errors", because it is the same kind of fact: a
			# reader deciding whether to trust `final` has to see it without
			# knowing that [P06] keeps a `verdict` block.
			"ended": {} if _end_tick < 0 else {
				"tick": _end_tick, "reason": _end_reason,
				"ticks_simulated_after": _ticks - _end_tick,
			},
			"final": Sim.serialize(),
			"checkpoints": _checkpoints,
			"errors": _errors,
		}, "  "))

	var mf := FileAccess.open(base + "/metrics.csv", FileAccess.WRITE)
	if mf != null:
		mf.store_line(",".join(_metric_keys))
		for row: PackedStringArray in _metric_rows:
			mf.store_line(",".join(row))

	var lf := FileAccess.open(base + "/log.txt", FileAccess.WRITE)
	if lf != null:
		for line: String in Log.drain():
			lf.store_line(line)
