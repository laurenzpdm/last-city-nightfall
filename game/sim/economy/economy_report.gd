class_name EconomyReport
extends RefCounted
## [P12] Economy & Balance — turning a run into a verdict.
##
## Takes the metric samples a run produced (the same rows the harness writes to
## metrics.csv, or live samples from `Sim.collect_metrics()`), folds them into
## the per-day shape the DifficultyCurve describes, and grades each day.
##
## This is what makes balance measurement-driven rather than vibes-driven: the
## intended experience is a resource, the run is data, and this class is the
## only place that decides whether they agree. `tools/analyze_balance.py`
## computes the same four quantities from a metrics.csv for offline work; the
## definitions below are the specification both obey.
##
##   margin        supply / demand at one sample. 1.0 when demand is zero.
##   night margin  mean margin over the dark phases (dusk, night, deep night)
##   trough        the single lowest margin sample of those dark phases
##   frozen        max(frozen_buildings / heat_buildings) over the dark phases
##   buffer floor  min(buffer) over the dark phases, as a fraction of the most
##                 the grid had ever banked up to the end of that day — i.e.
##                 "how much of your savings did the night take"
##
## DETERMINISM: pure. Same rows in, same report out, on any machine.

const KEY_TICK: String = "tick"
const KEY_DAY: String = "climate.day"
const KEY_PHASE: String = "climate.phase"
const KEY_STORM: String = "climate.storm_intensity"
const KEY_TEMP: String = "climate.ambient_temp"
const KEY_SUPPLY: String = "heat.total_supply"
const KEY_DEMAND: String = "heat.total_demand"
const KEY_DEFICIT: String = "heat.deficit"
const KEY_BUFFER: String = "heat.buffer"
const KEY_FROZEN: String = "heat.frozen_buildings"
const KEY_HEAT_BUILDINGS: String = "heat.buildings"
const KEY_NETWORKS: String = "heat.networks"
const KEY_BUILDINGS: String = "build.buildings_total"
const KEY_MATERIALS: String = "build.materials"


## Full report over a metric series.
##
## `rows` is an Array of Dictionaries; missing keys degrade to zero rather than
## failing, because half these systems are still being written. Pass the curve
## explicitly in tests; production callers pass `Balance.curve()`.
##
## Returns {days: Array[Dictionary], summary: Dictionary, verdict: StringName,
##          failures: Array[String]}.
static func analyse(rows: Array, curve: DifficultyCurve, day_ticks: int = 0) -> Dictionary:
	var dt: int = day_ticks if day_ticks > 0 else (curve.day_ticks if curve != null else EconomyDefs.DEFAULT_DAY_TICKS)
	var by_day: Dictionary[int, Array] = {}
	var order: Array[int] = []
	for raw: Variant in rows:
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var row: Dictionary = raw
		var d: int = _day_of(row, dt)
		if not by_day.has(d):
			by_day[d] = []
			order.append(d)
		(by_day[d] as Array).append(row)
	order.sort()

	var days: Array[Dictionary] = []
	var failures: Array[String] = []
	var worst: StringName = EconomyDefs.VERDICT_PASS
	var peak_buffer: float = 0.0

	for d: int in order:
		var day_rows: Array = by_day[d]
		for raw2: Variant in day_rows:
			peak_buffer = maxf(peak_buffer, _num(raw2, KEY_BUFFER))
		var entry: Dictionary = _measure_day(d, day_rows, peak_buffer)
		var targets: Dictionary = curve.targets_for(d) if curve != null else {}
		var checks: Array[Dictionary] = []
		if not targets.is_empty() and bool(entry["has_night"]):
			checks = _grade(entry, targets, curve.soft_tolerance)
		entry["targets"] = targets
		entry["checks"] = checks
		var day_verdict: StringName = EconomyDefs.VERDICT_PASS
		if targets.is_empty():
			day_verdict = EconomyDefs.VERDICT_NO_DATA
		elif not bool(entry["has_night"]):
			day_verdict = EconomyDefs.VERDICT_NO_DATA
		else:
			for c: Dictionary in checks:
				var v: StringName = StringName(String(c["verdict"]))
				if v == EconomyDefs.VERDICT_FAIL:
					day_verdict = EconomyDefs.VERDICT_FAIL
				elif v == EconomyDefs.VERDICT_SOFT and day_verdict == EconomyDefs.VERDICT_PASS:
					day_verdict = EconomyDefs.VERDICT_SOFT
				if v == EconomyDefs.VERDICT_FAIL:
					failures.append("day %d: %s" % [d, String(c["text"])])
		entry["verdict"] = day_verdict
		if day_verdict == EconomyDefs.VERDICT_FAIL:
			worst = EconomyDefs.VERDICT_FAIL
		elif day_verdict == EconomyDefs.VERDICT_SOFT and worst == EconomyDefs.VERDICT_PASS:
			worst = EconomyDefs.VERDICT_SOFT
		days.append(entry)

	return {
		"days": days,
		"summary": _summarise(rows, days),
		"verdict": worst,
		"failures": failures,
	}


