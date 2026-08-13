extends TestCase
## The contracts in game/core/ that every other part is coded against.
##
## Nobody owns core except the integrator, which is exactly why it needs an
## owner-independent guard: if Rng stops being reproducible or SimClock stops
## advancing in whole ticks, twenty parts break at once and none of their own
## tests would say why.

const SEED: int = 4242

var world: SimFixture


# Worldgen costs a few hundred milliseconds, so the suite shares one world and
# the handful of tests that need a pristine tick counter or Rng say so with
# world.restart(). A test rig that is slow gets run less often, and a rig that
# is run less often is worth less than no rig at all.
func before_all() -> void:
	world = SimFixture.new(SEED).start()


func setup() -> void:
	world.ensure()


func after_all() -> void:
	world.stop()


# --- Rng ---------------------------------------------------------------------

func test_same_seed_produces_the_same_stream() -> void:
	Rng.reset(99)
	var a: Array[float] = []
	for _i: int in 12:
		a.append(Rng.stream("threat").randf())
	Rng.reset(99)
	var b: Array[float] = []
	for _i: int in 12:
		b.append(Rng.stream("threat").randf())
	assert_eq(a, b, "a seed is a promise")


func test_different_seeds_produce_different_streams() -> void:
	Rng.reset(1)
	var a: float = Rng.stream("threat").randf()
	Rng.reset(2)
	var b: float = Rng.stream("threat").randf()
	assert_ne(a, b, "two seeds must not collapse to the same run")


func test_named_streams_are_independent() -> void:
	# The whole point of named streams: adding a roll in one system must not
	# shift the sequence another system sees.
	Rng.reset(7)
	var threat_solo: Array[float] = []
	for _i: int in 5:
		threat_solo.append(Rng.stream("threat").randf())

	Rng.reset(7)
	var threat_mixed: Array[float] = []
	for _i: int in 5:
		Rng.stream("mapgen").randf()
		Rng.stream("loot").randi()
		threat_mixed.append(Rng.stream("threat").randf())

	assert_eq(threat_solo, threat_mixed, "another system's rolls must not move this one")


func test_stream_identity_is_stable_across_calls() -> void:
	Rng.reset(3)
	var first: RandomNumberGenerator = Rng.stream("weather")
	var second: RandomNumberGenerator = Rng.stream("weather")
	assert_true(first == second, "one stream object per name")


func test_snapshot_and_restore_round_trip() -> void:
	Rng.reset(11)
	for _i: int in 20:
		Rng.stream("threat").randf()
		Rng.stream("mapgen").randf()
	var snap: Dictionary = Rng.snapshot()
	var expected: Array[float] = []
	for _i: int in 5:
		expected.append(Rng.stream("threat").randf())

	Rng.restore(snap)
	var replayed: Array[float] = []
	for _i: int in 5:
		replayed.append(Rng.stream("threat").randf())
	assert_eq(replayed, expected, "restoring a snapshot resumes the exact sequence")


func test_snapshot_keys_are_sorted() -> void:
	Rng.reset(5)
	for name: String in ["zulu", "alpha", "mike", "bravo"]:
		Rng.stream(name).randf()
	var keys: Array = Rng.snapshot().keys()
	var sorted_keys: Array = keys.duplicate()
	sorted_keys.sort()
	assert_eq(keys, sorted_keys, "unsorted keys leak insertion order into saves")


func test_hash_combine_stays_in_positive_range() -> void:
	for a: int in [0, 1, -1, 7, 1 << 40]:
		for b: int in [0, 99, -99, 1 << 31]:
			var h: int = Rng.hash_combine(a, b)
			assert_ge(float(h), 0.0, "hash_combine feeds a seed; it must not go negative")


# --- SimClock ----------------------------------------------------------------

func test_tick_rate_and_dt_are_the_world_constants() -> void:
	assert_eq(SimClock.TICK_HZ, 20, "20 Hz is baked into every balance number in the game")
	assert_near(SimClock.DT, 0.05, 1e-12)


func test_advance_moves_whole_ticks_only() -> void:
	var before: int = world.tick()
	world.run(37)
	assert_eq(world.tick(), before + 37)
	assert_near(SimClock.seconds(), float(before + 37) * 0.05, 1e-9)


func test_advance_emits_one_bus_tick_per_step() -> void:
	var advance_ten: Callable = func() -> void: world.run(10)
	assert_signal_emitted(Bus, &"tick_advanced", advance_ten, 10)


func test_reset_returns_the_clock_to_zero() -> void:
	world.run(50)
	SimClock.reset()
	assert_eq(SimClock.tick, 0)
	assert_near(SimClock.seconds(), 0.0, 1e-12)
	world.restart()


# --- Sim ---------------------------------------------------------------------

func test_create_world_is_alive_and_seeded() -> void:
	world.restart()
	assert_true(world.alive(), "a created world is alive")
	assert_eq(Rng.seed_value, 4242, "world seed reaches Rng")
	assert_eq(world.tick(), 0, "a fresh world starts at tick zero")


