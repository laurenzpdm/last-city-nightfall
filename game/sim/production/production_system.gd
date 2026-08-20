class_name ProductionSystem
extends SimSystem
## [P04] Production & Recipes — the factory half of the game.
##
## Machines pull items, spend time, emit items, and — the part that makes this a
## city builder and not a spreadsheet — they only do it while they are WARM and
## while the grid is feeding them. Every machine that is not moving carries a
## written reason, so a stalled base is a base the player can read.
##
## What this system owns:
##   * the RECIPE GRAPH, loaded from game/content/recipes/ ([ProdRecipeBook]),
##     including the computed chain depth [P18] lays its tree out on
##   * every MACHINE: recipe choice, input and output buffers, progress, and the
##     stall reason it announces on Bus.machine_stalled ([ProdMachine])
##   * EXTRACTION: a drill works the seam under it, a salvage crew walks to one,
##     and a worked-out deposit stalls with &"depleted"
##   * the HEAT-RECOVERY LOOP ([ProdWasteHeat]): smelters throw off recoverable
##     waste, a recuperator standing close enough turns it back into grid heat
##   * FUEL for [P02]'s burners — the moment this system exists, heat stops
##     running on faith and starts asking for coal
##
## Nothing here knows the name of a single building or recipe. A .tres with
## `recipes` or `extracts` is a machine; a .tres in content/recipes is a recipe.
##
## ─────────────────────────────────────────────────────────────────────────────
## THE CHAIN — ratios at craft speed 1.0, full heat, full warmth. A balance
## agent tunes the .tres; these are the numbers they were tuned TO, so a change
## that breaks a clean ratio is visible as a change to this table.
## `ProdRecipeBook.describe_ratios()` regenerates it from the live content.
##
##  TIER 0  extraction        ore_drill 0.80 /s on any seam · scrap_collector 0.55 /s
##
##  TIER 1  smelter
##    iron_plate    2 iron_ore            -> 1 iron_plate + 1 slag     50t   0.40/s
##    copper_coil   1 copper_ore          -> 2 copper_coil             25t   1.60/s
##    steel_plate   2 iron_plate + 1 coal -> 1 steel_plate            100t   0.20/s
##
##  TIER 1  rubble_sorter
##    sorted_rubble 4 scrap    -> 2 stone + 1 timber + 1 iron_ore     100t
##    salvaged_stores 6 scrap  -> 2 grain + 1 timber                  200t
##    salvaged_wire 8 scrap    -> 2 copper_ore                        250t   0.16/s
##
##  WHY THE WIRE RECIPE EXISTS AND WHY ITS NUMBER IS BAD ON PURPOSE. Until it
##  landed, `copper_ore` was a RAW material — the only way to get any was a
##  drill standing on a copper field, and on the reference map the nearest one
##  is 37 tiles south-east of the wall. `copper_coil` feeds `pipe_segment` and
##  `circuit`, `heat_core` needs both, and a `warmth_radiator` costs coil to
##  place, so FOUR of the fourteen shipped recipes were unreachable by anyone
##  who had not first mounted an expedition, and the reference run reached chain
##  depth 2 against content that is five deep. Salvage closes the hole at
##  0.16 ore/s against a drill's 0.80: FIVE sorters to feed one copper smelter.
##  That ratio is the design. It is how a poor city gets its first coil, and it
##  is the tooltip telling the player, in numbers, to go and take the field.
##
##  TIER 2  workshop
##    gear          2 iron_plate                    -> 1 gear         100t   0.20/s
##    insulation    2 slag + 1 timber               -> 2 insulation   100t   0.40/s
##    pipe_segment  1 steel_plate + 1 copper_coil   -> 2 pipe_segment 100t   0.40/s
##    circuit       3 copper_coil + 1 iron_plate    -> 2 circuit      200t   0.20/s
##
##  TIER 3  workshop / assembly_hall
##    ammo_shell    1 steel_plate + 1 gear + 2 sulfur -> 4 ammo_shell 200t   0.40/s
##
##  TIER 4  assembly_hall
##    heat_core     2 pipe_segment + 1 circuit + 2 insulation -> 1 heat_core 200t 0.10/s
##
##  THE CLEAN RATIOS the player is rewarded for finding — all exactly 1:1:
##    1 drill on iron      feeds 1 smelter on iron_plate     (0.80 ore/s)
##    1 drill on copper    feeds 1 smelter on copper_coil    (0.80 ore/s)
##    1 iron smelter       feeds 1 steel smelter             (0.40 plate/s)
##    1 iron smelter       feeds 1 workshop on gear          (0.40 plate/s)
##    1 iron smelter's SLAG feeds 1 workshop on insulation   (0.40 slag/s)
##    1 steel smelter      feeds 1 workshop on pipe_segment  (0.20 steel/s)
##  and the one deliberate 2:1, so the top of the tree is not free:
##    1 pipe + 1 circuit + 1 insulation workshop feeds 2 assembly halls
##
##  The slag line is the design's centrepiece: iron smelting cannot be run
##  without producing slag, and slag has exactly one use, at exactly the rate
##  one smelter makes it. A player who lays out 1 drill : 1 smelter : 1 gear
##  shop : 1 insulation shop has a block that consumes nothing it does not use.
## ─────────────────────────────────────────────────────────────────────────────

const SYSTEM_ORDER: int = 40          ## after logistics (30), before citizens (50)

# --- cold coupling --------------------------------------------------------
## Degrees a fully sealed shell adds to what the machine feels inside. A machine
## at insulation 0.35 works as if it stood 10.5 C warmer than the tile it is on.
const SHELTER_C: float = 30.0
## Degrees above a recipe's floor at which it reaches full speed. Inside the band
## it runs proportionally — cold is a slope, not a switch.
const COLD_BAND_C: float = 14.0
## Fallback outdoor temperature when neither [P09] nor [P02] exists.
const DEFAULT_AMBIENT_C: float = -18.0

# --- pacing ---------------------------------------------------------------
## Ticks between rescans of [P11]'s building list. A machine coming online half
## a second late is imperceptible; walking a thousand buildings every tick is
## not — that walk is the single largest cost this system has on a big base.
const SYNC_EVERY: int = 10
## Ticks between attempts to find a fresh seam for an extractor that lost one.
## A ring search is the most expensive thing this system can do; it happens at
## most five times a minute per idle drill.
const SEAM_SEARCH_EVERY: int = 200
## Ticks between rate-window rotations. Two windows are kept, so the reported
## per-minute figure always looks back over 30 to 60 seconds of real production.
const RATE_WINDOW_TICKS: int = 600
## Ticks between re-reading research gates.
const UNLOCK_RECHECK_TICKS: int = 200
## A stalled machine re-announces its reason this often, so a UI that connected
## late still learns why the smelter is dark.
const STALL_REANNOUNCE_TICKS: int = 100
## Ticks between prunes of the "this building is not a machine" cache. It only
## ever grows by one entry per building the city has ever finished, so once a
## minute is generous.
const NOT_OURS_PRUNE_TICKS: int = 1200
## Below this the machine is treated as stopped rather than crawling.
const MIN_RATE: float = 0.01
## How long a shop keeps working on what is already on the bench after its last
## hand walks out. Forty-five seconds at 20 Hz. See `_crew_of`.
const STAFF_COAST_TICKS: int = 900
## Cap on the per-item rate columns in metrics.csv.
const MAX_RATE_KEYS: int = 32
## Fraction of an input buffer a machine keeps topped up from the city store.
const REFILL_TARGET: float = 0.5
## Input sets a machine will hold at most, so one smelter cannot hoard the ore
## of ten. Buffer capacity still applies on top.
const REFILL_SETS: int = 8

