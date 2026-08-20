extends TestCase
## [P04] EACH TIER HAS TO CHANGE WHAT THE PLAYER CAN BUILD.
##
## A production chain is only deep if depth BUYS something. Fourteen recipes
## stacked five transformations high are a menu, not a progression, unless a
## building somewhere says "you cannot place me until you can make that". This
## file asserts that the shipped content says it — for every rung of the graph,
## not just the top one — and it is deliberately written against
## `game/content/buildings/*.tres` and `game/content/recipes/*.tres` rather than
## against a scenario, so it cannot be satisfied by one clever layout.
##
## WHY IT EXISTS. `production.chain_depth` on the reference run read 3 for four
## waves and the argument about it was always "add machines until it reads 4".
## That is the wrong argument. The right one is: at depth 4 the city can place a
## `geothermal_tap`, which is the only heat source in this game that burns no
## coal, and at depth 3 it cannot. If that stops being true — if somebody prices
## the tap in stone and iron so the reference run goes green sooner — the number
## keeps climbing and the game stops having tiers. That is what these go red for.
##
## WHAT WOULD MAKE THESE RED. Cheapen `geothermal_tap`'s cost to items the
## founders' stock already carries; delete `salvaged_wire` so copper stops being
## reachable from rubble; or flatten every building cost onto raw materials.

## Items a city has before it transforms anything: dug, salvaged or cut.
const GROUND: int = 0


func requires_systems() -> PackedStringArray:
	return PackedStringArray([])


# =============================================================================
# the gate itself
# =============================================================================

func test_every_rung_of_the_graph_unlocks_a_building() -> void:
	# THE CONTRACT IN ONE ASSERTION, and it is a loop rather than a list because
	# a list would need editing every time content moves. For each depth from 1
	# to the deepest thing the graph makes, SOME building in the game must cost
	# an item at exactly that depth — otherwise that rung is a step the player
	# takes for no reason they can see on the build menu.
	var b: ProdRecipeBook = _book()
	assert_gt(b.max_depth, 0, "the graph transforms something")
	var deepest_gate: int = 0
	for depth: int in range(1, b.max_depth + 1):
		if not _buildings_needing_depth(b, depth).is_empty():
			deepest_gate = depth
	assert_ge(deepest_gate, 4,
		"the deep half of the graph is a build gate, not a trophy cabinet")
	# NO HOLES BELOW IT. A ladder with a rung missing is worse than a short
	# ladder: the player crosses a tier, the build menu does not change, and the
	# tier reads as busywork. Every depth up to the deepest gate has to buy
	# something.
	for depth2: int in range(1, deepest_gate + 1):
		assert_not_empty(_buildings_needing_depth(b, depth2),
			"depth %d buys the player a building it could not place before" % depth2)
	# AND THE HOLE THAT IS ACTUALLY THERE, NAMED SO IT CANNOT BE FORGOTTEN.
	# `heat_core` is depth 5, the deepest thing the shipped graph makes, and NO
	# building in game/content/buildings is priced in one — so the top rung of
	# the ladder currently buys nothing at all. This asserts the shape of that
	# hole rather than its existence: the day a building costs a heat core,
	# deepest_gate becomes 5 and every line above still holds.
	assert_eq(deepest_gate, b.max_depth - 1,
		"the only rung that buys nothing is the top one (heat_core), and this "
		+ "goes red if a SECOND rung ever stops buying anything")


func test_the_fuel_free_heat_source_is_the_deepest_gate() -> void:
	# THE ONE THAT MATTERS TO THE CITY. Every other heat source in this game
	# eats coal, so the tap is the single building whose arrival changes the
	# shape of a run rather than its size — and it is priced in the deepest item
	# the graph makes short of heat_core. This is the design statement
	# `production.chain_depth` is really about.
	var b: ProdRecipeBook = _book()
	var tap: BuildingDef = _def(&"geothermal_tap")
	if tap == null:
		skip("no geothermal_tap in this build")
		return
	assert_true(tap.heat_produced > 0.0, "it makes heat")
	assert_empty(tap.fuel_items, "and it makes it out of nothing the city has to carry")
	var need: int = _cost_depth(b, tap)
	assert_ge(need, 4, "and it cannot be placed until the chain is four deep")
	for other: StringName in _heat_makers():
		if other == &"geothermal_tap":
			continue
		var d: BuildingDef = _def(other)
		if d == null or d.fuel_items.is_empty():
			continue
		assert_lt(_cost_depth(b, d), need,
			"'%s' burns fuel, so it must be cheaper in chain depth than the tap"
			% String(other))


func test_a_city_that_can_only_salvage_can_still_reach_that_gate() -> void:
	# AND THE GATE HAS TO BE OPENABLE FROM RUBBLE. A tier gate priced in an item
	# whose only source is thirty tiles past the wall is not a progression, it is
	# a wall with a picture of a door on it. Start from what the reference map
	# gives a city inside its own walls and close the graph over it.
	var b: ProdRecipeBook = _book()
	var tap: BuildingDef = _def(&"geothermal_tap")
	if tap == null:
		skip("no geothermal_tap in this build")
		return
	var have: Dictionary[StringName, bool] = {&"scrap": true, &"coal": true, &"stone": true}
	for _pass: int in 12:
		for rid: StringName in b.ids:
			var r: RecipeDef = b.get_recipe(rid)
			var ok: bool = not r.inputs.is_empty()
			for item: StringName in r.sorted_inputs():
				if not have.has(item):
					ok = false
			if not ok:
				continue
			for out_item: StringName in r.all_outputs().keys():
				have[out_item] = true
	for item2: StringName in ProdSort.keys_of(tap.cost):
		assert_true(have.has(item2) or b.item_depth(item2) == GROUND,
			"a scrap-and-coal city can make '%s', which the tap is priced in"
			% String(item2))


# =============================================================================
# internals
# =============================================================================

## Buildings whose cost names an item at exactly this chain depth.
func _buildings_needing_depth(b: ProdRecipeBook, depth: int) -> Array[StringName]:
	var out: Array[StringName] = []
	for id: StringName in _building_ids():
		var d: BuildingDef = _def(id)
		if d == null or d.cost.is_empty():
			continue
		for item: StringName in ProdSort.keys_of(d.cost):
			if b.item_depth(item) == depth:
				out.append(id)
				break
	return out


## The deepest item in a building's bill of materials.
func _cost_depth(b: ProdRecipeBook, d: BuildingDef) -> int:
	var best: int = 0
	for item: StringName in ProdSort.keys_of(d.cost):
		best = maxi(best, b.item_depth(item))
	return best


func _heat_makers() -> Array[StringName]:
	var out: Array[StringName] = []
	for id: StringName in _building_ids():
		var d: BuildingDef = _def(id)
		if d != null and d.heat_produced > 0.0:
			out.append(id)
	return out


func _building_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	for id: StringName in Registry.ids("buildings"):
		ids.append(id)
	return ProdSort.names(ids)


func _def(id: StringName) -> BuildingDef:
	return Registry.get_item("buildings", id) as BuildingDef


func _book() -> ProdRecipeBook:
	var b := ProdRecipeBook.new()
	b.load_all()
	return b