func test_create_world_emits_the_lifecycle_signals() -> void:
	var recreate: Callable = func() -> void: Sim.create_world(5)
	assert_signal_emitted(Bus, &"world_created", recreate)
	assert_signal_emitted(Bus, &"world_ready", recreate)
	world.restart()


func test_teardown_leaves_nothing_behind() -> void:
	world.stop()
	assert_false(Sim.alive)
	assert_empty(Sim.systems)
	assert_empty(Sim.by_name)
	world.start()


func test_systems_tick_in_declared_order() -> void:
	var orders: Array[int] = []
	for s: SimSystem in Sim.systems:
		orders.append(s.order)
	var sorted_orders: Array[int] = orders.duplicate()
	sorted_orders.sort()
	assert_eq(orders, sorted_orders, "Sim must keep systems sorted by tick order")


func test_system_names_are_unique() -> void:
	assert_eq(Sim.by_name.size(), Sim.systems.size(),
		"two systems claiming one name would silently shadow each other")


func test_missing_system_returns_null_instead_of_crashing() -> void:
	assert_null(Sim.get_system(&"a_part_that_does_not_exist"),
		"parts must tolerate an absent dependency during parallel development")


func test_commands_are_queued_and_applied_on_the_next_tick() -> void:
	# Nothing consumes this command, but the queue must drain rather than grow.
	world.cmd({"system": "nobody", "op": "noop"})
	assert_eq(Sim._commands.size(), 1, "submit_command queues, it does not apply")
	world.run(1)
	assert_empty(Sim._commands, "the queue drains on the next tick")


func test_serialize_reports_tick_seed_and_every_system() -> void:
	world.restart().run(3)
	var state: Dictionary = world.state()
	assert_eq(state["tick"], 3)
	assert_eq(state["seed"], 4242)
	assert_has(state, "rng")
	assert_has(state, "systems")
	var systems: Dictionary = state["systems"]
	assert_eq(systems.size(), Sim.systems.size(), "every system serializes itself")


func test_metrics_are_namespaced_by_system() -> void:
	world.run(2)
	var m: Dictionary = world.metrics()
	assert_has(m, "tick")
	for key: String in m.keys():
		if key == "tick":
			continue
		assert_has(key, ".", "metric '%s' must be prefixed with its system name" % key)


func test_metrics_change_as_the_world_runs() -> void:
	# A metrics series that never moves is a graph nobody can read, and it is
	# the failure mode a headless balance run cannot see for itself.
	if Sim.systems.is_empty():
		skip("no sim systems built yet")
		return
	var before: Dictionary = world.metrics()
	world.run(600)
	var after: Dictionary = world.metrics()
	assert_not_empty(JsonCanon.diff(before, after), "600 ticks changed nothing measurable")


func test_only_the_rng_block_loses_anything_on_the_way_to_state_json() -> void:
	# The harness writes state.json; anything that cannot round-trip is a hole
	# in the artifact a critic is handed.
	#
	# One hole exists today and is fenced in here on purpose: Rng.snapshot()
	# emits 64-bit RandomNumberGenerator states, and JSON numbers are doubles,
	# so those integers come back rounded. Everything else must survive intact,
	# and this test fails the moment a new system starts writing 2^53+ integers
	# (entity ids, hashes, packed cell keys) into its serialize().
	world.run(25)
	var state: Dictionary = world.state()
	var parsed: Variant = JSON.parse_string(JsonCanon.exact(state))
	assert_not_null(parsed, "state must be valid JSON")

	# 1e-12 relative: Godot writes 17 decimal PLACES, so a value near 1e-3 keeps
	# ~14 significant digits. Anything drifting further than that is a real loss.
	var drifted: PackedStringArray = PackedStringArray()
	for entry: String in JsonCanon.diff(state, parsed, PackedStringArray(), 60, 1.0e-12):
		if not entry.begins_with("$.rng."):
			drifted.append(entry)
	assert_empty(drifted, "a field outside $.rng no longer survives state.json")

	var without_rng: PackedStringArray = PackedStringArray(["rng"])
	assert_eq(_key_shape(JsonCanon.strip(state, without_rng), "$"),
		_key_shape(JsonCanon.strip(parsed, without_rng), "$"),
		"no key is lost writing state.json")


