class_name LogisticsSystem
extends SimSystem
## [P03] Logistics — belts, undergrounds, splitters, arms, stores and hauling.
##
## This is the Factorio half of the game. It owns every item that is not
## currently inside a machine: what is on a belt, what is in a chest, what a
## porter is carrying across the snow, and what is in a generator's coal bunker.
##
## THE ONE THING THAT CHANGES THE GAME. [P02] heat runs its burners in "fuel
## autarky" whenever no logistics system exists — generators burn faith. The
## moment this system is present, heat switches to metered fuel and starts
## calling `request_fuel()`. Coal has to physically arrive, from a store, from a
## belt, or on somebody's back. That is what turns a heat number into a supply
## chain, and it is why this part exists before production does.
##
## WHAT ANOTHER PART CALLS
##   throughput_of(cell) -> float         items/s crossing a belt tile
##   saturation_of(cell) -> float         0..1 how full that tile is
##   is_starved(building_id) -> bool      it asked for something and went short
##   request_fuel(id, item, amount)       [P02]'s burner contract, in items
##   request_items(id, item, amount)      the same thing for anybody else
##   store_of(building_id) -> LogiStore   a machine's own buffer, for [P04]
##   deposit(id, item, n) / withdraw(...) production's in and out tray
##   items_for_view() / belts_for_view()  what [P13] and [P19] draw
##
## The command surface mirrors [P11]'s, so a scenario can lay out a factory:
##   {"system": &"logistics", "op": "place", "kind": &"belt_mk1", "cell": [x, y], "rot": 0}
##   {"system": &"logistics", "op": "place_line", "kind": &"belt_mk1", "from": .., "to": ..}
##   {"system": &"logistics", "op": "insert", "cell": .., "item": &"coal", "count": 40}

const SYSTEM_ORDER: int = 30
const CATEGORY: String = "logistics"
## Ids minted here never collide with [P11]'s (1..) or [P02]'s (1000000..).
const LOCAL_ID_BASE: int = 2000000
## Seconds of burning a bunker is kept topped up to. Short enough that losing
## the coal supply is felt inside half a minute, long enough that the porters
## are not the bottleneck.
const FUEL_RESERVE_SECONDS: float = 30.0
const MIN_FUEL_RESERVE: float = 4.0
## Ticks between sweeps of the request layer.
const REQUEST_EVERY: int = 10
## Ticks between "the city is out of X" alerts.
const ALERT_EVERY: int = 400

var world: LogiWorld = LogiWorld.new()
var haul: LogiHaul = LogiHaul.new()

var _items: Dictionary[StringName, LogiItem] = {}
var _defs: Dictionary[StringName, LogiDef] = {}
var _next_id: int = LOCAL_ID_BASE
var _tick: int = 0

var _build: SimSystem = null
var _heat: SimSystem = null
var _grid: SimSystem = null
var _citizens: SimSystem = null
var _m_haulers: String = ""

## [P11] buildings we have taken an interest in, and the ones we never will.
var _adopted: Dictionary[int, bool] = {}
var _not_ours: Dictionary[int, bool] = {}
var _seen_build: Dictionary[int, bool] = {}
## Building kind -> {storage, filter, fuel, burn} read once out of the registry.
var _kind_traits: Dictionary[StringName, Dictionary] = {}

var _last_alert_tick: int = -100000
## True while there is nowhere in the world an item could come from. See
## _has_any_source: this is the counterpart of [P02]'s fuel autarky.
var _bootstrap_logged: bool = false
var _placed_total: int = 0
var _removed_total: int = 0
var _fuel_short: int = 0


func _init() -> void:
	order = SYSTEM_ORDER


func system_name() -> StringName:
	return &"logistics"


# =========================================================================
# lifecycle
# =========================================================================

func setup() -> void:
	order = SYSTEM_ORDER
	world = LogiWorld.new()
	haul = LogiHaul.new()
	_items = {}
	_defs = {}
	_adopted = {}
	_not_ours = {}
	_seen_build = {}
	_kind_traits = {}
	_next_id = LOCAL_ID_BASE
	_tick = 0
	_placed_total = 0
	_removed_total = 0
	_fuel_short = 0
	_last_alert_tick = -100000
	_load_content()


func post_setup() -> void:
	_build = Sim.get_system(&"build")
	_heat = Sim.get_system(&"heat")
	_grid = Sim.get_system(&"grid")
	_citizens = Sim.get_system(&"citizens")
	if _citizens != null:
		for candidate: String in ["idle_haulers", "hauler_count", "available_haulers", "population"]:
			if _citizens.has_method(candidate):
				_m_haulers = candidate
				break
	world.bind(_heat, _build)
	Log.info("logistics", "ready — %d items, %d transport definitions, heat=%s build=%s haulers=%s" % [
		_items.size(), _defs.size(), str(_heat != null), str(_build != null),
		_m_haulers if _m_haulers != "" else "base crew"])


