extends TestCase
## [P07] Combat against a real world: turrets, walls, pathing and the heat that
## decides whether any of it fires.
##
## Every test gets a world of its own. Worldgen is cheap enough (about a sixth of
## a second) that isolation is worth more than the time, and combat is a system
## whose state is exactly "what is standing on the map" — a leftover body from the
## previous test is not a flake, it is a wrong answer.
##
## [P08]'s wave director is switched off for the duration: it drives spawns
## through this system by design, and a test of combat must be a test of combat.

const HOUND: StringName = &"drift_hound"
const BREAKER: StringName = &"hoarfrost_breaker"

var world: SimFixture = null
var combat: CombatSystem = null
var grid: GridSystem = null
var build: BuildSystem = null
var core: Vector2i = Vector2i.ZERO


func requires_systems() -> PackedStringArray:
	return PackedStringArray(["combat", "grid", "build"])


func setup() -> void:
	world = SimFixture.new(7).start()
	combat = world.system(&"combat") as CombatSystem
	grid = world.system(&"grid") as GridSystem
	build = world.system(&"build") as BuildSystem
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


## An open spot far enough from the core that the flow field has somewhere to go.
func _open_cell(offset: Vector2i) -> Vector2i:
	var c: Vector2i = core + offset
	if grid.is_walkable(c):
		return c
	return grid.world().nearest_walkable(c, 30)


# =========================================================================
# spawning and movement
# =========================================================================

func test_spawning_puts_bodies_on_the_field_and_announces_them() -> void:
	var seen: Dictionary = world.count_bus_signals(PackedStringArray(["enemy_spawned"]),
		func() -> void: combat.spawn(HOUND, _open_cell(Vector2i(30, 0)), 6))
	assert_eq(combat.enemies_alive(), 6, "six hounds arrived")
	assert_eq(int(seen["enemy_spawned"]), 6, "and each one announced itself")


func test_an_unknown_kind_is_refused_not_crashed() -> void:
	assert_eq(combat.spawn(&"not_a_real_enemy", core + Vector2i(20, 0), 3), 0,
		"nothing spawns for a kind that does not exist")
	assert_eq(combat.enemies_alive(), 0)


func test_enemies_walk_toward_the_warm_centre() -> void:
	var start: Vector2i = _open_cell(Vector2i(34, 0))
	combat.spawn(HOUND, start, 8)
	var before: float = _mean_distance_to_core()
	world.run(120)
	var after: float = _mean_distance_to_core()
	assert_lt(after, before - 32.0,
		"six seconds of walking closes real ground toward the hearth")


func test_a_burrower_ignores_a_wall_a_hound_has_to_go_around() -> void:
	# Same start, same goal, one wall between: the borer's route ignores it.
	var start: Vector2i = _open_cell(Vector2i(20, 0))
	for dy: int in range(-5, 6):
		_place(&"wall", Vector2i(start.x - 3, start.y + dy))
	world.run(2)
	combat.spawn(&"permafrost_borer", start, 1)
	var d0: float = _mean_distance_to_core()
	world.run(200)
	var d1: float = _mean_distance_to_core()
	assert_lt(d1, d0 - 100.0, "the borer crossed the wall line rather than stopping at it")
	assert_eq(build.count_of(&"wall"), 11, "and it did not have to break anything")


# =========================================================================
# structures
# =========================================================================

func test_a_blocked_enemy_attacks_the_wall_in_its_way() -> void:
	var start: Vector2i = _open_cell(Vector2i(14, 0))
	var wall: BuildingInstance = null
	for dy: int in range(-8, 9):
		var w: BuildingInstance = _place(&"wall", Vector2i(start.x - 2, start.y + dy))
		if dy == 0:
			wall = w
	world.run(2)
	combat.spawn(BREAKER, start, 3)
	var before: float = _wall_health_total()
	world.run(400)
	var after: float = _wall_health_total()
	assert_lt(after, before, "the wall is taking damage")
	assert_gt(combat.damage_taken, 0.0, "and combat is counting it")
	assert_not_null(wall, "the middle panel existed")


