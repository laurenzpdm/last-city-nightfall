class_name NarrativeSystem
extends SimSystem
## [P22] Events, dilemmas, the campaign spine and the small writing.
##
## WHAT THIS PART REFUSES TO BE
##
## A timer. Nothing here fires because a clock reached a number. Every event
## carries an `all_of` list of clauses over the fact table in NarrativeDefs, and
## every clause it fired on is handed to the player with its live value in it.
## The card does not say "a delegation has arrived"; it says "a delegation has
## arrived. Discontent (66.4) is at or above 62, and has been for six hours."
## An event that cannot say that is refused at load.
##
## HOW IT FITS TOGETHER
##
##   NarrativeWorld     one scan of the city per second, flattened to facts
##   NarrativeEventDef  authored content from game/content/events/*.tres
##   NarrativeOption    a choice, with a price that is printed before it is paid
##   NarrativeEffects   the price, applied through other parts' command surfaces
##   NarrativeCampaign  the spine, and the account it renders at the end
##   NarrativeFlavour   150 lines of small writing, each gated on a real fact
##   NarrativeJournal   the chronicle and the ticker
##
## TIMING. The world is re-read and every event re-tested once every 20 ticks.
## Between samples step() increments a counter and returns. On a full city the
## sample is a walk over ~60 scalar accessors and ~40 events of ~3 clauses each.
##
## DETERMINISM. This system lives outside game/sim/** because the architecture
## puts narrative at game/narrative/, but it runs INSIDE the tick and obeys §3
## exactly: Rng.stream("narrative") only, SimClock for time, sorted iteration
## everywhere, no engine callbacks, no scene tree, no wall clock. It is proved
## by tools/determinism.sh like everything else, because it serializes into the
## same state.json.
##
## WHAT OTHER PARTS READ — through game/narrative/narrative_api.gd, never here.

const TAG: String = NarrativeDefs.TAG

# --- content -----------------------------------------------------------------

var events: Array[NarrativeEventDef] = []
var by_id: Dictionary[StringName, NarrativeEventDef] = {}
var content_problems: int = 0

# --- live state --------------------------------------------------------------

var world: NarrativeWorld = null
var journal: NarrativeJournal = null
var effects: NarrativeEffects = null

## Events waiting on the player, richest-first. Each is a plain Dictionary so a
## HUD can render one without compiling against a single class in this folder.
var pending: Array[Dictionary] = []

var chapter_index: int = 0
var ended: bool = false
var epilogue: Dictionary = {}

var _tick: int = 0
var _hour_ticks: int = NarrativeDefs.DEFAULT_DAY_TICKS / NarrativeDefs.HOURS_PER_DAY

## event id -> tick it last fired. -1 means never.
var _fired_at: Dictionary[StringName, int] = {}
var _fire_count: Dictionary[StringName, int] = {}
## event id -> tick its all_of first held continuously. -1 while it does not.
var _hold_since: Dictionary[StringName, int] = {}

var _events_fired: int = 0
var _dilemmas_resolved: int = 0
var _expired: int = 0
var _last_event_tick: int = 0

# --- flavour -----------------------------------------------------------------

var _flavour_next: int = 0
var _flavour_said: int = 0
## bank -> the shuffled order it is working through, and how far in it is.
var _decks: Dictionary[StringName, PackedInt32Array] = {}
var _deck_pos: Dictionary[StringName, int] = {}

# --- what we have already reacted to ----------------------------------------

var _deaths_seen: int = 0
var _waves_seen: int = 0
var _laws_seen: int = 0
var _obit_tick_seen: int = -1

var _citizens: SimSystem = null
var _society: SimSystem = null
var _threat: SimSystem = null

## Built once. `NarrativeCampaign.chapters()` and `NarrativeFlavour.gates()`
## each allocate their whole structure on every call, and the sample runs
## fifty times a second of in-world time; rebuilding seven chapters and
## fourteen conditions that often was two thirds of this system's tick.
var _chapters: Array[NarrativeCampaign.Chapter] = []
var _gates: Array[Dictionary] = []


func system_name() -> StringName:
	return &"narrative"


func _init() -> void:
	order = NarrativeDefs.SYSTEM_ORDER


# =========================================================================
#  lifecycle
# =========================================================================

func setup() -> void:
	order = NarrativeDefs.SYSTEM_ORDER
	world = NarrativeWorld.new()
	journal = NarrativeJournal.new()
	effects = NarrativeEffects.new()
	pending.clear()
	chapter_index = -1
	ended = false
	epilogue = {}
	_tick = 0
	_fired_at.clear()
	_fire_count.clear()
	_hold_since.clear()
	_events_fired = 0
	_dilemmas_resolved = 0
	_expired = 0
	_last_event_tick = 0
	_flavour_next = 0
	_flavour_said = 0
	_decks.clear()
	_deck_pos.clear()
	_deaths_seen = 0
	_waves_seen = 0
	_laws_seen = 0
	_obit_tick_seen = -1
	_chapters = NarrativeCampaign.chapters()
	_gates = NarrativeFlavour.gates()
	_load_content()


