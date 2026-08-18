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
## Ticks between full rescans of [P02]'s world for burners.
const BURNER_RESCAN_TICKS: int = 200
## Fastest a burner rescan may happen even when the heat world keeps changing.
## During a mass build, heat gains a node every few ticks and a rescan walks
## every pipe in the city; once every twenty ticks is a quarter of a second of
## latency on a bunker that starts empty anyway.
const BURNER_RESCAN_MIN: int = 20
## Ticks between sweeps of [P11]'s building list when its roster has not moved.
## roster_version counts placements, removals, completions and switches — but
## NOT a rotation, and a rotated belt has to turn. So the unconditional sweep
## stays, at the cadence it always had; the roster counter only makes it faster.
const SYNC_EVERY: int = 20
## Ticks between sweeping the drag tables for pieces [P11] no longer has.
const PRUNE_EVERY: int = 600
## Fastest a sweep may happen while the roster IS moving. A player dragging a
## belt wants it carrying coal a fifth of a second later, not a second later,
## and a mass build must still not walk seventeen hundred buildings every tick.
const SYNC_MIN: int = 4
## How often the profiling line is written at DEBUG.
const LOG_PERF_EVERY: int = 1000

## Ticks between recomputing which burners have an arm loading them. Cheap
## (it walks the arms, not the city), but there is no reason to pay it a tick.
const LINE_FED_EVERY: int = 20
## Ticks between research reads. A node finishes once a minute at best.
const TECH_EVERY: int = 200
## Ticks between re-finding the Hearth. It is unique and it does not move, but it
## can be destroyed and rebuilt, and a yard at the wrong end of the map would
## price every stockpile delivery in the city wrongly.
const YARD_EVERY: int = 400
## Ticks between sweeps for arms aimed at nothing and belts that feed no one.
## Walks the arms and the lines, not the city; a player editing a factory should
## be told within a second, not on the next autosave.
const DEAD_END_EVERY: int = 20
## Ticks a belt or an arm must sit in the broken state before anybody says so.
## Twenty seconds: long past any drag, well short of a player wandering off.
const DEAD_END_GRACE: int = 400
## Ticks between re-raising the alert while the mistake is still there. Must stay
## under [P17]'s twelve-second bus TTL or a standing fault leaves the panel.
const DEAD_END_REPEAT: int = 160

## What _settled() decides: nothing, the first word (log + panel), or the panel
## alone (the alert has to be renewed; the log must not repeat itself).
const SAY_NOTHING: int = 0
const SAY_FIRST: int = 1
const SAY_AGAIN: int = 2

var world: LogiWorld = LogiWorld.new()
var haul: LogiHaul = LogiHaul.new()
## Placement through [P11]: the palette, the ghost, the drag. See LogiBuildLink.
var link: LogiBuildLink = LogiBuildLink.new()

var _items: Dictionary[StringName, LogiItem] = {}
var _defs: Dictionary[StringName, LogiDef] = {}
var _next_id: int = LOCAL_ID_BASE
var _tick: int = 0

var _build: SimSystem = null
var _heat: SimSystem = null
var _grid: SimSystem = null
var _research: SimSystem = null
var _production: SimSystem = null
var _tech_tick: int = -100000
var _yard_tick: int = -100000
var _yard_logged: bool = false

## [P11] buildings we have taken an interest in, and the ones we never will.
var _adopted: Dictionary[int, bool] = {}
var _not_ours: Dictionary[int, bool] = {}
var _seen_build: Dictionary[int, bool] = {}
## Building kind -> {storage, filter, fuel, burn} read once out of the registry.
var _kind_traits: Dictionary[StringName, Dictionary] = {}

var _last_alert_tick: int = -100000
var _perf_us: int = 0
var _perf_max_us: int = 0
var _perf_steps: int = 0
var _sync_tick: int = -100000
var _burner_cache: Array[int] = []
var _burner_fuel: Dictionary[int, StringName] = {}
var _burner_seen: Dictionary[int, bool] = {}
var _reserve_cache: Dictionary[int, float] = {}
var _burner_scan_size: int = -1
var _burner_scan_tick: int = -100000
## True while there is nowhere in the world an item could come from. See
## _has_any_source: this is the counterpart of [P02]'s fuel autarky.
var _bootstrap_logged: bool = false
## True while the simulation itself is running, so a view-side read can never
## mutate the world. See _ensure_adopted.
var _in_sim: bool = false
var _placed_total: int = 0
var _removed_total: int = 0
var _fuel_short: int = 0
var _roster_v: int = -1
var _prune_tick: int = -100000
var _adopted_transport: Array[int] = []
## Burner id -> true while an arm is loading it. Recomputed on a slow timer.
var _line_fed: Dictionary[int, bool] = {}
## Store owner -> true while an arm is lifting goods off it. Same slow timer as
## _line_fed, and the gate on accept_output().
var _arm_drained: Dictionary[int, bool] = {}
var _line_fed_tick: int = -100000
var _line_dry: int = 0
var _line_fed_logged: Dictionary[int, bool] = {}
var _items_moved_total: int = 0
var _dead_end_tick: int = -100000
var _arms_no_target: int = 0
var _lines_to_nowhere: int = 0
## Cell -> the tick it was first seen broken, and the cells already spoken for.
var _dead_end_since: Dictionary[Vector2i, int] = {}
var _dead_end_logged: Dictionary[Vector2i, bool] = {}
## Cell -> the tick its alert was last renewed for the panel.
var _dead_end_said: Dictionary[Vector2i, int] = {}


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
	link = LogiBuildLink.new()
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
	_burner_cache = []
	_burner_fuel = {}
	_burner_seen = {}
	_reserve_cache = {}
	_burner_scan_size = -1
	_burner_scan_tick = -100000
	_bootstrap_logged = false
	_roster_v = -1
	_prune_tick = -100000
	_adopted_transport = []
	_production = null
	_line_fed = {}
	_arm_drained = {}
	_line_fed_tick = -100000
	_line_fed_logged = {}
	_line_dry = 0
	_items_moved_total = 0
	_dead_end_tick = -100000
	_arms_no_target = 0
	_lines_to_nowhere = 0
	_dead_end_since = {}
	_dead_end_logged = {}
	_dead_end_said = {}
	_yard_tick = -100000
	_yard_logged = false
	_load_content()


