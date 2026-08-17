extends Node
## Root of the simulation world. Holds every SimSystem, owns creation and teardown.
##
## Parts register their system here by adding a line to _SYSTEM_SCRIPTS below —
## this is the ONE shared list, kept tiny and append-only on purpose. Everything
## else (buildings, recipes, enemies, laws) registers by directory scan instead.

## Append-only. One line per part. Order in this array is irrelevant —
## SimSystem.order decides tick order.
const _SYSTEM_SCRIPTS: Array[String] = [
	"res://game/sim/climate/climate_system.gd",
	"res://game/sim/grid/grid_system.gd",
	"res://game/sim/heat/heat_system.gd",
	"res://game/sim/logistics/logistics_system.gd",
	"res://game/sim/production/production_system.gd",
	"res://game/sim/citizens/citizen_system.gd",
	"res://game/sim/society/society_system.gd",
	"res://game/sim/threat/threat_system.gd",
	"res://game/sim/combat/combat_system.gd",
	"res://game/sim/research/research_system.gd",
	"res://game/sim/build/build_system.gd",
]

var systems: Array[SimSystem] = []
var by_name: Dictionary[StringName, SimSystem] = {}
var alive: bool = false

var _commands: Array[Dictionary] = []

# --- per-system tick profiling ------------------------------------------------
# Nobody could attribute a millisecond of the tick budget to a system, so every
# optimisation argument was a guess. This measures it. It is wall-clock and it
# NEVER reaches serialize(), metrics() or any decision the sim makes, so a replay
# stays byte-identical with it on — tools/determinism.sh is the proof, not this
# comment. Cost is two Time.get_ticks_usec() calls per system per tick, ~0.5 us
# against a 24 ms tick, which is why it is on by default: attribution that is
# always there beats a knob nobody turns.
var profile_enabled: bool = true

var _prof_us: PackedInt64Array = PackedInt64Array()
var _prof_peak_us: PackedInt64Array = PackedInt64Array()
var _prof_calls: PackedInt64Array = PackedInt64Array()
var _prof_ticks: int = 0
var _prof_cmd_us: int = 0
var _prof_total_us: int = 0


## Quitting is a teardown too.
##
## Nothing used to destroy the world on the way out — `create_world` tears down
## the PREVIOUS world, so a process that builds one world and then exits never
## calls teardown at all. The engine frees this autoload, its `systems` array
## goes with it, and the eleven systems keep each other alive anyway (see
## `_release_world`), so every run ended with the whole world resident and Godot
## reported it: 813 ObjectDB instances and 269 resources still in use, on every
## quit, allowlisted since nobody had chased them down.
##
## The players' version of that report is a Steam build that leaks a world every
## time it is closed. This is the line that stops it.
func _exit_tree() -> void:
	teardown()


## Creates a fresh world. Everything before this point is inert.
func create_world(world_seed: int) -> void:
	teardown()
	Rng.reset(world_seed)
	SimClock.reset()
	Bus.world_created.emit(world_seed)

	for path: String in _SYSTEM_SCRIPTS:
		if not ResourceLoader.exists(path):
			Log.debug("sim", "system not present yet: %s" % path)
			continue
		# A script that does not COMPILE loads as null, and `null.new()` used to
		# abort create_world half way through the list: the engine printed one
		# error nothing was counting, `alive` never became true, and the game
		# came up with a renderer, a HUD and no world at all — looking for all
		# the world like a rendering bug. Name the pillar that is missing and
		# keep building the rest, so the run says what is wrong on line one.
		var scr: Script = load(path) as Script
		if scr == null:
			Log.error("sim", "%s failed to compile — that whole pillar is ABSENT from this world" % path)
			continue
		var s: SimSystem = scr.new() as SimSystem
		if s == null:
			Log.error("sim", "%s did not produce a SimSystem — pillar ABSENT from this world" % path)
			continue
		systems.append(s)
		by_name[s.system_name()] = s

	# Sorted THREE times on purpose. A system may legitimately decide its order in
	# _init(), in setup() or while wiring itself in post_setup(); sorting only once
	# up front silently ticked heat behind logistics and production for a whole
	# phase, so every consumer read last tick's power factor. Re-sorting is O(n log n)
	# on eleven elements, once per world, and it makes the declared order true.
	_sort_by_order()
	for s: SimSystem in systems:
		s.setup()
	_sort_by_order()
	for s: SimSystem in systems:
		s.post_setup()
	_sort_by_order()

	alive = true
	profile_reset()
	Log.info("sim", "world created, seed=%d, systems=%d" % [world_seed, systems.size()])
	Bus.world_ready.emit()