func _load_content() -> void:
	var bad: int = 0
	for id: StringName in Registry.ids(CATEGORY):
		var res: Resource = Registry.get_item(CATEGORY, id)
		var item := res as LogiItem
		if item != null:
			var issues: PackedStringArray = item.validate()
			if not issues.is_empty():
				bad += 1
				Log.warn("logistics", "item '%s' — %s" % [String(id), ", ".join(issues)])
			_items[item.id] = item
			world.intern(item.id)
			continue
		var def := res as LogiDef
		if def != null:
			var problems: PackedStringArray = def.validate()
			if not problems.is_empty():
				bad += 1
				Log.warn("logistics", "definition '%s' — %s" % [String(id), ", ".join(problems)])
			_defs[def.id] = def
			continue
		Log.warn("logistics", "content item '%s' is neither a LogiItem nor a LogiDef" % String(id))
	Log.debug("logistics", "loaded %d items and %d definitions (%d with warnings)" % [
		_items.size(), _defs.size(), bad])


# =========================================================================
# the tick
# =========================================================================

func step(tick: int) -> void:
	_tick = tick
	haul.begin_tick(tick, _crew())
	_sync_from_build()
	world.step(tick)
	# Fuel every tick, stock requests every half second: a burner running dry is
	# the difference between a lit city and a dead one, and the loop is a handful
	# of early-outs when every bunker is full.
	_serve_fuel()
	if tick % REQUEST_EVERY == 0:
		_serve_requests()


## Is there anywhere in this world an item could physically come from?
##
## [P02] switches its burners from faith to metered fuel the moment this system
## exists, so a build with logistics but no construction stockpile and no stores
## would have a heat grid that can never be lit — which is not a supply chain, it
## is a broken build. In that one case fuel is handed out unmetered and said so
## in the log, exactly the way heat says "autarky" when nobody hauls.
func _has_any_source() -> bool:
	return _stock() != null or not world.stores.is_empty()


func _bootstrap_note() -> void:
	if _bootstrap_logged:
		return
	_bootstrap_logged = true
	Log.info("logistics", "no stockpile and no stores in this build — "
		+ "burners are fuelled unmetered until an economy exists")


## Porters available to the haul network. [P05] raises it once citizens exist.
func _crew() -> int:
	if _citizens != null and _m_haulers != "":
		var v: Variant = _citizens.call(_m_haulers)
		if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
			return LogiHaul.BASE_PORTERS + int(float(v) * 0.25)
	return LogiHaul.BASE_PORTERS


## Keeps every burner [P02] owns above a floor of fuel, so a generator browns
## out because the city ran out of coal and never because nobody walked over.
func _serve_fuel() -> void:
	if _heat == null:
		return
	var short: int = 0
	var missing: StringName = &""
	var unmetered: bool = not _has_any_source()
	for id: int in world.burner_ids():
		var fuel: StringName = world.fuel_item_of[id]
		if String(fuel) == "":
			continue
		if not bool(_heat.call("has_building", id)):
			continue
		var stock: float = float(_heat.call("fuel_stock_of", id))
		var reserve: float = _fuel_reserve(id)
		if stock >= reserve:
			continue
		var want: int = int(ceilf(reserve - stock))
		var cell: Vector2i = world.store_origin.get(id, Vector2i.ZERO)
		if unmetered:
			_bootstrap_note()
			haul.fuel_total += world.give_fuel(id, fuel, want)
			continue
		var got: int = haul.serve(world, _stock(), id, cell, fuel, want)
		if got > 0:
			var taken: int = world.give_fuel(id, fuel, got)
			haul.fuel_total += taken
			if taken < got:
				# The bunker was fuller than we thought: put the rest back
				# rather than letting items evaporate.
				_return_items(cell, fuel, got - taken)
		elif stock < MIN_FUEL_RESERVE:
			# Nothing arrived AND the bunker is nearly empty. A half-full reserve
			# that is merely refilling slowly is not a crisis and must not cry.
			short += 1
			missing = fuel
	_fuel_short = short
	if short > 0 and _tick - _last_alert_tick >= ALERT_EVERY:
		_last_alert_tick = _tick
		Bus.alert_raised.emit(1, &"fuel_short",
			"%d burner%s running dry — the city is out of %s" % [
				short, "" if short == 1 else "s", String(missing).replace("_", " ")],
			Vector2.ZERO)
		Log.info("logistics", "%d burners short of %s" % [short, String(missing)])


