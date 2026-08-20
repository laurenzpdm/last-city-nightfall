class_name LogiHaul
extends RefCounted
## The request layer: how a building that is not on a belt still gets fed.
##
## Belts are the answer to "I need a thousand of these an hour". This is the
## answer to "the generator on the far side of the wall needs coal and I have
## not run a line out there yet" — a handful of porters with sledges, moving
## goods out of whatever store has them.
##
## It is deliberately WORSE than a belt, in three ways a player can feel, and
## every one of those three is a number in this file that BINDS. That sentence
## used to be here and be false, so the numbers are written out:
##
##   * IT IS RATE LIMITED. Six porters at [constant PORTER_RATE] is
##     [b]6 items a second for the whole city[/b] — 40% of one belt_mk1, which
##     carries 15. Everyone shares it: the smelter, the granary, every bunker
##     not on a line, and the turrets asking for shells.
##   * DISTANCE COSTS. Carrying is free inside [constant HAUL_FREE] tiles and
##     then each [constant HAUL_STEP] tiles adds one whole porter-item to the
##     bill, so an 18-tile carry costs 2.75x and a 36-tile carry costs 5x. The
##     outpost across the wall really does eat the haul network.
##   * IT WILL NOT REACH PAST [constant HAUL_RANGE] TILES AT ALL. That is a
##     third of the playable map, not all of it.
##
## All three apply to the CITY STOCKPILE too, which is the rule the first draft
## of this file left out and which was worth 61% of all hauling — see
## [member yard].
##
## AND IT DOES NOT GROW WITH THE CITY. The crew is six people with sledges on
## day one and six people with sledges on day thirty (see
## [method LogisticsSystem._crew]). It used to be `6 + population / 4`, which
## meant 18 founders became 19 porters and 76 items a second by day three —
## the free tier out-carrying five belts, for nothing, at unlimited range. A
## player who never opened the Logistics tab lost nothing. That was the whole
## automation pillar, given away.
##
## The two ways out are both things the player BUILDS: a belt, or the
## `logistics.throughput_mult` research line (Hand Carts, Logistic Scheduling),
## which raises [member rate_mult] and is worth taking precisely because the
## floor under it is low.
##
## That is the pressure that makes automation the answer rather than a
## decoration: hauling works, right up until the city grows.

## Items one porter moves per second on a short haul, before research.
const PORTER_RATE: float = 1.0
## The haul crew. Fixed: population never adds a porter.
const BASE_PORTERS: int = 6
## Carrying costs nothing extra inside this radius — the building's own doorstep.
const HAUL_FREE: int = 4
## Each of these many tiles past HAUL_FREE adds 1.0 to the cost of every item.
const HAUL_STEP: int = 8
## Furthest a porter will walk, in tiles. Beyond this, build something.
const HAUL_RANGE: int = 40
## Ticks a building is remembered as starved after a request went unmet.
const STARVE_MEMORY: int = 100
## Upper edges of the delivery-distance histogram, in tiles.
const REACH_BUCKETS: Array[int] = [4, 12, 24]

var porters: int = BASE_PORTERS
## Items of hauling still available this tick.
var budget: float = 0.0
## Where the construction stockpile physically IS — the Hearth's yard, set by
## [method LogisticsSystem._read_yard]. Vector2i.MIN means nobody has told us,
## which happens only in a world with no Hearth in it.
##
## THIS FIELD IS THE THIRD RULE'S LAST HOLE. Every store in the city was priced
## by distance and refused past [constant HAUL_RANGE], and then the stockpile
## branch below handed out the city's entire yard at doorstep price to any cell
## on the map, because "the construction stockpile is the city's own yard: near
## by definition". It is not near by definition; it is near the Hearth. On the
## reference run 1211 of 1980 hauled items — 61% — came down that branch, so
## the range cap and the cost curve were both true of 39% of hauling and a
## comment about the rest.
var yard: Vector2i = Vector2i(-2147483648, -2147483648)
## `logistics.throughput_mult` from [P10], 1.0 with no research in the build.
## The ONLY thing that makes the crew faster, and the player has to pay for it.
var rate_mult: float = 1.0

