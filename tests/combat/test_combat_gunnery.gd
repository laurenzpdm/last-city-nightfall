extends TestCase
## [P07] CAN THE GUNS HIT ANYTHING THAT IS NOT RUNNING?
##
## A projectile is aimed once, at the muzzle, at `target_pos + velocity × flight
## × lead_factor`, and it counts as a hit only within `body_radius + 6px` of the
## target — about half a tile. So the aim is only as good as the velocity the
## swarm reports, and the swarm reported a body's INTENTION:
##
##     return Vector2(e_hx[slot] * d_speed[d] * (1.0 + e_rally[slot]), ...)
##
## That is heading times TOP speed. It is not multiplied by `e_ground`, the snow
## scale the movement code actually uses, and it is only zeroed for the ATTACKING
## state — so anything that had stopped without attacking still claimed to be
## crossing the ground at full pace: a body pinned against a wall, one sliding
## along an obstacle with both axes zeroed, one wading through drift, and one
## standing at the fire with nothing it is allowed to hit.
##
## The lead error is up to a tile and a half against a hit window of half a tile,
## so the miss is TOTAL rather than partial. In the reference run that read as:
##
##     night 1: 6 spawned, 5 killed, 1 walked away | 869 shot(s), 3128.4 heat
##
## 869 shells and 3128 heat — the whole night's grid — for five drift hounds
## worth 150 hit points, because three of them stood three tiles from the hearth
## for 2600 ticks while the entire wall shot past them and `combat.damage_dealt`
## sat at 0.0. With the velocity honest the same night reads `6 spawned, 6
## killed, 0 walked away | 6 shot(s), 21.6 heat`.
##
## Heat is this build's one shared resource — it is the city's warmth, the
## factory's power and the wall's ammunition at the same time. A gun that misses
## is not a difficulty setting; it is a hole in the player's grid.

const HOUND: StringName = &"drift_hound"
## Ground scale of a body wading rather than running. Any value below 1 makes
## the old expression and the new one disagree; a quarter makes the disagreement
## four times the hit window, which is what the reference run was living with.
const WADING: float = 0.25

var world: SimFixture = null
var combat: CombatSystem = null
var grid: GridSystem = null
var core: Vector2i = Vector2i.ZERO


func requires_systems() -> PackedStringArray:
	return PackedStringArray(["combat", "grid"])


func setup() -> void:
	world = SimFixture.new(23).start()
	combat = world.system(&"combat") as CombatSystem
	grid = world.system(&"grid") as GridSystem
	if combat != null:
		combat.director.enabled = false
	var threat: SimSystem = world.system(&"threat")
	if threat != null:
		threat.enabled = false
	if grid != null:
		core = grid.core_cell()


func teardown() -> void:
	if world != null:
		world.stop()


## Steps until the next tick is one on which slot 0 does NOT think, so a value
## written into e_ground survives into the movement that reads it. The think
## gate is `(i + tick) % THINK_PERIOD == 0`; for slot 0 that is `tick % 10`.
func _settle_to_a_quiet_tick() -> void:
	var guard: int = 0
	while (world.tick() + 1) % EnemySwarm.THINK_PERIOD == 0 and guard < 20:
		world.run(1)
		guard += 1


# ==========================================================================
#  1. THE VELOCITY A GUNNER LEADS BY IS THE GROUND THE BODY COVERED
# ==========================================================================