## One day's measured shape, without any grading.
static func _measure_day(d: int, day_rows: Array, peak_buffer: float) -> Dictionary:
	var margin_sum: float = 0.0
	var margin_n: int = 0
	var trough: float = INF
	var frozen_worst: float = 0.0
	var buffer_low: float = INF
	var storm_peak: float = 0.0
	var coldest: float = 0.0
	var has_temp: bool = false
	var deficit_samples: int = 0
	var night_samples: int = 0
	var demand_peak: float = 0.0
	var supply_peak: float = 0.0
	var networks_peak: int = 0
	var buildings_end: int = 0

	for raw: Variant in day_rows:
		var row: Dictionary = raw
		storm_peak = maxf(storm_peak, _num(row, KEY_STORM))
		var temp: float = _num(row, KEY_TEMP)
		if row.has(KEY_TEMP):
			coldest = temp if not has_temp else minf(coldest, temp)
			has_temp = true
		demand_peak = maxf(demand_peak, _num(row, KEY_DEMAND))
		supply_peak = maxf(supply_peak, _num(row, KEY_SUPPLY))
		networks_peak = maxi(networks_peak, int(_num(row, KEY_NETWORKS)))
		buildings_end = int(_num(row, KEY_BUILDINGS))
		if _num(row, KEY_DEFICIT) > 0.01:
			deficit_samples += 1
		if not EconomyDefs.is_night_phase(_phase(row)):
			continue
		night_samples += 1
		var m: float = EconomyDefs.margin(_num(row, KEY_SUPPLY), _num(row, KEY_DEMAND))
		margin_sum += m
		margin_n += 1
		trough = minf(trough, m)
		var heat_buildings: float = _num(row, KEY_HEAT_BUILDINGS)
		if heat_buildings > 0.0:
			frozen_worst = maxf(frozen_worst, _num(row, KEY_FROZEN) / heat_buildings)
		buffer_low = minf(buffer_low, _num(row, KEY_BUFFER))

	var has_night: bool = margin_n > 0
	return {
		"day": d,
		"samples": day_rows.size(),
		"night_samples": night_samples,
		"has_night": has_night,
		"margin": snappedf(margin_sum / float(maxi(1, margin_n)), 0.0001) if has_night else 0.0,
		"trough": snappedf(trough, 0.0001) if has_night else 0.0,
		"frozen_fraction": snappedf(frozen_worst, 0.0001),
		"buffer_floor": snappedf(
			(buffer_low / peak_buffer) if (has_night and peak_buffer > 0.0) else 0.0, 0.0001),
		"buffer_low": snappedf(buffer_low if has_night else 0.0, 0.01),
		"buffer_peak_so_far": snappedf(peak_buffer, 0.01),
		"storm_peak": snappedf(storm_peak, 0.001),
		"coldest_c": snappedf(coldest, 0.01),
		"deficit_samples": deficit_samples,
		"demand_peak": snappedf(demand_peak, 0.01),
		"supply_peak": snappedf(supply_peak, 0.01),
		"networks_peak": networks_peak,
		"buildings": buildings_end,
	}


