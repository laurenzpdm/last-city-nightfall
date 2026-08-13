extends TestCase
## [C5] The watchdog, the withdrawal, and the siege surface's cost.
##
## Every test in here defends a property that a real run violated:
##
##   * an enemy born on tick 17036 was still standing on tick 24000 at full
##     health, taking a storage yard apart at four damage a second, because a
##     wave "ending" left [P07]'s bodies exactly where they were;
##   * that one body kept `live` above zero for ever, so no later night could
##     end by "nothing is alive" and `waves_cleared` froze;
##   * nothing anywhere wrote a line about either;
##   * and building the siege surface cost one 83 ms tick — the largest single
##     spike in the build — because it was flooded in a single call.

const HOUND: StringName = &"drift_hound"
const KEENER: StringName = &"keener"

var world: SimFixture = null
var combat: CombatSystem = null


func requires_systems() -> PackedStringArray:
	return PackedStringArray(["combat", "grid"])


func setup() -> void:
	world = SimFixture.new(23).start()
	combat = world.system(&"combat") as CombatSystem
	if combat != null:
		combat.director.enabled = false
	var threat: SimSystem = world.system(&"threat")
	if threat != null:
		threat.enabled = false


func teardown() -> void:
	if world != null:
		world.stop()


func _core() -> Vector2i:
	return world.system(&"grid").call("core_cell")


func _spawn_out(kind: StringName, offset: Vector2i, n: int = 1) -> int:
	var grid: GridSystem = world.system(&"grid") as GridSystem
	return combat.spawn(kind, grid.world().nearest_walkable(_core() + offset, 40), n)


# --- the withdrawal ------------------------------------------------------------

func test_a_withdrawal_empties_the_field() -> void:
	assert_gt(float(_spawn_out(HOUND, Vector2i(26, 0), 5)), 0.0, "bodies are on the map")
	world.run(4)
	var before: int = combat.enemies_alive()
	assert_gt(float(before), 0.0, "and they are counted as fighting")

	var sent: int = combat.withdraw_wave(-1)
	assert_eq(sent, before, "everything on the field was told to break off")
	assert_eq(combat.enemies_alive(), 0,
		"a body that is walking away is not part of the fight any more")
	assert_gt(float(combat.bodies_on_map()), 0.0,
		"but it is still on the map, still visible and still shootable")

	# RETREAT_TICKS is the hard ceiling on how long that can take.
	world.run(EnemySwarm.RETREAT_TICKS + 5)
	assert_eq(combat.bodies_on_map(), 0, "and then it is gone")
	assert_eq(combat.swarm.kills, 0, "leaving is not dying: nobody earned those")
	assert_eq(combat.swarm.withdrawn, before, "they are counted as withdrawn instead")


func test_a_withdrawn_body_stops_fighting_immediately() -> void:
	_spawn_out(HOUND, Vector2i(6, 0), 4)
	world.run(30)
	combat.withdraw_wave(-1)
	var damage_before: float = combat.damage_taken
	world.run(60)
	assert_near(combat.damage_taken, damage_before, 0.001,
		"nothing that has broken off may still be taking the city apart")


func test_a_retreating_body_can_still_be_shot() -> void:
	_spawn_out(HOUND, Vector2i(4, 0), 3)
	world.run(4)
	combat.withdraw_wave(-1)
	var slot: int = 0
	var killed: int = combat.swarm.kills
	combat.swarm.hurt(slot, combat.swarm.e_id[slot], 1000.0,
		CombatTypes.Damage.KINETIC, 100.0, world.tick())
	assert_eq(combat.swarm.kills, killed + 1,
		"a body caught on its way out is a kill the player earned")


# --- the watchdog ---------------------------------------------------------------

func test_a_body_that_does_nothing_at_all_is_eventually_removed() -> void:
	# Pinned in place, no target, nothing shooting it: the exact shape of the
	# failure the campaign froze on, minus the damage that hid it.
	_spawn_out(HOUND, Vector2i(30, 0), 1)
	world.run(2)
	assert_gt(float(combat.bodies_on_map()), 0.0, "one body")
	var pinned: Vector2 = Vector2(combat.swarm.e_x[0], combat.swarm.e_y[0])
	var seen_stall: bool = false
	for _i: int in range((EnemySwarm.STALL_TICKS * EnemySwarm.MAX_STALLS) / 10 + 40):
		if combat.bodies_on_map() > 0:
			# Hold it exactly still. Nothing else in the sim does this; that is
			# the point — it is a synthetic version of a stuck path.
			combat.swarm.e_x[0] = pinned.x
			combat.swarm.e_y[0] = pinned.y
		world.run(10)
		if combat.swarm.stalls > 0:
			seen_stall = true
		if combat.enemies_alive() == 0:
			break
	assert_true(seen_stall, "the watchdog noticed it")
	assert_gt(float(combat.swarm.stalls_resolved), 0.0, "and it resolved it")
	assert_eq(combat.enemies_alive(), 0, "a body that is going nowhere does not stay for ever")


