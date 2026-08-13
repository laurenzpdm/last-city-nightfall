extends SceneTree
## Plays a scenario and writes down the things state.json cannot prove.
##
##   Godot --headless --path . --script tools/gate_probe.gd -- \
##       --scenario=first_night [--ticks=N] [--seed=N] [--out=artifacts/gate/first_night]
##
## The harness writes the world's final shape. This writes the world's BEHAVIOUR:
##
##   alerts   every Bus.alert_raised with its tick and its exact words, so an
##            alert that promises "Timber runs out in 20 seconds" can be held
##            against the timber series that went 715 -> 495 -> flat.
##   signals  wave_started / wave_cleared / enemy_spawned / enemy_killed /
##            turret_fired / item_produced, so "43 shots and 19 kills across
##            three days" and "wave 2 never ended" become assertions instead of
##            observations a critic has to make by hand.
##   rosters  who is alive, with hit points, sixty times over the run, so an
##            enemy standing at full HP for 7000 ticks is detectable.
##   series   Sim.collect_metrics() plus per-item stock, so a band on a named
##            metric has something to bite on.
##
## It asserts nothing. tools/assert_run.py grades it against
## tests/gate/expectations.json. A probe that also judged would be a probe
## nobody could re-point at a new question.
##
## Wall-clock and Dictionary order are used freely in here — this is a tool, it
## never writes to sim state, and the determinism gate is tools/determinism.sh.

const ROSTER_SNAPSHOTS: int = 60

var _alerts: Array[Dictionary] = []
var _sig_wave_started: Array[Dictionary] = []
var _sig_wave_cleared: Array[Dictionary] = []
var _sig_wave_incoming: Array[Dictionary] = []
var _sig_game_over: Array[Dictionary] = []
var _sig_law: Array[Dictionary] = []
var _counts: Dictionary[String, int] = {}
var _rosters: Array[Dictionary] = []
var _series: Dictionary[String, Array] = {}
var _clock: Node = null
var _done: bool = false


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	quit(_execute())
	return true


func _execute() -> int:
	var scenario_name: String = ""
	var out_dir: String = ""
	var ticks_override: int = 0
	var seed_override: int = 0
	var has_seed: bool = false
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--scenario="):
			scenario_name = arg.substr(11)
		elif arg.begins_with("--ticks="):
			ticks_override = int(arg.substr(8))
		elif arg.begins_with("--seed="):
			seed_override = int(arg.substr(7))
			has_seed = true
		elif arg.begins_with("--out="):
			out_dir = arg.substr(6)
	if scenario_name == "":
		print("gate_probe: --scenario= is required")
		return 2

	var path: String = scenario_name if scenario_name.begins_with("res://") \
		else "res://tests/scenarios/%s.json" % scenario_name
	if not FileAccess.file_exists(path):
		print("gate_probe: no scenario at %s" % path)
		return 2
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		print("gate_probe: %s is not valid JSON" % path)
		return 2
	var scenario: Dictionary = parsed

	var world_seed: int = seed_override if has_seed else int(scenario.get("seed", 7))
	var ticks: int = ticks_override if ticks_override > 0 else int(scenario.get("ticks", 3000))
	var sample_every: int = maxi(1, int(scenario.get("sample_every", 20)))
	if out_dir == "":
		out_dir = "artifacts/gate/%s" % String(scenario.get("name", scenario_name))

	var script_by_tick: Dictionary[int, Array] = {}
	for entry: Dictionary in scenario.get("script", []):
		var t: int = int(entry.get("tick", 0))
		var arr: Array = script_by_tick.get(t, [])
		arr.append(entry.get("cmd", {}))
		script_by_tick[t] = arr

	# Autoloads are children of the root under a custom main loop, and a --script
	# file compiles before the autoload globals exist, so they are fetched by node.
	var sim: Node = root.get_node_or_null(^"Sim")
	var bus: Node = root.get_node_or_null(^"Bus")
	var log_node: Node = root.get_node_or_null(^"Log")
	_clock = root.get_node_or_null(^"SimClock")
	if sim == null or bus == null or _clock == null:
		print("gate_probe: autoloads are missing — is this the right project?")
		return 2
	if log_node != null:
		log_node.set("min_level", 2)

	_connect(bus)
	_clock.call("set_manual", true)
	sim.call("create_world", world_seed)

	var roster_every: int = maxi(sample_every, ticks / ROSTER_SNAPSHOTS)
	var t0: int = Time.get_ticks_msec()
	for t: int in range(1, ticks + 1):
		for cmd: Dictionary in script_by_tick.get(t, []):
			sim.call("submit_command", cmd)
		_clock.call("advance", 1)
		if t % sample_every == 0:
			_sample(sim, t)
		if t % roster_every == 0 or t == ticks:
			_roster(sim, t)
	var wall_ms: int = Time.get_ticks_msec() - t0

	var payload: Dictionary = {
		"scenario": String(scenario.get("name", scenario_name)),
		"seed": world_seed,
		"ticks": ticks,
		"sample_every": sample_every,
		"wall_ms": wall_ms,
		"tick_hz": _clock.get("TICK_HZ"),
		"alerts": _alerts,
		"rosters": _rosters,
		"series": _series,
		"signals": {
			"wave_started": _sig_wave_started,
			"wave_cleared": _sig_wave_cleared,
			"wave_incoming": _sig_wave_incoming,
			"game_over": _sig_game_over,
			"law_enacted": _sig_law,
			"enemy_spawned_count": _counts.get("enemy_spawned", 0),
			"enemy_killed_count": _counts.get("enemy_killed", 0),
			"turret_fired_count": _counts.get("turret_fired", 0),
			"item_produced_count": _counts.get("item_produced", 0),
			"building_placed_count": _counts.get("building_placed", 0),
			"citizen_died_count": _counts.get("citizen_died", 0),
			"machine_stalled_count": _counts.get("machine_stalled", 0),
			"research_completed_count": _counts.get("research_completed", 0),
			"alert_count": _alerts.size(),
		},
		"log_errors": int(log_node.get("errors")) if log_node != null else -1,
		"log_warnings": int(log_node.get("warnings")) if log_node != null else -1,
	}
	_write(out_dir, payload)
	print("gate_probe: %s — %d ticks in %d ms, %d alerts, %d roster snapshots, %d series" % [
		String(payload["scenario"]), ticks, wall_ms, _alerts.size(), _rosters.size(), _series.size()])
	return 0