## Grid.Res index -> the item that deposit yields. Index 6 (a geothermal vent)
## is not minable: it is [P02]'s to stand a tap on.
const ORE_ITEMS: Array[StringName] = [
	&"", &"scrap", &"coal", &"iron_ore", &"copper_ore", &"sulfur", &"",
]

var machines: Dictionary[int, ProdMachine] = {}
var book: ProdRecipeBook = null
var store: ProdStore = null
var waste: ProdWasteHeat = null

var _defs: Dictionary[StringName, ProdMachineDef] = {}
## Building kinds with no production behaviour. Same perf contract as [HeatDef]'s
## negative cache: without it every wall on the map is re-reflected every sync.
var _not_machines: Dictionary[StringName, bool] = {}
## Building ids [P11] owns that are not machines, so a rescan can skip them.
var _not_ours: Dictionary[int, bool] = {}
var _order: PackedInt32Array = PackedInt32Array()
var _order_dirty: bool = true

var _build: SimSystem = null
var _heat: SimSystem = null
var _grid: SimSystem = null
var _citizens: SimSystem = null
var _climate: SimSystem = null
var _logistics: SimSystem = null
## [P10]. Null in a build without research; then both stay 1.0.
var _research: SimSystem = null
var _tech_craft: float = 1.0
var _tech_yield: float = 1.0

var _has_temperature: bool = false
var _has_power: bool = false
var _has_served: bool = false
var _has_frozen: bool = false
var _has_ambient: bool = false
var _has_harvest: bool = false
var _has_deliver_fuel: bool = false
var _has_accept_output: bool = false
var _has_staffing_of: bool = false
## Nobody assigns crews yet, so machines run themselves. The moment [P05] lands,
## staffing is real. Mirrors [P02]'s fuel autarky, for the same reason.
var _staff_autarky: bool = true
var _heat_autarky: bool = true

var _last_sync_tick: int = -1000
var _not_ours_pruned: int = 0
## Bound once. Building it inside step() allocated a Callable every tick.
var _deliver_waste_cb: Callable = Callable()
var _unlock_cache: Dictionary[StringName, bool] = {}
var _unlock_checked: int = -1000

# --- rate window ----------------------------------------------------------
var _produced_total: Dictionary[StringName, int] = {}
var _mark_prev: Dictionary[StringName, int] = {}
var _mark_cur: Dictionary[StringName, int] = {}
var _mark_prev_tick: int = 0
var _mark_cur_tick: int = 0
var _rate_keys: Array[StringName] = []

# --- totals ---------------------------------------------------------------
var _active: int = 0
var _stalled: int = 0
var _idle: int = 0
## Stalls split by cause, recounted every tick alongside `_stalled`.
var _stalled_unstaffed: int = 0
var _stalled_cold: int = 0
var _stalled_starved: int = 0
var _crafts_total: int = 0
var _fuel_served: float = 0.0
var _fuel_denied: float = 0.0
var _tick: int = 0


func _init() -> void:
	order = SYSTEM_ORDER


func system_name() -> StringName:
	return &"production"


# ------------------------------------------------------------- lifecycle ----

func setup() -> void:
	order = SYSTEM_ORDER
	machines = {}
	_defs = {}
	_not_machines = {}
	_not_ours = {}
	_order = PackedInt32Array()
	_order_dirty = true
	_produced_total = {}
	_mark_prev = {}
	_mark_cur = {}
	_mark_prev_tick = 0
	_mark_cur_tick = 0
	_unlock_cache = {}
	_unlock_checked = -1000
	_last_sync_tick = -1000
	_crafts_total = 0
	_fuel_served = 0.0
	_fuel_denied = 0.0
	_tick = 0

	book = ProdRecipeBook.new()
	book.load_all()
	store = ProdStore.new()
	waste = ProdWasteHeat.new()

	for problem: String in book.problems:
		Log.warn("production", "recipe %s" % problem)

	_rate_keys = []
	for item: StringName in book.items:
		if _rate_keys.size() >= MAX_RATE_KEYS:
			break
		_rate_keys.append(item)


func post_setup() -> void:
	_build = Sim.get_system(&"build")
	_heat = Sim.get_system(&"heat")
	_grid = Sim.get_system(&"grid")
	_citizens = Sim.get_system(&"citizens")
	_climate = Sim.get_system(&"climate")
	_logistics = Sim.get_system(&"logistics")

	store.bind(_build)
	_deliver_waste_cb = Callable(self, "_deliver_waste")
	_has_temperature = _heat != null and _heat.has_method("temperature_at")
	_has_power = _heat != null and _heat.has_method("power_factor")
	_has_served = _heat != null and _heat.has_method("served_of")
	_has_frozen = _heat != null and _heat.has_method("is_frozen")
	_has_deliver_fuel = _heat != null and _heat.has_method("deliver_fuel")
	_has_ambient = _climate != null and _climate.has_method("ambient_temperature")
	_has_harvest = _grid != null and _grid.has_method("harvest")
	_has_accept_output = _logistics != null and _logistics.has_method("accept_output")
	_has_staffing_of = _citizens != null and _citizens.has_method("staffing_of")
	_staff_autarky = _citizens == null
	_heat_autarky = _heat == null
	_research = Sim.get_system(&"research")
	if _research != null and not _research.has_method("multiplier"):
		_research = null

	_load_defs()
	Log.info("production", "ready — %d recipes (depth %d), %d machine definitions, store '%s', heat=%s grid=%s staffing=%s" % [
		book.size(), book.max_depth, _defs.size(), String(store.backing()),
		"metered" if not _heat_autarky else "absent",
		"yes" if _has_harvest else "no",
		"autarky" if _staff_autarky else "crewed"])


func step(tick: int) -> void:
	_tick = tick
	_sync_from_build(tick)
	if tick - _unlock_checked >= UNLOCK_RECHECK_TICKS:
		_unlock_checked = tick
		_unlock_cache.clear()
		_read_tech()

	_active = 0
	_stalled = 0
	_idle = 0
	_stalled_unstaffed = 0
	_stalled_cold = 0
	_stalled_starved = 0
	var ids: PackedInt32Array = _sorted_ids()
	for id: int in ids:
		_advance(machines[id], tick)

	waste.relink(ids, machines)
	waste.distribute(ids, machines, SimClock.DT, _deliver_waste_cb)
	_roll_rates(tick)


# =========================================================================
# public API — everything another part is allowed to touch
# =========================================================================

## [P02] heat asks for fuel here every half second for any burner below half a
## tank. Returns how much was actually handed over, so the bunker knows what it
## got. This is the call that turns "heat runs on faith" into "heat runs on coal".
func request_fuel(building_id: int, item: StringName, amount: float) -> float:
	if amount <= 0.0 or String(item) == "":
		return 0.0
	if item == &"waste_heat":
		# Not an item and never in the stores: recovered heat only ever arrives
		# by push from the recovery loop, so a recuperator asking is answered no.
		return 0.0
	var want: int = int(floor(amount))
	if want <= 0:
		return 0.0
	# A machine standing on the seam feeds a neighbour first: a coal drill next
	# to a generator is a supply line, not a coincidence.
	var got: int = _take_from_machines(item, want)
	if got < want:
		got += store.take_up_to(item, want - got)
	if got <= 0:
		_fuel_denied += float(want)
		return 0.0
	_fuel_served += float(got)
	return float(got)


