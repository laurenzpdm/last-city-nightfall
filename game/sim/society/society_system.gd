class_name SocietySystem
extends SimSystem
## [P06] Society: Hope, Discontent and Law. The conscience of the city.
##
## Two meters, opposed, and neither of them is ever allowed to move for a reason
## the player cannot read. That is the entire contract of this part. A society
## system that says "discontent 71" and nothing else is a mood ring. This one
## can always answer, per reason, with numbers from this run:
##
##   Discontent  +4.6/h  Cold houses      Eleven of nineteen homes are below
##                                        twelve degrees. The coldest is at -9.
##   Discontent  +3.4/h  The Pits         The dead go under the ice at the north
##                                        gate and the ice is not deep.
##   Hope        -2.6    Three froze      They had no bunk and no canvas.
##
## HOW IT FITS TOGETHER
##
##   SocietyReading    one scan of the city per second. Physical facts only.
##   SocietyPopulace   the people. A STAND IN that yields to [P05] on arrival.
##   LawBook           the graph, the seal and the record of what you signed.
##   SocietyPressures  reading + people + book -> named, worded, signed forces.
##   SocietyLedger     every force, integrated, with four views of its history.
##   SocietyCouncil    factions, grievances and demands with deadlines.
##   SocietyVerdict    the escalation ladder, and the two ways a run ends.
##
## TIMING. Meters integrate every tick. The world is re-read, pressures rebuilt
## and the council polled once every 20 ticks. That is what keeps step() at
## roughly a hundredth of the tick budget on a full base: the per tick path is
## a walk over about thirty floats and a dictionary write each.
##
## WHAT OTHER PARTS READ
##   hope() / discontent()                the meters, 0..100
##   hope_reasons() / discontent_reasons() ranked, worded, with rates
##   policy_value(key) / policy_flag(f)   what the book has done to the city
##   work_hours() / ration_multiplier() / labour_multiplier()
##   has_law(id) / laws_signed()
##   population() / deaths_total()        while [P05] is absent
##   demands() / grievances() / factions()
##   is_over() / end_reason()

const SYSTEM_ORDER: int = 60
const TAG: String = "society"
const RNG_STREAM: String = "society"

## Bus.hope_changed / discontent_changed are emitted at most this often, and
## only when the meter actually moved.
const ANNOUNCE_EVERY: int = SocietyDefs.SAMPLE_EVERY
const ANNOUNCE_EPSILON: float = 0.005

var hope_value: float = SocietyDefs.HOPE_START
var discontent_value: float = SocietyDefs.DISCONTENT_START

var book: LawBook = null
var ledger: SocietyLedger = null
var council: SocietyCouncil = null
var populace: SocietyPopulace = null
var verdict: SocietyVerdict = null

var _reading: SocietyReading = null
var _pressures: SocietyPressures = null

var _tick: int = 0
var _day: int = 1
var _day_ticks: int = SocietyDefs.DEFAULT_DAY_TICKS
var _hour_ticks: int = SocietyDefs.DEFAULT_DAY_TICKS / 24
var _hours_per_tick: float = 1.0 / float(SocietyDefs.DEFAULT_DAY_TICKS / 24)
var _sample_hours: float = 1.0

var _heat: SimSystem = null
var _climate: SimSystem = null
var _build: SimSystem = null
var _citizens: SimSystem = null
var _research: SimSystem = null
var _threat: SimSystem = null

var _last_hope_announced: float = 0.0
var _last_discontent_announced: float = 0.0
var _destroyed_seen: int = 0
var _research_seen: int = 0
var _waves_seen: int = 0
var _law_problems: int = 0
var _rate_hope: float = 0.0
var _rate_discontent: float = 0.0


func system_name() -> StringName:
	return &"society"


func _init() -> void:
	order = SYSTEM_ORDER


# =========================================================================
#  lifecycle
# =========================================================================