## Every .tres in game/content/events/ that is an event. Anything else in that
## folder (the bootstrap resource, for one) is skipped by TYPE, not by filename.
func _load_content() -> void:
	events.clear()
	by_id.clear()
	content_problems = 0
	for res: Resource in Registry.all("events"):
		var def := res as NarrativeEventDef
		if def == null:
			continue
		var problems: PackedStringArray = def.validate()
		if not problems.is_empty():
			# A malformed event silently removes a decision from the game. It
			# fails the run on purpose, exactly like a malformed law does.
			for p: String in problems:
				Log.error(TAG, "event '%s' %s" % [String(def.id), p])
			content_problems += problems.size()
			continue
		if by_id.has(def.id):
			Log.error(TAG, "duplicate event id '%s'" % String(def.id))
			content_problems += 1
			continue
		by_id[def.id] = def
		events.append(def)
	# Registry.all() is already sorted by id; sorting again by (priority, id)
	# makes the evaluation order the same one the player experiences.
	events.sort_custom(func(a: NarrativeEventDef, b: NarrativeEventDef) -> bool:
		if a.priority != b.priority:
			return a.priority > b.priority
		return String(a.id) < String(b.id))
	if events.is_empty():
		Log.warn(TAG, "no events loaded; nothing in game/content/events is a NarrativeEventDef")


func post_setup() -> void:
	world.bind()
	_hour_ticks = world.hour_ticks
	_citizens = Sim.get_system(&"citizens")
	_society = Sim.get_system(&"society")
	_threat = Sim.get_system(&"threat")
	world.read(0, _own_facts())
	_flavour_next = _flavour_interval()
	Log.info(TAG, "ready: %d events, %d chapters, %d flavour lines, reads %s" % [
		events.size(), NarrativeCampaign.chapter_count(),
		NarrativeFlavour.total_lines(), world.source_list()])


# =========================================================================
#  the tick
# =========================================================================

func step(tick: int) -> void:
	_tick = tick
	if tick % NarrativeDefs.SAMPLE_EVERY != 0:
		return
	world.read(tick, _own_facts())
	_advance_chapter()
	_react_to_the_dead()
	_react_to_the_night()
	_react_to_the_book()
	_expire_deadlines()
	_evaluate_events()
	_maybe_say_something()
	_check_ending()


func _own_facts() -> Dictionary:
	return {
		&"chapter": float(maxi(0, chapter_index)),
		&"events_fired": float(_events_fired),
		&"dilemmas_resolved": float(_dilemmas_resolved),
		&"quiet_hours": float(_tick - _last_event_tick) / float(maxi(1, _hour_ticks)),
	}


# =========================================================================
#  the campaign spine
# =========================================================================

func _advance_chapter() -> void:
	var all: Array[NarrativeCampaign.Chapter] = _chapters
	# Chapters only ever go forward: a run's shape must not oscillate because a
	# storm ended. Walk from the one after the current, and take the furthest
	# whose conditions hold, so a late arrival never skips its own prose.
	var i: int = chapter_index + 1
	while i < all.size():
		if not all[i].opens(world.facts):
			break
		_open_chapter(i, all[i])
		i += 1


func _open_chapter(index: int, ch: NarrativeCampaign.Chapter) -> void:
	chapter_index = index
	var body: String = world.fill(ch.prose)
	var causes: PackedStringArray = PackedStringArray()
	for c: NarrativeCondition in ch.conditions:
		causes.append(c.explain(world.facts))
	var row: Dictionary = journal.record(_tick, _day(), NarrativeDefs.CAT_BEAT, ch.key,
		ch.title, body, causes)
	var card: Dictionary = {
		"seq": int(row["seq"]),
		"id": String(ch.key),
		"category": String(NarrativeDefs.CAT_BEAT),
		"title": ch.title,
		"lede": ch.subtitle,
		"body": body,
		"cause_prose": "",
		"causes": row["causes"],
		"options": [],
		"raised_tick": _tick,
		"day": _day(),
		"era": world.text.get(&"era", ""),
		"deadline_tick": _tick + int(NarrativeDefs.LINGER_BEAT_HOURS * float(_hour_ticks)),
		"priority": 100,
		"focus": [],
	}
	var showing: bool = _push(card)
	Log.info(TAG, "chapter %d: %s" % [index, ch.title])
	Bus.narrative_event.emit(NarrativeDefs.EV_CHAPTER, {
		"chapter": index, "key": String(ch.key), "title": ch.title,
		"subtitle": ch.subtitle, "text": body,
	})
	if not showing:
		Bus.alert_raised.emit(NarrativeDefs.SEV_NOTE, NarrativeDefs.EV_CHAPTER,
			ch.title, Vector2.ZERO)


