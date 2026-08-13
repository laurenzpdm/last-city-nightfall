class_name ResearchSystem
extends SimSystem
## [P10] Research & Progression — the tech tree, and the pacing engine that
## decides what the tree offers you next.
##
## The tree itself is content: 45 nodes in `game/content/research/`, a real
## directed acyclic graph with cross-branch prerequisites (the armour-piercing
## round needs the metallurgists, not the gunners). Nothing in this folder knows
## the name of a single node.
##
## THREE THINGS MAKE THIS MORE THAN A TIMER:
##
## 1. RESEARCH COMPETES FOR MATERIALS. Costs are paid in four instalments out of
##    the same yard construction eats from (ResearchLedger). A plate spent on
##    Alloy Steel is a plate the wall does not get, and a project that cannot buy
##    its next instalment STALLS with the shortfall named — a legible failure,
##    not a silent one.
##
## 2. THE TREE ANSWERS PROBLEMS, NOT A LIST. Every node declares the measured
##    problem it is an answer to (ResearchNode.answers). ResearchPacing measures
##    twenty of those problems from the live world every five seconds, and the
##    recommendation is whichever available node answers the loudest one. That
##    is why insulation arrives the night heat loss first hurts and the
##    anti-armour round arrives when the breakers do.
##
## 3. PROGRESS SURVIVES A CHANGE OF MIND. Set a project aside because the copper
##    ran out and the insight and materials already spent stay on it.
##
## Contracts other parts use:
##   is_unlocked(id) -> bool          [P11] gates BuildingDef.unlock_id on it
##   available() -> Array             ids the player may start right now
##   progress_of(id) -> float         0..1
##   tree_layout() -> Dictionary      everything [P18] needs to draw the tree
##   multiplier(key) / modifier(key)  the numeric payoff, see ResearchDefs
##   unlocked_laws() / unlocked_recipes()   for [P06] and [P04]
##
## Commands: Sim.submit_command({"system": &"research", "op": "start", "id": ...})
## — see execute() for the full verb list.

const CATEGORY: String = "research"
const TAG: String = ResearchDefs.TAG

## Ticks between pacing samples. The measurements it reads move on the scale of
## a minute; sampling every tick would be twenty times the cost for no signal.
const PACING_INTERVAL: int = 100
## Ticks between recomputing the insight rate (a scan over the city's workshops).
const RATE_INTERVAL: int = 20
## Insight per second with nothing built at all. The city always has engineers;
## a save with no workshops still crawls forward instead of deadlocking.
## Calibrated on the reference run: a bare city clears a tier-1 node in about
## two minutes, a city with three workshops in under one.
const BASE_INSIGHT: float = 1.5
## Per running building tagged &"research".
const INSIGHT_PER_LAB: float = 2.5
## Per running building tagged &"crafter" — drafting happens on the shop floor.
const INSIGHT_PER_WORKSHOP: float = 0.70
## A browned-out city thinks slower, but never stops.
const COLD_HANDS_FLOOR: float = 0.55
## Ambient at which cold starts costing thinking time, and the span to the floor.
const COLD_START_C: float = -25.0
const COLD_SPAN_C: float = 25.0
## Ticks a project may sit unable to buy its next instalment before the
## auto-picker sets it aside and works on something it can actually pay for.
const STALL_PARK_TICKS: int = 900
## Ticks between repeats of the "your engineers are idle" nudge.
const IDLE_NUDGE_TICKS: int = 1200
## Share of materials handed back when a project is abandoned outright.
const CANCEL_REFUND: float = 0.5

## Result codes returned by execute(), so a UI can react to the KIND of refusal.
const CODE_OK: StringName = &"ok"
const CODE_UNKNOWN: StringName = &"unknown_node"
const CODE_LOCKED: StringName = &"prereqs_missing"
const CODE_DONE: StringName = &"already_researched"
const CODE_BUSY: StringName = &"already_active"
const CODE_BAD_COMMAND: StringName = &"bad_command"

# --------------------------------------------------------------- state ------

var _graph: ResearchGraph = ResearchGraph.new()
var _effects: ResearchEffects = ResearchEffects.new()
var _ledger: ResearchLedger = ResearchLedger.new()
var _pacing: ResearchPacing = ResearchPacing.new()

var _done: Dictionary[StringName, bool] = {}
var _done_order: Array[StringName] = []
var _unlocked: Dictionary[StringName, bool] = {}
var _progress: Dictionary[StringName, ResearchProgress] = {}
var _queue: Array[StringName] = []
var _active: StringName = &""

## The engineers pick their own next project when the queue runs dry. Turn it
## off and the city waits for orders.
var _auto: bool = true
var _tick: int = 0
var _rate: float = BASE_INSIGHT
var _rate_reason: String = "bare hands"
var _insight_total: float = 0.0
var _completed_total: int = 0
var _stall_events: int = 0
var _last_idle_nudge: int = -100000

## Cached availability, invalidated whenever the done-set changes.
var _available: Array[StringName] = []
var _available_dirty: bool = true

## Latest recommendation: {id, score, signal, reason}. Empty when nothing fits.
var _suggestion: Dictionary = {}

var _climate: WeakRef = null
var _heat: WeakRef = null
var _build: WeakRef = null

## Static half of tree_layout(), built once. The state half is merged on call.
var _layout_cache: Dictionary = {}


func _init() -> void:
	order = 90


func system_name() -> StringName:
	return &"research"


# ==========================================================================
#  LIFECYCLE
# ==========================================================================

