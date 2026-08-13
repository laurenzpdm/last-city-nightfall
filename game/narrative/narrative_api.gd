class_name Narrative
extends RefCounted
## [P22] The only thing other parts touch.
##
## Everything here returns plain Dictionaries and Arrays, and every mutation
## goes through `Sim.submit_command`, so [P17]'s HUD, [P18]'s panels, [P20]'s
## stats and [P23]'s mixer can present the winter without compiling against a
## single class in `game/narrative/` and without ever writing simulation state
## from a UI handler.
##
##     for card in Narrative.pending():
##         draw_card(card["title"], card["body"], card["causes"], card["options"])
##
##     Narrative.choose(&"the_delegation", 1)     # queued, applied next tick
##     Narrative.acknowledge(&"the_first_night")
##
##     Narrative.feed(6)          # the ticker: overheard lines, obituaries
##     Narrative.chronicle(20)    # the chronicle: what happened, and why
##     Narrative.reckoning()      # the ending, or the account so far
##
## THE CARD, key by key. Everything is already localised into sentences; a
## renderer never formats a number and therefore can never produce the
## "String formatting error" that made 68 lines of a visual run unreadable.
##
##   id            StringName as String
##   category      "beat" | "dilemma" | "report" | "obituary" | "scout"
##   title         one line, the headline
##   lede          one sentence, present tense
##   body          the prose, tokens already filled
##   cause_prose   authored sentence about the cause, may be ""
##   causes        Array[String]: the machine's own list, each with a live number
##   options       Array of {index, label, body, cost, gain, tags, is_default}
##   hours_left    in-world hours before it decides itself. 0 = it waits
##   day, raised_tick, priority, focus
##
## Live events also arrive on `Bus.narrative_event(id, payload)` with the ids in
## `NarrativeDefs.EV_*`, for anything that wants to react rather than poll.

## The system, installing it into the current world if that has not happened
## yet. Null when there is no world.
static func system() -> NarrativeSystem:
	var s: SimSystem = Sim.get_system(&"narrative")
	if s != null:
		return s as NarrativeSystem
	return LcnNarrativeBootstrap.ensure()


static func available() -> bool:
	return system() != null


# =========================================================================
#  what is waiting on the player
# =========================================================================

## Every event awaiting an answer, highest priority first.
static func pending() -> Array[Dictionary]:
	var s: NarrativeSystem = system()
	return [] if s == null else s.pending_cards()


## The one that should be on screen, or {}.
static func current() -> Dictionary:
	var s: NarrativeSystem = system()
	return {} if s == null else s.top_card()


static func pending_count() -> int:
	var s: NarrativeSystem = system()
	return 0 if s == null else s.pending.size()


## True when something is waiting that the player cannot simply dismiss.
static func needs_a_decision() -> bool:
	for card: Dictionary in pending():
		if not (card.get("options", []) as Array).is_empty():
			return true
	return false


# =========================================================================
#  answering
# =========================================================================

## Take one of the options. Queued through the command path, exactly like a
## building placement, so a click can never desync a replay.
static func choose(event_id: StringName, option_index: int) -> void:
	Sim.submit_command({
		"system": &"narrative", "op": "choose",
		"event": event_id, "option": option_index,
	})


## Dismiss a notice. Refused for a dilemma, which needs an answer.
static func acknowledge(event_id: StringName) -> void:
	Sim.submit_command({"system": &"narrative", "op": "acknowledge", "event": event_id})


# =========================================================================
#  reading the winter
# =========================================================================

## The ticker. Newest first: overheard lines, obituaries, scout reports.
static func feed(n: int = 8) -> Array[Dictionary]:
	var s: NarrativeSystem = system()
	return [] if s == null else s.journal.recent_feed(n)


## The chronicle. Oldest first, with the causes that produced each entry and,
## where a decision was taken, what was chosen and what it cost.
static func chronicle(n: int = 20) -> Array[Dictionary]:
	var s: NarrativeSystem = system()
	return [] if s == null else s.journal.last(n)


## {index, key, title, subtitle, of} — where the campaign has got to.
static func chapter() -> Dictionary:
	var s: NarrativeSystem = system()
	return {} if s == null else s.chapter()


## The ending, or the account so far with outcome "unfinished".
static func reckoning() -> Dictionary:
	var s: NarrativeSystem = system()
	return {} if s == null else s.reckoning()


static func has_ended() -> bool:
	var s: NarrativeSystem = system()
	return false if s == null else s.ended


## A flag this part raised as the outcome of a decision. Other parts may read
## these to know what kind of city this became.
static func flag(name: StringName) -> bool:
	var s: NarrativeSystem = system()
	return false if s == null else s.flag(name)


## The fact table the events are triggered on, as {String: float}. For [P20]'s
## stats panel and for anybody debugging why a card did or did not arrive.
static func facts() -> Dictionary:
	var s: NarrativeSystem = system()
	return {} if s == null else s.facts()
