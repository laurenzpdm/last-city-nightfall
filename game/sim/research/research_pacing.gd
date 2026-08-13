class_name ResearchPacing
extends RefCounted
## The part of [P10] that makes the tree a conversation instead of a shopping list.
##
## A tech tree fails when it is a menu the player scrolls at their leisure. It
## works when every unlock lands on the night it is needed. You cannot author
## that with static ordering, because the player's base is not the one you
## imagined — so the tree is authored with an ANSWER on every node
## (ResearchNode.answers, one of ResearchDefs.SIG_*) and this class measures,
## from the live simulation, how loudly each of those problems is being asked.
##
## Every sample it produces:
##   * signals   — twenty measurements of "what hurts", each 0..1
##   * details   — the human phrasing of each measurement, with the number in it
##   * sources   — whether a signal was MEASURED from a live system or is a
##                 campaign-clock PROXY because that part has not landed yet.
##                 Shipped in state.json so a critic can tell the difference.
##
## Nothing here writes simulation state. It reads other systems defensively,
## through name probes, and produces a ranking. The system decides what to do
## with it.

## Weight of the primary answer in the score. Dominates tier and breadth on
## purpose: an urgent answer must outrank a cheap irrelevance.
const W_PRIMARY: float = 4.0
const W_SECONDARY: float = 1.6
## Preference for something that can be paid for right now.
const W_AFFORDABLE: float = 0.9
## Small pull toward nodes that open more of the tree, so the auto-picker does
## not walk into a dead end while a whole branch waits on one cheap prerequisite.
const W_BREADTH: float = 0.08
const MAX_BREADTH: int = 8
## Below this the engine says nothing rather than recommending noise.
const SUGGEST_FLOOR: float = 0.35

## signal key -> 0..1
var signals: Dictionary[StringName, float] = {}
## signal key -> "31% of demand unserved"
var details: Dictionary[StringName, String] = {}
## signal key -> &"measured" | &"proxy" | &"idle"
var sources: Dictionary[StringName, StringName] = {}
## Absolute tick of the last sample.
var sampled_tick: int = -1

## Memory of the worst deficit the last night actually inflicted. Decays across
## the day, which is what makes "the generators cover the day and lose the
## night" a thing the tree can answer BEFORE the next dusk.
var _night_peak: float = 0.0
const NIGHT_PEAK_DECAY: float = 0.985

var _climate: WeakRef = null
var _heat: WeakRef = null
var _build: WeakRef = null
var _threat: WeakRef = null
var _combat: WeakRef = null
var _citizens: WeakRef = null
var _society: WeakRef = null

## Campaign day, for the proxies. 1 when climate is absent.
var _day: int = 1


## Rebinds every optional dependency. Cheap; call from post_setup().
func bind() -> void:
	_climate = _wref(Sim.get_system(&"climate"))
	_heat = _wref(Sim.get_system(&"heat"))
	_build = _wref(Sim.get_system(&"build"))
	_threat = _wref(Sim.get_system(&"threat"))
	_combat = _wref(Sim.get_system(&"combat"))
	_citizens = _wref(Sim.get_system(&"citizens"))
	_society = _wref(Sim.get_system(&"society"))


## Which optional systems actually answered, for the log line at world creation.
func describe() -> String:
	var found: Array[String] = []
	for pair: Array in [["climate", _climate], ["heat", _heat], ["build", _build],
			["threat", _threat], ["combat", _combat], ["citizens", _citizens],
			["society", _society]]:
		if (pair[1] as WeakRef) != null and (pair[1] as WeakRef).get_ref() != null:
			found.append(String(pair[0]))
	if found.is_empty():
		return "no world signals yet — pacing runs on the campaign clock alone"
	return "signals from " + ", ".join(found)


# ==========================================================================
#  MEASUREMENT
# ==========================================================================

## Reads the world once. Called every ResearchSystem.PACING_INTERVAL ticks, not
## every tick — the numbers it looks at move on the scale of a minute.
func sample(tick: int) -> void:
	sampled_tick = tick
	signals.clear()
	details.clear()
	sources.clear()
	_sample_climate()
	_sample_heat()
	_sample_build()
	_sample_threat()
	_sample_people()


func value(sig: StringName) -> float:
	return float(signals.get(sig, 0.0))


func detail(sig: StringName) -> String:
	return String(details.get(sig, ""))


## The loudest problem right now, or &"" when the city is genuinely fine.
func loudest() -> StringName:
	var best: StringName = &""
	var best_v: float = 0.0
	var keys: Array = signals.keys()
	keys.sort()
	for k: StringName in keys:
		var v: float = float(signals[k])
		if v > best_v + 0.0001:
			best_v = v
			best = k
	return best