func setup() -> void:
	order = SYSTEM_ORDER
	hope_value = SocietyDefs.HOPE_START
	discontent_value = SocietyDefs.DISCONTENT_START
	_last_hope_announced = hope_value
	_last_discontent_announced = discontent_value

	book = LawBook.new()
	ledger = SocietyLedger.new()
	council = SocietyCouncil.new()
	populace = SocietyPopulace.new()
	verdict = SocietyVerdict.new()
	_reading = SocietyReading.new()
	_pressures = SocietyPressures.new()

	council.setup()
	populace.reset()
	verdict.reset()
	_tick = 0
	_day = 1
	_destroyed_seen = 0
	_research_seen = 0
	_waves_seen = 0
	_rate_hope = 0.0
	_rate_discontent = 0.0
	_set_day_length(SocietyDefs.DEFAULT_DAY_TICKS)

	var problems: PackedStringArray = book.load_from_registry()
	_law_problems = problems.size()
	for p: String in problems:
		# A malformed law tree is a content bug that silently removes choices
		# from the game. It fails the run on purpose.
		Log.error(TAG, p)
	if book.count() == 0:
		Log.warn(TAG, "the Book of Laws is empty; nothing in game/content/laws loaded")


func post_setup() -> void:
	_heat = Sim.get_system(&"heat")
	_climate = Sim.get_system(&"climate")
	_build = Sim.get_system(&"build")
	_citizens = Sim.get_system(&"citizens")
	_research = Sim.get_system(&"research")
	_threat = Sim.get_system(&"threat")
	_sample_world()
	_set_day_length(_reading.day_ticks)
	_day = _reading.day
	_rebuild_pressures()
	Log.info(TAG, "ready — %d laws in the book, people from %s, sees %s" % [
		book.count(),
		"citizens" if _reading.citizens_authoritative() else "its own stand-in model",
		_source_list()])


func _source_list() -> String:
	var parts: PackedStringArray = PackedStringArray()
	for s: StringName in [&"climate", &"heat", &"build", &"citizens", &"research", &"threat"]:
		if _reading.has_source(s):
			parts.append(String(s))
	return "nothing yet" if parts.is_empty() else ", ".join(parts)


func _set_day_length(ticks: int) -> void:
	_day_ticks = maxi(24, ticks)
	_hour_ticks = maxi(1, _day_ticks / 24)
	_hours_per_tick = 1.0 / float(_hour_ticks)
	_sample_hours = float(SocietyDefs.SAMPLE_EVERY) * _hours_per_tick


# =========================================================================
#  the tick
# =========================================================================

func step(tick: int) -> void:
	_tick = tick
	_advance_seal(tick)
	if tick % SocietyDefs.SAMPLE_EVERY == 0:
		_sample(tick)
	_integrate()
	if tick % ANNOUNCE_EVERY == 0:
		_announce()


## Per tick, and only this. Everything expensive happens on the sample.
func _integrate() -> void:
	var n: int = _pressures.size()
	if n == 0:
		return
	var dt_hours: float = _hours_per_tick
	var raw_hope: float = 0.0
	var raw_discontent: float = 0.0
	for i: int in n:
		if _pressures.meters[i] == SocietyPressures.HOPE:
			raw_hope += _pressures.rates[i]
		else:
			raw_discontent += _pressures.rates[i]
	_rate_hope = raw_hope
	_rate_discontent = raw_discontent

	var want_hope: float = raw_hope * dt_hours
	var want_discontent: float = raw_discontent * dt_hours
	var new_hope: float = clampf(hope_value + want_hope, 0.0, SocietyDefs.METER_MAX)
	var new_discontent: float = clampf(discontent_value + want_discontent, 0.0, SocietyDefs.METER_MAX)
	# When a meter is pinned at an end, every reason is credited with the share
	# of the movement that actually happened. Otherwise the reasons stop summing
	# to the meter, and a ledger whose numbers do not add up is worse than none.
	var scale_hope: float = 1.0
	if absf(want_hope) > 0.0000001:
		scale_hope = (new_hope - hope_value) / want_hope
	var scale_discontent: float = 1.0
	if absf(want_discontent) > 0.0000001:
		scale_discontent = (new_discontent - discontent_value) / want_discontent
	hope_value = new_hope
	discontent_value = new_discontent

	for i: int in n:
		var is_hope: bool = _pressures.meters[i] == SocietyPressures.HOPE
		var scale: float = scale_hope if is_hope else scale_discontent
		if absf(scale) < 0.0000001:
			continue
		ledger.add(
			SocietyDefs.METER_HOPE if is_hope else SocietyDefs.METER_DISCONTENT,
			_pressures.keys[i], _pressures.labels[i], _pressures.texts[i],
			_pressures.rates[i] * dt_hours * scale, _pressures.rates[i], _tick)


