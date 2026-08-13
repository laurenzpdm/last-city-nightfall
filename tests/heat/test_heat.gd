extends TestCase
## [P02] Heat & Power Network.
##
## The heat solver is the load-bearing system in the whole game and it shipped
## with an empty tests/heat/. These tests are written against BEHAVIOUR, not
## against the implementation: every one of them states a rule a player can feel
## and then measures it on a live network.
##
## Networks are built through heat's own command surface (op "place" / "line")
## with ids above LOCAL_ID_BASE, so the build system is not involved and each
## case owns exactly the graph it describes.

const BASE: int = 1000000

var world: SimFixture = null
var heat: SimSystem = null


func requires_systems() -> PackedStringArray:
	return PackedStringArray(["heat"])


func setup() -> void:
	world = SimFixture.new(7).start()
	heat = world.system(&"heat")


func teardown() -> void:
	if world != null:
		world.stop()


# --- helpers -----------------------------------------------------------------

## An empty patch of ground far from anything the world generator placed.
func _origin() -> Vector2i:
	return Vector2i(40, 40)


func _place(kind: String, cell: Vector2i) -> void:
	world.cmd_now({"system": &"heat", "op": "place", "kind": kind, "cell": [cell.x, cell.y]})


func _line(kind: String, from: Vector2i, to: Vector2i) -> void:
	world.cmd_now({"system": &"heat", "op": "line", "kind": kind,
		"from": [from.x, from.y], "to": [to.x, to.y]})


## id of whatever heat owns at a cell, or -1.
func _id_at(cell: Vector2i) -> int:
	var g: HeatGraph = heat.call("graph")
	return int(g.occ.get(cell, -1))


func _node(cell: Vector2i) -> HeatNode:
	var id: int = _id_at(cell)
	return null if id < 0 else (heat.get("nodes") as Dictionary).get(id)


## id -> [route_dist, route_eta] for every node heat currently owns.
func _routing_snapshot() -> Dictionary:
	var out: Dictionary = {}
	var nodes: Dictionary = heat.get("nodes")
	var keys: Array = nodes.keys()
	keys.sort()
	for k: int in keys:
		var n: HeatNode = nodes[k]
		out[k] = [n.route_dist, n.route_eta]
	return out


## A hearth, a run of pipe and a radiator at the far end. Returns the radiator.
func _corridor(length: int, pipe: String = "heat_pipe") -> HeatNode:
	var o: Vector2i = _origin()
	_place("the_hearth", o)
	_line(pipe, o + Vector2i(5, 2), o + Vector2i(5 + length - 1, 2))
	_place("warmth_radiator", o + Vector2i(5 + length, 2))
	world.run(10)
	return _node(o + Vector2i(5 + length, 2))


# --- the network itself ------------------------------------------------------

func test_a_line_of_pipe_is_one_network() -> void:
	var o: Vector2i = _origin()
	_place("the_hearth", o)
	_line("heat_pipe", o + Vector2i(5, 2), o + Vector2i(24, 2))
	world.run(5)
	var ids: PackedInt32Array = heat.call("network_ids")
	assert_size(ids, 1, "a hearth touching a connected run of pipe is one network")
	var stats: Dictionary = heat.call("network_stats", ids[0])
	assert_eq(int(stats.get("nodes", 0)), 21, "every piece is a member of it")
	assert_gt(float(stats.get("supply", 0.0)), 0.0, "and the hearth is supplying it")


func test_cutting_the_line_splits_the_network_in_two() -> void:
	var o: Vector2i = _origin()
	_place("the_hearth", o)
	_line("heat_pipe", o + Vector2i(5, 2), o + Vector2i(24, 2))
	_place("warmth_radiator", o + Vector2i(25, 2))
	world.run(5)
	assert_size(heat.call("network_ids"), 1, "one network before the cut")
	var far: HeatNode = _node(o + Vector2i(25, 2))
	assert_near(far.served, 1.0, 0.001, "the radiator is served while connected")

	world.cmd_now({"system": &"heat", "op": "remove_at", "cell": [o.x + 15, o.y + 2]})
	world.run(3)
	assert_size(heat.call("network_ids"), 2, "removing one pipe splits the run in two")
	# Long enough for its own thermal mass to run dry: a radiator rides out a
	# short cut on stored heat, which is the point of thermal mass.
	world.run(200)
	assert_lt(far.served, 0.05, "and the far radiator is cut off from every source")