## Every key path in a structure, sorted. Compares shape without comparing the
## float values, which a JSON round trip is allowed to nudge in the last bits.
func _key_shape(value: Variant, path: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	match typeof(value):
		TYPE_DICTIONARY:
			var d: Dictionary = value
			var keys: Array = d.keys()
			keys.sort_custom(func(a: Variant, b: Variant) -> bool: return String(a) < String(b))
			for k: Variant in keys:
				out.append("%s.%s" % [path, k])
				out.append_array(_key_shape(d[k], "%s.%s" % [path, k]))
		TYPE_ARRAY:
			var a: Array = value
			for i: int in range(a.size()):
				out.append_array(_key_shape(a[i], "%s[%d]" % [path, i]))
		TYPE_INT, TYPE_FLOAT:
			# JSON has one number type; int vs float is not a shape difference.
			out.append("%s:number" % path)
		_:
			out.append("%s:%s" % [path, type_string(typeof(value))])
	return out


func test_state_json_is_idempotent_once_it_has_been_read_back() -> void:
	# Godot's full-precision JSON writes 17 decimal PLACES, not 17 significant
	# digits, and JSON.parse turns every number into a double. The determinism
	# tripwire compares two files that both went through that path, so what it
	# needs is not losslessness but a fixed point: reading and rewriting must
	# never change the bytes again, or every replay would report phantom drift.
	world.run(120)
	var first_write: String = JsonCanon.exact(world.state())
	var second_write: String = JsonCanon.exact(JSON.parse_string(first_write))
	var third_write: String = JsonCanon.exact(JSON.parse_string(second_write))
	assert_eq(third_write, second_write, "write→read→write must be stable")


# --- Log ---------------------------------------------------------------------

func test_log_respects_its_level_filter() -> void:
	var chatter: Callable = func() -> void:
		Log.debug("p00", "invisible")
		Log.info("p00", "visible")
	var captured: PackedStringArray = TestEnv.capture_log(chatter, TestEnv.LOG_INFO)
	assert_eq(captured.size(), 1, "DEBUG is below INFO and must be dropped")
	assert_has(captured[0], "visible")


func test_log_lines_carry_level_tick_and_tag() -> void:
	world.run(5)
	var one: Callable = func() -> void: Log.warn("p00", "cold snap")
	var captured: PackedStringArray = TestEnv.capture_log(one, TestEnv.LOG_WARN)
	assert_eq(captured.size(), 1)
	assert_has(captured[0], "[WARN]")
	assert_has(captured[0], "[t000005]")
	assert_has(captured[0], "[p00]")
	assert_has(captured[0], "cold snap")


func test_drain_empties_the_buffer() -> void:
	var one: Callable = func() -> void: Log.error("p00", "once")
	assert_eq(TestEnv.capture_log(one, TestEnv.LOG_ERROR).size(), 1)
	var nothing: Callable = func() -> void: pass
	assert_empty(TestEnv.capture_log(nothing, TestEnv.LOG_ERROR), "drain is destructive")


# --- Registry ----------------------------------------------------------------

func test_registry_is_loaded_and_iterates_in_sorted_order() -> void:
	assert_true(Registry.loaded, "Registry scans at boot")
	for category: String in Registry.categories():
		var ids: Array[StringName] = Registry.ids(category)
		var sorted_ids: Array = ids.duplicate()
		sorted_ids.sort()
		assert_eq(ids, sorted_ids, "category '%s' must iterate deterministically" % category)
		assert_eq(Registry.all(category).size(), ids.size(),
			"all() and ids() must agree for '%s'" % category)


func test_registry_lookups_of_absent_ids_are_safe() -> void:
	assert_false(Registry.has("buildings", &"a_building_that_never_existed"))
	assert_null(Registry.get_item("buildings", &"a_building_that_never_existed"))
	assert_empty(Registry.all("a_category_that_never_existed"))


func test_registered_ids_match_their_resource_id_field() -> void:
	for category: String in Registry.categories():
		for id: StringName in Registry.ids(category):
			var res: Resource = Registry.get_item(category, id)
			assert_not_null(res, "%s/%s resolves" % [category, id])
			if res != null and "id" in res:
				var declared: String = String(res.get("id"))
				if declared != "":
					assert_eq(declared, String(id),
						"%s/%s is indexed under a different id than it declares" % [category, id])


# --- determinism of the world itself -----------------------------------------

func test_two_worlds_with_the_same_seed_are_identical() -> void:
	var diff: PackedStringArray = SimFixture.replay_diff(20260813, 200)
	assert_empty(diff, "same seed, same run — this is the rule the whole project rests on")


func test_a_scripted_run_replays_identically() -> void:
	var script: Dictionary = {
		40: [{"system": "climate", "op": "skip_to_phase", "phase": "dusk"}],
		120: [{"system": "climate", "op": "force_storm", "intensity": 0.8, "duration_ticks": 400}],
	}
	var diff: PackedStringArray = SimFixture.replay_diff(31337, 300, script)
	assert_empty(diff, "commands must not introduce order-dependent state")


func test_a_different_seed_actually_changes_the_world() -> void:
	# The inverse guard: a determinism check that passes because nothing ever
	# varies is worthless.
	if Sim.systems.is_empty():
		skip("no sim systems built yet — nothing can vary")
		return
	var a: Dictionary = SimFixture.replay(1001, 300)
	var b: Dictionary = SimFixture.replay(2002, 300)
	assert_not_empty(JsonCanon.diff(a, b), "two different seeds produced the identical world")
