extends TestCase
## [P07] The two properties that decide whether this part ships: it stays inside
## the tick budget with a real siege on the map, and it replays byte-identically.
##
## The performance assertion is deliberately loose (a 10x regression fails, a 20%
## one does not) because twelve agents share this machine, but the MEASURED number
## goes into the failure message either way, so a regression is legible even when
## the gate stays green.

const BODIES: int = 600
const MEASURE_TICKS: int = 60
## Hard ceiling per tick, in microseconds. The design target is 2000; this is the
## point at which the part is broken rather than merely slow.
const CEILING_US: int = 12000

var world: SimFixture = null
var combat: CombatSystem = null


func requires_systems() -> PackedStringArray:
	return PackedStringArray(["combat", "grid"])


func setup() -> void:
	world = SimFixture.new(11).start()
	combat = world.system(&"combat") as CombatSystem
	if combat != null:
		combat.director.enabled = false
	var threat: SimSystem = world.system(&"threat")
	if threat != null:
		threat.enabled = false


func teardown() -> void:
	if world != null:
		world.stop()


# --- performance --------------------------------------------------------------

func test_six_hundred_bodies_stay_inside_the_tick_budget() -> void:
	var grid: GridSystem = world.system(&"grid") as GridSystem
	var core: Vector2i = grid.core_cell()
	var placed: int = 0
	# Spread them over four approaches so the spatial index and the flow field are
	# both doing real work rather than answering one bucket.
	for k: int in range(4):
		var a: float = float(k) * TAU / 4.0
		var at := Vector2i(core.x + int(cos(a) * 40.0), core.y + int(sin(a) * 40.0))
		placed += combat.spawn(&"drift_hound", grid.world().nearest_walkable(at, 40), 90)
		placed += combat.spawn(&"hoarfrost_breaker", grid.world().nearest_walkable(at, 40), 20)
		placed += combat.spawn(&"pale_stalker", grid.world().nearest_walkable(at, 40), 20)
		placed += combat.spawn(&"cinder_leech", grid.world().nearest_walkable(at, 40), 20)
	assert_ge(float(placed), float(BODIES), "the field is genuinely full")

	world.run(5)   # let the siege surface and the buckets warm up
	var worst: int = 0
	var total: int = 0
	for _i: int in range(MEASURE_TICKS):
		world.run(1)
		var us: int = combat.last_step_usec()
		total += us
		worst = maxi(worst, us)
	var mean: float = float(total) / float(MEASURE_TICKS)
	assert_lt(mean, float(CEILING_US),
		"%d bodies: mean %.2f ms/tick, worst %.2f ms (design target 2.00 ms, budget 50.00 ms)"
		% [combat.enemies_alive(), mean / 1000.0, float(worst) / 1000.0])
	Log.info("combat", "PERF %d bodies: mean %.2f ms/tick, worst %.2f ms" % [
		combat.enemies_alive(), mean / 1000.0, float(worst) / 1000.0])


func test_an_empty_field_costs_almost_nothing() -> void:
	world.run(40)
	var total: int = 0
	for _i: int in range(MEASURE_TICKS):
		world.run(1)
		total += combat.last_step_usec()
	var mean: float = float(total) / float(MEASURE_TICKS)
	assert_lt(mean, 900.0,
		"with no enemies combat costs %.3f ms/tick — it must be nearly free" % (mean / 1000.0))
	assert_false(combat.assault.ready,
		"and the siege surface was never built, because nothing needed it")


# --- determinism --------------------------------------------------------------

func test_a_scripted_siege_replays_byte_identically() -> void:
	var script: Dictionary = {
		20: [{"system": "combat", "op": "spawn", "kind": "drift_hound", "count": 24, "lane": 0}],
		40: [{"system": "combat", "op": "spawn", "kind": "hoarfrost_breaker", "count": 4, "lane": 1}],
		60: [{"system": "combat", "op": "spawn", "kind": "cinder_leech", "count": 8, "lane": 2}],
		80: [{"system": "combat", "op": "spawn_wave", "strength": 1.5, "lane": 3}],
		140: [{"system": "combat", "op": "spawn", "kind": "the_long_cold", "count": 1, "lane": 0}],
	}
	var diff: PackedStringArray = SimFixture.replay_diff(4242, 400, script, 12)
	assert_empty(diff, "two runs of the same seed and the same siege agree exactly")


func test_the_spawn_scatter_never_consumes_the_random_stream() -> void:
	# Body scatter is hashed off the enemy id on purpose: an Rng draw inside a
	# spawn loop would make every later roll depend on how many bodies a wave
	# happened to contain.
	var rng: RandomNumberGenerator = Rng.stream("combat_waves")
	var before: int = rng.state
	combat.spawn(&"drift_hound", world.system(&"grid").call("core_cell"), 40)
	assert_eq(rng.state, before, "spawning drew nothing from the wave stream")


# --- state --------------------------------------------------------------------

func test_serialize_round_trips_a_live_siege() -> void:
	var grid: GridSystem = world.system(&"grid") as GridSystem
	var core: Vector2i = grid.core_cell()
	combat.spawn(&"drift_hound", grid.world().nearest_walkable(core + Vector2i(30, 0), 30), 12)
	combat.spawn(&"ash_spitter", grid.world().nearest_walkable(core + Vector2i(0, 30), 30), 4)
	world.run(30)
	var before: Dictionary = combat.serialize()
	combat.deserialize(before)
	var after: Dictionary = combat.serialize()
	assert_eq(after["enemies"], before["enemies"], "every body survives the round trip")
	assert_eq(after["kills"], before["kills"], "and so do the counters")
	assert_eq(after["wave"], before["wave"])


func test_metrics_report_the_five_numbers_the_brief_asks_for() -> void:
	var m: Dictionary = combat.metrics()
	for key: String in ["enemies_alive", "kills", "damage_taken", "turret_uptime",
			"heat_spent_on_defence"]:
		assert_has(m, key, "metrics carry '%s'" % key)
	for k2: String in m:
		var t: int = typeof(m[k2])
		assert_true(t == TYPE_INT or t == TYPE_FLOAT,
			"metric '%s' is a scalar the CSV can hold" % k2)


func test_state_is_json_safe() -> void:
	combat.spawn(&"keener", world.system(&"grid").call("core_cell"), 2)
	world.run(5)
	var text: String = JSON.stringify(combat.serialize())
	assert_gt(float(text.length()), 40.0, "the state serialises")
	assert_eq(typeof(JSON.parse_string(text)), TYPE_DICTIONARY, "and parses back")