# =========================================================================
#  reacting to what the city just did
# =========================================================================

## New obituaries become named lines in the ticker. A death this game reports as
## "a citizen died" is a death that did not happen to anybody.
func _react_to_the_dead() -> void:
	if _citizens == null:
		return
	var total: int = int(world.fact(&"deaths"))
	if total <= _deaths_seen:
		return
	var fresh: int = total - _deaths_seen
	_deaths_seen = total
	var records: Array = _citizens.call("recent_deaths", mini(fresh, 4))
	var said: int = 0
	for raw: Variant in records:
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var r: Dictionary = raw
		if int(r.get("tick", -1)) <= _obit_tick_seen:
			continue
		if said >= 2:
			break
		said += 1
		var cause: StringName = StringName(String(r.get("cause", "cold")))
		var line: String = "%s, %d, %s." % [String(r.get("name", "Somebody")),
			int(r.get("age", 0)), String(r.get("trade", "of the Nine"))]
		var after: String = _draw(StringName("grief_" + String(cause)),
			NarrativeFlavour.grief_bank(cause))
		if after != "":
			line += " " + after
		journal.say(_tick, _day(), NarrativeDefs.CAT_OBITUARY, line, String(r.get("name", "")))
		Bus.narrative_event.emit(NarrativeDefs.EV_FLAVOUR, {
			"kind": String(NarrativeDefs.CAT_OBITUARY), "text": line,
			"cause": String(cause), "name": String(r.get("name", "")),
		})
	if not records.is_empty():
		var last: Dictionary = records[records.size() - 1]
		_obit_tick_seen = maxi(_obit_tick_seen, int(last.get("tick", _tick)))


## A night that was fought is worth one line in the morning, and only one.
func _react_to_the_night() -> void:
	if _threat == null:
		return
	var cleared: int = int(world.fact(&"waves_cleared"))
	if cleared <= _waves_seen:
		return
	_waves_seen = cleared
	var line: String = _draw(NarrativeFlavour.BANK_ASSAULT,
		NarrativeFlavour.bank(NarrativeFlavour.BANK_ASSAULT))
	if line == "":
		return
	journal.say(_tick, _day(), NarrativeDefs.CAT_REPORT, line, "wall")
	Bus.narrative_event.emit(NarrativeDefs.EV_FLAVOUR, {
		"kind": "assault", "text": line, "wave": cleared,
	})


## [P06] owns the prose of a law. This part owns the fact that it happened,
## because the chronicle has to be able to say what the city agreed to and on
## which day, months later, when the epilogue reads it back.
func _react_to_the_book() -> void:
	if _society == null:
		return
	var laws: int = int(world.fact(&"laws_signed"))
	if laws <= _laws_seen:
		return
	_laws_seen = laws
	var titles: PackedStringArray = PackedStringArray()
	for row: Variant in _society.call("book_view") as Array:
		var law: Dictionary = row
		if bool(law.get("signed", false)):
			titles.append(String(law.get("title", "")))
	var newest: String = "" if titles.is_empty() else titles[titles.size() - 1]
	journal.record(_tick, _day(), NarrativeDefs.CAT_REPORT, &"law_signed",
		"A page was signed",
		"The book on the map table in the Survey Hall has %d page%s in it now." % [
			laws, "" if laws == 1 else "s"],
		PackedStringArray(["The city signed something on day %d%s." % [
			_day(), "" if newest == "" else ": " + newest]]))


# =========================================================================
#  events
# =========================================================================

func _evaluate_events() -> void:
	if ended:
		return
	for def: NarrativeEventDef in events:
		var eligible: bool = _conditions_hold(def)
		if not eligible:
			_hold_since[def.id] = -1
			continue
		if int(_hold_since.get(def.id, -1)) < 0:
			_hold_since[def.id] = _tick
		if not _gates_open(def):
			continue
		if pending.size() >= NarrativeDefs.PENDING_MAX:
			# The queue is full. The event stays eligible and will arrive when
			# the player has dealt with what is already in front of them: a city
			# that hands you nine decisions has handed you none.
			return
		_raise(def)