func post_setup() -> void:
	_build = Sim.get_system(&"build")
	_heat = Sim.get_system(&"heat")
	_grid = Sim.get_system(&"grid")
	_research = Sim.get_system(&"research")
	_production = Sim.get_system(&"production")
	if _production != null and _production.has_method("offer_input"):
		world.machine_input = _offer_to_machine
	_read_tech()
	world.bind(_heat, _build)
	_read_yard()
	Log.info("logistics", ("ready — %d items, %d transport definitions, heat=%s build=%s; "
		+ "haul crew %d, %.1f items/s citywide, range %d tiles, yard %s") % [
		_items.size(), _defs.size(), str(_heat != null), str(_build != null),
		LogiHaul.BASE_PORTERS, haul.capacity(), LogiHaul.HAUL_RANGE, _yard_words()])
	_report_reachability()


## Says out loud how much of the transport ladder a player can actually put down.
##
## This part spent a whole phase carrying belts nothing could place: every piece
## existed, every test passed, and `logistics.belt_lines` was 0 for the entire
## reference run because no belt was a BuildingDef and so no build menu ever
## listed one. A pillar that is unreachable is not a pillar, and a build that
## cannot see the difference will ship it twice. So the count is printed on the
## ready line, and tests/logistics/test_logistics_build.gd fails if it drops.
func _report_reachability() -> void:
	if _build == null or not _build.has_method("def_of"):
		Log.warn("logistics", "no build system — transport cannot be placed by a player in this build")
		return
	var placeable: PackedStringArray = PackedStringArray()
	var orphan: PackedStringArray = PackedStringArray()
	for def: LogiDef in all_defs():
		if _build.call("def_of", def.id) != null:
			placeable.append(String(def.id))
		else:
			orphan.append(String(def.id))
	if orphan.is_empty():
		Log.info("logistics", "buildable — all %d transport pieces are in the build catalogue" % placeable.size())
	else:
		Log.warn("logistics", "%d of %d transport pieces have no BuildingDef and cannot be placed by a player: %s" % [
			orphan.size(), _defs.size(), ", ".join(orphan)])


## Every transport piece a player can actually select in the build menu.
func placeable_kinds() -> Array[StringName]:
	var out: Array[StringName] = []
	if _build == null or not _build.has_method("def_of"):
		return out
	for def: LogiDef in all_defs():
		if _build.call("def_of", def.id) != null:
			out.append(def.id)
	return out


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
	var t0: int = Time.get_ticks_usec()  # lint:allow profiling only; never serialized
	_in_sim = true
	_tick = tick
	if tick - _tech_tick >= TECH_EVERY:
		_tech_tick = tick
		_read_tech()
	if tick - _yard_tick >= YARD_EVERY:
		_yard_tick = tick
		_read_yard()
	haul.begin_tick(tick, _crew())
	_sync_from_build()
	world.step(tick)
	_items_moved_total += world.items_moved
	# Fuel every tick, stock requests every half second: a burner running dry is
	# the difference between a lit city and a dead one, and the loop is a handful
	# of early-outs when every bunker is full.
	_serve_fuel()
	if tick % REQUEST_EVERY == 0:
		_serve_requests()
	_check_dead_ends()

	_in_sim = false
	var us: int = Time.get_ticks_usec() - t0  # lint:allow profiling only
	_perf_us += us
	_perf_max_us = maxi(_perf_max_us, us)
	_perf_steps += 1
	if _perf_steps >= LOG_PERF_EVERY:
		Log.debug("logistics", "step avg %.1f us, max %d us over %d ticks; %d lines, %d items, %d arms" % [
			float(_perf_us) / float(_perf_steps), _perf_max_us, _perf_steps,
			world.segment_ids.size(), world.items_on_belts(), world.inserter_ids.size()])
		_perf_us = 0
		_perf_max_us = 0
		_perf_steps = 0


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


## Porters available to the haul network. A CONSTANT, and that is the design.
##
## This used to read `BASE_PORTERS + population / 4` and it was the largest
## balance hole in the build: 18 founders became 59 people became 19 porters
## became 76 items a second of free, unbuilt, unlimited-range throughput by day
## three — five belt_mk1s' worth, growing on its own, for a player who never
## opened the Logistics tab. Growth in a city builder must not silently buy you
## out of the automation game; the city gets bigger, the sledge crew does not,
## and the gap between them is the reason to lay a belt.
##
## The crew grows through `logistics.throughput_mult` research, which the player
## pays for. See LogiHaul's header.
func _crew() -> int:
	return LogiHaul.BASE_PORTERS


