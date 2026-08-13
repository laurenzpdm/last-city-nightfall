extends TestCase
## The scenario library is the input side of every headless run, every balance
## reading and the determinism tripwire. A malformed scenario does not fail
## loudly — the harness quietly runs the wrong thing and a critic reads numbers
## that mean nothing. So the library is validated as data, here, against
## tests/scenarios/_schema.json.

const DIR: String = "res://tests/scenarios"
const SCHEMA_PATH: String = "res://tests/scenarios/_schema.json"

var schema: Dictionary = {}
var scenarios: Dictionary = {}   ## name -> parsed scenario


func before_all() -> void:
	var raw: Variant = JsonCanon.load_file(SCHEMA_PATH)
	if typeof(raw) == TYPE_DICTIONARY:
		schema = raw
	for path: String in _scenario_paths():
		var parsed: Variant = JsonCanon.load_file(path)
		if typeof(parsed) == TYPE_DICTIONARY:
			scenarios[path.get_file().get_basename()] = parsed


func _scenario_paths() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var dir: DirAccess = DirAccess.open(DIR)
	if dir == null:
		return out
	var files: Array[String] = []
	for f: String in dir.get_files():
		if f.ends_with(".json") and not f.begins_with("_"):
			files.append(f)
	files.sort()
	for f: String in files:
		out.append("%s/%s" % [DIR, f])
	return out


func _known_systems() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for s: Variant in schema.get("scenario_systems", []):
		out.append(String(s))
	return out


# --- the library exists and is well-formed -----------------------------------

func test_schema_is_present_and_parses() -> void:
	assert_not_empty(schema, "tests/scenarios/_schema.json must parse")
	assert_not_empty(schema.get("scenario_systems", []), "the schema lists the routable systems")


func test_every_required_scenario_exists() -> void:
	for required: Variant in schema.get("required_scenarios", []):
		assert_has(scenarios, String(required), "scenario '%s' is missing" % required)


func test_every_scenario_file_parses_as_json() -> void:
	var paths: PackedStringArray = _scenario_paths()
	assert_not_empty(paths, "there is at least one scenario")
	assert_eq(scenarios.size(), paths.size(), "every scenario file parses as a JSON object")


func test_name_matches_the_file_and_required_keys_are_typed() -> void:
	for key: String in _names():
		var sc: Dictionary = scenarios[key]
		assert_eq(String(sc.get("name", "")), key, "%s.json declares a different name" % key)
		assert_eq(typeof(sc.get("seed")), TYPE_FLOAT if sc.get("seed") is float else TYPE_INT,
			"%s: seed must be a number" % key)
		assert_ge(float(sc.get("ticks", 0)), 1.0, "%s: ticks must be at least 1" % key)
		assert_ge(float(sc.get("sample_every", 20)), 1.0, "%s: sample_every must be at least 1" % key)
		assert_not_empty(String(sc.get("description", "")),
			"%s: say what this scenario is for — a critic reads this first" % key)


func test_no_unknown_top_level_keys() -> void:
	var allowed: PackedStringArray = PackedStringArray()
	var spec: Dictionary = schema.get("scenario", {})
	for k: Variant in (spec.get("required", {}) as Dictionary).keys():
		allowed.append(String(k))
	for k: Variant in (spec.get("optional", {}) as Dictionary).keys():
		allowed.append(String(k))
	for key: String in _names():
		for k: Variant in (scenarios[key] as Dictionary).keys():
			assert_has(allowed, String(k),
				"%s: '%s' is not a scenario key — the harness would ignore it" % [key, k])


# --- the script timeline ------------------------------------------------------

func test_script_entries_are_inside_the_run_and_in_order() -> void:
	for key: String in _names():
		var sc: Dictionary = scenarios[key]
		var ticks: int = int(sc.get("ticks", 0))
		var previous: int = 0
		for raw: Variant in sc.get("script", []):
			assert_eq(typeof(raw), TYPE_DICTIONARY, "%s: script entries are objects" % key)
			var entry: Dictionary = raw
			var t: int = int(entry.get("tick", 0))
			# The harness loop is `for t in range(1, ticks + 1)`, so a command
			# scheduled at tick 0 is silently never delivered.
			assert_ge(float(t), 1.0, "%s: tick 0 never fires" % key)
			assert_le(float(t), float(ticks), "%s: tick %d is past the end of the run" % [key, t])
			assert_ge(float(t), float(previous), "%s: script must read in tick order" % key)
			previous = t