# ==========================================================================
#  RANKING
# ==========================================================================

## How well this node answers what is happening right now.
func score(node: ResearchNode, affordable: bool, breadth: int) -> float:
	if node == null:
		return 0.0
	var s: float = 0.0
	if String(node.answers) != "":
		s += W_PRIMARY * maxf(0.0, node.answer_weight) * value(node.answers)
	if String(node.also_answers) != "":
		s += W_SECONDARY * value(node.also_answers)
	# Cheap things first, gently: a tier-1 answer beats a tier-4 answer to the
	# same problem, which is how a player ends up climbing rather than leaping.
	s += 0.6 / float(maxi(1, node.tier))
	s += W_BREADTH * float(mini(breadth, MAX_BREADTH))
	if affordable:
		s += W_AFFORDABLE
	s += node.priority_bias
	return s


## Player-facing "why this, why now". One sentence the node author wrote, one
## clause this class measured.
func reason_for(node: ResearchNode) -> String:
	if node == null:
		return ""
	var line: String = node.urgency_line.strip_edges()
	var sig: StringName = node.answers
	if String(sig) == "" or value(sig) < 0.05:
		return line
	var body: String = ResearchDefs.signal_line(sig)
	var d: String = detail(sig)
	if d != "":
		body += " — " + d
	if line == "":
		return body.capitalize()
	return "%s Right now %s." % [line, body]


## Everything the tree view needs to explain the recommendation, JSON-safe.
func snapshot() -> Dictionary:
	var sig_out: Dictionary = {}
	var det_out: Dictionary = {}
	var src_out: Dictionary = {}
	var keys: Array = signals.keys()
	keys.sort()
	for k: StringName in keys:
		var v: float = float(signals[k])
		if v <= 0.0005:
			continue
		sig_out[String(k)] = snappedf(v, 0.001)
		var d: String = detail(k)
		if d != "":
			det_out[String(k)] = d
		src_out[String(k)] = String(sources.get(k, &"measured"))
	return {
		"tick": sampled_tick,
		"loudest": String(loudest()),
		"signals": sig_out,
		"details": det_out,
		"sources": src_out,
	}


# ==========================================================================
#  INTERNALS — one reader per source system, all optional
# ==========================================================================

func _sample_climate() -> void:
	var c: Object = _live(_climate)
	if c == null:
		_put(ResearchDefs.SIG_COLD, 0.35, "the plain is always lethal here", &"proxy")
		return
	_day = int(c.call("day"))
	var ambient: float = float(c.call("ambient_temperature"))
	var storm: float = float(c.call("storm_intensity"))
	var night: bool = bool(c.call("is_night"))

	# -15 C is survivable in a coat; -40 kills an unsheltered citizen outright.
	var cold: float = clampf((-15.0 - ambient) / 25.0, 0.0, 1.0)
	_put(ResearchDefs.SIG_COLD, cold, "%.0f C outside" % ambient, &"measured")

	var storm_sig: float = storm
	var until: float = float(c.call("seconds_until_storm"))
	if storm <= 0.02 and until >= 0.0 and until < 900.0:
		storm_sig = maxf(storm_sig, 0.85 * (1.0 - until / 900.0))
	var n: Dictionary = c.call("next_storm")
	var title: String = String(n.get("title", "a Great Frost"))
	var storm_detail: String = ""
	if storm > 0.02:
		storm_detail = "%s is on the city" % String(c.call("storm_title"))
	elif until >= 0.0:
		storm_detail = "%s in %d:%02d" % [title, int(until) / 60, int(until) % 60]
	_put(ResearchDefs.SIG_STORM, storm_sig, storm_detail, &"measured")

	var vis: float = float(c.call("visibility"))
	var blind: float = clampf(1.0 - vis, 0.0, 1.0)
	if night:
		blind = maxf(blind, 0.4)
	_put(ResearchDefs.SIG_BLIND, blind, "visibility %d%%" % int(vis * 100.0), &"measured")