## Slow-timer read of [P10]. Applies to the crew that ALREADY exists, per §7 of
## the architecture contract: Hand Carts makes today's porters quicker, it does
## not unlock a porter.
func _read_tech() -> void:
	if _research == null or not _research.has_method("multiplier"):
		haul.rate_mult = 1.0
		return
	var v: Variant = _research.call("multiplier", ResearchDefs.E_LOGI_THROUGHPUT_MULT)
	if typeof(v) != TYPE_FLOAT and typeof(v) != TYPE_INT:
		return
	haul.rate_mult = clampf(float(v), 0.25, 8.0)


## Where the construction stockpile is, for pricing a delivery out of it.
##
## THE STOCKPILE IS NOT NOWHERE. [P11]'s stock is a flat dictionary with no
## position, so the haul network charged it 1.0 per item to anywhere on the map
## and never refused it — 1211 of the 1980 items hauled in the reference run.
## The yard is the Hearth, which is `unique`, which is why one building is the
## whole answer; the day this city has two, the first by id wins and the log
## says which.
func _read_yard() -> void:
	if _build == null or not _build.has_method("buildings_of_kind"):
		return
	var raw: Variant = _build.call("buildings_of_kind", &"the_hearth")
	if typeof(raw) != TYPE_ARRAY:
		return
	var found: Array = raw
	if found.is_empty():
		if not _yard_logged:
			_yard_logged = true
			Log.info("logistics", ("no Hearth in this world, so the stockpile has no yard to "
				+ "walk from — deliveries out of it are priced as if they were next door"))
		return
	var b: Object = found[0]
	if b == null:
		return
	var raw_cell: Variant = b.get("cell")
	if typeof(raw_cell) != TYPE_VECTOR2I:
		return
	var at: Vector2i = raw_cell
	if haul.yard == at:
		return
	haul.yard = at
	Log.info("logistics", "the city's yard is the Hearth at (%d,%d) — every stockpile delivery is priced from there" % [at.x, at.y])


func _yard_words() -> String:
	return "unplaced" if haul.yard.x == -2147483648 else "(%d,%d)" % [haul.yard.x, haul.yard.y]


## Keeps every burner [P02] owns above a floor of fuel, so a generator browns
## out because the city ran out of coal and never because nobody walked over.
func _serve_fuel() -> void:
	if _heat == null:
		return
	_refresh_line_fed()
	var short: int = 0
	var dry_lines: int = 0
	var missing: StringName = &""
	var unmetered: bool = not _has_any_source()
	for id: int in _burners():
		var fuel: StringName = _fuel_of(id)
		if String(fuel) == "":
			continue
		if not bool(_heat.call("has_building", id)):
			continue
		var stock: float = float(_heat.call("fuel_stock_of", id))
		var reserve: float = _fuel_reserve(id)
		if _line_fed.has(id):
			# THE INTERLOCK. You built the line; the line feeds it. Porters do
			# not quietly cover for a belt that has been cut, or the automation
			# half of this game would be decoration — a burner that a hand-cart
			# always reaches can never brown out because of a factory mistake.
			if stock < MIN_FUEL_RESERVE:
				dry_lines += 1
				short += 1
				missing = fuel
				_note_dry_line(id)
			else:
				_line_fed_logged.erase(id)
			continue
		if stock >= reserve:
			continue
		var want: int = int(ceilf(reserve - stock))
		var cell: Vector2i = world.store_origin.get(id, _cell_of(id))
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
	_line_dry = dry_lines
	if short > 0 and _tick - _last_alert_tick >= ALERT_EVERY:
		_last_alert_tick = _tick
		var what: String = String(missing).replace("_", " ")
		if dry_lines >= short:
			Bus.alert_raised.emit(1, &"line_dry",
				"%d burner%s starving on an empty line — nothing is arriving on the belt" % [
					dry_lines, "" if dry_lines == 1 else "s"], Vector2.ZERO)
			Log.info("logistics", "%d line-fed burners dry — the belt into them is empty" % dry_lines)
		else:
			# "THE CITY IS OUT OF COAL" WHILE THE STORES RAIL SAYS 160 COAL.
			# `haul.serve` returning nothing means nothing ARRIVED, which is
			# three different situations: the city has none of the stuff, or it
			# has it and no porter got there in time. Only the first one is
			# "out of". The other one is the player's actual problem — a bunker
			# too far from the stores for the crew it has — and naming it is the
			# difference between an alert and a lie the resource rail contradicts
			# in the same frame.
			var in_store: int = 0
			var st: BuildStock = _stock()
			if st != null:
				in_store = st.count(missing)
			var sentence: String = ""
			if in_store > 0:
				sentence = ("%d burner%s running dry — there is %s in store and " +
					"nobody is carrying it there") % [
						short, "" if short == 1 else "s",
						"%d %s" % [in_store, what]]
			else:
				sentence = "%d burner%s running dry — the city is out of %s" % [
					short, "" if short == 1 else "s", what]
			Bus.alert_raised.emit(1, &"fuel_short", sentence, Vector2.ZERO)
			# The same sentence the alert two lines up says, in the same words.
			# It used to read `1 burners short of waste_heat (0 of them on a
			# dead line)` — a plural on a count of one, a content id where the
			# alert beside it said "waste heat", and a parenthesis whose whole
			# job is to name a subset that is empty. It printed 21 times in one
			# 24000-tick run, which is 21 chances to read the log as noise.
			var tail: String = ""
			if dry_lines > 0:
				tail = ", %d of them on a dead line" % dry_lines
			Log.info("logistics", "%d burner%s short of %s%s" % [
				short, "" if short == 1 else "s", what, tail])