## Tie-broken by system name so two parts claiming the same order still produce
## one stable, replayable tick sequence.
func _sort_by_order() -> void:
	systems.sort_custom(func(a: SimSystem, b: SimSystem) -> bool:
		if a.order != b.order:
			return a.order < b.order
		return String(a.system_name()) < String(b.system_name()))


## Destroys the world. Called before every create_world, and it has to actually
## destroy it — see _release_world for why clearing the array is not enough.
func teardown() -> void:
	var departing: Array[SimSystem] = systems.duplicate()
	systems.clear()
	by_name.clear()
	_commands.clear()
	alive = false
	if departing.is_empty():
		return
	for s: SimSystem in departing:
		s.teardown()
	_release_world(departing)


## Breaks the reference cycle between sim systems so the old world can be freed.
##
## Every system holds its neighbours: heat points at build, build points at
## citizens, citizens point back at heat, and their helper objects point at
## systems too (`CitizenRouter._grid`, `CitizenJobBoard._build`). A SimSystem is
## RefCounted and GDScript has no cycle collector, so that ring keeps itself
## alive for the life of the process no matter what this array does.
##
## Measured before this existed, with three worlds built and torn down in one
## process: 2030 objects at rest, 2333 after the first world, and 2287 · 2471 ·
## 2655 after each teardown — every world ever created still resident, plus the
## content Resources its definition tables held. That is ~184 objects and a
## quarter of the registry per load of a save game, which is why an at-exit
## number in the hundreds was never the whole story: the count grows while the
## game is running.
##
## The walk visits every plain RefCounted reachable from a departing system and
## nulls any property pointing back INTO the departing set. It deliberately does
## not follow Resources or Nodes: a content definition is shared with Registry and
## outlives the world, and a Node is somebody else's tree. Each system's own data
## is left alone — once nothing points at a system, its own objects fall with it.
##
## Parts that would rather do this themselves override `SimSystem.teardown()`,
## which runs first; this is the net underneath, and it is what makes a part that
## has not thought about teardown harmless rather than a leak.
func _release_world(departing: Array[SimSystem]) -> void:
	var doomed: Dictionary[int, bool] = {}
	for s: SimSystem in departing:
		doomed[s.get_instance_id()] = true
	var seen: Dictionary[int, bool] = {}
	var frontier: Array[Object] = []
	for s: SimSystem in departing:
		frontier.append(s)
	while not frontier.is_empty():
		var owner_obj: Object = frontier.pop_back()
		if owner_obj == null or not is_instance_valid(owner_obj):
			continue
		var id: int = owner_obj.get_instance_id()
		if seen.has(id):
			continue
		seen[id] = true
		for p: Dictionary in owner_obj.get_property_list():
			if int(p.get("usage", 0)) & PROPERTY_USAGE_SCRIPT_VARIABLE == 0:
				continue
			var name: String = String(p.get("name", ""))
			var value: Variant = owner_obj.get(name)
			if value is Array:
				_release_array(value, doomed, frontier)
				continue
			if value is Dictionary:
				_release_dict(value, doomed, frontier)
				continue
			if not (value is Object):
				continue
			var target: Object = value
			if target == null or not is_instance_valid(target):
				continue
			if doomed.has(target.get_instance_id()):
				owner_obj.set(name, null)
			elif _is_plain_ref(target):
				frontier.append(target)