func _connect(bus: Node) -> void:
	bus.connect("alert_raised", func(severity: int, key: StringName, text: String, _pos: Vector2) -> void:
		_alerts.append({"tick": _tick(), "severity": severity, "key": String(key), "text": text}))
	bus.connect("wave_started", func(wave: int, strength: float) -> void:
		_sig_wave_started.append({"tick": _tick(), "wave": wave, "strength": strength}))
	bus.connect("wave_cleared", func(wave: int) -> void:
		_sig_wave_cleared.append({"tick": _tick(), "wave": wave}))
	bus.connect("wave_incoming", func(wave: int, seconds_until: float) -> void:
		_sig_wave_incoming.append({"tick": _tick(), "wave": wave, "in": seconds_until}))
	bus.connect("game_over", func(reason: String) -> void:
		_sig_game_over.append({"tick": _tick(), "reason": reason}))
	bus.connect("law_enacted", func(id: StringName) -> void:
		_sig_law.append({"tick": _tick(), "id": String(id)}))
	bus.connect("enemy_spawned", func(_a: int, _b: StringName, _c: Vector2) -> void: _bump("enemy_spawned"))
	bus.connect("enemy_killed", func(_a: int, _b: Vector2) -> void: _bump("enemy_killed"))
	bus.connect("turret_fired", func(_a: int, _b: Vector2, _c: Vector2) -> void: _bump("turret_fired"))
	bus.connect("item_produced", func(_a: StringName, _b: int) -> void: _bump("item_produced"))
	bus.connect("building_placed", func(_a: int, _b: StringName, _c: Vector2i) -> void: _bump("building_placed"))
	bus.connect("citizen_died", func(_a: int, _b: StringName) -> void: _bump("citizen_died"))
	bus.connect("machine_stalled", func(_a: int, _b: StringName) -> void: _bump("machine_stalled"))
	bus.connect("research_completed", func(_a: StringName) -> void: _bump("research_completed"))


func _bump(key: String) -> void:
	_counts[key] = _counts.get(key, 0) + 1


func _tick() -> int:
	return int(_clock.get("tick"))


func _sample(sim: Node, t: int) -> void:
	var m: Dictionary = sim.call("collect_metrics")
	for k: String in m:
		var v: Variant = m[k]
		if typeof(v) == TYPE_BOOL:
			v = 1 if v else 0
		_push(k, t, v)
	# Per-item stock is the series an ATTENTION panel is actually talking about
	# when it says a resource is about to run out. It is nowhere in metrics.csv.
	var build: Object = sim.call("get_system", &"build")
	if build == null:
		return
	var stock: Object = build.get("stock")
	if stock == null:
		return
	var dumped: Dictionary = stock.call("to_dict")
	# to_dict() wraps the counts in {"provider": …, "amounts": {…}}. Recording
	# the wrapper would have produced two useless series called stock.amounts and
	# stock.provider, and every depletion assertion would have quietly had
	# nothing to bite on.
	var amounts: Dictionary = dumped.get("amounts", dumped)
	for item: Variant in amounts:
		_push("stock.%s" % String(item), t, amounts[item])


func _push(key: String, t: int, value: Variant) -> void:
	var arr: Array = _series.get(key, [])
	arr.append([t, value])
	_series[key] = arr


func _roster(sim: Node, t: int) -> void:
	var combat: Object = sim.call("get_system", &"combat")
	if combat == null:
		return
	var state: Dictionary = combat.call("serialize")
	var enemies: Array[Dictionary] = []
	for raw: Variant in state.get("enemies", []):
		var e: Dictionary = raw
		enemies.append({
			"id": int(e.get("id", 0)),
			"kind": String(e.get("kind", "?")),
			"hp": float(e.get("hp", 0.0)),
			"born": int(e.get("born", 0)),
		})
	_rosters.append({"tick": t, "enemies": enemies})


func _write(out_dir: String, payload: Dictionary) -> void:
	var dir: String = out_dir if out_dir.begins_with("res://") else "res://" + out_dir
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var f: FileAccess = FileAccess.open(dir + "/gate.json", FileAccess.WRITE)
	if f == null:
		print("gate_probe: cannot write %s/gate.json" % dir)
		return
	f.store_string(JSON.stringify(payload, "", true, true))
	f.close()