## Belt that cannot deliver anything to anything, named out loud.
##
## THE QUESTION THIS ANSWERS. A critic reading the reference run saw three lines
## reporting `blocked` for 80% of it and two ending in `sink_id: -1`, and read
## that as two belts going nowhere. It was not: lines 1-3 are ONE compressed
## chain out of the coal yard whose last tile is bare ground behind the last arm,
## and line 4 ends under the last of four arms on the Hearth's south face. All
## four are working belts with more supply than demand, which is what a full belt
## MEANS. But nothing in this build could say so, and a number a critic has to
## guess at is a number that will be guessed wrong. So now the system answers it:
## an arm aimed at snow, and a line with no sink and no arm on it, are counted,
## published in state.json, and said once each in the log with their cell.
##
## THE GRACE PERIOD IS THE WHOLE DESIGN. Every belt is a belt to nowhere for the
## second between laying the first tile and laying the second, and an assistant
## that says so is worse than one that says nothing — the first draft of this
## shouted at t261 about a nine-tile run that was four ticks old. So the state is
## measured continuously and only SPOKEN after DEAD_END_GRACE ticks of it, keyed
## on the cell rather than the entity id, because a line's id changes every time
## the player extends it and its exit does not.
func _check_dead_ends() -> void:
	if _tick - _dead_end_tick < DEAD_END_EVERY:
		return
	_dead_end_tick = _tick
	var seen: Dictionary[Vector2i, bool] = {}
	var arms: int = 0
	var lines: int = 0

	for id: int in world.arms_with_no_target():
		var arm: LogiInserter = world.entities.get(id)
		if arm == null:
			continue
		arms += 1
		var at: Vector2i = arm.target_cell()
		seen[arm.cell] = true
		var say: int = _settled(arm.cell)
		if say == SAY_NOTHING:
			continue
		if say == SAY_FIRST:
			Log.info("logistics", ("arm at (%d,%d) is aimed at (%d,%d) and there is nothing "
				+ "there — it will never put anything down") % [arm.cell.x, arm.cell.y, at.x, at.y])
		Bus.alert_raised.emit(1, &"build_arm_no_target",
			"An arm is reaching into empty ground — nothing it picks up can be put down.",
			Vector2(at) * LogiTypes.TILE)

	for sid: int in world.lines_to_nowhere():
		var seg: LogiSegment = world.segments.get(sid)
		if seg == null:
			continue
		lines += 1
		seen[seg.exit_cell] = true
		var say2: int = _settled(seg.exit_cell)
		if say2 == SAY_NOTHING:
			continue
		if say2 == SAY_FIRST:
			Log.info("logistics", ("the line from (%d,%d) to (%d,%d) ends in nothing and no arm "
				+ "reaches onto it — it moves goods to no one") % [
				seg.entry_cell.x, seg.entry_cell.y, seg.exit_cell.x, seg.exit_cell.y])
		Bus.alert_raised.emit(1, &"build_belt_to_nowhere",
			"This belt ends in open ground and nothing takes anything off it.",
			Vector2(seg.exit_cell) * LogiTypes.TILE)

	_arms_no_target = arms
	_lines_to_nowhere = lines
	_forget_fixed(seen)


## SAY_FIRST on the one sweep `where` crosses DEAD_END_GRACE, SAY_AGAIN every
## DEAD_END_REPEAT ticks it is still broken after that, SAY_NOTHING otherwise.
##
## THE LOG AND THE PANEL WANT OPPOSITE THINGS AND THIS IS WHERE THAT IS DECIDED.
## A log is a transcript: saying "this belt goes nowhere" a hundred times is how
## log.txt becomes unreadable, so it is said once. The ATTENTION panel is a
## STATUS, and [P17] ages a bus alert out after twelve seconds — so a standing
## condition announced once is a condition that is not on screen thirty seconds
## later. The first draft did the once-only thing for both, and the proof shot
## `artifacts/H2_nowhere_vis/shots/named.world.png` came back with the belt
## plainly visible, `lines_to_nowhere: 1` in state.json, and NOTHING IN THE
## PANEL: raised at t441, expired by t681, photographed at t2200.
func _settled(where: Vector2i) -> int:
	if not _dead_end_since.has(where):
		_dead_end_since[where] = _tick
		return SAY_NOTHING
	if _tick - int(_dead_end_since[where]) < DEAD_END_GRACE:
		return SAY_NOTHING
	if not _dead_end_logged.has(where):
		_dead_end_logged[where] = true
		_dead_end_said[where] = _tick
		return SAY_FIRST
	if _tick - int(_dead_end_said.get(where, -100000)) < DEAD_END_REPEAT:
		return SAY_NOTHING
	_dead_end_said[where] = _tick
	return SAY_AGAIN


## Drops the cells that are no longer broken, so fixing a belt and breaking it
## again a day later is two warnings, not one.
func _forget_fixed(seen: Dictionary[Vector2i, bool]) -> void:
	var keys: Array = _dead_end_since.keys()
	keys.sort()
	for k: Vector2i in keys:
		if not seen.has(k):
			_dead_end_since.erase(k)
			_dead_end_logged.erase(k)
			_dead_end_said.erase(k)


## Which burners have an arm loading them, refreshed on a slow timer. Walks the
## arms, not the city, so it stays a rounding error even in a big factory.
func _refresh_line_fed() -> void:
	if _tick - _line_fed_tick < LINE_FED_EVERY:
		return
	_line_fed_tick = _tick
	_line_fed = world.line_fed_burners()
	_arm_drained = world.arm_drained_stores()


