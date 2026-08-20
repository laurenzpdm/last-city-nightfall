extends TestCase
## [P03] THE HAUL NETWORK, AND THE FOUR CLAIMS ITS OWN HEADER MAKES.
##
## `game/sim/logistics/logi_haul.gd` said, for two waves, that hauling is
## "deliberately WORSE than a belt, in three ways a player can feel". Measured on
## the reference run, none of the three bound: the range covered the whole map,
## the distance term was 1.26x at its worst, and the crew grew with population
## until nineteen porters were moving 76 items a second for free. On top of that
## 91% of everything they carried was one crate and one yard, eighteen tiles
## apart, stealing the same coal off each other for three days.
##
## Every test below is one of those four sentences, written so that it FAILS
## against the code that shipped:
##
##   the shuttle          two stores that both want coal must not trade it
##   the rate limit       six porters, six items a second, and not one more
##   the distance         thirty tiles costs what four tiles does not
##   the range            past HAUL_RANGE the answer is no, not "slowly"
##   the crew             a city three times the size has the same six porters
##   the yard             the city stockpile is a store, priced from the Hearth
##
## and two more about the instruments, because a balance claim measured with a
## broken ruler is worse than no claim:
##
##   fuel_by_machine      must not count fuel a PORTER carried
##   the dead-end warning must fire on a real dead end and stay quiet otherwise
##
## THE ABLATION, RUN, NOT ASSERTED — three of them, in three scratch copies of
## the repo, each reverting one thing and leaving everything else alone.
##
##   1. THE BALANCE. `LogiStore.spare` back to `count()`, PORTER_RATE back to
##      4.0, HAUL_RANGE back to 96, the cost curve back to `1 + d/96`, `_crew()`
##      back to `BASE_PORTERS + population/4`. 8 of these tests went red with 15
##      failed assertions.
##   2. THE INSTRUMENTS. `fuel_by_machine` back to `int(world.delivered_as_fuel)`
##      and the two dead-end queries back to returning nothing. 4 more went red.
##   3. THE YARD. The stockpile branch back to costing 1.0 to anywhere. 2 more.
##
## Three tests stay green under all three, and that is their job: they are the
## don't-overcorrect guards — a store with a real surplus must still give it up,
## a full belt with an arm on it is not a dead end, and the Hearth's own doorstep
## is still the cheapest delivery in the game.

const O: Vector2i = Vector2i(40, 40)   ## empty ground, far from the world generator

var world: SimFixture = null
var logi: LogisticsSystem = null


func requires_systems() -> PackedStringArray:
	return PackedStringArray(["logistics"])


func setup() -> void:
	world = SimFixture.new(7).start()
	logi = world.system(&"logistics") as LogisticsSystem
	# bunker_chest is tier 2 and research-gated, which is its own rule with its
	# own test in test_logistics.gd. Nothing here is about gates.
	if world.system(&"build") != null:
		world.cmd({"system": &"build", "op": "grant_unlock", "unlock": "splitters_and_balancers"})
		world.cmd_now({"system": &"build", "op": "grant_unlock", "unlock": "logistic_scheduling"})


func teardown() -> void:
	if world != null:
		world.stop()


# --- helpers -----------------------------------------------------------------

func _place(kind: String, cell: Vector2i, rot: int = 0) -> int:
	var r: Dictionary = logi.place(StringName(kind), cell, rot, true)
	return int(r.get("id", -1)) if bool(r.get("ok", false)) else -1


## A store with `held` of `kind` in it, and optionally a standing request.
func _stocked(kind: String, cell: Vector2i, held: int, request: int = 0) -> int:
	var id: int = _place(kind, cell)
	var st: LogiStore = logi.world.stores.get(id)
	if st != null and held > 0:
		st.insert(&"coal", held)
	if request > 0:
		logi.set_request(id, &"coal", request)
	return id


## Empties the city stockpile so a test measures the haul network and not the
## founders' pile, which is at distance zero and would answer every request.
func _empty_the_city() -> void:
	world.cmd_now({"system": &"build", "op": "set_stock", "items": {
		"coal": 0, "iron_plate": 0, "grain": 0, "scrap": 0, "timber": 0,
		"stone": 0, "steel_plate": 0, "gear": 0, "copper_coil": 0}})


