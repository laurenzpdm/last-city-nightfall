class_name SocietyFaction
extends RefCounted
## A constituency, not a party. Memberships overlap on purpose: the woman on the
## night shift is in The Shift and in the Hearthside, so the law that buys you
## the workers costs you the parents, and she is both people at once.

var id: StringName = &""
var approval: float = 0.0            ## -100 .. 100
## Every failed demand hardens them. Radicals shout louder and give you less time.
var radical: int = 0
var demands_made: int = 0
var demands_met: int = 0
var demands_failed: int = 0
var last_demand_tick: int = -100000


func _init(fid: StringName = &"") -> void:
	id = fid


func name_of() -> String:
	return SocietyDefs.faction_name(id)


func share() -> float:
	return SocietyDefs.faction_share(id)


func adjust(delta: float) -> void:
	approval = clampf(approval + delta, SocietyDefs.APPROVAL_MIN, SocietyDefs.APPROVAL_MAX)


## Left alone, a faction forgets. Slowly, and never past neutral.
func drift(hours: float) -> void:
	var step: float = SocietyDefs.APPROVAL_DRIFT_PER_HOUR * hours
	if approval > 0.0:
		approval = maxf(0.0, approval - step)
	elif approval < 0.0:
		approval = minf(0.0, approval + step)


## Discontent per hour this faction contributes purely from resentment, before
## any specific grievance. Approval above zero costs nothing; approval below
## zero is people who have decided about you.
func resentment_rate() -> float:
	if approval >= 0.0:
		return 0.0
	return (-approval / 100.0) * share() * 2.4 * (1.0 + 0.35 * float(radical))


## Hope per hour from a faction that likes you. Goodwill is worth less than
## resentment costs, which is the correct exchange rate for a frozen city.
func goodwill_rate() -> float:
	if approval <= 0.0:
		return 0.0
	return (approval / 100.0) * share() * 0.9


func mood() -> String:
	if approval >= 60.0:
		return "devoted"
	if approval >= 20.0:
		return "with you"
	if approval > -20.0:
		return "watchful"
	if approval > -60.0:
		return "angry"
	return "done with you"


func view() -> Dictionary:
	return {
		"id": String(id),
		"name": name_of(),
		"of_whom": SocietyDefs.faction_of_whom(id),
		"share": snappedf(share(), 0.001),
		"approval": snappedf(approval, 0.01),
		"mood": mood(),
		"radical": radical,
		"demands_made": demands_made,
		"demands_met": demands_met,
		"demands_failed": demands_failed,
	}


func serialize() -> Dictionary:
	var d: Dictionary = view()
	d["last_demand_tick"] = last_demand_tick
	return d


static func from_dict(d: Dictionary) -> SocietyFaction:
	var f := SocietyFaction.new(StringName(String(d.get("id", ""))))
	f.approval = float(d.get("approval", 0.0))
	f.radical = int(d.get("radical", 0))
	f.demands_made = int(d.get("demands_made", 0))
	f.demands_met = int(d.get("demands_met", 0))
	f.demands_failed = int(d.get("demands_failed", 0))
	f.last_demand_tick = int(d.get("last_demand_tick", -100000))
	return f
