extends SceneTree
## Performance gate. Reads finished headless runs, computes ticks/second, checks
## each against the floor its own scenario declares, and writes artifacts/perf.json.
##
##   Godot --headless --path . --script tools/perf_report.gd -- \
##       --runs=artifacts/perf/stress_1000,artifacts/perf/smoke \
##       [--out=artifacts/perf.json] [--budget=tools/perf_budget.json]
##
## The floor lives in the scenario (`expects.min_ticks_per_second`), not here,
## so a scenario and its performance contract can never drift apart.
## tools/perf_budget.json only scales that floor for slower machines.
##
## Exit codes: 0 within budget, 2 usage/IO error, 4 regression.

const TICK_HZ: float = 20.0

var _done: bool = false


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	quit(_execute())
	return true


func _execute() -> int:
	var run_dirs: PackedStringArray = PackedStringArray()
	var out_path: String = "artifacts/perf.json"
	var budget_path: String = "tools/perf_budget.json"
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--runs="):
			for d: String in arg.substr(7).split(",", false):
				var trimmed: String = d.strip_edges()
				if trimmed != "":
					run_dirs.append(trimmed)
		elif arg.begins_with("--out="):
			out_path = arg.substr(6)
		elif arg.begins_with("--budget="):
			budget_path = arg.substr(9)

	if run_dirs.is_empty():
		print("usage: --runs=<dir>[,<dir>...] [--out=artifacts/perf.json] [--budget=tools/perf_budget.json]")
		return 2

	var canon: Script = load("res://tests/framework/json_canon.gd") as Script
	if canon == null:
		print("perf: cannot load tests/framework/json_canon.gd")
		return 2

	var budget: Dictionary = {}
	var budget_raw: Variant = canon.call("load_file", budget_path)
	if typeof(budget_raw) == TYPE_DICTIONARY:
		budget = budget_raw
	var multiplier: float = float(budget.get("floor_multiplier", 1.0))
	var overrides: Dictionary = budget.get("overrides", {})

	var rows: Array = []
	var worst: String = "ok"
	var failures: PackedStringArray = PackedStringArray()

	for dir_path: String in run_dirs:
		var row: Dictionary = _measure(canon, dir_path, multiplier, overrides)
		rows.append(row)
		var status: String = String(row.get("status", "error"))
		if status == "error" or status == "regressed":
			worst = "regressed" if worst != "error" else worst
			if status == "error":
				worst = "error"
			failures.append("%s: %s" % [String(row.get("scenario", dir_path)), String(row.get("note", status))])

	_print_table(rows)

	var report: Dictionary = {
		"tick_hz": TICK_HZ,
		"status": worst,
		"floor_multiplier": multiplier,
		"runs": rows,
	}
	_write(out_path, report)

	if worst == "ok":
		print("PERF OK")
		return 0
	print("")
	for f: String in failures:
		print("  %s" % f)
	print("PERF REGRESSION")
	return 4