## [P03] logistics hands items to a machine's input buffer. Returns how much the
## machine took, so a belt knows what to keep carrying.
func offer_input(building_id: int, item: StringName, amount: int) -> int:
	var m: ProdMachine = machines.get(building_id)
	if m == null or amount <= 0:
		return 0
	if m.recipe != null and not m.recipe.inputs.has(item):
		return 0
	var take: int = mini(amount, m.input_room())
	if take <= 0:
		return 0
	m.add_input(item, take)
	return take


## [P03] logistics drains a machine's output buffer. Returns what it got.
func take_output(building_id: int, item: StringName, amount: int) -> int:
	var m: ProdMachine = machines.get(building_id)
	if m == null:
		return 0
	return m.take_output(item, amount)


## Chosen recipe of a machine, or empty. [P17]/[P18]/[P19] read this.
func recipe_of(building_id: int) -> StringName:
	var m: ProdMachine = machines.get(building_id)
	return m.recipe_id if m != null else &""


## Sets a machine's recipe. Returns false when the machine or the recipe does not
## exist, or when this machine cannot run it. Clears the current craft, because
## half a gear is not half a circuit.
func set_recipe(building_id: int, rid: StringName) -> bool:
	var m: ProdMachine = machines.get(building_id)
	if m == null:
		return false
	if String(rid) == "":
		_assign(m, &"")
		return true
	var r: RecipeDef = book.get_recipe(rid)
	if r == null or not r.runs_on(m.kind, m.def.tags):
		return false
	_assign(m, rid)
	return true


## A recipe named on a cell that holds a CONSTRUCTION SITE rather than a
## finished machine. Returns true when the order was taken.
##
## Both halves of this already existed and nothing joined them: `_pick_recipe()`
## reads a recipe out of the building's `meta` the instant the machine
## registers, and `_write_meta_recipe()` puts one there — but only ever for a
## machine that was already standing. So naming a recipe was legal exactly and
## only in the window between "the site finished" and "the player wanted it",
## and the caller had to guess build time to hit that window.
##
## THE MEASUREMENT. tests/scenarios/first_night.json places a rubble_sorter at
## t=3200 and names `salvaged_stores` on it at t=4650, with a comment explaining
## that a site is not a machine yet. The site did not complete until t=9471 —
## the guess was 4821 ticks short — so the order was refused with a Log.warn
## nobody read, the sorter came up on its default recipe, the field kitchen sat
## at `missing_input: grain` for the whole run, and the interlock ARCHITECTURE.md
## §7 lists as LIVE ("scrap becomes grain becomes a meal") produced no rations in
## the reference run of this game. The city ate its founders' larder and starved.
##
## A standing order removes the guess: name it whenever you like, and the machine
## is born running it.
func _standing_order(cmd: Dictionary, rid: StringName) -> bool:
	if _build == null or not cmd.has("cell"):
		return false
	var site: Object = _build.call("building_at", _to_cell(cmd["cell"]))
	if site == null:
		return false
	var kind: StringName = StringName(String(site.get("kind")))
	var def: ProdMachineDef = _def_for(kind)
	if def == null:
		return false
	if String(rid) != "":
		var r: RecipeDef = book.get_recipe(rid)
		if r == null or not r.runs_on(kind, def.tags):
			Log.warn("production", "set_recipe: a %s cannot run '%s'" % [
				String(kind), String(rid)])
			return true
	_write_meta_recipe(int(site.get("id")), rid)
	Log.info("production", "standing order: the %s being built at %s will run '%s'" % [
		String(kind), str(_to_cell(cmd["cell"])), String(rid)])
	return true


## Recipes this machine is allowed to run, in menu order. [P18]'s browser.
func recipes_for(building_id: int) -> Array[StringName]:
	var m: ProdMachine = machines.get(building_id)
	if m == null:
		return []
	return book.for_machine(m.kind, m.def.tags, m.def.recipes)


## ProdMachine.State for a building, or IDLE when it is not a machine.
func state_of(building_id: int) -> int:
	var m: ProdMachine = machines.get(building_id)
	return m.state if m != null else ProdMachine.State.IDLE


## Why this machine is not moving: {reason, item, recipe, rate, power, cold,
## heat_factor, staffing, felt_c}. Empty reason means it is running.
## This is [P19]'s whole contract for the production overlay.
func stall_of(building_id: int) -> Dictionary:
	var m: ProdMachine = machines.get(building_id)
	if m == null:
		return {}
	return {
		"reason": String(m.reason),
		"item": String(m.reason_item),
		"recipe": String(m.recipe_id),
		"state": m.state,
		"rate": snappedf(m.rate, 0.0001),
		"power": snappedf(m.power, 0.0001),
		"cold": snappedf(m.cold, 0.0001),
		"heat_factor": snappedf(m.heat_factor, 0.0001),
		"staffing": snappedf(m.staffing, 0.0001),
		"bench": snappedf(m.bench, 0.0001),
		"felt_c": snappedf(m.felt_c, 0.01),
		"progress": snappedf(m.progress_ratio(), 0.001),
	}


## Every machine that is not doing its job, worst first (a hard stall before an
## idle switch), each with the reason and the numbers behind it. This is the
## whole list [P19]'s production overlay draws and [P17]'s alert row counts —
## one call, no walking of private state.
func stalled_machines() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id: int in _sorted_ids():
		var m: ProdMachine = machines[id]
		if m.reason == ProdMachine.REASON_NONE:
			continue
		var entry: Dictionary = stall_of(id)
		entry["id"] = id
		entry["kind"] = String(m.kind)
		entry["cell"] = [m.cell.x, m.cell.y]
		entry["pos"] = [m.world_pos.x, m.world_pos.y]
		out.append(entry)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var sa: int = _severity(StringName(String(a["reason"])))
		var sb: int = _severity(StringName(String(b["reason"])))
		if sa != sb:
			return sa > sb
		return int(a["id"]) < int(b["id"]))
	return out


## How loudly a stall should shout. A machine the player switched off is not a
## problem; a frozen one is the city dying.
func _severity(reason: StringName) -> int:
	match reason:
		ProdMachine.REASON_FROZEN:
			return 5
		ProdMachine.REASON_NO_HEAT, ProdMachine.REASON_TOO_COLD:
			return 4
		ProdMachine.REASON_DEPLETED:
			return 3
		ProdMachine.REASON_MISSING_INPUT, ProdMachine.REASON_OUTPUT_FULL:
			return 2
		ProdMachine.REASON_UNSTAFFED, ProdMachine.REASON_LOCKED, ProdMachine.REASON_NO_RECIPE:
			return 1
		_:
			return 0


func has_machine(building_id: int) -> bool:
	return machines.has(building_id)


func machine_count() -> int:
	return machines.size()


func machine_ids() -> PackedInt32Array:
	return _sorted_ids()


