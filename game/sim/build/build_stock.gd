class_name BuildStock
extends RefCounted
## The materials construction draws from, and the one place that knows where
## they actually live.
##
## By default the build system owns a plain ledger — that is what makes this part
## testable and playable before logistics exists. As soon as another system claims
## the city inventory it takes over, and every call here routes to it instead.
##
## Provider contract — any SimSystem may implement it, first match wins:
## [codeblock]
##   func stock_count(item: StringName) -> int
##   func stock_take(items: Dictionary) -> bool    # all-or-nothing, true on success
##   func stock_give(items: Dictionary) -> void
## [/codeblock]

## Local ledger, item id -> amount. Ignored while a provider is attached.
var amounts: Dictionary[StringName, int] = {}

var _provider: SimSystem = null
var _provider_name: StringName = &"local"


## Routes every read and write to `system`. Pass null to fall back to the ledger.
func attach_provider(system: SimSystem, provider_name: StringName) -> void:
	_provider = system
	_provider_name = provider_name if system != null else &"local"


## Which store is authoritative right now — reported in metrics and the log.
func provider_name() -> StringName:
	return _provider_name


func count(item: StringName) -> int:
	if _provider != null:
		return int(_provider.call("stock_count", item))
	return int(amounts.get(item, 0))


## True when every line of `items` is available right now.
func can_afford(items: Dictionary[StringName, int]) -> bool:
	return missing(items).is_empty()


## The shortfall per item, empty when affordable.
func missing(items: Dictionary[StringName, int]) -> Dictionary[StringName, int]:
	var out: Dictionary[StringName, int] = {}
	var keys: Array = items.keys()
	keys.sort()
	for k: StringName in keys:
		var short: int = items[k] - count(k)
		if short > 0:
			out[k] = short
	return out


## All-or-nothing withdrawal. Returns false and changes nothing when short.
func take(items: Dictionary[StringName, int]) -> bool:
	if items.is_empty():
		return true
	if _provider != null:
		return bool(_provider.call("stock_take", BuildTypes.items_to_json(items)))
	if not can_afford(items):
		return false
	var keys: Array = items.keys()
	keys.sort()
	for k: StringName in keys:
		amounts[k] = int(amounts.get(k, 0)) - items[k]
		if amounts[k] <= 0:
			amounts.erase(k)
	return true


## Withdraws as much of `items` as exists. Returns what was actually taken.
## This is how a construction site gets fed while the city is still poor.
func take_partial(items: Dictionary[StringName, int]) -> Dictionary[StringName, int]:
	var got: Dictionary[StringName, int] = {}
	var keys: Array = items.keys()
	keys.sort()
	for k: StringName in keys:
		var want: int = items[k]
		var have: int = count(k)
		var n: int = mini(want, have)
		if n <= 0:
			continue
		var one: Dictionary[StringName, int] = {}
		one[k] = n
		if take(one):
			got[k] = n
	return got


## Deposits items. Refunds, cancellations and demolition all land here.
func give(items: Dictionary[StringName, int]) -> void:
	if items.is_empty():
		return
	if _provider != null:
		_provider.call("stock_give", BuildTypes.items_to_json(items))
		return
	var keys: Array = items.keys()
	keys.sort()
	for k: StringName in keys:
		amounts[k] = int(amounts.get(k, 0)) + items[k]


## Sets an absolute amount in the local ledger. Scenario and test setup only;
## a no-op against an external provider, which owns its own numbers.
func set_amount(item: StringName, amount: int) -> void:
	if _provider != null:
		return
	if amount <= 0:
		amounts.erase(item)
	else:
		amounts[item] = amount


## Sum of every item held. A single legible "how rich am I" number for metrics.
func total_units() -> int:
	if _provider != null:
		return -1
	var sum: int = 0
	for k: StringName in amounts:
		sum += amounts[k]
	return sum


func to_dict() -> Dictionary:
	return {
		"provider": String(_provider_name),
		"amounts": BuildTypes.items_to_json(amounts),
	}


func from_dict(data: Dictionary) -> void:
	amounts = BuildTypes.to_items(data.get("amounts", {}))