func test_conservation_holds_on_a_starved_network() -> void:
	# One coal generator against far more demand than it can cover. Whatever it
	# produces has to end up delivered, lost or stored — nothing may appear and
	# nothing may vanish.
	var o: Vector2i = _origin()
	_place("coal_generator", o)
	_line("heat_pipe", o + Vector2i(3, 0), o + Vector2i(3, 12))
	for i: int in 5:
		_place("warmth_radiator", o + Vector2i(4, i * 2))
	world.run(60)
	var nid: int = heat.call("network_of", _id_at(o))
	var s: Dictionary = heat.call("network_stats", nid)
	var used: float = float(s.get("supply_used", 0.0))
	var out: float = float(s.get("delivered", 0.0)) + float(s.get("loss", 0.0)) \
		+ float(s.get("charge", 0.0)) - float(s.get("discharge", 0.0))
	assert_near(used, out, 0.0005,
		"supply_used(%.5f) must equal delivered + loss + charge - discharge(%.5f)" % [used, out])
	assert_gt(float(s.get("deficit", 0.0)), 0.0, "and the network is genuinely short")


func test_distance_costs_heat_and_a_booster_pump_buys_it_back() -> void:
	var far: HeatNode = _corridor(30)
	assert_not_null(far, "the far radiator exists")
	assert_eq(far.route_dist, 31, "it is 31 hops from the hearth")
	var plain_eta: float = far.route_eta
	assert_lt(plain_eta, 0.85, "thirty tiles of plain pipe costs real efficiency (%.4f)" % plain_eta)

	# Same corridor, but with a repeater in the middle.
	world.restart()
	heat = world.system(&"heat")
	var o: Vector2i = _origin()
	_place("the_hearth", o)
	_line("heat_pipe", o + Vector2i(5, 2), o + Vector2i(19, 2))
	_place("heat_booster_pump", o + Vector2i(20, 2))
	_line("heat_pipe", o + Vector2i(21, 2), o + Vector2i(34, 2))
	_place("warmth_radiator", o + Vector2i(35, 2))
	world.run(20)
	var boosted: HeatNode = _node(o + Vector2i(35, 2))
	assert_not_null(boosted, "the boosted radiator exists")
	assert_gt(boosted.route_eta, plain_eta,
		"a booster pump at the halfway point must beat the same distance without one (%.4f vs %.4f)"
			% [boosted.route_eta, plain_eta])


func test_insulated_pipe_loses_less_than_plain_pipe() -> void:
	var plain: HeatNode = _corridor(24, "heat_pipe")
	var plain_eta: float = plain.route_eta
	world.restart()
	heat = world.system(&"heat")
	world.cmd_now({"system": &"build", "op": "grant_unlock", "unlock": "pipe_lagging"})
	var lagged: HeatNode = _corridor(24, "heat_pipe_insulated")
	assert_gt(lagged.route_eta, plain_eta,
		"insulated pipe must deliver more over the same distance (%.4f vs %.4f)"
			% [lagged.route_eta, plain_eta])


# --- the rules a player is supposed to be able to feel ------------------------

func test_a_shortfall_sheds_from_the_bottom_of_the_priority_list() -> void:
	var o: Vector2i = _origin()
	_place("coal_generator", o)
	_line("heat_pipe", o + Vector2i(3, 0), o + Vector2i(3, 14))
	# Life support, defence and industry all hanging off one under-sized burner.
	_place("housing_block", o + Vector2i(4, 0))
	_place("warmth_radiator", o + Vector2i(4, 5))
	_place("turret_mount", o + Vector2i(4, 8))
	_place("workshop", o + Vector2i(4, 11))
	world.run(80)
	var housing: HeatNode = _node(o + Vector2i(4, 0))
	var radiator: HeatNode = _node(o + Vector2i(4, 5))
	var turret: HeatNode = _node(o + Vector2i(4, 8))
	var shop: HeatNode = _node(o + Vector2i(4, 11))
	assert_not_null(housing)
	assert_not_null(shop)
	assert_gt(housing.priority, shop.priority, "housing outranks industry")
	assert_ge(housing.served, radiator.served - 0.001, "housing is served before warmth")
	assert_ge(radiator.served, turret.served - 0.001, "warmth is served before defence")
	assert_ge(turret.served, shop.served - 0.001, "defence is served before industry")
	assert_lt(shop.served, 0.999, "and something at the bottom actually went short")


func test_every_starved_building_can_name_what_choked_it() -> void:
	var o: Vector2i = _origin()
	_place("coal_generator", o)
	_line("heat_pipe", o + Vector2i(3, 0), o + Vector2i(3, 10))
	for i: int in 4:
		_place("workshop", o + Vector2i(4, i * 3))
	world.run(60)
	var starved: int = 0
	var explained: int = 0
	for i: int in 4:
		var n: HeatNode = _node(o + Vector2i(4, i * 3))
		if n == null or n.served >= 0.999:
			continue
		starved += 1
		var why: Dictionary = heat.call("bottleneck_of", n.id)
		if not why.is_empty() and int(why.get("node", -1)) >= 0:
			explained += 1
	assert_gt(float(starved), 0.0, "the setup really does starve somebody")
	assert_eq(explained, starved, "every browned-out building points at the tile that choked it")


