class_name LcnStatsRecorder
extends RefCounted
## Reads the simulation into the history, and costs nothing doing it. [P20]
##
## The recorder is the only thing in this part that runs while the game is
## running, so its whole design is about not being noticed:
##
##   * it is driven from `Bus.tick_advanced`, never from a frame, so a dropped
##     frame cannot skip a sample and a fast-forward cannot double one;
##   * it samples every [constant FINE_STRIDE] ticks and does the expensive
##     reads only every [constant MID_STRIDE], holding the last value in
##     between — a chart cannot tell the difference and the tick can;
##   * it only ever CALLS the simulation, never writes to it. Every accessor it
##     uses returns a cached value or walks a list the system already keeps.
##
## Measured, not asserted: [method microseconds_per_tick] reports the real
## amortised cost against the real number of ticks that went past, and
## `tests/stats/test_stats_recorder.gd` fails the build if it crosses
## [constant BUDGET_US_PER_TICK].
##
## PER-ITEM CONSUMPTION is the one number the simulation does not already keep.
## [ProductionSystem] counts what was produced but nothing counts what was eaten,
## so the recorder differences each machine's `crafts_done` and multiplies by its
## recipe's inputs. A machine that switched recipe between two samples has its
## delta dropped rather than misattributed — half a gear is not half a circuit,
## and it is not two iron plates either.

## Ticks between samples on each track. 20 ticks is one in-world second.
const FINE_STRIDE: int = 10
const MID_STRIDE: int = 100
const RUN_STRIDE: int = 400

const FINE_CAP: int = 240      ## 120 s
const MID_CAP: int = 288       ## 24 min
const RUN_CAP: int = 300       ## 100 min, then it halves and keeps going

## Ticks between the expensive reads (building census, research, job board).
const SLOW_EVERY: int = MID_STRIDE
## Ticks between prunes of the per-machine craft ledger.
const PRUNE_EVERY: int = 2000
## The contract this part signs with the tick budget, in microseconds.
const BUDGET_US_PER_TICK: float = 200.0

## Track ids.
const T_FINE: StringName = &"fine"
const T_MID: StringName = &"mid"
const T_RUN: StringName = &"run"

var fine: LcnStatTrack = null
var mid: LcnStatTrack = null
var run: LcnStatTrack = null

## Items the recipe book knows about, sorted. The per-item series follow it.
var items: Array[StringName] = []
## True once bind() found at least one system to read.
var bound: bool = false
## Absolute tick of the last sample taken.
var last_tick: int = 0

var _sim: Node = null
var _heat: Object = null
var _society: Object = null
var _citizens: Object = null
var _climate: Object = null
var _combat: Object = null
var _threat: Object = null
var _production: Object = null
var _logistics: Object = null
var _build: Object = null
var _research: Object = null

# --- consumption ledger -----------------------------------------------------
var _machine_crafts: Dictionary[int, int] = {}
var _machine_recipe: Dictionary[int, StringName] = {}
var _consumed: Dictionary[StringName, float] = {}
var _produced: Dictionary[StringName, float] = {}

# --- held values from the slow read ----------------------------------------
var _slow: Dictionary[StringName, float] = {}
var _slow_tick: int = -100000
var _prune_tick: int = -100000

# --- cost ------------------------------------------------------------------
var _cost_us: int = 0
var _cost_ticks: int = 0
var _samples: int = 0

var _values: Dictionary[StringName, float] = {}


func _init() -> void:
	fine = LcnStatTrack.new(FINE_STRIDE, FINE_CAP, false)
	mid = LcnStatTrack.new(MID_STRIDE, MID_CAP, false)
	run = LcnStatTrack.new(RUN_STRIDE, RUN_CAP, true)


## Points the recorder at the live world and declares every series. Safe to call
## again after `Sim.create_world`; it throws the old history away, because two
## worlds on one chart is a lie.
##
## `overrides` replaces a system by name. Only the tests use it, and they use it
## so the consumption ledger can be driven against a machine that crafts on
## command instead of against whatever the balance happens to be this week.
func bind(overrides: Dictionary = {}) -> void:
	_sim = _autoload("Sim")
	_heat = _pick(overrides, &"heat")
	_society = _pick(overrides, &"society")
	_citizens = _pick(overrides, &"citizens")
	_climate = _pick(overrides, &"climate")
	_combat = _pick(overrides, &"combat")
	_threat = _pick(overrides, &"threat")
	_production = _pick(overrides, &"production")
	_logistics = _pick(overrides, &"logistics")
	_build = _pick(overrides, &"build")
	_research = _pick(overrides, &"research")
	bound = _heat != null or _society != null or _climate != null or _production != null

	items = _read_item_list()
	LcnStatsDefs.assign_palette(items)
	_machine_crafts.clear()
	_machine_recipe.clear()
	_consumed.clear()
	_produced.clear()
	_slow.clear()
	_slow_tick = -100000
	_prune_tick = -100000
	_cost_us = 0
	_cost_ticks = 0
	_samples = 0
	last_tick = 0

	for track: LcnStatTrack in [fine, mid, run]:
		track.clear()
		for key: StringName in LcnStatsDefs.ordered_keys():
			track.declare(key, LcnStatsDefs.kind_of(key) == LcnStatsDefs.Kind.COUNTER)
		for item: StringName in items:
			track.declare(LcnStatsDefs.produced_key(item), true)
			track.declare(LcnStatsDefs.consumed_key(item), true)
			track.declare(LcnStatsDefs.stock_key(item), false)


