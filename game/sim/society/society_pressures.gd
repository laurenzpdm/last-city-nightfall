class_name SocietyPressures
extends RefCounted
## Turns a reading of the city into named, worded, signed reasons.
##
## THIS IS THE LEGIBILITY LAYER. Every continuous force acting on hope or
## discontent is built here, and every one of them carries three things:
##
##   a key    stable, so a UI can bind an icon and a test can assert on it
##   a rate   meter points per in world hour, so the number is comparable
##   a text   a sentence with THIS RUN's numbers in it
##
## A factor with no sentence is a bug. "Discontent is rising" is not an
## explanation; "Eleven of nineteen homes are below freezing" is.
##
## Laws each get their OWN factor, keyed law:<id> and labelled with the law's
## title, rather than being summed into a single anonymous lump. When discontent
## is climbing because you signed The Pits three days ago, the book should be
## the thing the player sees, by name.

## Parallel arrays instead of an array of dictionaries: this is rebuilt every
## sample and read every tick, and the tick loop should touch floats, not keys.
var keys: Array[StringName] = []
var labels: PackedStringArray = PackedStringArray()
var texts: PackedStringArray = PackedStringArray()
var rates: PackedFloat32Array = PackedFloat32Array()
## 0 = hope, 1 = discontent.
var meters: PackedByteArray = PackedByteArray()

## grievance kind -> 0..1 cause strength, handed to SocietyCouncil.
var grievance_pressure: Dictionary[StringName, float] = {}
## grievance kind -> the sentence with the numbers in it.
var grievance_detail: Dictionary[StringName, String] = {}
## metric name -> value, the table demands are checked against.
var metric_values: Dictionary[StringName, float] = {}

const HOPE: int = 0
const DISCONTENT: int = 1
const MIN_RATE: float = 0.002

## HOPE HAS A CEILING AND THE CEILING IS EARNED.
##
## Comfort is not achievement. A warm, fed, housed city holds its hope steady
## somewhere in the middle; it does not climb to a hundred just by continuing to
## exist, because then the meter stops being a question and the whole system
## stops mattering. So every STANDING positive force fades out as hope
## approaches a ceiling set by how well the city is genuinely doing, and past
## that ceiling hope decays back down.
##
## The only things that lift hope above the ceiling are things that HAPPEN: a
## night survived, a wave held, a law kept, a promise met, research finished.
## Those are impulses and they bypass this entirely. That is the shape of the
## whole meter: comfort holds a floor, events buy the rest, and the rest leaks.
const CEILING_BASE: float = 26.0
const CEILING_SPAN: float = 40.0
const CEILING_SOLACE: float = 14.0
const CEILING_SOFTNESS: float = 12.0
## Per hour, per point above the ceiling.
const OVERSHOOT_DECAY: float = 0.075

var _headroom: float = 1.0
var _ceiling: float = 0.0


func size() -> int:
	return keys.size()


## Drops every standing force without touching the history. Used when a run
## ends: the bars stop where they stopped.
func clear_forces() -> void:
	keys.clear()
	labels.clear()
	texts.clear()
	rates.clear()
	meters.clear()


## Rebuilds every factor from scratch. Called once per sample, not per tick.
func compute(reading: SocietyReading, pop: SocietyPopulace, book: LawBook,
		council: SocietyCouncil, hope: float, discontent: float) -> void:
	keys.clear()
	labels.clear()
	texts.clear()
	rates.clear()
	meters.clear()
	grievance_pressure.clear()
	grievance_detail.clear()

	var people: float = maxf(pop.population, 1.0)
	var homeless_share: float = clampf(pop.homeless / people, 0.0, 1.0)
	var sick_share: float = clampf(pop.sick / people, 0.0, 1.0)
	var cold_share: float = 1.0 - reading.warm_share
	if reading.homes_total == 0:
		# No houses yet is not automatically the worst case. A camp pitched
		# around a lit hearth is cold; a camp with nothing lit is fatal, and the
		# difference has to show up as a different number.
		cold_share = clampf((SocietyDefs.COMFORT_C - pop.camp_temp_c) / 24.0, 0.0, 1.0)
	var work_hours: float = book.policy_value(&"work_hours")
	var strain: float = clampf((work_hours - 10.0) / 8.0, 0.0, 1.0)
	var corpse_share: float = clampf(pop.corpses / maxf(people * 0.05, 2.0), 0.0, 1.0)

	_ceiling = _hope_ceiling(reading, pop, book, homeless_share, sick_share, cold_share)
	_headroom = clampf((_ceiling - hope) / CEILING_SOFTNESS, 0.0, 1.0)

	_fill_metrics(reading, pop, book, hope, discontent, homeless_share, sick_share)

	_baselines(hope)
	_cold(reading, pop, cold_share)
	_shelter(reading, pop, homeless_share)
	_food(reading, pop)
	_health(pop, sick_share, book)
	_labour(book, work_hours, strain)
	_dead(pop, book, corpse_share)
	_infrastructure(reading)
	_weather(reading)
	_citizen_mood(reading, pop)
	_the_book(book)
	_the_council(council)
	_hope_floor(hope, discontent)

	_grievances(reading, pop, book, cold_share, homeless_share, sick_share,
		strain, corpse_share)


