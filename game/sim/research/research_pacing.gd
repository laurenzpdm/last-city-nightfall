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
const W_SECONDARY: float = 2.0
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
	_roster.clear()
	_roster_read = false


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
## `census` is [P10]'s single pass over the city — see ResearchSystem._take_census.
## Scanning the building list again here would double the only expensive read in
## the whole part.
func sample(tick: int, census: Dictionary = {}) -> void:
	sampled_tick = tick
	signals.clear()
	details.clear()
	sources.clear()
	_sample_climate()
	_sample_heat()
	_sample_build(census)
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
	keys = ResearchDefs.sorted_names(keys)
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
		s += W_PRIMARY * maxf(0.0, node.answer_weight) \
				* ResearchDefs.stake(node.answers) * value(node.answers)
	if String(node.also_answers) != "":
		s += W_SECONDARY * ResearchDefs.stake(node.also_answers) * value(node.also_answers)
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
	# Whichever of the node's two problems is actually loudest right now. A node
	# that quietly fixes freezing buildings should say so on the night buildings
	# are freezing, not recite its headline.
	var sig: StringName = node.answers
	if String(node.also_answers) != "" and value(node.also_answers) > value(sig):
		sig = node.also_answers
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
	keys = ResearchDefs.sorted_names(keys)
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
	# The detail is appended to the signal's own headline, which for SIG_COLD is
	# already "the plain outside is lethal". "…is lethal — -27°C outside" said
	# outside twice and put an em dash immediately in front of a minus sign.
	_put(ResearchDefs.SIG_COLD, cold, "the air is %.0f°C" % ambient, &"measured")

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


## Scales here are calibrated against the reference run (first_night), not
## guessed: a signal that saturates at 1.0 by minute three is a signal that
## stops ranking anything.
const SPRAWL_FULL: float = 14.0     ## things that need supplying, not tiles
const TANGLE_CONDUITS: float = 140.0
const TANGLE_MACHINES: float = 6.0
const MATERIALS_COMFORTABLE: float = 500.0
const LABOUR_FLOOR_SITES: float = 10.0
const LABOUR_SHARE: float = 0.35    ## queue as a share of the city that is a problem

func _sample_build(census: Dictionary) -> void:
	var b: Object = _live(_build)
	if b == null:
		return
	var total: int = int(census.get("total", 0))
	# Sprawl is not tile count — a hundred pipe segments are one decision. What
	# makes a base hard to run is the number of things that have to be SUPPLIED.
	var machines: int = int(census.get("machines", 0))
	var extractors: int = int(census.get("extractors", 0))
	var stores: int = int(census.get("stores", 0))
	var supplied: int = machines + extractors + stores
	_put(ResearchDefs.SIG_SPRAWL, clampf(float(supplied) / SPRAWL_FULL, 0.0, 1.0),
		"%d machines, drills and stores to keep fed" % supplied, &"measured")

	# Tangle needs BOTH: a lot of pipe, and a lot of things the pipe has to get
	# around. Either one on its own is just a big base.
	var conduits: int = int(census.get("conduits", 0))
	var tangle: float = clampf(float(conduits) / TANGLE_CONDUITS, 0.0, 1.0) \
			* clampf(float(machines + extractors) / TANGLE_MACHINES, 0.0, 1.0)
	_put(ResearchDefs.SIG_TANGLE, tangle,
		"%d conduit tiles crossing %d machines" % [conduits, machines + extractors], &"measured")

	var m: Dictionary = b.call("metrics")
	var materials: int = int(m.get("materials", -1))
	if materials >= 0:
		_put(ResearchDefs.SIG_MATERIALS,
			clampf(1.0 - float(materials) / MATERIALS_COMFORTABLE, 0.0, 1.0),
			"%d units left in the yard" % materials, &"measured")
	# A backlog only means "not enough hands" relative to the city that has to
	# build it. Ten sites is a lot on day one and nothing on day nine.
	var queued: int = int(m.get("queued", 0))
	var reference: float = maxf(LABOUR_FLOOR_SITES, float(total) * LABOUR_SHARE)
	_put(ResearchDefs.SIG_LABOUR, clampf(float(queued) / reference, 0.0, 1.0),
		"%d site(s) waiting on hands" % queued, &"measured")


## Armour that a plain kinetic round stops answering. The hoarfrost breaker
## carries 14 of it; a drift hound carries none.
const ARMOUR_HURTS: float = 4.0
## Pack size at which a unit is a swarm whatever its role says.
const SWARM_PACK: int = 4
## Structures lost in one night that reads as "the wall did not hold".
const LOSSES_SEVERE: float = 4.0

## Cached roster table: one row per enemy kind, [min_wave, weight, armoured, swarm].
## The roster is content and never changes at runtime, so it is read once.
var _roster: Array[Array] = []
var _roster_read: bool = false