## Call once per simulation tick. Everything above the modulo is the cost the
## budget is measured against, which is why the modulo comes first.
func on_tick(tick: int) -> void:
	_cost_ticks += 1
	if not bound or not fine.is_due(tick):
		return
	var t0: int = Time.get_ticks_usec()
	_collect(tick)
	fine.push_sample(tick, _values)
	if mid.is_due(tick):
		mid.push_sample(tick, _values)
	if run.is_due(tick):
		run.push_sample(tick, _values)
	last_tick = tick
	_samples += 1
	_cost_us += Time.get_ticks_usec() - t0


## Amortised microseconds per simulation tick since bind(). This is the number
## the perf claim is made of; it is measured, not asserted.
func microseconds_per_tick() -> float:
	if _cost_ticks <= 0:
		return 0.0
	return float(_cost_us) / float(_cost_ticks)


func microseconds_per_sample() -> float:
	if _samples <= 0:
		return 0.0
	return float(_cost_us) / float(_samples)


func sample_count() -> int:
	return _samples


func track(id: StringName) -> LcnStatTrack:
	match id:
		T_MID:
			return mid
		T_RUN:
			return run
		_:
			return fine


## Total bytes of sample storage across all three tracks.
func memory_bytes() -> int:
	return fine.memory_bytes() + mid.memory_bytes() + run.memory_bytes()


## The last value recorded for a key, straight off the fine track.
func latest(key: StringName) -> float:
	var s: LcnStatSeries = fine.series(key)
	return 0.0 if s == null else s.last()


# =========================================================== the sample =====

func _collect(tick: int) -> void:
	var v: Dictionary[StringName, float] = _values
	if tick - _slow_tick >= SLOW_EVERY:
		_slow_tick = tick
		_read_slow()
	if tick - _prune_tick >= PRUNE_EVERY:
		_prune_tick = tick
		_prune_ledger()

	_read_heat(v)
	_read_society(v)
	_read_combat(v)
	_read_world(v)
	_read_factory(v, tick)
	for key: StringName in _slow:
		v[key] = _slow[key]


func _read_heat(v: Dictionary[StringName, float]) -> void:
	if _heat == null:
		return
	var t: Dictionary = _heat.call("totals")
	v[&"heat_supply"] = float(t.get("supply", 0.0))
	v[&"heat_demand"] = float(t.get("demand", 0.0))
	v[&"heat_delivered"] = float(t.get("delivered", 0.0))
	v[&"heat_deficit"] = float(t.get("deficit", 0.0))
	v[&"heat_buffer"] = float(t.get("buffer", 0.0))
	v[&"heat_loss"] = float(t.get("loss", 0.0))
	v[&"heat_frozen"] = float(t.get("frozen", 0))
	v[&"heat_avg_warmth"] = float(t.get("avg_warmth", 0.0))
	v[&"heat_brownouts"] = float(t.get("brownouts", 0))


func _read_society(v: Dictionary[StringName, float]) -> void:
	if _society == null:
		return
	v[&"hope"] = float(_society.call("hope"))
	v[&"discontent"] = float(_society.call("discontent"))
	v[&"pop"] = float(_society.call("population"))
	v[&"deaths"] = float(_society.call("deaths_total"))
	v[&"sick"] = float(_society.call("sick_count"))
	v[&"homeless"] = float(_society.call("homeless_count"))
	v[&"laws"] = float(_society.call("laws_signed_count"))


func _read_combat(v: Dictionary[StringName, float]) -> void:
	if _combat != null:
		var m: Dictionary = _combat.call("metrics")
		v[&"kills"] = float(m.get("kills", 0))
		v[&"damage_dealt"] = float(m.get("damage_dealt", 0.0))
		v[&"damage_taken"] = float(m.get("damage_taken", 0.0))
		v[&"enemies_alive"] = float(m.get("enemies_alive", 0))
		v[&"structures_lost"] = float(m.get("structures_lost", 0))
		v[&"defence_heat"] = float(m.get("heat_spent_on_defence", 0.0))
	if _threat != null and _threat.has_method("threat_level"):
		v[&"threat"] = float(_threat.call("threat_level"))