func _measure(canon: Script, dir_path: String, multiplier: float, overrides: Dictionary) -> Dictionary:
	var state_path: String = dir_path.rstrip("/") + "/state.json"
	var state: Variant = canon.call("load_file", state_path)
	if typeof(state) != TYPE_DICTIONARY:
		return {"run": dir_path, "scenario": dir_path.get_file(), "status": "error",
			"note": "no readable state.json at %s — did the run crash?" % state_path}

	var s: Dictionary = state
	var scenario: String = String(s.get("scenario", dir_path.get_file()))
	var ticks: int = int(s.get("ticks", 0))
	var wall_ms: int = int(s.get("wall_ms", 0))
	var errors: Array = s.get("errors", [])
	var tps: float = 0.0
	if wall_ms > 0:
		tps = float(ticks) * 1000.0 / float(wall_ms)
	elif ticks > 0:
		# Faster than the millisecond clock can see. Report the floor as met
		# rather than dividing by zero.
		tps = float(ticks) * 1000.0

	var expects: Dictionary = _expects_of(canon, scenario)
	var floor_tps: float = float(overrides.get(scenario, expects.get("min_ticks_per_second", 100.0))) * multiplier
	var target_tps: float = float(expects.get("target_ticks_per_second", 0.0)) * multiplier
	var max_errors: int = int(expects.get("max_errors", 0))
	# A perf scenario has to build the city it is named for. Measuring 46 ticks/s
	# on a third of the advertised entities is not a performance number, it is a
	# fiction with a decimal point.
	var min_buildings: int = int(expects.get("min_buildings", 0))

	var metrics: Dictionary = _read_metrics(dir_path)

	var status: String = "ok"
	var note: String = ""
	var built: int = int(float(metrics.get("final", {}).get("build.buildings_total", 0)))
	if ticks <= 0:
		status = "error"
		note = "the run reported zero ticks"
	elif min_buildings > 0 and built < min_buildings:
		status = "regressed"
		note = "only %d buildings on the map, %d required — the workload is not what the scenario claims" % [
			built, min_buildings]
	elif errors.size() > max_errors:
		status = "regressed"
		note = "%d run error(s), %d allowed: %s" % [errors.size(), max_errors, str(errors[0])]
	elif tps < floor_tps:
		status = "regressed"
		note = "%.0f ticks/s is below the floor of %.0f" % [tps, floor_tps]
	elif target_tps > 0.0 and tps < target_tps:
		status = "slow"
		note = "%.0f ticks/s is under the %.0f target but above the floor" % [tps, target_tps]

	return {
		"run": dir_path,
		"scenario": scenario,
		"ticks": ticks,
		"wall_ms": wall_ms,
		"ticks_per_second": snappedf(tps, 0.1),
		"realtime_factor": snappedf(tps / TICK_HZ, 0.01),
		"ms_per_tick": snappedf(float(wall_ms) / maxf(1.0, float(ticks)), 0.0001),
		"floor_ticks_per_second": snappedf(floor_tps, 0.1),
		"target_ticks_per_second": snappedf(target_tps, 0.1),
		"errors": errors.size(),
		"buildings": built,
		"min_buildings": min_buildings,
		"metric_rows": int(metrics.get("rows", 0)),
		"final_metrics": metrics.get("final", {}),
		"status": status,
		"note": note,
	}


func _expects_of(canon: Script, scenario: String) -> Dictionary:
	var sc: Variant = canon.call("load_file", "res://tests/scenarios/%s.json" % scenario)
	if typeof(sc) != TYPE_DICTIONARY:
		return {}
	var expects: Variant = (sc as Dictionary).get("expects", {})
	return expects if typeof(expects) == TYPE_DICTIONARY else {}


## Row count and the last sampled row of metrics.csv, so perf.json also records
## what the world actually contained when it was that slow.
func _read_metrics(dir_path: String) -> Dictionary:
	var path: String = dir_path.rstrip("/") + "/metrics.csv"
	var full: String = path if path.begins_with("res://") or path.is_absolute_path() else "res://" + path
	var f: FileAccess = FileAccess.open(full, FileAccess.READ)
	if f == null:
		return {"rows": 0, "final": {}}
	var header: PackedStringArray = PackedStringArray()
	var last: PackedStringArray = PackedStringArray()
	var rows: int = 0
	while not f.eof_reached():
		var line: String = f.get_line()
		if line.strip_edges() == "":
			continue
		if header.is_empty():
			header = line.split(",")
			continue
		last = line.split(",")
		rows += 1
	var final: Dictionary = {}
	for i: int in range(mini(header.size(), last.size())):
		final[header[i]] = _as_number(last[i])
	return {"rows": rows, "final": final}


func _as_number(text: String) -> Variant:
	if text.is_valid_int():
		return int(text)
	if text.is_valid_float():
		return float(text)
	return text


func _print_table(rows: Array) -> void:
	print("")
	print(" %-16s %8s %9s %10s %9s %8s  %s" % ["scenario", "ticks", "wall ms", "ticks/s", "x realtime", "floor", "status"])
	for raw: Variant in rows:
		var r: Dictionary = raw
		print(" %-16s %8d %9d %10.0f %9.0fx %8.0f  %s%s" % [
			String(r.get("scenario", "?")),
			int(r.get("ticks", 0)),
			int(r.get("wall_ms", 0)),
			float(r.get("ticks_per_second", 0.0)),
			float(r.get("realtime_factor", 0.0)),
			float(r.get("floor_ticks_per_second", 0.0)),
			String(r.get("status", "?")),
			"" if String(r.get("note", "")) == "" else "  — " + String(r.get("note", "")),
		])
	print("")


func _write(out_path: String, report: Dictionary) -> void:
	var full: String = out_path if out_path.begins_with("res://") or out_path.is_absolute_path() else "res://" + out_path
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(full.get_base_dir()))
	var f: FileAccess = FileAccess.open(full, FileAccess.WRITE)
	if f == null:
		print("perf: cannot write %s" % full)
		return
	f.store_string(JSON.stringify(report, "  ", true, true))
	f.close()
	print("perf: wrote %s" % out_path)