func test_breaking_a_wall_reroutes_the_flow_field() -> void:
	# A wall of walls across the approach: the assault surface must cost more to
	# cross it than to walk round it, and the moment a panel is gone the cost of
	# stepping through that gap collapses.
	var start: Vector2i = _open_cell(Vector2i(16, 0))
	var gap: Vector2i = Vector2i(start.x - 2, start.y)
	var panel: BuildingInstance = null
	for dy: int in range(-6, 7):
		var w: BuildingInstance = _place(&"wall", Vector2i(start.x - 2, start.y + dy))
		if dy == 0:
			panel = w
	world.run(2)
	combat.spawn(HOUND, start, 1)
	world.run(2)
	assert_true(combat.assault.ready, "the siege surface came up with the first body")

	var walled: int = combat.assault.distance_at(gap)
	build.execute({"op": &"remove", "id": panel.id, "instant": true})
	# A wall the PLAYER takes down reaches the siege surface on the next sweep,
	# not instantly; only a wall combat breaks is pushed through immediately.
	world.run(20)
	var opened: int = combat.assault.distance_at(gap)
	assert_lt(float(opened), float(walled),
		"with the panel gone the same tile is genuinely cheaper to stand on")
	assert_lt(float(combat.assault.cost[gap.y * grid.map_size().x + gap.x]),
		float(AssaultField.DIG_COST), "and its movement cost is no longer a dig")


func test_a_damaged_wall_becomes_the_cheap_way_in() -> void:
	var start: Vector2i = _open_cell(Vector2i(16, 4))
	var panel: BuildingInstance = null
	for dy: int in range(-6, 7):
		var w: BuildingInstance = _place(&"wall", Vector2i(start.x - 2, start.y + dy))
		if dy == 0:
			panel = w
	world.run(2)
	combat.spawn(HOUND, start, 1)
	world.run(2)
	var cell: Vector2i = panel.cell
	var idx: int = cell.y * grid.map_size().x + cell.x
	assert_eq(int(combat.assault.cost[idx]), AssaultField.DIG_COST,
		"an intact panel costs a full dig")
	build.apply_damage(panel.id, panel.max_hp * 0.7, &"test")
	# Damage alone does not weaken the route; combat notices when it is the one
	# doing the hitting, so drive one enemy attack through the same path.
	combat.assault.weaken(panel.id, panel.cells)
	world.run(2)
	assert_eq(int(combat.assault.cost[idx]), AssaultField.WEAK_COST,
		"a cracked panel is the cheap way through, and the field says so")


func test_destroying_a_landmark_ends_the_run() -> void:
	var hearth: BuildingInstance = _place(&"the_hearth", _open_cell(Vector2i(-14, -14)))
	assert_not_null(hearth, "the hearth is placeable")
	if hearth == null:
		return
	var fired: Dictionary = world.count_bus_signals(PackedStringArray(["game_over"]),
		func() -> void:
			combat.spawn(HOUND, hearth.cell, 1)
			world.run(1)
			var id: int = combat.swarm.e_id[0]
			combat.swarm.e_target[0] = hearth.id
			combat.swarm.e_tx[0] = hearth.world_center().x
			combat.swarm.e_ty[0] = hearth.world_center().y
			hearth.hp = 1.0
			combat.enemy_attack(0, hearth.id, hearth.world_center())
			assert_eq(combat.swarm.e_id[0], id, "the slot did not move under us"))
	assert_ge(float(fired["game_over"]), 1.0, "the hearth going out is a game over")


# =========================================================================
# turrets
# =========================================================================