func _read_world(v: Dictionary[StringName, float]) -> void:
	if _climate == null:
		return
	v[&"temperature"] = float(_climate.call("ambient_temperature"))
	v[&"light"] = float(_climate.call("light_level"))
	v[&"night"] = 1.0 if bool(_climate.call("is_night")) else 0.0
	v[&"day"] = float(_climate.call("day"))
	v[&"storm"] = float(_climate.call("storm_intensity"))


## Production, consumption and stock. The consumption ledger is the only place
## the recorder does real arithmetic, and it is one pass over the machines.
func _read_factory(v: Dictionary[StringName, float], _tick: int) -> void:
	if _production == null:
		return
	_advance_consumption()
	var store: Object = _production.get("store")
	for item: StringName in items:
		var made: float = float(_production.call("produced_total", item))
		_produced[item] = made
		v[LcnStatsDefs.produced_key(item)] = made
		v[LcnStatsDefs.consumed_key(item)] = _consumed.get(item, 0.0)
		if store != null:
			v[LcnStatsDefs.stock_key(item)] = float(store.call("count", item))


## One pass over every machine, differencing `crafts_done`. A machine whose
## recipe changed since the last pass contributes nothing this pass: attributing
## its crafts to whichever recipe it happens to hold now would put iron ore in
## the circuit line and send a player hunting a bottleneck that does not exist.
func _advance_consumption() -> void:
	var machines: Dictionary = _production.get("machines")
	if machines == null:
		return
	for id: int in machines:
		var m: Object = machines[id]
		if m == null:
			continue
		var done: int = int(m.get("crafts_done"))
		var rid: StringName = StringName(String(m.get("recipe_id")))
		var prev: int = _machine_crafts.get(id, 0)
		var prev_rid: StringName = _machine_recipe.get(id, rid)
		_machine_crafts[id] = done
		_machine_recipe[id] = rid
		if done <= prev or rid != prev_rid or rid == &"":
			continue
		var recipe: Object = m.get("recipe")
		if recipe == null:
			continue
		var inputs: Dictionary = recipe.get("inputs")
		if inputs == null or inputs.is_empty():
			continue
		var runs: float = float(done - prev)
		for item: StringName in inputs:
			_consumed[item] = _consumed.get(item, 0.0) + runs * float(inputs[item])


## A demolished machine leaves an entry behind. It is two ints, but a city that
## rebuilds for ten hours would leave thousands, so the ledger is swept.
func _prune_ledger() -> void:
	var machines: Dictionary = _production.get("machines") if _production != null else {}
	if machines == null or _machine_crafts.size() <= machines.size():
		return
	var stale: Array[int] = []
	for id: int in _machine_crafts:
		if not machines.has(id):
			stale.append(id)
	for id2: int in stale:
		_machine_crafts.erase(id2)
		_machine_recipe.erase(id2)


## The reads that walk a list. Every hundred ticks, held in between — a building
## census on a seventeen-hundred-building city is the single most expensive
## thing this part can ask for, and asking for it ten times a second would put
## the recorder over budget on its own.
func _read_slow() -> void:
	if _build != null:
		var bm: Dictionary = _build.call("metrics")
		_slow[&"buildings"] = float(bm.get("buildings_total", 0))
	if _production != null:
		var pm: Dictionary = _production.call("totals")
		_slow[&"machines_active"] = float(pm.get("active", 0))
		_slow[&"machines_stalled"] = float(pm.get("stalled", 0))
		_slow[&"crafts"] = float(pm.get("crafts", 0))
	if _logistics != null:
		var lw: Object = _logistics.get("world")
		if lw != null:
			_slow[&"items_moved"] = float(lw.get("items_moved"))
	if _citizens != null:
		_slow[&"avg_warmth"] = float(_citizens.call("average_warmth"))
		_slow[&"avg_morale"] = float(_citizens.call("average_morale"))
	if _research != null:
		var active: StringName = StringName(String(_research.call("active")))
		_slow[&"research"] = float(_research.call("progress_of", active)) if String(active) != "" else 0.0
		_slow[&"researched"] = float((_research.call("unlocked_ids") as Array).size())


# ============================================================== plumbing =====

func _read_item_list() -> Array[StringName]:
	var out: Array[StringName] = []
	if _production == null:
		return out
	var book: Object = _production.get("book")
	if book == null:
		return out
	var raw: Array = book.get("items")
	if raw == null:
		return out
	var names: Array[String] = []
	for i: Variant in raw:
		names.append(String(i))
	names.sort()
	for n: String in names:
		out.append(StringName(n))
	return out


func _pick(overrides: Dictionary, n: StringName) -> Object:
	if overrides.has(n):
		return overrides[n]
	return _system(n)


func _system(n: StringName) -> Object:
	if _sim == null:
		return null
	return _sim.call("get_system", n)


func _autoload(n: String) -> Node:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null(NodePath(n))