func setup() -> void:
	_done.clear()
	_done_order.clear()
	_unlocked.clear()
	_progress.clear()
	_queue.clear()
	_active = &""
	_auto = true
	_tick = 0
	_rate = BASE_INSIGHT
	_insight_total = 0.0
	_completed_total = 0
	_stall_events = 0
	_last_idle_nudge = -100000
	_suggestion = {}
	_effects.clear()
	_available_dirty = true

	var nodes: Array[ResearchNode] = []
	for res: Resource in Registry.all(CATEGORY):
		var n := res as ResearchNode
		if n == null:
			Log.warn(TAG, "content item in %s is not a ResearchNode: %s" % [CATEGORY, res.resource_path])
			continue
		nodes.append(n)
	_graph.build(nodes)
	for p: String in _graph.problems:
		Log.warn(TAG, "tree: %s" % p)

	_build_layout_cache()

	if _graph.size() == 0:
		Log.warn(TAG, "no research content in game/content/%s — the tree is empty" % CATEGORY)
	else:
		Log.info(TAG, "tree loaded: %d nodes, %d edges, %d branches, %d columns, %d roots" % [
			_graph.size(), _graph.edges().size(), _graph.bands.size(),
			_graph.columns, _graph.roots().size(),
		])


func post_setup() -> void:
	_climate = _wref(Sim.get_system(&"climate"))
	_heat = _wref(Sim.get_system(&"heat"))
	_build = _wref(Sim.get_system(&"build"))
	_ledger.bind()
	_pacing.bind()
	_recompute_rate()
	# Sample once before the first tick so the very first auto-pick is already an
	# answer to the world the player woke up in, not a guess.
	_pacing.sample(0)
	_refresh_suggestion()
	Log.info(TAG, "ready: %s, %s, %.2f insight/s at rest" % [
		_ledger.describe(), _pacing.describe(), _rate,
	])


func step(tick: int) -> void:
	_tick = tick
	if _graph.size() == 0:
		return

	if tick % PACING_INTERVAL == 0:
		_pacing.sample(tick)
		_refresh_suggestion()
	if tick % RATE_INTERVAL == 0:
		_recompute_rate()

	if String(_active) == "":
		_pull_next()
		if String(_active) == "":
			_nudge_if_idle()
			return

	_advance_active()


# ==========================================================================
#  PUBLIC API — what the rest of the game asks
# ==========================================================================

## Is this gate open? Answers for node ids AND for anything a node grants
## (recipe_*, law_*, a building id another part chose). [P11] routes
## BuildingDef.unlock_id through here.
func is_unlocked(id: StringName) -> bool:
	if String(id) == "":
		return true
	return _unlocked.has(id)


## True only for a node that has actually been researched.
func is_researched(id: StringName) -> bool:
	return _done.has(id)


## Node ids the player may start right now: every prerequisite done, not already
## researched. Sorted, so a UI listing it twice gets the same order twice.
func available() -> Array[StringName]:
	_ensure_available()
	return _available.duplicate()


## 0.0 untouched, 1.0 finished. Works for any node id; 0.0 for an unknown one.
func progress_of(id: StringName) -> float:
	if _done.has(id):
		return 1.0
	var n: ResearchNode = _graph.node(id)
	if n == null:
		return 0.0
	var p: ResearchProgress = _progress.get(id)
	if p == null:
		return 0.0
	return p.fraction(n.work)


## The node being worked on, or &"".
func active() -> StringName:
	return _active


## Explicit player queue, in order. Does not include the active node.
func queue() -> Array[StringName]:
	return _queue.duplicate()


## Insight points produced per second right now.
func rate() -> float:
	return _rate


## Seconds until the active node finishes at the current rate. -1 when nothing
## is running, and a very large number while it is stalled.
func eta_seconds() -> float:
	if String(_active) == "":
		return -1.0
	var n: ResearchNode = _graph.node(_active)
	var p: ResearchProgress = _progress.get(_active)
	if n == null or p == null:
		return -1.0
	if p.is_stalled():
		return -2.0
	var left: float = maxf(0.0, float(n.work) - p.points)
	return left / maxf(0.0001, _rate)


## Additive sum for an effect key. See ResearchDefs for the key namespace.
func modifier(key: StringName) -> float:
	return _effects.modifier(key)


## 1.0 + the additive sum, floored at 0. This is what a rate should be scaled by.
func multiplier(key: StringName) -> float:
	return _effects.multiplier(key)


## Every live modifier, sorted. For the stats panel and for saves.
func effects() -> Dictionary:
	return _effects.snapshot()


## Law ids the tree has opened, for [P06].
func unlocked_laws() -> Array[StringName]:
	return _unlocked_with(ResearchDefs.PREFIX_LAW)


## Recipe ids the tree has opened, for [P04].
func unlocked_recipes() -> Array[StringName]:
	return _unlocked_with(ResearchDefs.PREFIX_RECIPE)


## Every unlock id currently open, sorted.
func unlocked_ids() -> Array[StringName]:
	var keys: Array = _unlocked.keys()
	keys.sort()
	var out: Array[StringName] = []
	for k: StringName in keys:
		out.append(k)
	return out


## What the engineers would pick next and why, or {} when nothing fits.
## Keys: id, title, score, signal, signal_value, reason, branch.
func suggestion() -> Dictionary:
	return _suggestion.duplicate(true)


## The measured problems behind that recommendation. Straight from ResearchPacing.
func pacing_snapshot() -> Dictionary:
	return _pacing.snapshot()


## The tree as a graph object, for tests and tooling. Read-only.
func graph() -> ResearchGraph:
	return _graph


## Materials still owed on a node before it can finish, empty when clear.
func remaining_cost(id: StringName) -> Dictionary[StringName, int]:
	var out: Dictionary[StringName, int] = {}
	var n: ResearchNode = _graph.node(id)
	if n == null or _done.has(id):
		return out
	var p: ResearchProgress = _progress.get(id)
	var keys: Array = n.cost.keys()
	keys.sort()
	for k: StringName in keys:
		var owed: int = int(n.cost[k])
		if p != null:
			owed -= int(p.paid.get(k, 0))
		if owed > 0:
			out[k] = owed
	return out


# ==========================================================================
#  TREE LAYOUT — everything [P18] needs, so it never re-derives the graph
# ==========================================================================