func _sample_heat() -> void:
	var h: Object = _live(_heat)
	if h == null:
		return
	var t: Dictionary = h.call("totals")
	var demand: float = float(t.get("demand", 0.0))
	var supply: float = float(t.get("supply", 0.0))
	var deficit: float = float(t.get("deficit", 0.0))
	var loss: float = float(t.get("loss", 0.0))
	var frozen: int = int(t.get("frozen", 0))

	var deficit_frac: float = 0.0
	if demand > 0.001:
		deficit_frac = clampf(deficit / demand, 0.0, 1.0)
	_put(ResearchDefs.SIG_HEAT_DEFICIT, deficit_frac,
		"%d%% of demand unserved" % int(deficit_frac * 100.0), &"measured")

	# A third of production dying in the pipes is a five-alarm reading; scale so
	# that lands at 1.0 and a healthy 5% barely registers.
	var loss_frac: float = 0.0
	if supply > 0.001:
		loss_frac = clampf(loss / supply * 3.0, 0.0, 1.0)
	_put(ResearchDefs.SIG_HEAT_LOSS, loss_frac,
		"%.0f u/s lost in transmission" % loss, &"measured")

	# Night memory. This is the signal that lets the tree offer accumulators the
	# morning after the night they were needed, instead of two days later.
	var night: bool = _is_night()
	if night:
		_night_peak = maxf(_night_peak, deficit_frac)
	else:
		_night_peak *= NIGHT_PEAK_DECAY
	_put(ResearchDefs.SIG_HEAT_PEAK, _night_peak,
		"last night the grid ran %d%% short" % int(_night_peak * 100.0), &"measured")

	_put(ResearchDefs.SIG_FROZEN, clampf(float(frozen) / 3.0, 0.0, 1.0),
		"%d building(s) frozen solid" % frozen, &"measured")

	var worst_consumers: int = 0
	var worst_cell: Vector2i = Vector2i.ZERO
	var starved: int = 0
	var ids: PackedInt32Array = h.call("network_ids")
	for nid: int in ids:
		var st: Dictionary = h.call("network_stats", nid)
		if st.is_empty():
			continue
		starved += int(st.get("starved", 0))
		var worst: Dictionary = st.get("worst_bottleneck", {})
		if worst.is_empty():
			continue
		if String(worst.get("reason", "")) != "capacity":
			continue
		var n: int = int(worst.get("consumers", 0))
		if n > worst_consumers:
			worst_consumers = n
			var cell: Array = worst.get("cell", [0, 0])
			if cell.size() == 2:
				worst_cell = Vector2i(int(cell[0]), int(cell[1]))
	_put(ResearchDefs.SIG_HEAT_BOTTLENECK, clampf(float(worst_consumers) / 6.0, 0.0, 1.0),
		"one tile at %d,%d is throttling %d buildings" % [worst_cell.x, worst_cell.y, worst_consumers],
		&"measured")
	_put(ResearchDefs.SIG_FUEL, clampf(float(starved) / 2.0, 0.0, 1.0),
		"%d burner(s) running on fumes" % starved, &"measured")


func _sample_build() -> void:
	var b: Object = _live(_build)
	if b == null:
		return
	var total: int = int(b.call("building_count"))
	_put(ResearchDefs.SIG_SPRAWL, clampf(float(total) / 70.0, 0.0, 1.0),
		"%d buildings to keep supplied" % total, &"measured")

	# Tangle is density, not size: pipes and machines competing for the same
	# tiles is what makes a player want to route underneath.
	var conduits: int = (b.call("buildings_with_tag", &"conduit") as Array).size()
	var machines: int = (b.call("buildings_with_tag", &"machine") as Array).size()
	var tangle: float = clampf((float(conduits) / 60.0) * (0.4 + 0.6 * clampf(float(machines) / 8.0, 0.0, 1.0)), 0.0, 1.0)
	_put(ResearchDefs.SIG_TANGLE, tangle,
		"%d conduit tiles around %d machines" % [conduits, machines], &"measured")

	var m: Dictionary = b.call("metrics")
	var materials: int = int(m.get("materials", -1))
	if materials >= 0:
		# 400 units in the yard is comfortable; empty is a five-alarm reading.
		_put(ResearchDefs.SIG_MATERIALS, clampf(1.0 - float(materials) / 400.0, 0.0, 1.0),
			"%d units left in the yard" % materials, &"measured")
	var queued: int = int(m.get("queued", 0))
	var ghosts: int = int(m.get("ghosts", 0))
	_put(ResearchDefs.SIG_LABOUR, clampf(float(queued + ghosts) / 12.0, 0.0, 1.0),
		"%d site(s) waiting on hands" % (queued + ghosts), &"measured")