## Fuel a burner is kept topped up to: half a minute of full output.
func _fuel_reserve(building_id: int) -> float:
	var burn: float = 0.0
	var b: Object = _building(building_id)
	if b != null:
		var traits: Dictionary = _traits_of(StringName(String(b.get("kind"))))
		burn = float(traits.get("burn", 0.0))
	return maxf(MIN_FUEL_RESERVE, burn * FUEL_RESERVE_SECONDS)


## Stores that asked to be kept stocked get filled from everywhere else.
func _serve_requests() -> void:
	for id: int in world.store_ids():
		var st: LogiStore = world.stores[id]
		if not st.requesting:
			continue
		var cell: Vector2i = world.store_origin.get(id, Vector2i.ZERO)
		var keys: Array = st.requests.keys()
		keys.sort()
		for kind: StringName in keys:
			var need: int = st.shortfall(kind)
			if need <= 0:
				continue
			var got: int = haul.serve(world, _stock(), id, cell, kind, need)
			if got > 0:
				var placed: int = st.insert(kind, got)
				if placed < got:
					_return_items(cell, kind, got - placed)
			else:
				Bus.machine_stalled.emit(id, &"no_items")


## Hands items nobody could take back to the city stockpile. Conservation is not
## optional: an item that disappears is a balance bug nobody will ever find.
func _return_items(_cell: Vector2i, kind: StringName, amount: int) -> void:
	if amount <= 0:
		return
	var st: BuildStock = _stock()
	if st == null:
		return
	var back: Dictionary[StringName, int] = {}
	back[kind] = amount
	st.give(back)


# =========================================================================
# [P11] handshake
# =========================================================================

## Pulls finished buildings out of build and takes an interest in the ones that
## hold items or burn fuel. A pull rather than a Bus subscription, for the same
## reason [P02] pulls: a RefCounted system that subscribes to an autoload signal
## is never released.
func _sync_from_build() -> void:
	if _build == null or not _build.has_method("all_buildings"):
		return
	var raw: Variant = _build.call("all_buildings")
	if typeof(raw) != TYPE_ARRAY:
		return
	var list: Array = raw
	var seen: Dictionary[int, bool] = {}
	for entry: Variant in list:
		var b: Object = entry
		if b == null or not b.has_method("is_complete") or not bool(b.call("is_complete")):
			continue
		var id: int = int(b.get("id"))
		seen[id] = true
		if not _seen_build.has(id):
			_seen_build[id] = true
			_clear_ground_for(b)
		if _not_ours.has(id) or _adopted.has(id):
			continue
		_adopt(b, id)
	var known: Array = _adopted.keys()
	known.sort()
	for id2: int in known:
		if not seen.has(id2):
			_release(id2)
	if _not_ours.size() > seen.size():
		var stale: Array = _not_ours.keys()
		stale.sort()
		for id3: int in stale:
			if not seen.has(id3):
				_not_ours.erase(id3)
				_seen_build.erase(id3)


## [P11] owns the ground. Anything of ours under a new building is torn out and
## refunded rather than left in a state where two systems both think they are
## standing there.
func _clear_ground_for(b: Object) -> void:
	if world.occ.is_empty():
		return
	var raw: Variant = b.get("cells")
	if typeof(raw) != TYPE_ARRAY:
		return
	var hit: Dictionary[int, bool] = {}
	for c: Variant in raw:
		var id: int = int(world.occ.get(c, -1))
		if id >= 0:
			hit[id] = true
	var ids: Array = hit.keys()
	ids.sort()
	for id2: int in ids:
		var e: LogiEntity = world.entities.get(id2)
		if e == null or e.from_build:
			continue
		Log.debug("logistics", "%s at %s removed: a building went up on top of it" % [
			String(e.kind), str(e.cell)])
		_remove_entity(id2, true)


func _adopt(b: Object, id: int) -> void:
	var kind: StringName = StringName(String(b.get("kind")))
	var traits: Dictionary = _traits_of(kind)
	var storage: int = int(traits.get("storage", 0))
	var fuel: StringName = traits.get("fuel", &"")
	if storage <= 0 and String(fuel) == "":
		_not_ours[id] = true
		return
	var cells: Array[Vector2i] = []
	var raw: Variant = b.get("cells")
	if typeof(raw) == TYPE_ARRAY:
		for c: Variant in raw:
			if typeof(c) == TYPE_VECTOR2I:
				cells.append(c)
	if cells.is_empty():
		cells.append(b.get("cell"))
	if storage > 0:
		var filter: Array[StringName] = traits.get("filter", [] as Array[StringName])
		var store := LogiStore.new(id, storage, filter)
		world.register_store(id, store, cells, cells[0])
	if String(fuel) != "":
		world.register_burner(id, fuel, cells)
	_adopted[id] = true
	Log.debug("logistics", "adopted %s #%d (storage %d, fuel %s)" % [
		String(kind), id, storage, String(fuel)])