## Once per second: re-read the world, re-run the people, re-rank the forces,
## poll the council, and let the verdict escalate.
func _sample(tick: int) -> void:
	ledger.decay(_sample_hours)
	_sample_world()
	if _reading.day != _day:
		_roll_day(_reading.day)
	_apply_external_events()

	for ev: Dictionary in populace.step(_reading, book, _sample_hours):
		_on_populace_event(ev)

	_rebuild_pressures()

	var events: Array[Dictionary] = council.sample(
		_pressures.grievance_pressure, _pressures.grievance_detail,
		_pressures.metric_values, book, _sample_hours, tick, _hour_ticks)
	for ev: Dictionary in events:
		_on_council_event(ev)

	for ev: Dictionary in verdict.step(hope_value, discontent_value, tick, _hour_ticks, _verdict_context()):
		_on_verdict_event(ev)


func _sample_world() -> void:
	if _citizens == null:
		_citizens = Sim.get_system(&"citizens")
	if _research == null:
		_research = Sim.get_system(&"research")
	if _threat == null:
		_threat = Sim.get_system(&"threat")
	_reading.sample(_heat, _climate, _build, _citizens, _research, _threat)
	if _reading.day_ticks != _day_ticks:
		_set_day_length(_reading.day_ticks)


func _rebuild_pressures() -> void:
	_pressures.compute(_reading, populace, book, council, hope_value, discontent_value)


func _roll_day(new_day: int) -> void:
	var survived: int = new_day - _day
	_day = new_day
	ledger.roll_day()
	if survived > 0:
		# Getting to dawn is worth something on its own, and it is worth less
		# when the night cost you people.
		var toll: int = int(round(populace.deaths_today))
		var gain: float = maxf(0.6, 2.8 - 0.55 * float(toll))
		var line: String = "The light came back. Nobody expected anything else and everybody checked."
		if toll > 0:
			line = "The light came back. %s did not." % SocietyDefs.people(toll).capitalize()
		_impulse(SocietyDefs.METER_HOPE, &"dawn", "Another dawn", line, gain)
	for ev: Dictionary in populace.dawn(_reading, hope_value):
		_on_populace_event(ev)


# =========================================================================
#  events in
# =========================================================================

## Cumulative counters from other parts, turned into impulses on their delta.
func _apply_external_events() -> void:
	var lost: int = _reading.buildings_destroyed_total - _destroyed_seen
	if _destroyed_seen == 0 and _reading.buildings_destroyed_total > 0 and _tick <= SocietyDefs.SAMPLE_EVERY:
		lost = 0
	_destroyed_seen = _reading.buildings_destroyed_total
	if lost > 0:
		_impulse(SocietyDefs.METER_HOPE, &"buildings_lost", "Something was taken from us",
			"%s buildings came down and everyone watched it happen." % SocietyDefs.spell(lost).capitalize(),
			-1.8 * float(lost))
		_impulse(SocietyDefs.METER_DISCONTENT, &"buildings_lost", "Something was taken from us",
			"%s buildings came down." % SocietyDefs.spell(lost).capitalize(), 1.4 * float(lost))

	var done: int = _reading.research_completed_total - _research_seen
	_research_seen = _reading.research_completed_total
	if done > 0:
		_impulse(SocietyDefs.METER_HOPE, &"research", "We worked something out",
			"The workshop has something it did not have this morning.", 3.0 * float(done))

	var cleared: int = _reading.waves_cleared_total - _waves_seen
	_waves_seen = _reading.waves_cleared_total
	if cleared > 0:
		_impulse(SocietyDefs.METER_HOPE, &"wave_held", "The line held",
			"Whatever came out of the dark went back into it.", 5.0 * float(cleared))
		_impulse(SocietyDefs.METER_DISCONTENT, &"wave_held", "The line held",
			"Nobody argues with the person who kept the wall up.", -4.0 * float(cleared))