## The trigger, ignoring cooldowns and flags. Split out so `_hold_since` tracks
## how long the WORLD has been in this state, not how long the event has been
## allowed to fire.
func _conditions_hold(def: NarrativeEventDef) -> bool:
	for c: NarrativeCondition in def.all_of:
		if not c.holds(world.facts):
			return false
	if not def.any_of.is_empty():
		var any: bool = false
		for c: NarrativeCondition in def.any_of:
			if c.holds(world.facts):
				any = true
				break
		if not any:
			return false
	for c: NarrativeCondition in def.none_of:
		if c.holds(world.facts):
			return false
	return true


## Everything that is not about the state of the city: the day window, flags,
## once-ness, the cooldown, and the sustain.
func _gates_open(def: NarrativeEventDef) -> bool:
	var day: int = _day()
	if day < def.min_day:
		return false
	if def.max_day > 0 and day > def.max_day:
		return false
	for f: StringName in def.requires_flags:
		if not effects.flag(f):
			return false
	for f: StringName in def.forbids_flags:
		if effects.flag(f):
			return false
	var fired: int = int(_fired_at.get(def.id, -1))
	if def.once and fired >= 0:
		return false
	if fired >= 0 and _tick - fired < int(def.cooldown_hours * float(_hour_ticks)):
		return false
	if _is_pending(def.id):
		return false
	var sustain: int = int(def.max_sustained_hours() * float(_hour_ticks))
	if sustain > 0:
		var since: int = int(_hold_since.get(def.id, -1))
		if since < 0 or _tick - since < sustain:
			return false
	return true


func _raise(def: NarrativeEventDef) -> void:
	_fired_at[def.id] = _tick
	_fire_count[def.id] = int(_fire_count.get(def.id, 0)) + 1
	_events_fired += 1
	_last_event_tick = _tick

	var causes: PackedStringArray = def.causes(world.facts)
	var body: String = world.fill(def.body)
	var row: Dictionary = journal.record(_tick, _day(), def.category, def.id,
		def.title, body, causes)
	var card: Dictionary = _build_card(def, causes, int(row["seq"]), _tick,
		_linger_deadline(def))
	var showing2: bool = _push(card)

	Log.info(TAG, "%s: %s" % [String(def.category), def.title])
	Bus.narrative_event.emit(NarrativeDefs.EV_RAISED, card.duplicate(true))
	# A DILEMMA STILL ANNOUNCES ITSELF EVEN WHILE IT IS ON SCREEN. That alert is
	# severity 1: it goes to the attention stack and stays there for as long as
	# the question is unanswered, which is the point of it. Only the severity-0
	# note — the toast — is suppressed for a card the player is already reading.
	if def.is_dilemma():
		Bus.alert_raised.emit(NarrativeDefs.SEV_WARN,
			StringName("narrative_" + String(def.id)), def.title, _focus_of(def))
	elif not showing2:
		Bus.alert_raised.emit(NarrativeDefs.SEV_NOTE,
			StringName("narrative_" + String(def.id)), def.title, _focus_of(def))


## The card, as plain data. Nothing in here is a class from this folder, so a
## HUD can draw it, a save can hold it and a test can read it without compiling
## against [P22] at all.
func _build_card(def: NarrativeEventDef, causes: PackedStringArray, seq: int,
		raised: int, deadline: int) -> Dictionary:
	var opts: Array = []
	for i: int in def.options.size():
		var o: NarrativeOption = def.options[i]
		opts.append({
			"index": i,
			"label": o.label,
			"body": world.fill(o.body),
			"cost": world.fill(o.cost_line),
			"gain": world.fill(o.gain_line),
			"tags": _names(o.tags),
			"is_default": o.is_default,
		})
	return {
		"seq": seq,
		"id": String(def.id),
		"category": String(def.category),
		"title": def.title,
		"lede": world.fill(def.lede),
		"body": world.fill(def.body),
		"cause_prose": world.fill(def.cause_prose),
		"causes": _to_array(causes),
		"options": opts,
		"raised_tick": raised,
		"day": _day(),
		"deadline_tick": deadline,
		"priority": def.priority,
		"focus": [] if def.focus_cell.x < -9000 else [def.focus_cell.x, def.focus_cell.y],
	}


## When this card comes off the pile by itself. A decision has the deadline its
## author gave it; a notice has a linger, because a notice nobody clicked must
## never be the reason the next real event cannot arrive.
func _linger_deadline(def: NarrativeEventDef) -> int:
	if not def.options.is_empty():
		if def.deadline_hours <= 0.0:
			return 0
		return _tick + int(def.deadline_hours * float(_hour_ticks))
	var hours: float = NarrativeDefs.LINGER_BEAT_HOURS if def.category == NarrativeDefs.CAT_BEAT \
		else NarrativeDefs.LINGER_REPORT_HOURS
	return _tick + int(hours * float(_hour_ticks))


