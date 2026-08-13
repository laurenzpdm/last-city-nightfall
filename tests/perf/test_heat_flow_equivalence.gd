extends TestCase
## [PERF] The heat solver's fast path must be the same solver.
##
## Two optimisations in HeatFlow trade recomputation for memory, and both of
## them are only legitimate if they are INVISIBLE in the result:
##
##   1. the cross-tick routing cache, keyed on HeatFlow._route_sig, and
##   2. the residual-route memo, keyed on that plus the saturated-tile set.
##
## A cache whose key misses one input does not fail loudly — it quietly serves a
## slightly wrong grid and the balance drifts. So this suite does not inspect the
## cache. It builds a real city that browns out (which is the only state where
## residual rerouting happens at all), runs it both ways, and demands the two
## simulations agree to the last decimal it serialises.
##
## If this suite ever goes red, the answer is NOT to loosen the comparison. It
## means some input the router branches on is missing from the signature.

const BASE: int = 1000000

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


## A grid deliberately built to starve: one generator, a long undersized trunk,
## and far more radiators hanging off it than the trunk can carry. That is the
## shape that saturates a tile, leaves demand unmet and therefore reroutes over
## the residual graph — the exact path the memo short-circuits.
func _build_a_starving_city(origin: Vector2i) -> void:
	_cmd({"system": &"heat", "op": "place", "kind": "coal_generator",
		"cell": [origin.x, origin.y]})
	_cmd({"system": &"heat", "op": "line", "kind": "heat_pipe",
		"from": [origin.x + 2, origin.y], "to": [origin.x + 40, origin.y]})
	for i: int in 12:
		var x: int = origin.x + 4 + i * 3
		_cmd({"system": &"heat", "op": "line", "kind": "heat_pipe",
			"from": [x, origin.y + 1], "to": [x, origin.y + 4]})
		_cmd({"system": &"heat", "op": "place", "kind": "warmth_radiator",
			"cell": [x, origin.y + 5]})
		_cmd({"system": &"heat", "op": "line", "kind": "heat_pipe",
			"from": [x, origin.y - 1], "to": [x, origin.y - 4]})
		_cmd({"system": &"heat", "op": "place", "kind": "warmth_radiator",
			"cell": [x, origin.y - 5]})


## Everything the solver writes back onto a node, as one comparable blob.
## Deliberately taken from heat's own serialize() rather than a hand-picked
## subset: a divergence anywhere in the flow record has to show up here.
func _fingerprint() -> String:
	var state: Dictionary = heat.serialize()
	return JSON.stringify(state.get("buildings", []))


func _totals() -> String:
	return JSON.stringify((heat.serialize() as Dictionary).get("networks", []))


func test_the_residual_memo_changes_nothing() -> void:
	var origin: Vector2i = Vector2i(40, 40)
	_build_a_starving_city(origin)
	world.run(600)

	var cached_nodes: String = _fingerprint()
	var cached_nets: String = _totals()
	var stats: Array = heat.call("route_cache_stats")
	assert_gt(int(stats[0]), 0,
		"the run has to actually HIT the residual memo, or this test proves nothing")

	# Same seed, same script, memo off.
	world.restart()
	heat = world.system(&"heat")
	heat.call("set_route_cache", false)
	_build_a_starving_city(origin)
	world.run(600)

	assert_eq(_fingerprint(), cached_nodes,
		"every building's flow record must be identical with the residual memo off")
	assert_eq(_totals(), cached_nets,
		"every network's balance sheet must be identical with the residual memo off")
	var fresh: Array = heat.call("route_cache_stats")
	assert_eq(int(fresh[0]), 0, "with the memo off nothing may be served from it")


func test_the_cross_tick_route_cache_changes_nothing() -> void:
	var origin: Vector2i = Vector2i(40, 40)
	_build_a_starving_city(origin)
	world.run(400)
	var cached: String = _fingerprint()

	world.restart()
	heat = world.system(&"heat")
	_build_a_starving_city(origin)
	# Throw the routing away every single tick: the cache can never be consulted,
	# so what comes out is the from-scratch answer by construction.
	for _i: int in 400:
		heat.call("invalidate_routes")
		world.run(1)

	assert_eq(_fingerprint(), cached,
		"a routing cache that survives a tick must equal the route rebuilt that tick")


## The memo must not survive a change to the thing it was keyed on. Freezing a
## trunk changes which tiles conduct, and a stale route would keep pushing heat
## down a dead pipe.
func test_a_changed_grid_invalidates_the_memo() -> void:
	var origin: Vector2i = Vector2i(40, 40)
	_build_a_starving_city(origin)
	world.run(300)
	var before: float = float((heat.call("totals") as Dictionary).get("delivered", 0.0))
	assert_gt(before, 0.0, "the city has to be receiving heat before we cut it")

	# Cut the trunk in half. The far radiators become unreachable and delivery
	# must fall — if the memo were stale they would keep drawing through a pipe
	# that is no longer there.
	_cmd({"system": &"heat", "op": "remove_at", "cell": [origin.x + 20, origin.y]})
	world.run(60)
	var after: float = float((heat.call("totals") as Dictionary).get("delivered", 0.0))
	assert_lt(after, before,
		"cutting the trunk must reduce delivered heat (%.2f -> %.2f)" % [before, after])
	var nets: int = int((heat.call("totals") as Dictionary).get("networks", 0))
	assert_ge(nets, 2, "cutting the trunk must split the network in two")