func _on_populace_event(ev: Dictionary) -> void:
	var kind: StringName = StringName(String(ev.get("kind", "")))
	var n: int = int(ev.get("count", 0))
	var detail: String = String(ev.get("detail", ""))
	if kind == &"death":
		var cause: StringName = StringName(String(ev.get("cause", "cold")))
		var key: StringName = StringName("deaths_%s" % String(cause))
		var label: String = "Deaths: %s" % String(cause).replace("_", " ")
		_impulse(SocietyDefs.METER_HOPE, key, label, detail, SocietyDefs.DEATH_HOPE * float(n))
		_impulse(SocietyDefs.METER_DISCONTENT, key, label, detail, SocietyDefs.DEATH_DISCONTENT * float(n))
		Bus.narrative_event.emit(SocietyDefs.EV_DEATHS, {
			"cause": String(cause), "count": n, "text": detail,
			"population": snappedf(populace.population, 0.01),
		})
		Bus.alert_raised.emit(SocietyDefs.SEV_WARN, StringName("society_death_%s" % String(cause)),
			detail, Vector2.ZERO)
	elif kind == &"arrival":
		_impulse(SocietyDefs.METER_HOPE, &"arrivals", "Somebody came",
			detail, 1.4 * float(n))
		Bus.narrative_event.emit(SocietyDefs.EV_ARRIVALS, {
			"count": n, "text": detail, "population": snappedf(populace.population, 0.01),
		})


func _on_council_event(ev: Dictionary) -> void:
	var kind: StringName = StringName(String(ev.get("kind", "")))
	var text: String = String(ev.get("text", ""))
	match kind:
		&"grievance_opened":
			Bus.narrative_event.emit(SocietyDefs.EV_GRIEVANCE_OPENED, ev)
			Bus.alert_raised.emit(SocietyDefs.SEV_NOTE,
				StringName("society_grievance_%s" % String(ev.get("grievance", ""))),
				text, Vector2.ZERO)
			Log.info(TAG, "grievance opened: %s" % text)
		&"grievance_closed":
			Bus.narrative_event.emit(SocietyDefs.EV_GRIEVANCE_CLOSED, ev)
			_impulse(SocietyDefs.METER_HOPE,
				StringName("resolved_%s" % String(ev.get("grievance", ""))),
				"Settled: %s" % String(ev.get("title", "")), text, 2.2)
		&"demand_made":
			Bus.narrative_event.emit(SocietyDefs.EV_DEMAND_MADE, ev)
			Bus.alert_raised.emit(SocietyDefs.SEV_WARN,
				StringName("society_demand_%s" % String(ev.get("faction", ""))),
				"%s  [%s, %.0f hours]" % [text, String(ev.get("terms", "")), float(ev.get("hours", 0.0))],
				Vector2.ZERO)
			Log.info(TAG, "demand: %s (%s)" % [text, String(ev.get("terms", ""))])
		&"demand_met":
			Bus.narrative_event.emit(SocietyDefs.EV_DEMAND_MET, ev)
			var met_key: StringName = StringName("demand_met_%s" % String(ev.get("faction", "")))
			_impulse(SocietyDefs.METER_HOPE, met_key, "A promise kept", text,
				SocietyDefs.DEMAND_MET_HOPE)
			_impulse(SocietyDefs.METER_DISCONTENT, met_key, "A promise kept", text,
				SocietyDefs.DEMAND_MET_DISCONTENT)
		&"demand_failed":
			Bus.narrative_event.emit(SocietyDefs.EV_DEMAND_FAILED, ev)
			Bus.alert_raised.emit(SocietyDefs.SEV_WARN,
				StringName("society_demand_failed_%s" % String(ev.get("faction", ""))),
				text, Vector2.ZERO)
			var fail_key: StringName = StringName("demand_failed_%s" % String(ev.get("faction", "")))
			_impulse(SocietyDefs.METER_HOPE, fail_key, "A promise broken", text,
				SocietyDefs.DEMAND_FAILED_HOPE)
			_impulse(SocietyDefs.METER_DISCONTENT, fail_key, "A promise broken", text,
				SocietyDefs.DEMAND_FAILED_DISCONTENT)
			Log.info(TAG, "demand failed: %s" % text)


