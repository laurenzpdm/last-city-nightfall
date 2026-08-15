extends TestCase
## [P07] WHAT A NIGHT TAKES.
##
## The measured build ran three nights and cost the player nothing:
##
##     combat.structures_lost 0
##     combat.breaches        0
##
## Zero across every night means the player is never punished for anything,
## which means nothing they build in the day matters. Frostpunk's nights cost
## you people. This suite is the contract that says ours do too — and, just as
## importantly, that they cost them for a REASON the player can point at: a
## citizen is only ever hurt when a building they were standing in comes down.
##
## The second half of the suite is the counterweight. The same reference run,
## measured to 60000 ticks instead of 24000, loses THE HEARTH on night three at
## t027725 and spends the following thirty thousand ticks as a corpse being
## walked through: population 39 -> 0, `0 shot(s)` on nights four, five and six.
## A night that can end the run by having eight hounds walk past a cold wall and
## stand on the fire is not pressure. The hearth is now a target of last resort,
## and that rule is pinned here.

const HOUND: StringName = &"drift_hound"

var world: SimFixture = null
var combat: CombatSystem = null
var build: BuildSystem = null
var grid: GridSystem = null
var citizens: SimSystem = null
var core: Vector2i = Vector2i.ZERO


func requires_systems() -> PackedStringArray:
	return PackedStringArray(["combat", "build", "grid"])


func setup() -> void:
	world = SimFixture.new(11).start()
	combat = world.system(&"combat") as CombatSystem
	build = world.system(&"build") as BuildSystem
	grid = world.system(&"grid") as GridSystem
	citizens = world.system(&"citizens")
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


func _place(kind: StringName, cell: Vector2i) -> BuildingInstance:
	var res: Dictionary = build.execute({
		"op": &"place", "kind": kind, "cell": [cell.x, cell.y],
		"free": true, "instant": true})
	if not bool(res.get("ok", false)):
		fail("could not place %s at %s: %s" % [kind, str(cell), res.get("reason", "?")])
		return null
	return build.get_building(int(res.get("id", -1)))


## An open spot far enough from the core that a footprint fits.
func _open_cell(offset: Vector2i) -> Vector2i:
	var c: Vector2i = core + offset
	if grid.is_walkable(c):
		return c
	return grid.world().nearest_walkable(c, 30)


# --- the ledger --------------------------------------------------------------

func test_a_night_that_cost_nothing_says_nothing() -> void:
	# The summary is what the morning reads. It must be empty rather than
	# cheerful when the wall held, or a clean night and an expensive one look
	# the same in the one place the player looks.
	assert_eq(combat.night_toll_line(0), "", "no losses, no sentence")
	assert_empty(combat.night_toll(0), "and no rows")


func test_every_structure_lost_writes_itself_down_with_a_place_and_a_tick() -> void:
	var b: BuildingInstance = _place(&"watchtower", _open_cell(Vector2i(9, 0)))
	if b == null:
		return
	var at: int = SimClock.tick
	combat.toll.structure_lost(at, &"watchtower", "Watchtower",
		PackedStringArray(["defense"]), _cells_of(b))
	var rows: Array[Dictionary] = combat.night_toll(0)
	assert_size(rows, 1, "the loss is on the ledger")
	assert_eq(String(rows[0]["kind"]), "watchtower", "by kind")
	assert_eq(int(rows[0]["tick"]), at, "and by the tick it happened on")
	assert_has(combat.night_toll_line(0), "Watchtower",
		"and the morning sentence names it")


func test_the_ledger_is_read_one_night_at_a_time() -> void:
	# [P08] snapshots the tick it went dark and asks for everything after it.
	# Without that filter a quiet night would inherit last night's dead.
	var b: BuildingInstance = _place(&"watchtower", _open_cell(Vector2i(9, 0)))
	if b == null:
		return
	combat.toll.structure_lost(100, &"watchtower", "Watchtower",
		PackedStringArray(), _cells_of(b))
	combat.toll.structure_lost(900, &"watchtower", "Watchtower",
		PackedStringArray(), _cells_of(b))
	assert_size(combat.night_toll(0), 2, "the whole campaign is two rows")
	assert_size(combat.night_toll(500), 1, "tonight is one of them")
	assert_eq(combat.night_toll_line(1000), "", "and a night after both is silent")


# --- the dead have names -------------------------------------------------------

func test_a_building_that_comes_down_on_people_kills_people_by_name() -> void:
	if citizens == null:
		skip("no [P05] in this build to lose")
		return
	# Let the founding population settle onto the map, then take the ground out
	# from under whoever is standing on it.
	world.run(200)
	var before: int = int(citizens.call("population"))
	if before <= 0:
		skip("no citizens on the map to lose")
		return
	var occupied: Array[Vector2i] = _cells_holding_people(24)
	if occupied.is_empty():
		skip("nobody stood still long enough to be caught")
		return

	var row: Dictionary = combat.toll.structure_lost(
		SimClock.tick, &"housing_block", "Housing Block",
		PackedStringArray(["housing"]), occupied)
	var dead: Array = row.get("dead", [])
	var hurt: int = int(row.get("hurt", 0))
	assert_gt(float(dead.size() + hurt), 0.0,
		("a building coming down on %d people must cost at least one of them; "
		+ "this is the whole difference between structures_lost 0 and a night "
		+ "that took something") % occupied.size())
	for name_of_dead: Variant in dead:
		assert_ne(String(name_of_dead), "", "the dead are named, never counted")
		assert_ne(String(name_of_dead), "someone",
			"and the name comes from [P05]'s roster, not from a placeholder")
	if not dead.is_empty():
		assert_lt(float(int(citizens.call("population"))), float(before),
			"and the city is actually smaller afterwards")
		assert_has(combat.night_toll_line(0), "did not come out",
			"the morning sentence says so in words")


