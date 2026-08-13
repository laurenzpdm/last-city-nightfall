extends TestCase
## [P08] Threat Director — the siege model.
##
## SiegeResolver is what the director uses to find out how a night went when
## [P07] combat is not in the build. It is dormant in a full build, which is
## exactly why it needs its own tests: an unexercised fallback is a fallback
## that has quietly stopped working by the time anybody needs it.
##
## Every case here drives the resolver directly, so it runs identically whether
## or not combat is present.

var world: SimFixture = null
var threat: SimSystem = null


func requires_systems() -> PackedStringArray:
	return PackedStringArray(["threat", "grid"])


func setup() -> void:
	world = SimFixture.new(3).start()
	threat = world.system(&"threat")


func teardown() -> void:
	if world != null:
		world.stop()


func _profile() -> ThreatProfile:
	return threat.call("profile") as ThreatProfile


func _units() -> Dictionary[StringName, ThreatUnit]:
	var out: Dictionary[StringName, ThreatUnit] = {}
	for u: ThreatUnit in (threat.call("units") as Array[ThreatUnit]):
		out[u.id] = u
	return out


func _planner() -> ApproachPlanner:
	var p := ApproachPlanner.new()
	p.bind(_profile(), world.system(&"grid"), world.system(&"build"), world.system(&"heat"))
	p.build_vectors()
	return p


## A plan with one vector and one group of `count` of the cheapest unit.
func _rig(count: int = 10) -> Dictionary:
	var planner: ApproachPlanner = _planner()
	var units: Dictionary[StringName, ThreatUnit] = _units()
	if units.is_empty() or planner.candidates().is_empty():
		return {}
	var plan := WavePlan.new()
	plan.units = units
	plan.wave = 5
	plan.vectors = planner.select(1, false, Rng.stream("test_siege"))
	if plan.vectors.is_empty():
		return {}
	var ids: Array = units.keys()
	ids.sort()
	var pick: ThreatUnit = units[ids[0]]
	for id: StringName in ids:
		if units[id].min_wave <= 1:
			pick = units[id]
			break
	var g := WaveGroup.new()
	g.enemy = pick.id
	g.count = count
	g.cost = pick.cost * float(count)
	g.vector = 0
	g.spawn_cell = plan.vectors[0].entry_cell
	plan.groups.append(g)

	var resolver := SiegeResolver.new()
	resolver.bind(_profile(), planner, world.system(&"build"), world.system(&"grid"), units)
	resolver.begin(plan)
	resolver.dispatch(g, plan)
	return {"planner": planner, "plan": plan, "resolver": resolver, "unit": pick}


# --- movement ------------------------------------------------------------------

func test_a_pack_walks_toward_the_city() -> void:
	var rig: Dictionary = _rig()
	if rig.is_empty():
		skip("no roster or no approach lanes in this build")
		return
	var r: SiegeResolver = rig["resolver"]
	var plan: WavePlan = rig["plan"]
	var start: float = r.packs[0].path_pos
	for _i: int in 200:
		r.step(plan, _profile().siege_step_ticks)
	assert_lt(r.packs[0].path_pos, start, "a pack that never moves is not an attack")
	assert_lt(float(r.closest_cells), 1 << 20, "and its closest approach must be recorded")


func test_movement_never_leaves_the_road() -> void:
	var rig: Dictionary = _rig()
	if rig.is_empty():
		skip("no roster or no approach lanes in this build")
		return
	var r: SiegeResolver = rig["resolver"]
	var plan: WavePlan = rig["plan"]
	for _i: int in 400:
		r.step(plan, _profile().siege_step_ticks)
		assert_ge(r.packs[0].path_pos, 0.0, "a pack can never walk past the core")
	assert_le(r.packs[0].path_pos, float(plan.vectors[0].path.size() - 1),
		"nor back out beyond the map edge")


func test_reaching_the_core_is_a_breach() -> void:
	var rig: Dictionary = _rig()
	if rig.is_empty():
		skip("no roster or no approach lanes in this build")
		return
	var r: SiegeResolver = rig["resolver"]
	var plan: WavePlan = rig["plan"]
	assert_false(r.breached, "nothing has happened yet")
	r.packs[0].path_pos = 1.0
	r.step(plan, _profile().siege_step_ticks)
	assert_true(r.breached, "a pack standing on the hearth is a breach")
	assert_le(float(r.closest_cells), float(_profile().breach_radius),
		"and the closest approach says so")


# --- fire --------------------------------------------------------------------