## Says it once per burner, at INFO, the first time its line goes dry. A player
## reading log.txt has to be able to tell "the city has no coal" apart from
## "the coal exists and your belt does not reach it".
func _note_dry_line(id: int) -> void:
	if _line_fed_logged.has(id):
		return
	_line_fed_logged[id] = true
	Log.info("logistics", "burner #%d is fed by an arm and its line has run dry — porters stand down" % id)


## Every burner in the world that wants fuel, ascending.
##
## Not just the ones [P11] built: [P02] can own heat entities nobody constructed
## (its own command surface mints them, and every heat test does), and a burner
## nobody feeds is a burner that never lights. The list is rebuilt only when the
## heat world actually changed size, because a hundred and fifty pipes must not
## be walked every tick to find two furnaces.
func _burners() -> Array[int]:
	var nodes: Dictionary = {}
	if _heat != null:
		var raw: Variant = _heat.get("nodes")
		if typeof(raw) == TYPE_DICTIONARY:
			nodes = raw
	var changed: bool = nodes.size() != _burner_scan_size
	var waited: int = _tick - _burner_scan_tick
	if not ((changed and waited >= BURNER_RESCAN_MIN) or waited >= BURNER_RESCAN_TICKS):
		return _burner_cache
	_burner_scan_size = nodes.size()
	_burner_scan_tick = _tick

	# Incremental: a heat node is classified once and never again. A city with
	# fourteen hundred pipes must not pay for forty property reads apiece every
	# time somebody finishes a wall.
	var dirty: bool = false
	for id: Variant in nodes:
		var key: int = int(id)
		if _burner_seen.has(key):
			continue
		_burner_seen[key] = true
		var n: Object = nodes[id]
		if n == null:
			continue
		var d: Object = n.get("def")
		if d == null:
			continue
		var fuel: StringName = StringName(String(d.get("fuel")))
		if String(fuel) != "":
			_burner_fuel[key] = fuel
			dirty = true
	for id2: int in world.burner_ids():
		if not _burner_fuel.has(id2):
			_burner_fuel[id2] = world.fuel_item_of[id2]
			dirty = true
	if _burner_seen.size() > nodes.size():
		# Something was demolished. Rare, and the only time the full list is walked.
		var stale: Array = _burner_seen.keys()
		stale.sort()
		for k2: int in stale:
			if not nodes.has(k2) and not world.fuel_item_of.has(k2):
				_burner_seen.erase(k2)
				if _burner_fuel.erase(k2):
					dirty = true
	if dirty:
		var keys: Array = _burner_fuel.keys()
		keys.sort()
		_burner_cache = []
		for k: int in keys:
			_burner_cache.append(k)
	return _burner_cache


func _fuel_of(building_id: int) -> StringName:
	var known: StringName = _burner_fuel.get(building_id, &"")
	if String(known) != "":
		return known
	return world.fuel_item_of.get(building_id, &"")


## Fuel a burner is kept topped up to: half a minute of full output.
func _fuel_reserve(building_id: int) -> float:
	var cached: float = float(_reserve_cache.get(building_id, -1.0))
	if cached >= 0.0:
		return cached
	var burn: float = _burn_rate(building_id)
	if burn <= 0.0:
		var b: Object = _building(building_id)
		if b != null:
			var traits: Dictionary = _traits_of(StringName(String(b.get("kind"))))
			burn = float(traits.get("burn", 0.0))
	var reserve: float = maxf(MIN_FUEL_RESERVE, burn * FUEL_RESERVE_SECONDS)
	_reserve_cache[building_id] = reserve
	return reserve


## Items per second this burner eats at full output, straight off [P02]'s own
## normalised definition, so a retuned .tres changes the reserve with it.
func _burn_rate(building_id: int) -> float:
	if _heat == null:
		return 0.0
	var raw: Variant = _heat.get("nodes")
	if typeof(raw) != TYPE_DICTIONARY:
		return 0.0
	var n: Object = (raw as Dictionary).get(building_id)
	if n == null:
		return 0.0
	var d: Object = n.get("def")
	if d == null:
		return 0.0
	return maxf(0.0, (float(d.get("output")) + float(d.get("self_burn")))
		* float(d.get("fuel_per_unit")))


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
			var was_short: bool = haul.is_starved(id)
			var got: int = haul.serve(world, _stock(), id, cell, kind, need)
			if got > 0:
				var placed: int = st.insert(kind, got)
				if placed < got:
					_return_items(cell, kind, got - placed)
			elif not was_short:
				# On the edge only. A building that has been starving for a minute
				# is one alert, not a hundred and twenty.
				Bus.machine_stalled.emit(id, &"no_items")


## Hands items nobody could take back to the city stockpile. Conservation is not
## optional: an item that disappears is a balance bug nobody will ever find.
func _return_items(_cell: Vector2i, kind: StringName, amount: int) -> void:
	if amount <= 0:
		return
	var back: Dictionary[StringName, int] = {}
	back[kind] = amount
	_return_stock(back)