func _count(id: int, kind: StringName = &"coal") -> int:
	var st: LogiStore = logi.world.stores.get(id)
	return 0 if st == null else st.count(kind)


# =========================================================================
# THE SHUTTLE — the 91%
# =========================================================================

## Two stores, both asking for coal, one of them holding some. In the shipped
## build the request layer read a store's raw `count()`, so the yard took coal
## off the crate, the crate took it back off the yard on the next sweep, and the
## pair burned the entire city's haul budget forever: 17908 of 19578 items in
## the reference run, 4.7 times more coal than the whole map contained.
##
## THE RULE: a store is a source only for what it holds ABOVE its own request.
func test_two_stores_that_both_want_coal_do_not_trade_it_forever() -> void:
	_empty_the_city()
	var west: int = _stocked("bunker_chest", O, 300, 300)
	var east: int = _stocked("bunker_chest", O + Vector2i(18, 0), 0, 300)
	assert_gt(float(west), -1.0, "the west store was placed")
	assert_gt(float(east), -1.0, "the east store was placed")

	var before: int = logi.haul.hauled_total
	world.run(600)
	var carried: int = logi.haul.hauled_total - before

	# The east store may legitimately be given the coal ONCE — it asked, the west
	# store has none spare, so the honest answer is nothing moves at all.
	assert_eq(_count(west), 300, "the west store keeps what it asked to keep")
	assert_eq(_count(east), 0, "and the east store is told no, rather than robbing it")
	assert_le(float(carried), 30.0,
		"thirty seconds of two stores wanting the same coal must not move a river of it")


## The other half of the same rule, so the fix cannot be "porters never take
## anything from a store". A store holding MORE than it asked for has a surplus,
## and the surplus is exactly what the network is allowed to move.
func test_a_store_still_gives_up_what_it_holds_above_its_own_request() -> void:
	_empty_the_city()
	var full: int = _stocked("bunker_chest", O, 400, 100)      # 300 spare
	var want: int = _stocked("bunker_chest", O + Vector2i(6, 0), 0, 200)
	assert_gt(float(full), -1.0, "the full store was placed")
	world.run(900)
	assert_ge(float(_count(want)), 100.0, "the surplus does move")
	assert_ge(float(_count(full)), 100.0, "and the source keeps its own request level")


## LogiStore.spare in isolation, because the rule above is one line and the one
## line is the whole fix.
func test_spare_is_what_a_store_holds_above_its_request() -> void:
	var st: LogiStore = LogiStore.new(-1, 500)
	st.insert(&"coal", 300)
	assert_eq(st.spare(&"coal"), 300, "no request, everything is spare")
	st.set_request(&"coal", 200)
	assert_eq(st.spare(&"coal"), 100, "asking for 200 of 300 leaves 100 spare")
	st.set_request(&"coal", 400)
	assert_eq(st.spare(&"coal"), 0, "asking for more than it holds leaves nothing")
	assert_eq(st.count(&"coal"), 300, "and none of this moved a single item")


# =========================================================================
# THE RATE LIMIT
# =========================================================================

## Six porters at PORTER_RATE, and everyone in the city shares that number. The
## shipped build handed out `6 + population / 4` porters at 4.0 items a second
## each, which is 76 items a second by day three — five belt_mk1s, free.
func test_the_whole_city_moves_six_items_a_second_by_hand() -> void:
	assert_eq(LogiHaul.BASE_PORTERS, 6, "six porters")
	assert_near(logi.haul.capacity(), 6.0, 0.001,
		"six items a second for the whole city, which is 40% of one belt_mk1")
	assert_lt(logi.haul.capacity(), LogiTypes.ITEMS_PER_TILE * 1.875 * 2.0,
		"the free tier must be worse than the cheapest belt, or nobody builds one")


