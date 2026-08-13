class_name ResearchNode
extends Resource
## One node of the tech tree. **This is the schema the tree is authored in.**
##
## Drop a .tres of this type into `game/content/research/` and Registry finds it;
## there is no list to edit. Look one up with
## `Registry.get_item("research", &"pipe_lagging") as ResearchNode`.
##
## THE RULE FOR AUTHORING A NODE, and it is not decoration:
## `description` states THE BEAT — the moment in the campaign this node is meant
## to arrive at, and the problem the player is feeling when it does. A node whose
## description reads like a shopping-list entry ("+10% turret damage") is a
## failed node. `answers` names the measured signal that beat corresponds to, so
## the pacing engine can actually put it in front of the player at that moment
## instead of hoping they scroll to it.

# ---------------------------------------------------------------- identity ---

## Stable id. Unique across game/content/research/, and it doubles as an UNLOCK
## ID: a BuildingDef with `unlock_id = &"pipe_lagging"` opens when this completes.
@export var id: StringName = &""
## Player-facing name. Two or three words.
@export var title: String = ""
## THE BEAT. When in the campaign this should land and what problem it answers.
## Written for a player, read by a designer, shown in the tree tooltip.
@export_multiline var description: String = ""
## One line of in-world voice. Optional, and never carries mechanical information.
@export_multiline var flavour: String = ""
## Which lane of the tree, see ResearchDefs.BRANCH_*.
@export var branch: StringName = &"heat"
## 1..4. Sets the default cost curve and sorts a lane's nodes.
@export var tier: int = 1

# ------------------------------------------------------------ graph shape ----

## Node ids that must all be finished first. Cross-branch prerequisites are the
## point: the anti-armour round needs the metallurgists, not the gunners.
@export var prereqs: Array[StringName] = []

# ---------------------------------------------------------- cost and time ----

## Materials consumed, item id -> amount. Paid in four instalments as the work
## progresses, out of the same yard construction eats from — so research is a
## real competitor for steel, not a free background timer.
@export var cost: Dictionary[StringName, int] = {}
## Insight points needed. The city produces roughly 1/s bare, more with staffed
## workshops, less when it is freezing. 20 points ~ one second of a bare city.
@export var work: int = 120

# -------------------------------------------------------------- payoff ------

## Extra unlock ids opened alongside this node's own id: recipe_*, law_*, or a
## building id another part gates on. See ResearchDefs.PREFIX_*.
@export var grants: Array[StringName] = []
## Numeric modifiers merged into the effect layer on completion.
## Keys must come from ResearchDefs.EFFECT_KEYS or validate() complains.
@export var effects: Dictionary[StringName, float] = {}

# -------------------------------------------------------------- pacing ------

## The measured problem this node is an answer to, see ResearchDefs.SIG_*.
@export var answers: StringName = &""
## How loudly it answers it. 1.0 is a normal answer, 2.0 is "this is THE fix".
@export var answer_weight: float = 1.0
## Second-order signal, half weight. Optional.
@export var also_answers: StringName = &""
## One sentence the pacing engine puts in front of the player when it recommends
## this node. Present tense, concrete, no numbers — the engine adds those.
@export var urgency_line: String = ""
## Nudges a node up or down the auto-pick order without touching its answer
## weights. Use sparingly; the signals should be doing this work.
@export var priority_bias: float = 0.0
## The city's engineers will NEVER start this on their own, however loudly its
## signal is being asked. Every node in the desperate branch is one of these by
## rule: a law is signed by the player or it is not signed at all. The pacing
## engine may still recommend it, and says so in different words when it does.
@export var player_decision: bool = false

# ---------------------------------------------------------- view hints ------

## Optional row hint inside the branch band. -1 lets the layout choose.
@export var row_hint: int = -1
## Icon for the tree view. Empty falls back to a branch glyph.
@export var icon_path: String = ""