## A system reference can also sit in a list — a roster of neighbours, a pending
## queue. Nulling the slot is enough: the world it belonged to is already gone.
func _release_array(arr: Array, doomed: Dictionary[int, bool], frontier: Array[Object]) -> void:
	for i: int in arr.size():
		var v: Variant = arr[i]
		if not (v is Object):
			continue
		var target: Object = v
		if target == null or not is_instance_valid(target):
			continue
		if doomed.has(target.get_instance_id()):
			arr[i] = null
		elif _is_plain_ref(target):
			frontier.append(target)


func _release_dict(d: Dictionary, doomed: Dictionary[int, bool], frontier: Array[Object]) -> void:
	# Keys sorted for the same reason every other iteration here is: two runs of
	# the same teardown must do the same things in the same order.
	var keys: Array = d.keys()
	keys.sort()
	for k: Variant in keys:
		var v: Variant = d[k]
		if not (v is Object):
			continue
		var target: Object = v
		if target == null or not is_instance_valid(target):
			continue
		if doomed.has(target.get_instance_id()):
			d[k] = null
		elif _is_plain_ref(target):
			frontier.append(target)


## Worth walking into: a part's own helper object. NOT a Resource (Registry owns
## those and they outlive the world) and NOT a Node (somebody else's tree).
func _is_plain_ref(o: Object) -> bool:
	return o is RefCounted and not (o is Resource)


## Typed accessor. `Sim.get_system(&"heat")` — returns null if the part is absent,
## so parts must tolerate a missing dependency during parallel development.
func get_system(n: StringName) -> SimSystem:
	return by_name.get(n)


## The ONLY way view/ and ui/ change simulation state. Queued, applied at the
## start of the next tick, so a click mid-frame cannot desync a replay.
func submit_command(cmd: Dictionary) -> void:
	_commands.append(cmd)


## Called by SimClock. Not for general use.
func _advance(tick: int) -> void:
	if not alive:
		return
	var t_tick0: int = Time.get_ticks_usec() if profile_enabled else 0
	if not _commands.is_empty():
		var pending: Array[Dictionary] = _commands.duplicate()
		_commands.clear()
		for c: Dictionary in pending:
			var target: SimSystem = by_name.get(c.get("system", &""))
			if target != null and target.has_method("handle_command"):
				target.call("handle_command", c)
			else:
				# ERROR, not warn. A command addressed to a system this build does
				# not have is a broken script, and a broken script that only warns
				# is how a scenario ends up three-quarters no-op and still exit 0.
				Log.error("sim", "command for absent system '%s' (op '%s') was dropped" % [
					str(c.get("system", "?")), str(c.get("op", "?"))])
	if not profile_enabled:
		for s: SimSystem in systems:
			if s.enabled:
				s.step(tick)
		return

	var n: int = systems.size()
	if _prof_us.size() != n:
		_prof_resize(n)
	_prof_cmd_us += Time.get_ticks_usec() - t_tick0
	_prof_ticks += 1
	for i: int in n:
		var s: SimSystem = systems[i]
		if not s.enabled:
			continue
		var t0: int = Time.get_ticks_usec()
		s.step(tick)
		var used: int = Time.get_ticks_usec() - t0
		_prof_us[i] += used
		_prof_calls[i] += 1
		if used > _prof_peak_us[i]:
			_prof_peak_us[i] = used
	_prof_total_us += Time.get_ticks_usec() - t_tick0


func _prof_resize(n: int) -> void:
	_prof_us.resize(n)
	_prof_peak_us.resize(n)
	_prof_calls.resize(n)


## Clears the profile counters. Called on world creation; call it again after a
## warm-up stretch when you only want the steady state measured.
func profile_reset() -> void:
	_prof_resize(systems.size())
	_prof_us.fill(0)
	_prof_peak_us.fill(0)
	_prof_calls.fill(0)
	_prof_ticks = 0
	_prof_cmd_us = 0
	_prof_total_us = 0