## The whole tree, positioned, stated and explained. Column/row coordinates are
## computed once at world creation and never move, so a UI can cache sprite
## positions and only re-read the state fields.
##
## Shape:
##   {columns, rows, branches:[{key,title,summary,color,row_start,row_end,
##                              total,done,available}],
##    nodes:[{id,title,description,flavour,branch,tier,column,row,state,
##            progress,points,work,cost,paid,missing,affordable,prereqs,
##            unlocks,grants,effects,answers,urgency,score,reason,eta_seconds}],
##    edges:[{from,to,from_branch,to_branch,cross_branch,satisfied}],
##    active, queue, researched, suggestion, rate, auto}
func tree_layout() -> Dictionary:
	_ensure_available()
	var out: Dictionary = _layout_cache.duplicate(true)
	var avail: Dictionary[StringName, bool] = {}
	for a: StringName in _available:
		avail[a] = true

	var nodes: Array = out.get("nodes", [])
	for entry: Variant in nodes:
		var row: Dictionary = entry
		var id: StringName = StringName(String(row.get("id", "")))
		var n: ResearchNode = _graph.node(id)
		if n == null:
			continue
		var p: ResearchProgress = _progress.get(id)
		var state: int = _state_of(id, avail.has(id))
		row["state"] = ResearchDefs.state_name(state)
		row["state_index"] = state
		row["progress"] = snappedf(progress_of(id), 0.001)
		row["points"] = snappedf(p.points if p != null else 0.0, 0.01)
		row["paid"] = p.paid_json() if p != null else {}
		row["missing"] = p.missing_json() if p != null else {}
		var owed: Dictionary[StringName, int] = remaining_cost(id)
		row["remaining_cost"] = _items_json(owed)
		row["affordable"] = _ledger.can_afford(owed)
		row["eta_seconds"] = snappedf(_eta_of(id), 0.1)
		if avail.has(id):
			row["score"] = snappedf(_score_of(id), 0.01)
			row["reason"] = _pacing.reason_for(n)
		else:
			row["score"] = 0.0
			row["reason"] = ""

	var branches: Array = out.get("branches", [])
	for entry2: Variant in branches:
		var b: Dictionary = entry2
		var key: StringName = StringName(String(b.get("key", "")))
		var total: int = 0
		var done: int = 0
		var open: int = 0
		for id2: StringName in _graph.branch_ids(key):
			total += 1
			if _done.has(id2):
				done += 1
			elif avail.has(id2):
				open += 1
		b["total"] = total
		b["done"] = done
		b["available"] = open

	var edges: Array = out.get("edges", [])
	for entry3: Variant in edges:
		var e: Dictionary = entry3
		e["satisfied"] = _done.has(StringName(String(e.get("from", ""))))

	out["active"] = String(_active)
	out["queue"] = _ids_json(_queue)
	out["researched"] = _ids_json(_done_order)
	out["suggestion"] = suggestion()
	out["pacing"] = _pacing.snapshot()
	out["rate"] = snappedf(_rate, 0.01)
	out["rate_reason"] = _rate_reason
	out["auto"] = _auto
	return out


# ==========================================================================
#  COMMANDS
# ==========================================================================

## Routed by Sim.submit_command. Never logs an error — a refused research order
## is a message for the player, not a broken build.
func handle_command(cmd: Dictionary) -> void:
	var res: Dictionary = execute(cmd)
	if not bool(res.get("ok", false)):
		Log.warn(TAG, "%s refused: %s" % [String(cmd.get("op", "?")), String(res.get("reason", ""))])


## The command surface, also callable directly by tests and by [P21] tutorial.
##
##   start {id}          begin now; whatever was active is parked with its progress
##   queue {id}          append to the queue
##   unqueue {id}        remove from the queue
##   clear_queue {}      empty the queue
##   cancel {id?}        abandon a project, refunding half of what it consumed
##   park {}             set the active project aside, keeping everything
##   complete {id}       finish it and every prerequisite (scenarios, tutorial)
##   grant {unlock}      open one unlock id without researching anything
##   set_auto {on}       let the engineers pick for themselves, or not
##   add_insight {points} debug: pour insight into the active project
func execute(cmd: Dictionary) -> Dictionary:
	var op: String = String(cmd.get("op", ""))
	match op:
		"start":
			return _op_start(_id_of(cmd))
		"queue":
			return _op_queue(_id_of(cmd))
		"unqueue":
			return _op_unqueue(_id_of(cmd))
		"clear_queue":
			var n: int = _queue.size()
			_queue.clear()
			return _ok({"removed": n})
		"cancel":
			var id: StringName = _id_of(cmd)
			return _op_cancel(id if String(id) != "" else _active)
		"park":
			return _op_park()
		"complete":
			return _op_complete(_id_of(cmd))
		"grant":
			return _op_grant(StringName(String(cmd.get("unlock", cmd.get("id", "")))))
		"set_auto":
			_auto = bool(cmd.get("on", cmd.get("value", true)))
			return _ok({"auto": _auto})
		"add_insight":
			return _op_add_insight(float(cmd.get("points", 0.0)))
		_:
			return _fail(CODE_BAD_COMMAND, "Unknown research op '%s'." % op)


func _op_start(id: StringName) -> Dictionary:
	var check: Dictionary = _can_start(id)
	if not bool(check.get("ok", false)):
		return check
	if id == _active:
		return _fail(CODE_BUSY, "Already working on it.")
	if String(_active) != "":
		_park_active("set aside for %s" % _title_of(id))
	_queue.erase(id)
	_begin(id, "ordered")
	return _ok({"id": String(id)})


func _op_queue(id: StringName) -> Dictionary:
	var n: ResearchNode = _graph.node(id)
	if n == null:
		return _fail(CODE_UNKNOWN, "No research node '%s'." % String(id))
	if _done.has(id):
		return _fail(CODE_DONE, "%s is already researched." % n.title)
	if id == _active or _queue.has(id):
		return _fail(CODE_BUSY, "%s is already scheduled." % n.title)
	# Queuing something locked is legal and useful: the queue can hold a whole
	# path, and prerequisites already in the queue satisfy it in order.
	_queue.append(id)
	if String(_active) == "":
		_pull_next()
	return _ok({"id": String(id), "position": _queue.find(id) + 1})


func _op_unqueue(id: StringName) -> Dictionary:
	if not _queue.has(id):
		return _fail(CODE_UNKNOWN, "Not in the queue.")
	_queue.erase(id)
	return _ok({"id": String(id)})