func _on_verdict_event(ev: Dictionary) -> void:
	var kind: StringName = StringName(String(ev.get("kind", "")))
	var text: String = String(ev.get("text", ""))
	match kind:
		&"unrest":
			Bus.narrative_event.emit(SocietyDefs.EV_UNREST, ev)
			Bus.alert_raised.emit(SocietyDefs.SEV_WARN, SocietyDefs.EV_UNREST, text, Vector2.ZERO)
			Log.info(TAG, "unrest stage %d: discontent %.1f" % [int(ev.get("stage", 0)), discontent_value])
		&"despair":
			Bus.narrative_event.emit(SocietyDefs.EV_DESPAIR, ev)
			Bus.alert_raised.emit(SocietyDefs.SEV_WARN, SocietyDefs.EV_DESPAIR, text, Vector2.ZERO)
			Log.info(TAG, "despair stage %d: hope %.1f" % [int(ev.get("stage", 0)), hope_value])
		&"ultimatum":
			Bus.narrative_event.emit(SocietyDefs.EV_ULTIMATUM, ev)
			Bus.alert_raised.emit(SocietyDefs.SEV_WARN, SocietyDefs.EV_ULTIMATUM, text, Vector2.ZERO)
			Log.warn(TAG, "ultimatum: %s" % text)
		&"ultimatum_lifted":
			Bus.narrative_event.emit(SocietyDefs.EV_ULTIMATUM_LIFTED, ev)
			_impulse(SocietyDefs.METER_HOPE, &"reprieve", "They went home", text, 4.0)
		&"game_over":
			var reason: String = String(ev.get("reason", ""))
			Bus.narrative_event.emit(SocietyDefs.EV_UNREST if reason == SocietyDefs.REASON_EXILE
				else SocietyDefs.EV_DESPAIR, ev)
			Log.warn(TAG, "run over (%s): %s" % [reason, text])
			Bus.game_over.emit(reason)


func _verdict_context() -> Dictionary:
	var worst: String = ""
	var open: Array[SocietyGrievance] = council.open_grievances()
	if not open.is_empty():
		var g: SocietyGrievance = open[0]
		worst = "%s %s" % [g.complaint(), g.detail]
	var angriest: String = ""
	var lowest: float = 1.0
	for id: StringName in SocietyDefs.FACTION_IDS:
		var f: SocietyFaction = council.faction_of(id)
		if f != null and f.approval < lowest:
			lowest = f.approval
			angriest = f.name_of()
	return {"worst_grievance": worst.strip_edges(), "angriest_faction": angriest}


# =========================================================================
#  impulses
# =========================================================================

## A one-off meter change with a reason attached. This is the ONLY other way a
## meter moves; there is no path from anywhere to hope_value that skips here.
func _impulse(meter: StringName, key: StringName, label: String, text: String,
		amount: float) -> void:
	if absf(amount) < 0.0001:
		return
	var applied: float = 0.0
	if meter == SocietyDefs.METER_HOPE:
		var before: float = hope_value
		hope_value = clampf(hope_value + amount, 0.0, SocietyDefs.METER_MAX)
		applied = hope_value - before
	else:
		var before_d: float = discontent_value
		discontent_value = clampf(discontent_value + amount, 0.0, SocietyDefs.METER_MAX)
		applied = discontent_value - before_d
	if absf(applied) < 0.0000001:
		return
	ledger.add(meter, key, label, text, applied, 0.0, _tick)


func _announce() -> void:
	var dh: float = hope_value - _last_hope_announced
	if absf(dh) >= ANNOUNCE_EPSILON:
		_last_hope_announced = hope_value
		Bus.hope_changed.emit(snappedf(hope_value, 0.001), snappedf(dh, 0.001))
	var dd: float = discontent_value - _last_discontent_announced
	if absf(dd) >= ANNOUNCE_EPSILON:
		_last_discontent_announced = discontent_value
		Bus.discontent_changed.emit(snappedf(discontent_value, 0.001), snappedf(dd, 0.001))


# =========================================================================
#  the seal
# =========================================================================