## Per-system tick cost since the last profile_reset(). Wall clock, in
## milliseconds, plus each system's share of the measured tick. Never feed this
## back into simulation state — it is an observation of the machine, not of the
## world.
func profile_report() -> Dictionary:
	var ticks: int = maxi(1, _prof_ticks)
	var rows: Array[Dictionary] = []
	var sum_us: int = 0
	for i: int in mini(systems.size(), _prof_us.size()):
		sum_us += _prof_us[i]
	var denom: float = float(maxi(1, sum_us + _prof_cmd_us))
	for i: int in mini(systems.size(), _prof_us.size()):
		var s: SimSystem = systems[i]
		rows.append({
			"system": String(s.system_name()),
			"order": s.order,
			"ms_per_tick": snappedf(float(_prof_us[i]) / float(ticks) / 1000.0, 0.0001),
			"peak_ms": snappedf(float(_prof_peak_us[i]) / 1000.0, 0.0001),
			"total_ms": snappedf(float(_prof_us[i]) / 1000.0, 0.1),
			"share": snappedf(float(_prof_us[i]) / denom, 0.0001),
			"ticked": _prof_calls[i],
		})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["ms_per_tick"]) > float(b["ms_per_tick"]))
	return {
		"ticks": _prof_ticks,
		"sim_ms_per_tick": snappedf(float(_prof_total_us) / float(ticks) / 1000.0, 0.0001),
		"systems_ms_per_tick": snappedf(float(sum_us) / float(ticks) / 1000.0, 0.0001),
		"commands_ms_per_tick": snappedf(float(_prof_cmd_us) / float(ticks) / 1000.0, 0.0001),
		"budget_ms": 1000.0 / float(SimClock.TICK_HZ),
		"systems": rows,
	}


func serialize() -> Dictionary:
	var out: Dictionary = {"tick": SimClock.tick, "seed": Rng.seed_value, "rng": Rng.snapshot()}
	var sys: Dictionary = {}
	for s: SimSystem in systems:
		sys[String(s.system_name())] = s.serialize()
	out["systems"] = sys
	return out


