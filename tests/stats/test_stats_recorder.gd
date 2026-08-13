extends TestCase
## [P20] The recorder, against a real world. Does it see the simulation, does it
## account for consumption honestly, and does it stay inside its share of the
## tick budget?
##
## The cost assertion is the one that matters. A statistics screen that records
## everything and costs a millisecond a tick has taken 2 % of the frame budget
## away from the game to draw a chart nobody has opened, and the whole design of
## this part — three resolutions, a slow lane for the expensive reads, a modulo
## before anything else — exists to make that number small enough to ignore.


var world: SimFixture


func suite_name() -> String:
	return "stats_recorder"


func requires_systems() -> PackedStringArray:
	return PackedStringArray(["heat", "climate", "society", "production"])


func before_all() -> void:
	world = SimFixture.new(7).start()
	# The city a player is handed on launch, through the same command path.
	var boot: Script = load("res://game/boot.gd") as Script
	if boot != null:
		for cmd: Dictionary in boot.call("opening_commands", _core_cell()):
			world.cmd(cmd)
	world.run(200)


func after_all() -> void:
	world.stop()


func setup() -> void:
	world.ensure()


# ============================================================== it records ===

func test_it_binds_to_the_world_and_declares_every_series() -> void:
	var rec := LcnStatsRecorder.new()
	rec.bind()
	assert_true(rec.bound, "the recorder found a world to read")
	assert_true(rec.items.size() >= 5,
		"it took the item list off the recipe graph (%d items)" % rec.items.size())
	for key: StringName in LcnStatsDefs.ordered_keys():
		assert_true(rec.fine.has(key), "the fine track carries %s" % key)
		assert_true(rec.run.has(key), "and so does the whole-run track")
	for item: StringName in rec.items:
		assert_true(rec.fine.has(LcnStatsDefs.produced_key(item)),
			"%s has a production series" % item)
		assert_true(rec.fine.has(LcnStatsDefs.consumed_key(item)),
			"%s has a consumption series" % item)


func test_it_samples_all_three_resolutions_at_their_own_stride() -> void:
	var rec := LcnStatsRecorder.new()
	rec.bind()
	for t: int in range(1, 2001):
		world.run(1)
		rec.on_tick(world.tick())
	assert_eq(rec.fine.sample_count(), 200, "one fine sample every ten ticks")
	assert_eq(rec.mid.sample_count(), 20, "one mid sample every hundred")
	assert_eq(rec.run.sample_count(), 5, "one run sample every four hundred")
	assert_true(rec.fine.latest_tick > 0, "and the newest sample knows its tick")


func test_the_readings_are_the_simulation_s_own_numbers() -> void:
	var rec := LcnStatsRecorder.new()
	rec.bind()
	for _i: int in 400:
		world.run(1)
		rec.on_tick(world.tick())
	var heat: SimSystem = world.system(&"heat")
	var totals: Dictionary = heat.call("totals")
	assert_near(rec.latest(&"heat_demand"), float(totals["demand"]), 0.51,
		"the recorded demand is the grid's own demand")
	assert_true(rec.latest(&"heat_demand") > 0.0,
		"a city with radiators in it is asking for heat")
	var climate: SimSystem = world.system(&"climate")
	assert_near(rec.latest(&"temperature"), float(climate.call("ambient_temperature")), 0.6,
		"and the temperature is the plain's own")
	assert_true(rec.latest(&"pop") > 0.0, "somebody is alive to be counted")


func test_a_flag_series_is_zero_or_one_and_nothing_else() -> void:
	var rec := LcnStatsRecorder.new()
	rec.bind()
	for _i: int in 600:
		world.run(1)
		rec.on_tick(world.tick())
	var night: LcnStatSeries = rec.fine.series(&"night")
	for i: int in night.size():
		var v: float = night.at(i)
		assert_true(v == 0.0 or v == 1.0, "sample %d of the night flag is 0 or 1" % i)


# ========================================================= it costs nothing ==

func test_the_recording_cost_stays_inside_its_budget() -> void:
	var rec := LcnStatsRecorder.new()
	rec.bind()
	for _i: int in 3000:
		world.run(1)
		rec.on_tick(world.tick())
	var us: float = rec.microseconds_per_tick()
	# Printed as well as asserted: a budget you cannot see the headroom on is a
	# budget you will cross without noticing.
	Log.info("stats-tests", "recorder: %.1f us/tick amortised, %.1f us/sample, %d samples, %.0f KB" % [
		us, rec.microseconds_per_sample(), rec.sample_count(),
		float(rec.memory_bytes()) / 1024.0])
	assert_true(us < LcnStatsRecorder.BUDGET_US_PER_TICK,
		"recording costs %.1f us a tick against a %.0f us budget" % [
			us, LcnStatsRecorder.BUDGET_US_PER_TICK])
	assert_true(rec.memory_bytes() < 400000,
		"the whole history is under 400 KB (%d bytes)" % rec.memory_bytes())