## Units of `item` the city has produced in the last 30 to 60 seconds, per
## minute. The number [P20]'s graphs and the HUD's throughput row read.
func items_per_minute(item: StringName) -> float:
	var window: float = float(maxi(1, _tick - _mark_prev_tick)) * SimClock.DT
	if window < 1.0:
		return 0.0
	var made: int = int(_produced_total.get(item, 0)) - int(_mark_prev.get(item, 0))
	return float(made) * 60.0 / window


## Lifetime units of `item` this city has made.
func produced_total(item: StringName) -> int:
	return int(_produced_total.get(item, 0))


## How many transformations deep the city has actually got. Raw ore is 0, a
## plate 1, a gear 2, a shell 3 — a single honest number for progression.
func chain_depth_reached() -> int:
	var best: int = 0
	for item: StringName in book.items:
		if int(_produced_total.get(item, 0)) > 0:
			best = maxi(best, book.item_depth(item))
	return best


## Deepest chain the shipped content can reach at all.
func chain_depth_max() -> int:
	return book.max_depth


## Recoverable heat per second currently being fed back into [P02]'s grid.
func waste_recovered() -> float:
	return waste.recovered_rate


## The back-pressure hook. [P03] closes this when the belts and the yards are
## genuinely full; every machine then fills its output buffer and stalls with
## REASON_OUTPUT_FULL, which is exactly what a jammed factory should look like.
func set_output_accepting(on: bool) -> void:
	store.accepting = on


## Runs every machine fully crewed, ignoring [P05]'s labour market. Set
## automatically while no citizens system exists — the same idea as [P02]'s fuel
## autarky, and for the same reason: a half-built dependency must not make this
## system look dead. A suite that means to measure PRODUCTION rather than the job
## board turns it on explicitly; play never does.
func set_staffing_autarky(on: bool) -> void:
	_staff_autarky = on


func staffing_autarky() -> bool:
	return _staff_autarky


## City-wide production totals, the same numbers metrics() reports.
func totals() -> Dictionary:
	return {
		"machines": machines.size(),
		"active": _active,
		"stalled": _stalled,
		"idle": _idle,
		"crafts": _crafts_total,
		"recipes": book.size(),
		"chain_depth": chain_depth_reached(),
		"chain_depth_max": book.max_depth,
		"waste_recovered": snappedf(waste.recovered_rate, 0.001),
		"waste_vented": snappedf(waste.vented_rate, 0.001),
		"fuel_served": snappedf(_fuel_served, 0.001),
	}


## The recipe graph as data, for [P18]'s browser and for a balance report.
func recipe_tree() -> Dictionary:
	return book.to_json()


## Regenerated ratio table. A balance agent diffs this text across builds.
func ratio_report() -> PackedStringArray:
	return book.describe_ratios()


# ------------------------------------------------------------- commands ----

func handle_command(cmd: Dictionary) -> void:
	var op: String = String(cmd.get("op", ""))
	match op:
		"set_recipe":
			var id: int = _target_id(cmd)
			var rid: StringName = StringName(String(cmd.get("recipe", "")))
			if id < 0:
				if not _standing_order(cmd, rid):
					Log.warn("production", "set_recipe: no machine at %s" % str(cmd.get("cell", cmd.get("id", "?"))))
			elif not set_recipe(id, rid):
				Log.warn("production", "set_recipe: #%d cannot run '%s'" % [id, String(rid)])
		"clear_recipe":
			var cid: int = _target_id(cmd)
			if cid >= 0:
				set_recipe(cid, &"")
		"set_staffing_autarky":
			set_staffing_autarky(bool(cmd.get("on", true)))
		"set_output_accepting":
			set_output_accepting(bool(cmd.get("on", true)))
		"dump":
			_dump()
		"ratios":
			for line: String in book.describe_ratios():
				Log.info("production", line)
		_:
			Log.warn("production", "unknown op '%s'" % op)


# =========================================================================
# the tick
# =========================================================================

## One machine, one tick. The order is the order a player would check in: is it
## switched on, does it have something to make, can it make it, is it warm
## enough, is the grid feeding it — and only then, does it move.
func _advance(m: ProdMachine, tick: int) -> void:
	m.rate = 0.0

	if not m.enabled:
		_park(m, ProdMachine.State.IDLE, ProdMachine.REASON_DISABLED, &"", tick)
		return

	# Read the world BEFORE the frozen check, so a frozen machine still reports a
	# live temperature and the overlay can show it thawing rather than stuck on
	# whatever it happened to feel the moment it died.
	_read_environment(m, tick)
	if _is_frozen(m.id):
		_park(m, ProdMachine.State.FROZEN, ProdMachine.REASON_FROZEN, &"", tick)
		return

	if m.def.is_recuperator() and not m.def.is_crafter() and not m.def.is_extractor():
		# A recuperator does no work of its own; [ProdWasteHeat] drives it below,
		# which is why what it reports here is last tick's intake. One tick of lag
		# on a status light is invisible; reordering the tick to remove it would
		# cost a second pass over every machine.
		if m.waste_taken > 0.0:
			m.state = ProdMachine.State.RUNNING
			m.reason = ProdMachine.REASON_NONE
			m.reason_item = &""
			m.rate = 1.0
			_active += 1
		else:
			_park(m, ProdMachine.State.STALLED, ProdMachine.REASON_MISSING_INPUT, &"waste_heat", tick)
		return

	if m.bench <= 0.0:
		_park(m, ProdMachine.State.STALLED, ProdMachine.REASON_UNSTAFFED, &"", tick)
		return

	if m.def.is_extractor():
		_extract(m, tick)
		return
	_craft(m, tick)


## A crafter: choose, feed, warm up, work, deliver.
func _craft(m: ProdMachine, tick: int) -> void:
	if m.recipe == null:
		_pick_recipe(m)
	if m.recipe == null:
		_park(m, ProdMachine.State.IDLE, ProdMachine.REASON_NO_RECIPE, &"", tick)
		return
	if not _is_unlocked(m.recipe.unlock_id):
		_park(m, ProdMachine.State.STALLED, ProdMachine.REASON_LOCKED, m.recipe_id, tick)
		return

	var r: RecipeDef = m.recipe
	# The cold and the grid are checked BEFORE anything is consumed: a furnace
	# that ate its charge and then discovered it had no heat is a furnace that
	# threw the charge away.
	var rate: float = _work_rate(m, r)
	if rate < MIN_RATE:
		_park(m, ProdMachine.State.STALLED, _cold_or_dark(m), &"", tick)
		return

	if not m.committed:
		# Nothing is consumed until a whole craft can start AND its result will
		# fit. That is what makes "output_full" a real, recoverable state rather
		# than a machine that ate its inputs and threw them away.
		var out_size: int = m.output_size
		if m.output_room() < out_size:
			_flush_outputs(m)
			if m.output_room() < out_size:
				_park(m, ProdMachine.State.STALLED, ProdMachine.REASON_OUTPUT_FULL, &"", tick)
				return
		if not m.has_all_inputs():
			_refill(m)
		if not m.has_all_inputs():
			_park(m, ProdMachine.State.STALLED, ProdMachine.REASON_MISSING_INPUT,
				m.first_missing_input(), tick)
			return
		m.consume_inputs()
		m.committed = true
		m.progress = 0.0

	m.rate = rate
	m.state = ProdMachine.State.RUNNING
	m.reason = ProdMachine.REASON_NONE
	m.reason_item = &""
	_active += 1
	m.progress += rate

	if r.waste_heat > 0.0:
		waste.bank(m, r.waste_heat * rate / float(maxi(1, r.time_ticks)))

	if m.progress < float(r.time_ticks):
		return

	m.progress -= float(r.time_ticks)
	m.committed = false
	m.crafts_done += 1
	_crafts_total += 1
	for item: StringName in r.sorted_outputs():
		_produce(m, item, r.outputs[item])
	for b: StringName in r.sorted_byproducts():
		_produce(m, b, r.byproducts[b])
	_flush_outputs(m)
	# Top the input buffer back up in the same tick so a well-fed machine never
	# shows a one-tick "missing input" flicker between crafts.
	_refill(m)