## Reported velocity must equal OBSERVED displacement over the tick.
##
## The two sides of this assertion are measured independently: one is read out
## of `velocity_at`, the other is the difference between two positions sampled
## before and after the same tick. It is therefore not a restatement of the
## implementation — it would fail just as loudly against a velocity that was
## invented some other way.
##
## RED against `e_hx * d_speed * (1 + rally)`: that ignores `e_ground` entirely,
## so a body wading at a quarter speed covers 1.36 px in a tick and is reported
## as covering 5.44. At burner-cannon range that is 22 px of lead error against
## a 16 px hit window — every shell behind the target, for ever.
func test_reported_velocity_is_the_ground_actually_covered() -> void:
	assert_eq(combat.spawn(HOUND, core + Vector2i(0, 14), 1), 1, "one body on the field")
	world.run(EnemySwarm.THINK_PERIOD + 1)
	_settle_to_a_quiet_tick()

	combat.swarm.e_ground[0] = WADING
	var before: Vector2 = combat.swarm.position_at(0)
	world.run(1)
	var after: Vector2 = combat.swarm.position_at(0)

	var observed: Vector2 = (after - before) / SimClock.DT
	var reported: Vector2 = combat.swarm.velocity_at(0)
	assert_near(reported.x, observed.x, 0.5,
		"the swarm reports vx=%.2f for a body that actually covered %.2f px/s" % [
			reported.x, observed.x])
	assert_near(reported.y, observed.y, 0.5,
		"the swarm reports vy=%.2f for a body that actually covered %.2f px/s" % [
			reported.y, observed.y])

	# And say the same thing the other way round, so a velocity that was zero for
	# the wrong reason cannot pass: the body IS moving, just not at top speed.
	var top: float = combat.swarm.d_speed[combat.swarm.e_def[0]]
	assert_gt(reported.length(), 0.1, "the body is walking; its velocity is not zero")
	assert_lt(reported.length(), top * 0.5,
		"a body on ground worth %.2f of its speed is reported at %.1f px/s of a "
		% [WADING, reported.length()] + "top speed of %.1f — the gunner is leading "
		% top + "it by four times the ground it is covering and every shell lands "
		+ "behind it")


## A body that did not move at all reports that it did not move at all.
##
## RED against the old expression for the same reason, in its worst form: with
## e_ground at zero the body is stationary and was reported at its full 108.8
## px/s, which is where the three hounds standing at the hearth came from.
func test_a_body_that_did_not_move_reports_no_velocity() -> void:
	assert_eq(combat.spawn(HOUND, core + Vector2i(0, 14), 1), 1, "one body on the field")
	world.run(EnemySwarm.THINK_PERIOD + 1)
	_settle_to_a_quiet_tick()

	combat.swarm.e_ground[0] = 0.0
	var before: Vector2 = combat.swarm.position_at(0)
	world.run(1)
	var after: Vector2 = combat.swarm.position_at(0)

	assert_near(before.distance_to(after), 0.0, 0.01,
		"precondition: the body must not have moved this tick")
	assert_near(combat.swarm.velocity_at(0).length(), 0.0, 0.01,
		"a body that covered no ground at all is reported as travelling %.1f px/s; "
		% combat.swarm.velocity_at(0).length() + "every gun in range leads it by "
		+ "that much and misses it for the rest of the night")


## The contract holds for a body walking freely, too — the fix must not have
## bought a stationary target by lying about a moving one.
func test_a_body_at_full_speed_still_reports_full_speed() -> void:
	assert_eq(combat.spawn(HOUND, core + Vector2i(0, 14), 1), 1, "one body on the field")
	world.run(EnemySwarm.THINK_PERIOD + 1)
	_settle_to_a_quiet_tick()

	var before: Vector2 = combat.swarm.position_at(0)
	world.run(1)
	var after: Vector2 = combat.swarm.position_at(0)
	var observed: Vector2 = (after - before) / SimClock.DT
	var reported: Vector2 = combat.swarm.velocity_at(0)
	assert_near(reported.x, observed.x, 0.5, "vx disagrees with the ground covered")
	assert_near(reported.y, observed.y, 0.5, "vy disagrees with the ground covered")
	assert_gt(reported.length(), combat.swarm.d_speed[combat.swarm.e_def[0]] * 0.8,
		"an unobstructed hound on clear ground should be reported at close to its "
		+ "top speed, or the gunner now under-leads a runner")