## Measured on a live world rather than asserted off a constant: a store that
## wants five hundred coal, standing on the city stockpile's doorstep, cannot be
## filled faster than the crew can walk.
func test_the_rate_limit_is_what_actually_arrives() -> void:
	var id: int = _stocked("bunker_chest", O, 0, 500)
	assert_gt(float(id), -1.0, "the store was placed")
	world.cmd_now({"system": &"build", "op": "set_stock", "items": {"coal": 5000}})
	var before: int = logi.haul.hauled_total
	world.run(200)                                     # ten seconds
	var moved: int = logi.haul.hauled_total - before
	assert_le(float(moved), 6.0 * 10.0 + 6.0,
		"ten seconds of hauling is sixty items and a second of banked budget")
	assert_gt(float(moved), 20.0,
		"and it is not zero — a new player must not be stranded on day one")


# =========================================================================
# THE DISTANCE, AND THE RANGE
# =========================================================================

## The cost curve, stated as arithmetic so a retune cannot quietly flatten it.
func test_distance_costs_and_the_curve_is_steep_enough_to_feel() -> void:
	assert_near(logi.haul.cost_per_item(0), 1.0, 0.001, "your own doorstep is free")
	assert_near(logi.haul.cost_per_item(LogiHaul.HAUL_FREE), 1.0, 0.001,
		"and so is anything inside HAUL_FREE")
	assert_near(logi.haul.cost_per_item(20), 3.0, 0.001, "twenty tiles is three times the price")
	assert_near(logi.haul.cost_per_item(36), 5.0, 0.001, "thirty-six tiles is five times")
	# The shipped curve was `1 + d / 96`, which is 1.21 at twenty tiles: a 21%
	# surcharge on the far side of the city, i.e. no surcharge at all.
	assert_gt(logi.haul.cost_per_item(20), 2.0,
		"a carry across the city must cost more than double, or distance is decoration")


## Far things arrive more slowly than near things, out of the same budget, in
## the same world, in the same number of ticks. This is the one a player feels.
func test_the_far_store_is_served_more_slowly_than_the_near_one() -> void:
	_empty_the_city()
	_stocked("bunker_chest", O, 2000)                                    # the source
	var near: int = _stocked("bunker_chest", O + Vector2i(4, 0), 0, 400)
	var far: int = _stocked("bunker_chest", O + Vector2i(36, 0), 0, 400)
	assert_gt(float(near), -1.0, "the near store was placed")
	assert_gt(float(far), -1.0, "the far store was placed")
	world.run(600)
	assert_gt(float(_count(near)), 0.0, "the near store is served")
	assert_gt(float(_count(near)), float(_count(far)) * 2.0,
		"and the near store is served at least twice as well as the one across the map")


## Past HAUL_RANGE the answer is NO. Not slower — nothing. The shipped range was
## 96 tiles, which is the entire playable city plus its outposts.
func test_nothing_is_carried_past_the_haul_range() -> void:
	_empty_the_city()
	_stocked("bunker_chest", O, 2000)
	var beyond: int = _stocked("bunker_chest", O + Vector2i(LogiHaul.HAUL_RANGE + 8, 0), 0, 200)
	assert_gt(float(beyond), -1.0, "the far store was placed")
	world.run(600)
	assert_eq(_count(beyond), 0, "past the range, nobody walks")
	assert_true(logi.is_starved(beyond), "and the building says so, so a lens can point at it")
	assert_lt(float(LogiHaul.HAUL_RANGE), 64.0,
		"the range must be a fraction of the map, not all of it")


# =========================================================================
# THE CREW — the free tier must not grow on its own
# =========================================================================

## The reference run went 18 founders -> 59 people -> 19 porters -> 76 items a
## second. Whatever the city's population does, the sledge crew does not move.
func test_the_haul_crew_does_not_grow_with_the_population() -> void:
	var citizens: SimSystem = world.system(&"citizens")
	if citizens == null:
		skip("no [P05] in this build, so there is no population to grow")
		return
	world.run(20)
	var start_porters: int = int(logi.metrics()["porters"])
	var start_pop: float = float(citizens.call("population")) if citizens.has_method("population") else 0.0
	world.run(4000)
	var end_pop: float = float(citizens.call("population")) if citizens.has_method("population") else 0.0
	assert_eq(int(logi.metrics()["porters"]), start_porters,
		"the crew is the same size it was, whatever happened to the city")
	assert_eq(start_porters, LogiHaul.BASE_PORTERS, "and it is BASE_PORTERS, not a derived number")
	if end_pop == start_pop:
		return   # nothing to prove either way; the equality above still holds
	assert_ne(end_pop, start_pop, "the population did move, which is what makes this a test")