func _release(id: int) -> void:
	world.unregister_store(id)
	world.unregister_burner(id)
	haul.forget(id)
	_adopted.erase(id)
	_seen_build.erase(id)


## What a [P11] building definition means to logistics, read once per kind.
func _traits_of(kind: StringName) -> Dictionary:
	var cached: Dictionary = _kind_traits.get(kind, {})
	if not cached.is_empty():
		return cached
	var out: Dictionary = {"storage": 0, "filter": [] as Array[StringName], "fuel": &"", "burn": 0.0}
	var res: Resource = Registry.get_item("buildings", kind)
	if res != null:
		if "storage_capacity" in res:
			out["storage"] = maxi(0, int(res.get("storage_capacity")))
		if "storage_filter" in res:
			var f: Variant = res.get("storage_filter")
			if typeof(f) == TYPE_ARRAY:
				var list: Array[StringName] = []
				for v: Variant in f:
					list.append(StringName(String(v)))
				out["filter"] = list
		if "fuel_items" in res:
			var fi: Variant = res.get("fuel_items")
			if typeof(fi) == TYPE_ARRAY and not (fi as Array).is_empty():
				out["fuel"] = StringName(String((fi as Array)[0]))
		if "fuel_burn_rate" in res:
			out["burn"] = maxf(0.0, float(res.get("fuel_burn_rate")))
	_kind_traits[kind] = out
	return out


func _building(id: int) -> Object:
	if _build == null or not _build.has_method("get_building"):
		return null
	return _build.call("get_building", id)


func _stock() -> BuildStock:
	if _build == null:
		return null
	var raw: Variant = _build.get("stock")
	return raw as BuildStock


# =========================================================================
# public API — everything another part is allowed to touch
# =========================================================================

## Items per second crossing the belt on this tile, smoothed over a second.
## 0 when there is no belt there. [P19]'s logistics lens colours belts with it.
func throughput_of(cell: Vector2i) -> float:
	return world.throughput_at(cell)


## 0..1, how full the belt on this tile is. 1.0 is a fully compressed belt.
func saturation_of(cell: Vector2i) -> float:
	return world.saturation_at(cell)


## True when this building asked logistics for something recently and went
## short. Machines, burners and requester chests all answer here.
func is_starved(building_id: int) -> bool:
	return haul.is_starved(building_id)


## Every building that is currently going short, ascending.
func starved_buildings() -> Array[int]:
	return haul.starved_ids()


## [P02]'s contract. Puts fuel in a burner's bunker and reports how much of it
## the city could actually find, in items.
func request_fuel(building_id: int, item: StringName, amount: float) -> float:
	haul.begin_tick(SimClock.tick, _crew())
	var want: int = int(ceilf(maxf(0.0, amount)))
	if want <= 0:
		return 0.0
	if not _has_any_source():
		_bootstrap_note()
		return float(want)
	var cell: Vector2i = world.store_origin.get(building_id, _cell_of(building_id))
	var got: int = haul.serve(world, _stock(), building_id, cell, item, want)
	haul.fuel_total += got
	return float(got)


## The same thing for anybody who is not a burner: [P04]'s machines, a granary
## asking for grain, a turret asking for shells. Returns what arrived, and puts
## it straight into the building's own store when it has one.
func request_items(building_id: int, item: StringName, amount: int) -> int:
	haul.begin_tick(SimClock.tick, _crew())
	if amount <= 0:
		return 0
	var cell: Vector2i = world.store_origin.get(building_id, _cell_of(building_id))
	var got: int = haul.serve(world, _stock(), building_id, cell, item, amount)
	if got <= 0:
		return 0
	var st: LogiStore = world.stores.get(building_id)
	if st == null:
		return got
	var placed: int = st.insert(item, got)
	if placed < got:
		_return_items(cell, item, got - placed)
	return placed


## A building's own item buffer, or null. [P04] production reads and writes this
## one object rather than inventing a second inventory.
func store_of(building_id: int) -> LogiStore:
	return world.stores.get(building_id)


## Puts what a machine produced into its own buffer. Returns what fit.
func deposit(building_id: int, item: StringName, amount: int) -> int:
	var st: LogiStore = world.stores.get(building_id)
	if st == null:
		return 0
	var n: int = st.insert(item, amount)
	if n > 0:
		Bus.item_produced.emit(item, n)
	return n