func _focus_of(def: NarrativeEventDef) -> Vector2:
	if def.focus_cell.x < -9000:
		return Vector2.ZERO
	return Vector2(def.focus_cell) * 32.0


## Returns TRUE when this card went straight to the front — which is to say, it
## is the one the player is looking at right now.
##
## THE CARD AND THE TOAST WERE THE SAME SENTENCE TWICE. A chapter raises the
## 660 px card that dims the whole city AND a severity-0 alert carrying the same
## title, which [P17] puts in the toast lane: `artifacts/play1/shots/opening.png`
## has "The Column Stopped Here" as a card in the middle of the screen and as a
## chip at the bottom of it, in the first frame of the first minute. The toast is
## worth having for a card that is QUEUED — the player cannot see that one and
## should know it arrived — and it is noise for one they are reading.
func _push(card: Dictionary) -> bool:
	pending.append(card)
	pending.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["priority"]) != int(b["priority"]):
			return int(a["priority"]) > int(b["priority"])
		return int(a["seq"]) < int(b["seq"]))
	return not pending.is_empty() \
		and String(pending[0]["id"]) == String(card["id"])


func _is_pending(id: StringName) -> bool:
	for card: Dictionary in pending:
		if String(card["id"]) == String(id):
			return true
	return false


## A deadline that runs out is itself a decision, and it is never the kind one.
func _expire_deadlines() -> void:
	for i: int in range(pending.size() - 1, -1, -1):
		var card: Dictionary = pending[i]
		var deadline: int = int(card.get("deadline_tick", 0))
		if deadline <= 0 or _tick < deadline:
			continue
		var def: NarrativeEventDef = by_id.get(StringName(String(card["id"])))
		if def == null or def.options.is_empty():
			# A notice, not a decision. It scrolls into the chronicle, where it
			# stays readable, instead of holding a slot the next event needs.
			journal.close(int(card["seq"]), "unread",
				String(card.get("body", "")), PackedStringArray())
			pending.remove_at(i)
			continue
		_expired += 1
		_resolve(i, def.default_option_index(), true)


# =========================================================================
#  the player answers
# =========================================================================

## Applies one option, records what it cost, and takes the card off the pile.
func _resolve(index: int, option_index: int, by_default: bool) -> bool:
	if index < 0 or index >= pending.size():
		return false
	var card: Dictionary = pending[index]
	var id: StringName = StringName(String(card["id"]))
	var def: NarrativeEventDef = by_id.get(id)
	pending.remove_at(index)

	if def == null or def.options.is_empty():
		journal.close(int(card["seq"]), "acknowledged",
			world.fill(String(card.get("body", ""))), PackedStringArray())
		Bus.narrative_event.emit(NarrativeDefs.EV_RESOLVED, {
			"id": String(id), "choice": "", "option": -1, "by_default": by_default,
			"outcome": "", "effects": [],
		})
		return true

	var oi: int = clampi(option_index, 0, def.options.size() - 1)
	var opt: NarrativeOption = def.options[oi]
	var why: String = "%s: %s" % [def.title, opt.label]
	effects.apply(opt, why)
	var outcome: String = world.fill(opt.outcome)
	if not effects.took.is_empty():
		outcome += _name_the_taken()
	journal.close(int(card["seq"]), opt.label, outcome, effects.applied())
	journal.say(_tick, _day(), NarrativeDefs.CAT_REPORT, outcome, def.title)
	if def.is_dilemma():
		_dilemmas_resolved += 1
	for note: String in effects.dropped():
		Log.warn(TAG, "'%s' could not be applied: %s" % [def.title, note])

	Log.info(TAG, "%s -> %s%s" % [def.title, opt.label,
		" (nobody answered)" if by_default else ""])
	Bus.narrative_event.emit(NarrativeDefs.EV_EXPIRED if by_default
		else NarrativeDefs.EV_RESOLVED, {
		"id": String(id), "title": def.title, "choice": opt.label, "option": oi,
		"by_default": by_default, "outcome": outcome,
		"effects": _to_array(effects.applied()),
	})
	return true


## Effects that take people take the lowest living ids, deterministically. Say
## who, because a number is not a person and this part is the one that knows it.
func _name_the_taken() -> String:
	if _citizens == null or effects.took.is_empty():
		return ""
	var names: PackedStringArray = PackedStringArray()
	for id: int in effects.took:
		var info: Dictionary = _citizens.call("citizen_info", id)
		if info.is_empty():
			continue
		names.append("%s, %d, %s" % [String(info.get("name", "")),
			int(info.get("age", 0)), String(info.get("profession", ""))])
	if names.is_empty():
		return ""
	return "\n\nWritten down, because they had names: %s." % ", ".join(names)