func test_nobody_dies_anywhere_a_building_did_not_fall() -> void:
	# The narrow rule, asserted. There is no ambient attrition in this part: a
	# night may not quietly thin the population where the player cannot see it.
	if citizens == null:
		skip("no [P05] in this build")
		return
	world.run(200)
	var before: int = int(citizens.call("population"))
	var dead_before: int = combat.toll.dead_total
	world.run(600)
	assert_eq(combat.toll.dead_total, dead_before,
		"600 ticks of nothing happening costs nobody anything")
	assert_ge(float(int(citizens.call("population"))), float(before),
		"and the population does not drift down on its own")


# --- the hearth falls last ------------------------------------------------------

func test_nothing_chooses_the_hearth_while_anything_else_stands() -> void:
	# t027725: `The Hearth #1 destroyed by frost_shade`, `the hearth has gone
	# out` — on night three of the reference run, with a wall, six turret mounts
	# and forty citizens still on the map. Everything after it was a dead city.
	var seat: Vector2i = _open_cell(Vector2i(-16, -16))
	var hearth: BuildingInstance = _place(&"the_hearth", seat)
	if hearth == null:
		return
	# Seven tiles out from a 5x5 footprint: further from the attacker than the
	# hearth itself, so "nearest" alone would still answer the fire.
	var decoy: BuildingInstance = _place(&"watchtower", seat + Vector2i(7, 0))
	if decoy == null:
		return
	var from: Vector2 = hearth.world_center() + Vector2.RIGHT * 32.0
	var found: Dictionary = combat.find_enemy_target(from, CombatTypes.PREF_ANY, 14.0 * 32.0)
	assert_not_empty(found, "an attacker beside the hearth finds SOMETHING")
	assert_ne(int(found["id"]), hearth.id,
		"but never the hearth while a watchtower is standing seven tiles away — "
		+ "losing it is Bus.game_over, and a coin flip is not a difficulty curve")
	assert_eq(int(found["id"]), decoy.id, "it goes for the thing that is not the fire")


func test_the_hearth_does_burn_when_it_is_genuinely_the_last_thing_left() -> void:
	# The rule is "last resort", not "invulnerable". A city with nothing else
	# standing has already lost; the fire going out is the sentence, not the
	# accident.
	var seat: Vector2i = _open_cell(Vector2i(-16, -16))
	var hearth: BuildingInstance = _place(&"the_hearth", seat)
	if hearth == null:
		return
	var from: Vector2 = hearth.world_center() + Vector2.RIGHT * 32.0
	var found: Dictionary = combat.find_enemy_target(from, CombatTypes.PREF_ANY, 8.0 * 32.0)
	assert_not_empty(found, "with nothing else in reach it does find the hearth")
	assert_eq(int(found["id"]), hearth.id,
		"the rule is last resort, not invulnerable")

	# ...and hitting it does what it always did: the fire goes out and the run
	# is over. The mercy is only ever about the city that still stands.
	var fired: Dictionary = world.count_bus_signals(PackedStringArray(["game_over"]),
		func() -> void:
			combat.spawn(HOUND, hearth.cell, 1)
			world.run(1)
			combat.swarm.e_target[0] = hearth.id
			hearth.hp = 1.0
			combat.enemy_attack(0, hearth.id, hearth.world_center()))
	assert_ge(float(fired["game_over"]), 1.0,
		"the last building in the city coming down is still a game over")


func test_a_body_that_reaches_the_fire_is_absorbed_not_left_chewing_on_it() -> void:
	# The other half of the same rule, on the path that actually killed the
	# reference run: frost_shade has seek_radius 0, so it never CHOOSES a target
	# at all — it walks the flow field into whatever blocks it, and what blocks
	# it at the end of the road is the hearth.
	var seat: Vector2i = _open_cell(Vector2i(-16, -16))
	var hearth: BuildingInstance = _place(&"the_hearth", seat)
	if hearth == null:
		return
	if _place(&"watchtower", seat + Vector2i(7, 0)) == null:
		return
	combat.spawn(HOUND, hearth.cell, 1)
	world.run(1)
	var hp_before: float = hearth.hp
	var alive_before: int = combat.enemies_alive()
	var leaked_before: int = combat.swarm.leaked
	var landed: float = combat.enemy_attack(0, hearth.id, hearth.world_center())
	assert_lt(landed, 0.0, "nothing lands on the fire")
	assert_near(hearth.hp, hp_before, 0.001, "and the hearth is untouched")
	assert_eq(combat.swarm.leaked, leaked_before + 1,
		"the body is counted as having got INSIDE, which is the honest word for it")
	assert_lt(float(combat.enemies_alive()), float(alive_before),
		"and it is off the map rather than standing there demolishing the win "
		+ "condition at four damage a second for the rest of the campaign")


# --- helpers --------------------------------------------------------------------

func _cells_of(b: BuildingInstance) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for c: Vector2i in b.cells:
		out.append(c)
	return out


## Cells that actually have somebody standing on them right now, so the test
## measures the toll rather than the odds of finding anyone.
func _cells_holding_people(limit: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for id: int in (citizens.call("citizen_ids") as PackedInt32Array):
		var info: Variant = citizens.call("citizen_info", id)
		if typeof(info) != TYPE_DICTIONARY:
			continue
		var cell: Variant = (info as Dictionary).get("cell", null)
		if typeof(cell) != TYPE_ARRAY or (cell as Array).size() < 2:
			continue
		var v := Vector2i(int((cell as Array)[0]), int((cell as Array)[1]))
		if not out.has(v):
			out.append(v)
		if out.size() >= limit:
			break
	return out