func test_the_watchdog_says_so_out_loud() -> void:
	# Silence is what made the original bug survive a full phase of the build.
	_spawn_out(HOUND, Vector2i(30, 0), 1)
	world.run(2)
	var pinned: Vector2 = Vector2(combat.swarm.e_x[0], combat.swarm.e_y[0])
	for _i: int in range(EnemySwarm.STALL_TICKS / 10 + 12):
		if combat.bodies_on_map() > 0:
			combat.swarm.e_x[0] = pinned.x
			combat.swarm.e_y[0] = pinned.y
		world.run(10)
	assert_gt(float(combat.swarm.stalls), 0.0, "the watchdog fired")
	assert_gt(float(Log.warnings), 0.0, "and it reached the log rather than a counter")


func test_a_body_under_fire_is_never_called_stalled() -> void:
	# A pack held at a chokepoint by a working wall is the game working. The
	# watchdog must not pull it off the map for standing still.
	_spawn_out(HOUND, Vector2i(30, 0), 1)
	world.run(2)
	var pinned: Vector2 = Vector2(combat.swarm.e_x[0], combat.swarm.e_y[0])
	for _i: int in range(EnemySwarm.STALL_TICKS / 5):
		if combat.bodies_on_map() == 0:
			break
		combat.swarm.e_x[0] = pinned.x
		combat.swarm.e_y[0] = pinned.y
		# One scratch a second: it is being fought, not stuck.
		combat.swarm.hurt(0, combat.swarm.e_id[0], 0.05,
			CombatTypes.Damage.KINETIC, 0.0, world.tick())
		world.run(5)
	assert_eq(combat.swarm.stalls, 0,
		"being shot at is not being stuck, and the watchdog must know the difference")


func test_nothing_outlives_the_hard_lifetime() -> void:
	# The last line of defence: whatever a body is doing, however much damage it
	# is dealing, it does not live past MAX_LIFE_TICKS.
	assert_gt(float(EnemySwarm.MAX_LIFE_TICKS), 0.0, "there is a ceiling at all")
	_spawn_out(HOUND, Vector2i(3, 0), 1)
	world.run(4)
	if combat.bodies_on_map() == 0:
		skip("the body reached the core and leaked before it could be aged")
		return
	# Age it by hand rather than running six real minutes of simulation.
	combat.swarm.e_born[0] = world.tick() - EnemySwarm.MAX_LIFE_TICKS - 1
	combat.swarm.e_prog[0] = world.tick()
	world.run(EnemySwarm.THINK_PERIOD + 2)
	assert_eq(combat.enemies_alive(), 0, "past its lifetime it is not this campaign's problem")


# --- the siege surface ----------------------------------------------------------

func test_the_siege_surface_is_prepared_in_slices() -> void:
	var field := AssaultField.new()
	var grid: SimSystem = world.system(&"grid")
	assert_true(field.begin(grid), "preparation starts")
	assert_false(field.ready, "and it is NOT usable on the tick it started")
	assert_true(field.building, "it says it is working")
	var slices: int = 0
	while not field.advance() and slices < 4000:
		slices += 1
	assert_true(field.ready, "it finishes")
	assert_gt(float(slices), 4.0,
		"and it took real slices to get there — one call is the 83 ms tick this replaced")


func test_the_sliced_surface_agrees_with_the_synchronous_one() -> void:
	# Paying for a flood over several ticks may not change a single answer.
	var grid: SimSystem = world.system(&"grid")
	var whole := AssaultField.new()
	assert_true(whole.build(grid), "the synchronous surface builds")
	var sliced := AssaultField.new()
	assert_true(sliced.begin(grid), "the sliced one starts")
	var guard: int = 0
	while not sliced.advance() and guard < 4000:
		guard += 1
	assert_true(sliced.ready, "and finishes")
	assert_eq(sliced.cost, whole.cost, "the same movement costs, cell for cell")
	assert_eq(sliced.field.integration, whole.field.integration,
		"and the same travel cost to the hearth from every tile")


func test_a_body_that_arrives_before_the_surface_still_gets_one() -> void:
	# The fallback: nothing may walk on a map with no surface under it.
	assert_false(combat.assault.ready, "nothing built it yet")
	_spawn_out(HOUND, Vector2i(20, 0), 2)
	assert_true(combat.assault.ready,
		"a spawn with no prepared surface builds one synchronously rather than pathing blind")


# --- the numbers other parts read ------------------------------------------------

func test_the_defence_report_separates_armed_from_engaged() -> void:
	var r: Dictionary = combat.defence_report()
	for key: String in ["turrets", "armed", "cold", "uptime", "engaged",
			"engaged_ticks", "live_ticks", "shots"]:
		assert_has(r, key, "the defence report carries '%s'" % key)
	assert_between(float(r["engaged"]), 0.0, 1.0, "engagement is a fraction")


func test_metrics_carry_the_watchdog_counters() -> void:
	var m: Dictionary = combat.metrics()
	for key: String in ["stalls", "withdrawn", "shots_fired", "turret_engaged", "bodies"]:
		assert_has(m, key, "metrics carry '%s' so a stall can never be invisible again" % key)


func test_state_round_trips_a_retreating_body() -> void:
	_spawn_out(HOUND, Vector2i(20, 0), 3)
	world.run(6)
	combat.withdraw_wave(-1)
	world.run(2)
	var before: Dictionary = combat.serialize()
	combat.deserialize(before)
	var after: Dictionary = combat.serialize()
	assert_eq(after["enemies"], before["enemies"], "a body walking away survives a save")
	assert_eq(after["withdrawn"], before["withdrawn"], "and so does the tally")
