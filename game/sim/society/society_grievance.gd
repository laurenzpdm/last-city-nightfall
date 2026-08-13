class_name SocietyGrievance
extends RefCounted
## One standing complaint, held by one faction, about one thing.
##
## A grievance is not a boolean. It has to be sustained before it opens, it
## builds while the cause persists, it fades when the cause is fixed, and it
## only turns into a demand once it has been ignored long enough to be worth
## making a scene about. That hysteresis is what stops a two second brownout
## from producing a riot and what makes a genuinely bad week feel inevitable.

var kind: StringName = &""
var faction: StringName = &""
var open: bool = false
## 0..1. What the grievance is doing right now.
var intensity: float = 0.0
## 0..1. The measured cause, before hysteresis.
var pressure: float = 0.0
## Hours the pressure has been over the open line, or under the close line.
var above_hours: float = 0.0
var below_hours: float = 0.0
var opened_tick: int = -1
var closed_tick: int = -1
## Highest intensity ever reached. A grievance that peaked hard is remembered.
var peak: float = 0.0
var times_opened: int = 0
## The specific sentence with this run's numbers in it.
var detail: String = ""


func _init(k: StringName = &"") -> void:
	kind = k
	faction = SocietyDefs.grievance_faction(k)


func title() -> String:
	return SocietyDefs.grievance_title(kind)


func complaint() -> String:
	return SocietyDefs.grievance_complaint(kind)


func resolved_line() -> String:
	return SocietyDefs.grievance_resolved(kind)


## Advances hysteresis and intensity. Returns &"opened", &"closed" or &"".
func update(new_pressure: float, hours: float) -> StringName:
	pressure = clampf(new_pressure, 0.0, 1.0)
	var change: StringName = &""
	if pressure >= SocietyDefs.GRIEVANCE_OPEN:
		above_hours += hours
		below_hours = 0.0
	elif pressure <= SocietyDefs.GRIEVANCE_CLOSE:
		below_hours += hours
		above_hours = 0.0
	else:
		above_hours = maxf(0.0, above_hours - hours * 0.5)
		below_hours = maxf(0.0, below_hours - hours * 0.5)

	if not open and above_hours >= SocietyDefs.GRIEVANCE_OPEN_HOURS:
		open = true
		times_opened += 1
		change = &"opened"
	elif open and below_hours >= SocietyDefs.GRIEVANCE_CLOSE_HOURS and intensity <= 0.05:
		open = false
		change = &"closed"

	if open:
		# The floor keeps a grievance simmering while the cause is only half
		# fixed, but it must NOT apply once the cause is genuinely gone: a floor
		# that outlives the problem is a grievance that can never be closed, and
		# a city that can never be forgiven is not a system, it is a countdown.
		var target: float = pressure
		if pressure > SocietyDefs.GRIEVANCE_CLOSE:
			target = maxf(pressure, 0.12)
		if target > intensity:
			intensity = minf(target, intensity + SocietyDefs.GRIEVANCE_RISE_PER_HOUR * hours)
		else:
			intensity = maxf(target, intensity - SocietyDefs.GRIEVANCE_FALL_PER_HOUR * hours)
	else:
		intensity = maxf(0.0, intensity - SocietyDefs.GRIEVANCE_FALL_PER_HOUR * hours)
	peak = maxf(peak, intensity)
	return change


## Discontent per hour this grievance is generating city wide.
func discontent_rate(radical: int) -> float:
	if not open and intensity <= 0.0:
		return 0.0
	var share: float = SocietyDefs.faction_share(faction)
	return SocietyDefs.GRIEVANCE_DISCONTENT_PER_HOUR * intensity * share \
		* (1.0 + 0.45 * float(radical))


func hope_rate() -> float:
	if not open and intensity <= 0.0:
		return 0.0
	return SocietyDefs.GRIEVANCE_HOPE_PER_HOUR * intensity * SocietyDefs.faction_share(faction)


func ready_to_demand() -> bool:
	return open and intensity >= SocietyDefs.DEMAND_INTENSITY


func view() -> Dictionary:
	return {
		"kind": String(kind),
		"faction": String(faction),
		"faction_name": SocietyDefs.faction_name(faction),
		"title": title(),
		"complaint": complaint(),
		"detail": detail,
		"open": open,
		"intensity": snappedf(intensity, 0.001),
		"pressure": snappedf(pressure, 0.001),
		"peak": snappedf(peak, 0.001),
		"opened_tick": opened_tick,
		"times_opened": times_opened,
	}


func serialize() -> Dictionary:
	var d: Dictionary = view()
	d["above_hours"] = snappedf(above_hours, 0.01)
	d["below_hours"] = snappedf(below_hours, 0.01)
	d["closed_tick"] = closed_tick
	return d


static func from_dict(d: Dictionary) -> SocietyGrievance:
	var g := SocietyGrievance.new(StringName(String(d.get("kind", ""))))
	g.open = bool(d.get("open", false))
	g.intensity = float(d.get("intensity", 0.0))
	g.pressure = float(d.get("pressure", 0.0))
	g.peak = float(d.get("peak", 0.0))
	g.above_hours = float(d.get("above_hours", 0.0))
	g.below_hours = float(d.get("below_hours", 0.0))
	g.opened_tick = int(d.get("opened_tick", -1))
	g.closed_tick = int(d.get("closed_tick", -1))
	g.times_opened = int(d.get("times_opened", 0))
	g.detail = String(d.get("detail", ""))
	return g