## Takes ingredients out of a machine's buffer. Returns what was there.
func withdraw(building_id: int, item: StringName, amount: int) -> int:
	var st: LogiStore = world.stores.get(building_id)
	return 0 if st == null else st.take(item, amount)


## What a building is holding, item id -> count.
func contents_of(building_id: int) -> Dictionary[StringName, int]:
	var out: Dictionary[StringName, int] = {}
	var st: LogiStore = world.stores.get(building_id)
	if st == null:
		return out
	for k: StringName in st.kinds():
		out[k] = st.count(k)
	return out


## Asks the city to keep `amount` of `item` in this building.
func set_request(building_id: int, item: StringName, amount: int) -> bool:
	var st: LogiStore = world.stores.get(building_id)
	if st == null:
		return false
	st.set_request(item, amount)
	return true


## Item definition by id, or null.
func item(id: StringName) -> LogiItem:
	return _items.get(id)


func item_ids() -> Array[StringName]:
	var keys: Array = _items.keys()
	keys.sort()
	var out: Array[StringName] = []
	for k: StringName in keys:
		out.append(k)
	return out


## Transport definition by id, or null.
func def_of(kind: StringName) -> LogiDef:
	return _defs.get(kind)


func all_defs() -> Array[LogiDef]:
	var keys: Array = _defs.keys()
	keys.sort()
	var out: Array[LogiDef] = []
	for k: StringName in keys:
		out.append(_defs[k])
	return out


func entity_at(cell: Vector2i) -> LogiEntity:
	return world.entity_at(cell)


func segment_at(cell: Vector2i) -> LogiSegment:
	return world.segment_at(cell)


## Items on belts in world pixels — what [P13] draws and [P19] counts.
func items_for_view(bounds: Rect2i = Rect2i()) -> Array[Dictionary]:
	return world.items_for_view(bounds)


## Every belt tile with tier, direction and load.
func belts_for_view() -> Array[Dictionary]:
	return world.belts_for_view()


## City-wide totals, the same numbers metrics() reports.
func totals() -> Dictionary:
	return {
		"items_on_belts": world.items_on_belts(),
		"stored": world.stored_units(),
		"throughput": snappedf(world.total_belt_rate(), 0.01),
		"backed_up": world.backed_up_segments(),
		"starved": haul.starved_count(),
		"belts": world.segment_ids.size(),
		"entities": world.entity_ids.size(),
		"porters": haul.porters,
		"hauled": haul.hauled_total,
		"fuel_delivered": haul.fuel_total,
	}


# =========================================================================
# placement
# =========================================================================

## Can this go here? Pure: safe to call every frame for a ghost preview.
## Returns {ok, reason, cells}.
func can_place(kind: StringName, cell: Vector2i, rot: int = 0) -> Dictionary:
	var def: LogiDef = _defs.get(kind)
	if def == null:
		return {"ok": false, "reason": "There is no such thing as '%s'." % String(kind), "cells": []}
	if String(def.unlock_id) != "" and not _is_unlocked(def.unlock_id):
		return {"ok": false, "cells": [],
			"reason": "%s is still locked — research %s first." % [
				def.display_name, String(def.unlock_id).replace("_", " ")]}
	var cells: Array[Vector2i] = _cells_for(def, cell, rot)
	for c: Vector2i in cells:
		if world.occ.has(c):
			return {"ok": false, "reason": "Something of yours is already at %d, %d." % [c.x, c.y],
				"cells": cells}
		if not _ground_free(c):
			return {"ok": false, "reason": "The ground at %d, %d will not take it." % [c.x, c.y],
				"cells": cells}
	return {"ok": true, "reason": "", "cells": cells}


func _cells_for(def: LogiDef, cell: Vector2i, rot: int) -> Array[Vector2i]:
	if def.role_id() == LogiTypes.Role.SPLITTER:
		var d: Vector2i = LogiTypes.dir_vec(rot)
		return [cell, cell + LogiTypes.right_of(d)]
	return def.cells_at(cell, rot)


## Research gates are [P10]'s, and [P11] already knows how to answer for them
## while the tech tree is being built. Nothing is gated until somebody says so.
func _is_unlocked(unlock: StringName) -> bool:
	if _build != null and _build.has_method("is_unlocked"):
		return bool(_build.call("is_unlocked", unlock))
	return true


## True when neither [P01] nor [P11] objects to us standing on this tile.
func _ground_free(c: Vector2i) -> bool:
	if _build != null and _build.has_method("is_cell_free") and not bool(_build.call("is_cell_free", c)):
		return false
	if _grid != null and _grid.has_method("world"):
		var tiles: Object = _grid.call("world")
		if tiles != null and tiles.has_method("in_bounds") and not bool(tiles.call("in_bounds", c)):
			return false
		if tiles != null and tiles.has_method("is_buildable") and not bool(tiles.call("is_buildable", c)):
			return false
	return true