func test_defended_lanes_kill() -> void:
	var rig: Dictionary = _rig(10)
	if rig.is_empty():
		skip("no roster or no approach lanes in this build")
		return
	var r: SiegeResolver = rig["resolver"]
	var plan: WavePlan = rig["plan"]
	plan.vectors[0].defence_dps = 500.0
	r.packs[0].path_pos = float(plan.vectors[0].envelope_to)
	for _i: int in 200:
		r.step(plan, _profile().siege_step_ticks)
	assert_eq(r.killed, 10, "a lane with five hundred damage a second empties")
	assert_eq(r.live_units(), 0, "and nothing is left standing on it")
	assert_false(r.is_active(), "so the resolver has nothing left to do")


func test_an_undefended_lane_kills_nobody() -> void:
	var rig: Dictionary = _rig(10)
	if rig.is_empty():
		skip("no roster or no approach lanes in this build")
		return
	var r: SiegeResolver = rig["resolver"]
	var plan: WavePlan = rig["plan"]
	plan.vectors[0].defence_dps = 0.0
	for _i: int in 400:
		r.step(plan, _profile().siege_step_ticks)
	assert_eq(r.killed, 0, "an open road costs them nothing")
	assert_eq(r.live_units(), 10, "and they all arrive")


func test_fire_only_reaches_inside_the_envelope() -> void:
	var rig: Dictionary = _rig(10)
	if rig.is_empty():
		skip("no roster or no approach lanes in this build")
		return
	var r: SiegeResolver = rig["resolver"]
	var plan: WavePlan = rig["plan"]
	var v: ThreatVector = plan.vectors[0]
	if v.path.size() < v.envelope_to + 20:
		skip("this lane is too short to stand off the end of")
		return
	plan.vectors[0].defence_dps = 500.0
	# Stood off well beyond the defended stretch. One step, and nothing may die:
	# a turret at the gate is not shooting at the horizon, and the player can see
	# exactly where that envelope ends because it is drawn around the chokepoint.
	r.packs[0].path_pos = float(v.envelope_to) + 15.0
	var before: int = r.killed
	r.step(plan, 1)
	assert_eq(r.killed, before, "a turret at the gate does not shoot the horizon")
	# Walk it into the envelope and the same guns bite immediately.
	r.packs[0].path_pos = float(v.envelope_to)
	r.step(plan, 20)
	assert_gt(float(r.killed), float(before), "inside the envelope they are in range")


func test_armour_matters() -> void:
	var soft: Dictionary = _rig(10)
	if soft.is_empty():
		skip("no roster or no approach lanes in this build")
		return
	var r: SiegeResolver = soft["resolver"]
	var plan: WavePlan = soft["plan"]
	var unit: ThreatUnit = soft["unit"]
	var shot: float = _profile().defence_shot
	var bare: float = maxf(1.0, shot - 0.0) / shot
	var plated: float = maxf(1.0, shot - shot * 0.5) / shot
	assert_lt(plated, bare, "armour must reduce what a shot is worth")
	# And the resolver has to apply it: same fire, twice the armour, more alive.
	plan.vectors[0].defence_dps = unit.hp * 4.0
	r.packs[0].path_pos = float(plan.vectors[0].envelope_to)
	r.step(plan, 20)
	var killed_bare: int = r.killed

	var hard: Dictionary = _rig(10)
	var r2: SiegeResolver = hard["resolver"]
	var plan2: WavePlan = hard["plan"]
	plan2.vectors[0].defence_dps = unit.hp * 4.0
	r2.packs[0].path_pos = float(plan2.vectors[0].envelope_to)
	r2.packs[0].def = _armoured(unit, shot * 0.75)
	r2.packs[0].unit_hp = maxf(1.0, r2.packs[0].def.hp)
	r2.step(plan2, 20)
	assert_le(float(r2.killed), float(killed_bare), "plating must buy survivors")


## A copy of a unit with heavier armour, for a like-for-like comparison.
func _armoured(src: ThreatUnit, armor: float) -> ThreatUnit:
	var u := ThreatUnit.new()
	u.id = src.id
	u.display_name = src.display_name
	u.hp = src.hp
	u.armor = armor
	u.speed = src.speed
	u.damage = src.damage
	u.attack_interval = src.attack_interval
	u.attack_range = src.attack_range
	u.cost = src.cost
	u.pack_size = src.pack_size
	u.role = src.role
	return u


# --- barriers -------------------------------------------------------------------

