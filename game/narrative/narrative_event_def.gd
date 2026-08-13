class_name NarrativeEventDef
extends Resource
## One thing that happens to Caldera Nine, and the state of the world that made
## it happen.
##
## Drop a .tres in game/content/events/ and Registry finds it. There is no list
## to edit and nothing in this folder knows the name of a single event.
##
## WHAT MAKES AN EVENT LEGAL HERE
##
## 1. It is CAUSED. `all_of` is never empty. Every clause names a fact the
##    simulation actually measures, and the event carries every one of those
##    clauses, with their live numbers, into the card the player reads. "A
##    delegation is at the door" is worthless; "A delegation is at the door.
##    Discontent (66.4) is at or above 62, and has been for six hours" is the
##    game telling the truth about itself.
## 2. If it has options, it has at least two, and every one of them takes
##    something away. See NarrativeOption.validate().
## 3. It is about THIS city. The prose names the Hearth, the Drop, Kettle Row,
##    the shaft, a person, a number. A line that would fit any frozen city in
##    any game is a line that has failed and validate() cannot catch it, so the
##    suite in tests/narrative/ does.

# --- identity ----------------------------------------------------------------

@export var id: StringName = &""
@export var title: String = ""
## NarrativeDefs.CATEGORIES.
@export var category: StringName = &"report"
## Higher wins when two events want the player at the same moment.
@export var priority: int = 50
## Where the card should point the camera, if anywhere. Cell coordinates.
@export var focus_cell: Vector2i = Vector2i(-9999, -9999)

# --- the writing -------------------------------------------------------------

## The line that arrives. One sentence, present tense.
@export_multiline var lede: String = ""
## The body of the card. Tokens in {braces} are filled from the live world;
## see NarrativeWorld.tokens() for what is available.
@export_multiline var body: String = ""
## Optional authored sentence about the cause, spliced in ABOVE the machine's
## own list of clauses. Use it to say what a number means, never to restate it.
@export_multiline var cause_prose: String = ""
## Shown when the event resolves with no choice made. Reports use it as the
## acknowledgement line.
@export_multiline var closing: String = ""

# --- the trigger -------------------------------------------------------------

## Every clause must hold. Never empty — an event with no cause is a timer.
@export var all_of: Array[NarrativeCondition] = []
## At least one must hold. Empty means the clause is not used.
@export var any_of: Array[NarrativeCondition] = []
## None may hold.
@export var none_of: Array[NarrativeCondition] = []

## Flags this part has raised that must be set / must not be set. Flags are how
## one event's outcome becomes another event's cause.
@export var requires_flags: Array[StringName] = []
@export var forbids_flags: Array[StringName] = []

@export var min_day: int = 1
@export var max_day: int = 0                  ## 0 = no ceiling
## Fires at most once per run.
@export var once: bool = true
## In-world hours before it may fire again. Ignored when `once`.
@export var cooldown_hours: float = 24.0

# --- the decision ------------------------------------------------------------

@export var options: Array[NarrativeOption] = []
## In-world hours the player has. 0 = it waits forever (reports, beats).
@export var deadline_hours: float = 0.0

@export var tags: Array[StringName] = []


func is_dilemma() -> bool:
	return options.size() >= 2


func option(i: int) -> NarrativeOption:
	if i < 0 or i >= options.size():
		return null
	return options[i]


## The option taken when the clock runs out. The authored default if one is
## marked, otherwise the last one — which by convention is the one nobody wants.
func default_option_index() -> int:
	for i: int in options.size():
		if options[i].is_default:
			return i
	return options.size() - 1


func has_tag(t: StringName) -> bool:
	return tags.has(t)


## Longest sustain any clause asks for, in hours. The system uses it to know how
## far back it has to remember that a clause was true.
func max_sustained_hours() -> float:
	var m: float = 0.0
	for c: NarrativeCondition in all_of:
		m = maxf(m, c.sustained_hours)
	for c: NarrativeCondition in any_of:
		m = maxf(m, c.sustained_hours)
	return m