## Puts one piece of transport down. `free` skips the material cost.
func place(kind: StringName, cell: Vector2i, rot: int = 0, free: bool = false) -> Dictionary:
	var check: Dictionary = can_place(kind, cell, rot)
	if not bool(check["ok"]):
		Bus.placement_rejected.emit(cell, String(check["reason"]))
		return check
	var def: LogiDef = _defs[kind]
	if not free and not _pay(def):
		var poor: Dictionary = {"ok": false, "reason": "Not enough materials for a %s." % def.display_name,
			"cells": check["cells"]}
		Bus.placement_rejected.emit(cell, String(poor["reason"]))
		return poor

	var e: LogiEntity = _make_entity(def)
	e.id = _mint_id()
	e.kind = def.id
	e.def = def
	e.cell = cell
	e.rot = posmod(rot, 4) if def.is_rotatable() else 0
	e.cells = check["cells"]
	e.placed_tick = _tick
	if def.role_id() == LogiTypes.Role.CHEST:
		e.store = LogiStore.new(e.id, def.capacity, def.filter)
		e.store.requesting = def.requests
	world.add_entity(e)
	_placed_total += 1
	# No Bus.building_placed: [P13]'s world model is keyed to [P11] building ids
	# and would try to resolve a belt as a building. Belts reach the view through
	# belts_for_view() and items_for_view() instead, which is what they need.
	Log.debug("logistics", "placed %s #%d at %s" % [String(e.kind), e.id, str(e.cell)])
	return {"ok": true, "reason": "", "id": e.id, "cells": e.cells}


func _make_entity(def: LogiDef) -> LogiEntity:
	match def.role_id():
		LogiTypes.Role.SPLITTER:
			return LogiSplitter.new()
		LogiTypes.Role.INSERTER:
			return LogiInserter.new()
	return LogiEntity.new()


func _pay(def: LogiDef) -> bool:
	if def.cost.is_empty():
		return true
	var st: BuildStock = _stock()
	if st == null:
		return true
	return st.take(def.cost)


func _refund(def: LogiDef) -> void:
	if def == null or def.cost.is_empty():
		return
	var st: BuildStock = _stock()
	if st == null:
		return
	st.give(def.cost)


## Removes a piece of transport. Whatever was on it goes back to the stockpile
## rather than into the void.
func _remove_entity(id: int, refund: bool) -> bool:
	var e: LogiEntity = world.entities.get(id)
	if e == null:
		return false
	if e.store != null and not e.store.is_empty():
		var st: BuildStock = _stock()
		if st != null:
			var back: Dictionary[StringName, int] = {}
			for k: StringName in e.store.kinds():
				back[k] = e.store.count(k)
			st.give(back)
		e.store.clear()
	world.remove_entity(id)
	if refund:
		_refund(e.def)
	_removed_total += 1
	return true


func _mint_id() -> int:
	var id: int = _next_id
	_next_id += 1
	return id


func _cell_of(building_id: int) -> Vector2i:
	var b: Object = _building(building_id)
	if b != null:
		var c: Variant = b.get("cell")
		if typeof(c) == TYPE_VECTOR2I:
			return c
	if _heat != null:
		var nodes: Variant = _heat.get("nodes")
		if typeof(nodes) == TYPE_DICTIONARY:
			var n: Object = (nodes as Dictionary).get(building_id)
			if n != null:
				var hc: Variant = n.get("cell")
				if typeof(hc) == TYPE_VECTOR2I:
					return hc
	return Vector2i.ZERO


# =========================================================================
# commands
# =========================================================================

func handle_command(cmd: Dictionary) -> void:
	var op: String = String(cmd.get("op", ""))
	match op:
		"place":
			var r: Dictionary = place(StringName(String(cmd.get("kind", ""))),
				LogiTypes.to_cell(cmd.get("cell", [])), int(cmd.get("rot", 0)),
				bool(cmd.get("free", false)))
			if not bool(r["ok"]):
				Log.warn("logistics", "place refused: %s" % String(r.get("reason", "")))
		"place_line":
			_op_place_line(cmd)
		"remove":
			_remove_entity(int(cmd.get("id", -1)), true)
		"remove_at":
			var found: int = int(world.occ.get(LogiTypes.to_cell(cmd.get("cell", [])), -1))
			if found >= 0:
				_remove_entity(found, true)
		"rotate":
			_op_rotate(cmd)
		"set_enabled":
			var e: LogiEntity = _target(cmd)
			if e != null:
				e.enabled = bool(cmd.get("on", true))
		"set_filter":
			_op_set_filter(cmd)
		"set_priority":
			_op_set_priority(cmd)
		"insert":
			_op_insert(cmd)
		"request":
			_op_request(cmd)
		"dump":
			_dump()
		_:
			Log.warn("logistics", "unknown command op '%s'" % op)


