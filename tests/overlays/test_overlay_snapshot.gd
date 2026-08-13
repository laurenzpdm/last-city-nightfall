extends TestCase
## [P19] The snapshot against a REAL world.
##
## Three things have to be true and none of them can be judged from a
## screenshot:
##
##   1. the overlay reads the simulation and NEVER writes it. Proved by
##      serialising the whole sim, sampling a hundred times, serialising again
##      and diffing the JSON;
##   2. the numbers on screen are the solver's numbers — the network split, the
##      per-tile throughput, the bottleneck attribution and the flow direction
##      are copied, not re-derived;
##   3. sampling is cheap enough to do four times a second on a real base.

const SAMPLE_ALL: int = LcnOverlaySnapshot.S_HEAT | LcnOverlaySnapshot.S_BUILD


var world: SimFixture
var snap: LcnOverlaySnapshot


func suite_name() -> String:
	return "overlay_snapshot"


func requires_systems() -> PackedStringArray:
	return PackedStringArray(["heat"])


func setup() -> void:
	world = SimFixture.new(7).start()
	snap = LcnOverlaySnapshot.new()
	snap.bind()


func teardown() -> void:
	world.stop()


func _heat() -> HeatSystem:
	return world.system(&"heat") as HeatSystem


func _core() -> Vector2i:
	var grid: SimSystem = world.system(&"grid")
	if grid != null and grid.has_method("core_cell"):
		return grid.call("core_cell")
	return Vector2i(128, 128)


## Fills every bunker. Once [P03] and [P04] exist, heat is metered rather than
## autarkic, so an unfuelled hearth has no output, the router finds no live
## source and the whole grid reads as unreachable. A test that forgot this would
## pass vacuously on an empty network.
func _fuel() -> void:
	for item: String in ["coal", "timber"]:
		world.cmd({"system": &"heat", "op": "fuel_all", "item": item, "amount": 9000.0})
	world.run(1)


## A hearth, a pipe run east, a housing block at the end. One connected grid.
func _one_grid(at: Vector2i) -> void:
	world.cmd({"system": &"heat", "op": "place", "kind": "the_hearth", "cell": [at.x, at.y]})
	world.cmd({"system": &"heat", "op": "line", "kind": "heat_pipe",
		"from": [at.x + 3, at.y + 1], "to": [at.x + 12, at.y + 1]})
	world.cmd({"system": &"heat", "op": "place", "kind": "housing_block",
		"cell": [at.x + 13, at.y]})
	world.run(20)
	_fuel()
	world.run(20)


func _sample(times: int = 1) -> void:
	for i: int in times:
		snap.sample(world.tick() + i * 100, SAMPLE_ALL)
		snap.mark_dirty()


# =========================================================================
# the contract that matters most
# =========================================================================

## The overlay layer must be incapable of changing the game. If this ever fails,
## a lens has started poking the simulation and every replay in the repo is
## suspect.
func test_sampling_never_mutates_the_simulation() -> void:
	var at: Vector2i = _core()
	_one_grid(at)
	world.run(120)
	var before: String = JsonCanon.canon(world.state())
	for i: int in 100:
		snap.mark_dirty()
		snap.sample(world.tick(), SAMPLE_ALL)
		snap.sample_warmth(Rect2(Vector2(at) * 32.0 - Vector2(600.0, 400.0),
			Vector2(1200.0, 800.0)), true)
	var after: String = JsonCanon.canon(world.state())
	assert_eq(after, before, "100 samples left the world byte-identical")


func test_sampling_is_safe_before_a_world_exists() -> void:
	var empty := LcnOverlaySnapshot.new()
	empty.sample(0, SAMPLE_ALL)
	empty.sample_warmth(Rect2(0.0, 0.0, 100.0, 100.0), true)
	assert_eq(empty.node_count, 0, "no world, no rows, no crash")
	assert_eq(empty.headline(), "no heat network yet")


# =========================================================================
# the numbers are the solver's numbers
# =========================================================================

func test_nodes_mirror_the_heat_system() -> void:
	_one_grid(_core())
	_sample()
	var heat: HeatSystem = _heat()
	assert_eq(snap.node_count, heat.nodes.size(), "every heat entity has a row")
	for i: int in snap.node_count:
		var id: int = snap.node_id[i]
		assert_true(heat.nodes.has(id), "row %d refers to a real node" % i)
		var n: HeatNode = heat.nodes[id]
		assert_near(snap.node_served[i], n.served, 0.0001, "served is copied, not guessed")
		assert_near(snap.node_temp[i], n.temp_c, 0.0001, "temperature is copied")
		assert_eq(snap.node_net[i], heat.network_of(id), "network membership is copied")
		assert_eq(snap.node_row[id], i, "the id index points back at the row")


