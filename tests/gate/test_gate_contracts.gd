extends TestCase
## The gate's own contracts, held to the same standard as everything else.
##
## tests/gate/expectations.json, tests/gate/reachability.json and
## tools/error_allowlist.txt are data files that only ever run inside shell
## tools. Data that only shell reads is data that rots: a band naming a metric
## nobody emits any more, an allowlist entry with no owner, a scenario that
## quietly ships without a contract at all.
##
## So this suite runs inside the ordinary test runner, against the LIVE metric
## namespace of a real world, and fails when the gate's own inputs stop meaning
## anything. Without it, "every shipped scenario gets meaningful expectations"
## is a sentence in a commit message rather than a property of the repo.

const EXPECTATIONS: String = "res://tests/gate/expectations.json"
const REACHABILITY: String = "res://tests/gate/reachability.json"
const ALLOWLIST: String = "res://tools/error_allowlist.txt"
const SCENARIO_DIR: String = "res://tests/scenarios"

## Operators tools/gate_lib.py implements. A band using anything else is
## silently skipped by the checker, which is the quiet kind of green.
const OPS: Array[String] = [
	"final_min", "final_max", "min", "max", "peak_min", "peak_max",
	"mean_min", "mean_max", "delta_min", "delta_max",
	"must_move", "nonzero_by", "in_set", "why",
]
const STATE_OPS: Array[String] = ["min", "max", "eq", "len_min", "len_max", "exists", "why"]
const LIVENESS_KEYS: Array[String] = [
	"stalled_enemy_ticks", "waves_must_end", "min_kill_ratio",
	"min_shots_per_enemy", "claims", "$why_stalled", "$why_shots",
]

var _expect: Dictionary = {}
var _reach: Dictionary = {}
var _world: SimFixture = null
var _metric_keys: PackedStringArray = PackedStringArray()


func requires_files() -> PackedStringArray:
	return PackedStringArray([EXPECTATIONS, REACHABILITY, ALLOWLIST])


func before_all() -> void:
	_expect = _json(EXPECTATIONS)
	_reach = _json(REACHABILITY)
	_world = SimFixture.new(7).start()
	if _world.alive():
		var keys: Array = _world.metrics().keys()
		keys.sort()
		_metric_keys = PackedStringArray(keys)


func after_all() -> void:
	if _world != null:
		_world.stop()


