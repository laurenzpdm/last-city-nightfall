class_name SocietyDemand
extends RefCounted
## A faction has stopped complaining and started asking, with a date on it.
##
## Three shapes, all of them checkable by the simulation without a human in the
## loop, because a demand a player cannot verifiably satisfy is a trap:
##
##   condition  a number in the city has to reach a value. "Get three quarters
##              of us into a room above freezing."
##   law_any    sign one of these laws. The book is the answer.
##   law_none   sign none of these laws before the deadline. This is the shape
##              that makes the book dangerous: a faction can forbid you the one
##              page that would have solved a different problem.
##
## A demand resolves exactly once. `state` never leaves &"met" or &"failed".

const KIND_CONDITION: StringName = &"condition"
const KIND_LAW_ANY: StringName = &"law_any"
const KIND_LAW_NONE: StringName = &"law_none"

const STATE_OPEN: StringName = &"open"
const STATE_MET: StringName = &"met"
const STATE_FAILED: StringName = &"failed"

var id: int = 0
var faction: StringName = &""
var grievance: StringName = &""
var kind: StringName = KIND_CONDITION

## condition
var metric: StringName = &""
var op: StringName = &">="
var value: float = 0.0

## law_any / law_none
var laws: Array[StringName] = []

var issued_tick: int = 0
var deadline_tick: int = 0
var state: StringName = STATE_OPEN
var resolved_tick: int = -1

## What they say, in their voice.
var speech: String = ""
## The clause, in plain English, so a UI never has to render an operator.
var terms: String = ""


func is_open() -> bool:
	return state == STATE_OPEN


func hours_left(tick: int, hour_ticks: int) -> float:
	if hour_ticks <= 0:
		return 0.0
	return maxf(0.0, float(deadline_tick - tick) / float(hour_ticks))


func expired(tick: int) -> bool:
	return tick >= deadline_tick


## Whether the terms are satisfied at this instant. `values` maps metric name to
## the current number; `signed` answers whether a law is in force.
func satisfied(values: Dictionary, signed_check: Callable) -> bool:
	match kind:
		KIND_CONDITION:
			if not values.has(metric):
				return false
			var v: float = float(values[metric])
			return v >= value if op == &">=" else v <= value
		KIND_LAW_ANY:
			for l: StringName in laws:
				if bool(signed_check.call(l)):
					return true
			return false
		KIND_LAW_NONE:
			for l: StringName in laws:
				if bool(signed_check.call(l)):
					return false
			return true
	return false


## True when breaking the terms is immediate and final rather than a miss at the
## deadline. Signing a forbidden law is not something you get to take back.
func breaks_immediately() -> bool:
	return kind == KIND_LAW_NONE


func resolve(new_state: StringName, tick: int) -> void:
	if state != STATE_OPEN:
		return
	state = new_state
	resolved_tick = tick


func view(tick: int, hour_ticks: int) -> Dictionary:
	var law_names: Array = []
	for l: StringName in laws:
		law_names.append(String(l))
	return {
		"id": id,
		"faction": String(faction),
		"faction_name": SocietyDefs.faction_name(faction),
		"grievance": String(grievance),
		"kind": String(kind),
		"metric": String(metric),
		"op": String(op),
		"value": snappedf(value, 0.001),
		"laws": law_names,
		"speech": speech,
		"terms": terms,
		"issued_tick": issued_tick,
		"deadline_tick": deadline_tick,
		"hours_left": snappedf(hours_left(tick, hour_ticks), 0.01),
		"state": String(state),
		"resolved_tick": resolved_tick,
	}


func serialize() -> Dictionary:
	var law_names: Array = []
	for l: StringName in laws:
		law_names.append(String(l))
	return {
		"id": id,
		"faction": String(faction),
		"grievance": String(grievance),
		"kind": String(kind),
		"metric": String(metric),
		"op": String(op),
		"value": snappedf(value, 0.001),
		"laws": law_names,
		"speech": speech,
		"terms": terms,
		"issued_tick": issued_tick,
		"deadline_tick": deadline_tick,
		"state": String(state),
		"resolved_tick": resolved_tick,
	}


static func from_dict(d: Dictionary) -> SocietyDemand:
	var dem := SocietyDemand.new()
	dem.id = int(d.get("id", 0))
	dem.faction = StringName(String(d.get("faction", "")))
	dem.grievance = StringName(String(d.get("grievance", "")))
	dem.kind = StringName(String(d.get("kind", "condition")))
	dem.metric = StringName(String(d.get("metric", "")))
	dem.op = StringName(String(d.get("op", ">=")))
	dem.value = float(d.get("value", 0.0))
	dem.laws = []
	for l: Variant in d.get("laws", []):
		dem.laws.append(StringName(String(l)))
	dem.issued_tick = int(d.get("issued_tick", 0))
	dem.deadline_tick = int(d.get("deadline_tick", 0))
	dem.state = StringName(String(d.get("state", "open")))
	dem.resolved_tick = int(d.get("resolved_tick", -1))
	dem.speech = String(d.get("speech", ""))
	dem.terms = String(d.get("terms", ""))
	return dem