static func _grade(entry: Dictionary, targets: Dictionary, soft: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	out.append(_check("margin", float(entry["margin"]),
		float(targets["margin_min"]), float(targets["margin_max"]), soft,
		"average supply/demand across the dark phases"))
	out.append(_check("trough", float(entry["trough"]),
		float(targets["trough_min"]), float(targets["trough_max"]), soft,
		"worst single sample of the night"))
	out.append(_check("frozen_fraction", float(entry["frozen_fraction"]),
		0.0, float(targets["frozen_max"]), soft,
		"share of the heat grid frozen at once"))
	out.append(_check("buffer_floor", float(entry["buffer_floor"]),
		float(targets["buffer_floor_min"]), 1.0, soft,
		"stored heat left at the worst moment, against the most ever banked"))
	return out


static func _check(name: String, value: float, low: float, high: float,
		soft: float, note: String) -> Dictionary:
	var verdict: StringName = EconomyDefs.verdict_for(value, low, high, soft)
	return {
		"name": name,
		"value": snappedf(value, 0.0001),
		"low": snappedf(low, 0.0001),
		"high": snappedf(high, 0.0001),
		"offset": snappedf(EconomyDefs.band_offset(value, low, high), 0.0001),
		"verdict": verdict,
		"note": note,
		"text": "%s %.3f outside %.3f..%.3f (%s)" % [name, value, low, high, note],
	}


static func _summarise(rows: Array, days: Array[Dictionary]) -> Dictionary:
	var n: int = rows.size()
	var deficit_samples: int = 0
	var peak_demand: float = 0.0
	var peak_supply: float = 0.0
	var peak_networks: int = 0
	var first_buildings: int = 0
	var last_buildings: int = 0
	var last_materials: float = 0.0
	var first_materials: float = 0.0
	var last_tick: int = 0
	for i: int in n:
		var row: Dictionary = rows[i]
		if _num(row, KEY_DEFICIT) > 0.01:
			deficit_samples += 1
		peak_demand = maxf(peak_demand, _num(row, KEY_DEMAND))
		peak_supply = maxf(peak_supply, _num(row, KEY_SUPPLY))
		peak_networks = maxi(peak_networks, int(_num(row, KEY_NETWORKS)))
		last_buildings = int(_num(row, KEY_BUILDINGS))
		last_materials = _num(row, KEY_MATERIALS)
		last_tick = int(_num(row, KEY_TICK))
		if i == 0:
			first_buildings = last_buildings
			first_materials = last_materials
	return {
		"samples": n,
		"last_tick": last_tick,
		"days_measured": days.size(),
		"deficit_fraction": snappedf(float(deficit_samples) / float(maxi(1, n)), 0.0001),
		"peak_demand": snappedf(peak_demand, 0.01),
		"peak_supply": snappedf(peak_supply, 0.01),
		"peak_networks": peak_networks,
		"buildings_start": first_buildings,
		"buildings_end": last_buildings,
		"materials_start": snappedf(first_materials, 0.01),
		"materials_end": snappedf(last_materials, 0.01),
	}


## Human-readable table. Used by tests when they fail and by anything that wants
## the report in a log without shelling out to python.
static func render(report: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	out.append(" day  label            margin  trough  frozen  buf-floor  storm  verdict")
	for raw: Variant in report.get("days", []):
		var d: Dictionary = raw
		var targets: Dictionary = d.get("targets", {})
		out.append(" %3d  %-15s %6.3f  %6.3f  %5.1f%%  %8.3f  %5.2f  %s" % [
			int(d.get("day", 0)),
			String(targets.get("label", "—")).substr(0, 15),
			float(d.get("margin", 0.0)),
			float(d.get("trough", 0.0)),
			float(d.get("frozen_fraction", 0.0)) * 100.0,
			float(d.get("buffer_floor", 0.0)),
			float(d.get("storm_peak", 0.0)),
			String(d.get("verdict", "?")),
		])
	var summary: Dictionary = report.get("summary", {})
	out.append(" %d samples, peak demand %.1f, peak supply %.1f, %.0f%% of samples in deficit" % [
		int(summary.get("samples", 0)), float(summary.get("peak_demand", 0.0)),
		float(summary.get("peak_supply", 0.0)),
		float(summary.get("deficit_fraction", 0.0)) * 100.0])
	return out


static func _day_of(row: Dictionary, day_ticks: int) -> int:
	if row.has(KEY_DAY):
		var d: int = int(_num(row, KEY_DAY))
		if d > 0:
			return d
	return EconomyDefs.day_of_tick(int(_num(row, KEY_TICK)), day_ticks)


static func _phase(row: Dictionary) -> StringName:
	return StringName(String(row.get(KEY_PHASE, "")))


static func _num(row: Dictionary, key: String) -> float:
	if not row.has(key):
		return 0.0
	var v: Variant = row[key]
	match typeof(v):
		TYPE_FLOAT, TYPE_INT, TYPE_BOOL:
			return float(v)
		TYPE_STRING, TYPE_STRING_NAME:
			var s: String = String(v)
			return float(s) if s.is_valid_float() else 0.0
	return 0.0