func _json(path: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


func _scenarios() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var dir: DirAccess = DirAccess.open(SCENARIO_DIR)
	if dir == null:
		return out
	var files: PackedStringArray = dir.get_files()
	var sorted: Array[String] = []
	for f: String in files:
		if f.ends_with(".json") and not f.begins_with("_"):
			sorted.append(f.get_basename())
	sorted.sort()
	return PackedStringArray(sorted)


# --- every shipped scenario is under contract --------------------------------

func test_every_shipped_scenario_has_expectations() -> void:
	var specs: Dictionary = _expect.get("scenarios", {})
	assert_not_empty(specs, "tests/gate/expectations.json holds no scenarios at all")
	for name: String in _scenarios():
		assert_true(specs.has(name),
			"scenario '%s' ships with no EXPECTATION block — its metrics.csv is decoration" % name)


func test_every_contract_is_meaningful() -> void:
	var specs: Dictionary = _expect.get("scenarios", {})
	var names: Array = specs.keys()
	names.sort()
	for name: String in names:
		var spec: Dictionary = specs[name]
		assert_true(String(spec.get("why", "")).length() >= 40,
			"contract '%s' does not say why it exists" % name)
		var metrics: Dictionary = spec.get("metrics", {})
		assert_ge(float(metrics.size()), 4.0,
			"contract '%s' bands only %d metric(s); a contract that asserts almost nothing is how a 24000-tick run with a dead pillar passed" % [name, metrics.size()])
		for metric: String in metrics:
			var band: Dictionary = metrics[metric]
			assert_true(String(band.get("why", "")).length() >= 25,
				"%s / %s is a magic number: no why" % [name, metric])
			for op: String in band:
				assert_has(OPS, op, "%s / %s uses operator '%s', which gate_lib.py does not implement" % [name, metric, op])
		for path: String in spec.get("state", {}):
			var sband: Dictionary = spec["state"][path]
			for op: String in sband:
				assert_has(STATE_OPS, op, "%s / state %s uses unknown operator '%s'" % [name, path, op])
		for key: String in spec.get("liveness", {}):
			assert_has(LIVENESS_KEYS, key, "%s / liveness key '%s' is not implemented" % [name, key])


func test_every_banded_metric_exists_in_this_build() -> void:
	if _metric_keys.is_empty():
		skip("no world — cannot resolve the live metric namespace")
		return
	var specs: Dictionary = _expect.get("scenarios", {})
	var names: Array = specs.keys()
	names.sort()
	for name: String in names:
		for metric: String in (specs[name] as Dictionary).get("metrics", {}):
			# stock.<item> comes from tools/gate_probe.gd, not Sim.collect_metrics().
			if metric.begins_with("stock."):
				continue
			assert_has(_metric_keys, metric,
				"%s bands '%s', which no system emits — a band on a metric that does not exist can never fail" % [name, metric])


func test_consistency_rules_name_real_metrics_and_signals() -> void:
	if _metric_keys.is_empty():
		skip("no world — cannot resolve the live metric namespace")
		return
	var bus: Node = TestEnv.bus()
	var signals: PackedStringArray = PackedStringArray()
	if bus != null:
		for s: Dictionary in bus.get_signal_list():
			signals.append(String(s["name"]))
	for raw: Variant in (_expect.get("$defaults", {}) as Dictionary).get("consistency", []):
		var rule: Dictionary = raw
		assert_has(_metric_keys, String(rule.get("metric", "")),
			"consistency rule '%s' names a metric no system emits" % rule.get("id", "?"))
		assert_has(signals, String(rule.get("signal", "")),
			"consistency rule '%s' names a signal Bus does not declare" % rule.get("id", "?"))
		assert_true(String(rule.get("why", "")).length() >= 25,
			"consistency rule '%s' has no why" % rule.get("id", "?"))


func test_alert_claim_rules_are_valid_regex() -> void:
	var specs: Dictionary = _expect.get("scenarios", {})
	for name: String in specs:
		var liveness: Dictionary = (specs[name] as Dictionary).get("liveness", {})
		for raw: Variant in liveness.get("claims", []):
			var rule: Dictionary = raw
			var re := RegEx.new()
			var pattern: String = String(rule.get("match", ""))
			assert_eq(re.compile(pattern), OK,
				"%s / claim '%s' has a pattern that will not compile: %s" % [name, rule.get("id", "?"), pattern])
			assert_true(rule.has("implies_series") or rule.has("series"),
				"%s / claim '%s' checks nothing: no series to hold the claim against" % [name, rule.get("id", "?")])


# --- the reachability contract points at things that exist -------------------

func test_reachability_contract_points_at_real_scripts() -> void:
	var required: Array = _reach.get("required", [])
	assert_ge(float(required.size()), 4.0, "the reachability contract requires almost nothing")
	for raw: Variant in required:
		var req: Dictionary = raw
		assert_true(String(req.get("why", "")).length() >= 25,
			"required '%s' does not say why it has to be in the tree" % req.get("id", "?"))
		if req.has("script"):
			assert_true(ResourceLoader.exists(String(req["script"])) or FileAccess.file_exists(String(req["script"])),
				"required '%s' points at %s, which does not exist — the assertion can only ever fail for the wrong reason" % [req.get("id", "?"), req["script"]])
	var order: Dictionary = _reach.get("layer_order", {})
	var ids: Array = order.get("ids", [])
	var resolve: Dictionary = order.get("resolve", {})
	for id: Variant in ids:
		assert_true(resolve.has(String(id)), "layer_order names '%s' with no way to resolve it" % id)


func test_reachability_expects_the_systems_this_build_declares() -> void:
	if _world == null or not _world.alive():
		skip("no world")
		return
	var live: PackedStringArray = _world.system_names()
	for raw: Variant in _reach.get("expect_systems", []):
		assert_has(live, String(raw),
			"the reachability contract expects sim system '%s', which this build does not have" % raw)


# --- the allowlist cannot rot ------------------------------------------------

func test_every_allowlist_entry_qualifies() -> void:
	var text: String = FileAccess.get_file_as_string(ALLOWLIST)
	assert_not_empty(text, "tools/error_allowlist.txt is empty or unreadable")
	var current: Dictionary = {}
	var entries: Array[Dictionary] = []
	for raw_line: String in text.split("\n"):
		var line: String = raw_line
		if line.strip_edges().begins_with("#") or line.strip_edges() == "":
			continue
		var colon: int = line.find(":")
		if colon < 0 or line.begins_with(" ") or line.begins_with("\t"):
			continue
		var key: String = line.substr(0, colon).strip_edges()
		var value: String = line.substr(colon + 1).strip_edges()
		if key == "id":
			if not current.is_empty():
				entries.append(current)
			current = {}
		current[key] = value
	if not current.is_empty():
		entries.append(current)

	var today: Dictionary = Time.get_date_dict_from_system()
	for entry: Dictionary in entries:
		var id: String = String(entry.get("id", "?"))
		for field: String in ["class", "match", "owner", "why", "expires"]:
			assert_true(entry.has(field), "allowlist '%s' has no %s: — it suppresses nothing" % [id, field])
		assert_has(["tracked", "benign"], String(entry.get("class", "")),
			"allowlist '%s' has an unknown class" % id)
		assert_ge(float(String(entry.get("why", "")).length()), 25.0,
			"allowlist '%s' does not justify itself" % id)
		var parts: PackedStringArray = String(entry.get("expires", "")).split("-")
		assert_eq(parts.size(), 3, "allowlist '%s' expires: is not YYYY-MM-DD" % id)
		if parts.size() == 3:
			var stamp: int = int(parts[0]) * 10000 + int(parts[1]) * 100 + int(parts[2])
			var now: int = int(today["year"]) * 10000 + int(today["month"]) * 100 + int(today["day"])
			assert_gt(float(stamp), float(now),
				"allowlist '%s' expired on %s — renew it with a reason or fix the error" % [id, entry.get("expires", "")])


func test_the_gate_tools_are_all_present() -> void:
	# A gate stage whose tool is missing does not fail loudly; check.sh would
	# record a stage error, but a suite that names the files makes the coupling
	# visible from inside the test run too.
	for path: String in [
		"res://tools/gate.sh", "res://tools/gate_lib.py", "res://tools/scan_errors.py",
		"res://tools/assert_run.py", "res://tools/check_reachability.py",
		"res://tools/gate_probe.gd", "res://tools/reachability_probe.gd",
		"res://tools/reachability_scene.tscn",
	]:
		assert_true(FileAccess.file_exists(path), "%s is missing — a gate stage cannot run" % path)