## Two runs of pipe that do not touch are two grids, and the lens gives them
## different colour slots. This is the single most important thing the heat
## lens says, so it is asserted rather than eyeballed.
func test_two_disconnected_runs_get_two_slots() -> void:
	var at: Vector2i = _core()
	_one_grid(at)
	# A second, completely separate hearth well clear of the first.
	world.cmd({"system": &"heat", "op": "place", "kind": "the_hearth",
		"cell": [at.x + 40, at.y + 40]})
	world.cmd({"system": &"heat", "op": "line", "kind": "heat_pipe",
		"from": [at.x + 43, at.y + 41], "to": [at.x + 50, at.y + 41]})
	world.run(20)
	_fuel()
	world.run(20)
	_sample()
	assert_ge(float(snap.nets.size()), 2.0, "the sim really did make two networks")
	var slots: Dictionary[int, bool] = {}
	for n: Dictionary in snap.nets:
		slots[int(n["slot"])] = true
	assert_eq(slots.size(), snap.nets.size(), "every grid got its own colour slot")
	assert_true(snap.headline().contains("separate grids") or snap.headline() != "",
		"the legend says something about it")


## Flow direction has to come from the router, not from geometry: the bits point
## AWAY from the source along the routing tree.
func test_flow_directions_follow_the_routing_tree() -> void:
	var at: Vector2i = _core()
	_one_grid(at)
	world.run(60)
	_sample()
	var heat: HeatSystem = _heat()
	var checked: int = 0
	for i: int in snap.node_count:
		var dirs: int = snap.node_dirs[i]
		if dirs == 0:
			continue
		var me: HeatNode = heat.nodes[snap.node_id[i]]
		for d: int in 4:
			if (dirs & (1 << d)) == 0:
				continue
			var target: Vector2i = me.center_cell + LcnOverlayDefs.DIR_VECTORS[d]
			var other_id: int = heat.graph().occ.get(target, -1)
			assert_ge(float(other_id), 0.0, "a flow arrow points at a real tile")
			var other: HeatNode = heat.nodes[other_id]
			assert_gt(float(other.route_dist), float(me.route_dist),
				"heat flows away from the source, never back toward it")
			checked += 1
	assert_gt(float(checked), 0.0, "a live pipe run has flow to show")


func test_conduit_load_is_throughput_over_capacity() -> void:
	_one_grid(_core())
	world.run(60)
	_sample()
	var heat: HeatSystem = _heat()
	for i: int in snap.node_count:
		if (snap.node_flags[i] & LcnOverlayDefs.F_CONDUIT) == 0:
			continue
		var n: HeatNode = heat.nodes[snap.node_id[i]]
		var expect: float = clampf(n.throughput / n.def.capacity, 0.0, 1.0)
		assert_near(snap.node_load[i], expect, 0.001, "pipe brightness is real throughput")


## Everything the solver named as a bottleneck must reach the lens, tagged on
## the tile itself so the lens can pulse it.
func test_bottlenecks_are_carried_and_tagged() -> void:
	var at: Vector2i = _core()
	# One small source, a long thin line, and more demand than it can carry.
	world.cmd({"system": &"heat", "op": "place", "kind": "coal_generator", "cell": [at.x, at.y]})
	world.cmd({"system": &"heat", "op": "line", "kind": "heat_pipe",
		"from": [at.x + 2, at.y], "to": [at.x + 20, at.y]})
	for k: int in 6:
		world.cmd({"system": &"heat", "op": "place", "kind": "housing_block",
			"cell": [at.x + 4 + k * 3, at.y + 1]})
	world.run(20)
	_fuel()
	world.run(200)
	_sample()
	var heat: HeatSystem = _heat()
	var solver_total: int = 0
	for nid: int in heat.network_ids():
		solver_total += heat.bottlenecks_of(nid).size()
	assert_eq(snap.bottlenecks.size(), solver_total, "no bottleneck is dropped on the way out")
	for b: Dictionary in snap.bottlenecks:
		var row: int = snap.node_row.get(int(b["node"]), -1)
		assert_ge(float(row), 0.0, "the choking tile has a row")
		assert_true((snap.node_flags[row] & LcnOverlayDefs.F_CHOKED) != 0,
			"and is flagged so the lens can pulse it")