## Every clause that is currently true, worded with its live number. This is the
## "why did this happen" list the card shows, and it is generated, never typed,
## so it can never drift away from the trigger it claims to describe.
func causes(facts: Dictionary) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for c: NarrativeCondition in all_of:
		out.append(c.explain(facts))
	for c: NarrativeCondition in any_of:
		if c.holds(facts):
			out.append(c.explain(facts))
	return out


func summary() -> String:
	return "%s (%s, %d option(s))" % [title, String(category), options.size()]


## Everything wrong with this page, as human sentences. Empty means valid.
## Called once at load, so a malformed event is a loud error at boot instead of
## a hole in the winter at hour three.
func validate() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if id == &"":
		out.append("has no id")
	if title.strip_edges() == "":
		out.append("has no title")
	if lede.strip_edges() == "":
		out.append("has no lede; an event nobody wrote is not an event")
	if body.strip_edges() == "":
		out.append("has no body")
	if not NarrativeDefs.CATEGORIES.has(category):
		out.append("category '%s' is not one of %s" % [String(category),
			", ".join(_category_names())])
	if all_of.is_empty():
		out.append("has no all_of conditions: an event with no cause is a timer, "
			+ "and this part does not ship timers")
	for c: NarrativeCondition in all_of + any_of + none_of:
		if c == null:
			out.append("has a null condition")
			continue
		for problem: String in c.validate():
			out.append("condition %s" % problem)
	if min_day < 1:
		out.append("min_day must be at least 1")
	if max_day != 0 and max_day < min_day:
		out.append("max_day %d is before min_day %d" % [max_day, min_day])
	if not once and cooldown_hours <= 0.0:
		out.append("repeats with no cooldown; it would fire every second")
	if options.size() == 1:
		out.append("has exactly one option, which is a button with a story on it. "
			+ "Give it two, or give it none and let the player acknowledge it")
	if deadline_hours < 0.0:
		out.append("has a negative deadline")
	if deadline_hours > 0.0 and options.is_empty():
		out.append("has a deadline but nothing to decide")

	var dilemma: bool = is_dilemma()
	for o: NarrativeOption in options:
		if o == null:
			out.append("has a null option")
			continue
		for problem: String in o.validate(dilemma):
			out.append(problem)
	if dilemma:
		out.append_array(_check_no_obvious_answer())
	return out


## An option that is better than another on EVERY axis at once is the obvious
## answer, and an obvious answer is not a dilemma. This is deliberately a
## dominance test rather than a balance test: two options may be wildly unequal
## in weight as long as each takes something the other does not.
func _check_no_obvious_answer() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for i: int in options.size():
		for j: int in options.size():
			if i == j:
				continue
			if _dominates(options[i], options[j]):
				out.append(("'%s' is better than '%s' on every axis: there is nothing "
					+ "to weigh, so this is not a dilemma") % [options[i].label, options[j].label])
	return out


func _dominates(a: NarrativeOption, b: NarrativeOption) -> bool:
	var keys: Dictionary = {}
	for k: StringName in a.effect_keys():
		keys[k] = true
	for k: StringName in b.effect_keys():
		keys[k] = true
	var sorted: Array = keys.keys()
	sorted.sort()
	var strictly_better: bool = false
	for k: StringName in sorted:
		var av: float = a.effect(k)
		var bv: float = b.effect(k)
		# Discontent and deaths are bad when they go up; everything else is good.
		var sign: float = -1.0 if (k == NarrativeDefs.FX_DISCONTENT
			or k == NarrativeDefs.FX_DEATHS) else 1.0
		var da: float = av * sign
		var db: float = bv * sign
		if da < db - 0.0001:
			return false
		if da > db + 0.0001:
			strictly_better = true
	return strictly_better


func _category_names() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for c: StringName in NarrativeDefs.CATEGORIES:
		out.append(String(c))
	return out