func test_the_whole_run_track_covers_an_unbounded_run_in_bounded_memory() -> void:
	var rec := LcnStatsRecorder.new()
	rec.bind()
	var before: int = rec.run.memory_bytes()
	# Far past the run track's capacity, so it has to halve more than once.
	for _i: int in 400:
		world.run(LcnStatsRecorder.RUN_STRIDE)
		rec.on_tick(world.tick())
	assert_true(rec.run.halvings >= 1,
		"the run track halved rather than forgetting the beginning (%d)" % rec.run.halvings)
	assert_eq(rec.run.memory_bytes(), before, "and it costs exactly what it did before")
	assert_true(rec.run.tick_at(0) <= rec.fine.tick_at(0),
		"the whole-run track still reaches further back than the fine one")


# ======================================================== the consumption ====

func test_consumption_is_counted_from_the_crafts_a_machine_actually_finished() -> void:
	var rec := LcnStatsRecorder.new()
	var prod := _FakeProduction.new()
	rec.bind({&"production": prod})
	assert_eq(rec.items.size(), 2, "the fake graph has two items")

	rec.on_tick(10)
	prod.machine.crafts_done = 5      # 5 crafts of 2 iron_ore -> 1 iron_plate
	prod.produced[&"iron_plate"] = 5
	rec.on_tick(20)
	assert_near(rec.latest(LcnStatsDefs.consumed_key(&"iron_ore")), 10.0, 0.01,
		"five crafts of a two-ore recipe ate ten ore")
	assert_near(rec.latest(LcnStatsDefs.produced_key(&"iron_plate")), 5.0, 0.01,
		"and made five plates")


func test_a_recipe_switch_drops_its_crafts_instead_of_misattributing_them() -> void:
	# Half a gear is not half a circuit, and it is certainly not two iron plates.
	# Attributing a switched machine's backlog to whichever recipe it holds now
	# would send a player hunting a shortage that does not exist.
	var rec := LcnStatsRecorder.new()
	var prod := _FakeProduction.new()
	rec.bind({&"production": prod})
	rec.on_tick(10)
	prod.machine.crafts_done = 4
	prod.machine.recipe_id = &"something_else"
	prod.machine.recipe = _FakeRecipe.new({&"iron_ore": 99})
	rec.on_tick(20)
	assert_near(rec.latest(LcnStatsDefs.consumed_key(&"iron_ore")), 0.0, 0.01,
		"the crafts that straddled the switch are dropped")
	prod.machine.crafts_done = 6
	rec.on_tick(30)
	assert_near(rec.latest(LcnStatsDefs.consumed_key(&"iron_ore")), 198.0, 0.01,
		"and the next two crafts are counted against the new recipe")


func test_consumption_only_ever_goes_up() -> void:
	var rec := LcnStatsRecorder.new()
	var prod := _FakeProduction.new()
	rec.bind({&"production": prod})
	rec.on_tick(10)
	prod.machine.crafts_done = 3
	rec.on_tick(20)
	# A machine demolished and its id reused with a lower count must not be able
	# to drive a differenced rate negative.
	prod.machine.crafts_done = 1
	rec.on_tick(30)
	var s: LcnStatSeries = rec.fine.series(LcnStatsDefs.consumed_key(&"iron_ore"))
	for i: int in range(1, s.size()):
		assert_true(s.at(i) >= s.at(i - 1) - 0.0001,
			"consumption sample %d did not go backwards" % i)


# ================================================================ fixtures ===

func _core_cell() -> Vector2i:
	var grid: SimSystem = world.system(&"grid")
	if grid != null and grid.has_method("core_cell"):
		return grid.call("core_cell")
	return Vector2i(128, 128)


class _FakeRecipe extends RefCounted:
	var inputs: Dictionary[StringName, int] = {}

	func _init(items: Dictionary) -> void:
		for k: Variant in items:
			inputs[StringName(String(k))] = int(items[k])


class _FakeMachine extends RefCounted:
	var crafts_done: int = 0
	var recipe_id: StringName = &"iron_plate"
	var recipe: RefCounted = null


class _FakeBook extends RefCounted:
	var items: Array[StringName] = [&"iron_ore", &"iron_plate"]


class _FakeStore extends RefCounted:
	func count(_item: StringName) -> int:
		return 0


## The smallest object the recorder will accept as [ProductionSystem].
class _FakeProduction extends RefCounted:
	var machines: Dictionary[int, RefCounted] = {}
	var book: RefCounted = _FakeBook.new()
	var store: RefCounted = _FakeStore.new()
	var produced: Dictionary[StringName, int] = {}
	var machine: _FakeMachine = null

	func _init() -> void:
		machine = _FakeMachine.new()
		machine.recipe = _FakeRecipe.new({&"iron_ore": 2})
		machines[1] = machine

	func produced_total(item: StringName) -> int:
		return int(produced.get(item, 0))

	func totals() -> Dictionary:
		return {"active": 1, "stalled": 0, "crafts": machine.crafts_done}

	func stalled_machines() -> Array[Dictionary]:
		return []