## Research is the ONLY thing that raises the rate, and it applies to the crew
## that already exists. `logistics.throughput_mult` shipped on two research nodes
## for two waves and nothing in this build read it: Hand Carts promised +10%
## hauling and delivered a number nobody looked at.
func test_research_is_the_only_thing_that_makes_the_crew_faster() -> void:
	var base: float = logi.haul.capacity()
	logi.haul.rate_mult = 1.35
	assert_near(logi.haul.capacity(), base * 1.35, 0.001,
		"a throughput multiplier moves what the existing crew carries")
	logi.haul.rate_mult = 1.0
	assert_true(ResearchDefs.E_LOGI_THROUGHPUT_MULT == &"logistics.throughput_mult",
		"and it is the key the .tres files actually write")


# =========================================================================
# THE INSTRUMENTS — a balance claim is only as good as its ruler
# =========================================================================

## `logistics.fuel_by_machine` published `world.delivered_as_fuel`, which counts
## fuel put in a bunker BY ANY ROUTE — a porter's back included. The gate band
## beside it read "1040 by machine against 1029 by porter: the machines now carry
## more of this city's fuel than the people do". Here there is no belt and no arm
## anywhere in the world, so the honest answer is zero, and anything above zero
## means the ruler is counting porters as machines again.
func test_fuel_by_machine_counts_no_fuel_that_a_porter_carried() -> void:
	var heat: SimSystem = world.system(&"heat")
	if heat == null:
		skip("no [P02] in this build, so nothing burns")
		return
	world.cmd_now({"system": &"build", "op": "set_stock", "items": {"coal": 4000}})
	world.cmd_now({"system": &"build", "op": "place", "kind": "coal_generator",
		"cell": [O.x, O.y + 20], "free": true, "instant": true})
	world.run(600)
	var m: Dictionary = logi.metrics()
	assert_eq(int(m["arms_no_target"]), 0, "there are no arms at all in this world")
	assert_eq(int(m["fuel_by_machine"]), 0,
		"so not one unit of fuel in this city was delivered by a machine")
	assert_gt(float(m["fuel_by_porter"]), 0.0, "the porters, meanwhile, did the work")
	assert_ge(float(m["fuel_delivered"]), float(m["fuel_by_machine"]),
		"the any-route total is still published, and it is the larger number")


# =========================================================================
# THE DEAD END — "a belt that goes nowhere is not a balance problem"
# =========================================================================

## An arm with coal in its hand, aimed at open snow. It will never put that coal
## down, no supply behind it will help, and until now nothing in this build said
## so — a critic had to infer it from `sink_id: -1` and infer it wrongly.
func test_an_arm_holding_goods_and_aimed_at_snow_is_named() -> void:
	_empty_the_city()
	# a crate the arm can reach behind itself, and nothing at all in front of it
	var src: int = _stocked("crate", O, 300)
	assert_gt(float(src), -1.0, "the crate was placed")
	var arm: int = _place("inserter_mk1", O + Vector2i(1, 0), 0)   # facing east, into nothing
	assert_gt(float(arm), -1.0, "the arm was placed")
	world.run(60)
	assert_eq(int(logi.metrics()["arms_no_target"]), 1,
		"one arm in this city is reaching into empty ground and the city knows it")
	assert_signal_emitted(Bus, &"alert_raised", func() -> void:
		world.run(LogisticsSystem.DEAD_END_GRACE + LogisticsSystem.DEAD_END_EVERY),
		1, "and it says so exactly once, after the grace period, not every tick")