func test_switching_a_pipe_off_actually_stops_the_heat() -> void:
	var far: HeatNode = _corridor(20)
	assert_not_null(far)
	assert_near(far.served, 1.0, 0.01, "served while the line is intact")
	var mid: int = _id_at(_origin() + Vector2i(15, 2))
	assert_gt(float(mid), 0.0, "there is a pipe at the midpoint")

	world.cmd_now({"system": &"heat", "op": "set_enabled", "id": mid, "on": false})
	world.run(200)
	assert_lt(far.served, 0.05,
		"a switched-off conduit must carry nothing — the player's switch is not decoration")

	world.cmd_now({"system": &"heat", "op": "set_enabled", "id": mid, "on": true})
	world.run(40)
	assert_gt(far.served, 0.9, "and switching it back on restores the line")


func test_a_frozen_generator_takes_its_network_down() -> void:
	var o: Vector2i = _origin()
	_place("coal_generator", o)
	_line("heat_pipe", o + Vector2i(3, 0), o + Vector2i(3, 6))
	_place("warmth_radiator", o + Vector2i(4, 5))
	world.run(20)
	var gen: HeatNode = _node(o)
	assert_not_null(gen)
	assert_gt(gen.output, 0.0, "the generator is burning to start with")
	gen.frozen = true
	gen.temp_c = gen.def.freeze_below - 20.0
	world.run(2)
	assert_near(gen.output, 0.0, 0.001, "a frozen generator produces nothing")
	var rad: HeatNode = _node(o + Vector2i(4, 5))
	world.run(200)
	assert_lt(rad.served, 0.05, "and everything downstream of it goes dark")


# --- the caches must not be able to lie --------------------------------------

func test_the_cached_routing_equals_a_fresh_solve() -> void:
	# heat_system.gd ships invalidate_routes() with the comment "tests use it to
	# prove the cached routing equals the fresh one". This is that test.
	var o: Vector2i = _origin()
	_place("the_hearth", o)
	_line("heat_pipe", o + Vector2i(5, 2), o + Vector2i(24, 2))
	_place("heat_booster_pump", o + Vector2i(25, 2))
	_line("heat_pipe", o + Vector2i(26, 2), o + Vector2i(38, 2))
	_place("warmth_radiator", o + Vector2i(39, 2))
	_place("workshop", o + Vector2i(10, 3))
	_place("housing_block", o + Vector2i(16, 3))
	world.run(120)

	var cached: Dictionary = _routing_snapshot()
	heat.call("invalidate_routes")
	world.run(1)
	var fresh: Dictionary = _routing_snapshot()
	var keys: Array = cached.keys()
	keys.sort()
	var drift: PackedStringArray = PackedStringArray()
	for k: int in keys:
		var a: Array = cached[k]
		var b: Array = fresh.get(k, [])
		if b.is_empty() or int(a[0]) != int(b[0]) or absf(float(a[1]) - float(b[1])) > 0.0005:
			drift.append("#%d dist %s->%s eta %s->%s" % [k, a[0], b[0], a[1], b[1]])
	assert_empty(drift, "cached routing must be the same answer a fresh solve gives")


func test_a_dead_repeater_stops_boosting_on_the_very_next_tick() -> void:
	# The route cache used to key on live SOURCES only, so flipping a booster
	# pump's repeater state changed nothing until some unrelated event happened
	# to dirty the cache. Identical world state, two different answers.
	var o: Vector2i = _origin()
	_place("the_hearth", o)
	_line("heat_pipe", o + Vector2i(5, 2), o + Vector2i(19, 2))
	_place("heat_booster_pump", o + Vector2i(20, 2))
	_line("heat_pipe", o + Vector2i(21, 2), o + Vector2i(34, 2))
	_place("warmth_radiator", o + Vector2i(35, 2))
	world.run(60)
	var far: HeatNode = _node(o + Vector2i(35, 2))
	var pump: HeatNode = _node(o + Vector2i(20, 2))
	assert_not_null(far)
	assert_not_null(pump)
	var boosted_eta: float = far.route_eta

	pump.repeater_live = false
	world.run(1)
	assert_lt(far.route_eta, boosted_eta - 0.0005,
		"a dead booster pump must stop boosting immediately (%.4f vs %.4f)"
			% [far.route_eta, boosted_eta])

	pump.repeater_live = true
	world.run(1)
	assert_near(far.route_eta, boosted_eta, 0.0005, "and start again when it recovers")