func _sample_threat() -> void:
	var t: Object = _live(_threat)
	var proxy: float = clampf(float(_day - 2) / 5.0, 0.0, 1.0)
	if t == null:
		_put(ResearchDefs.SIG_WAVE, proxy, "", &"proxy")
		_put(ResearchDefs.SIG_ARMOURED, clampf(float(_day - 3) / 4.0, 0.0, 1.0), "", &"proxy")
		_put(ResearchDefs.SIG_SWARM, proxy * 0.7, "", &"proxy")
		_put(ResearchDefs.SIG_STRUCTURE_LOSS, proxy * 0.5, "", &"proxy")
		return

	# NOT "pressure": [P08] uses that name for its adaptive difficulty multiplier,
	# which sits at 1.0 on a quiet day one. Reading it as an urgency put the whole
	# defence branch at the front of the tree before anything had attacked.
	# threat_level() is the one [P08] documents as 0..1.
	var level: float = _probe(t, ["threat_level", "wave_strength"], proxy)
	_put(ResearchDefs.SIG_WAVE, clampf(level, 0.0, 1.0),
		"threat level %d%%" % int(clampf(level, 0.0, 1.0) * 100.0), &"measured")

	_read_roster(t)
	var wave_no: int = int(_probe(t, ["wave"], 0.0))
	if _roster.is_empty():
		_put(ResearchDefs.SIG_ARMOURED, clampf(float(_day - 3) / 4.0, 0.0, 1.0), "", &"proxy")
		_put(ResearchDefs.SIG_SWARM, proxy * 0.7, "", &"proxy")
	else:
		# What the plain can send TONIGHT, weighted the way [P08] weights it.
		# The armoured signal turns on the wave a breaker becomes eligible, which
		# is exactly the night armour-piercing rounds are supposed to arrive.
		var total: float = 0.0
		var armoured: float = 0.0
		var swarm: float = 0.0
		for row: Array in _roster:
			if int(row[0]) > wave_no + 1:
				continue
			var w: float = float(row[1])
			total += w
			if bool(row[2]):
				armoured += w
			if bool(row[3]):
				swarm += w
		if total > 0.0001:
			# What the roster CAN send only matters once something has actually
			# come. Before the first wave the composition of the dark is a fact
			# about the world, not a problem the player is feeling — and without
			# this the defence branch outbids the cold on day one.
			var engagement: float = clampf(float(wave_no) / 3.0, 0.15, 1.0)
			_put(ResearchDefs.SIG_ARMOURED,
				clampf(armoured / total * 2.0, 0.0, 1.0) * engagement,
				"%d%% of what the plain can send is armoured" % int(armoured / total * 100.0),
				&"measured")
			_put(ResearchDefs.SIG_SWARM,
				clampf(swarm / total * 1.5, 0.0, 1.0) * engagement,
				"%d%% of it arrives in packs" % int(swarm / total * 100.0), &"measured")

	var lost: float = _last_night_losses(t)
	if lost >= 0.0:
		_put(ResearchDefs.SIG_STRUCTURE_LOSS, clampf(lost / LOSSES_SEVERE, 0.0, 1.0),
			"%d structure(s) lost last night" % int(lost), &"measured")
	else:
		_put(ResearchDefs.SIG_STRUCTURE_LOSS, proxy * 0.5, "", &"proxy")


## Structures the city lost in the night in progress, or in the last one that
## finished. -1.0 when [P08] does not report it.
func _last_night_losses(t: Object) -> float:
	for name: String in ["current_wave_report", "last_wave_report"]:
		if not t.has_method(name):
			continue
		var report: Variant = t.call(name)
		if typeof(report) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = report
		if d.is_empty() or not d.has("structures_lost"):
			continue
		return float(d["structures_lost"])
	return -1.0


## Reads [P08]'s enemy roster once and reduces it to the four numbers this class
## needs. Content, not state: it cannot change while a world is alive.
func _read_roster(t: Object) -> void:
	if _roster_read:
		return
	_roster_read = true
	if not t.has_method("roster"):
		return
	var raw: Variant = t.call("roster")
	if typeof(raw) != TYPE_ARRAY:
		return
	for entry: Variant in raw:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = entry
		var armour: float = float(d.get("armor", d.get("armour", 0.0)))
		var pack: int = maxi(1, int(d.get("pack_size", 1)))
		var weight: float = maxf(0.0, float(d.get("weight", 1.0))) * float(pack)
		if weight <= 0.0:
			continue
		var role: String = String(d.get("role", ""))
		_roster.append([
			int(d.get("min_wave", 0)),
			weight,
			armour >= ARMOUR_HURTS,
			role == "swarm" or pack >= SWARM_PACK,
		])


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


func _wref(o: Object) -> WeakRef:
	return weakref(o) if o != null else null


func _live(w: WeakRef) -> Object:
	if w == null:
		return null
	return w.get_ref()