func _op_cancel(id: StringName) -> Dictionary:
	var n: ResearchNode = _graph.node(id)
	if n == null:
		return _fail(CODE_UNKNOWN, "No research node '%s'." % String(id))
	if _done.has(id):
		return _fail(CODE_DONE, "%s is finished; there is nothing to cancel." % n.title)
	_queue.erase(id)
	var p: ResearchProgress = _progress.get(id)
	var refund: Dictionary[StringName, int] = {}
	if p != null:
		var keys: Array = p.paid.keys()
		keys.sort()
		for k: StringName in keys:
			var back: int = int(floor(float(p.paid[k]) * CANCEL_REFUND))
			if back > 0:
				refund[k] = back
		_progress.erase(id)
	if not refund.is_empty():
		_ledger.give(refund)
	if id == _active:
		_active = &""
		_pull_next()
	Log.info(TAG, "abandoned '%s'%s" % [n.title,
		"" if refund.is_empty() else ", %s recovered" % _items_text(refund)])
	return _ok({"id": String(id), "refund": _items_json(refund)})


func _op_park() -> Dictionary:
	if String(_active) == "":
		return _fail(CODE_UNKNOWN, "Nothing is being researched.")
	var id: StringName = _active
	_park_active("set aside")
	return _ok({"id": String(id)})


func _op_complete(id: StringName) -> Dictionary:
	var n: ResearchNode = _graph.node(id)
	if n == null:
		return _fail(CODE_UNKNOWN, "No research node '%s'." % String(id))
	if _done.has(id):
		return _fail(CODE_DONE, "%s is already researched." % n.title)
	# Completing a node completes the path to it. A scenario that wants tier-3
	# defence should not have to spell out the seven nodes underneath.
	for prereq: StringName in _graph.ancestors(id):
		if not _done.has(prereq):
			_finish(prereq, true)
	_finish(id, true)
	return _ok({"id": String(id)})


func _op_grant(unlock: StringName) -> Dictionary:
	if String(unlock) == "":
		return _fail(CODE_BAD_COMMAND, "No unlock id given.")
	if _unlocked.has(unlock):
		return _ok({"unlock": String(unlock), "already": true})
	_open(unlock)
	Log.info(TAG, "granted unlock '%s'" % String(unlock))
	return _ok({"unlock": String(unlock)})


func _op_add_insight(points: float) -> Dictionary:
	if String(_active) == "":
		return _fail(CODE_UNKNOWN, "Nothing is being researched.")
	if points <= 0.0:
		return _fail(CODE_BAD_COMMAND, "Insight must be positive.")
	var n: ResearchNode = _graph.node(_active)
	var p: ResearchProgress = _progress.get(_active)
	if n == null or p == null:
		return _fail(CODE_UNKNOWN, "The active project vanished.")
	_apply_points(n, p, points)
	return _ok({"id": String(_active), "points": snappedf(p.points, 0.01)})


# ==========================================================================
#  THE TICK
# ==========================================================================

## Turns insight into progress, buys the next instalment when one falls due,
## and finishes the project when the work is done.
func _advance_active() -> void:
	var n: ResearchNode = _graph.node(_active)
	var p: ResearchProgress = _progress.get(_active)
	if n == null or p == null:
		_active = &""
		return
	_apply_points(n, p, _rate * SimClock.DT)
	if p.is_stalled():
		p.stalled_ticks += 1
		if _auto and p.stalled_ticks >= STALL_PARK_TICKS and _has_affordable_alternative():
			_park_active("no %s to be had" % _first_missing(p))


## Shared by the tick and by the debug insight command.
func _apply_points(n: ResearchNode, p: ResearchProgress, gain: float) -> void:
	if gain <= 0.0:
		return
	var target: float = minf(float(n.work), p.points + gain)
	# Pay every instalment the new progress crosses. A failed payment pins the
	# work at that boundary — the project cannot buy its way past what the yard
	# does not hold, and the shortfall is named on the node.
	while p.stage < ResearchProgress.STAGES:
		var due_at: float = ResearchProgress.stage_fraction(p.stage) * float(n.work)
		if target < due_at - 0.000001:
			break
		var owed: Dictionary[StringName, int] = _instalment(n, p)
		if owed.is_empty():
			p.stage += 1
			continue
		if not _ledger.take(owed):
			var short: Dictionary[StringName, int] = _ledger.missing(owed)
			if not p.is_stalled():
				_stall_events += 1
				_alert(1, ResearchDefs.KEY_STALLED, "%s is short of %s." % [n.title, _items_text(short)])
				Log.info(TAG, "'%s' stalled at %d%% — needs %s" % [
					n.title, int(p.fraction(n.work) * 100.0), _items_text(short)])
			p.missing = short
			# The work stops exactly at the instalment it cannot pay for. Insight
			# spent up to that line still counts; nothing past it does.
			var reached: float = clampf(due_at, p.points, target)
			_insight_total += reached - p.points
			p.points = reached
			return
		var keys: Array = owed.keys()
		keys.sort()
		for k: StringName in keys:
			p.paid[k] = int(p.paid.get(k, 0)) + int(owed[k])
		p.stage += 1
		p.clear_stall()
	if p.is_stalled():
		p.clear_stall()
	_insight_total += target - p.points
	p.points = target
	if p.points >= float(n.work) - 0.000001:
		_finish(n.id, false)


## The materials due for the instalment `stage`, net of what is already paid.
func _instalment(n: ResearchNode, p: ResearchProgress) -> Dictionary[StringName, int]:
	var upto: Dictionary[StringName, int] = n.cost_by_fraction(
		ResearchProgress.stage_fraction(p.stage + 1))
	var out: Dictionary[StringName, int] = {}
	var keys: Array = upto.keys()
	keys.sort()
	for k: StringName in keys:
		var owed: int = int(upto[k]) - int(p.paid.get(k, 0))
		if owed > 0:
			out[k] = owed
	return out