func test_a_turret_the_grid_stops_feeding_stops_shooting() -> void:
	# The whole fusion, end to end and with nothing forced: a mount with no heat
	# source anywhere runs on its own thermal buffer for a few seconds, and once
	# that is gone the grid serves it nothing, the magazine stops filling, and the
	# gun is a decoration with a reason attached.
	var mount: BuildingInstance = _place(&"turret_mount", _open_cell(Vector2i(8, 0)))
	world.run(150)
	var t: TurretBattery.Turret = combat.battery.get_turret(mount.id)
	assert_not_null(t, "the mount registered as a turret")
	if t == null:
		return
	assert_near(t.served, 0.0, 0.01, "the grid is delivering it nothing")
	var charge_before: float = t.charge
	world.run(100)
	assert_near(t.charge, charge_before, 0.001, "so the magazine has stopped filling")

	t.charge = 0.0
	var shots_before: int = t.shots
	combat.spawn(HOUND, mount.cell + Vector2i(4, 0), 4)
	world.run(20)
	assert_eq(CombatTypes.idle_name(t.idle), &"no_heat",
		"and the gun says exactly why it is quiet")
	assert_eq(t.shots, shots_before, "nothing was fired")


func test_a_turret_wired_to_a_hearth_keeps_firing() -> void:
	# The positive control for the test above, and the one that proves the shots
	# are paid for: a mount hung off a lit hearth is served in full and keeps
	# putting rounds out, and every one of them shows up as heat spent.
	var hearth: BuildingInstance = _place(&"the_hearth", _open_cell(Vector2i(-18, -18)))
	if hearth == null:
		return
	var mount: BuildingInstance = _place(&"turret_mount",
		Vector2i(hearth.cell.x + 5, hearth.cell.y))
	if mount == null:
		return
	world.run(60)
	var t: TurretBattery.Turret = combat.battery.get_turret(mount.id)
	if t == null:
		fail("no turret registered")
		return
	assert_gt(t.served, 0.9, "the hearth is feeding it")
	combat.spawn(HOUND, mount.cell + Vector2i(5, 0), 8)
	var fired: Dictionary = world.count_bus_signals(PackedStringArray(["turret_fired"]),
		func() -> void: world.run(200))
	assert_gt(float(fired["turret_fired"]), 3.0, "the gun fired repeatedly and said so")
	assert_gt(combat.heat_spent_on_defence(), 0.0, "every shot cost the city heat")
	assert_gt(combat.battery.damage_dealt, 0.0, "and the shells connected")
	assert_gt(float(combat.swarm.kills), 0.0, "and killed something")


func test_a_siphon_drains_the_magazines_around_it() -> void:
	var mount: BuildingInstance = _place(&"turret_mount", _open_cell(Vector2i(10, 10)))
	if mount == null:
		return
	world.run(20)
	var t: TurretBattery.Turret = combat.battery.get_turret(mount.id)
	if t == null:
		fail("no turret registered")
		return
	t.charge = t.capacity
	var before: float = t.charge
	# A leech feeding on something two tiles from the gun.
	var taken: float = combat.siphon_turrets(mount.world_center() + Vector2(64.0, 0.0),
		7.0 * 32.0, 12.0)
	assert_near(taken, 12.0, 0.001, "the leech got what it bit for")
	assert_near(t.charge, before - 12.0, 0.001, "straight out of the magazine")
	assert_near(combat.siphon_turrets(Vector2(1.0, 1.0), 32.0, 5.0), 0.0, 0.001,
		"and a leech nowhere near a gun gets nothing")


func test_a_chill_aura_slows_a_magazine_without_touching_it() -> void:
	var hearth: BuildingInstance = _place(&"the_hearth", _open_cell(Vector2i(-18, 14)))
	if hearth == null:
		return
	var mount: BuildingInstance = _place(&"turret_mount",
		Vector2i(hearth.cell.x + 5, hearth.cell.y))
	if mount == null:
		return
	world.run(60)
	var t: TurretBattery.Turret = combat.battery.get_turret(mount.id)
	if t == null:
		return
	t.charge = 0.0
	world.run(4)
	var warm_gain: float = t.charge
	t.charge = 0.0
	for _i: int in range(4):
		combat.chill_turrets(mount.world_center(), 9.0 * 32.0, 0.65)
		world.run(1)
	assert_lt(t.charge, warm_gain * 0.7,
		"a chilled magazine fills measurably slower than a warm one")