# =========================================================================
#  factors
# =========================================================================

## How well the city is actually doing, 0..1, and the hope it can sustain on
## that alone.
func _hope_ceiling(reading: SocietyReading, pop: SocietyPopulace, book: LawBook,
		homeless_share: float, sick_share: float, cold_share: float) -> float:
	var warm: float = 1.0 - clampf(cold_share, 0.0, 1.0)
	if pop.tented > 0.5:
		warm *= 1.0 - 0.5 * clampf(pop.tented / maxf(pop.population, 1.0), 0.0, 1.0)
	var fed: float = 1.0 - clampf(pop.hunger_share, 0.0, 1.0)
	var housed: float = 1.0 - clampf(homeless_share * 2.0, 0.0, 1.0)
	var well: float = 1.0 - clampf(sick_share * 3.0, 0.0, 1.0)
	var comfort: float = clampf(0.36 * warm + 0.26 * fed + 0.22 * housed + 0.16 * well, 0.0, 1.0)
	var solace: float = clampf(book.policy_value(&"solace"), 0.0, 1.5)
	var ceiling: float = CEILING_BASE + CEILING_SPAN * comfort + CEILING_SOLACE * solace
	if reading.storm:
		ceiling -= 6.0
	ceiling -= 2.5 * float(reading.era)
	return clampf(ceiling, 5.0, 92.0)


## Standing hope this city can currently justify. Exposed so a HUD can draw the
## line on the bar: everything above it is borrowed from recent good news.
func hope_ceiling() -> float:
	return _ceiling


func _push(meter: int, key: StringName, label: String, text: String, rate: float) -> void:
	# Standing optimism fades as it approaches what the city has earned.
	if meter == HOPE and rate > 0.0:
		rate *= _headroom
	if absf(rate) < MIN_RATE:
		return
	keys.append(key)
	labels.append(label)
	texts.append(text)
	rates.append(rate)
	meters.append(meter)


func _baselines(hope: float) -> void:
	_push(HOPE, &"drift", "Nothing is getting better",
		"Another day exactly like the last one. That costs something on its own.",
		SocietyDefs.HOPE_DRIFT_PER_HOUR)
	_push(DISCONTENT, &"settle", "Time passing",
		"Anger cools when nothing is feeding it.",
		SocietyDefs.DISCONTENT_SETTLE_PER_HOUR)
	if hope > _ceiling + 0.5:
		_push(HOPE, &"overshoot", "Hope is ahead of the facts",
			"People are still living off last week's good news. This city can hold "
			+ "about %d on what it actually has." % int(round(_ceiling)),
			-OVERSHOOT_DECAY * (hope - _ceiling))