func _finish(id: StringName, forced: bool) -> void:
	var n: ResearchNode = _graph.node(id)
	if n == null or _done.has(id):
		return
	_done[id] = true
	_done_order.append(id)
	_completed_total += 1
	_effects.apply(n)
	for u: StringName in n.unlock_ids():
		_open(u)
	_queue.erase(id)
	if id == _active:
		_active = &""
	var p: ResearchProgress = _progress.get(id)
	if p != null:
		p.points = float(n.work)
		p.clear_stall()
	_available_dirty = true

	Bus.research_completed.emit(id)
	_alert(1, ResearchDefs.KEY_COMPLETED, "%s completed. %s" % [n.title, _payoff_text(n)])
	Bus.narrative_event.emit(ResearchDefs.KEY_COMPLETED, {
		"id": String(id),
		"title": n.title,
		"branch": String(n.branch),
		"tier": n.tier,
		"flavour": n.flavour,
		"unlocks": _ids_json(n.unlock_ids()),
		"effects": _effects_json(n),
		"forced": forced,
	})
	Log.info(TAG, "completed '%s'%s%s" % [n.title,
		"" if n.grants.is_empty() else " — opens %s" % ", ".join(_ids_json(n.grants)),
		" (granted)" if forced else ""])
	if not forced:
		_pull_next()


func _open(unlock: StringName) -> void:
	if String(unlock) == "" or _unlocked.has(unlock):
		return
	_unlocked[unlock] = true
	Bus.unlocked.emit(unlock)


## Starts the next project: the player's queue first, then whatever the pacing
## engine says the city most needs.
func _pull_next() -> void:
	if String(_active) != "":
		return
	while not _queue.is_empty():
		var id: StringName = _queue[0]
		if _done.has(id):
			_queue.remove_at(0)
			continue
		if not _prereqs_done(id):
			# A queued goal whose path is not walked yet is an instruction, not a
			# mistake: start the nearest missing prerequisite instead of stalling
			# or wandering off to something unrelated.
			var step_to: StringName = _next_step_toward(id)
			if String(step_to) != "":
				_queue.erase(step_to)
				_begin(step_to, "queued")
				return
			break
		_queue.remove_at(0)
		_begin(id, "queued")
		return
	if not _auto:
		return
	var pick: StringName = _auto_pick()
	if String(pick) != "":
		_begin(pick, "auto")


## The cheapest available prerequisite on the way to `goal`, or &"".
func _next_step_toward(goal: StringName) -> StringName:
	var best: StringName = &""
	var best_work: int = 0x7FFFFFFF
	for anc: StringName in _graph.ancestors(goal):
		if _done.has(anc) or not _prereqs_done(anc):
			continue
		var n: ResearchNode = _graph.node(anc)
		if n == null:
			continue
		if n.work < best_work or (n.work == best_work and String(anc) < String(best)):
			best_work = n.work
			best = anc
	return best


func _begin(id: StringName, how: String) -> void:
	var n: ResearchNode = _graph.node(id)
	if n == null:
		return
	var p: ResearchProgress = _progress.get(id)
	if p == null:
		p = ResearchProgress.new(id)
		p.started_tick = _tick
		_progress[id] = p
	else:
		p.resumes += 1
		p.clear_stall()
	_active = id
	Bus.research_started.emit(id)
	var why: String = _pacing.reason_for(n)
	if how == "auto":
		_alert(0, ResearchDefs.KEY_STARTED, "The engineers began %s. %s" % [n.title, why])
		Log.info(TAG, "auto-started '%s' — %s" % [n.title, why if why != "" else "next in the tree"])
	else:
		_alert(0, ResearchDefs.KEY_STARTED, "Research: %s." % n.title)
		Log.info(TAG, "started '%s' (%s), %d work, %s" % [
			n.title, how, n.work,
			"no cost" if n.cost.is_empty() else _items_text(n.total_cost())])


## Sets the active project aside with everything it has accumulated intact.
func _park_active(why: String) -> void:
	if String(_active) == "":
		return
	var n: ResearchNode = _graph.node(_active)
	var p: ResearchProgress = _progress.get(_active)
	if p != null:
		p.clear_stall()
	if n != null:
		Log.info(TAG, "parked '%s' at %d%% — %s" % [
			n.title, int(progress_of(_active) * 100.0), why])
		_alert(0, ResearchDefs.KEY_STALLED, "%s set aside — %s. The work so far is kept." % [n.title, why])
	_active = &""
	_pull_next()


## Idle is a decision point, not a bug — and it happens under auto as well, when
## the only things left need the player's signature.
func _nudge_if_idle() -> void:
	if _tick - _last_idle_nudge < IDLE_NUDGE_TICKS:
		return
	_ensure_available()
	if _available.is_empty():
		return
	_last_idle_nudge = _tick
	var s: Dictionary = _suggestion
	if s.is_empty():
		return
	var lead: String = "Your engineers have nothing to do."
	if bool(s.get("consent", false)):
		lead = "Your engineers will not start this one without you."
	_alert(1, ResearchDefs.KEY_IDLE, "%s %s" % [lead, String(s.get("reason", ""))])


# ==========================================================================
#  PACING
# ==========================================================================

## How much better a law has to look than the best honest answer before the
## tree will mention it at all. The dark branch is offered when the honest
## branches have visibly run out, not whenever its signal is loud.
const DARK_MARGIN: float = 2.5


## Recomputes the recommendation from the freshest sample.
##
## Two candidates are ranked separately: the best thing the engineers would do
## on their own, and the best thing that needs the player's signature. The
## honest one is the recommendation. The other is offered as an ALTERNATIVE, and
## only when it is decisively better — that is the difference between a game
## that tempts you and a game that nags you.
func _refresh_suggestion() -> void:
	_ensure_available()
	_suggestion = {}
	var best: StringName = &""
	var best_score: float = -1.0e9
	var dark: StringName = &""
	var dark_score: float = -1.0e9
	for id: StringName in _available:
		# The recommendation answers "what after this", so whatever is already on
		# the bench is not a candidate — and the half-finished bonus in
		# _score_of() cannot drown out a problem that appeared since.
		if id == _active:
			continue
		var s: float = _score_of(id)
		if ResearchDefs.needs_consent(_graph.node(id)):
			if s > dark_score + 0.0001:
				dark_score = s
				dark = id
		elif s > best_score + 0.0001:
			best_score = s
			best = id

	var chosen: StringName = best
	var chosen_score: float = best_score
	if String(best) == "" or best_score < ResearchPacing.SUGGEST_FLOOR:
		chosen = dark
		chosen_score = dark_score
	if String(chosen) == "" or chosen_score < ResearchPacing.SUGGEST_FLOOR:
		return

	_suggestion = _suggestion_row(chosen, chosen_score)
	if chosen == best and String(dark) != "" and dark_score > best_score + DARK_MARGIN:
		_suggestion["alternative"] = _suggestion_row(dark, dark_score)