## Hands a whole bundle back to the city stockpile.
func _return_stock(items: Dictionary[StringName, int]) -> void:
	if items.is_empty():
		return
	var st: BuildStock = _stock()
	if st == null:
		return
	st.give(items)


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
	# Walking seventeen hundred buildings every tick to find the two that gained
	# a chest is most of what this system would cost in a big city. [P11] keeps a
	# monotonic roster counter for exactly this question, so the sweep runs when
	# something actually moved — at most every SYNC_MIN ticks during a mass
	# build — and otherwise idles on a slow tripwire.
	var version: int = int(_build.call("roster_version")) if _build.has_method("roster_version") else _tick
	var waited: int = _tick - _sync_tick
	var moved: bool = version != _roster_v
	if not ((moved and waited >= SYNC_MIN) or waited >= SYNC_EVERY):
		return
	_roster_v = version
	_sync_tick = _tick
	var raw: Variant = _build.call("all_buildings")
	if typeof(raw) != TYPE_ARRAY:
		return
	var list: Array = raw
	var seen: Dictionary[int, bool] = {}
	# Every id [P11] still has, gathered only on the slow prune tick. A piece
	# cancelled while it was a ghost is noted and never adopted, so the drag
	# tables need somebody to tell them it is gone.
	var pruning: bool = _tick - _prune_tick >= PRUNE_EVERY
	var roster: Dictionary[int, bool] = {}
	# Only what actually needs work is carried out of the walk. A city with
	# fourteen hundred finished buildings must not allocate a fourteen-hundred
	# element array to notice that one crate finished.
	var fresh: Array[Object] = []
	for entry: Variant in list:
		var b: Object = entry
		if b == null or not b.has_method("is_complete"):
			continue
		var id: int = int(b.get("id"))
		if pruning:
			roster[id] = true
		var mine: LogiDef = _defs.get(StringName(String(b.get("kind"))))
		if mine != null:
			# Recorded the moment the site exists, finished or not: the facing of
			# a dragged run is decided by the run, and the run is only legible
			# while all of it is still fresh.
			link.note(id, mine.id, b.get("cell"), int(b.get("rot")),
				int(b.get("placed_tick")), mine.is_transport())
		if not bool(b.call("is_complete")):
			continue
		seen[id] = true
		if not _seen_build.has(id):
			_seen_build[id] = true
			_clear_ground_for(b)
		if _not_ours.has(id):
			continue
		if _adopted.has(id):
			_resync_entity(b, id)
		else:
			fresh.append(b)
	# Facings first: a belt that finished this sweep has to know which way the
	# drag was going before it becomes a transport line.
	_apply_run_facings()
	for b2: Object in fresh:
		_adopt(b2, int(b2.get("id")))
	var known: Array = _adopted.keys()
	known.sort()
	for id3: int in known:
		if not seen.has(id3):
			_release(id3)
	if _not_ours.size() > seen.size():
		var stale: Array = _not_ours.keys()
		stale.sort()
		for id4: int in stale:
			if not seen.has(id4):
				_not_ours.erase(id4)
				_seen_build.erase(id4)
	if pruning:
		_prune_tick = _tick
		link.prune(roster)


## Turns each dragged run into a line of belts that faces the way the cursor
## went, and writes that rotation back onto [P11]'s instance so the build
## system, the renderer and the transport line all describe the same belt.
func _apply_run_facings() -> void:
	if not link.has_pending():
		return
	var decided: Array[Dictionary] = link.resolve()
	for row: Dictionary in decided:
		var id: int = int(row["id"])
		var rot: int = int(row["rot"])
		var b: Object = _building(id)
		if b == null:
			continue
		var def: LogiDef = _defs.get(StringName(String(b.get("kind"))))
		if def == null or not def.is_rotatable():
			continue
		# Only a one-tile piece. Rotating anything larger moves its footprint and
		# that is [P11]'s bookkeeping, not ours.
		if def.size != Vector2i.ONE:
			continue
		if int(b.get("rot")) == rot:
			continue
		b.set("rot", rot)
		if b.has_method("refresh_cells"):
			b.call("refresh_cells")


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
	# A piece that is a LogiDef AND a BuildingDef is one thing placed by [P11]
	# and driven by us. That is the whole point of the two-file handshake.
	var transport: LogiDef = _defs.get(kind)
	if transport != null:
		if _adopt_transport(b, id, transport):
			_adopted[id] = true
			return
		_not_ours[id] = true
		return
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


## Gives a [P11]-placed belt, tunnel, splitter, arm or chest its transport
## behaviour. The building keeps its id, so removing it, rotating it, switching
## it off or blueprinting it all reach the same object from both sides.
func _adopt_transport(b: Object, id: int, def: LogiDef) -> bool:
	if world.entities.has(id):
		return true
	var cells: Array[Vector2i] = _cells_of(b)
	if cells.is_empty():
		return false
	var rot: int = link.facing_of(id, int(b.get("rot"))) if def.is_rotatable() else 0
	var e: LogiEntity = _make_entity(def)
	e.id = id
	e.kind = def.id
	e.def = def
	e.rot = posmod(rot, 4)
	e.cell = _entity_origin(def, cells, e.rot, b.get("cell"))
	e.cells = cells
	e.from_build = true
	e.enabled = bool(b.get("enabled"))
	e.placed_tick = int(b.get("placed_tick"))
	if def.role_id() == LogiTypes.Role.CHEST:
		e.store = LogiStore.new(id, def.capacity, def.filter)
		e.store.requesting = def.requests
	world.add_entity(e)
	_placed_total += 1
	_adopted_transport.append(id)
	Log.debug("logistics", "adopted %s #%d at %s facing %d (placed by build)" % [
		String(def.id), id, str(e.cell), e.rot])
	return true


