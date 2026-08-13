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
##
## One recorded pass over a real city is shared by every assertion below. A
## suite that creates a world per test spends its life in worldgen, and the gate
## has nineteen other parts queued behind it.

## Ticks of real simulation the shared pass records. Two minutes of world time:
## long enough for all three tracks to fill and for the numbers to be honest,
## short enough that the gate does not notice.
const RECORDED_TICKS: int = 3000

var world: SimFixture
var rec: LcnStatsRecorder = null


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

	rec = LcnStatsRecorder.new()
	rec.bind()
	for _i: int in RECORDED_TICKS:
		world.run(1)
		rec.on_tick(world.tick())


func after_all() -> void:
	world.stop()


# ============================================================== it records ===

func test_it_binds_to_the_world_and_declares_every_series() -> void:
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
		assert_true(rec.fine.has(LcnStatsDefs.stock_key(item)),
			"%s has a stock series" % item)


func test_it_samples_all_three_resolutions_at_their_own_stride() -> void:
	assert_eq(rec.fine.sample_count(),
		mini(LcnStatsRecorder.FINE_CAP, RECORDED_TICKS / LcnStatsRecorder.FINE_STRIDE),
		"one fine sample every ten ticks, up to its capacity")
	assert_eq(rec.mid.sample_count(), RECORDED_TICKS / LcnStatsRecorder.MID_STRIDE,
		"one mid sample every hundred ticks")
	assert_eq(rec.run.sample_count(),
		1 + (RECORDED_TICKS - LcnStatsRecorder.FINE_STRIDE) / LcnStatsRecorder.RUN_STRIDE,
		"one run sample every four hundred, from the first tick recorded")
	assert_true(rec.fine.latest_tick >= RECORDED_TICKS - LcnStatsRecorder.FINE_STRIDE,
		"and the newest sample is the one just taken")
	assert_true(rec.run.tick_at(0) < rec.fine.tick_at(0),
		"the coarse track reaches further back than the fine one once the fine "
		+ "window has slid (run %d, fine %d)" % [rec.run.tick_at(0), rec.fine.tick_at(0)])


func test_the_readings_are_the_simulation_s_own_numbers() -> void:
	var heat: SimSystem = world.system(&"heat")
	var totals: Dictionary = heat.call("totals")
	assert_near(rec.latest(&"heat_demand"), float(totals["demand"]), 1.0,
		"the recorded demand is the grid's own demand")
	assert_true(rec.latest(&"heat_demand") > 0.0,
		"a city with radiators in it is asking for heat")
	assert_true(rec.latest(&"heat_supply") > 0.0, "and a lit hearth is supplying it")
	var climate: SimSystem = world.system(&"climate")
	assert_near(rec.latest(&"temperature"), float(climate.call("ambient_temperature")), 1.0,
		"and the temperature is the plain's own")
	assert_true(rec.latest(&"pop") > 0.0, "somebody is alive to be counted")
	assert_true(rec.latest(&"buildings") > 5.0,
		"the opening settlement was counted (%.0f)" % rec.latest(&"buildings"))


func test_a_flag_series_is_zero_or_one_and_nothing_else() -> void:
	var night: LcnStatSeries = rec.fine.series(&"night")
	assert_true(night.size() > 0, "the night flag was recorded")
	for i: int in night.size():
		var v: float = night.at(i)
		assert_true(v == 0.0 or v == 1.0, "sample %d of the night flag is 0 or 1" % i)


func test_every_counter_series_is_monotonic() -> void:
	# A differenced rate that can go negative is a graph that tells the player
	# the factory un-made a plate.
	for key: StringName in LcnStatsDefs.ordered_keys():
		if LcnStatsDefs.kind_of(key) != LcnStatsDefs.Kind.COUNTER:
			continue
		var s: LcnStatSeries = rec.fine.series(key)
		assert_true(s.is_monotonic(), "%s is declared as a counter" % key)
		for i: int in range(1, s.size()):
			assert_true(s.at(i) >= s.at(i - 1) - 0.0001,
				"%s never went backwards (sample %d)" % [key, i])


# ========================================================= it costs nothing ==

func test_the_recording_cost_stays_inside_its_budget() -> void:
	var us: float = rec.microseconds_per_tick()
	# Printed as well as asserted: a budget you cannot see the headroom on is a
	# budget you will cross without noticing.
	Log.info("stats-tests", "recorder: %.1f us/tick amortised, %.1f us/sample, %d samples, %.0f KB" % [
		us, rec.microseconds_per_sample(), rec.sample_count(),
		float(rec.memory_bytes()) / 1024.0])
	print("  recorder: %.1f us/tick amortised over %d ticks, %.1f us/sample, %.0f KB" % [
		us, RECORDED_TICKS, rec.microseconds_per_sample(),
		float(rec.memory_bytes()) / 1024.0])
	assert_true(us < LcnStatsRecorder.BUDGET_US_PER_TICK,
		"recording costs %.1f us a tick against a %.0f us budget" % [
			us, LcnStatsRecorder.BUDGET_US_PER_TICK])
	assert_true(rec.memory_bytes() < 400000,
		"the whole history is under 400 KB (%d bytes)" % rec.memory_bytes())


