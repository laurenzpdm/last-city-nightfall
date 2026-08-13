extends SceneTree
## Per-system tick profiler. Plays a scenario exactly like the harness does and
## reports where the 50 ms tick budget actually goes, system by system.
##
##   Godot --headless --path . --script tools/profile_run.gd -- \
##       --scenario=stress_1000 [--ticks=3000] [--seed=4242] [--warmup=300] \
##       [--out=artifacts/profile/stress_1000.json]
##
## `--warmup` discards the first N ticks before the counters are zeroed, so the
## number is the steady state and not the construction queue draining.
##
## This is a MEASURING tool: it never asserts, never gates. The gate is
## tools/perf.sh. What this answers is "which system, and how many ms", which is
## the question nobody in this build could answer before it existed.

var _done: bool = false


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	quit(_execute())
	return true


func _execute() -> int:
	var scenario_name: String = "stress_1000"
	var out_path: String = ""
	var ticks_override: int = 0
	var seed_override: int = 0
	var has_seed: bool = false
	var warmup: int = -1
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--scenario="):
			scenario_name = arg.substr(11)
		elif arg.begins_with("--ticks="):
			ticks_override = int(arg.substr(8))
		elif arg.begins_with("--seed="):
			seed_override = int(arg.substr(7))
			has_seed = true
		elif arg.begins_with("--warmup="):
			warmup = int(arg.substr(9))
		elif arg.begins_with("--out="):
			out_path = arg.substr(6)

	var path: String = scenario_name if scenario_name.begins_with("res://") \
		else "res://tests/scenarios/%s.json" % scenario_name
	if not FileAccess.file_exists(path):
		print("profile: no scenario at %s" % path)
		return 2
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		print("profile: %s is not valid JSON" % path)
		return 2
	var scenario: Dictionary = parsed

	var world_seed: int = seed_override if has_seed else int(scenario.get("seed", 7))
	var ticks: int = ticks_override if ticks_override > 0 else int(scenario.get("ticks", 3000))
	if warmup < 0:
		warmup = mini(ticks / 4, _last_script_tick(scenario) + 20)

	var script_by_tick: Dictionary[int, Array] = {}
	for entry: Dictionary in scenario.get("script", []):
		var t: int = int(entry.get("tick", 0))
		var arr: Array = script_by_tick.get(t, [])
		arr.append(entry.get("cmd", {}))
		script_by_tick[t] = arr

	# Autoloads are children of the root under a custom main loop. Reached by
	# node, not by global identifier, because a --script file compiles before the
	# autoload globals are registered.
	var sim: Node = root.get_node_or_null(^"Sim")
	var clock: Node = root.get_node_or_null(^"SimClock")
	var log_node: Node = root.get_node_or_null(^"Log")
	if sim == null or clock == null:
		print("profile: autoloads are missing — is this the right project?")
		return 2
	if log_node != null:
		log_node.set("min_level", 2)  # WARN and up; the profile is the output here

	clock.call("set_manual", true)
	sim.set("profile_enabled", true)
	sim.call("create_world", world_seed)

	var wall0: int = Time.get_ticks_usec()
	var warm_wall_us: int = 0
	for t: int in range(1, ticks + 1):
		for cmd: Dictionary in script_by_tick.get(t, []):
			sim.call("submit_command", cmd)
		clock.call("advance", 1)
		if t == warmup:
			warm_wall_us = Time.get_ticks_usec() - wall0
			sim.call("profile_reset")
	var wall_us: int = Time.get_ticks_usec() - wall0
	var measured_us: int = wall_us - warm_wall_us
	var measured_ticks: int = maxi(1, ticks - warmup)

	var r_ticks: int = measured_ticks
	var report: Dictionary = sim.call("profile_report")
	report["scenario"] = String(scenario.get("name", scenario_name))
	report["seed"] = world_seed
	report["total_ticks"] = ticks
	report["warmup_ticks"] = warmup
	report["wall_ms_per_tick"] = snappedf(float(measured_us) / float(measured_ticks) / 1000.0, 0.0001)
	report["ticks_per_second"] = snappedf(float(measured_ticks) * 1.0e6 / float(maxi(1, measured_us)), 0.1)
	report["buildings"] = _building_count(sim)

	var hf: Script = load("res://game/sim/heat/heat_flow.gd")
	if hf != null:
		var prof: Dictionary = hf.get("PROF")
		var pk: Array = prof.keys(); pk.sort()
		print("")
		print("── heat flow phases (us total, %d measured ticks) ──" % int(r_ticks))
		for k: String in pk:
			print("   %-18s %12d" % [k, int(prof[k])])
	_print(report)
	if out_path == "":
		out_path = "artifacts/profile/%s.json" % String(report["scenario"])
	_write(out_path, report)
	return 0


func _last_script_tick(scenario: Dictionary) -> int:
	var last: int = 0
	for entry: Dictionary in scenario.get("script", []):
		last = maxi(last, int(entry.get("tick", 0)))
	return last


func _building_count(sim: Node) -> int:
	var build: Object = sim.call("get_system", &"build")
	if build == null:
		return 0
	var m: Dictionary = build.call("metrics")
	return int(m.get("buildings_total", 0))


func _print(r: Dictionary) -> void:
	print("")
	print("── profile: %s ── %d ticks measured (%d warm-up), %d buildings" % [
		String(r.get("scenario", "?")), int(r.get("ticks", 0)),
		int(r.get("warmup_ticks", 0)), int(r.get("buildings", 0))])
	print(" %-14s %6s %10s %10s %8s   %s" % ["system", "order", "ms/tick", "peak ms", "share", ""])
	for raw: Variant in r.get("systems", []):
		var row: Dictionary = raw
		var share: float = float(row.get("share", 0.0))
		var bar: String = "█".repeat(int(round(share * 40.0)))
		print(" %-14s %6d %10.3f %10.3f %7.1f%%   %s" % [
			String(row.get("system", "?")), int(row.get("order", 0)),
			float(row.get("ms_per_tick", 0.0)), float(row.get("peak_ms", 0.0)),
			share * 100.0, bar])
	print("")
	print(" %-14s %10.3f ms/tick   (systems %.3f + commands %.3f)" % [
		"SIM TOTAL", float(r.get("sim_ms_per_tick", 0.0)),
		float(r.get("systems_ms_per_tick", 0.0)),
		float(r.get("commands_ms_per_tick", 0.0))])
	print(" %-14s %10.3f ms/tick   → %.1f ticks/s   budget %.1f ms" % [
		"WALL", float(r.get("wall_ms_per_tick", 0.0)),
		float(r.get("ticks_per_second", 0.0)), float(r.get("budget_ms", 50.0))])
	print("")


func _write(out_path: String, report: Dictionary) -> void:
	var full: String = out_path if out_path.begins_with("res://") or out_path.is_absolute_path() \
		else "res://" + out_path
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(full.get_base_dir()))
	var f: FileAccess = FileAccess.open(full, FileAccess.WRITE)
	if f == null:
		print("profile: cannot write %s" % full)
		return
	f.store_string(JSON.stringify(report, "  ", true, true))
	f.close()
	print("profile: wrote %s" % out_path)
