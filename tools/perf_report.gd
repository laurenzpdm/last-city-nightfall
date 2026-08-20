extends SceneTree
## Performance gate. Reads finished headless runs, computes ticks/second, checks
## each against the floor its own scenario declares, and writes artifacts/perf.json.
##
##   Godot --headless --path . --script tools/perf_report.gd -- \
##       --runs=artifacts/perf/stress_1000/r1,artifacts/perf/stress_1000/r2,... \
##       [--out=artifacts/perf.json] [--budget=tools/perf_budget.json]
##
## The floor lives in the scenario (`expects.min_ticks_per_second`), not here,
## so a scenario and its performance contract can never drift apart.
## tools/perf_budget.json only scales that floor for slower machines.
##
## ── ONE READING IS NOT A MEASUREMENT ────────────────────────────────────────
##
## Six readings of the same test on the same macOS runner with no code change:
## 9410 · 9913 · 10442 · 11427 · 12177 · 16215 µs against a floor of 9000 — a
## 72 % spread, wider than the gap to the floor. Four gate stages flapped on it,
## and a gate that goes red for reasons unrelated to the code gets ignored
## exactly like one that is never red.
##
## So this stage takes several readings per scenario (tools/perf.sh --repeat)
## and judges the MEDIAN, never a single sample, and it always prints every
## reading and the spread. The floors are untouched — the statistic changed,
## not the bar. Three verdicts a reader can act on:
##
##   REGRESSED  the median is under the floor. The build is slow. Fix the build.
##   noisy      the median holds the floor but at least one reading fell under
##              it. That is the box, not the code, and the spread says so.
##   ok         every reading held.
##
## A scenario measured only once is reported as `1 reading` so nobody mistakes
## a coin flip for a trend.
##
## Exit codes: 0 within budget (noise included), 2 usage/IO error, 4 regression.

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
	for dir_path: String in run_dirs:
		rows.append(_measure(canon, dir_path, multiplier, overrides))

	# Readings of the same scenario are one measurement, not several verdicts.
	var order: PackedStringArray = PackedStringArray()
	var by_scenario: Dictionary = {}
	for raw: Variant in rows:
		var r: Dictionary = raw
		var name: String = String(r.get("scenario", "?"))
		if not by_scenario.has(name):
			by_scenario[name] = []
			order.append(name)
		(by_scenario[name] as Array).append(r)

	var groups: Array = []
	var worst: String = "ok"
	var failures: PackedStringArray = PackedStringArray()
	var noisy: PackedStringArray = PackedStringArray()
	for name: String in order:
		var g: Dictionary = _summarise(name, by_scenario[name])
		groups.append(g)
		var status: String = String(g.get("status", "error"))
		if status == "error":
			worst = "error"
			failures.append("%s: %s" % [name, String(g.get("note", status))])
		elif status == "regressed":
			if worst != "error":
				worst = "regressed"
			failures.append("%s: %s" % [name, String(g.get("note", status))])
		elif status == "noisy":
			noisy.append("%s: %s" % [name, String(g.get("note", status))])

	_print_table(groups)

	var report: Dictionary = {
		"tick_hz": TICK_HZ,
		"status": worst,
		"statistic": "median of the readings; a single reading is reported as such",
		"floor_multiplier": multiplier,
		"scenarios": groups,
		"runs": rows,
	}
	_write(out_path, report)

	if not noisy.is_empty():
		print("")
		print(" NOISE, not a regression — the median held the floor and a reading did not:")
		for n: String in noisy:
			print("   %s" % n)
	if worst == "ok":
		print("PERF OK")
		return 0
	print("")
	for f: String in failures:
		print("  %s" % f)
	print("PERF REGRESSION")
	return 4


## Several readings of one scenario, collapsed into the distribution and the one
## verdict that follows from it.
func _summarise(scenario: String, raw_runs: Array) -> Dictionary:
	var samples: Array[float] = []
	var floor_tps: float = 0.0
	var target_tps: float = 0.0
	var ticks: int = 0
	var hard: String = ""
	var workload: String = ""
	for raw: Variant in raw_runs:
		var r: Dictionary = raw
		floor_tps = maxf(floor_tps, float(r.get("floor_ticks_per_second", 0.0)))
		target_tps = maxf(target_tps, float(r.get("target_ticks_per_second", 0.0)))
		ticks = maxi(ticks, int(r.get("ticks", 0)))
		match String(r.get("fault", "")):
			"error":
				if hard == "":
					hard = String(r.get("note", "the run did not produce a state.json"))
			"workload":
				# Not a timing question at all: the run did not build the city it
				# is named for, or it printed errors. One bad reading is enough.
				if workload == "":
					workload = String(r.get("note", ""))
			_:
				samples.append(float(r.get("ticks_per_second", 0.0)))
	samples.sort()

	var med: float = _median(samples)
	var lo: float = samples[0] if not samples.is_empty() else 0.0
	var hi: float = samples[samples.size() - 1] if not samples.is_empty() else 0.0
	var spread: float = ((hi - lo) / lo * 100.0) if lo > 0.0 else 0.0
	var below: int = 0
	for s: float in samples:
		if s < floor_tps:
			below += 1

	var status: String = "ok"
	var note: String = ""
	if hard != "":
		status = "error"
		note = hard
	elif workload != "":
		status = "regressed"
		note = workload
	elif samples.is_empty():
		status = "error"
		note = "no readable reading for %s" % scenario
	elif med < floor_tps:
		status = "regressed"
		note = "median %.0f ticks/s is below the floor of %.0f (%d of %d reading(s) under it, spread %.0f%%)" % [
			med, floor_tps, below, samples.size(), spread]
	elif below > 0:
		status = "noisy"
		note = "median %.0f holds the floor of %.0f but %d of %d reading(s) fell under it (%.0f..%.0f, spread %.0f%%) — this box, not this build" % [
			med, floor_tps, below, samples.size(), lo, hi, spread]
	elif target_tps > 0.0 and med < target_tps:
		status = "slow"
		note = "median %.0f ticks/s is under the %.0f target but above the floor" % [med, target_tps]
	elif samples.size() == 1:
		note = "1 reading — a single sample is not a distribution; run tools/perf.sh --repeat=3 before quoting it"

	return {
		"scenario": scenario,
		"readings": samples.size(),
		"ticks": ticks,
		"samples": samples,
		"median_ticks_per_second": snappedf(med, 0.1),
		"min_ticks_per_second": snappedf(lo, 0.1),
		"max_ticks_per_second": snappedf(hi, 0.1),
		"spread_percent": snappedf(spread, 0.1),
		"readings_below_floor": below,
		"floor_ticks_per_second": snappedf(floor_tps, 0.1),
		"target_ticks_per_second": snappedf(target_tps, 0.1),
		"status": status,
		"note": note,
	}


