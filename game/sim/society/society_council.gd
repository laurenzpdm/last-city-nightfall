class_name SocietyCouncil
extends RefCounted
## Factions, grievances and demands: the part of [P06] that talks back.
##
## The loop is deliberately slow and deliberately fair.
##
##   1. A pressure rises. Nothing happens for an hour and a half. The city
##      grumbles and you get to notice.
##   2. A grievance opens. It is named, it is attributed to a faction, and it
##      starts costing discontent proportional to how many people hold it.
##   3. If it is still there when it has built to two thirds intensity, the
##      faction stops grumbling and issues a DEMAND with a deadline. The demand
##      is always something the simulation can check, and always something the
##      player can actually do.
##   4. Meet it and they remember. Miss it and they radicalise: shorter fuses,
##      sharper penalties, more discontent per head, forever.
##
## Nothing here reads the world directly. SocietySystem measures the city and
## hands this class pressures and metric values, which keeps the observation in
## one place and makes every rule in here testable with a dictionary.

const DEMAND_COOLDOWN_HOURS: float = 14.0
const RNG_STREAM: String = "society"
## Settled demands are kept for the end screen, but not forever: a seven day run
## produces dozens and state.json is not an archive.
const DEMAND_HISTORY: int = 12

## grievance kind -> array of demand shapes. The first is the shape a faction
## reaches for when the city can still fix the problem with heat and hands; the
## second reaches for the book instead.
const DEMAND_TEMPLATES: Dictionary = {
	&"cold": [
		{
			"kind": "condition", "metric": "warm_share", "op": ">=", "value": 0.75,
			"speech": "We are not asking for comfort. We are asking for a room where a child can take a coat off.",
			"terms": "Three in four of us in a room above twelve degrees.",
		},
		{
			"kind": "law_any", "laws": ["night_curfew"],
			"speech": "Then take the heat off the machines at night and give it to the houses. Write it down so it cannot be quietly forgotten.",
			"terms": "Sign the Night Curfew.",
		},
	],
	&"hunger": [
		{
			"kind": "condition", "metric": "hunger_share", "op": "<=", "value": 0.15,
			"speech": "Fill the pots. That is the whole of it. Fill the pots.",
			"terms": "Feed all but a handful of us.",
		},
		{
			"kind": "law_none", "laws": ["soup_ration", "sawdust_bread", "rendering"],
			"speech": "Whatever you do next, do not touch the bowl again. We will know what is in it.",
			"terms": "Cut the ration no further before the deadline.",
		},
	],
	&"overwork": [
		{
			"kind": "condition", "metric": "work_hours", "op": "<=", "value": 12.0,
			"speech": "Twelve hours. We will give you twelve hours and our backs and you will not ask for the fourteenth.",
			"terms": "Bring the shift down to twelve hours.",
		},
		{
			"kind": "law_none", "laws": ["extended_shift", "press_gangs"],
			"speech": "Do not lengthen it again. The next man who goes down on the ice will not be carried in.",
			"terms": "Do not lengthen the shift before the deadline.",
		},
	],
	&"children": [
		{
			"kind": "law_none", "laws": ["child_labour", "apprentices"],
			"speech": "You will not put them in the pits. Say it now, in front of everyone, and we will go back to work.",
			"terms": "Do not send the children into the works.",
		},
		{
			"kind": "law_any", "laws": ["child_shelter_duty"],
			"speech": "Give them something indoors. Give them a room and a task and we will stop counting them at the gate.",
			"terms": "Sign Child Shelter Duty.",
		},
	],
	&"sickness": [
		{
			"kind": "condition", "metric": "sick_share", "op": "<=", "value": 0.10,
			"speech": "It is going room to room in the order the bunks are laid out. Break the chain.",
			"terms": "Get the fever below one in ten.",
		},
		{
			"kind": "law_any", "laws": ["care_house", "house_of_prayer"],
			"speech": "Then give us a building with a door that shuts and someone in it who is not also on shift.",
			"terms": "Sign a law that puts the sick somewhere.",
		},
	],
	&"dead_unburied": [
		{
			"kind": "condition", "metric": "corpses", "op": "<=", "value": 1.0,
			"speech": "They are under a tarp by the east wall and the tarp is not long enough. Deal with them.",
			"terms": "Clear the dead from the east wall.",
		},
		{
			"kind": "law_any", "laws": ["named_graves", "snow_burial", "corpse_pits", "rite_of_ash"],
			"speech": "Decide what we are. Write down what happens to a body in this city and we will abide by it, whatever it says.",
			"terms": "Sign a law that says where the dead go.",
		},
	],
	&"homeless": [
		{
			"kind": "condition", "metric": "homeless_share", "op": "<=", "value": 0.02,
			"speech": "We came because you had walls. We are sleeping against the outside of them.",
			"terms": "A bunk for nearly everyone.",
		},
		{
			"kind": "law_any", "laws": ["double_bunks"],
			"speech": "Then put two of us in every bed. We will take head to foot over the open ice.",
			"terms": "Sign Double Bunks.",
		},
	],
	&"fear": [
		{
			"kind": "condition", "metric": "discontent", "op": "<=", "value": 45.0,
			"speech": "Nobody argues in the street any more. They wait until they are indoors. Give us back the street.",
			"terms": "Bring discontent down below forty five.",
		},
		{
			"kind": "law_none", "laws": ["martial_law", "informers", "public_penance"],
			"speech": "Do not tighten it further. There is a point past which we stop being a city and start being a work camp.",
			"terms": "Sign nothing further that puts a hand on our throat.",
		},
	],
	&"faithless": [
		{
			"kind": "law_any", "laws": ["path_of_faith", "evening_prayer"],
			"speech": "You keep the fire and you will not say what it is. Let us give it a name and kneel to it.",
			"terms": "Let the congregation have its evening.",
		},
	],
	&"disorder": [
		{
			"kind": "law_any", "laws": ["path_of_order", "watch_patrols"],
			"speech": "There were three fights at the ration line and nobody stopped any of them. Give us the authority and we will.",
			"terms": "Put someone in charge of the street.",
		},
		{
			"kind": "condition", "metric": "discontent", "op": "<=", "value": 40.0,
			"speech": "Or settle them yourself. We do not care how. We care that it stops.",
			"terms": "Bring discontent down below forty.",
		},
	],
}

