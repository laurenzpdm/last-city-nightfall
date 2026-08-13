class_name DifficultyCurve
extends Resource
## ============================================================================
##  THE INTENDED EXPERIENCE, DAY BY DAY.  [P12] Economy & Balance.
## ============================================================================
##
## A balance target that cannot be measured is an opinion. This resource says,
## per campaign day, what a real headless run has to look like — and
## `EconomyReport` measures a run against it. Both `tools/analyze_balance.py`
## and `tests/economy/` read this same file, so "day three should hurt" is a
## number with a pass/fail, not a note in a design doc.
##
## The measured quantity for each day is taken over the DARK half of that day
## (dusk, night, deep night), because that is when the game is played:
##
##   margin        = heat supply / heat demand, averaged over the dark phases
##   trough        = the single lowest margin sample of the night
##   frozen        = frozen buildings / buildings on the heat grid, at its worst
##   buffer_floor  = lowest stored heat as a fraction of grid buffer capacity
##
## Bands are inclusive. A run inside every band on a day is that day working as
## designed. `EconomyDefs.verdict_for` grades how far outside a miss is, so a
## 2% overshoot reads differently from a 200% one.

@export var id: StringName = &"default"
@export var display_name: String = "The First Week"
@export var priority: int = 0

## Ticks in one day/night cycle. Must agree with ClimateProfile.day_ticks;
## `Balance.day_ticks()` prefers the live climate value when [P09] is present.
@export var day_ticks: int = 9600

## The days that carry a designed intent. Index-aligned with every array below.
@export var day: PackedInt32Array = PackedInt32Array([1, 2, 3, 4, 5, 6, 7])

## One line each, in the player's language. This is the actual deliverable of
## balancing; the numbers underneath it are how we prove it happened.
@export var intent: PackedStringArray = PackedStringArray([
	"Survivable by an attentive beginner. The night bites, the buffer covers it, nobody dies.",
	"The first real squeeze. Industry browns out before the homes do, and the player feels the shed order.",
	"First Frost. The storm is on the calendar from minute one and it should still nearly take the city.",
	"The morning after. Colder baseline, a grid that has to be rebuilt wider before dusk.",
	"Consolidation. The player who banked storage on day 4 has a quiet night; the one who did not, does not.",
	"The stretch before the second storm. Demand outgrows a hearth-only city for good.",
	"The Second Frost. A city with no thermal storage and no second generator ring does not see day 8.",
])

## Short label for reports and for the eventual [P20] stats screen.
@export var label: PackedStringArray = PackedStringArray([
	"First Night", "The Squeeze", "First Frost", "Colder Ground",
	"Consolidation", "Outgrown", "Second Frost",
])

# --- the measured bands -------------------------------------------------------

## Average supply/demand across the dark phases.
@export var margin_min: PackedFloat32Array = PackedFloat32Array([
	0.88, 0.80, 0.62, 0.72, 0.74, 0.68, 0.52,
])
@export var margin_max: PackedFloat32Array = PackedFloat32Array([
	1.45, 1.30, 1.05, 1.25, 1.30, 1.20, 1.00,
])

## The worst single sample of the night. This is the number that decides whether
## a night is frightening; the average only decides whether it is survivable.
@export var trough_min: PackedFloat32Array = PackedFloat32Array([
	0.62, 0.52, 0.30, 0.42, 0.46, 0.40, 0.22,
])
@export var trough_max: PackedFloat32Array = PackedFloat32Array([
	1.10, 1.02, 0.86, 1.00, 1.05, 0.98, 0.80,
])

## Worst fraction of heat-grid buildings frozen at once. Freezing is the loss
## condition made visible, so day 1 allows almost none of it and day 7 allows a
## district's worth.
@export var frozen_max: PackedFloat32Array = PackedFloat32Array([
	0.04, 0.07, 0.16, 0.14, 0.13, 0.16, 0.26,
])

## Lowest stored heat as a fraction of buffer capacity. Reaching 0 means the
## storage did its job and then ran out, which is the designed shape of a storm
## night and a failure on a quiet one.
@export var buffer_floor_min: PackedFloat32Array = PackedFloat32Array([
	0.05, 0.02, 0.0, 0.0, 0.0, 0.0, 0.0,
])

## True on the days a Great Frost is scheduled. Kept here rather than derived so
## the curve stays readable next to ClimateProfile.frost_day.
@export var storm_day: PackedInt32Array = PackedInt32Array([3, 7])

## How far outside a band still counts as a soft miss rather than a failure,
## in band widths. Runs drift; a gate that fires on 1% drift gets disabled.
@export var soft_tolerance: float = 0.30


func validate() -> bool:
	var ok: bool = true
	day_ticks = maxi(120, day_ticks)
	soft_tolerance = clampf(soft_tolerance, 0.0, 2.0)

	var n: int = day.size()
	if n < 1:
		day = PackedInt32Array([1])
		n = 1
		ok = false
	for i: int in range(1, n):
		if day[i] <= day[i - 1]:
			day[i] = day[i - 1] + 1
			ok = false

	intent = _fit_strings(intent, n, "")
	label = _fit_strings(label, n, "Day")
	margin_min = _fit_floats(margin_min, n, 0.0)
	margin_max = _fit_floats(margin_max, n, 99.0)
	trough_min = _fit_floats(trough_min, n, 0.0)
	trough_max = _fit_floats(trough_max, n, 99.0)
	frozen_max = _fit_floats(frozen_max, n, 1.0)
	buffer_floor_min = _fit_floats(buffer_floor_min, n, 0.0)

	for i: int in n:
		if margin_max[i] < margin_min[i]:
			margin_max[i] = margin_min[i]
			ok = false
		if trough_max[i] < trough_min[i]:
			trough_max[i] = trough_min[i]
			ok = false
		frozen_max[i] = clampf(frozen_max[i], 0.0, 1.0)
		buffer_floor_min[i] = clampf(buffer_floor_min[i], 0.0, 1.0)
	return ok


## Index into the parallel arrays for a campaign day, or -1 when the curve says
## nothing about it. Days past the last entry deliberately return -1: the design
## stops making promises rather than extrapolating them.
func index_of_day(campaign_day: int) -> int:
	for i: int in day.size():
		if day[i] == campaign_day:
			return i
	return -1


## Every designed day, ascending.
func days() -> PackedInt32Array:
	return day.duplicate()


func is_storm_day(campaign_day: int) -> bool:
	return storm_day.has(campaign_day)


## The whole design for one day as plain data, or {} when undesigned.
func targets_for(campaign_day: int) -> Dictionary:
	var i: int = index_of_day(campaign_day)
	if i < 0:
		return {}
	return {
		"day": campaign_day,
		"label": label[i],
		"intent": intent[i],
		"storm": is_storm_day(campaign_day),
		"margin_min": float(margin_min[i]),
		"margin_max": float(margin_max[i]),
		"trough_min": float(trough_min[i]),
		"trough_max": float(trough_max[i]),
		"frozen_max": float(frozen_max[i]),
		"buffer_floor_min": float(buffer_floor_min[i]),
	}


static func _fit_floats(src: PackedFloat32Array, n: int, fill: float) -> PackedFloat32Array:
	if src.size() == n:
		return src
	var out := PackedFloat32Array()
	for i: int in n:
		out.append(float(src[i]) if i < src.size() else fill)
	return out


static func _fit_strings(src: PackedStringArray, n: int, fill: String) -> PackedStringArray:
	if src.size() == n:
		return src
	var out := PackedStringArray()
	for i: int in n:
		out.append(String(src[i]) if i < src.size() else fill)
	return out