func _suggestion_row(id: StringName, score: float) -> Dictionary:
	var n: ResearchNode = _graph.node(id)
	return {
		"id": String(id),
		"title": n.title,
		"branch": String(n.branch),
		"score": snappedf(score, 0.01),
		"signal": String(n.answers),
		"signal_value": snappedf(_pacing.value(n.answers), 0.001),
		"reason": _pacing.reason_for(n),
		"consent": ResearchDefs.needs_consent(n),
	}


## What the engineers start when nobody told them what to do. Deterministic:
## highest pacing score, ties broken by id.
##
## Two rounds on purpose. Engineers start what they can actually start, so the
## first round only considers projects whose opening instalment the yard can
## cover; a tree full of steel-hungry tier-3 nodes never leaves the city idle on
## day two. Only when nothing at all is affordable does the second round pick the
## most urgent project regardless — and that project then STALLS visibly, which
## is the correct message: you need a supply line before you need a technology.
func _auto_pick() -> StringName:
	_ensure_available()
	for round_i: int in 2:
		var best: StringName = &""
		var best_score: float = -1.0e9
		for id: StringName in _available:
			# The engineers never sign a law. See ResearchDefs.CONSENT_BRANCHES.
			if ResearchDefs.needs_consent(_graph.node(id)):
				continue
			if round_i == 0 and not _can_open(id):
				continue
			var s: float = _score_of(id)
			if s > best_score + 0.0001:
				best_score = s
				best = id
		if String(best) != "":
			return best
	return &""


## Can the yard cover this project's FIRST instalment right now?
func _can_open(id: StringName) -> bool:
	var n: ResearchNode = _graph.node(id)
	if n == null:
		return false
	var p: ResearchProgress = _progress.get(id)
	var stage: int = p.stage if p != null else 0
	if stage >= ResearchProgress.STAGES:
		return true
	var upto: Dictionary[StringName, int] = n.cost_by_fraction(
		ResearchProgress.stage_fraction(stage + 1))
	var owed: Dictionary[StringName, int] = {}
	var keys: Array = upto.keys()
	keys.sort()
	for k: StringName in keys:
		var need: int = int(upto[k]) - (int(p.paid.get(k, 0)) if p != null else 0)
		if need > 0:
			owed[k] = need
	return _ledger.can_afford(owed)


func _score_of(id: StringName) -> float:
	var n: ResearchNode = _graph.node(id)
	if n == null:
		return 0.0
	var affordable: bool = _ledger.can_afford(remaining_cost(id))
	var breadth: int = (_graph.dependents.get(id, []) as Array).size()
	var s: float = _pacing.score(n, affordable, breadth)
	# Work already invested pulls a project back to the front, so a parked
	# project resumes rather than being abandoned for a fresh one.
	var p: ResearchProgress = _progress.get(id)
	if p != null and p.points > 0.0:
		s += 1.2 * p.fraction(n.work)
	return s


func _has_affordable_alternative() -> bool:
	_ensure_available()
	for id: StringName in _available:
		if id == _active:
			continue
		if _ledger.can_afford(remaining_cost(id)):
			return true
	return false


# ==========================================================================
#  INSIGHT RATE
# ==========================================================================

## How fast the city thinks. Workshops and labs do the work, heat keeps their
## hands warm enough to hold a pencil, and the deep cold takes it back.
func _recompute_rate() -> void:
	var labs: int = 0
	var shops: int = 0
	var b: Object = _live(_build)
	if b != null:
		labs = _running_with_tag(b, &"research")
		shops = _running_with_tag(b, &"crafter")
	var raw: float = BASE_INSIGHT + float(labs) * INSIGHT_PER_LAB + float(shops) * INSIGHT_PER_WORKSHOP

	var served: float = 1.0
	var h: Object = _live(_heat)
	if h != null:
		var t: Dictionary = h.call("totals")
		var demand: float = float(t.get("demand", 0.0))
		if demand > 0.001:
			served = clampf(float(t.get("delivered", 0.0)) / demand, 0.0, 1.0)
	var heat_factor: float = lerpf(COLD_HANDS_FLOOR, 1.0, served)

	var cold_factor: float = 1.0
	var c: Object = _live(_climate)
	if c != null:
		var ambient: float = float(c.call("ambient_temperature"))
		var bite: float = clampf((COLD_START_C - ambient) / COLD_SPAN_C, 0.0, 1.0)
		cold_factor = lerpf(1.0, COLD_HANDS_FLOOR, bite)

	_rate = maxf(0.05, raw * heat_factor * cold_factor
			* _effects.multiplier(ResearchDefs.E_RESEARCH_SPEED_MULT))
	_rate_reason = "%d lab(s), %d workshop(s), heat %d%%, cold %d%%" % [
		labs, shops, int(heat_factor * 100.0), int(cold_factor * 100.0)]


func _running_with_tag(build: Object, tag: StringName) -> int:
	var arr: Array = build.call("buildings_with_tag", tag)
	var n: int = 0
	for entry: Variant in arr:
		var inst: Object = entry
		if inst != null and inst.has_method("is_running") and bool(inst.call("is_running")):
			n += 1
	return n


# ==========================================================================
#  AVAILABILITY
# ==========================================================================

func _ensure_available() -> void:
	if not _available_dirty:
		return
	_available_dirty = false
	_available.clear()
	for id: StringName in _graph.ids:
		if _done.has(id):
			continue
		if _prereqs_done(id):
			_available.append(id)