func _cold(reading: SocietyReading, pop: SocietyPopulace, cold_share: float) -> void:
	if pop.tented > 0.5:
		var lit: String = "nothing is lit" if reading.hearths_lit == 0 \
			else "%s heat sources are lit" % SocietyDefs.spell(reading.hearths_lit)
		var text: String = "%s are under canvas at %.0f degrees, and %s." % [
			SocietyDefs.sentence(SocietyDefs.people(int(round(pop.tented)))), pop.camp_temp_c, lit]
		var share: float = clampf(pop.tented / maxf(pop.population, 1.0), 0.0, 1.0)
		_push(DISCONTENT, &"tents", "Sleeping under canvas", text, 3.4 * share * maxf(cold_share, 0.25))
		_push(HOPE, &"tents", "Sleeping under canvas", text, -1.6 * share * maxf(cold_share, 0.25))
		if pop.tent_capacity < SocietyPopulace.TENT_CAPACITY * 0.34:
			_push(HOPE, &"canvas_failing", "The canvas is going",
				"Half the tents have been cut up for wrappings and the rest are stiff with ice.",
				-1.3)
	if reading.homes_total == 0:
		return
	if cold_share > 0.02:
		var n: int = reading.homes_cold
		var text: String = "%s of %s homes %s below twelve degrees. The coldest is at %.0f." % [
			SocietyDefs.sentence(SocietyDefs.spell(n)), SocietyDefs.spell(reading.homes_total),
			SocietyDefs.is_are(n), reading.coldest_home_c]
		_push(DISCONTENT, &"cold_homes", "Cold houses", text, 4.6 * cold_share)
		_push(HOPE, &"cold_homes", "Cold houses", text, -2.2 * cold_share)
	if reading.warm_share > 0.55:
		_push(HOPE, &"warm_homes", "Warm rooms",
			"%d in a hundred of us sleep somewhere that does not hurt." % int(round(reading.warm_share * 100.0)),
			1.9 * reading.warm_share)
	if reading.homes_frozen > 0:
		# Share of the housing stock, not a raw count: a city with two hundred
		# houses and eight iced over is having a bad night, not a collapse, and
		# a linear term would have said otherwise at the top of the curve.
		var share: float = clampf(float(reading.homes_frozen) / maxf(float(reading.homes_total), 1.0),
			0.0, 1.0)
		_push(DISCONTENT, &"frozen_homes", "Frozen houses",
			"%s of %s houses have iced over completely. Nobody is going back into those." % [
				SocietyDefs.sentence(SocietyDefs.spell(reading.homes_frozen)),
				SocietyDefs.spell(reading.homes_total)],
			5.0 * share)


func _shelter(reading: SocietyReading, pop: SocietyPopulace, homeless_share: float) -> void:
	if homeless_share <= 0.005:
		if reading.homes_total > 0 and pop.tented <= 0.5:
			_push(HOPE, &"housed", "Everyone has a bunk",
				"There is a roof over every head in the city tonight.", 0.7)
		return
	var n: int = int(round(pop.homeless))
	var text: String = "%s have no bunk. They are sleeping in the lee of the wall at %.0f degrees." % [
		SocietyDefs.sentence(SocietyDefs.people(n)), reading.outdoor_c]
	_push(DISCONTENT, &"homeless", "Nowhere to sleep", text, 7.0 * homeless_share)
	_push(HOPE, &"homeless", "Nowhere to sleep", text, -3.0 * homeless_share)


func _food(reading: SocietyReading, pop: SocietyPopulace) -> void:
	var h: float = pop.hunger_share
	if h > 0.03:
		var short_people: int = int(round(pop.population * h))
		var text: String = "%s go without today. %s kitchens are running." % [
			SocietyDefs.sentence(SocietyDefs.people(short_people)),
			SocietyDefs.sentence(SocietyDefs.spell(int(round(reading.kitchens_running))))]
		_push(DISCONTENT, &"hunger", "Short rations", text, 6.4 * h)
		_push(HOPE, &"hunger", "Short rations", text, -2.6 * h)
	elif reading.kitchens > 0:
		_push(HOPE, &"fed", "Everyone eats",
			"The queue at the kitchen moves and everyone in it gets fed.", 1.1)


func _health(pop: SocietyPopulace, sick_share: float, book: LawBook) -> void:
	if sick_share > 0.02:
		var sick_n: int = int(round(pop.sick))
		var text: String = "%s %s ill. It is moving room to room." % [
			SocietyDefs.sentence(SocietyDefs.people(sick_n)), SocietyDefs.is_are(sick_n)]
		_push(DISCONTENT, &"sickness", "The fever", text, 4.0 * sick_share)
		_push(HOPE, &"sickness", "The fever", text, -1.8 * sick_share)
	var care: float = book.policy_value(&"medical_care")
	if care > 1.05:
		_push(HOPE, &"medicine", "Somewhere to be ill",
			"There is a building with a door that shuts and somebody in it who is not also on shift.",
			0.8 * (care - 1.0))
	elif care < 0.95:
		_push(DISCONTENT, &"triage", "The dying are moved aside",
			"The ones who will not recover have been put in the back room to make space.",
			2.2 * (1.0 - care))


