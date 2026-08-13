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
	var errors_at_start: int = Log.errors

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
	var logged: int = Log.errors - errors_at_start
	if logged > 0:
		_errors.append("%d error(s) written to the log" % logged)
	var allowed: int = int((_scenario.get("expects", {}) as Dictionary).get("max_errors", 0))
	var failed: bool = _errors.size() > allowed
	_write_outputs(wall_ms)
	Log.info("harness", "done in %d ms (%d ticks), %d error(s), allowed %d" % [
		wall_ms, _ticks, _errors.size(), allowed])
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
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	var path: String = "%s/shots/%s.png" % [_out_dir, name]
	img.save_png(ProjectSettings.globalize_path(path))
	Log.info("harness", "shot %s" % name)


func _on_alert(severity: int, key: StringName, text: String, _pos: Vector2) -> void:
	if severity >= 2:
		_errors.append("[t%d] %s: %s" % [SimClock.tick, key, text])


func _write_outputs(wall_ms: int) -> void:
	var base: String = ProjectSettings.globalize_path(_out_dir)

	var sf := FileAccess.open(base + "/state.json", FileAccess.WRITE)
	if sf != null:
		sf.store_string(JSON.stringify({
			"scenario": _scenario.get("name", "adhoc"),
			"seed": _seed, "ticks": _ticks,
			"wall_ms": wall_ms,
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