## An extractor: work a seam, and say so when the seam is gone.
func _extract(m: ProdMachine, tick: int) -> void:
	if m.seam.x < 0 or not _seam_alive(m):
		if not _acquire_seam(m, tick):
			_park(m, ProdMachine.State.STALLED, ProdMachine.REASON_DEPLETED, &"", tick)
			return

	var rate: float = _work_rate(m, null)
	if rate < MIN_RATE:
		_park(m, ProdMachine.State.STALLED, _cold_or_dark(m), &"", tick)
		return
	if m.output_room() <= 0:
		_flush_outputs(m)
		if m.output_room() <= 0:
			_park(m, ProdMachine.State.STALLED, ProdMachine.REASON_OUTPUT_FULL, &"", tick)
			return

	m.rate = rate
	m.state = ProdMachine.State.RUNNING
	m.reason = ProdMachine.REASON_NONE
	m.reason_item = &""
	_active += 1

	m.extract_acc += m.def.extract_rate * m.def.craft_speed * _tech_yield * rate * SimClock.DT
	var whole: int = int(floor(m.extract_acc))
	if whole <= 0:
		return
	whole = mini(whole, m.output_room())
	if whole <= 0:
		return
	var taken: int = _harvest(m.seam, whole)
	if taken <= 0:
		# The seam ran out between ticks. Drop the fraction rather than banking a
		# unit that was never dug, and go looking for a new one next tick.
		m.extract_acc = 0.0
		return
	m.extract_acc -= float(taken)
	m.crafts_done += 1
	_produce(m, m.seam_item, taken)
	_flush_outputs(m)


## Every multiplier that decides how fast a machine moves this tick, and the one
## place that couples the factory to the weather and to the grid.
##
##   staffing  — a half-crewed shop runs at half speed ([P05])
##   power     — 0..1 of the heat it asked for and got ([P02])
##   cold      — how far above the recipe's freezing point the machine feels
##   heat      — whether the recipe's heat rate fits inside what the grid gives
## [P10]. Refreshed on the same slow timer as the unlock cache — a research node
## finishes once a minute at best, and this is read by every machine every tick.
func _read_tech() -> void:
	if _research == null:
		return
	var craft: Variant = _research.call("multiplier", ResearchDefs.E_CRAFT_SPEED_MULT)
	var yield_v: Variant = _research.call("multiplier", ResearchDefs.E_MINE_YIELD_MULT)
	if typeof(craft) == TYPE_FLOAT or typeof(craft) == TYPE_INT:
		_tech_craft = clampf(float(craft), 0.05, 20.0)
	if typeof(yield_v) == TYPE_FLOAT or typeof(yield_v) == TYPE_INT:
		_tech_yield = clampf(float(yield_v), 0.05, 20.0)


func _work_rate(m: ProdMachine, r: RecipeDef) -> float:
	var floor_c: float = r.min_temperature_c if r != null else -30.0
	m.cold = clampf((m.felt_c - floor_c) / COLD_BAND_C, 0.0, 1.0)

	# A machine that asks the grid for nothing cannot be browned out by it,
	# whatever its recipe costs — hand-work does not stop when the pipes do.
	m.heat_factor = 1.0
	if m.def.heat_rating <= 0.0:
		pass
	elif r != null and r.heat_cost > 0.0:
		var need: float = r.heat_rate()
		var have: float = m.def.heat_rating * m.power
		m.heat_factor = clampf(have / maxf(need, 0.0001), 0.0, 1.0)
	else:
		m.heat_factor = m.power

	return m.bench * m.cold * m.heat_factor * m.def.craft_speed * _tech_craft


## Which of the two soft failures actually stopped it — the player needs to know
## whether to run a pipe or to run a radiator.
func _cold_or_dark(m: ProdMachine) -> StringName:
	if m.cold <= m.heat_factor:
		return ProdMachine.REASON_TOO_COLD
	return ProdMachine.REASON_NO_HEAT


func _read_environment(m: ProdMachine, tick: int) -> void:
	if _heat_autarky:
		m.power = 1.0
	else:
		m.power = clampf(float(_heat.call("power_factor", m.id)), 0.0, 1.0) if _has_power else 1.0
		if m.def.heat_rating <= 0.0:
			m.power = 1.0
	var outside: float = _ambient()
	if _has_temperature:
		outside = float(_heat.call("temperature_at", m.center_cell))
	m.felt_c = outside + m.def.insulation * SHELTER_C
	m.staffing = 1.0
	m.bench = 1.0
	if not _staff_autarky and m.def.workers_required > 0:
		# TWO NUMBERS ON PURPOSE. `staffing` is [P05]'s answer, unsmoothed,
		# because it is the published one and another part is entitled to
		# compare it. `bench` is what this shop can get done, which is not zero
		# the instant its one hand walks to the larder.
		m.staffing = clampf(_staffing_of(m.id), 0.0, 1.0)
		m.bench = _crew_of(m, tick)


## Crew, read over a short window instead of this instant.
##
## [P05] reports crew PRESENT, which is the right number and a very twitchy one:
## a two-person shop whose second hand is on the night rotation reads 0 every
## time the remaining one walks to the larder, and a machine that stalls outright
## at `staffing <= 0` therefore spends a large part of its day announcing `no
## crew` about somebody who is coming back in four seconds. Measured on the
## reference run, `production.stalled_unstaffed` averaged 1.9 machines in the
## AFTERNOON, with the city's whole day crew on the clock.
##
## So a shop coasts: it keeps the crew it last had, ramped linearly to nothing
## across STAFF_COAST_TICKS, and then reports the truth. Twenty seconds of work
## already on the bench is a thing a workshop has; a night off is not, and after
## the window this says `unstaffed` exactly as loudly as it did before.
##
## This is `m.bench` and it is NOT `m.staffing`. Smoothing the published number
## would have made `production` quietly disagree with `citizens` about who is
## standing in a building, which is the kind of drift this project has paid for
## twice — so the two are separate fields and both are in the metrics dump.
func _crew_of(m: ProdMachine, tick: int) -> float:
	var raw: float = m.staffing
	if raw > 0.0:
		m.staff_held = raw
		m.staff_seen_tick = tick
		return raw
	var gone: int = tick - m.staff_seen_tick
	if gone >= STAFF_COAST_TICKS or m.staff_held <= 0.0:
		return 0.0
	return m.staff_held * (1.0 - float(gone) / float(STAFF_COAST_TICKS))