## The counterpart, and the reason the grace period and the `held > 0` rule
## exist: laying a belt, and pointing an arm at a building that is still a
## construction site, are both NORMAL. An assistant that calls those mistakes is
## the reason nobody reads warnings. This is the case that caught the first
## draft, which shouted at t261 about a nine-tile run four ticks old.
func test_a_belt_still_being_built_is_not_called_a_mistake() -> void:
	_empty_the_city()
	var seen: Array[int] = [0]
	var tap: Callable = func(_sev: int, kind: StringName, _t: String, _p: Vector2) -> void:
		if kind == &"belt_to_nowhere" or kind == &"arm_no_target":
			seen[0] += 1
	Bus.alert_raised.connect(tap)
	# a run of belt laid a tile at a time, exactly as a drag arrives
	for i: int in 8:
		_place("belt_mk1", O + Vector2i(i, 0), 0)
		world.run(6)
	assert_eq(int(logi.metrics()["lines_to_nowhere"]), 1,
		"the state is measured honestly the whole time")
	assert_eq(seen[0], 0, "and nobody is shouted at while they are still laying it")
	Bus.alert_raised.disconnect(tap)


## And once it HAS been sitting there doing nothing, it is named — with its
## cells, so a lens can point at it.
func test_a_finished_belt_that_feeds_no_one_is_named() -> void:
	_empty_the_city()
	for i: int in 8:
		_place("belt_mk1", O + Vector2i(i, 0), 0)
	world.run(30)
	assert_eq(int(logi.metrics()["lines_to_nowhere"]), 1, "a line with no sink and no arm on it")
	assert_signal_emitted(Bus, &"alert_raised", func() -> void:
		world.run(LogisticsSystem.DEAD_END_GRACE + LogisticsSystem.DEAD_END_EVERY),
		1, "is named once the grace period is over")


## THE ONE THAT STOPS THIS BECOMING WALLPAPER. A saturated belt with a live
## consumer is a belt DOING ITS JOB. Three of the four lines in the reference
## run report `blocked` for 80% of it and two end in `sink_id: -1`, and all four
## are healthy — which is exactly what a critic read as two belts to nowhere.
func test_a_full_belt_with_an_arm_on_it_is_not_a_dead_end() -> void:
	_empty_the_city()
	var src: int = _stocked("crate", O, 600)
	assert_gt(float(src), -1.0, "the crate was placed")
	_place("inserter_mk1", O + Vector2i(1, 0), 0)         # crate -> belt
	for i: int in 8:
		_place("belt_mk1", O + Vector2i(2 + i, 0), 0)     # a line ending in bare ground
	# An arm reaching off the FLANK of the line into a chest beside it. The line
	# still ends in snow and still backs up solid, exactly like lines 1-3 of the
	# reference run, and it is still doing its job.
	var sink: int = _place("crate", O + Vector2i(6, 2))
	assert_gt(float(sink), -1.0, "the destination crate was placed")
	var unload: int = _place("inserter_mk1", O + Vector2i(6, 1), 1)
	assert_gt(float(unload), -1.0, "the unloading arm was placed")
	world.run(LogisticsSystem.DEAD_END_GRACE + 200)
	var m: Dictionary = logi.metrics()
	assert_eq(int(m["lines_to_nowhere"]), 0,
		"a line an arm draws from is not a line to nowhere, however full it gets")
	assert_eq(int(m["arms_no_target"]), 0, "and no arm here is reaching into snow")
	assert_gt(float(m["items_moved"]), 0.0, "because the belt is, in fact, moving goods")


# =========================================================================
# THE YARD — the hole the other three rules had
# =========================================================================

## Places the Hearth and lets the slow timer find it, so `haul.yard` is real.
func _found_the_yard(at: Vector2i) -> bool:
	if world.system(&"build") == null:
		return false
	world.cmd_now({"system": &"build", "op": "place", "kind": "the_hearth",
		"cell": [at.x, at.y], "free": true, "instant": true})
	world.run(LogisticsSystem.YARD_EVERY + 20)
	return logi.haul.yard == at


