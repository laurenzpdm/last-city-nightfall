class_name LogiHaul
extends RefCounted
## The request layer: how a building that is not on a belt still gets fed.
##
## Belts are the answer to "I need a thousand of these an hour". This is the
## answer to "the generator on the far side of the wall needs coal and I have
## not run a line out there yet" — a handful of porters with sledges, moving
## goods out of whatever store has them.
##
## It is deliberately WORSE than a belt, in three ways a player can feel:
##
##   * it is rate limited. All the porters in the city move
##     `porters * PORTER_RATE` items a second between them, and everyone shares
##     that number.
##   * distance costs. A delivery `d` tiles away spends `1 + d / HAUL_RANGE`
##     porter-items of the budget for each item moved, so an outpost across the
##     map quietly eats the whole haul network.
##   * it will not reach past HAUL_RANGE at all.
##
## That is the pressure that makes automation the answer rather than a
## decoration: hauling works, right up until the city grows.

## Items one porter moves per second.
const PORTER_RATE: float = 4.0
## Porters the city has before [P05] assigns anybody to hauling.
const BASE_PORTERS: int = 6
## Furthest a porter will walk, in tiles.
const HAUL_RANGE: int = 96
## Ticks a building is remembered as starved after a request went unmet.
const STARVE_MEMORY: int = 100

var porters: int = BASE_PORTERS
## Items of hauling still available this tick.
var budget: float = 0.0

var hauled_total: int = 0
var fuel_total: int = 0
var requests_served: int = 0
var requests_unmet: int = 0

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
	var per_tick: float = float(porters) * PORTER_RATE * SimClock.DT
	budget = minf(budget + per_tick, float(porters) * PORTER_RATE)


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
		var cost_each: float = 1.0 + float(dist) / float(HAUL_RANGE)
		var affordable: int = int(floorf(budget / cost_each))
		if affordable <= 0:
			break
		var take: int = mini(want - moved, affordable)
		var got: int = st.take(kind, take)
		if got <= 0:
			continue
		budget = maxf(0.0, budget - float(got) * cost_each)
		moved += got

	if moved < want and stock != null:
		var missing: Dictionary[StringName, int] = {}
		missing[kind] = want - moved
		var from_stock: Dictionary[StringName, int] = stock.take_partial(missing)
		var n: int = int(from_stock.get(kind, 0))
		if n > 0:
			# The construction stockpile is the city's own yard: near by
			# definition, but it is still porter work.
			budget = maxf(0.0, budget - float(n))
			moved += n

	hauled_total += moved
	if moved > 0:
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
		if st.count(kind) <= 0:
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
	}