func _labour(book: LawBook, work_hours: float, strain: float) -> void:
	if strain > 0.01:
		_push(DISCONTENT, &"overwork", "The shifts do not end",
			"A %.0f hour shift, every day, in this." % work_hours, 5.2 * strain)
		_push(HOPE, &"overwork", "The shifts do not end",
			"A %.0f hour shift, every day, in this." % work_hours, -1.5 * strain)
	if book.policy_flag(SocietyDefs.FLAG_CHILD_LABOUR):
		_push(DISCONTENT, &"child_labour", "The children are in the works",
			"Their parents watch them go in at the same hour they do.", 3.4)
		_push(HOPE, &"child_labour", "The children are in the works",
			"Everyone knows what a city looks like when it does this.", -1.7)
	if book.policy_flag(SocietyDefs.FLAG_PRESS_GANGS):
		_push(DISCONTENT, &"press_gangs", "Conscripted labour",
			"Men are being taken off the ration line and put on the ice.", 3.0)


func _dead(pop: SocietyPopulace, book: LawBook, corpse_share: float) -> void:
	if pop.corpses >= 1.0 and book.policy_value(&"corpse_capacity") <= 0.0:
		var text: String = "%s lie under a tarp by the east wall. The tarp is not long enough." % \
			SocietyDefs.sentence(SocietyDefs.people(int(round(pop.corpses))))
		_push(DISCONTENT, &"unburied", "The dead are still here", text, 4.4 * corpse_share)
		_push(HOPE, &"unburied", "The dead are still here", text, -2.0 * corpse_share)
	elif book.policy_flag(SocietyDefs.FLAG_NAMED_GRAVES) and pop.deaths_total >= 1.0:
		_push(HOPE, &"graves", "The dead have names",
			"There is a row of markers past the north gate and people walk out to it.", 1.0)
	if book.policy_flag(SocietyDefs.FLAG_RENDERING):
		_push(HOPE, &"rendering", "What is in the soup",
			"Everybody knows and nobody says it, and that is worse than saying it.", -3.2)
		_push(DISCONTENT, &"rendering", "What is in the soup",
			"Everybody knows and nobody says it.", 1.4)


## [P05] tracks bitterness per citizen from their own needs. That number is
## better than anything society could infer from the outside, so when it is
## there it gets its own line rather than being folded into an average.
func _citizen_mood(reading: SocietyReading, pop: SocietyPopulace) -> void:
	if reading.citizens_unrest > 0.02:
		var bitter: int = int(round(reading.citizens_unrest * pop.population))
		_push(DISCONTENT, &"bitterness", "People have had enough",
			"%s of us %s past arguing about it." % [
				SocietyDefs.sentence(SocietyDefs.people(bitter)), SocietyDefs.is_are(bitter)],
			5.5 * reading.citizens_unrest)
	if reading.citizens_morale >= 0.0 and reading.citizens_morale < 40.0:
		_push(HOPE, &"morale", "Nobody talks at meals",
			"Average morale across the city is %d out of a hundred." % int(round(reading.citizens_morale)),
			-2.0 * (40.0 - reading.citizens_morale) / 40.0)


func _infrastructure(reading: SocietyReading) -> void:
	if reading.heat_deficit_share > 0.03:
		_push(DISCONTENT, &"heat_deficit", "The grid is short",
			"The network is delivering %d in a hundred of what the city asked for." % \
				int(round((1.0 - reading.heat_deficit_share) * 100.0)),
			5.0 * reading.heat_deficit_share)
	if reading.frozen_buildings > 0:
		var share: float = clampf(float(reading.frozen_buildings)
			/ maxf(float(reading.buildings_operational) * 0.2, 5.0), 0.0, 1.0)
		_push(HOPE, &"frozen_buildings", "Buildings are icing over",
			"%d of the %d standing buildings have gone below the line and stopped."
				% [reading.frozen_buildings, reading.buildings_operational],
			-3.4 * share)


func _weather(reading: SocietyReading) -> void:
	if reading.storm:
		var name: String = reading.storm_title if reading.storm_title != "" else "The storm"
		_push(HOPE, &"storm", "The storm",
			"%s is on top of us and there is nothing to do but hold." % name, -1.9)
	if reading.era >= 2:
		_push(HOPE, &"winter", "It keeps getting colder",
			"The old people say it was never like this, and then they stop saying it.",
			-0.35 * float(reading.era))