func test_the_whole_run_track_covers_an_unbounded_run_in_bounded_memory() -> void:
	# Driven with synthetic ticks against the live world: what is under test is
	# the track's own arithmetic, and simulating three hours to prove it would
	# cost the gate three minutes.
	var solo := LcnStatsRecorder.new()
	solo.bind()
	var before: int = solo.run.memory_bytes()
	var last: int = LcnStatsRecorder.RUN_STRIDE * (LcnStatsRecorder.RUN_CAP * 4)
	for t: int in range(LcnStatsRecorder.FINE_STRIDE, last, LcnStatsRecorder.FINE_STRIDE):
		solo.on_tick(t)
	assert_true(solo.run.halvings >= 2,
		"the run track halved twice rather than forgetting the beginning (%d)" % solo.run.halvings)
	assert_eq(solo.run.memory_bytes(), before, "and it costs exactly what it did before")
	assert_eq(solo.run.tick_at(0), LcnStatsRecorder.FINE_STRIDE,
		"the first sample of the run is still the first sample of the run")
	assert_true(solo.run.stride >= LcnStatsRecorder.RUN_STRIDE * 4,
		"at four times the stride it started with")
	assert_true(solo.run.sample_count() <= LcnStatsRecorder.RUN_CAP,
		"and never more samples than it has room for")


# ======================================================== the consumption ====

func test_consumption_is_counted_from_the_crafts_a_machine_actually_finished() -> void:
	var solo := LcnStatsRecorder.new()
	var prod := _FakeProduction.new()
	solo.bind({&"production": prod})
	assert_eq(solo.items.size(), 2, "the fake graph has two items")

	solo.on_tick(10)
	prod.machine.crafts_done = 5      # 5 crafts of 2 iron_ore -> 1 iron_plate
	prod.produced[&"iron_plate"] = 5
	solo.on_tick(20)
	assert_near(solo.latest(LcnStatsDefs.consumed_key(&"iron_ore")), 10.0, 0.01,
		"five crafts of a two-ore recipe ate ten ore")
	assert_near(solo.latest(LcnStatsDefs.produced_key(&"iron_plate")), 5.0, 0.01,
		"and made five plates")


func test_a_recipe_switch_drops_its_crafts_instead_of_misattributing_them() -> void:
	# Half a gear is not half a circuit, and it is certainly not two iron plates.
	# Attributing a switched machine's backlog to whichever recipe it holds now
	# would send a player hunting a shortage that does not exist.
	var solo := LcnStatsRecorder.new()
	var prod := _FakeProduction.new()
	solo.bind({&"production": prod})
	solo.on_tick(10)
	prod.machine.crafts_done = 4
	prod.machine.recipe_id = &"something_else"
	prod.machine.recipe = _FakeRecipe.new({&"iron_ore": 99})
	solo.on_tick(20)
	assert_near(solo.latest(LcnStatsDefs.consumed_key(&"iron_ore")), 0.0, 0.01,
		"the crafts that straddled the switch are dropped")
	prod.machine.crafts_done = 6
	solo.on_tick(30)
	assert_near(solo.latest(LcnStatsDefs.consumed_key(&"iron_ore")), 198.0, 0.01,
		"and the next two crafts are counted against the new recipe")


func test_consumption_only_ever_goes_up() -> void:
	var solo := LcnStatsRecorder.new()
	var prod := _FakeProduction.new()
	solo.bind({&"production": prod})
	solo.on_tick(10)
	prod.machine.crafts_done = 3
	solo.on_tick(20)
	# A machine demolished and its id reused with a lower count must not be able
	# to drive a differenced rate negative.
	prod.machine.crafts_done = 1
	solo.on_tick(30)
	var s: LcnStatSeries = solo.fine.series(LcnStatsDefs.consumed_key(&"iron_ore"))
	for i: int in range(1, s.size()):
		assert_true(s.at(i) >= s.at(i - 1) - 0.0001,
			"consumption sample %d did not go backwards" % i)


func test_the_ledger_forgets_machines_that_no_longer_exist() -> void:
	var solo := LcnStatsRecorder.new()
	var prod := _FakeProduction.new()
	solo.bind({&"production": prod})
	for i: int in 40:
		prod.machines[100 + i] = _FakeMachine.new()
	solo.on_tick(10)
	for i2: int in 40:
		prod.machines.erase(100 + i2)
	solo.on_tick(LcnStatsRecorder.PRUNE_EVERY + 10)
	assert_eq(solo.ledger_size(), 1,
		"a city that rebuilds for ten hours does not leave ten hours of dead ids behind")


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