## [P05] publishes `staffing_of(id)` for exactly this call — crew PRESENT, not
## crew on the roster, so a shift that has walked home stops the machine.
## Falls back to [P11]'s worker count, and finally to "it runs itself".
func _staffing_of(building_id: int) -> float:
	if _has_staffing_of:
		return float(_citizens.call("staffing_of", building_id))
	if _build == null:
		return 1.0
	var b: Object = _build.call("get_building", building_id)
	if b == null or not b.has_method("staffing_ratio"):
		return 1.0
	return float(b.call("staffing_ratio"))


func _produce(m: ProdMachine, item: StringName, amount: int) -> void:
	if amount <= 0 or String(item) == "":
		return
	m.add_output(item, amount)
	_produced_total[item] = int(_produced_total.get(item, 0)) + amount
	Bus.item_produced.emit(item, amount)


## Hands finished goods to whoever will take them: [P03] first when it exists,
## the city stores otherwise. Anything refused stays in the buffer and eventually
## stalls the machine, which is exactly the back-pressure belts are supposed to
## create.
func _flush_outputs(m: ProdMachine) -> void:
	if m.outputs.is_empty():
		return
	for item: StringName in m.sorted_keys(m.outputs):
		var have: int = int(m.outputs.get(item, 0))
		if have <= 0:
			continue
		var accepted: int = 0
		if _has_accept_output:
			accepted = int(_logistics.call("accept_output", m.id, item, have))
			accepted = clampi(accepted, 0, have)
		if accepted < have:
			accepted += store.deposit(item, have - accepted)
		if accepted > 0:
			m.take_output(item, accepted)


## Tops the input buffer up from the city stores. A machine asks for whole sets,
## never a partial one, so two machines competing for the last ore do not each
## end up holding half of what they need.
func _refill(m: ProdMachine) -> void:
	var r: RecipeDef = m.recipe
	if r == null or r.inputs.is_empty():
		return
	var room: int = m.input_room()
	if room <= 0:
		return
	for item: StringName in r.sorted_inputs():
		var per: int = r.inputs[item]
		var have: int = int(m.inputs.get(item, 0))
		var target: int = maxi(per, mini(per * REFILL_SETS,
			int(round(float(m.def.input_slots) * REFILL_TARGET))))
		var want: int = mini(target - have, room)
		if want < per - have:
			want = per - have
		if want <= 0:
			continue
		var got: int = store.take(item, want)
		if got <= 0 and want > per - have and per - have > 0:
			# Could not take the comfortable amount; settle for exactly one set.
			got = store.take(item, per - have)
		if got > 0:
			m.add_input(item, got)
			room -= got


## Records the stall, announces it once, and re-announces it on a slow cadence so
## a UI that connected late still learns why.
func _park(m: ProdMachine, state: int, reason: StringName, item: StringName, tick: int) -> void:
	m.state = state
	m.reason = reason
	m.reason_item = item
	m.rate = 0.0
	if state == ProdMachine.State.IDLE:
		_idle += 1
	else:
		_stalled += 1
		# Counted by cause, not just counted. "8 stalled" is a number; "8 stalled
		# and every one of them says no crew" is a diagnosis, and it is the
		# difference between a critic reading a factory as dead and reading it as
		# starved of one specific thing. Written to metrics.csv so the answer is
		# in the artifacts rather than in a builder's summary.
		if reason == ProdMachine.REASON_UNSTAFFED:
			_stalled_unstaffed += 1
		elif reason == ProdMachine.REASON_NO_HEAT or reason == ProdMachine.REASON_TOO_COLD:
			_stalled_cold += 1
		elif reason == ProdMachine.REASON_MISSING_INPUT:
			_stalled_starved += 1
	var fresh: bool = m.announced_reason != reason
	if not fresh and tick - m.announced_tick < STALL_REANNOUNCE_TICKS:
		return
	m.announced_reason = reason
	m.announced_tick = tick
	Bus.machine_stalled.emit(m.id, reason)
	if fresh and reason == ProdMachine.REASON_DEPLETED:
		# A seam running out is a chapter of the game, not a status light: the
		# city has to go further out, into the dark, for the next one. Severity 1
		# — a brownout is gameplay, and so is this.
		Bus.alert_raised.emit(1, &"seam_depleted",
			"%s has worked out the ground under it." % m.def.display_name, m.world_pos)


# --- recipes --------------------------------------------------------------

## Picks the first recipe the machine can actually run, honouring research. The
## choice is written back into the building's `meta`, which [P11] documents as
## ours and which survives a blueprint round-trip — so a copied smelter comes
## back already set to what it was making.
func _pick_recipe(m: ProdMachine) -> void:
	var stored: StringName = _meta_recipe(m.id)
	if String(stored) != "" and book.has(stored):
		var r: RecipeDef = book.get_recipe(stored)
		if r.runs_on(m.kind, m.def.tags):
			_assign(m, stored)
			return
	for rid: StringName in book.for_machine(m.kind, m.def.tags, m.def.recipes):
		if _is_unlocked(book.get_recipe(rid).unlock_id):
			_assign(m, rid)
			return


func _assign(m: ProdMachine, rid: StringName) -> void:
	if m.recipe_id == rid:
		return
	# Materials already committed to the old craft are returned, not burned.
	if m.committed and m.recipe != null:
		for item: StringName in m.recipe.sorted_inputs():
			store.give(item, m.recipe.inputs[item])
	m.recipe_id = rid
	m.recipe = book.get_recipe(rid)
	m.progress = 0.0
	m.committed = false
	m.output_size = 0
	if m.recipe != null:
		# Cached because the "will the result fit" test runs every tick for every
		# machine, and building the merged output table there was two dictionary
		# allocations per machine per tick.
		var all: Dictionary[StringName, int] = m.recipe.all_outputs()
		for k: StringName in all:
			m.output_size += all[k]
	_write_meta_recipe(m.id, rid)


func _meta_recipe(building_id: int) -> StringName:
	if _build == null:
		return &""
	var b: Object = _build.call("get_building", building_id)
	if b == null:
		return &""
	var meta: Variant = b.get("meta")
	if typeof(meta) != TYPE_DICTIONARY:
		return &""
	return StringName(String((meta as Dictionary).get("recipe", "")))


func _write_meta_recipe(building_id: int, rid: StringName) -> void:
	if _build == null:
		return
	var b: Object = _build.call("get_building", building_id)
	if b == null:
		return
	var meta: Variant = b.get("meta")
	if typeof(meta) != TYPE_DICTIONARY:
		return
	var d: Dictionary = meta
	if String(rid) == "":
		d.erase("recipe")
	else:
		d["recipe"] = String(rid)


## Research gate. Defers to [P11]'s is_unlocked, which itself defers to [P10]
## when the tech tree exists and to the locally granted set otherwise — so a
## recipe can be gated before research lands.
func _is_unlocked(unlock_id: StringName) -> bool:
	if String(unlock_id) == "":
		return true
	if _unlock_cache.has(unlock_id):
		return _unlock_cache[unlock_id]
	var open: bool = true
	if _build != null and _build.has_method("is_unlocked"):
		open = bool(_build.call("is_unlocked", unlock_id))
	_unlock_cache[unlock_id] = open
	return open


# --- extraction -----------------------------------------------------------

func _seam_alive(m: ProdMachine) -> bool:
	if _grid == null or m.seam.x < 0:
		return false
	return int(_grid.call("resource_amount_at", m.seam)) > 0