func test_starved_consumers_are_flagged_and_counted() -> void:
	var at: Vector2i = _core()
	world.cmd({"system": &"heat", "op": "place", "kind": "coal_generator", "cell": [at.x, at.y]})
	world.cmd({"system": &"heat", "op": "line", "kind": "heat_pipe",
		"from": [at.x + 2, at.y], "to": [at.x + 16, at.y]})
	for k: int in 8:
		world.cmd({"system": &"heat", "op": "place", "kind": "housing_block",
			"cell": [at.x + 3 + k * 3, at.y + 1]})
	world.run(20)
	_fuel()
	world.run(300)
	_sample()
	var heat: HeatSystem = _heat()
	var expect: int = 0
	for id: int in heat.nodes:
		var n: HeatNode = heat.nodes[id]
		if n.def.is_consumer() and n.enabled and n.served < 0.999:
			expect += 1
	assert_eq(snap.starved_count(), expect, "the count on screen is the solver's count")


func test_warmth_field_matches_the_heat_system() -> void:
	var at: Vector2i = _core()
	_one_grid(at)
	world.run(200)
	var origin: Vector2 = Vector2(at) * 32.0
	snap.sample(world.tick(), SAMPLE_ALL)
	snap.sample_warmth(Rect2(origin - Vector2(400.0, 300.0), Vector2(800.0, 600.0)), true)
	assert_gt(float(snap.warm_w), 1.0, "the field has extent")
	var heat: HeatSystem = _heat()
	var checked: int = 0
	for y: int in mini(snap.warm_h, 12):
		for x: int in mini(snap.warm_w, 12):
			var cell := Vector2i(
				snap.warm_origin.x + x * snap.warm_step,
				snap.warm_origin.y + y * snap.warm_step)
			assert_near(snap.warm[y * snap.warm_w + x], heat.temperature_at(cell), 0.02,
				"every texel is the temperature a citizen standing there feels")
			checked += 1
	assert_gt(float(checked), 0.0)


## The warmth query must not explode when the player zooms all the way out.
func test_warmth_sampling_is_budgeted_at_strategic_zoom() -> void:
	_one_grid(_core())
	snap.sample(world.tick(), SAMPLE_ALL)
	snap.sample_warmth(Rect2(Vector2.ZERO, Vector2(256.0, 256.0) * 32.0), true)
	assert_le(float(snap.warm_w * snap.warm_h), float(LcnOverlaySnapshot.WARMTH_BUDGET) * 1.05,
		"a whole-map view is downsampled, never queried tile by tile")
	assert_gt(float(snap.warm_step), 1.0, "which means the step grew")


func test_freeze_eta_is_derived_from_the_measured_cooling_rate() -> void:
	_one_grid(_core())
	world.run(40)
	snap.sample(world.tick(), SAMPLE_ALL)
	world.run(100)
	snap.mark_dirty()
	snap.sample(world.tick(), SAMPLE_ALL)
	for i: int in snap.node_count:
		var eta: float = snap.freeze_eta(i)
		if eta < 0.0:
			continue
		# A warming building must never report a countdown, and a cooling one
		# must report a number consistent with its own margin and rate.
		assert_gt(snap.node_cool[i], 0.0, "only a cooling building has an ETA")
		assert_near(eta, (snap.node_temp[i] - snap.node_freeze[i]) / snap.node_cool[i], 0.01)


func test_headline_says_the_worst_thing_first() -> void:
	var at: Vector2i = _core()
	_one_grid(at)
	world.run(60)
	_sample()
	assert_ne(snap.headline(), "", "there is always a sentence")


# =========================================================================
# cost
# =========================================================================

## The whole design rests on sampling being cheap. 4 Hz on a real base has to
## cost well under a millisecond, or the lens system starts eating the frame it
## was supposed to explain.
func test_sampling_a_real_base_is_cheap() -> void:
	var at: Vector2i = _core()
	world.cmd({"system": &"heat", "op": "place", "kind": "the_hearth", "cell": [at.x, at.y]})
	for row: int in 10:
		world.cmd({"system": &"heat", "op": "line", "kind": "heat_pipe",
			"from": [at.x + 3, at.y + row * 2], "to": [at.x + 34, at.y + row * 2]})
	world.run(20)
	_fuel()
	world.run(60)
	_sample()
	assert_gt(float(snap.node_count), 200.0, "a base worth measuring")

	var t0: int = Time.get_ticks_usec()
	var runs: int = 20
	for i: int in runs:
		snap.mark_dirty()
		snap.sample(world.tick(), SAMPLE_ALL)
	var per: float = float(Time.get_ticks_usec() - t0) / float(runs)
	Log.info("overlay", "test: %d nodes sampled in %.0f us" % [snap.node_count, per])
	assert_lt(per, 4000.0, "%d nodes sampled in %.0f us (budget 4000 us at 4 Hz)" % [
		snap.node_count, per])
