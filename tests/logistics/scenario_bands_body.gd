extends RefCounted
## [P03] Body of run_scenario_bands.gd. Replays each scenario against a real
## world and checks the metric bands it declares.
##
## It replays the script the same way game/core/harness.gd does — submit the
## commands scheduled for a tick, then advance one tick — so what is measured
## here is the same run a critic gets out of `--harness --scenario=...`.

const SCENARIOS: Array[String] = [
	"res://tests/logistics/cold_snap.json",
	"res://tests/logistics/belt_by_hand.json",
]

var _checks: int = 0
var _failures: PackedStringArray = PackedStringArray()


func run() -> bool:
	Log.min_level = Log.Level.WARN
	print("")
	print("── [P03] logistics scenario bands ──────────────────────────────────────")
	for path: String in SCENARIOS:
		_run_one(path)
	print("────────────────────────────────────────────────────────────────────────")
	if _failures.is_empty():
		print(" %d band(s) checked across %d scenario(s)" % [_checks, SCENARIOS.size()])
		print("TESTS PASSED")
		return true
	for line: String in _failures:
		print("  ✗ %s" % line)
	print(" %d of %d band(s) failed" % [_failures.size(), _checks])
	print("TESTS FAILED")
	return false


func _run_one(path: String) -> void:
	if not FileAccess.file_exists(path):
		_failures.append("%s does not exist" % path)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		_failures.append("%s is not valid JSON" % path)
		return
	var sc: Dictionary = parsed
	var name: String = String(sc.get("name", path.get_file().get_basename()))
	var ticks: int = int(sc.get("ticks", 1))
	var by_tick: Dictionary[int, Array] = {}
	for raw: Variant in sc.get("script", []):
		var entry: Dictionary = raw
		var t: int = int(entry.get("tick", 0))
		var list: Array = by_tick.get(t, [])
		list.append(entry.get("cmd", {}))
		by_tick[t] = list

	var errors_before: int = Log.errors
	SimClock.set_manual(true)
	Sim.create_world(int(sc.get("seed", 7)))
	var t0: int = Time.get_ticks_msec()  # wall clock: reporting only, never state
	for t: int in range(1, ticks + 1):
		for cmd: Variant in by_tick.get(t, []):
			Sim.submit_command(cmd)
		SimClock.advance(1)
	var wall: int = Time.get_ticks_msec() - t0
	var metrics: Dictionary = Sim.collect_metrics()
	Sim.teardown()

	var expects: Dictionary = sc.get("expects", {})
	var bands: Dictionary = expects.get("metrics", {})
	var logged: int = Log.errors - errors_before
	var max_errors: int = int(expects.get("max_errors", 0))
	print(" %s — %d ticks in %d ms, %d band(s)" % [name, ticks, wall, bands.size()])
	if bands.is_empty():
		_failures.append("%s declares no metric bands — a run that cannot fail" % name)
	_checks += 1
	if logged > max_errors:
		_failures.append("%s: %d error(s) logged, %d allowed" % [name, logged, max_errors])

	var keys: Array = bands.keys()
	keys.sort()
	for key: String in keys:
		_checks += 1
		var band: Array = bands[key]
		if band.size() != 2:
			_failures.append("%s: band '%s' is not [low, high]" % [name, key])
			continue
		if not metrics.has(key):
			_failures.append("%s: metric '%s' does not exist in this build" % [name, key])
			continue
		var value: float = float(metrics[key])
		var low: float = float(band[0])
		var high: float = float(band[1])
		if value < low or value > high:
			_failures.append("%s: %s = %s, expected %s..%s" % [name, key, str(metrics[key]), str(low), str(high)])
		else:
			print("    ✓ %-34s %12s  in %s..%s" % [key, str(metrics[key]), str(low), str(high)])