var factions: Dictionary[StringName, SocietyFaction] = {}
var grievances: Dictionary[StringName, SocietyGrievance] = {}
var demands: Array[SocietyDemand] = []

var _next_demand_id: int = 1


func setup() -> void:
	factions.clear()
	grievances.clear()
	demands.clear()
	_next_demand_id = 1
	for id: StringName in SocietyDefs.FACTION_IDS:
		factions[id] = SocietyFaction.new(id)
	for id: StringName in SocietyDefs.GRIEVANCE_IDS:
		grievances[id] = SocietyGrievance.new(id)


# =========================================================================
#  the loop
# =========================================================================

## One sample. `pressures` maps grievance kind to 0..1; `details` maps the same
## keys to the sentence with this run's numbers in it; `values` is the metric
## table demands are checked against. Returns the events that happened.
func sample(pressures: Dictionary, details: Dictionary, values: Dictionary,
		book: LawBook, hours: float, tick: int, hour_ticks: int) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	var relieved: Array[StringName] = book.relieved_grievances()

	for kind: StringName in SocietyDefs.GRIEVANCE_IDS:
		var g: SocietyGrievance = grievances[kind]
		var p: float = float(pressures.get(kind, 0.0))
		if relieved.has(kind):
			# A law that answers a grievance does not just reduce the pressure,
			# it takes the argument off the table.
			p *= 0.25
		var detail: String = String(details.get(kind, ""))
		if detail != "":
			g.detail = detail
		var change: StringName = g.update(p, hours)
		if change == &"opened":
			g.opened_tick = tick
			events.append({
				"kind": &"grievance_opened",
				"grievance": String(kind),
				"faction": String(g.faction),
				"title": g.title(),
				"text": "%s: %s" % [SocietyDefs.faction_name(g.faction), g.complaint()],
				"detail": g.detail,
			})
		elif change == &"closed":
			g.closed_tick = tick
			events.append({
				"kind": &"grievance_closed",
				"grievance": String(kind),
				"faction": String(g.faction),
				"title": g.title(),
				"text": g.resolved_line(),
				"detail": g.detail,
			})

	events.append_array(_resolve_demands(values, book, tick, hour_ticks))
	events.append_array(_issue_demands(book, tick, hour_ticks))
	_prune_demands()

	for id: StringName in SocietyDefs.FACTION_IDS:
		(factions[id] as SocietyFaction).drift(hours)
	return events