## Total items this node will ever cost, as a plain dictionary.
func total_cost() -> Dictionary[StringName, int]:
	var out: Dictionary[StringName, int] = {}
	var keys: Array = cost.keys()
	keys = ResearchDefs.sorted_names(keys)
	for k: StringName in keys:
		var n: int = int(cost[k])
		if n > 0:
			out[k] = n
	return out


## Items owed by the time `fraction` (0..1) of the work is done, cumulative.
## Instalments are cumulative-rounded so the last one always squares the books:
## the sum of four instalments is exactly `cost`, never one plate over or under.
func cost_by_fraction(fraction: float) -> Dictionary[StringName, int]:
	var f: float = clampf(fraction, 0.0, 1.0)
	var out: Dictionary[StringName, int] = {}
	var keys: Array = cost.keys()
	keys = ResearchDefs.sorted_names(keys)
	for k: StringName in keys:
		var total: int = int(cost[k])
		if total <= 0:
			continue
		out[k] = mini(total, int(ceil(float(total) * f - 0.000001)))
	return out


## Every unlock id this node opens, its own id first. Sorted after that.
func unlock_ids() -> Array[StringName]:
	var out: Array[StringName] = [id]
	var extra: Array[StringName] = []
	for g: StringName in grants:
		if String(g) != "" and g != id and not extra.has(g):
			extra.append(g)
	extra = ResearchDefs.sorted_names(extra)
	out.append_array(extra)
	return out


## Law ids this node opens, for [P06].
func law_ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for g: StringName in grants:
		if ResearchDefs.is_law(g):
			out.append(g)
	out = ResearchDefs.sorted_names(out)
	return out


## Recipe ids this node opens, for [P04].
func recipe_ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for g: StringName in grants:
		if ResearchDefs.is_recipe(g):
			out.append(g)
	out = ResearchDefs.sorted_names(out)
	return out


## Content sanity check. Human-readable problems; empty means clean. The system
## runs it over every node at world creation, so a bad .tres is a line in the
## log rather than a mystery on day nine.
func validate() -> PackedStringArray:
	var problems: PackedStringArray = PackedStringArray()
	if String(id) == "":
		problems.append("missing id")
	if title == "":
		problems.append("missing title")
	if description.strip_edges().length() < 24:
		problems.append("description must state the beat this node arrives at, not a stat line")
	if not ResearchDefs.is_branch(branch):
		problems.append("unknown branch '%s'" % String(branch))
	if tier < 1 or tier > 4:
		problems.append("tier must be 1..4, got %d" % tier)
	if work <= 0:
		problems.append("work must be > 0")
	if prereqs.has(id):
		problems.append("node lists itself as a prerequisite")
	var seen: Dictionary[StringName, bool] = {}
	for p: StringName in prereqs:
		if String(p) == "":
			problems.append("empty prerequisite id")
		elif seen.has(p):
			problems.append("duplicate prerequisite '%s'" % String(p))
		seen[p] = true
	var ckeys: Array = cost.keys()
	for k: Variant in ckeys:
		if int(cost[k]) <= 0:
			problems.append("non-positive cost entry '%s'" % String(k))
	var ekeys: Array = effects.keys()
	ekeys = ResearchDefs.sorted_names(ekeys)
	for k2: Variant in ekeys:
		var key: StringName = StringName(String(k2))
		if not ResearchDefs.is_effect_key(key):
			problems.append("unknown effect key '%s'" % String(key))
	if String(answers) != "" and not ResearchDefs.is_signal(answers):
		problems.append("unknown pacing signal '%s'" % String(answers))
	if String(also_answers) != "" and not ResearchDefs.is_signal(also_answers):
		problems.append("unknown secondary pacing signal '%s'" % String(also_answers))
	if String(answers) != "" and urgency_line.strip_edges() == "":
		problems.append("answers a signal but has no urgency_line to say why now")
	if grants.has(id):
		problems.append("grants its own id, which is implicit")
	return problems