func _median(sorted_samples: Array[float]) -> float:
	var n: int = sorted_samples.size()
	if n == 0:
		return 0.0
	if n % 2 == 1:
		return sorted_samples[n / 2]
	return (sorted_samples[n / 2 - 1] + sorted_samples[n / 2]) * 0.5


func _measure(canon: Script, dir_path: String, multiplier: float, overrides: Dictionary) -> Dictionary:
	var state_path: String = dir_path.rstrip("/") + "/state.json"
	var state: Variant = canon.call("load_file", state_path)
	if typeof(state) != TYPE_DICTIONARY:
		return {"run": dir_path, "scenario": _scenario_of(dir_path), "status": "error", "fault": "error",
			"note": "no readable state.json at %s — did the run crash?" % state_path}

	var s: Dictionary = state
	var scenario: String = String(s.get("scenario", _scenario_of(dir_path)))
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
	# `fault` is what the scenario-level verdict reads. Only a fault that no
	# amount of re-reading can wash out belongs here: a crashed run, or a run
	# that did not build the city it is named for. A single slow READING is a
	# sample, not a verdict — the distribution decides, in _summarise().
	var fault: String = ""
	var built: int = int(float(metrics.get("final", {}).get("build.buildings_total", 0)))
	if ticks <= 0:
		status = "error"
		fault = "error"
		note = "the run reported zero ticks"
	elif min_buildings > 0 and built < min_buildings:
		status = "regressed"
		fault = "workload"
		note = "only %d buildings on the map, %d required — the workload is not what the scenario claims" % [
			built, min_buildings]
	elif errors.size() > max_errors:
		status = "regressed"
		fault = "workload"
		note = "%d run error(s), %d allowed: %s" % [errors.size(), max_errors, str(errors[0])]
	elif tps < floor_tps:
		status = "under floor"
		note = "%.0f ticks/s is below the floor of %.0f" % [tps, floor_tps]
	elif target_tps > 0.0 and tps < target_tps:
		status = "slow"
		note = "%.0f ticks/s is under the %.0f target but above the floor" % [tps, target_tps]

	return {
		"run": dir_path,
		"fault": fault,
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


## artifacts/perf/stress_1000/r2 -> "stress_1000". Repeat readings of one
## scenario live in sibling directories, and a crashed run has no state.json to
## name itself from.
func _scenario_of(dir_path: String) -> String:
	var leaf: String = dir_path.rstrip("/").get_file()
	if leaf.length() > 1 and leaf.begins_with("r") and leaf.substr(1).is_valid_int():
		return dir_path.rstrip("/").get_base_dir().get_file()
	return leaf


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


## The spread is printed on every run, passing or failing. A reader looking at a
## red perf stage has to be able to tell in one glance whether it is real, and
## the single number this table used to print could not tell them.
func _print_table(groups: Array) -> void:
	print("")
	print(" %-16s %5s %8s %9s %9s %9s %8s %8s  %s" % [
		"scenario", "reads", "ticks", "median/s", "min/s", "max/s", "spread", "floor", "status"])
	for raw: Variant in groups:
		var g: Dictionary = raw
		print(" %-16s %5d %8d %9.0f %9.0f %9.0f %7.0f%% %8.0f  %s" % [
			String(g.get("scenario", "?")),
			int(g.get("readings", 0)),
			int(g.get("ticks", 0)),
			float(g.get("median_ticks_per_second", 0.0)),
			float(g.get("min_ticks_per_second", 0.0)),
			float(g.get("max_ticks_per_second", 0.0)),
			float(g.get("spread_percent", 0.0)),
			float(g.get("floor_ticks_per_second", 0.0)),
			String(g.get("status", "?")),
		])
		var samples: Array = g.get("samples", [])
		if samples.size() > 1:
			var parts: PackedStringArray = PackedStringArray()
			for s: Variant in samples:
				parts.append("%.0f" % float(s))
			print("   readings: %s ticks/s" % " · ".join(parts))
		if String(g.get("note", "")) != "":
			print("   %s" % String(g.get("note", "")))
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