func _resolve_demands(values: Dictionary, book: LawBook, tick: int,
		hour_ticks: int) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	var check: Callable = func(l: StringName) -> bool: return book.is_signed(l)
	for d: SocietyDemand in demands:
		if not d.is_open():
			continue
		var ok: bool = d.satisfied(values, check)
		var due: bool = d.expired(tick)
		if d.breaks_immediately():
			if not ok:
				events.append(_fail(d, tick, "broken"))
				continue
			if due:
				events.append(_meet(d, tick))
			continue
		if ok:
			events.append(_meet(d, tick))
		elif due:
			events.append(_fail(d, tick, "expired"))
	return events


func _meet(d: SocietyDemand, tick: int) -> Dictionary:
	d.resolve(SocietyDemand.STATE_MET, tick)
	var f: SocietyFaction = factions[d.faction]
	f.demands_met += 1
	f.adjust(SocietyDefs.DEMAND_MET_APPROVAL)
	f.radical = maxi(0, f.radical - 1)
	var g: SocietyGrievance = grievances.get(d.grievance)
	if g != null:
		g.intensity = maxf(0.0, g.intensity * 0.35)
	return {
		"kind": &"demand_met",
		"faction": String(d.faction),
		"grievance": String(d.grievance),
		"demand": d.id,
		"text": "%s got what they asked for: %s" % [f.name_of(), d.terms],
	}


func _fail(d: SocietyDemand, tick: int, how: String) -> Dictionary:
	d.resolve(SocietyDemand.STATE_FAILED, tick)
	var f: SocietyFaction = factions[d.faction]
	f.demands_failed += 1
	f.adjust(SocietyDefs.DEMAND_FAILED_APPROVAL)
	f.radical = mini(SocietyDefs.RADICAL_MAX, f.radical + 1)
	var g: SocietyGrievance = grievances.get(d.grievance)
	if g != null:
		g.intensity = minf(1.0, g.intensity + 0.2)
	var line: String = "%s asked for one thing and did not get it: %s" % [f.name_of(), d.terms]
	if how == "broken":
		line = "%s asked you to hold off, and you signed anyway." % f.name_of()
	return {
		"kind": &"demand_failed",
		"faction": String(d.faction),
		"grievance": String(d.grievance),
		"demand": d.id,
		"how": how,
		"text": line,
	}


func _issue_demands(book: LawBook, tick: int, hour_ticks: int) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	for kind: StringName in SocietyDefs.GRIEVANCE_IDS:
		var g: SocietyGrievance = grievances[kind]
		if not g.ready_to_demand():
			continue
		var f: SocietyFaction = factions[g.faction]
		if _has_open_demand(g.faction):
			continue
		if float(tick - f.last_demand_tick) < DEMAND_COOLDOWN_HOURS * float(hour_ticks):
			continue
		var d: SocietyDemand = _build_demand(g, f, book, tick, hour_ticks)
		if d == null:
			continue
		demands.append(d)
		f.demands_made += 1
		f.last_demand_tick = tick
		events.append({
			"kind": &"demand_made",
			"faction": String(f.id),
			"grievance": String(kind),
			"demand": d.id,
			"text": "%s: %s" % [f.name_of(), d.speech],
			"terms": d.terms,
			"hours": snappedf(d.hours_left(tick, hour_ticks), 0.1),
		})
	return events