func test_incremental_components_match_a_full_rebuild() -> void:
	var o: Vector2i = _origin()
	_place("the_hearth", o)
	_line("heat_pipe", o + Vector2i(5, 2), o + Vector2i(30, 2))
	_line("heat_pipe", o + Vector2i(15, 3), o + Vector2i(15, 12))
	_place("warmth_radiator", o + Vector2i(16, 12))
	world.run(5)
	var g: HeatGraph = heat.call("graph")
	var before: String = str(g.partition_signature())
	world.cmd_now({"system": &"heat", "op": "remove_at", "cell": [o.x + 20, o.y + 2]})
	world.run(3)
	var incremental: String = str(g.partition_signature())
	heat.call("rebuild_networks")
	world.run(1)
	assert_eq(str(g.partition_signature()), incremental,
		"the incrementally maintained components must equal a from-scratch rebuild")
	assert_ne(incremental, before, "and the removal really did change the partition")


# --- the seams other parts rely on -------------------------------------------

func test_the_view_can_ask_which_things_are_warm() -> void:
	var o: Vector2i = _origin()
	_place("the_hearth", o)
	_line("heat_pipe", o + Vector2i(5, 2), o + Vector2i(14, 2))
	_place("warmth_radiator", o + Vector2i(15, 2))
	world.run(80)
	assert_true(heat.has_method("heat_sources_for_view"),
		"[P13] renders warm light off this contract; it has to exist")
	var srcs: Array = heat.call("heat_sources_for_view")
	assert_not_empty(srcs, "a lit hearth and a served radiator are warm things")
	var lit: Dictionary = srcs[0]
	for key: String in ["pos", "radius", "intensity"]:
		assert_has(lit, key, "a source carries %s" % key)
	assert_gt(float(lit["radius"]), 0.0, "with a real radius")
	assert_between(float(lit["intensity"]), 0.0, 1.0, "and an intensity the renderer can scale")

	# Switch the hearth off: the world must visibly go dark.
	var before: int = srcs.size()
	world.cmd_now({"system": &"heat", "op": "set_enabled", "id": _id_at(o), "on": false})
	world.run(120)
	assert_lt(float((heat.call("heat_sources_for_view") as Array).size()), float(before),
		"switching the hearth off must take warm things off the map")


func test_a_wall_is_not_a_heat_entity_and_is_never_offered_twice() -> void:
	# The missing [P11]<->[P02] handshake: heat used to re-offer every plain
	# building on the map, every tick, forever, and rebuild its definition each
	# time. 1500 walls cost 28 ms of a 50 ms tick.
	assert_false(heat.call("register_building", 500001, &"wall", Vector2i(60, 60)),
		"a wall carries no heat behaviour")
	assert_false(heat.call("has_building", 500001), "so heat does not own it")
	var totals: Dictionary = heat.call("totals")
	assert_eq(int(totals.get("buildings", -1)), 0, "and it is not on the network")


func test_temperature_at_a_tile_is_ambient_plus_what_the_grid_delivers() -> void:
	var o: Vector2i = _origin()
	var cold: float = heat.call("temperature_at", o + Vector2i(40, 40))
	assert_near(cold, heat.call("ambient"), 0.001, "far from any fire, a tile is just the weather")
	_place("the_hearth", o)
	world.run(120)
	var warm: float = heat.call("temperature_at", o + Vector2i(2, 2))
	assert_gt(warm, cold + 1.0, "standing in the hearth is warmer than standing outside")
	assert_near(heat.call("warmth_at", o + Vector2i(2, 2)), warm - float(heat.call("ambient")), 0.001,
		"warmth_at is exactly the difference")


func test_the_whole_heat_system_replays_identically() -> void:
	var script: Dictionary = {
		1: [{"system": &"heat", "op": "place", "kind": "the_hearth", "cell": [40, 40]}],
		4: [{"system": &"heat", "op": "line", "kind": "heat_pipe", "from": [45, 42], "to": [70, 42]}],
		9: [{"system": &"heat", "op": "place", "kind": "warmth_radiator", "cell": [71, 42]}],
		20: [{"system": &"heat", "op": "place", "kind": "coal_generator", "cell": [45, 46]}],
		40: [{"system": &"heat", "op": "remove_at", "cell": [55, 42]}],
		60: [{"system": &"heat", "op": "set_priority", "id": BASE, "priority": 95}],
	}
	var diff: PackedStringArray = SimFixture.replay_diff(7, 200, script)
	assert_empty(diff, "the same heat script on the same seed must produce the same world")
