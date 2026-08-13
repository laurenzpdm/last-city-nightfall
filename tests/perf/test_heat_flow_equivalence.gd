extends TestCase
## [PERF] The heat solver's fast path must be the same solver.
##
## Two optimisations in HeatFlow trade recomputation for memory, and both are
## only legitimate if they are INVISIBLE in the result:
##
##   1. the cross-tick routing cache, keyed on HeatFlow._route_sig, and
##   2. the residual-route memo, keyed on that plus the saturated-tile set.
##
## A cache whose key misses one input does not fail loudly — it quietly serves a
## slightly wrong grid and the balance drifts for a hundred ticks before anyone
## notices. So this suite does not inspect the cache. It builds a city that
## genuinely chokes, runs it both ways, and demands the two simulations agree to
## the last decimal heat serialises.
##
## If this suite ever goes red, the answer is NOT to loosen the comparison. It
## means some input the router branches on is missing from the signature.

var world: SimFixture = null
var heat: SimSystem = null


func requires_systems() -> PackedStringArray:
	return PackedStringArray(["heat"])


func setup() -> void:
	world = SimFixture.new(4242).start()
	heat = world.system(&"heat")


func teardown() -> void:
	if world != null:
		world.stop()


func _cmd(d: Dictionary) -> void:
	world.cmd_now(d)


## A grid deliberately built to choke on a PIPE rather than on the boiler: one
## hearth with 120 u/s to give, a single 60 u/s conduit out of it, and ten
## radiators asking for 120 behind that conduit.
##
## That combination is the only one that reaches the code under test. The tile
## saturates, demand stays unmet, and the hearth still has heat in hand — which
## is exactly the condition under which _serve_tier reroutes over the residual
## graph. Starve the boiler instead and the solver correctly gives up without
## ever rerouting, which is how the first draft of this test proved nothing.
func _build_a_choked_city(origin: Vector2i) -> void:
	_cmd({"system": &"heat", "op": "place", "kind": "the_hearth",
		"cell": [origin.x, origin.y]})
	_cmd({"system": &"heat", "op": "line", "kind": "heat_pipe",
		"from": [origin.x + 4, origin.y], "to": [origin.x + 14, origin.y]})
	for i: int in 5:
		var x: int = origin.x + 6 + i * 2
		_cmd({"system": &"heat", "op": "place", "kind": "warmth_radiator",
			"cell": [x, origin.y + 1]})
		_cmd({"system": &"heat", "op": "place", "kind": "warmth_radiator",
			"cell": [x, origin.y - 1]})


## Everything the solver writes back onto a node, as one comparable blob.
## Deliberately taken from heat's own serialize() rather than a hand-picked
## subset: a divergence anywhere in the flow record has to show up here.
func _fingerprint() -> String:
	return JSON.stringify((heat.serialize() as Dictionary).get("buildings", []))


func _balance_sheets() -> String:
	return JSON.stringify((heat.serialize() as Dictionary).get("networks", []))


## How many buildings the grid has effectively cut off.
func _starved_count() -> int:
	var n: int = 0
	for raw: Variant in (heat.serialize() as Dictionary).get("buildings", []):
		var b: Dictionary = raw
		if float(b.get("demand", 0.0)) > 0.0 and float(b.get("served", 1.0)) < 0.05:
			n += 1
	return n


func test_the_residual_memo_changes_nothing() -> void:
	var origin: Vector2i = Vector2i(40, 40)
	_build_a_choked_city(origin)
	world.run(600)

	var cached_nodes: String = _fingerprint()
	var cached_nets: String = _balance_sheets()
	var stats: Array = heat.call("route_cache_stats")
	assert_gt(int(stats[0]), 0,
		"the run has to actually HIT the residual memo, or this test proves nothing")

	# Same seed, same city, memo off — every reroute recomputed from scratch.
	world.restart()
	heat = world.system(&"heat")
	heat.call("set_route_cache", false)
	_build_a_choked_city(origin)
	world.run(600)

	var fresh: Array = heat.call("route_cache_stats")
	assert_eq(int(fresh[0]), 0, "with the memo off nothing may be served from it")
	assert_gt(int(fresh[1]), 0, "and it must still have been rerouting")
	assert_eq(_fingerprint(), cached_nodes,
		"every building's flow record must be identical with the residual memo off")
	assert_eq(_balance_sheets(), cached_nets,
		"every network's balance sheet must be identical with the residual memo off")


func test_the_cross_tick_route_cache_changes_nothing() -> void:
	var origin: Vector2i = Vector2i(40, 40)
	_build_a_choked_city(origin)
	world.run(400)
	var cached: String = _fingerprint()

	world.restart()
	heat = world.system(&"heat")
	_build_a_choked_city(origin)
	# Throw the routing away every single tick, so the cache can never be
	# consulted and what comes out is the from-scratch answer by construction.
	for _i: int in 400:
		heat.call("invalidate_routes")
		world.run(1)

	assert_eq(_fingerprint(), cached,
		"a routing cache that survives a tick must equal the route rebuilt that tick")


## The memo is keyed on the shape of the grid. Cut the grid and it must not be
## reused: the far radiators are no longer reachable and have to go dark.
func test_a_cut_grid_is_not_served_from_a_stale_route() -> void:
	var origin: Vector2i = Vector2i(40, 40)
	_build_a_choked_city(origin)
	world.run(300)
	var nets_before: int = int((heat.call("totals") as Dictionary).get("networks", 0))
	var starved_before: int = _starved_count()

	_cmd({"system": &"heat", "op": "remove_at", "cell": [origin.x + 9, origin.y]})
	world.run(400)

	assert_gt(int((heat.call("totals") as Dictionary).get("networks", 0)), nets_before,
		"cutting the trunk must split the network")
	assert_gt(_starved_count(), starved_before,
		"the radiators past the cut must lose their heat, not keep drawing through a pipe that is gone")