var hauled_total: int = 0
var fuel_total: int = 0
var requests_served: int = 0
var requests_unmet: int = 0

## Diagnostics. Where the haul budget actually went, so a balance claim about
## this layer is a number in state.json and not a paragraph in a report.
var hauled_by_kind: Dictionary[StringName, int] = {}
## Items delivered, bucketed by how far they were carried (see REACH_BUCKETS).
var hauled_by_reach: Array[int] = [0, 0, 0, 0]
var hauled_from_stock: int = 0
## Requests the yard was too far away to answer. Published so "the range bites"
## is a number rather than a claim.
var stock_out_of_range: int = 0

var _tick: int = -1
## Building id -> the tick its last request went short.
var _starved: Dictionary[int, int] = {}


## Tops the budget back up. Lazy on purpose: [P02] calls request_fuel() during
## its own step, which runs before ours, and the budget has to be right then.
func begin_tick(tick: int, crew: int) -> void:
	if tick == _tick:
		return
	_tick = tick
	porters = maxi(1, crew)
	# One second of banked hauling and no more. A pool that grows while nobody
	# asks would let a quiet morning pay for an instant afternoon, which is the
	# rate limit refunding itself.
	var ceiling: float = capacity()
	budget = minf(budget + ceiling * SimClock.DT, ceiling)


## Items a second the whole haul network can move on a doorstep delivery.
func capacity() -> float:
	return float(porters) * PORTER_RATE * maxf(0.05, rate_mult)


## Porter-items of budget spent per item carried `dist` tiles. 1.0 next door,
## and one more for every HAUL_STEP tiles after the first HAUL_FREE.
func cost_per_item(dist: int) -> float:
	return 1.0 + float(maxi(0, dist - HAUL_FREE)) / float(HAUL_STEP)


## Tiles from the city's yard to `cell`. A world with no Hearth in it has no
## yard, and rather than quietly restoring the old free-delivery-everywhere rule
## it answers 0 — a test fixture with no city is a city with one building in it,
## and the caller logs the absence once rather than pricing a guess.
func yard_distance(cell: Vector2i) -> int:
	if yard.x == -2147483648:
		return 0
	return LogiTypes.chebyshev(yard, cell)


## Moves up to `amount` of `kind` to `target_cell` out of the city's stores and,
## failing those, out of the construction stockpile. Returns what arrived.
##
## `into` is called with the number of items that reached the destination and
## must return how many were actually accepted, so nothing is ever created: what
## the destination refuses is put straight back where it came from.
func serve(world: LogiWorld, stock: BuildStock, owner: int, target_cell: Vector2i,
		kind: StringName, amount: int) -> int:
	if amount <= 0:
		return 0
	var want: int = mini(amount, int(floorf(budget)))
	if want <= 0:
		_mark_short(owner)
		return 0

	var moved: int = 0
	for source: int in _sources_near(world, target_cell, kind, owner):
		if moved >= want:
			break
		var st: LogiStore = world.stores.get(source)
		if st == null:
			continue
		var dist: int = LogiTypes.chebyshev(
			world.store_origin.get(source, target_cell), target_cell)
		var cost_each: float = cost_per_item(dist)
		var affordable: int = int(floorf(budget / cost_each))
		if affordable <= 0:
			break
		var take: int = mini(mini(want - moved, affordable), st.spare(kind))
		if take <= 0:
			continue
		var got: int = st.take(kind, take)
		if got <= 0:
			continue
		budget = maxf(0.0, budget - float(got) * cost_each)
		moved += got
		_note_reach(dist, got)

	if moved < want and stock != null:
		# The yard is a store like any other: same curve, same cap. A requester
		# out past HAUL_RANGE is told no by the city's own stockpile too, which
		# is the whole point of a range — otherwise the outpost across the map
		# is supplied for free and only the neighbours pay.
		var yard_dist: int = yard_distance(target_cell)
		if yard_dist <= HAUL_RANGE:
			var yard_cost: float = cost_per_item(yard_dist)
			var can_pay: int = mini(want - moved, int(floorf(budget / yard_cost)))
			if can_pay > 0:
				var missing: Dictionary[StringName, int] = {}
				missing[kind] = can_pay
				var from_stock: Dictionary[StringName, int] = stock.take_partial(missing)
				var n: int = int(from_stock.get(kind, 0))
				if n > 0:
					budget = maxf(0.0, budget - float(n) * yard_cost)
					moved += n
					hauled_from_stock += n
					_note_reach(yard_dist, n)
		else:
			stock_out_of_range += 1

	hauled_total += moved
	if moved > 0:
		hauled_by_kind[kind] = int(hauled_by_kind.get(kind, 0)) + moved
		requests_served += 1
		_starved.erase(owner)
	else:
		# Getting SOME of what you asked for is a rate limit, and the next tick
		# brings more. Getting none of it means the city has none: that is the
		# only thing worth calling starvation, and the only thing worth an alert.
		requests_unmet += 1
		_mark_short(owner)
	return moved