## Keeps every open demand and the most recent DEMAND_HISTORY settled ones.
func _prune_demands() -> void:
	var settled: int = 0
	for d: SocietyDemand in demands:
		if not d.is_open():
			settled += 1
	if settled <= DEMAND_HISTORY:
		return
	var drop: int = settled - DEMAND_HISTORY
	var kept: Array[SocietyDemand] = []
	for d: SocietyDemand in demands:
		if not d.is_open() and drop > 0:
			drop -= 1
			continue
		kept.append(d)
	demands = kept


func _has_open_demand(faction: StringName) -> bool:
	for d: SocietyDemand in demands:
		if d.faction == faction and d.is_open():
			return true
	return false


## Picks a shape the city can actually satisfy. A law based demand whose every
## named law is already foreclosed is not a demand, it is a death sentence with
## extra steps, so those templates are skipped.
func _build_demand(g: SocietyGrievance, f: SocietyFaction, book: LawBook,
		tick: int, hour_ticks: int) -> SocietyDemand:
	var templates: Array = DEMAND_TEMPLATES.get(g.kind, [])
	if templates.is_empty():
		return null
	var usable: Array[Dictionary] = []
	for raw: Variant in templates:
		var t: Dictionary = raw
		if String(t.get("kind", "")) == "law_any":
			var reachable: bool = false
			for name: Variant in t.get("laws", []):
				var lid: StringName = StringName(String(name))
				if not book.has(lid):
					continue
				if book.is_signed(lid) or not book.is_foreclosed(lid):
					reachable = true
					break
			if not reachable:
				continue
		usable.append(t)
	if usable.is_empty():
		return null

	var rng: RandomNumberGenerator = Rng.stream(RNG_STREAM)
	var pick: Dictionary = usable[rng.randi_range(0, usable.size() - 1)]
	var d := SocietyDemand.new()
	d.id = _next_demand_id
	_next_demand_id += 1
	d.faction = f.id
	d.grievance = g.kind
	d.kind = StringName(String(pick.get("kind", "condition")))
	d.metric = StringName(String(pick.get("metric", "")))
	d.op = StringName(String(pick.get("op", ">=")))
	d.value = float(pick.get("value", 0.0))
	d.laws = []
	for name: Variant in pick.get("laws", []):
		d.laws.append(StringName(String(name)))
	d.speech = String(pick.get("speech", ""))
	d.terms = String(pick.get("terms", ""))
	d.issued_tick = tick
	var hours: float = maxf(SocietyDefs.DEMAND_HOURS_MIN,
		SocietyDefs.DEMAND_HOURS_BASE - 2.0 * float(f.radical))
	hours *= 1.0 + rng.randf_range(-0.15, 0.15)
	d.deadline_tick = tick + maxi(1, int(round(hours * float(hour_ticks))))
	return d


# =========================================================================
#  what the rest of the system asks for
# =========================================================================

func faction_of(id: StringName) -> SocietyFaction:
	return factions.get(id)


func approval_of(id: StringName) -> float:
	var f: SocietyFaction = factions.get(id)
	return 0.0 if f == null else f.approval


func adjust_approval(id: StringName, delta: float) -> void:
	var f: SocietyFaction = factions.get(id)
	if f != null:
		f.adjust(delta)


func grievance_of(kind: StringName) -> SocietyGrievance:
	return grievances.get(kind)


## Open grievances, worst first. Order is stable: intensity, then kind.
func open_grievances() -> Array[SocietyGrievance]:
	var out: Array[SocietyGrievance] = []
	for kind: StringName in SocietyDefs.GRIEVANCE_IDS:
		var g: SocietyGrievance = grievances[kind]
		if g.open or g.intensity > 0.001:
			out.append(g)
	out.sort_custom(func(a: SocietyGrievance, b: SocietyGrievance) -> bool:
		if absf(a.intensity - b.intensity) > 0.0001:
			return a.intensity > b.intensity
		return String(a.kind) < String(b.kind))
	return out


func active_grievance_count() -> int:
	var n: int = 0
	for kind: StringName in SocietyDefs.GRIEVANCE_IDS:
		if (grievances[kind] as SocietyGrievance).open:
			n += 1
	return n