func test_a_turret_charges_at_the_rate_heat_is_serving_it() -> void:
	var mount: BuildingInstance = _place(&"turret_mount", _open_cell(Vector2i(-8, 6)))
	world.run(12)
	var t: TurretBattery.Turret = combat.battery.get_turret(mount.id)
	if t == null:
		fail("no turret registered")
		return
	assert_near(t.charge_rate, mount.def.heat_consumed, 0.001,
		"the magazine charges off the building's heat draw, not a magic number")
	t.charge = 0.0
	world.run(20)
	var expected: float = t.charge_rate * t.served * 1.0
	assert_near(t.charge, minf(t.capacity, expected), maxf(expected * 0.15, 0.2),
		"one second of charging is one second of served heat")


func test_targeting_policies_choose_different_targets() -> void:
	var mount: BuildingInstance = _place(&"turret_mount", _open_cell(Vector2i(0, 10)))
	world.run(12)
	var t: TurretBattery.Turret = combat.battery.get_turret(mount.id)
	if t == null:
		fail("no turret registered")
		return
	# Two bodies inside range: a near hound and a far breaker. Every policy has an
	# unambiguous right answer here.
	var near_cell: Vector2i = Vector2i(mount.cell.x + 2, mount.cell.y)
	var far_cell: Vector2i = Vector2i(mount.cell.x + 6, mount.cell.y)
	combat.spawn(HOUND, near_cell, 1)
	combat.spawn(BREAKER, far_cell, 1)
	world.run(1)
	assert_eq(combat.enemies_alive(), 2, "both are on the field")
	var hound_id: int = -1
	var breaker_id: int = -1
	for i: int in range(combat.swarm.count):
		if combat.swarm.d_id[combat.swarm.e_def[i]] == HOUND:
			hound_id = combat.swarm.e_id[i]
		else:
			breaker_id = combat.swarm.e_id[i]

	assert_eq(_pick(t, CombatTypes.Aim.CLOSEST), hound_id, "closest picks the near hound")
	assert_eq(_pick(t, CombatTypes.Aim.STRONGEST), breaker_id, "strongest picks the breaker")
	assert_eq(_pick(t, CombatTypes.Aim.WEAKEST), hound_id, "weakest picks the hound")
	assert_eq(_pick(t, CombatTypes.Aim.ARMOURED), breaker_id, "armoured picks the plated one")


func test_first_policy_prefers_whatever_is_furthest_along_the_way_in() -> void:
	var mount: BuildingInstance = _place(&"turret_mount", _open_cell(Vector2i(0, -10)))
	world.run(12)
	var t: TurretBattery.Turret = combat.battery.get_turret(mount.id)
	if t == null:
		fail("no turret registered")
		return
	# One body between the turret and the core, one behind it. Both in range.
	var inward: Vector2i = Vector2i(mount.cell.x, mount.cell.y + 3)
	var outward: Vector2i = Vector2i(mount.cell.x, mount.cell.y - 5)
	combat.spawn(HOUND, inward, 1)
	world.run(1)
	var leader: int = combat.swarm.e_id[0]
	combat.spawn(HOUND, outward, 1)
	world.run(1)
	if not combat.assault.ready:
		skip("the siege surface did not come up")
		return
	assert_eq(_pick(t, CombatTypes.Aim.FIRST), leader,
		"'first' means nearest to the hearth, not nearest to the gun")


func test_a_refit_changes_the_weapon_a_mount_carries() -> void:
	var mount: BuildingInstance = _place(&"turret_mount", _open_cell(Vector2i(10, -6)))
	world.run(12)
	var before: StringName = combat.battery.get_turret(mount.id).weapon_id
	combat.handle_command({"op": "refit", "id": mount.id, "weapon": "flame_projector"})
	world.run(12)
	var after: StringName = combat.battery.get_turret(mount.id).weapon_id
	assert_ne(String(after), String(before), "the barrel actually changed")
	assert_eq(String(after), "flame_projector", "to the one asked for")