## [P11] anchors a footprint at its minimum corner. A splitter is anchored at
## its left half, which for two of the four rotations is the other cell.
func _entity_origin(def: LogiDef, cells: Array[Vector2i], rot: int, fallback: Variant) -> Vector2i:
	if def.role_id() == LogiTypes.Role.SPLITTER:
		return LogiBuildLink.splitter_origin(cells, rot)
	if typeof(fallback) == TYPE_VECTOR2I:
		return fallback
	return cells[0]


func _cells_of(b: Object) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var raw: Variant = b.get("cells")
	if typeof(raw) == TYPE_ARRAY:
		for c: Variant in raw:
			if typeof(c) == TYPE_VECTOR2I:
				out.append(c)
	if out.is_empty():
		var single: Variant = b.get("cell")
		if typeof(single) == TYPE_VECTOR2I:
			out.append(single)
	return out


## Keeps an adopted piece pointing where [P11] says it points. This is what
## makes R work on a belt that is already down: build rotates the instance, we
## notice, and the transport line is rebuilt around the new facing.
func _resync_entity(b: Object, id: int) -> void:
	var e: LogiEntity = world.entities.get(id)
	if e == null or e.def == null:
		return
	var on: bool = bool(b.get("enabled"))
	if e.enabled != on:
		e.enabled = on
	if not e.def.is_rotatable():
		return
	var rot: int = posmod(int(b.get("rot")), 4)
	if rot == e.rot:
		return
	var cells: Array[Vector2i] = _cells_of(b)
	if cells.is_empty():
		return
	link.set_facing(id, rot)
	world.remove_entity(id)
	e.rot = rot
	e.cell = _entity_origin(e.def, cells, rot, b.get("cell"))
	e.cells = cells
	e.pair_id = -1
	e.is_entrance = true
	e.seg_id = -1
	world.add_entity(e)


func _release(id: int) -> void:
	_reserve_cache.erase(id)
	var e: LogiEntity = world.entities.get(id)
	if e != null:
		# What was riding on that tile goes back to the city, not into the void.
		# [P11] refunds the belt; nobody refunds the coal that was on it.
		if e.is_transport():
			_return_stock(world.take_items_on(e.cell, e.is_underground()))
		if e.store != null and not e.store.is_empty():
			var back: Dictionary[StringName, int] = {}
			for k: StringName in e.store.kinds():
				back[k] = e.store.count(k)
			_return_stock(back)
			e.store.clear()
		world.remove_entity(id)
		_removed_total += 1
		_adopted_transport.erase(id)
	link.forget(id)
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
	# [P02] pulls on its own schedule as well as being pushed by _serve_fuel.
	# The interlock has to hold on both doors or a cut belt is still covered.
	if _line_fed.has(building_id):
		return 0.0
	_ensure_adopted(building_id)
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
	_ensure_adopted(building_id)
	var cell: Vector2i = world.store_origin.get(building_id, _cell_of(building_id))
	var got: int = haul.serve(world, _stock(), building_id, cell, item, amount)
	if got <= 0:
		return 0
	var st: LogiStore = store_of(building_id)
	if st == null:
		return got
	var placed: int = st.insert(item, got)
	if placed < got:
		_return_items(cell, item, got - placed)
	return placed


## [P04] offering a finished craft to the transport layer. Returns how much
## [P03] took; whatever is left over production hands to the city stores exactly
## as it always did, so this can never lose a plate.
##
## THE INTERLOCK THIS CLOSES, AND WHY IT WAS WORTH FINDING. `offer_input()` and
## `take_output()` have been sitting on ProductionSystem since the first wave
## with "[P03] logistics hands items to a machine's input buffer" written over
## them, and NOTHING IN THIS FOLDER EVER CALLED THEM. `_has_accept_output` in
## game/sim/production/production_system.gd resolved to false in every run this
## project has ever made, so every machine took its ingredients out of the city
## stockpile and put its output back into it — at unlimited range, at no cost, in
## the same tick. Coal was the only thing on a belt in the reference run because
## a burner's bunker is the one destination in the game that was actually wired
## up. The factory could not be belt-fed because there was nothing to belt to.
##
## IT IS OPT-IN BY CONSTRUCTION AND THAT IS THE DESIGN, NOT A HEDGE. A machine
## only hands its goods over while an ARM IS STANDING ON IT (see
## [method LogiWorld.arm_drained_stores]) — the same rule as
## `_line_fed`, which stands the porters down for a burner an arm is loading. A
## city that has built no arms behaves to the item exactly as it did before this
## function existed, which is what makes it safe to turn on under a run everyone
## else screenshots against; a city that has built one gets its plate on a belt.
func accept_output(building_id: int, item: StringName, amount: int) -> int:
	if amount <= 0 or String(item) == "":
		return 0
	# Deliberately NOT refreshing the index here. [P04] calls this from inside
	# its own step, which runs after ours in the same tick, so recomputing on
	# demand moved WHEN _line_fed was rebuilt and with it when the porters stood
	# down for a belt-fed burner: measured, it changed `crafts` 235 -> 247 on a
	# reference run where not one arm touches a machine. A read-only accessor
	# that quietly reschedules another system's cadence is not read-only.
	if not _arm_drained.has(building_id):
		return 0
	var st: LogiStore = store_of(building_id)
	if st == null:
		return 0
	var n: int = st.insert(item, amount)
	if n > 0:
		world.machine_taken += n
	return n