func _advance_seal(tick: int) -> void:
	var law: LawDef = book.advance(tick, _hour_ticks)
	if law == null:
		return
	council.apply_law(law, tick)
	if absf(law.hope_on_sign) > 0.0001:
		_impulse(SocietyDefs.METER_HOPE, StringName("law:%s" % String(law.id)),
			law.title, law.signed_line, law.hope_on_sign)
	if absf(law.discontent_on_sign) > 0.0001:
		_impulse(SocietyDefs.METER_DISCONTENT, StringName("law:%s" % String(law.id)),
			law.title, law.signed_line, law.discontent_on_sign)
	_rebuild_pressures()
	Bus.law_enacted.emit(law.id)
	Bus.narrative_event.emit(SocietyDefs.EV_LAW_SIGNED, {
		"id": String(law.id), "title": law.title, "branch": String(law.branch),
		"text": law.signed_line, "prose": law.prose,
		"signed": book.signed_count(),
	})
	Bus.alert_raised.emit(SocietyDefs.SEV_NOTE, SocietyDefs.EV_LAW_SIGNED,
		"%s is in force. %s" % [law.title, law.signed_line], Vector2.ZERO)
	Log.info(TAG, "law in force: %s" % law.summary())


# =========================================================================
#  public API
# =========================================================================

func hope() -> float:
	return hope_value


func discontent() -> float:
	return discontent_value


## Points per hour hope is currently moving, summed over every reason.
func hope_rate() -> float:
	return _rate_hope


func discontent_rate() -> float:
	return _rate_discontent


## Every reason acting on hope, strongest first. Each entry carries key, label,
## a sentence with this run's numbers in it, the live rate per hour, and what it
## has cost or earned today and over the whole run.
func hope_reasons(limit: int = 0) -> Array[Dictionary]:
	return ledger.top(SocietyDefs.METER_HOPE, limit)


func discontent_reasons(limit: int = 0) -> Array[Dictionary]:
	return ledger.top(SocietyDefs.METER_DISCONTENT, limit)


## Both meters at once, ranked by how much they are moving right now.
func reasons(limit: int = 0) -> Array[Dictionary]:
	return ledger.all(limit)


## What one specific reason has done, or an empty dictionary.
func reason(key: StringName) -> Dictionary:
	for r: Dictionary in ledger.all():
		if String(r["key"]) == String(key):
			return r
	return {}


func law_book() -> LawBook:
	return book


func has_law(id: StringName) -> bool:
	return book.is_signed(id)


func laws_signed() -> Array[StringName]:
	return book.signed_ids()


func laws_signed_count() -> int:
	return book.signed_count()


## Every page, with its current standing, for the book UI.
func book_view() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for law: LawDef in book.all():
		var av: Dictionary = book.availability(law.id, _day, _tick)
		out.append({
			"id": String(law.id),
			"title": law.title,
			"branch": String(law.branch),
			"section": law.section,
			"tier": law.tier,
			"prose": law.prose,
			"argument_for": law.argument_for,
			"argument_against": law.argument_against,
			"signed_line": law.signed_line,
			"signed": book.is_signed(law.id),
			"signed_tick": book.signed_at(law.id),
			"pending": book.pending_id() == law.id,
			"available": bool(av.get("ok", false)),
			"reason": String(av.get("reason", "")),
			"blocked_by": String(av.get("blocked_by", "")),
			"requires": _names(law.requires),
			"excludes": _names(law.excludes),
			"tags": _names(law.tags),
		})
	return out


func available_laws() -> Array[StringName]:
	var out: Array[StringName] = []
	for law: LawDef in book.available(_day, _tick):
		out.append(law.id)
	return out


## Puts a law to the room. Returns {ok, reason, hours}. This is what the UI
## calls through Sim.submit_command({"system": &"society", "op": "sign", ...}).
func sign_law(id: StringName) -> Dictionary:
	var res: Dictionary = book.propose(id, _day, _tick, _hour_ticks)
	if not bool(res.get("ok", false)):
		Bus.narrative_event.emit(SocietyDefs.EV_LAW_REFUSED, {
			"id": String(id), "reason": String(res.get("reason", "")),
		})
		return {"ok": false, "reason": String(res.get("reason", "")), "hours": 0.0}
	var law: LawDef = book.get_law(id)
	var hours: float = law.effective_debate_hours()
	Bus.narrative_event.emit(SocietyDefs.EV_LAW_PROPOSED, {
		"id": String(id), "title": law.title, "prose": law.prose,
		"argument_for": law.argument_for, "argument_against": law.argument_against,
		"hours": hours,
	})
	Log.info(TAG, "proposed %s, %0.1f hours of argument" % [law.title, hours])
	return {"ok": true, "reason": "", "hours": hours}