## One factor per law in force. This is what makes the book visible in the
## tooltip instead of a mystery number.
func _the_book(book: LawBook) -> void:
	for id: StringName in book.signed_ids():
		var law: LawDef = book.get_law(id)
		if law == null:
			continue
		if absf(law.hope_rate) >= MIN_RATE:
			_push(HOPE, StringName("law:%s" % String(id)), law.title, law.signed_line, law.hope_rate)
		if absf(law.discontent_rate) >= MIN_RATE:
			_push(DISCONTENT, StringName("law:%s" % String(id)), law.title, law.signed_line,
				law.discontent_rate)
	var discipline: float = book.policy_value(&"discipline")
	if discipline > 0.0:
		_push(DISCONTENT, &"discipline", "Discipline",
			"People are angry in private now, which is not the same as being less angry.",
			-3.0 * discipline)
		_push(HOPE, &"discipline", "Discipline",
			"Nobody argues in the street. Nobody sings in it either.", -0.6 * discipline)
	var solace: float = book.policy_value(&"solace")
	if solace > 0.0:
		_push(HOPE, &"solace", "Something to hold onto",
			"Whatever it is they have decided the fire means, it is getting them up in the morning.",
			2.1 * solace)


func _the_council(council: SocietyCouncil) -> void:
	for g: SocietyGrievance in council.open_grievances():
		var f: SocietyFaction = council.faction_of(g.faction)
		var radical: int = 0 if f == null else f.radical
		var key: StringName = StringName("grievance:%s" % String(g.kind))
		var text: String = g.detail if g.detail != "" else g.complaint()
		var d_rate: float = g.discontent_rate(radical)
		var h_rate: float = g.hope_rate()
		_push(DISCONTENT, key, "%s: %s" % [SocietyDefs.faction_name(g.faction), g.title()],
			text, d_rate)
		_push(HOPE, key, "%s: %s" % [SocietyDefs.faction_name(g.faction), g.title()],
			text, h_rate)
	var resent: float = council.resentment_rate()
	if resent > 0.0:
		var worst: float = council.lowest_approval()
		_push(DISCONTENT, &"resentment", "They have decided about you",
			"The worst standing you have with anyone is %d out of a hundred, and %d %s stopped negotiating."
				% [int(round(worst)), council.radical_count(),
					"group has" if council.radical_count() == 1 else "groups have"],
			resent)
	var good: float = council.goodwill_rate()
	if good > 0.0:
		_push(HOPE, &"goodwill", "Somebody is on your side",
			"There are people in this city who will argue for you when you are not in the room.",
			good)


func _hope_floor(hope: float, discontent: float) -> void:
	if hope >= 72.0:
		_push(DISCONTENT, &"high_hope", "People believe it will work",
			"It is hard to stay furious in a city that looks like it is going to make it.",
			-1.4 * ((hope - 72.0) / 28.0 + 0.4))
	if discontent >= 62.0:
		_push(HOPE, &"anger", "The mood in the street",
			"You cannot build anything in a city this angry and everybody knows it.",
			-1.2 * ((discontent - 62.0) / 38.0 + 0.3))


# =========================================================================
#  grievance causes
# =========================================================================

