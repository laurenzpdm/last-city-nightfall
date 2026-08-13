class_name NarrativeCondition
extends Resource
## One clause of an event's trigger, and the sentence that proves it fired.
##
## A condition is a named world fact, a comparator and a threshold. That is the
## whole of it, on purpose: an event whose trigger is a script cannot explain
## itself, and the entire point of this part is that the player can always read
## why a delegation is standing in the doorway.
##
##     fact = &"discontent"   cmp = GE   threshold = 62.0
##
##     holds(world)  -> true
##     explain(world) -> "Discontent (66.4) is at or above 62."
##
## `sustained_hours` is what separates a caused event from a twitchy one: the
## clause has to have been true continuously for that long before the event is
## allowed to fire. Discontent brushing 62 for one tick on its way back down is
## not a reason for anyone to march on the Hearth.

## Key from NarrativeDefs.FACTS. Anything else is refused at load.
@export var fact: StringName = &""
@export_enum("ge", "le", "gt", "lt", "eq", "ne") var cmp: int = NarrativeDefs.Cmp.GE
@export var threshold: float = 0.0

## The clause must hold continuously for this many in-world hours. 0 = instant.
@export var sustained_hours: float = 0.0

## Optional override for the explanation. Use it when the raw fact label is
## clumsy in a sentence; `{value}` is replaced with the live number.
@export var phrasing: String = ""


func holds(facts: Dictionary) -> bool:
	return NarrativeDefs.compare(float(facts.get(fact, 0.0)), cmp, threshold)


func value_of(facts: Dictionary) -> float:
	return float(facts.get(fact, 0.0))


## "Discontent (66.4) is at or above 62." — the live number is always in it,
## because a reason without a number is a mood.
func explain(facts: Dictionary) -> String:
	var v: float = value_of(facts)
	var shown: String = NarrativeDefs.fact_value_text(fact, v)
	if phrasing != "":
		return phrasing.replace("{value}", shown)
	if NarrativeDefs.is_boolean_fact(fact):
		# "Night (yes) is at or above yes" is a sentence this build actually
		# printed at a player. A yes or a no is stated, never compared.
		return "%s: %s." % [NarrativeDefs.fact_label(fact), shown]
	return "%s (%s) %s %s." % [
		NarrativeDefs.fact_label(fact), shown,
		NarrativeDefs.cmp_word(cmp),
		NarrativeDefs.fact_value_text(fact, threshold),
	]


## Stable text used in tests and logs. No live numbers, so it can be compared.
func signature() -> String:
	return "%s %s %s" % [String(fact), String(NarrativeDefs.cmp_name(cmp)),
		String.num(threshold, 3)]


## Everything wrong with this clause, as human sentences. Empty means valid.
func validate() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if fact == &"":
		out.append("has no fact")
	elif not NarrativeDefs.has_fact(fact):
		out.append("names fact '%s', which nothing in the simulation measures" % String(fact))
	if cmp < 0 or cmp >= NarrativeDefs.CMP_NAMES.size():
		out.append("has comparator %d, which is not one of ge/le/gt/lt/eq/ne" % cmp)
	if sustained_hours < 0.0:
		out.append("has a negative sustained_hours")
	return out


## Convenience for code-authored events and for tests.
static func make(fact_key: StringName, comparator: int, value: float,
		sustained: float = 0.0) -> NarrativeCondition:
	var c := NarrativeCondition.new()
	c.fact = fact_key
	c.cmp = comparator
	c.threshold = value
	c.sustained_hours = sustained
	return c
