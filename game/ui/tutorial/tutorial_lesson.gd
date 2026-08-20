class_name LcnTutorialLesson
extends Resource
## [P21] One lesson: a pressure the player can feel, and the smallest action
## that relieves it.
##
## A lesson is data, and it registers by being a .tres in
## `game/content/tutorial/` — there is no list to edit and nothing to merge.
##
## THE SHAPE OF A LESSON, and why each field is here:
##
##   headline   the pressure, stated flat. "Three heat networks. One fire."
##   body       what is true right now, with LIVE NUMBERS in {braces}.
##   action     the one thing to do about it. One thing, never three.
##   watch      the meters that move while the player fixes it.
##   done_when  the SIMULATION's answer. All clauses must hold.
##
## `done_when` is the whole contract. It is a list of clauses over
## `LcnTutorialFacts.KEYS`, every one of which is pulled from a live SimSystem,
## so a lesson retires when the generator is lit and not when four seconds have
## gone by. There is deliberately no way to express "after N seconds" — the one
## thing this file must never be able to say.
##
## `urgent_when` is the other half of being driven by the world. The night does
## not wait for the player to finish the food chain, so a lesson whose pressure
## has ARRIVED jumps the queue, and the queue resumes underneath it when it is
## done.

## Registry indexes on this. Must match the filename.
@export var id: StringName = &""
## Teaching order. The course sorts on it, then on id, so it is stable.
@export var order: int = 0

## Small caps over the headline. "THE COLD", "THE DARK".
@export var kicker: String = ""
## The pressure, in one line. No live numbers: it must not reflow while read.
@export var headline: String = ""
## What is true right now. {tokens} from LcnTutorialFacts.
@export_multiline var body: String = ""
## The smallest action that relieves it. Names the key and the building.
@export_multiline var action: String = ""

## Fact keys shown as a live strip under the action. Three or four, no more.
@export var watch: Array[StringName] = []

## ALL of these must hold for the lesson to retire. Clauses are
## "<fact> <op> <number>", ops <= >= == != < >.
@export var done_when: Array[String] = []

## ANY of these promotes the lesson to the front of the queue, because the thing
## it teaches is happening NOW. Empty means it waits its turn.
@export var urgent_when: Array[String] = []

## Which cell the on-screen marker points at: orphan / turret / burner, or empty
## for none. Resolved against LcnTutorialFacts.focus_cells — never authored as a
## coordinate, because the player's city is not the one the author had.
@export var focus: StringName = &""

## The closing card. Nothing in the simulation can retire it; the player closes
## it. Exactly one lesson may set this and it must sort last.
@export var final_card: bool = false


## True when the world says this lesson is over.
func is_done(facts: LcnTutorialFacts) -> bool:
	if final_card:
		return false
	return facts.all_hold(done_when)


## True when this lesson's subject is happening right now and should jump ahead.
func is_urgent(facts: LcnTutorialFacts) -> bool:
	if final_card or urgent_when.is_empty():
		return false
	return facts.any_holds(urgent_when)


## Everything wrong with this lesson, as human sentences. Empty means valid.
## Read by tests/tutorial so a mistyped fact key is a red suite and not a lesson
## that can never be completed by any player who ever plays this game.
func validate() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if String(id) == "":
		out.append("has no id")
	if headline.strip_edges() == "":
		out.append("has no headline")
	if body.strip_edges() == "":
		out.append("has no body")
	if not final_card:
		if action.strip_edges() == "":
			out.append("has no action — a lesson with nothing to do is a modal")
		if done_when.is_empty():
			out.append("has no done_when — nothing in the simulation can ever retire it")
	for clause: String in done_when + urgent_when:
		out.append_array(_clause_problems(clause))
	for key: StringName in watch:
		if not LcnTutorialFacts.has_key(key):
			out.append("watches '%s', which nothing in the simulation measures" % String(key))
	if headline.find("!") >= 0 or body.find("!") >= 0 or action.find("!") >= 0:
		out.append("uses an exclamation mark; this city does not")
	return out


func _clause_problems(clause: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var parsed: Dictionary = LcnTutorialFacts.parse(clause)
	if parsed.is_empty():
		out.append("clause '%s' is not <fact> <op> <number>" % clause)
		return out
	var key: StringName = parsed["key"]
	if not LcnTutorialFacts.has_key(key):
		out.append("clause '%s' names fact '%s', which nothing in the simulation measures" % [
			clause, String(key)])
	return out