func _target(cmd: Dictionary) -> LogiEntity:
	if cmd.has("id"):
		return world.entities.get(int(cmd["id"]))
	if cmd.has("cell"):
		return world.entity_at(LogiTypes.to_cell(cmd["cell"]))
	return null


## Drags a belt along an L-shaped path, turning each tile to face the next one —
## which is what a player's cursor means when it drags a belt.
func _op_place_line(cmd: Dictionary) -> void:
	var kind: StringName = StringName(String(cmd.get("kind", "")))
	var def: LogiDef = _defs.get(kind)
	if def == null:
		Log.warn("logistics", "place_line: no such thing as '%s'" % String(kind))
		return
	var from: Vector2i = LogiTypes.to_cell(cmd.get("from", []))
	var to: Vector2i = LogiTypes.to_cell(cmd.get("to", []))
	var free: bool = bool(cmd.get("free", false))
	var path: Array[Vector2i] = []
	var x: int = from.x
	while x != to.x:
		path.append(Vector2i(x, from.y))
		x += signi(to.x - from.x)
	var y: int = from.y
	while y != to.y:
		path.append(Vector2i(to.x, y))
		y += signi(to.y - from.y)
	path.append(to)

	var placed: int = 0
	for i: int in path.size():
		var step: Vector2i = path[i + 1] - path[i] if i + 1 < path.size() \
			else (path[i] - path[i - 1] if i > 0 else LogiTypes.dir_vec(int(cmd.get("rot", 0))))
		var rot: int = LogiTypes.rot_of(step)
		if rot < 0:
			rot = int(cmd.get("rot", 0))
		if bool(place(kind, path[i], rot, free)["ok"]):
			placed += 1
	Log.debug("logistics", "line of %s: %d of %d placed" % [String(kind), placed, path.size()])


func _op_rotate(cmd: Dictionary) -> void:
	var e: LogiEntity = _target(cmd)
	if e == null or e.def == null or not e.def.is_rotatable():
		return
	var want: int = int(cmd["rot"]) if cmd.has("rot") else e.rot + int(cmd.get("delta", 1))
	var rot: int = posmod(want, 4)
	if rot == e.rot:
		return
	var cells: Array[Vector2i] = _cells_for(e.def, e.cell, rot)
	for c: Vector2i in cells:
		var occupant: int = int(world.occ.get(c, -1))
		if occupant >= 0 and occupant != e.id:
			return
	var def: LogiDef = e.def
	var cell: Vector2i = e.cell
	var id: int = e.id
	var store: LogiStore = e.store
	world.remove_entity(id)
	e.rot = rot
	e.cells = cells
	e.pair_id = -1
	e.is_entrance = true
	e.store = store
	e.id = id
	e.cell = cell
	e.def = def
	world.add_entity(e)


func _op_set_filter(cmd: Dictionary) -> void:
	var e: LogiEntity = _target(cmd)
	if e == null:
		return
	var kind: StringName = StringName(String(cmd.get("item", "")))
	var sp := e as LogiSplitter
	if sp != null:
		sp.filter_kind = kind
		sp.filter_side = clampi(int(cmd.get("side", LogiSplitter.Side.LEFT)), 0, 1)
		return
	var arm := e as LogiInserter
	if arm != null:
		arm.filter_kind = kind
		return
	if e.store != null:
		var list: Array[StringName] = []
		if String(kind) != "":
			list.append(kind)
		e.store.filter = list


func _op_set_priority(cmd: Dictionary) -> void:
	var sp := _target(cmd) as LogiSplitter
	if sp == null:
		return
	if cmd.has("input"):
		sp.input_priority = _side_from(cmd["input"])
	if cmd.has("output"):
		sp.output_priority = _side_from(cmd["output"])


static func _side_from(v: Variant) -> int:
	var s: String = String(v).to_lower()
	if s == "left" or s == "0":
		return LogiSplitter.Side.LEFT
	if s == "right" or s == "1":
		return LogiSplitter.Side.RIGHT
	return LogiSplitter.Side.NONE


## Scenario and test hook: put items straight onto a belt or into a store.
func _op_insert(cmd: Dictionary) -> void:
	var cell: Vector2i = LogiTypes.to_cell(cmd.get("cell", []))
	var kind: StringName = StringName(String(cmd.get("item", "")))
	var count: int = maxi(1, int(cmd.get("count", 1)))
	var placed: int = world.give_to_cell(cell, kind, count)
	if placed < count:
		Log.debug("logistics", "insert: only %d of %d %s fitted at %s" % [
			placed, count, String(kind), str(cell)])