func withdraw_law() -> bool:
	var was: StringName = book.withdraw()
	if was == &"":
		return false
	# Taking a page back off the table is not free. Everyone saw it there.
	_impulse(SocietyDefs.METER_DISCONTENT, &"withdrawn", "You took it back",
		"It was read out, argued over for hours, and then quietly withdrawn.", 2.5)
	return true


func pending_law() -> StringName:
	return book.pending_id()


func seal_hours_left() -> float:
	return float(book.cooldown_ticks_left(_tick)) / float(_hour_ticks)


func policy_value(key: StringName) -> float:
	return book.policy_value(key)


func policy_flag(f: StringName) -> bool:
	return book.policy_flag(f)


## Hours the city works per day. [P05] reads this to set shift length.
func work_hours() -> float:
	return book.policy_value(&"work_hours")


## Share of a full ration actually served. [P04] and [P05] read this.
func ration_multiplier() -> float:
	return book.policy_value(&"ration")


## Multiplier on hands available for work, from shift length, child labour and
## conscription. [P11] build and [P04] production read this.
func labour_multiplier() -> float:
	var hours: float = book.policy_value(&"work_hours")
	var pool: float = book.policy_value(&"labour_pool")
	return clampf(pool * (hours / 10.0), 0.2, 3.0)


## How far a unit of food goes. Sawdust and worse push this up.
func food_yield() -> float:
	return book.policy_value(&"food_yield")


func factions() -> Array[Dictionary]:
	return council.faction_views()


func approval_of(faction: StringName) -> float:
	return council.approval_of(faction)


func grievances() -> Array[Dictionary]:
	return council.grievance_views()


func active_grievances() -> int:
	return council.active_grievance_count()


func demands() -> Array[Dictionary]:
	return council.demand_views(_tick, _hour_ticks)


func population() -> float:
	return populace.population


func deaths_total() -> float:
	return populace.deaths_total


func sick_count() -> float:
	return populace.sick


func homeless_count() -> float:
	return populace.homeless


func hunger_share() -> float:
	return populace.hunger_share


## True once the run has ended, either way.
func is_over() -> bool:
	return verdict.ended


func end_reason() -> String:
	return verdict.end_reason


## What the player is being warned about right now, for the HUD.
func warning_state() -> Dictionary:
	return {
		"unrest_stage": verdict.unrest_stage,
		"despair_stage": verdict.despair_stage,
		"ultimatum": verdict.ultimatum_active(),
		"vigil": verdict.vigil_active(),
		"hours_left": snappedf(verdict.hours_left(_tick, _hour_ticks), 0.01),
		"ended": verdict.ended,
		"reason": verdict.end_reason,
	}


## The city as society currently sees it. Read-only, for overlays and stats.
func city_reading() -> Dictionary:
	return _reading.serialize()


func day() -> int:
	return _day


func hour_ticks() -> int:
	return _hour_ticks


# =========================================================================
#  commands
# =========================================================================

func handle_command(cmd: Dictionary) -> void:
	var op: String = String(cmd.get("op", ""))
	match op:
		"sign":
			var id: StringName = StringName(String(cmd.get("law", cmd.get("id", ""))))
			var res: Dictionary = sign_law(id)
			if not bool(res.get("ok", false)):
				Log.warn(TAG, "cannot sign '%s': %s" % [String(id), String(res.get("reason", ""))])
		"withdraw":
			if not withdraw_law():
				Log.warn(TAG, "nothing is being argued")
		"nudge":
			var meter: StringName = StringName(String(cmd.get("meter", "hope")))
			var amount: float = float(cmd.get("amount", 0.0))
			var why: String = String(cmd.get("reason", "A scripted event."))
			_impulse(meter, StringName(String(cmd.get("key", "scripted"))),
				String(cmd.get("label", "Scripted")), why, amount)
		"set_meter":
			var m: StringName = StringName(String(cmd.get("meter", "hope")))
			var v: float = clampf(float(cmd.get("value", 0.0)), 0.0, SocietyDefs.METER_MAX)
			if m == SocietyDefs.METER_HOPE:
				hope_value = v
			else:
				discontent_value = v
			Log.info(TAG, "%s set to %.1f" % [String(m), v])
		"approval":
			council.adjust_approval(StringName(String(cmd.get("faction", ""))),
				float(cmd.get("delta", 0.0)))
		"dump":
			_dump()
		_:
			Log.warn(TAG, "unknown op '%s'" % op)