## Finds the deposit this machine works: the richest matching tile under its own
## footprint first, and only then a ring search out to its reach. The search is
## throttled hard — it is the most expensive thing production can do.
func _acquire_seam(m: ProdMachine, tick: int) -> bool:
	if _grid == null:
		return false
	# The cooldown is stamped only when the search comes back EMPTY, so a drill
	# that has just worked one seam out looks for the next one on the very next
	# tick, and a drill on genuinely dead ground stops asking twenty times a
	# second. Deposits only ever shrink, so a failed search stays failed.
	if tick - m.last_seam_search < SEAM_SEARCH_EVERY:
		return false
	m.seam = Vector2i(-1, -1)
	var wanted: int = _ore_kind(m.def.extracts)
	var best: Vector2i = Vector2i(-1, -1)
	var best_amount: int = 0
	var best_kind: int = 0
	for c: Vector2i in m.footprint:
		var kind: int = int(_grid.call("resource_kind_at", c))
		if kind <= 0 or kind >= ORE_ITEMS.size() or String(ORE_ITEMS[kind]) == "":
			continue
		if wanted > 0 and kind != wanted:
			continue
		var amount: int = int(_grid.call("resource_amount_at", c))
		if amount > best_amount:
			best_amount = amount
			best = c
			best_kind = kind
	if best.x >= 0:
		m.seam = best
		m.seam_kind = best_kind
		m.seam_item = ORE_ITEMS[best_kind]
		return true

	if m.def.reach <= 0 or wanted <= 0 or not _grid.has_method("nearest_resource"):
		m.last_seam_search = tick
		return false
	var found: Vector2i = _grid.call("nearest_resource", m.center_cell, wanted, m.def.reach)
	if found.x < 0:
		m.last_seam_search = tick
		return false
	m.seam = found
	m.seam_kind = wanted
	m.seam_item = ORE_ITEMS[wanted]
	return true


func _harvest(cell: Vector2i, amount: int) -> int:
	if not _has_harvest:
		return amount
	return int(_grid.call("harvest", cell, amount))


## Item name -> Grid.Res index. 0 for "*" or anything unknown, which means
## "whatever is under the machine".
func _ore_kind(item: StringName) -> int:
	if String(item) == "" or item == &"*":
		return 0
	for i: int in ORE_ITEMS.size():
		if ORE_ITEMS[i] == item:
			return i
	return 0


# --- fuel & waste heat ----------------------------------------------------

## Pulls fuel straight out of a nearby extractor's output buffer before touching
## the city stores. Sorted by machine id, so it is stable.
func _take_from_machines(item: StringName, want: int) -> int:
	var got: int = 0
	for id: int in _sorted_ids():
		if got >= want:
			break
		var m: ProdMachine = machines[id]
		if int(m.outputs.get(item, 0)) <= 0:
			continue
		got += m.take_output(item, want - got)
	return got


## Hands captured waste heat to a recuperator as [P02] fuel. Heat treats it like
## any other burner, which is why the recovery loop needed no heat-side code.
func _deliver_waste(recuperator_id: int, units: float) -> float:
	if not _has_deliver_fuel:
		return units
	return float(_heat.call("deliver_fuel", recuperator_id, &"waste_heat", units))


# --- syncing with [P11] ---------------------------------------------------

## Pulls the finished buildings out of [P11]. Throttled: a full rescan every
## half second, or immediately when the building count moves. A machine coming
## online 10 ticks late is invisible; rescanning a thousand walls every tick is
## not affordable at any base size.
func _sync_from_build(tick: int) -> void:
	if _build == null or not _build.has_method("all_buildings"):
		return
	# A FIXED cadence, not "whenever the building count moved". Under a build
	# spree the count moves every tick, which turned this into a full walk of a
	# thousand buildings per tick — the exact cost the throttle exists to avoid.
	# Half a second of latency on a machine coming online is invisible.
	if tick - _last_sync_tick < SYNC_EVERY:
		return
	_last_sync_tick = tick

	var raw: Variant = _build.call("all_buildings")
	if typeof(raw) != TYPE_ARRAY:
		return
	# One reflective read per entry in the common case. A wall the city already
	# knows is not a machine costs an `id` read and a dictionary hit — everything
	# else (is_complete, kind, cell, rot) is only touched for candidates. On a
	# thousand-building base that difference is the whole cost of this system.
	for entry: Variant in (raw as Array):
		var b: Object = entry
		if b == null:
			continue
		var id: int = int(b.get("id"))
		if _not_ours.has(id):
			continue
		var m: ProdMachine = machines.get(id)
		if m == null:
			if not bool(b.call("is_complete")):
				continue
			if not _register(id, StringName(String(b.get("kind"))), b.get("cell"), int(b.get("rot"))):
				_not_ours[id] = true
				continue
			m = machines[id]
		m.enabled = bool(b.get("enabled"))

	# Removals are found from OUR side, which is tens of ids rather than
	# thousands, so a demolition costs nothing to notice.
	for id2: int in _sorted_ids().duplicate():
		var still: Object = _build.call("get_building", id2)
		if still == null or not bool(still.call("is_complete")):
			_unregister(id2)

	# The negative cache would otherwise remember every id the city ever built.
	# Pruning it is a full pass, so it happens once a minute, not once a tick.
	if tick - _not_ours_pruned >= NOT_OURS_PRUNE_TICKS:
		_not_ours_pruned = tick
		_prune_not_ours()


## Forgets ids [P11] no longer has, so the negative cache cannot grow forever.
func _prune_not_ours() -> void:
	if _not_ours.is_empty() or _build == null:
		return
	var keys: Array = _not_ours.keys()
	keys.sort()
	for id: int in keys:
		if _build.call("get_building", id) == null:
			_not_ours.erase(id)


func _register(building_id: int, kind: StringName, cell_value: Variant, rot: int) -> bool:
	var def: ProdMachineDef = _def_for(kind)
	if def == null:
		return false
	var m := ProdMachine.new()
	m.setup(building_id, kind, _to_cell(cell_value), def, rot)
	machines[building_id] = m
	_order_dirty = true
	waste.mark_dirty()
	_pick_recipe(m)
	Log.debug("production", "machine #%d %s at %s%s" % [building_id, kind, str(m.cell),
		"" if String(m.recipe_id) == "" else " running %s" % String(m.recipe_id)])
	return true


func _unregister(building_id: int) -> void:
	var m: ProdMachine = machines.get(building_id)
	if m == null:
		return
	# A demolished machine gives its buffers back rather than eating them.
	for item: StringName in m.sorted_keys(m.outputs):
		store.give(item, m.outputs[item])
	for item2: StringName in m.sorted_keys(m.inputs):
		store.give(item2, m.inputs[item2])
	machines.erase(building_id)
	_not_ours.erase(building_id)
	_order_dirty = true
	waste.mark_dirty()


func _load_defs() -> void:
	var count: int = 0
	# Registry.ids() is intern-pointer ordered, not alphabetical — see [ProdSort].
	# It only fills caches here, but a cache filled in a build-dependent order is
	# one refactor away from being a state-dependent one.
	for id: StringName in ProdSort.names(Registry.ids("buildings")):
		var def: ProdMachineDef = ProdMachineDef.from_resource(id, Registry.get_item("buildings", id))
		if not def.participates():
			_not_machines[id] = true
			continue
		_defs[id] = def
		count += 1
	Log.debug("production", "%d building definitions carry production behaviour" % count)