func test_every_command_names_a_routable_system_and_an_op() -> void:
	var systems: PackedStringArray = _known_systems()
	for key: String in _names():
		for raw: Variant in (scenarios[key] as Dictionary).get("script", []):
			var entry: Dictionary = raw
			assert_eq(typeof(entry.get("cmd")), TYPE_DICTIONARY,
				"%s: every script entry carries a cmd object" % key)
			var c: Dictionary = entry.get("cmd", {})
			var system: String = String(c.get("system", ""))
			assert_has(systems, system,
				"%s @%d: '%s' is not a routable system" % [key, int(entry.get("tick", 0)), system])
			assert_not_empty(String(c.get("op", "")),
				"%s @%d: command to '%s' has no op" % [key, int(entry.get("tick", 0)), system])


func test_cells_and_regions_are_integer_pairs() -> void:
	for key: String in _names():
		for raw: Variant in (scenarios[key] as Dictionary).get("script", []):
			var entry: Dictionary = raw
			var c: Dictionary = entry.get("cmd", {})
			for field: String in ["cell", "from", "to", "at"]:
				if not c.has(field):
					continue
				var v: Variant = c[field]
				assert_eq(typeof(v), TYPE_ARRAY,
					"%s @%d: %s must be [x, y]" % [key, int(entry.get("tick", 0)), field])
				var pair: Array = v
				assert_eq(pair.size(), 2,
					"%s @%d: %s must have exactly two components" % [key, int(entry.get("tick", 0)), field])
				for component: Variant in pair:
					assert_eq(float(component), floor(float(component)),
						"%s @%d: %s components must be whole tiles" % [key, int(entry.get("tick", 0)), field])


func test_build_commands_use_ops_the_build_system_actually_has() -> void:
	# The one system that is fully landed, so its vocabulary can be checked hard.
	if not need_system(&"build"):
		return
	var vocabulary: Dictionary = (schema.get("command_vocabulary", {}) as Dictionary).get("build", {})
	var known: PackedStringArray = PackedStringArray()
	for k: Variant in vocabulary.keys():
		if not String(k).begins_with("$"):
			known.append(String(k))
	assert_not_empty(known, "the schema documents the build vocabulary")
	for key: String in _names():
		for raw: Variant in (scenarios[key] as Dictionary).get("script", []):
			var entry: Dictionary = raw
			var c: Dictionary = entry.get("cmd", {})
			if String(c.get("system", "")) != "build":
				continue
			assert_has(known, String(c.get("op", "")),
				"%s @%d: build op '%s' is not in the documented vocabulary" % [
					key, int(entry.get("tick", 0)), String(c.get("op", ""))])


# --- shots --------------------------------------------------------------------

func test_shots_are_inside_the_run_and_uniquely_named() -> void:
	for key: String in _names():
		var sc: Dictionary = scenarios[key]
		var ticks: int = int(sc.get("ticks", 0))
		var seen: PackedStringArray = PackedStringArray()
		for raw: Variant in sc.get("shots", []):
			var shot: Dictionary = raw
			var t: int = int(shot.get("tick", 0))
			assert_between(float(t), 1.0, float(ticks), "%s: shot tick %d is outside the run" % [key, t])
			var shot_name: String = String(shot.get("name", ""))
			assert_not_empty(shot_name, "%s: a shot needs a name; it becomes a PNG filename" % key)
			assert_has_not(seen, shot_name, "%s: two shots called '%s' would overwrite each other" % [key, shot_name])
			assert_eq(shot_name, shot_name.to_snake_case().to_lower(),
				"%s: shot name '%s' must be lower_snake_case" % [key, shot_name])
			seen.append(shot_name)


func test_the_reference_scenario_covers_the_whole_day_arc() -> void:
	# first_night is what the art, audio and UI parts screenshot against. If the
	# beats drift out of their phases, every visual review is looking at dusk
	# when it thinks it is looking at night.
	var sc: Dictionary = scenarios.get("first_night", {})
	assert_not_empty(sc, "first_night exists")
	var beats: Dictionary = {}
	for raw: Variant in sc.get("shots", []):
		var shot: Dictionary = raw
		beats[String(shot.get("name", ""))] = int(shot.get("tick", 0))
	for required: String in ["opening", "build", "dusk", "assault", "dawn"]:
		assert_has(beats, required, "first_night must screenshot the '%s' beat" % required)
	if not need_system(&"climate"):
		return
	var day_ticks: int = 9600
	assert_lt(float(beats["opening"]), 960.0, "the opening shot belongs in dawn")
	assert_between(float(beats["dusk"]), 5376.0, 6336.0, "the dusk shot belongs in dusk")
	assert_between(float(beats["assault"]), 6336.0, float(day_ticks), "the assault shot belongs in the night")
	assert_gt(float(beats["dawn"]), float(day_ticks), "the dawn shot belongs to the morning after")
	assert_gt(float(sc.get("ticks", 0)), float(day_ticks), "first_night must outlast the first day")