func _dump() -> void:
	Log.info(TAG, "hope %.1f (%+.2f/h), discontent %.1f (%+.2f/h), pop %.0f, dead %.0f, laws %d" % [
		hope_value, _rate_hope, discontent_value, _rate_discontent,
		populace.population, populace.deaths_total, book.signed_count()])
	for r: Dictionary in reasons(6):
		Log.info(TAG, "  %-12s %-28s %+7.2f/h  %s" % [
			String(r["meter"]), String(r["label"]), float(r["rate"]), String(r["text"])])
	for d: Dictionary in demands():
		Log.info(TAG, "  demand: %s wants %s (%.1f h left)" % [
			String(d["faction_name"]), String(d["terms"]), float(d["hours_left"])])


# =========================================================================
#  persistence and metrics
# =========================================================================

func serialize() -> Dictionary:
	return {
		"hope": snappedf(hope_value, 0.001),
		"discontent": snappedf(discontent_value, 0.001),
		"hope_rate": snappedf(_rate_hope, 0.001),
		"discontent_rate": snappedf(_rate_discontent, 0.001),
		"day": _day,
		"hour_ticks": _hour_ticks,
		"reasons": ledger.serialize(),
		"forces": _pressures.serialize(),
		"book": book.serialize(),
		"council": council.serialize(_tick, _hour_ticks),
		"people": populace.serialize(),
		"verdict": verdict.serialize(_tick, _hour_ticks),
		"city": _reading.serialize(),
		"seen": {
			"destroyed": _destroyed_seen,
			"research": _research_seen,
			"waves": _waves_seen,
		},
	}


func deserialize(data: Dictionary) -> void:
	hope_value = clampf(float(data.get("hope", SocietyDefs.HOPE_START)), 0.0, SocietyDefs.METER_MAX)
	discontent_value = clampf(float(data.get("discontent", SocietyDefs.DISCONTENT_START)),
		0.0, SocietyDefs.METER_MAX)
	_last_hope_announced = hope_value
	_last_discontent_announced = discontent_value
	_day = int(data.get("day", 1))
	ledger.deserialize(data.get("reasons", []))
	book.deserialize(data.get("book", {}))
	council.deserialize(data.get("council", {}))
	populace.deserialize(data.get("people", {}))
	verdict.deserialize(data.get("verdict", {}))
	var seen: Dictionary = data.get("seen", {})
	_destroyed_seen = int(seen.get("destroyed", 0))
	_research_seen = int(seen.get("research", 0))
	_waves_seen = int(seen.get("waves", 0))
	_sample_world()
	_rebuild_pressures()
	Log.info(TAG, "restored — hope %.1f, discontent %.1f, %d laws" % [
		hope_value, discontent_value, book.signed_count()])


func metrics() -> Dictionary:
	return {
		"hope": snappedf(hope_value, 0.01),
		"discontent": snappedf(discontent_value, 0.01),
		"hope_rate": snappedf(_rate_hope, 0.01),
		"discontent_rate": snappedf(_rate_discontent, 0.01),
		"laws_signed": book.signed_count(),
		"active_grievances": council.active_grievance_count(),
		"open_demands": council.open_demands().size(),
		"population": snappedf(populace.population, 0.01),
		"deaths": snappedf(populace.deaths_total, 0.01),
		"sick": snappedf(populace.sick, 0.01),
		"homeless": snappedf(populace.homeless, 0.01),
		"hunger": snappedf(populace.hunger_share, 0.001),
		"approval_min": snappedf(council.lowest_approval(), 0.01),
		"unrest_stage": verdict.unrest_stage,
		"despair_stage": verdict.despair_stage,
		"ended": 1 if verdict.ended else 0,
	}


func _names(arr: Array[StringName]) -> Array:
	var out: Array = []
	for a: StringName in arr:
		out.append(String(a))
	return out
