class_name ProdStore
extends RefCounted
## Where a machine's inputs come from and where its outputs go.
##
## Production deliberately does NOT own the city inventory. [P11] build already
## owns a ledger with a documented provider contract, and [P03] logistics will
## eventually claim it; if production claimed it too, the city would end up with
## two disagreeing sets of books and a construction site that cannot see the
## plates the factory just made.
##
## So this is a client façade over `BuildSystem.stock`, which is itself a façade
## over whoever owns the goods. Attach logistics tomorrow and every call here
## follows it without a line changing. With no build system at all — a bare unit
## test of production — it falls back to a local ledger so machines still run.
##
## Deposits from a MACHINE go through `deposit()`, which is allowed to be
## refused; deposits from [P03] or a refund go through the ledger directly and
## never are. That separation is what lets back-pressure exist without ever
## losing a construction refund.

## Local ledger. Only authoritative when no build system is attached.
var amounts: Dictionary[StringName, int] = {}
## The back-pressure switch. While false, `deposit()` refuses everything and
## machines fill their output buffers and stall with REASON_OUTPUT_FULL. [P03]
## closes it when the belts and the yards are genuinely full; nothing else does,
## because losing a construction refund to a full yard would be a bug, and
## refunds go through `give()`, which is never refused.
var accepting: bool = true

var _build: SimSystem = null
var _stock: Object = null
var _pulled: int = 0
var _pushed: int = 0


## Routes every read and write through [P11]'s ledger. Pass null to fall back.
func bind(build: SimSystem) -> void:
	_build = build
	_stock = null
	if build == null:
		return
	var s: Variant = build.get("stock")
	if s is Object and (s as Object).has_method("count"):
		_stock = s


## Which ledger is authoritative right now — reported in metrics and the log.
func backing() -> StringName:
	if _stock == null:
		return &"local"
	var name: Variant = _stock.call("provider_name")
	var provider: StringName = StringName(String(name))
	return &"build" if provider == &"local" else provider


func attached() -> bool:
	return _stock != null


func count(item: StringName) -> int:
	if _stock != null:
		return int(_stock.call("count", item))
	return int(amounts.get(item, 0))


## Removes exactly `amount` of one item, or nothing. Returns what it took.
## All-or-nothing per item on purpose: half an input set is a stalled machine
## holding materials another machine could have used.
func take(item: StringName, amount: int) -> int:
	if amount <= 0:
		return 0
	if _stock != null:
		var one: Dictionary[StringName, int] = {}
		one[item] = amount
		if not bool(_stock.call("take", one)):
			return 0
		_pulled += amount
		return amount
	var have: int = int(amounts.get(item, 0))
	if have < amount:
		return 0
	if have - amount <= 0:
		amounts.erase(item)
	else:
		amounts[item] = have - amount
	_pulled += amount
	return amount


## Removes up to `amount`. Used for fuel, where a partial tank is still useful.
func take_up_to(item: StringName, amount: int) -> int:
	if amount <= 0:
		return 0
	return take(item, mini(amount, count(item)))


## Unconditional deposit. Refunds, scenario seeding and [P03] hand-offs.
func give(item: StringName, amount: int) -> void:
	if amount <= 0:
		return
	if _stock != null:
		var one: Dictionary[StringName, int] = {}
		one[item] = amount
		_stock.call("give", one)
		_pushed += amount
		return
	amounts[item] = int(amounts.get(item, 0)) + amount
	_pushed += amount


## A machine offering finished goods to the city. Returns how much was accepted.
## Today the city always takes everything; when [P03] lands and belts back up,
## this is the one place that has to start saying no, and every machine already
## handles a refusal by stalling with REASON_OUTPUT_FULL.
func deposit(item: StringName, amount: int) -> int:
	if amount <= 0 or not accepting:
		return 0
	give(item, amount)
	return amount


func pulled_total() -> int:
	return _pulled


func pushed_total() -> int:
	return _pushed


## Only meaningful for the local fallback ledger; -1 when [P11] owns the books.
func to_json() -> Dictionary:
	if _stock != null:
		return {"backing": String(backing())}
	var items: Dictionary = {}
	for k: StringName in ProdSort.keys_of(amounts):
		if amounts[k] > 0:
			items[String(k)] = amounts[k]
	return {"backing": "local", "amounts": items}


func from_json(data: Dictionary) -> void:
	amounts.clear()
	var raw: Variant = data.get("amounts", {})
	if typeof(raw) != TYPE_DICTIONARY:
		return
	var src: Dictionary = raw
	for k: Variant in ProdSort.names(src.keys()):
		var n: int = int(src.get(String(k), 0))
		if n > 0:
			amounts[StringName(String(k))] = n