func _op_request(cmd: Dictionary) -> void:
	var id: int = int(cmd.get("id", -1))
	if id < 0 and cmd.has("cell"):
		id = int(world.store_cells.get(LogiTypes.to_cell(cmd["cell"]), -1))
	if not set_request(id, StringName(String(cmd.get("item", ""))), int(cmd.get("amount", 0))):
		Log.warn("logistics", "request: nothing with a store at id %d" % id)


func _dump() -> void:
	var t: Dictionary = totals()
	Log.info("logistics", "%d lines, %d items on belts, %.1f items/s, %d stored, %d backed up, %d starved" % [
		int(t["belts"]), int(t["items_on_belts"]), float(t["throughput"]),
		int(t["stored"]), int(t["backed_up"]), int(t["starved"])])


# =========================================================================
# persistence + metrics
# =========================================================================

func serialize() -> Dictionary:
	var ents: Array = []
	for id: int in world.entity_ids:
		ents.append(world.entities[id].to_json())
	var lines: Array = []
	for sid: int in world.segment_ids:
		lines.append(world.segments[sid].to_json(Callable(world, "kind_name")))
	var adopted: Array = []
	var keys: Array = _adopted.keys()
	keys.sort()
	for id2: int in keys:
		var st: LogiStore = world.stores.get(id2)
		var row: Dictionary = {"id": id2}
		if st != null:
			row["store"] = st.to_json()
		if world.fuel_item_of.has(id2):
			row["fuel"] = String(world.fuel_item_of[id2])
		adopted.append(row)
	return {
		"entities": ents,
		"lines": lines,
		"adopted": adopted,
		"haul": haul.to_json(),
		"totals": totals(),
		"spilled": world.spilled,
		"next_id": _next_id,
	}


func deserialize(data: Dictionary) -> void:
	for id: int in world.entity_ids.duplicate():
		world.remove_entity(id)
	world.rebuild_topology()
	_next_id = int(data.get("next_id", LOCAL_ID_BASE))
	for raw: Variant in data.get("entities", []):
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var row: Dictionary = raw
		if bool(row.get("from_build", false)):
			continue
		var def: LogiDef = _defs.get(StringName(String(row.get("kind", ""))))
		if def == null:
			continue
		var e: LogiEntity = _make_entity(def)
		e.id = int(row.get("id", _mint_id()))
		e.kind = def.id
		e.def = def
		e.cell = LogiTypes.to_cell(row.get("cell", []))
		e.rot = int(row.get("rot", 0))
		e.cells = _cells_for(def, e.cell, e.rot)
		e.enabled = bool(row.get("enabled", true))
		if def.role_id() == LogiTypes.Role.CHEST:
			e.store = LogiStore.new(e.id, def.capacity, def.filter)
			if row.has("store"):
				e.store.from_json(row["store"])
		world.add_entity(e)
		_next_id = maxi(_next_id, e.id + 1)
	world.rebuild_topology()
	for raw2: Variant in data.get("lines", []):
		if typeof(raw2) != TYPE_DICTIONARY:
			continue
		var line: Dictionary = raw2
		var seg: LogiSegment = world.segment_at(LogiTypes.to_cell(line.get("entry", [])))
		if seg == null:
			continue
		var lanes: Array = line.get("lanes", [])
		for lane: int in mini(LogiTypes.LANES, lanes.size()):
			var flat: Array = lanes[lane]
			var i: int = 0
			while i + 1 < flat.size():
				seg.lanes[lane].insert_at(world.intern(StringName(String(flat[i]))), float(flat[i + 1]))
				i += 2
	Log.info("logistics", "restored %d entities across %d lines" % [
		world.entity_ids.size(), world.segment_ids.size()])


func metrics() -> Dictionary:
	return {
		"items_on_belts": world.items_on_belts(),
		"throughput": snappedf(world.total_belt_rate(), 0.01),
		"backed_up_belts": world.backed_up_segments(),
		"starved_machines": haul.starved_count(),
		"belt_lines": world.segment_ids.size(),
		"entities": world.entity_ids.size(),
		"stored_items": world.stored_units(),
		"stores": world.stores.size(),
		"idle_arms": world.idle_arms(),
		"items_moved": world.items_moved,
		"hauled_total": haul.hauled_total,
		"fuel_delivered": haul.fuel_total,
		"burners_short": _fuel_short,
		"porters": haul.porters,
		"spilled": world.spilled,
	}