func _grievances(reading: SocietyReading, pop: SocietyPopulace, book: LawBook,
		cold_share: float, homeless_share: float, sick_share: float,
		strain: float, corpse_share: float) -> void:
	var cold_detail: String = "The camp is at %.0f degrees and there is not a house in it." \
		% pop.camp_temp_c
	if reading.homes_total > 0:
		cold_detail = "%s of %s homes are below twelve degrees." % [
			SocietyDefs.sentence(SocietyDefs.spell(reading.homes_cold)),
			SocietyDefs.spell(reading.homes_total)]
	_grievance(&"cold", cold_share, cold_detail)
	var hungry: int = int(round(pop.population * pop.hunger_share))
	_grievance(&"hunger", pop.hunger_share, "%s %s short today." % [
		SocietyDefs.sentence(SocietyDefs.people(hungry)),
		SocietyDefs.verb_s(hungry, "go")])
	_grievance(&"overwork", strain,
		"The shift is %.0f hours long." % book.policy_value(&"work_hours"))
	var ill: int = int(round(pop.sick))
	_grievance(&"sickness", clampf(sick_share * 3.5, 0.0, 1.0),
		"%s %s ill." % [SocietyDefs.sentence(SocietyDefs.people(ill)),
			SocietyDefs.is_are(ill)])
	var tent_share: float = clampf(pop.tented / maxf(pop.population, 1.0), 0.0, 1.0)
	var unbunked: int = int(round(pop.homeless))
	var tented: int = int(round(pop.tented))
	_grievance(&"homeless", clampf(maxf(homeless_share * 2.5, tent_share * 0.55), 0.0, 1.0),
		"%s %s no bunk. %s %s under canvas." % [
			SocietyDefs.sentence(SocietyDefs.people(unbunked)), SocietyDefs.has_have(unbunked),
			SocietyDefs.sentence(SocietyDefs.people(tented)), SocietyDefs.is_are(tented)])

	var child: float = 0.9 if book.policy_flag(SocietyDefs.FLAG_CHILD_LABOUR) else 0.0
	if book.policy_value(&"child_risk") > 0.0 and child < 0.5:
		child = 0.45
	_grievance(&"children", child, "The children are in the works.")

	var dead: float = corpse_share if book.policy_value(&"corpse_capacity") <= 0.0 else corpse_share * 0.2
	var unburied: int = int(round(pop.corpses))
	_grievance(&"dead_unburied", dead, "%s %s stacked by the east wall." % [
		SocietyDefs.sentence(SocietyDefs.people(unburied)), SocietyDefs.is_are(unburied)])

	var fear: float = clampf(book.policy_value(&"discipline") * 0.55, 0.0, 1.0)
	if book.policy_flag(SocietyDefs.FLAG_MARTIAL_LAW):
		fear = maxf(fear, 0.75)
	_grievance(&"fear", fear, "Nobody argues in the street any more.")

	var faithless: float = 0.0
	if book.committed_branch() == SocietyDefs.BRANCH_ORDER:
		faithless = 0.5
	if book.policy_flag(SocietyDefs.FLAG_NEW_ORDER):
		faithless = 0.8
	_grievance(&"faithless", faithless, "There is nothing here to kneel to.")

	var disorder: float = 0.0
	if book.committed_branch() == SocietyDefs.BRANCH_FAITH:
		disorder = 0.42
	if book.policy_flag(SocietyDefs.FLAG_NEW_FAITH):
		disorder = 0.7
	if book.policy_value(&"discipline") <= 0.0 and pop.population >= 60.0:
		disorder = maxf(disorder, 0.3)
	_grievance(&"disorder", disorder, "Nobody stopped any of the three fights at the ration line.")


func _grievance(kind: StringName, pressure: float, detail: String) -> void:
	grievance_pressure[kind] = clampf(pressure, 0.0, 1.0)
	grievance_detail[kind] = detail


# =========================================================================
#  metric table for demands
# =========================================================================

func _fill_metrics(reading: SocietyReading, pop: SocietyPopulace, book: LawBook,
		hope: float, discontent: float, homeless_share: float, sick_share: float) -> void:
	metric_values.clear()
	metric_values[&"warm_share"] = reading.warm_share
	metric_values[&"cold_homes"] = float(reading.homes_cold)
	metric_values[&"hunger_share"] = pop.hunger_share
	metric_values[&"sick_share"] = sick_share
	metric_values[&"homeless_share"] = homeless_share
	metric_values[&"corpses"] = pop.corpses
	metric_values[&"deaths_today"] = pop.deaths_today
	metric_values[&"population"] = pop.population
	metric_values[&"hope"] = hope
	metric_values[&"discontent"] = discontent
	metric_values[&"work_hours"] = book.policy_value(&"work_hours")
	metric_values[&"ration"] = book.policy_value(&"ration")
	metric_values[&"heat_deficit_share"] = reading.heat_deficit_share


## Everything currently acting, as JSON-safe records. Used by serialize() so a
## critic reading state.json sees the forces, not only the result.
func serialize() -> Array:
	var out: Array = []
	for i: int in keys.size():
		out.append({
			"key": String(keys[i]),
			"meter": "hope" if meters[i] == HOPE else "discontent",
			"label": labels[i],
			"text": texts[i],
			"rate": snappedf(rates[i], 0.001),
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ra: float = absf(float(a["rate"]))
		var rb: float = absf(float(b["rate"]))
		if absf(ra - rb) > 0.0005:
			return ra > rb
		return String(a["key"]) < String(b["key"]))
	return out