# =========================================================================
#  flavour
# =========================================================================

func _flavour_interval() -> int:
	# Every 25 to 40 seconds of in-world time. Frequent enough that the city is
	# never silent, rare enough that it is never wallpaper.
	var r: RandomNumberGenerator = Rng.stream(NarrativeDefs.RNG_STREAM)
	return 500 + r.randi_range(0, 300)


func _maybe_say_something() -> void:
	if _tick < _flavour_next:
		return
	_flavour_next = _tick + _flavour_interval()
	var open: Array[Dictionary] = []
	var weight_total: int = 0
	for gate: Dictionary in _gates:
		var ok: bool = true
		for c: NarrativeCondition in (gate["all_of"] as Array[NarrativeCondition]):
			if not c.holds(world.facts):
				ok = false
				break
		if not ok:
			continue
		open.append(gate)
		weight_total += int(gate["weight"])
	if open.is_empty() or weight_total <= 0:
		return
	var r: RandomNumberGenerator = Rng.stream(NarrativeDefs.RNG_STREAM)
	var roll: int = r.randi_range(0, weight_total - 1)
	var chosen: StringName = StringName(open[0]["bank"])
	for gate: Dictionary in open:
		roll -= int(gate["weight"])
		if roll < 0:
			chosen = StringName(gate["bank"])
			break
	var line: String = _draw(chosen, NarrativeFlavour.bank(chosen))
	if line == "":
		return
	_flavour_said += 1
	journal.say(_tick, _day(), NarrativeDefs.CAT_REPORT, line, String(chosen))
	Bus.narrative_event.emit(NarrativeDefs.EV_FLAVOUR, {
		"kind": String(chosen), "text": line, "day": _day(),
	})


## Draws from a bank without repeating until the bank has been all the way
## round. A city that says the same sentence twice in five minutes stops being
## a place.
func _draw(deck_id: StringName, lines: Array[String]) -> String:
	if lines.is_empty():
		return ""
	var order: PackedInt32Array = _decks.get(deck_id, PackedInt32Array())
	var pos: int = int(_deck_pos.get(deck_id, 0))
	if order.size() != lines.size() or pos >= order.size():
		order = _shuffled(lines.size())
		pos = 0
	var line: String = lines[order[pos]]
	_decks[deck_id] = order
	_deck_pos[deck_id] = pos + 1
	return line


