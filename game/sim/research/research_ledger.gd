class_name ResearchLedger
extends RefCounted
## Where research buys its materials.
##
## Research must draw from the SAME yard construction eats from. That is the
## whole point: a plate spent on Alloy Steel is a plate the wall does not get,
## and the player feels the tech tree as a competitor rather than as a timer
## running in a corner of the HUD.
##
## Binding order, first match wins:
##   1. a SimSystem implementing the city-inventory contract
##      (stock_count / stock_take / stock_give) — [P03] or [P04] when they land,
##   2. [P11] build's own BuildStock façade, which is the ledger today,
##   3. a private ledger, so a unit test can run this part in isolation.
##
## Everything is duck-typed on purpose. Twelve parts are being written in
## parallel; compiling against another part's class means going red when it
## changes shape, and this system degrading to "no materials" is far worse than
## it degrading to "a private ledger with nothing in it".

## Systems asked, in order, whether they own the city inventory. Same list and
## same order [P11] uses, so both never disagree about who the banker is.
const PROVIDER_CANDIDATES: Array[StringName] = [&"logistics", &"production", &"economy"]

## Private fallback ledger. Only consulted when nothing else answered.
var amounts: Dictionary[StringName, int] = {}

var _system: WeakRef = null      ## SimSystem provider (contract 1)
var _owner: WeakRef = null       ## system that owns a BuildStock-shaped façade (contract 2)
var _source: StringName = &"local"


## Finds the banker. Call from post_setup(), after every system exists.
func bind() -> void:
	_system = null
	_owner = null
	_source = &"local"

	for candidate: StringName in PROVIDER_CANDIDATES:
		var s: SimSystem = Sim.get_system(candidate)
		if s != null and s.has_method("stock_count") and s.has_method("stock_take") \
				and s.has_method("stock_give"):
			_system = weakref(s)
			_source = candidate
			return

	var build: SimSystem = Sim.get_system(&"build")
	if build != null:
		var facade: Object = build.get("stock")
		if facade != null and facade.has_method("count") and facade.has_method("take") \
				and facade.has_method("give"):
			# The OWNER is held, not the façade: [P11] replaces its BuildStock
			# instance on load, and a weak reference to the old one would go
			# stale into a silent private ledger.
			_owner = weakref(build)
			_source = &"build"


## Who is authoritative right now. Reported in the log and in serialize().
func source() -> StringName:
	return _source


func count(item: StringName) -> int:
	var s: Object = _live_system()
	if s != null:
		return int(s.call("stock_count", item))
	var f: Object = _live_facade()
	if f != null:
		return int(f.call("count", item))
	return int(amounts.get(item, 0))


## The shortfall per item, empty when every line is affordable.
func missing(items: Dictionary[StringName, int]) -> Dictionary[StringName, int]:
	var out: Dictionary[StringName, int] = {}
	var keys: Array = items.keys()
	keys.sort()
	for k: StringName in keys:
		var short: int = int(items[k]) - count(k)
		if short > 0:
			out[k] = short
	return out


func can_afford(items: Dictionary[StringName, int]) -> bool:
	return missing(items).is_empty()


## All-or-nothing withdrawal. Returns false and changes nothing when short —
## a half-paid instalment would leave materials in a project the player then
## cancels, and refunding that correctly is not worth the complexity.
func take(items: Dictionary[StringName, int]) -> bool:
	if items.is_empty():
		return true
	var s: Object = _live_system()
	if s != null:
		return bool(s.call("stock_take", _to_json(items)))
	var f: Object = _live_facade()
	if f != null:
		return bool(f.call("take", items))
	if not can_afford(items):
		return false
	var keys: Array = items.keys()
	keys.sort()
	for k: StringName in keys:
		amounts[k] = int(amounts.get(k, 0)) - int(items[k])
		if amounts[k] <= 0:
			amounts.erase(k)
	return true


## Hands materials back. Cancelling a project refunds part of what it consumed.
func give(items: Dictionary[StringName, int]) -> void:
	if items.is_empty():
		return
	var s: Object = _live_system()
	if s != null:
		s.call("stock_give", _to_json(items))
		return
	var f: Object = _live_facade()
	if f != null:
		f.call("give", items)
		return
	var keys: Array = items.keys()
	keys.sort()
	for k: StringName in keys:
		amounts[k] = int(amounts.get(k, 0)) + int(items[k])


## Test and scenario setup only: a no-op once a real banker is attached, which
## owns its own numbers.
func set_amount(item: StringName, amount: int) -> void:
	if _live_system() != null or _live_facade() != null:
		return
	if amount <= 0:
		amounts.erase(item)
	else:
		amounts[item] = amount


func describe() -> String:
	return "materials from '%s'" % String(_source)


# --- internals --------------------------------------------------------------

## Weak on both sides: the banker is a RefCounted system that may hold a
## reference back to research, and two systems pointing at each other would
## keep the whole world alive after teardown.
func _live_system() -> Object:
	if _system == null:
		return null
	return _system.get_ref()


func _live_facade() -> Object:
	if _owner == null:
		return null
	var owner: Object = _owner.get_ref()
	if owner == null:
		return null
	var facade: Object = owner.get("stock")
	if facade == null or not facade.has_method("take"):
		return null
	return facade


func _to_json(items: Dictionary[StringName, int]) -> Dictionary:
	var out: Dictionary = {}
	var keys: Array = items.keys()
	keys.sort()
	for k: StringName in keys:
		out[String(k)] = int(items[k])
	return out