func _def_for(kind: StringName) -> ProdMachineDef:
	var cached: ProdMachineDef = _defs.get(kind)
	if cached != null:
		return cached
	if _not_machines.has(kind):
		return null
	if not Registry.has("buildings", kind):
		_not_machines[kind] = true
		return null
	var def: ProdMachineDef = ProdMachineDef.from_resource(kind, Registry.get_item("buildings", kind))
	if not def.participates():
		_not_machines[kind] = true
		return null
	_defs[kind] = def
	return def


# --- rates ----------------------------------------------------------------

## Two rolling marks, rotated every 30 seconds. The reported per-minute figure
## therefore always looks back over 30 to 60 seconds of real output — long
## enough that a 10-second craft does not make it flap, short enough that a
## stalled line shows up before the player has walked away.
func _roll_rates(tick: int) -> void:
	if tick - _mark_cur_tick < RATE_WINDOW_TICKS:
		return
	_mark_prev = _mark_cur.duplicate()
	_mark_prev_tick = _mark_cur_tick
	_mark_cur = _produced_total.duplicate()
	_mark_cur_tick = tick


# --- helpers --------------------------------------------------------------

func _sorted_ids() -> PackedInt32Array:
	if not _order_dirty:
		return _order
	var keys: Array = machines.keys()
	keys.sort()
	_order = PackedInt32Array()
	for k: int in keys:
		_order.append(k)
	_order_dirty = false
	return _order


func _is_frozen(building_id: int) -> bool:
	if not _has_frozen:
		return false
	return bool(_heat.call("is_frozen", building_id))


func _ambient() -> float:
	if _has_ambient:
		var v: Variant = _climate.call("ambient_temperature")
		if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
			return float(v)
	return DEFAULT_AMBIENT_C


func _target_id(cmd: Dictionary) -> int:
	if cmd.has("id"):
		var id: int = int(cmd["id"])
		return id if machines.has(id) else -1
	if not cmd.has("cell"):
		return -1
	var cell: Vector2i = _to_cell(cmd["cell"])
	for mid: int in _sorted_ids():
		if machines[mid].footprint.has(cell):
			return mid
	return -1


func _to_cell(v: Variant) -> Vector2i:
	match typeof(v):
		TYPE_VECTOR2I:
			return v
		TYPE_VECTOR2:
			var f: Vector2 = v
			return Vector2i(int(f.x), int(f.y))
		TYPE_ARRAY:
			var a: Array = v
			if a.size() >= 2:
				return Vector2i(int(a[0]), int(a[1]))
		TYPE_DICTIONARY:
			var d: Dictionary = v
			return Vector2i(int(d.get("x", 0)), int(d.get("y", 0)))
	return Vector2i.ZERO


func _dump() -> void:
	Log.info("production", "%d machines: %d running, %d stalled, %d idle, %d crafts, depth %d/%d" % [
		machines.size(), _active, _stalled, _idle, _crafts_total,
		chain_depth_reached(), book.max_depth])
	for id: int in _sorted_ids():
		var m: ProdMachine = machines[id]
		Log.info("production", "  #%-5d %-16s %-14s %-13s rate %.2f (cold %.2f heat %.2f) in %d out %d" % [
			id, String(m.kind), String(m.recipe_id),
			String(m.reason) if String(m.reason) != "" else "running",
			m.rate, m.cold, m.heat_factor, m.input_total(), m.output_total()])
	for item: StringName in _rate_keys:
		var ipm: float = items_per_minute(item)
		if ipm > 0.0:
			Log.info("production", "  %-16s %6.1f /min  (%d total)" % [
				String(item), ipm, int(_produced_total.get(item, 0))])


# =========================================================================
# persistence & metrics
# =========================================================================

func serialize() -> Dictionary:
	var ms: Array = []
	for id: int in _sorted_ids():
		ms.append(machines[id].to_json())
	var totals_by_item: Dictionary = {}
	var rates: Dictionary = {}
	for k: StringName in ProdSort.keys_of(_produced_total):
		totals_by_item[String(k)] = _produced_total[k]
		rates[String(k)] = snappedf(items_per_minute(k), 0.01)
	return {
		"machines": ms,
		"produced": totals_by_item,
		"items_per_minute": rates,
		"store": store.to_json(),
		"waste": {
			"recovered": snappedf(waste.recovered_rate, 0.001),
			"vented": snappedf(waste.vented_rate, 0.001),
			"links": waste.to_json(),
		},
		"totals": totals(),
		"marks": {
			"prev_tick": _mark_prev_tick,
			"cur_tick": _mark_cur_tick,
		},
	}


func deserialize(data: Dictionary) -> void:
	machines.clear()
	_order_dirty = true
	_not_ours.clear()
	waste.mark_dirty()
	for raw: Variant in data.get("machines", []):
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var snap: Dictionary = raw
		var kind: StringName = StringName(String(snap.get("kind", "")))
		var def: ProdMachineDef = _def_for(kind)
		if def == null:
			Log.warn("production", "save references unknown machine '%s'" % String(kind))
			continue
		var m := ProdMachine.new()
		var cell: Vector2i = _to_cell(snap.get("cell", [0, 0]))
		m.setup(int(snap.get("id", 0)), kind, cell, def, 0)
		m.from_json(snap)
		m.recipe = book.get_recipe(m.recipe_id)
		m.output_size = 0
		if m.recipe != null:
			var all: Dictionary[StringName, int] = m.recipe.all_outputs()
			for k: StringName in all:
				m.output_size += all[k]
		machines[m.id] = m

	_produced_total.clear()
	var prod: Variant = data.get("produced", {})
	if typeof(prod) == TYPE_DICTIONARY:
		var pd: Dictionary = prod
		for k: StringName in ProdSort.names(pd.keys()):
			_produced_total[k] = int(pd.get(String(k), 0))
	store.from_json(data.get("store", {}))
	var marks: Dictionary = data.get("marks", {})
	_mark_prev_tick = int(marks.get("prev_tick", 0))
	_mark_cur_tick = int(marks.get("cur_tick", 0))
	_mark_prev = _produced_total.duplicate()
	_mark_cur = _produced_total.duplicate()
	_last_sync_tick = -1000


func metrics() -> Dictionary:
	var out: Dictionary = {
		"machines": machines.size(),
		"active_machines": _active,
		"stalled": _stalled,
		"stalled_unstaffed": _stalled_unstaffed,
		"stalled_cold": _stalled_cold,
		"stalled_starved": _stalled_starved,
		"idle": _idle,
		"crafts_total": _crafts_total,
		"chain_depth": chain_depth_reached(),
		"recipes": book.size(),
		"waste_recovered": snappedf(waste.recovered_rate, 0.001),
		"waste_vented": snappedf(waste.vented_rate, 0.001),
		"fuel_served": snappedf(_fuel_served, 0.001),
		"fuel_denied": snappedf(_fuel_denied, 0.001),
	}
	# Fixed key set, derived from the recipe graph at setup, so metrics.csv keeps
	# the same columns for the whole run and two builds stay diffable.
	for item: StringName in _rate_keys:
		out["ipm.%s" % String(item)] = snappedf(items_per_minute(item), 0.01)
	return out