# --- the library against the real build --------------------------------------

func test_metrics_sampling_produces_a_readable_series() -> void:
	for key: String in _names():
		var sc: Dictionary = scenarios[key]
		var rows: int = int(sc.get("ticks", 0)) / maxi(1, int(sc.get("sample_every", 20)))
		assert_between(float(rows), 20.0, 4000.0,
			"%s: %d metric rows is not a series a human or a graph can read" % [key, rows])


func test_perf_expectations_are_declared_for_gated_scenarios() -> void:
	for key: String in _names():
		var sc: Dictionary = scenarios[key]
		var expects: Dictionary = sc.get("expects", {})
		assert_has(expects, "min_ticks_per_second", "%s: declare the floor tools/perf.sh enforces" % key)
		assert_gt(float(expects.get("min_ticks_per_second", 0.0)), 20.0,
			"%s: a headless run below 20 ticks/second is slower than real time" % key)
		assert_has(expects, "max_errors", "%s: declare how many run errors are tolerable" % key)


func test_scenarios_reference_buildings_that_exist_once_content_lands() -> void:
	# Deliberately not per-id: [P11] owns the ids and may rename one. What must
	# never happen is the scenario library drifting into fiction — if buildings
	# exist and not a single referenced kind resolves, these runs build nothing.
	var available: Array[StringName] = Registry.ids("buildings")
	if available.is_empty():
		skip("game/content/buildings/ is empty — [P11] has not shipped content yet")
		return
	var referenced: PackedStringArray = PackedStringArray()
	for key: String in _names():
		for raw: Variant in (scenarios[key] as Dictionary).get("script", []):
			var c: Dictionary = (raw as Dictionary).get("cmd", {})
			var kind: String = String(c.get("kind", ""))
			if kind != "" and not referenced.has(kind):
				referenced.append(kind)
	assert_not_empty(referenced, "the library places buildings")
	var resolved: int = 0
	for kind: String in referenced:
		if Registry.has("buildings", StringName(kind)):
			resolved += 1
	assert_gt(float(resolved), 0.0,
		"none of the %d building kinds the scenarios place exist in the registry" % referenced.size())


func test_a_scenario_script_replays_identically() -> void:
	# The determinism scenario is the one the tripwire runs. Prove in-process
	# first, so a failure points at a system instead of at the shell tooling.
	var sc: Dictionary = scenarios.get("determinism", {})
	assert_not_empty(sc, "the determinism scenario exists")
	var by_tick: Dictionary = _script_by_tick(sc)
	# Kept short on purpose: the full 4000-tick, two-process version is what
	# tools/determinism.sh runs. This one exists so an in-process failure points
	# at a system instead of at the shell tooling.
	var diff: PackedStringArray = SimFixture.replay_diff(int(sc.get("seed", 0)), 120, by_tick)
	assert_empty(diff, "the determinism scenario diverged from itself")


func test_running_a_scenario_script_raises_no_errors() -> void:
	var sc: Dictionary = scenarios.get("first_night", {})
	assert_not_empty(sc)
	var by_tick: Dictionary = _script_by_tick(sc)
	var play: Callable = func() -> void:
		SimFixture.replay(int(sc.get("seed", 7)), 200, by_tick)
	assert_no_errors(play, "the opening of first_night must not log an error")


func _script_by_tick(sc: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for raw: Variant in sc.get("script", []):
		var entry: Dictionary = raw
		var t: int = int(entry.get("tick", 0))
		var bucket: Array = out.get(t, [])
		bucket.append(entry.get("cmd", {}))
		out[t] = bucket
	return out


func _names() -> PackedStringArray:
	var keys: Array = scenarios.keys()
	keys.sort()
	var out: PackedStringArray = PackedStringArray()
	for k: Variant in keys:
		out.append(String(k))
	return out
