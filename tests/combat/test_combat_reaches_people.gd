extends TestCase
## [P07] CAN THE NIGHT REACH THE PEOPLE AT ALL?
##
## `NightToll` has been able to kill through [P05]'s own `kill_citizen` since it
## was written, and `combat.citizens_killed` has read 0 in every run of every
## scenario in this build. The machinery was never the problem. Three things in
## front of it were, and each of them is pinned below by a test that goes red
## against the code it replaced:
##
##   1. NINE BODIES IN TEN NEVER THOUGHT. `(i + tick) % THINK_PERIOD ==
##      tick % THINK_PERIOD` is true exactly when `i` is a multiple of ten, for
##      every tick. Seeking a target happens only on a think tick, so nine
##      attackers in ten could only ever hit what physically blocked their next
##      step — and a heat pipe does not block movement, so they walked over the
##      whole heat network without touching it.
##   2. THE HEARTH WAS A DEADLOCK, NOT A LAST RESORT. `enemy_attack` refused to
##      let anything demolish the fire and redirected it onto the nearest real
##      building — and the next step's blocker probe put the target straight
##      back on the hearth. Attack, refuse, redirect, retarget, at zero damage a
##      second, until dawn.
##   3. NOTHING IN THE ROSTER WANTED THE PEOPLE. Ten enemy kinds went for walls,
##      guns, pipes, generators and "whatever is nearest". `snow_widow` goes for
##      housing, and housing is where the names are.

const WIDOW: StringName = &"snow_widow"
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
	world = SimFixture.new(23).start()
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


func _step(n: int) -> void:
	world.run(n)


# ==========================================================================
#  1. THE THINK GATE
# ==========================================================================

## Every body must reach a think tick, not one slot in ten.
##
## RED against the old gate: with `(i + tick) % THINK_PERIOD ==
## tick % THINK_PERIOD`, slots 1..9 and 11..19 are never true for any tick, so
## `seen` ends up holding only the multiples of ten and this fails on the very
## first missing slot.
func test_every_body_gets_a_think_tick() -> void:
	var n: int = EnemySwarm.THINK_PERIOD * 3
	var seen: Dictionary[int, bool] = {}
	for tick: int in range(0, EnemySwarm.THINK_PERIOD * 4):
		for i: int in range(n):
			if (i + tick) % EnemySwarm.THINK_PERIOD == 0:
				seen[i] = true
	for i: int in range(n):
		assert_true(seen.has(i),
			"slot %d never reaches a think tick in %d ticks — it will never seek a "
			% [i, EnemySwarm.THINK_PERIOD * 4] + "target, never age out and never "
			+ "run the stall watchdog")


# ==========================================================================
#  2. THE HEARTH IS NOT A THING TO CHEW ON
# ==========================================================================

## The fire is impassable, and it is not a target while anything else stands.
##
## RED against the old code: `blocker_at` did not exist and the swarm asked
## `structure_at`, which hands back the hearth's own id. The assertion below is
## the exact value that fed the deadlock.
func test_the_fire_is_not_a_blocker_while_the_city_stands() -> void:
	var hearth: BuildingInstance = _place(&"the_hearth", core - Vector2i(2, 2))
	if hearth == null:
		return
	var seat: Vector2i = _housing_seat(Vector2i(7, 0))
	var house: BuildingInstance = _place(&"housing_block", seat)
	if house == null:
		return
	var on_fire: Vector2i = core
	assert_eq(combat.structure_at(on_fire), hearth.id,
		"structure_at must still answer honestly about what stands on the tile")
	assert_eq(combat.blocker_at(on_fire), 0,
		"the hearth must not be something to chew on while the city is more than "
		+ "the hearth — a body told otherwise re-targets it every step and spends "
		+ "the night doing zero damage to a 3000 hit-point landmark")


## And when it really is the last thing left, the fire goes out.
func test_the_fire_is_a_blocker_when_it_is_all_that_is_left() -> void:
	var hearth: BuildingInstance = _place(&"the_hearth", core - Vector2i(2, 2))
	if hearth == null:
		return
	assert_eq(combat.blocker_at(core), hearth.id,
		"with nothing else standing the hearth is fair game, or a city reduced to "
		+ "its fire could never be finished off")


# ==========================================================================
#  3. SOMETHING IN THE ROSTER GOES FOR THE HOUSES
# ==========================================================================

func test_the_roster_has_a_housing_seeker() -> void:
	var found: bool = false
	for id: StringName in combat.enemy_kinds():
		var def: CombatEnemyDef = combat.swarm.def_resource(combat.swarm.def_slot(id))
		if def != null and def.target_pref == CombatTypes.PREF_HOUSING:
			found = true
			assert_true(def.seek_radius > 0.0,
				"%s prefers housing but never looks for any (seek_radius 0)" % id)
			assert_true(def.min_day <= 2,
				"%s cannot appear before day %d; the night that is supposed to teach "
				% [id, def.min_day] + "the player what a leak costs is night two")
	assert_true(found,
		"nothing in game/content/enemies/ has target_pref = housing, so no night "
		+ "can ever cost the player a person — combat.citizens_killed reads 0 in "
		+ "every scenario in this build and this is why")


