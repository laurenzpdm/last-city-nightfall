class_name LawDef
extends Resource
## One page of the Book of Laws. Data only; LawBook owns the graph and
## SocietySystem owns the consequences.
##
## Drop a .tres in game/content/laws/ and Registry finds it. There is no list to
## edit and no code in this folder that knows the name of a single law.
##
## A law is a real choice or it is decoration. The rule content follows:
## every law solves a problem the player actually has, charges for it in a
## currency the player also cares about, and closes a door. If a law is strictly
## better than not signing it, it is a reward, not a law, and it does not belong
## in this book.

# --- identity ---------------------------------------------------------------

@export var id: StringName = &""
@export var title: String = ""
## Which half of the book this page is in: trunk, order or faith.
@export var branch: StringName = &"trunk"
## Depth for layout. The graph is what actually gates; this is for the UI.
@export var tier: int = 1
## Section heading, e.g. "Shelter", "The Dead", "Discipline".
@export var section: String = ""
@export var sort_order: int = 0

# --- the writing ------------------------------------------------------------

## The text of the law itself, as it stands in the book.
@export_multiline var prose: String = ""
## What the people who want it say.
@export_multiline var argument_for: String = ""
## What the people who do not want it say.
@export_multiline var argument_against: String = ""
## The line the city speaks the morning after it comes into force.
@export_multiline var signed_line: String = ""

# --- the graph --------------------------------------------------------------

## Every one of these must be in force before this law can be proposed.
@export var requires: Array[StringName] = []
## At least one of these must be in force. Empty means no such condition.
@export var requires_any: Array[StringName] = []
## Signing this forecloses all of these forever, and any of them being in force
## forecloses this one. LawBook makes the relation symmetric, so declaring it on
## one side is enough.
@export var excludes: Array[StringName] = []
## Earliest day this can be proposed. Day 1 is the first day.
@export var min_day: int = 1
## Hours of argument between proposing and coming into force.
@export var debate_hours: float = 4.0

# --- what it does to the meters ---------------------------------------------

## One-off, applied the moment the law comes into force.
@export var hope_on_sign: float = 0.0
@export var discontent_on_sign: float = 0.0
## Continuous, in meter points per in-world hour, for as long as it is in force.
@export var hope_rate: float = 0.0
@export var discontent_rate: float = 0.0

# --- what it does to the world ----------------------------------------------

## Offsets added to SocietyDefs.POLICY_DEFAULTS. Several laws can push the same
## key and the offsets sum, which is why laws that would stack absurdly exclude
## each other instead of being clamped.
@export var policy: Dictionary[StringName, float] = {}
## Flags this law raises. Set membership, checked with law_flag().
@export var flags: Array[StringName] = []

# --- what it does to the people ---------------------------------------------

## faction id -> approval delta applied once on signing.
@export var approval: Dictionary[StringName, float] = {}
## Grievance kinds this law answers. An open grievance of this kind is closed
## and counts as resolved, which is how a law can defuse a standing demand.
@export var relieves: Array[StringName] = []
## Grievance kinds this law creates pressure for, whatever the world looks like.
@export var provokes: Array[StringName] = []
## Free-form, for UI filtering and for tests. e.g. &"cruel", &"costly".
@export var tags: Array[StringName] = []


func has_flag(f: StringName) -> bool:
	return flags.has(f)


func has_tag(t: StringName) -> bool:
	return tags.has(t)


func policy_offset(key: StringName) -> float:
	return float(policy.get(key, 0.0))


func effective_debate_hours() -> float:
	return maxf(0.0, debate_hours)


## One line for a log or a compact list.
func summary() -> String:
	return "%s (%s, tier %d)" % [title, String(branch), tier]


## Everything wrong with this page, as human sentences. Empty means valid.
## Called once at load so a malformed law is a loud error at boot instead of a
## silent hole in the tree at hour three.
func validate() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if id == &"":
		out.append("has no id")
	if title.strip_edges() == "":
		out.append("has no title")
	if prose.strip_edges() == "":
		out.append("has no prose; a law nobody wrote is not a choice")
	if signed_line.strip_edges() == "":
		out.append("has no signed_line")
	if branch != SocietyDefs.BRANCH_TRUNK and branch != SocietyDefs.BRANCH_ORDER \
			and branch != SocietyDefs.BRANCH_FAITH:
		out.append("branch '%s' is not trunk, order or faith" % String(branch))
	if requires.has(id) or requires_any.has(id) or excludes.has(id):
		out.append("refers to itself")
	if tier < 1:
		out.append("tier must be at least 1")
	if debate_hours < 0.0:
		out.append("debate_hours is negative")
	for key: StringName in policy.keys():
		if not SocietyDefs.POLICY_DEFAULTS.has(key):
			out.append("policy key '%s' is not in SocietyDefs.POLICY_DEFAULTS" % String(key))
	for f: StringName in approval.keys():
		if not SocietyDefs.FACTIONS.has(f):
			out.append("approval names unknown faction '%s'" % String(f))
	for g: StringName in relieves:
		if not SocietyDefs.GRIEVANCES.has(g):
			out.append("relieves unknown grievance '%s'" % String(g))
	for g: StringName in provokes:
		if not SocietyDefs.GRIEVANCES.has(g):
			out.append("provokes unknown grievance '%s'" % String(g))
	var free: bool = hope_on_sign >= 0.0 and discontent_on_sign <= 0.0 \
		and hope_rate >= 0.0 and discontent_rate <= 0.0 \
		and provokes.is_empty() and _worst_approval() >= 0.0
	if free:
		out.append("costs nothing: no hope lost, nobody angered, nothing foreclosed. "
			+ "That is a reward, not a law")
	return out


func _worst_approval() -> float:
	var worst: float = 0.0
	for f: StringName in approval.keys():
		worst = minf(worst, float(approval[f]))
	return worst