func _shuffled(n: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(n)
	for i: int in n:
		out[i] = i
	var r: RandomNumberGenerator = Rng.stream(NarrativeDefs.RNG_STREAM)
	# Fisher-Yates against a named stream: deterministic, and independent of
	# every other roll in the build.
	for i: int in range(n - 1, 0, -1):
		var j: int = r.randi_range(0, i)
		var tmp: int = out[i]
		out[i] = out[j]
		out[j] = tmp
	return out


# =========================================================================
#  the ending
# =========================================================================

func _check_ending() -> void:
	if ended:
		return
	var outcome: StringName = &""
	var reason: String = ""
	if _society != null and bool(_society.call("is_over")):
		outcome = &"lost"
		reason = String(_society.call("end_reason"))
	elif _citizens != null and int(world.fact(&"population")) <= 0 \
			and int(world.fact(&"deaths")) > 0:
		outcome = &"lost"
		reason = "extinct"
	if outcome == &"":
		return
	ended = true
	epilogue = _build_reckoning(outcome, reason)
	var row: Dictionary = journal.record(_tick, _day(), NarrativeDefs.CAT_BEAT,
		&"epilogue", String(epilogue.get("title", "")),
		String(epilogue.get("text", "")), PackedStringArray([reason]))
	# The account goes ON THE PILE, not only into a log. An ending nobody is
	# shown is a text file, and the whole argument of this part is that the
	# player has to be made to read what it cost.
	pending.clear()
	_push({
		"seq": int(row["seq"]),
		"id": "epilogue",
		"category": String(NarrativeDefs.CAT_BEAT),
		"title": String(epilogue.get("title", "")),
		"lede": "Day %d. The account, from this run and nothing else."
			% int(epilogue.get("day", _day())),
		"body": String(epilogue.get("text", "")),
		"cause_prose": "",
		"causes": row["causes"],
		"options": [],
		"raised_tick": _tick,
		"day": _day(),
		# NOT [P09]'s ERA, FOR THIS ONE CARD. A beat is stamped with the date
		# line the clock is showing so the two do not argue — which is right for
		# every beat except the last one. `escalation_title()` reads "The Lull"
		# through day 3 because the baseline temperature has not sunk yet, and
		# it is correct arithmetic about a curve; stamped across the top of the
		# card that says the city is over it reads as the interface not having
		# noticed. `artifacts/play1/shots/third_day_city.png`: **DAY 3   THE
		# LULL** over "The City Did Not Stand". The ending is its own chapter and
		# this is the one place in the run where nothing else can be true.
		"era": "The Reckoning",
		"deadline_tick": 0,
		"priority": 1000,
		"focus": [],
	})
	Log.info(TAG, "epilogue: %s" % String(epilogue.get("title", "")))
	Bus.narrative_event.emit(NarrativeDefs.EV_EPILOGUE, epilogue.duplicate(true))


func _build_reckoning(outcome: StringName, reason: String) -> Dictionary:
	var laws: Array[Dictionary] = []
	if _society != null:
		for row: Variant in _society.call("book_view") as Array:
			if typeof(row) == TYPE_DICTIONARY:
				laws.append(row as Dictionary)
	return NarrativeCampaign.reckoning(outcome, world.facts, journal, laws, reason)


# =========================================================================
#  the public surface other parts use — always through narrative_api.gd
# =========================================================================

## The events waiting on the player, highest priority first. Plain data.
func pending_cards() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for card: Dictionary in pending:
		var c: Dictionary = card.duplicate(true)
		var deadline: int = int(card.get("deadline_tick", 0))
		c["hours_left"] = 0.0 if deadline <= 0 else snappedf(
			float(deadline - _tick) / float(maxi(1, _hour_ticks)), 0.01)
		out.append(c)
	return out


func top_card() -> Dictionary:
	var cards: Array[Dictionary] = pending_cards()
	return {} if cards.is_empty() else cards[0]


## Answer an event. Returns false when it is not on the pile, or the index is
## not one of its options — an unanswerable card must never silently vanish.
func choose(id: StringName, option_index: int) -> bool:
	for i: int in pending.size():
		if String(pending[i]["id"]) != String(id):
			continue
		var def: NarrativeEventDef = by_id.get(id)
		if def != null and not def.options.is_empty():
			if option_index < 0 or option_index >= def.options.size():
				Log.warn(TAG, "option %d is not one of '%s' %d choices" % [
					option_index, String(id), def.options.size()])
				return false
		return _resolve(i, option_index, false)
	return false


func acknowledge(id: StringName) -> bool:
	for i: int in pending.size():
		if String(pending[i]["id"]) == String(id):
			var def: NarrativeEventDef = by_id.get(id)
			if def != null and def.is_dilemma():
				Log.warn(TAG, "'%s' is a decision, not a notice; it needs an answer"
					% String(id))
				return false
			return _resolve(i, 0, false)
	return false


func chapter() -> Dictionary:
	var all: Array[NarrativeCampaign.Chapter] = _chapters if not _chapters.is_empty() \
		else NarrativeCampaign.chapters()
	var i: int = clampi(chapter_index, 0, all.size() - 1)
	if chapter_index < 0:
		return {"index": -1, "key": "", "title": "", "subtitle": "", "of": all.size()}
	return {
		"index": i, "key": String(all[i].key), "title": all[i].title,
		"subtitle": all[i].subtitle, "of": all.size(),
	}


## The ending, or the account so far. A run that is still going gets the same
## shape with outcome "unfinished", so a stats panel never has to special-case
## a city that has not fallen over yet.
func reckoning() -> Dictionary:
	if ended and not epilogue.is_empty():
		return epilogue.duplicate(true)
	return _build_reckoning(&"unfinished", "")


func fact(key: StringName) -> float:
	return world.fact(key)


func facts() -> Dictionary:
	return world.serialize()


func flag(name: StringName) -> bool:
	return effects.flag(name)


# =========================================================================
#  commands
# =========================================================================

func handle_command(cmd: Dictionary) -> void:
	var op: String = String(cmd.get("op", ""))
	match op:
		"choose":
			var id: StringName = StringName(String(cmd.get("event", cmd.get("id", ""))))
			if not choose(id, int(cmd.get("option", 0))):
				Log.warn(TAG, "cannot answer '%s': it is not waiting" % String(id))
		"acknowledge", "ack":
			var id: StringName = StringName(String(cmd.get("event", cmd.get("id", ""))))
			if not acknowledge(id):
				Log.warn(TAG, "cannot acknowledge '%s'" % String(id))
		"raise":
			# Scenarios and the tutorial force a card up. It still has to be a
			# real event with real conditions; nothing here invents one.
			var id: StringName = StringName(String(cmd.get("event", cmd.get("id", ""))))
			var def: NarrativeEventDef = by_id.get(id)
			if def == null:
				Log.warn(TAG, "no event '%s' to raise" % String(id))
			elif not _is_pending(id):
				_raise(def)
		"dump":
			_dump()
		_:
			Log.warn(TAG, "unknown op '%s'" % op)


func _dump() -> void:
	var ch: Dictionary = chapter()
	Log.info(TAG, "chapter %s '%s', %d fired, %d decided, %d expired, %d lines said, %d waiting" % [
		str(ch.get("index", -1)), String(ch.get("title", "")), _events_fired,
		_dilemmas_resolved, _expired, _flavour_said, pending.size()])
	for card: Dictionary in pending:
		Log.info(TAG, "  waiting: %s (%s)" % [String(card["title"]), String(card["category"])])
		for cause: Variant in card.get("causes", []):
			Log.info(TAG, "    because %s" % String(cause))


# =========================================================================
#  persistence and metrics
# =========================================================================

func serialize() -> Dictionary:
	var fired: Dictionary = {}
	var ids: Array = _fired_at.keys()
	ids.sort()
	for id: StringName in ids:
		fired[String(id)] = _fired_at[id]
	var counts: Dictionary = {}
	var cids: Array = _fire_count.keys()
	cids.sort()
	for id: StringName in cids:
		counts[String(id)] = _fire_count[id]
	var cards: Array = []
	for card: Dictionary in pending:
		cards.append({
			"id": card["id"], "seq": card["seq"], "category": card["category"],
			"raised_tick": card["raised_tick"], "deadline_tick": card["deadline_tick"],
			"causes": card["causes"],
		})
	return {
		"chapter": chapter_index,
		"chapter_key": String(chapter().get("key", "")),
		"events_fired": _events_fired,
		"dilemmas_resolved": _dilemmas_resolved,
		"expired": _expired,
		"flavour_said": _flavour_said,
		"content_problems": content_problems,
		"events_loaded": events.size(),
		"pending": cards,
		"fired_at": fired,
		"fire_count": counts,
		"flags": effects.serialize(),
		"journal": journal.serialize(),
		"ended": ended,
		"epilogue": epilogue.duplicate(true),
		"facts": world.serialize(),
	}


func deserialize(data: Dictionary) -> void:
	chapter_index = int(data.get("chapter", -1))
	_events_fired = int(data.get("events_fired", 0))
	_dilemmas_resolved = int(data.get("dilemmas_resolved", 0))
	_expired = int(data.get("expired", 0))
	_flavour_said = int(data.get("flavour_said", 0))
	ended = bool(data.get("ended", false))
	epilogue = (data.get("epilogue", {}) as Dictionary).duplicate(true)
	effects.deserialize(data.get("flags", {}))
	journal.deserialize(data.get("journal", {}))
	_fired_at.clear()
	var fired: Dictionary = data.get("fired_at", {})
	var keys: Array = fired.keys()
	keys.sort()
	for k: String in keys:
		_fired_at[StringName(k)] = int(fired[k])
	_fire_count.clear()
	var counts: Dictionary = data.get("fire_count", {})
	var ckeys: Array = counts.keys()
	ckeys.sort()
	for k: String in ckeys:
		_fire_count[StringName(k)] = int(counts[k])
	pending.clear()
	for raw: Variant in data.get("pending", []):
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var stub: Dictionary = raw
		var def: NarrativeEventDef = by_id.get(StringName(String(stub.get("id", ""))))
		if def == null:
			continue
		# Rebuilt, not re-raised. Calling _raise() here would count the event a
		# second time, write a second chronicle entry and announce it on the Bus
		# as if it had just happened, which is how loading a save ends up
		# claiming a delegation arrived twice.
		var causes: PackedStringArray = PackedStringArray()
		for line: Variant in stub.get("causes", []):
			causes.append(String(line))
		var card: Dictionary = _build_card(def, causes, int(stub.get("seq", 0)),
			int(stub.get("raised_tick", _tick)), int(stub.get("deadline_tick", 0)))
		_push(card)
	Log.info(TAG, "restored: chapter %d, %d fired, %d waiting" % [
		chapter_index, _events_fired, pending.size()])


func metrics() -> Dictionary:
	return {
		"chapter": maxi(0, chapter_index),
		"events_fired": _events_fired,
		"pending": pending.size(),
		"dilemmas_resolved": _dilemmas_resolved,
		"expired": _expired,
		"flavour_said": _flavour_said,
		"journal": journal.entries.size(),
		"ended": 1 if ended else 0,
	}


# =========================================================================
#  small helpers
# =========================================================================

func _day() -> int:
	return maxi(1, int(world.fact(&"day")))


func _names(ids: Array[StringName]) -> Array:
	var out: Array = []
	for id: StringName in ids:
		out.append(String(id))
	return out


func _to_array(s: PackedStringArray) -> Array:
	var out: Array = []
	for line: String in s:
		out.append(line)
	return out