func _prereqs_done(id: StringName) -> bool:
	for p: StringName in _graph.prereqs.get(id, []):
		if not _done.has(p):
			return false
	return true


func _can_start(id: StringName) -> Dictionary:
	var n: ResearchNode = _graph.node(id)
	if n == null:
		return _fail(CODE_UNKNOWN, "No research node '%s'." % String(id))
	if _done.has(id):
		return _fail(CODE_DONE, "%s is already researched." % n.title)
	if not _prereqs_done(id):
		var waiting: Array[String] = []
		for p: StringName in _graph.prereqs.get(id, []):
			if not _done.has(p):
				waiting.append(_title_of(p))
		return _fail(CODE_LOCKED, "%s needs %s first." % [n.title, ", ".join(waiting)])
	return _ok({})


func _state_of(id: StringName, is_available: bool) -> int:
	if _done.has(id):
		return ResearchDefs.State.DONE
	if id == _active:
		return ResearchDefs.State.ACTIVE
	if _queue.has(id):
		return ResearchDefs.State.QUEUED
	var p: ResearchProgress = _progress.get(id)
	if p != null and p.points > 0.0:
		return ResearchDefs.State.PARKED
	return ResearchDefs.State.AVAILABLE if is_available else ResearchDefs.State.LOCKED


func _eta_of(id: StringName) -> float:
	if _done.has(id):
		return 0.0
	var n: ResearchNode = _graph.node(id)
	if n == null:
		return -1.0
	var p: ResearchProgress = _progress.get(id)
	var left: float = float(n.work) - (p.points if p != null else 0.0)
	return maxf(0.0, left) / maxf(0.0001, _rate)


# ==========================================================================
#  SERIALIZATION
# ==========================================================================

func serialize() -> Dictionary:
	var progress: Array = []
	var pkeys: Array = _progress.keys()
	pkeys.sort()
	for k: StringName in pkeys:
		progress.append((_progress[k] as ResearchProgress).to_dict())

	var board: Array = []
	_ensure_available()
	var avail: Dictionary[StringName, bool] = {}
	for a: StringName in _available:
		avail[a] = true
	for id: StringName in _graph.ids:
		var st: int = _state_of(id, avail.has(id))
		if st == ResearchDefs.State.LOCKED:
			continue
		board.append({
			"id": String(id),
			"state": ResearchDefs.state_name(st),
			"progress": snappedf(progress_of(id), 0.001),
		})

	return {
		"researched": _ids_json(_done_order),
		"researched_count": _done_order.size(),
		"active": String(_active),
		"progress": snappedf(progress_of(_active), 0.001) if String(_active) != "" else 0.0,
		"queue": _ids_json(_queue),
		"auto": _auto,
		"rate": snappedf(_rate, 0.01),
		"rate_reason": _rate_reason,
		"insight_total": snappedf(_insight_total, 0.1),
		"stall_events": _stall_events,
		"unlocked": _ids_json(unlocked_ids()),
		"laws": _ids_json(unlocked_laws()),
		"recipes": _ids_json(unlocked_recipes()),
		"effects": _effects.snapshot(),
		"available": _ids_json(_available),
		"suggestion": _suggestion.duplicate(true),
		"pacing": _pacing.snapshot(),
		"records": progress,
		"board": board,
		"ledger": String(_ledger.source()),
		"nodes_total": _graph.size(),
	}


func deserialize(data: Dictionary) -> void:
	_done.clear()
	_done_order.clear()
	_unlocked.clear()
	_progress.clear()
	_queue.clear()
	_effects.clear()
	_active = &""
	_available_dirty = true

	for raw: Variant in data.get("researched", []):
		var id: StringName = StringName(String(raw))
		if not _graph.has(id) or _done.has(id):
			continue
		_done[id] = true
		_done_order.append(id)
		var n: ResearchNode = _graph.node(id)
		_effects.apply(n)
		for u: StringName in n.unlock_ids():
			_unlocked[u] = true
	# Granted unlocks that no node produced (tutorial, narrative) survive too.
	for raw2: Variant in data.get("unlocked", []):
		_unlocked[StringName(String(raw2))] = true

	for raw3: Variant in data.get("records", []):
		if typeof(raw3) != TYPE_DICTIONARY:
			continue
		var p: ResearchProgress = ResearchProgress.from_dict(raw3)
		if _graph.has(p.id) and not _done.has(p.id):
			_progress[p.id] = p

	for raw4: Variant in data.get("queue", []):
		var qid: StringName = StringName(String(raw4))
		if _graph.has(qid) and not _done.has(qid) and not _queue.has(qid):
			_queue.append(qid)

	_auto = bool(data.get("auto", true))
	_completed_total = _done_order.size()
	_stall_events = int(data.get("stall_events", 0))
	_insight_total = float(data.get("insight_total", 0.0))

	var want: StringName = StringName(String(data.get("active", "")))
	if _graph.has(want) and not _done.has(want) and _prereqs_done(want):
		_active = want
		if not _progress.has(want):
			_progress[want] = ResearchProgress.new(want)
	Log.info(TAG, "restored %d researched, %d in progress, active '%s'" % [
		_done_order.size(), _progress.size(), String(_active)])


func metrics() -> Dictionary:
	_ensure_available()
	return {
		"researched_count": _done_order.size(),
		"active": String(_active),
		"progress": snappedf(progress_of(_active), 0.001) if String(_active) != "" else 0.0,
		"unlocks_pending": _available.size(),
		"unlocked_total": _unlocked.size(),
		"rate": snappedf(_rate, 0.01),
		"stalled": 1 if _is_active_stalled() else 0,
		"queued": _queue.size(),
		"insight_total": snappedf(_insight_total, 0.1),
	}


# ==========================================================================
#  INTERNALS — small helpers
# ==========================================================================

func _is_active_stalled() -> bool:
	if String(_active) == "":
		return false
	var p: ResearchProgress = _progress.get(_active)
	return p != null and p.is_stalled()


func _first_missing(p: ResearchProgress) -> String:
	var keys: Array = p.missing.keys()
	keys.sort()
	if keys.is_empty():
		return "materials"
	return String(keys[0]).replace("_", " ")