func test_a_wall_on_the_road_stops_them_and_gets_eaten() -> void:
	var build: SimSystem = world.system(&"build")
	if build == null:
		skip("no [P11] build system in this build")
		return
	var rig: Dictionary = _rig(10)
	if rig.is_empty():
		skip("no roster or no approach lanes in this build")
		return
	var planner: ApproachPlanner = rig["planner"]
	var plan: WavePlan = rig["plan"]
	var r: SiegeResolver = rig["resolver"]
	var v: ThreatVector = plan.vectors[0]

	# Put a wall on the lane, somewhere inside the defended stretch.
	var placed: int = -1
	var at: int = -1
	for i: int in range(v.envelope_to, maxi(v.envelope_from, v.envelope_to - 24), -1):
		var cell: Vector2i = planner.cell_of(v.path[i])
		world.cmd_now({"system": &"build", "op": "place", "kind": "wall",
			"cell": [cell.x, cell.y], "free": true, "instant": true})
		var b: Object = build.call("building_at", cell)
		if b != null:
			placed = int(b.get("id"))
			at = i
			break
	if placed < 0:
		skip("could not place a wall anywhere on this lane")
		return

	planner.refresh(plan.vectors)
	r.rearm(plan)
	assert_has(Array(plan.vectors[0].structures), placed, "the wall must be seen on the lane")

	var wall: Object = build.call("get_building", placed)
	var hp_before: float = float(wall.get("hp"))
	r.packs[0].path_pos = float(at) + 0.5
	for _i: int in 200:
		r.step(plan, _profile().siege_step_ticks)
	var still: Object = build.call("get_building", placed)
	if still != null:
		assert_lt(float(still.get("hp")), hp_before, "a wall in the way gets chewed on")
		assert_lt(r.packs[0].path_pos, float(at) + 1.0, "and it holds them where it stands")
	else:
		assert_ge(float(r.structures_lost), 1.0, "a wall that fell must be counted as lost")
	assert_gt(r.damage_dealt, 0.0, "the damage they dealt is recorded")


# --- the night as a whole ---------------------------------------------------------

func test_dawn_ends_the_night() -> void:
	var rig: Dictionary = _rig(8)
	if rig.is_empty():
		skip("no roster or no approach lanes in this build")
		return
	var r: SiegeResolver = rig["resolver"]
	var plan: WavePlan = rig["plan"]
	r.step(plan, 40)
	assert_true(r.is_active(), "before dawn they are on the map")
	var left: int = r.withdraw()
	assert_eq(left, 8, "everything still alive goes back out onto the plain")
	assert_false(r.is_active(), "and the night is over")
	assert_eq(r.live_units(), 0, "with nothing left on the field")


func test_the_outcome_is_complete() -> void:
	var rig: Dictionary = _rig(8)
	if rig.is_empty():
		skip("no roster or no approach lanes in this build")
		return
	var r: SiegeResolver = rig["resolver"]
	var out: Dictionary = r.outcome(3264, 1200)
	for key: String in ["spawned", "killed", "structures_lost", "closest_cells",
			"night_ticks", "heat_ok_ticks", "resolved_by"]:
		assert_has(out, key, "the post-mortem must report '%s'" % key)
	assert_eq(int(out["spawned"]), 8, "and it must count what was actually sent")
	assert_eq(String(out["resolved_by"]), "siege_model", "and say who resolved it")


func test_the_siege_model_is_deterministic() -> void:
	if _units().is_empty():
		skip("no roster in this build")
		return
	var produce: Callable = func() -> Dictionary:
		var rig: Dictionary = _rig(12)
		if rig.is_empty():
			return {}
		var r: SiegeResolver = rig["resolver"]
		var plan: WavePlan = rig["plan"]
		plan.vectors[0].defence_dps = 30.0
		for _i: int in 300:
			r.step(plan, _profile().siege_step_ticks)
		return r.to_dict(plan)
	assert_deterministic(produce, "the same siege, twice, must play out the same")


func test_state_survives_a_round_trip() -> void:
	var rig: Dictionary = _rig(9)
	if rig.is_empty():
		skip("no roster or no approach lanes in this build")
		return
	var r: SiegeResolver = rig["resolver"]
	var plan: WavePlan = rig["plan"]
	for _i: int in 60:
		r.step(plan, _profile().siege_step_ticks)
	var before: Dictionary = r.to_dict(plan)
	var r2 := SiegeResolver.new()
	r2.bind(_profile(), rig["planner"], world.system(&"build"), world.system(&"grid"), _units())
	r2.from_dict(before)
	assert_eq(r2.to_dict(plan), before, "a saved siege must load back byte for byte")


func test_view_packs_report_real_positions() -> void:
	var rig: Dictionary = _rig(6)
	if rig.is_empty():
		skip("no roster or no approach lanes in this build")
		return
	var r: SiegeResolver = rig["resolver"]
	var plan: WavePlan = rig["plan"]
	r.step(plan, 40)
	var view: Array[Dictionary] = r.view_packs(plan)
	assert_size(view, 1, "one pack on the map is one marker on the map")
	assert_eq(int(view[0]["count"]), 6, "and it says how many are in it")
	assert_between(float(view[0]["hp"]), 0.0, 1.0, "with a health fraction the HUD can draw")
	r.withdraw()
	assert_empty(r.view_packs(plan), "and nothing is drawn once they are gone")