## [P03] putting an ingredient into a machine's mouth. Bound onto
## [member LogiWorld.machine_input] so a belt or an arm delivering onto a
## machine's footprint feeds the recipe instead of filling a shelf nobody reads.
func _offer_to_machine(building_id: int, item: StringName, amount: int) -> int:
	if _production == null or amount <= 0:
		return 0
	return int(_production.call("offer_input", building_id, item, amount))


## A building's own item buffer, or null. [P04] production reads and writes this
## one object rather than inventing a second inventory.
func store_of(building_id: int) -> LogiStore:
	_ensure_adopted(building_id)
	return world.stores.get(building_id)


## The sweep of [P11]'s buildings runs twice a second, not every tick, because
## walking seventeen hundred of them to find one new chest is most of what this
## system would cost. Anybody who ASKS about a building gets it adopted right
## then, so the delay is never visible through the API — only to the sweep.
func _ensure_adopted(building_id: int) -> void:
	# ONLY inside the simulation. A read from the view layer must never be able
	# to change when a building joins the logistics world, or a rendered run
	# would drift away from the headless replay of the same seed — which is the
	# one property this project refuses to lose.
	if not _in_sim or building_id < 0 or _adopted.has(building_id) or _not_ours.has(building_id):
		return
	var b: Object = _building(building_id)
	if b == null or not b.has_method("is_complete") or not bool(b.call("is_complete")):
		return
	_adopt(b, building_id)


## Puts what a machine produced into its own buffer. Returns what fit.
func deposit(building_id: int, item: StringName, amount: int) -> int:
	var st: LogiStore = store_of(building_id)
	if st == null:
		return 0
	var n: int = st.insert(item, amount)
	if n > 0:
		Bus.item_produced.emit(item, n)
	return n


## Takes ingredients out of a machine's buffer. Returns what was there.
func withdraw(building_id: int, item: StringName, amount: int) -> int:
	var st: LogiStore = store_of(building_id)
	return 0 if st == null else st.take(item, amount)


## What a building is holding, item id -> count.
func contents_of(building_id: int) -> Dictionary[StringName, int]:
	var out: Dictionary[StringName, int] = {}
	var st: LogiStore = store_of(building_id)
	if st == null:
		return out
	for k: StringName in st.kinds():
		out[k] = st.count(k)
	return out


## Asks the city to keep `amount` of `item` in this building.
func set_request(building_id: int, item: StringName, amount: int) -> bool:
	var st: LogiStore = store_of(building_id)
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
		"fuel_by_porter": haul.fuel_total,
		"fuel_by_machine": world.fuel_by_arm,
		"fuel_delivered": int(world.delivered_as_fuel),
		"delivered_by_arm": world.delivered_by_arm,
		"items_moved_total": _items_moved_total,
		"placed_by_player": _adopted_transport.size(),
		"line_fed_burners": _line_fed.size(),
		"belt_fed_machines": _arm_drained.size(),
		"machine_fed": world.machine_fed,
		"machine_taken": world.machine_taken,
		"lines_dry": _line_dry,
		"lines_to_nowhere": _lines_to_nowhere,
		"arms_no_target": _arms_no_target,
		"stock_out_of_range": haul.stock_out_of_range,
		"runs_dragged": link.runs_resolved,
		"corners_turned": link.corners_turned,
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
			return {"ok": false, "reason": "Something of yours is already at (%d, %d)." % [c.x, c.y],
				"cells": cells}
		if not _ground_free(c):
			return {"ok": false, "reason": "The ground at (%d, %d) will not take it." % [c.x, c.y],
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
	_in_sim = true
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
	_in_sim = false


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


## Named series for metrics.csv, the gate contract and [P20]. Counters are
## cumulative for the run; levels describe this instant.
##
## `items_moved` is CUMULATIVE, and that is the whole point of it. It used to
## publish [member LogiWorld.items_moved], which [method LogiWorld.step] zeroes
## at the top of every tick — so the series was a one-tick delta wearing the name
## of a counter. Everything downstream reads it as a total: the gate bands it
## `final_min 1` ("a reference day in which the pillar moves not one item"),
## [P20] declares it `Kind.COUNTER` and the night report takes a `_delta()` of
## two samples of it. A one-tick delta makes all three lie — the band asks
## whether an item happened to move on tick 11000 exactly, and a healthy belt
## that is momentarily backed up answers no. The instantaneous reading anyone
## wants is `throughput`; the raw per-tick count is still here as
## `items_moved_tick` for anything that genuinely needs the delta.
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
		"items_moved": _items_moved_total,
		"items_moved_tick": world.items_moved,
		"items_moved_total": _items_moved_total,
		"hauled_total": haul.hauled_total,
		"fuel_by_porter": haul.fuel_total,
		"fuel_by_machine": world.fuel_by_arm,
		"fuel_delivered": int(world.delivered_as_fuel),
		"delivered_by_arm": world.delivered_by_arm,
		"haul_capacity": snappedf(haul.capacity(), 0.01),
		"burners_short": _fuel_short,
		"lines_dry": _line_dry,
		"lines_to_nowhere": _lines_to_nowhere,
		"arms_no_target": _arms_no_target,
		"stock_out_of_range": haul.stock_out_of_range,
		"line_fed_burners": _line_fed.size(),
		"belt_fed_machines": _arm_drained.size(),
		"machine_fed": world.machine_fed,
		"machine_taken": world.machine_taken,
		"placed_by_player": _adopted_transport.size(),
		"runs_dragged": link.runs_resolved,
		"corners_turned": link.corners_turned,
		"porters": haul.porters,
		"spilled": world.spilled,
	}
