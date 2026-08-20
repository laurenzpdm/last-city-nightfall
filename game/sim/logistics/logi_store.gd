class_name LogiStore
extends RefCounted
## A place items sit still: a chest, a storage yard, or the input/output buffer
## of a machine.
##
## Capacity is counted in ITEM UNITS, not slots. One number a player can read off
## a tooltip and reason about ("the yard holds 1200 things") beats two numbers
## that need a stack table to interpret.
##
## A store may also carry REQUESTS: "keep 200 coal in me". The haul layer reads
## those and moves goods across the city to satisfy them, which is how a
## building that is nowhere near a belt still gets fed — slowly, and at a cost.

## Building or logistics entity this belongs to.
var owner_id: int = -1
var capacity: int = 0
## Items it will accept. Empty means anything.
var filter: Array[StringName] = []
## Requested stock levels, item -> how many to keep on hand.
var requests: Dictionary[StringName, int] = {}
## True when this store asks the city to keep it stocked.
var requesting: bool = false

var _items: Dictionary[StringName, int] = {}
var _total: int = 0


func _init(store_owner: int = -1, store_capacity: int = 0, store_filter: Array[StringName] = []) -> void:
	owner_id = store_owner
	capacity = maxi(0, store_capacity)
	filter = store_filter.duplicate()


func accepts(kind: StringName) -> bool:
	return filter.is_empty() or filter.has(kind)


func count(kind: StringName) -> int:
	return int(_items.get(kind, 0))


func total() -> int:
	return _total


func free_space() -> int:
	return maxi(0, capacity - _total)


func room_for(kind: StringName) -> int:
	return free_space() if accepts(kind) else 0


func is_empty() -> bool:
	return _total <= 0


func is_full() -> bool:
	return _total >= capacity


## 0..1 for the storage lens.
func fill_ratio() -> float:
	return 0.0 if capacity <= 0 else clampf(float(_total) / float(capacity), 0.0, 1.0)


## Puts up to `amount` in. Returns how many were actually accepted.
func insert(kind: StringName, amount: int) -> int:
	if amount <= 0 or not accepts(kind):
		return 0
	var take: int = mini(amount, free_space())
	if take <= 0:
		return 0
	_items[kind] = int(_items.get(kind, 0)) + take
	_total += take
	return take


## Takes up to `amount` out. Returns how many were actually removed.
func take(kind: StringName, amount: int) -> int:
	if amount <= 0:
		return 0
	var have: int = int(_items.get(kind, 0))
	var give: int = mini(amount, have)
	if give <= 0:
		return 0
	if give >= have:
		_items.erase(kind)
	else:
		_items[kind] = have - give
	_total -= give
	return give


## The kind an arm should grab when it has no filter: the one there is most of,
## ties broken by id so two identical worlds always pick the same thing.
func best_kind() -> StringName:
	var keys: Array = _items.keys()
	keys.sort()
	var best: StringName = &""
	var best_n: int = 0
	for k: StringName in keys:
		var n: int = _items[k]
		if n > best_n:
			best_n = n
			best = k
	return best


## Item ids present, sorted — the only safe way to iterate this dictionary.
func kinds() -> Array[StringName]:
	var keys: Array = _items.keys()
	keys.sort()
	var out: Array[StringName] = []
	for k: StringName in keys:
		out.append(k)
	return out


## How many more of `kind` this store is asking for, 0 when satisfied.
func shortfall(kind: StringName) -> int:
	var want: int = int(requests.get(kind, 0))
	if want <= 0:
		return 0
	return maxi(0, mini(want - count(kind), free_space()))


## How many of `kind` the haul network is allowed to take OUT of this store.
##
## A store that asks the city to keep 600 coal in it is not a coal supplier at
## 599: only what it holds ABOVE its own request is spare. Without this rule two
## stores that both request the same item take it off each other forever — in the
## reference run that was 17908 of 19578 hauled items, a coal yard and a crate
## eighteen tiles apart trading the same coal back and forth for three days while
## every real delivery in the city queued behind it.
##
## Arms are deliberately NOT subject to this: an inserter drains a requester
## chest onto a belt, which is the whole point of putting one there.
func spare(kind: StringName) -> int:
	return maxi(0, count(kind) - int(requests.get(kind, 0)))


func set_request(kind: StringName, amount: int) -> void:
	if amount <= 0:
		requests.erase(kind)
	else:
		requests[kind] = amount
	requesting = not requests.is_empty()


func clear() -> void:
	_items.clear()
	_total = 0


func to_json() -> Dictionary:
	var items: Dictionary = {}
	for k: StringName in kinds():
		items[String(k)] = _items[k]
	var reqs: Dictionary = {}
	var rkeys: Array = requests.keys()
	rkeys.sort()
	for k: StringName in rkeys:
		reqs[String(k)] = requests[k]
	return {
		"owner": owner_id,
		"capacity": capacity,
		"total": _total,
		"items": items,
		"requests": reqs,
	}


func from_json(data: Dictionary) -> void:
	clear()
	capacity = int(data.get("capacity", capacity))
	var raw: Dictionary = data.get("items", {})
	var keys: Array = raw.keys()
	keys.sort()
	for k: Variant in keys:
		insert(StringName(String(k)), int(raw[k]))
	var rreq: Dictionary = data.get("requests", {})
	var rkeys: Array = rreq.keys()
	rkeys.sort()
	for k: Variant in rkeys:
		set_request(StringName(String(k)), int(rreq[k]))