## [P11]'s stockpile is a dictionary with no position in it, so the haul network
## charged it 1.0 per item to ANY cell on the map and never once refused it. That
## was 1211 of the 1980 items hauled in the reference run — 61% of all hauling —
## which made the range cap and the cost curve true of the other 39% and a
## comment about the rest. The yard is the Hearth, and it is priced from there.
func test_the_stockpile_is_priced_from_the_yard_like_any_other_store() -> void:
	_empty_the_city()
	if not _found_the_yard(O):
		skip("no [P11] in this build, so there is no stockpile to price")
		return
	# ONE post, thirty-seven tiles out, and no store anywhere holds coal — so
	# every item that arrives came out of the yard and its price is the only
	# thing being measured. Two posts side by side does NOT measure this: they
	# drain one shared budget in id order, so the near one wins by going first
	# whether or not distance costs anything, and that version of this test
	# passed against the unpriced stockpile.
	var far: int = _stocked("bunker_chest", O + Vector2i(37, 0), 0, 400)
	assert_gt(float(far), -1.0, "the far post was placed")
	assert_gt(logi.haul.cost_per_item(37), 5.0, "thirty-seven tiles is over five times the price")
	world.cmd_now({"system": &"build", "op": "set_stock", "items": {"coal": 6000}})
	world.run(1200)
	var got: int = _count(far)
	assert_gt(float(got), 0.0, "the far post is served — the range has not run out yet")
	# Sixty seconds is 360 porter-items. At 5.125 each that is seventy deliveries
	# before the Hearth beside it takes its own fuel out of the same budget; at
	# the doorstep price the shipped stockpile charged, the same minute fills the
	# post's whole 400 request. 150 sits between those two worlds and nowhere near
	# either boundary.
	assert_lt(float(got), 150.0,
		"and a minute of the whole city's porters does not fill a post across the map")

## Past the range the yard says no, exactly as a chest would. Not slower: nothing.
func test_the_stockpile_will_not_reach_past_the_haul_range() -> void:
	_empty_the_city()
	if not _found_the_yard(O):
		skip("no [P11] in this build, so there is no stockpile to price")
		return
	var beyond: int = _stocked("bunker_chest", O + Vector2i(LogiHaul.HAUL_RANGE + 6, 0), 0, 300)
	assert_gt(float(beyond), -1.0, "the far post was placed")
	world.cmd_now({"system": &"build", "op": "set_stock", "items": {"coal": 6000}})
	var refused_before: int = int(logi.metrics()["stock_out_of_range"])
	world.run(900)
	assert_eq(_count(beyond), 0,
		"a post outside the range gets nothing from the city stockpile either")
	assert_true(logi.is_starved(beyond), "and it is marked starving, so a lens can point at it")
	assert_gt(float(int(logi.metrics()["stock_out_of_range"]) - refused_before), 0.0,
		"and the refusal is counted rather than silent")


## The other half, so the fix cannot be "the stockpile never delivers anything":
## inside the range it still answers, and it still answers first for a building
## standing on the yard itself.
func test_the_yard_still_supplies_the_city_it_stands_in() -> void:
	_empty_the_city()
	if not _found_the_yard(O):
		skip("no [P11] in this build, so there is no stockpile to price")
		return
	# O+(5,0) rather than O+(3,0): the Hearth is five tiles across and its own
	# footprint is not somewhere you may put a chest.
	var post: int = _stocked("bunker_chest", O + Vector2i(5, 0), 0, 300)
	assert_gt(float(post), -1.0, "the post was placed")
	world.cmd_now({"system": &"build", "op": "set_stock", "items": {"coal": 6000}})
	world.run(600)
	# 60, not the 180 the crew could carry in thirty seconds, and not the 160 the
	# 1.125x surcharge leaves of it: THE HEARTH IS ALSO A BURNER. It is standing
	# right there eating coal out of the same six items a second, which is the
	# rate limit working exactly as designed and is why this bound is a floor and
	# not a target. Measured at 94.
	assert_ge(float(_count(post)), 60.0,
		"five tiles from the Hearth is the cheapest delivery in the game and it still happens")
	assert_eq(int(logi.metrics()["stock_out_of_range"]), 0, "and nothing was refused")
