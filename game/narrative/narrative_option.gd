class_name NarrativeOption
extends Resource
## One of the things you may do about it, and what it costs you.
##
## THE RULE THIS CLASS ENFORCES: an option that only gives is not an option.
## `validate()` refuses any choice with no price, exactly the way LawDef refuses
## a law that costs nothing, and `NarrativeEventDef.validate()` refuses a dilemma
## in which one option is cheaper than another on every axis at once. A dilemma
## where the right answer is obvious is a button, and this game does not ship
## buttons dressed as decisions.
##
## The price has to be READABLE before it is paid. `cost_line` is not flavour;
## it is the contract the player is agreeing to, and a test asserts that every
## option that moves a meter downward says so in words.

# --- the writing -------------------------------------------------------------

## The button. Short, in the voice of the person who wants it. "Open the Drop."
@export var label: String = ""
## What you are actually ordering, one or two sentences.
@export_multiline var body: String = ""
## What it costs, in plain words. Shown next to the button, before the click.
@export_multiline var cost_line: String = ""
## What you get for it. Shown next to the cost, same size, no emphasis.
@export_multiline var gain_line: String = ""
## The line the city speaks afterwards. This is the one that has to sting.
@export_multiline var outcome: String = ""

# --- what it does ------------------------------------------------------------

## effect key -> amount. Keys are NarrativeDefs.EFFECT_PREFIXES, optionally
## suffixed: "approval:workers", "stock:timber", "flag:the_drop_is_open".
@export var effects: Dictionary[StringName, float] = {}

## Free-form, for filtering and for tests. &"cruel", &"costly", &"faithless".
@export var tags: Array[StringName] = []

## Set when this is what happens if the player never answers. Exactly one option
## of a deadline dilemma carries it, and it is never the comfortable one.
@export var is_default: bool = false


func effect(key: StringName) -> float:
	return float(effects.get(key, 0.0))


## Sorted. Applying effects in Dictionary order would make a replay depend on
## insertion order, which is the exact class of bug §3 exists to forbid.
func effect_keys() -> Array[StringName]:
	var keys: Array = effects.keys()
	keys.sort()
	var out: Array[StringName] = []
	for k: StringName in keys:
		out.append(k)
	return out


func has_tag(t: StringName) -> bool:
	return tags.has(t)


## True when this option takes something real away. Used by validate() and by
## the presenter, which draws a priced option differently from a free one.
func has_price() -> bool:
	if effect(NarrativeDefs.FX_HOPE) < 0.0:
		return true
	if effect(NarrativeDefs.FX_DISCONTENT) > 0.0:
		return true
	if effect(NarrativeDefs.FX_DEATHS) > 0.0:
		return true
	if effect(NarrativeDefs.FX_FOOD) < 0.0:
		return true
	for k: StringName in effect_keys():
		var parts: Array[StringName] = NarrativeDefs.split_effect(k)
		if parts[0] == NarrativeDefs.FX_APPROVAL and effects[k] < 0.0:
			return true
		if parts[0] == NarrativeDefs.FX_STOCK and effects[k] < 0.0:
			return true
	return false


## The signed total of everything this option moves, in meter-ish points, used
## only to catch an option that is better than its sibling on every single axis.
## Deliberately crude: it is a smell test at load time, not a balance model.
func crude_worth() -> float:
	var w: float = 0.0
	w += effect(NarrativeDefs.FX_HOPE)
	w -= effect(NarrativeDefs.FX_DISCONTENT)
	w += effect(NarrativeDefs.FX_FOOD) * 0.05
	w -= effect(NarrativeDefs.FX_DEATHS) * 4.0
	w += effect(NarrativeDefs.FX_ARRIVALS) * 0.5
	for k: StringName in effect_keys():
		var parts: Array[StringName] = NarrativeDefs.split_effect(k)
		if parts[0] == NarrativeDefs.FX_APPROVAL:
			w += effects[k] * 0.12
		elif parts[0] == NarrativeDefs.FX_STOCK:
			w += effects[k] * 0.01
	return w


## One line for a log.
func summary() -> String:
	return "%s — %s" % [label, cost_line]


## Everything wrong with this option. Empty means valid.
func validate(dilemma: bool) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if label.strip_edges() == "":
		out.append("has no label")
	if outcome.strip_edges() == "":
		out.append("'%s' has no outcome line; a choice nobody wrote the consequence of "
			% label + "is a button")
	for k: StringName in effect_keys():
		var parts: Array[StringName] = NarrativeDefs.split_effect(k)
		if not NarrativeDefs.EFFECT_PREFIXES.has(parts[0]):
			out.append("'%s' has effect '%s', which nothing can apply" % [label, String(k)])
			continue
		if parts[0] == NarrativeDefs.FX_APPROVAL and not NarrativeDefs.FACTION_IDS.has(parts[1]):
			out.append("'%s' names unknown faction '%s'" % [label, String(parts[1])])
		if parts[0] == NarrativeDefs.FX_STOCK and not NarrativeDefs.STOCK_ITEMS.has(parts[1]):
			out.append("'%s' names unknown stock item '%s'" % [label, String(parts[1])])
		if parts[0] == NarrativeDefs.FX_FLAG and parts[1] == &"":
			out.append("'%s' raises a flag with no name" % label)
	if not dilemma:
		return out
	# From here on: rules that only bind a real decision.
	if not has_price():
		out.append("'%s' costs nothing: no hope lost, nobody angered, nothing spent. "
			% label + "That is a reward, not a choice")
	if cost_line.strip_edges() == "":
		out.append("'%s' has no cost_line; the player must be able to read the price "
			% label + "before paying it")
	if body.strip_edges() == "":
		out.append("'%s' has no body" % label)
	return out