func open_demands() -> Array[SocietyDemand]:
	var out: Array[SocietyDemand] = []
	for d: SocietyDemand in demands:
		if d.is_open():
			out.append(d)
	return out


## Discontent per hour from grievances plus plain resentment.
func discontent_rate() -> float:
	var total: float = 0.0
	for kind: StringName in SocietyDefs.GRIEVANCE_IDS:
		var g: SocietyGrievance = grievances[kind]
		total += g.discontent_rate((factions[g.faction] as SocietyFaction).radical)
	return total


func resentment_rate() -> float:
	var total: float = 0.0
	for id: StringName in SocietyDefs.FACTION_IDS:
		total += (factions[id] as SocietyFaction).resentment_rate()
	return total


func goodwill_rate() -> float:
	var total: float = 0.0
	for id: StringName in SocietyDefs.FACTION_IDS:
		total += (factions[id] as SocietyFaction).goodwill_rate()
	return total


func lowest_approval() -> float:
	var worst: float = SocietyDefs.APPROVAL_MAX
	for id: StringName in SocietyDefs.FACTION_IDS:
		worst = minf(worst, (factions[id] as SocietyFaction).approval)
	return worst


func radical_count() -> int:
	var n: int = 0
	for id: StringName in SocietyDefs.FACTION_IDS:
		if (factions[id] as SocietyFaction).radical > 0:
			n += 1
	return n


## Applied when a law comes into force: approval swings, grievances relieved and
## grievances provoked all land at once.
func apply_law(law: LawDef, tick: int) -> void:
	for f: StringName in SocietyDefs.sorted_keys(law.approval):
		adjust_approval(f, float(law.approval[f]))
	for g: StringName in law.relieves:
		var gr: SocietyGrievance = grievances.get(g)
		if gr != null:
			gr.intensity = maxf(0.0, gr.intensity * 0.3)
			gr.above_hours = 0.0
	for g: StringName in law.provokes:
		var gp: SocietyGrievance = grievances.get(g)
		if gp != null:
			gp.above_hours = maxf(gp.above_hours, SocietyDefs.GRIEVANCE_OPEN_HOURS)
			gp.intensity = maxf(gp.intensity, 0.22)
			if gp.opened_tick < 0:
				gp.opened_tick = tick


# =========================================================================
#  views and persistence
# =========================================================================

func faction_views() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id: StringName in SocietyDefs.FACTION_IDS:
		out.append((factions[id] as SocietyFaction).view())
	return out


func grievance_views() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for g: SocietyGrievance in open_grievances():
		out.append(g.view())
	return out


func demand_views(tick: int, hour_ticks: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for d: SocietyDemand in demands:
		if d.is_open():
			out.append(d.view(tick, hour_ticks))
	return out


func serialize(tick: int, hour_ticks: int) -> Dictionary:
	var f: Array = []
	for id: StringName in SocietyDefs.FACTION_IDS:
		f.append((factions[id] as SocietyFaction).serialize())
	var g: Array = []
	for kind: StringName in SocietyDefs.GRIEVANCE_IDS:
		g.append((grievances[kind] as SocietyGrievance).serialize())
	var d: Array = []
	for dem: SocietyDemand in demands:
		d.append(dem.serialize())
	return {
		"factions": f,
		"grievances": g,
		"demands": d,
		"open_demands": demand_views(tick, hour_ticks).size(),
		"next_demand_id": _next_demand_id,
	}


func deserialize(data: Dictionary) -> void:
	setup()
	for raw: Variant in data.get("factions", []):
		var f: SocietyFaction = SocietyFaction.from_dict(raw)
		if factions.has(f.id):
			factions[f.id] = f
	for raw: Variant in data.get("grievances", []):
		var g: SocietyGrievance = SocietyGrievance.from_dict(raw)
		if grievances.has(g.kind):
			grievances[g.kind] = g
	demands.clear()
	for raw: Variant in data.get("demands", []):
		demands.append(SocietyDemand.from_dict(raw))
	_next_demand_id = int(data.get("next_demand_id", 1))