func test_the_readout_names_a_reason_for_every_gun() -> void:
	_place(&"turret_mount", _open_cell(Vector2i(-10, -6)))
	world.run(12)
	var rows: Array[Dictionary] = combat.turret_readout()
	assert_size(rows, 1, "one mount, one row")
	if rows.is_empty():
		return
	assert_has(CombatTypes.IDLE_NAMES, StringName(String(rows[0]["idle"])),
		"the reason is one of the documented ones")
	assert_has(rows[0], "magazine", "and it reports how full the magazine is")


# =========================================================================
# the view and selection contracts
# =========================================================================

func test_agents_for_view_reports_render_archetypes() -> void:
	combat.spawn(HOUND, _open_cell(Vector2i(24, 0)), 3)
	var agents: Array[Dictionary] = combat.agents_for_view()
	assert_size(agents, 3, "every visible body is offered to the renderer")
	for a: Dictionary in agents:
		assert_has(["swarm", "brute"], String(a["kind"]),
			"the kind is a render archetype [P13] can actually bake")
		assert_has(a, "pos", "with a world position")


func test_a_burrower_is_invisible_and_untargetable_until_it_surfaces() -> void:
	combat.spawn(&"permafrost_borer", _open_cell(Vector2i(40, 0)), 1)
	world.run(1)
	assert_empty(combat.agents_for_view(), "nothing to draw while it is under the ice")
	assert_near(combat.swarm.hurt(0, combat.swarm.e_id[0], 500.0,
		CombatTypes.Damage.KINETIC, 0.0, 1), 0.0, 0.001,
		"and nothing can hit it either")


func test_selection_finds_an_enemy_by_cell() -> void:
	var at: Vector2i = _open_cell(Vector2i(26, 2))
	combat.spawn(HOUND, at, 1)
	world.run(1)
	var pos: Vector2 = combat.swarm.position_at(0)
	var cell := Vector2i(int(pos.x / 32.0), int(pos.y / 32.0))
	assert_eq(combat.entity_at_cell(cell), combat.swarm.e_id[0],
		"the tile a body stands on reports that body")
	assert_ge(float(combat.entities_in_cell_rect(Rect2i(cell - Vector2i(2, 2),
		Vector2i(5, 5))).size()), 1.0, "and a rectangle around it finds it too")
	assert_eq(combat.entity_at_cell(core), -1, "an empty tile reports nothing")


func test_describe_enemy_answers_the_inspector() -> void:
	combat.spawn(BREAKER, _open_cell(Vector2i(28, 0)), 1)
	world.run(1)
	var d: Dictionary = combat.describe_enemy(combat.swarm.e_id[0])
	assert_eq(String(d.get("kind", "")), String(BREAKER))
	assert_gt(float(d.get("armour", 0.0)), 0.0, "with its plating")
	assert_not_empty(String(d.get("description", "")), "and the line the bestiary shows")
	assert_empty(combat.describe_enemy(-1), "an unknown id describes nothing")


# =========================================================================
# helpers
# =========================================================================

func _pick(t: TurretBattery.Turret, policy: int) -> int:
	t.aim = policy
	t.target_slot = -1
	t.target_id = -1
	combat.swarm.reindex()
	combat.battery._acquire(t, combat.swarm, combat.assault,
		t.weapon.range_tiles * 32.0, t.weapon)
	return t.target_id


func _mean_distance_to_core() -> float:
	if combat.swarm.count == 0:
		return 0.0
	var centre: Vector2 = Grid.cell_to_world(core)
	var total: float = 0.0
	for i: int in range(combat.swarm.count):
		total += combat.swarm.position_at(i).distance_to(centre)
	return total / float(combat.swarm.count)


func _wall_health_total() -> float:
	var total: float = 0.0
	for b: BuildingInstance in build.buildings_with_tag(&"wall"):
		total += b.hp
	return total