## EVERY tagged preference in the roster has to resolve to something, or the
## specialist that names it is a generic biter with a description that lies.
##
## RED against the Packed-array accumulator: `_target_index` was empty for every
## tag on every tick, find_enemy_target is forbidden from falling back to the
## untagged search, and so the pale stalker walked past the guns, the leech past
## the mains, the breaker past the wall and the borer past the generators — each
## one chewing whatever happened to block its next step. Four of the ten answers
## in this roster, silently absent from the game.
func test_every_preference_in_the_roster_resolves_to_a_real_building() -> void:
	var seats: Dictionary[StringName, StringName] = {
		&"housing": &"housing_block",
		&"wall": &"wall",
		&"turret": &"turret_mount",
		&"heat_source": &"coal_generator",
		&"conduit": &"heat_pipe",
	}
	var wanted: Dictionary[StringName, bool] = {}
	for id: StringName in combat.enemy_kinds():
		var def: CombatEnemyDef = combat.swarm.def_resource(combat.swarm.def_slot(id))
		if def != null and def.target_pref != CombatTypes.PREF_ANY:
			wanted[def.target_pref] = true
	assert_true(wanted.size() >= 4,
		"this roster is supposed to answer a defence with specialists; only %d "
		% wanted.size() + "preferences are named at all")

	var keys: Array = wanted.keys()
	keys.sort()
	var at: Vector2i = _housing_seat(Vector2i(8, 0))
	for pref: StringName in keys:
		if not seats.has(pref):
			fail("no building in this build carries the tag '%s', so the enemies "
				% pref + "that prefer it can never find anything")
			continue
		var b: BuildingInstance = _place(seats[pref], at)
		if b == null:
			continue
		var from: Vector2 = b.world_center() + Vector2(0.0, 5.0 * 32.0)
		var found: Dictionary = combat.find_enemy_target(from, pref, 20.0 * 32.0)
		assert_false(found.is_empty(),
			"nothing answers preference '%s' five tiles from a finished %s — the "
			% [pref, seats[pref]] + "seek index is empty for that tag and every "
			+ "enemy that names it is behaving as a generic biter")
		build.execute({"op": &"remove", "cell": [at.x, at.y], "instant": true})
		_step(1)


## A seeker standing in the street finds the house.
##
## RED against the old think gate: the body is spawned into slot 0 here on
## purpose so that THIS test isolates the target index rather than the gate.
func test_a_seeker_finds_housing_it_is_standing_next_to() -> void:
	var seat: Vector2i = _housing_seat(Vector2i(6, 0))
	var house: BuildingInstance = _place(&"housing_block", seat)
	if house == null:
		return
	var from: Vector2 = Grid.cell_to_world(seat + Vector2i(0, 6))
	var found: Dictionary = combat.find_enemy_target(from, CombatTypes.PREF_HOUSING, 26.0 * 32.0)
	assert_false(found.is_empty(),
		"a housing seeker six tiles from a finished housing block found nothing; "
		+ "the tag index does not carry 'housing'")
	if not found.is_empty():
		assert_eq(int(found["id"]), house.id, "it found the wrong building")


# ==========================================================================
#  4. THE WHOLE CHAIN, END TO END: A HOUSE COMES DOWN AND IT HAS NAMES IN IT
# ==========================================================================

## The one test the brief is actually about. A housing block, people inside it,
## and something in the dark that wants it. Afterwards the block is gone, the
## toll ledger names who was in it, and [P05]'s obituary agrees.
func test_a_housing_block_comes_down_on_the_people_in_it() -> void:
	if citizens == null or not citizens.has_method("kill_citizen"):
		skip("[P05] is not in this build; the toll has nobody to bill")
		return
	var seat: Vector2i = _housing_seat(Vector2i(6, 0))
	var house: BuildingInstance = _place(&"housing_block", seat)
	if house == null:
		return
	var inside: PackedInt32Array = _stand_people_in(house, 8)
	if inside.size() < 4:
		# NOT a skip. A suite whose precondition quietly fails asserts nothing
		# and reports green, which is how 371 build assertions were once
		# reported passing while never executing.
		fail("only %d of 8 citizens ended up on the footprint (%s); this suite "
			% [inside.size(), str(house.rect())] + "cannot say anything about what "
			+ "a collapse costs until they are in there")
		return

	var dead_before: int = combat.toll.dead_total
	combat.spawn(WIDOW, seat + Vector2i(0, 3), 8)
	var guard: int = 0
	while build.get_building(house.id) != null and guard < 2400:
		world.run(1)
		guard += 1

	assert_null(build.get_building(house.id),
		"eight housing seekers stood next to a 900 hit-point housing block for "
		+ "150 seconds and it is still standing")
	assert_true(combat.toll.dead_total + combat.toll.hurt_total > 0,
		"the block came down with %d people on the footprint and the toll billed "
		% inside.size() + "nobody — combat.citizens_killed is still 0")
	assert_true(combat.toll.dead_total > dead_before,
		"the block came down on %d people and killed none of them" % inside.size())

	var rows: Array[Dictionary] = combat.night_toll(0)
	var named: Array = []
	for row: Dictionary in rows:
		if String(row.get("kind", "")) == "housing_block":
			named = row.get("dead", [])
	assert_true(named.size() > 0,
		"the ledger row for the housing block carries no names, so the morning "
		+ "after cannot say who is missing")
	for n: Variant in named:
		assert_ne(String(n), "someone",
			"the toll wrote a placeholder instead of a citizen's name")
	var line: String = combat.night_toll_line(0)
	assert_true(line.find("did not come out") >= 0,
		"the morning sentence does not mention the dead: '%s'" % line)