## Rebuilds this world from a `serialize()` payload — and checks its own work.
##
## The contract is one sentence: after `Sim.deserialize(w)` returns true,
## `Sim.serialize()` equals `w`. Not "close enough to converge in a tick", not
## "everything anybody remembered to write a reader for". Equal. Determinism is
## §0.4's non-negotiable and a save is the one place a player leaves the
## simulation and comes back to it, so a reload that lands somewhere else is the
## same defect as a `randf()` in a step function, just slower to notice.
##
## The order is load-bearing and every step of it was paid for:
##
##   1. `create_world(seed)` first, so every cross-system reference is wired
##      before a single value lands on it;
##   2. `SimClock.tick` BEFORE the systems, because several of them stamp the
##      current tick into what they rebuild;
##   3. systems deserialize in SORTED name order, so a load is as replayable as
##      the run that produced it;
##   4. `LcnStateReconciler` puts back what step 3 dropped — every system's
##      `serialize()` is compared against the payload it was handed and the
##      difference is hunted down to the variable it came from, then ratified by
##      re-serializing. See that file for why this is a measurement and not a
##      hand-written mapping table;
##   5. `Rng.restore()` LAST, because `create_world` reseeds every stream and
##      because a `serialize()` call in step 4 may itself have drawn one.
##
## Returns `{ok, restored, absent, repaired, unrestored, systems_incomplete}`.
## `unrestored` is the honest residue: fields that were in the save and are not
## in the world. It is empty on this build and a test says so; if it ever is not,
## it names the field and the part rather than being written down in a list of
## exceptions somewhere.
func deserialize(world: Dictionary) -> Dictionary:
	var report: Dictionary = {
		"ok": false, "restored": PackedStringArray(), "absent": PackedStringArray(),
		"repaired": PackedStringArray(), "unrestored": PackedStringArray(),
		"systems_incomplete": PackedStringArray(),
	}
	var blob: Variant = world.get("systems", {})
	if typeof(blob) != TYPE_DICTIONARY or (blob as Dictionary).is_empty():
		# A world with no systems in it is not a world. Refusing it here is what
		# lets a caller hand this function a corrupt file without the running
		# city being torn down before the problem is noticed.
		Log.error("sim", "load: the payload carries no systems block — refusing it")
		return report

	var payloads: Dictionary = blob
	var names: Array = payloads.keys()
	names.sort()

	create_world(int(world.get("seed", 7)))
	SimClock.tick = int(world.get("tick", 0))

	# PackedStringArray is a value type: appending through `report["x"]` appends
	# to a copy. Collect locally, assign once.
	var restored: PackedStringArray = PackedStringArray()
	var absent: PackedStringArray = PackedStringArray()
	var repaired: PackedStringArray = PackedStringArray()
	var unrestored: PackedStringArray = PackedStringArray()
	var incomplete: PackedStringArray = PackedStringArray()

	# TWICE, and the second pass is not superstition. Systems are restored in name
	# order, so `society` rebuilds its pressure ledger while `threat` is still the
	# empty world `create_world` just made — and society samples the night the
	# threat director has planned. Every `deserialize()` in this build clears what
	# it rebuilds, so a second pass is a no-op for every system that does not read
	# a neighbour, and the difference for the ones that do is measured:
	# `$.systems.society.forces` comes back only on the second pass.
	for _pass: int in LcnStateReconciler.RESTORE_PASSES:
		for n: String in names:
			var sys: SimSystem = get_system(StringName(n))
			if sys == null:
				if _pass == 0:
					absent.append(n)
				continue
			if typeof(payloads[n]) != TYPE_DICTIONARY:
				continue
			sys.deserialize(payloads[n])
			if _pass == 0:
				restored.append(n)

	# Then finish the job, until it stops getting better. One system's repair can
	# unlock another's — putting a citizen's morale back changes the average the
	# citizens system reports — so the sweep repeats while anything is still
	# moving, and stops the moment it is not.
	var mended: Dictionary[String, bool] = {}
	var last_left: int = -1
	for _round: int in LcnStateReconciler.RECONCILE_ROUNDS:
		unrestored.clear()
		incomplete.clear()
		for n2: String in names:
			var sys2: SimSystem = get_system(StringName(n2))
			if sys2 == null or typeof(payloads[n2]) != TYPE_DICTIONARY:
				continue
			var rep: Dictionary = LcnStateReconciler.finish(sys2, payloads[n2])
			for f: String in (rep["fixed"] as PackedStringArray):
				mended["$.systems.%s%s" % [n2, f.substr(1)]] = true
			var left: PackedStringArray = rep["left"]
			if left.is_empty():
				continue
			incomplete.append(n2)
			for f2: String in left:
				unrestored.append("$.systems.%s%s" % [n2, f2.substr(1)])
		if unrestored.size() == last_left:
			break
		last_left = unrestored.size()
	var mended_keys: Array = mended.keys()
	mended_keys.sort()
	for k: String in mended_keys:
		repaired.append(k)

	report["restored"] = restored
	report["absent"] = absent
	report["repaired"] = repaired
	report["unrestored"] = unrestored
	report["systems_incomplete"] = incomplete

	# Last, and after every serialize() this function performs.
	var rng_blob: Variant = world.get("rng", {})
	if typeof(rng_blob) == TYPE_DICTIONARY:
		Rng.restore(rng_blob)

	if not absent.is_empty():
		# Not a warning. A save naming a pillar this build does not have means the
		# player is loading a city that cannot come back the way it went in.
		Log.error("sim", "load: this build has no %s system(s) — that state is LOST" % [
			", ".join(absent)])
	if not unrestored.is_empty():
		Log.warn("sim", "load: %d field(s) did not come back: %s" % [
			unrestored.size(), " ".join(unrestored)])
	report["ok"] = true
	Log.info("sim", "loaded tick %d, seed %d, %d system(s), %d field(s) repaired, %d lost" % [
		SimClock.tick, Rng.seed_value, restored.size(), repaired.size(), unrestored.size()])
	Bus.world_ready.emit()
	return report


func collect_metrics() -> Dictionary:
	var out: Dictionary = {"tick": SimClock.tick}
	for s: SimSystem in systems:
		var m: Dictionary = s.metrics()
		for k: String in m:
			out["%s.%s" % [s.system_name(), k]] = m[k]
	return out
