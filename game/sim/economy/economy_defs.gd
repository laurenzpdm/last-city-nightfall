class_name EconomyDefs
extends RefCounted
## [P12] Economy & Balance — shared vocabulary.
##
## Names, buckets and pure helpers that every other economy file agrees on.
## Nothing here holds tuning values; those live in BalanceTable so a designer
## has exactly one file to open. This one exists so a typo in a category name
## is a parse error rather than a silently empty lookup.

# ---------------------------------------------------------------- categories -

## Build-menu / balance categories, matching BuildingDef.category.
const CATEGORIES: Array[StringName] = [
	&"power", &"heat", &"extraction", &"production", &"logistics",
	&"housing", &"storage", &"defense", &"infrastructure",
]

## Categories whose members are expected to put heat INTO the grid.
const PRODUCER_CATEGORIES: Array[StringName] = [&"power"]

## Progression tiers a definition may claim. Tier gates the audit bands.
const MIN_TIER: int = 1
const MAX_TIER: int = 4

# --------------------------------------------------------------------- phases -

## Index-aligned with ClimateDefs.Phase, repeated here so economy code does not
## have to depend on [P09] being present to bucket a metrics row.
const PHASES: Array[StringName] = [
	&"dawn", &"morning", &"afternoon", &"dusk", &"night", &"deep_night",
]

## The half of the day the player builds in...
const DAY_PHASES: Array[StringName] = [&"dawn", &"morning", &"afternoon"]
## ...and the half they survive.
const NIGHT_PHASES: Array[StringName] = [&"dusk", &"night", &"deep_night"]

# ---------------------------------------------------------------------- time -

## A full day/night cycle in ticks. Mirrors ClimateProfile.day_ticks; the live
## value is read from [P09] when it exists (see Balance.day_ticks).
const DEFAULT_DAY_TICKS: int = 9600
const TICKS_PER_SECOND: int = 20

# ------------------------------------------------------------------- verdicts -

## Result of measuring one designed expectation against a real run.
const VERDICT_PASS: StringName = &"pass"
const VERDICT_SOFT: StringName = &"soft"    ## outside the band but not by much
const VERDICT_FAIL: StringName = &"fail"
const VERDICT_NO_DATA: StringName = &"no_data"


## Day index (1-based) a tick falls in.
static func day_of_tick(tick: int, day_ticks: int = DEFAULT_DAY_TICKS) -> int:
	return 1 + int(floor(float(maxi(0, tick)) / float(maxi(1, day_ticks))))


## True when this phase name belongs to the dark half of the day.
static func is_night_phase(phase: StringName) -> bool:
	return NIGHT_PHASES.has(phase)


## supply / demand, guarded. 1.0 when nothing is asking for heat: a city with no
## demand is not in trouble, and reporting an infinite margin helps nobody.
static func margin(supply: float, demand: float) -> float:
	if demand <= 0.001:
		return 1.0
	return supply / demand


## Where a value sits relative to a band, as a signed fraction of the band width.
## 0.0 inside, -0.5 half a band below `low`, +0.25 a quarter above `high`.
static func band_offset(value: float, low: float, high: float) -> float:
	var width: float = maxf(0.0001, high - low)
	if value < low:
		return (value - low) / width
	if value > high:
		return (value - high) / width
	return 0.0


## Band verdict with a tolerance: inside is a pass, within `soft` band-widths of
## an edge is a soft miss, anything further is a failure.
static func verdict_for(value: float, low: float, high: float, soft: float = 0.25) -> StringName:
	var off: float = absf(band_offset(value, low, high))
	if off <= 0.0:
		return VERDICT_PASS
	if off <= soft:
		return VERDICT_SOFT
	return VERDICT_FAIL


## Sorted keys. Every iteration in this part goes through here so no economy
## code can ever walk a Dictionary in hash order (ARCHITECTURE.md §3).
static func sorted_keys(d: Dictionary) -> Array:
	var keys: Array = d.keys()
	keys.sort()
	return keys