func _title_of(id: StringName) -> String:
	var n: ResearchNode = _graph.node(id)
	return n.title if n != null else String(id)


func _payoff_text(n: ResearchNode) -> String:
	var parts: Array[String] = []
	if not n.grants.is_empty():
		parts.append("Opens " + ", ".join(_pretty_ids(n.grants)) + ".")
	var ekeys: Array = n.effects.keys()
	ekeys.sort()
	if not ekeys.is_empty():
		parts.append(n.flavour if n.flavour != "" else "")
	var out: String = " ".join(parts).strip_edges()
	return out if out != "" else n.flavour


func _pretty_ids(ids: Array[StringName]) -> Array[String]:
	var out: Array[String] = []
	for id: StringName in ids:
		var s: String = String(id)
		if s.begins_with(ResearchDefs.PREFIX_LAW):
			s = s.substr(ResearchDefs.PREFIX_LAW.length())
		elif s.begins_with(ResearchDefs.PREFIX_RECIPE):
			s = s.substr(ResearchDefs.PREFIX_RECIPE.length())
		out.append(s.replace("_", " "))
	return out


func _unlocked_with(prefix: String) -> Array[StringName]:
	var keys: Array = _unlocked.keys()
	keys.sort()
	var out: Array[StringName] = []
	for k: StringName in keys:
		if String(k).begins_with(prefix):
			out.append(k)
	return out


func _items_text(items: Dictionary[StringName, int]) -> String:
	var keys: Array = items.keys()
	keys.sort()
	var parts: Array[String] = []
	for k: StringName in keys:
		parts.append("%d %s" % [int(items[k]), String(k).replace("_", " ")])
	return ", ".join(parts)


func _items_json(items: Dictionary[StringName, int]) -> Dictionary:
	var out: Dictionary = {}
	var keys: Array = items.keys()
	keys.sort()
	for k: StringName in keys:
		out[String(k)] = int(items[k])
	return out


func _effects_json(n: ResearchNode) -> Dictionary:
	var out: Dictionary = {}
	var keys: Array = n.effects.keys()
	keys.sort()
	for k: Variant in keys:
		out[String(k)] = snappedf(float(n.effects[k]), 0.0001)
	return out


func _ids_json(ids: Array) -> Array:
	var out: Array = []
	for id: Variant in ids:
		out.append(String(id))
	return out


func _id_of(cmd: Dictionary) -> StringName:
	return StringName(String(cmd.get("id", cmd.get("node", ""))))


func _ok(extra: Dictionary) -> Dictionary:
	var out: Dictionary = {"ok": true, "code": String(CODE_OK)}
	var keys: Array = extra.keys()
	keys.sort()
	for k: Variant in keys:
		out[String(k)] = extra[k]
	return out


func _fail(code: StringName, reason: String) -> Dictionary:
	return {"ok": false, "code": String(code), "reason": reason}


## Severity is capped at 1: the harness fails a run on Bus severity >= 2, and a
## research message is never a run failure.
func _alert(severity: int, key: StringName, text: String) -> void:
	Bus.alert_raised.emit(clampi(severity, 0, ResearchDefs.MAX_BUS_SEVERITY), key, text, Vector2.ZERO)


func _wref(o: Object) -> WeakRef:
	return weakref(o) if o != null else null


func _live(w: WeakRef) -> Object:
	if w == null:
		return null
	return w.get_ref()


# ==========================================================================
#  LAYOUT CACHE — the half of tree_layout() that never changes
# ==========================================================================

func _build_layout_cache() -> void:
	var nodes: Array = []
	for id: StringName in _graph.ids:
		var n: ResearchNode = _graph.node(id)
		var pos: Vector2i = _graph.placement.get(id, Vector2i.ZERO)
		nodes.append({
			"id": String(id),
			"title": n.title,
			"description": n.description,
			"flavour": n.flavour,
			"branch": String(n.branch),
			"tier": n.tier,
			"column": pos.x,
			"row": pos.y,
			"depth": int(_graph.depth.get(id, 0)),
			"work": n.work,
			"cost": _items_json(n.total_cost()),
			"prereqs": _ids_json(_graph.prereqs.get(id, [])),
			"leads_to": _ids_json(_graph.dependents.get(id, [])),
			"grants": _ids_json(n.grants),
			"unlocks": _ids_json(n.unlock_ids()),
			"effects": _effects_json(n),
			"answers": String(n.answers),
			"urgency": n.urgency_line,
			"icon": n.icon_path,
			# State fields, overwritten on every tree_layout() call. Present here
			# so the shape of a node row never changes between calls.
			"state": ResearchDefs.state_name(ResearchDefs.State.LOCKED),
			"state_index": int(ResearchDefs.State.LOCKED),
			"progress": 0.0,
			"points": 0.0,
			"paid": {},
			"missing": {},
			"remaining_cost": {},
			"affordable": false,
			"eta_seconds": -1.0,
			"score": 0.0,
			"reason": "",
		})

	var branches: Array = []
	var keys: Array = _graph.bands.keys()
	keys.sort_custom(func(a: StringName, b: StringName) -> bool:
		var ia: int = ResearchDefs.branch_index(a)
		var ib: int = ResearchDefs.branch_index(b)
		if ia != ib:
			return ia < ib
		return String(a) < String(b))
	for key2: StringName in keys:
		var band: Vector2i = _graph.bands[key2]
		var color: Color = ResearchDefs.BRANCH_COLORS.get(key2, Color(0.7, 0.7, 0.7))
		branches.append({
			"key": String(key2),
			"title": ResearchDefs.branch_title(key2),
			"summary": String(ResearchDefs.BRANCH_SUMMARIES.get(key2, "")),
			"color": [snappedf(color.r, 0.001), snappedf(color.g, 0.001), snappedf(color.b, 0.001)],
			"row_start": band.x,
			"row_end": band.y,
			"total": 0,
			"done": 0,
			"available": 0,
		})

	_layout_cache = {
		"columns": _graph.columns,
		"rows": _graph.rows,
		"branches": branches,
		"nodes": nodes,
		"edges": _graph.edges(),
	}