## Stores holding `kind` within reach, nearest first, ties broken by id.
func _sources_near(world: LogiWorld, target: Vector2i, kind: StringName, skip: int) -> Array[int]:
	var found: Array[Vector2i] = []   # (distance, id) packed into a Vector2i
	for id: int in world.store_ids():
		if id == skip:
			continue
		var st: LogiStore = world.stores[id]
		# Not `count`: a store is a source only for what it holds above its own
		# standing request. See LogiStore.spare().
		if st.spare(kind) <= 0:
			continue
		var dist: int = LogiTypes.chebyshev(world.store_origin.get(id, target), target)
		if dist > HAUL_RANGE:
			continue
		found.append(Vector2i(dist, id))
	found.sort()
	var out: Array[int] = []
	for v: Vector2i in found:
		out.append(v.y)
	return out


## Buckets a delivery by carry distance. Pure diagnostics; never read by the sim.
func _note_reach(dist: int, n: int) -> void:
	for i: int in REACH_BUCKETS.size():
		if dist <= REACH_BUCKETS[i]:
			hauled_by_reach[i] += n
			return
	hauled_by_reach[REACH_BUCKETS.size()] += n


func _mark_short(owner: int) -> void:
	if owner >= 0:
		_starved[owner] = _tick


## True when this building asked for something recently and did not get it.
func is_starved(owner: int) -> bool:
	var when: int = int(_starved.get(owner, -1000000))
	return _tick - when < STARVE_MEMORY


func starved_count() -> int:
	var n: int = 0
	var keys: Array = _starved.keys()
	keys.sort()
	for k: int in keys:
		if _tick - int(_starved[k]) < STARVE_MEMORY:
			n += 1
	return n


func starved_ids() -> Array[int]:
	var out: Array[int] = []
	var keys: Array = _starved.keys()
	keys.sort()
	for k: int in keys:
		if _tick - int(_starved[k]) < STARVE_MEMORY:
			out.append(k)
	return out


func forget(owner: int) -> void:
	_starved.erase(owner)


func to_json() -> Dictionary:
	return {
		"porters": porters,
		"budget": snappedf(budget, 0.01),
		"hauled": hauled_total,
		"fuel": fuel_total,
		"served": requests_served,
		"unmet": requests_unmet,
		"starved": starved_ids(),
		"by_kind": _by_kind_json(),
		"by_reach": hauled_by_reach.duplicate(),
		"from_stock": hauled_from_stock,
		"stock_out_of_range": stock_out_of_range,
	}


func _by_kind_json() -> Dictionary:
	var out: Dictionary = {}
	var keys: Array = hauled_by_kind.keys()
	keys.sort()
	for k: StringName in keys:
		out[String(k)] = hauled_by_kind[k]
	return out