## A pipe is one tile and a housing block is sixteen; the cap on how many people
## one collapse can take has to know the difference.
##
## RED against the flat `max_caught = 6`: both answers were 6.
func test_a_bigger_building_can_take_more_people_with_it() -> void:
	var toll := NightToll.new()
	var one: Array[Vector2i] = [Vector2i(0, 0)]
	var block: Array[Vector2i] = []
	for x: int in range(4):
		for y: int in range(4):
			block.append(Vector2i(x, y))
	var small: int = toll.cap_for(one)
	var large: int = toll.cap_for(block)
	assert_true(large > small,
		"a sixteen-tile housing block full of sleepers can take no more people "
		+ "with it than a single length of heat pipe (%d vs %d)" % [large, small])
	assert_true(small >= 3, "a collapse always catches at least the doorway")
	assert_true(large >= 8,
		"a housing block that catches fewer than eight cannot produce the four "
		+ "named dead a bad night is supposed to cost")


# ==========================================================================
#  5. THE LEDGER CANNOT REPORT MORE SURVIVORS THAN IT SENT
# ==========================================================================

## [P08] closes a night with `killed = spawned - withdrew`. A `withdrew` that
## counts bodies the director never composed drives that to zero.
##
## RED against the old withdraw_wave(-1), which returned `swarm.withdraw_all()`
## — every body standing on the map. Here that is 9; the wave sent 4.
func test_dawn_counts_only_the_bodies_the_director_sent() -> void:
	var sent: int = 4
	combat.spawn_group({"wave": 1, "enemy": HOUND, "count": sent,
		"cell": [core.x, core.y + 24]})
	# Bodies from somewhere else entirely: a scenario's own hand, or a boss's
	# adds. Real, shootable, and no part of any plan.
	combat.spawn(HOUND, core + Vector2i(0, 26), 5)
	_step(4)

	var status: Dictionary = combat.wave_status(1)
	assert_eq(int(status["spawned"]), 4,
		"the wave record must hold what the director handed over, not what is "
		+ "standing on the map")
	var walked: int = combat.withdraw_wave(-1)
	assert_eq(combat.bodies_on_map(), 9,
		"dawn must still turn EVERY body around, whoever sent it")
	assert_true(walked <= sent,
		"dawn reported %d survivors of a wave that sent %d — [P08] computes "
		% [walked, sent] + "killed = spawned - withdrew and this is exactly how a "
		+ "night that was fought reports '0 killed'")
	assert_eq(walked, 4, "all four of the wave's bodies were still up at dawn")


# ==========================================================================
#  helpers
# ==========================================================================

## Ground a 4x4 housing block will actually take.
func _housing_seat(offset: Vector2i) -> Vector2i:
	var want: Vector2i = core + offset
	for r: int in range(0, 20):
		for c: Vector2i in ([want] if r == 0 else Grid.ring(want, r)):
			var ok: bool = true
			for dx: int in range(4):
				for dy: int in range(4):
					if not grid.is_walkable(c + Vector2i(dx, dy)):
						ok = false
						break
				if not ok:
					break
			if ok:
				return c
	return want


## Puts up to `want` citizens onto a building's footprint and returns their ids.
## They are placed, not persuaded: this suite is about what happens when the
## building comes down, not about [P05]'s shift rota.
func _stand_people_in(b: BuildingInstance, want: int) -> PackedInt32Array:
	var pool: Object = citizens.get("pool")
	if pool == null:
		return PackedInt32Array()
	var ids: PackedInt32Array = citizens.call("add_citizens", want, 30)
	var cells: Array = b.cells
	for k: int in range(ids.size()):
		var slot: int = pool.call("slot_of", ids[k])
		if slot < 0:
			continue
		var c: Vector2i = cells[k % cells.size()]
		pool.call("set_position", slot, c)
	return citizens.call("citizens_in_cell_rect", b.rect())