func _sample_threat() -> void:
	var t: Object = _live(_threat)
	var proxy: float = clampf(float(_day - 2) / 5.0, 0.0, 1.0)

	var wave: float = _probe(t, ["pressure", "threat_level", "wave_strength"], proxy)
	_put(ResearchDefs.SIG_WAVE, clampf(wave, 0.0, 1.0),
		"night pressure at %d%%" % int(clampf(wave, 0.0, 1.0) * 100.0),
		&"measured" if t != null else &"proxy")

	var armoured: float = _probe(t, ["armoured_share", "armored_share", "heavy_share"],
		clampf(float(_day - 3) / 4.0, 0.0, 1.0))
	_put(ResearchDefs.SIG_ARMOURED, clampf(armoured, 0.0, 1.0),
		"%d%% of what is coming is armoured" % int(clampf(armoured, 0.0, 1.0) * 100.0),
		&"measured" if t != null and _has(t, ["armoured_share", "armored_share", "heavy_share"]) else &"proxy")

	var swarm: float = _probe(t, ["swarm_share", "enemy_pressure"], proxy * 0.7)
	_put(ResearchDefs.SIG_SWARM, clampf(swarm, 0.0, 1.0), "",
		&"measured" if t != null and _has(t, ["swarm_share", "enemy_pressure"]) else &"proxy")

	var c: Object = _live(_combat)
	var lost: float = _probe(c, ["structures_lost", "structures_destroyed"], -1.0)
	if lost >= 0.0:
		_put(ResearchDefs.SIG_STRUCTURE_LOSS, clampf(lost / 4.0, 0.0, 1.0),
			"%d structure(s) lost" % int(lost), &"measured")
	else:
		var b: Object = _live(_build)
		var destroyed: float = -1.0
		if b != null:
			destroyed = float((b.call("metrics") as Dictionary).get("destroyed_total", -1))
		if destroyed >= 0.0:
			_put(ResearchDefs.SIG_STRUCTURE_LOSS, clampf(destroyed / 4.0, 0.0, 1.0),
				"%d structure(s) lost" % int(destroyed), &"measured")
		else:
			_put(ResearchDefs.SIG_STRUCTURE_LOSS, proxy * 0.5, "", &"proxy")


func _sample_people() -> void:
	var p: Object = _live(_citizens)
	var deaths: float = _probe(p, ["deaths", "died_total", "casualties"], -1.0)
	if deaths >= 0.0:
		_put(ResearchDefs.SIG_CASUALTIES, clampf(deaths / 5.0, 0.0, 1.0),
			"%d dead so far" % int(deaths), &"measured")
	else:
		# No population system yet: the cold itself stands in for the toll.
		_put(ResearchDefs.SIG_CASUALTIES, value(ResearchDefs.SIG_COLD) * 0.6, "", &"proxy")

	var hunger: float = _probe(p, ["hunger", "starvation"], -1.0)
	if hunger >= 0.0:
		_put(ResearchDefs.SIG_HUNGER, clampf(hunger, 0.0, 1.0),
			"%d%% of the city went hungry" % int(clampf(hunger, 0.0, 1.0) * 100.0), &"measured")
	else:
		_put(ResearchDefs.SIG_HUNGER, clampf(float(_day - 1) / 8.0, 0.0, 1.0), "", &"proxy")

	var s: Object = _live(_society)
	var discontent: float = _probe(s, ["discontent", "unrest"], -1.0)
	if discontent >= 0.0:
		_put(ResearchDefs.SIG_DISCONTENT, clampf(discontent, 0.0, 1.0),
			"discontent at %d%%" % int(clampf(discontent, 0.0, 1.0) * 100.0), &"measured")
	else:
		_put(ResearchDefs.SIG_DISCONTENT,
			maxf(value(ResearchDefs.SIG_CASUALTIES), value(ResearchDefs.SIG_HUNGER)) * 0.7,
			"", &"proxy")


# --- plumbing ---------------------------------------------------------------

func _put(sig: StringName, v: float, text: String, src: StringName) -> void:
	signals[sig] = clampf(v, 0.0, 1.0)
	if text != "":
		details[sig] = text
	sources[sig] = src


func _is_night() -> bool:
	var c: Object = _live(_climate)
	if c == null:
		return false
	return bool(c.call("is_night"))


## Calls the first zero-argument method on `obj` that exists and returns a
## number. `fallback` when the object or every candidate is missing.
func _probe(obj: Object, candidates: Array, fallback: float) -> float:
	if obj == null:
		return fallback
	for c: Variant in candidates:
		var name: StringName = StringName(String(c))
		if not obj.has_method(name):
			continue
		var v: Variant = obj.call(name)
		var t: int = typeof(v)
		if t == TYPE_FLOAT or t == TYPE_INT:
			return float(v)
	return fallback


func _has(obj: Object, candidates: Array) -> bool:
	if obj == null:
		return false
	for c: Variant in candidates:
		if obj.has_method(StringName(String(c))):
			return true
	return false


func _wref(o: Object) -> WeakRef:
	return weakref(o) if o != null else null


func _live(w: WeakRef) -> Object:
	if w == null:
		return null
	return w.get_ref()
