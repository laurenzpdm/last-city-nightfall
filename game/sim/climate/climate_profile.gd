class_name ClimateProfile
extends Resource
## ============================================================================
##  THE TUNING TABLE FOR THE WHOLE GAME'S PACING.  [P09] Climate & Nightfall.
## ============================================================================
##
## Everything about how long a day lasts, how fast the world freezes, when the
## Great Frost storms arrive and how hard they bite lives in this one file.
## Change a number here and the entire campaign re-paces.
##
## The script defaults below ARE the shipped campaign. A designer can override
## any of them per biome by dropping a `.tres` into `game/content/biomes/` —
## `Registry` picks it up, and the profile with the highest `priority` wins.
## See `game/content/biomes/climate_default.tres`.
##
## Every duration is in SIM TICKS (20 per second, see SimClock.TICK_HZ).
## Every temperature is degrees Celsius.

## Id used by Registry. Must be unique across game/content/biomes/.
@export var id: StringName = &"default"
@export var display_name: String = "The Frozen Plain"
## Highest priority profile in the registry wins. Lets a scenario ship a harsher world.
@export var priority: int = 0

# --------------------------------------------------------------------------
#  DAY LENGTH AND THE SHAPE OF THE DAY
# --------------------------------------------------------------------------

## 9600 ticks = 480 s = 8 real minutes per full day/night cycle.
@export var day_ticks: int = 9600

## Start tick of each phase, index-aligned with ClimateDefs.Phase.
## Must be strictly ascending, length 6, and begin at 0.
##   dawn 0-960 (48 s) | morning 960-3072 (105.6 s) | afternoon 3072-5376 (115.2 s)
##   dusk 5376-6336 (48 s) | night 6336-8256 (96 s) | deep night 8256-9600 (67.2 s)
## Daylight is 316.8 s, darkness 163.2 s. The player gets a little over five
## minutes to build and a little under three minutes to survive.
@export var phase_starts: PackedInt32Array = PackedInt32Array([0, 960, 3072, 5376, 6336, 8256])

## Sun elevation curve, 0 = pitch dark, 1 = full noon. Keyed on day progress 0..1,
## smoothstep-interpolated between keys. Peaks mid-afternoon (0.44) and is flat
## black from 0.72 to dawn — that flat stretch is where deep night gets its teeth.
@export var sun_key_progress: PackedFloat32Array = PackedFloat32Array([
	0.00, 0.05, 0.10, 0.20, 0.32, 0.44, 0.50, 0.56, 0.62, 0.66, 0.72, 0.86, 1.00,
])
@export var sun_key_value: PackedFloat32Array = PackedFloat32Array([
	0.00, 0.10, 0.32, 0.62, 0.85, 1.00, 0.96, 0.62, 0.22, 0.04, 0.00, 0.00, 0.00,
])

# --------------------------------------------------------------------------
#  TEMPERATURE
# --------------------------------------------------------------------------

## Degrees added to the day's baseline at full sun...
@export var solar_warm_c: float = 7.0
## ...and at zero sun. The 15 C spread between them is the diurnal swing.
@export var solar_cold_c: float = -8.0

## Thermal inertia. Per-tick approach rate towards the instantaneous target.
## 0.0012 gives a time constant of ~833 ticks (~42 s), which is why the coldest
## moment of the night lands at the leading edge of dawn instead of at midnight.
@export var solar_lag: float = 0.0012
## Weather bites faster than the sun turns. ~100 tick (5 s) time constant.
@export var weather_lag: float = 0.010

# --------------------------------------------------------------------------
#  THE CAMPAIGN PRESSURE CURVE — named escalation beats
# --------------------------------------------------------------------------
# Baseline ambient temperature, interpolated linearly between beats on the
# fractional day. Each beat is a story moment: crossing into one raises an alert
# and a narrative event so the player is told the world just got worse.

@export var escalation_day: PackedInt32Array = PackedInt32Array([1, 4, 8, 13, 19, 26, 34])
@export var escalation_base_c: PackedFloat32Array = PackedFloat32Array([
	-18.0, -24.0, -31.0, -39.0, -48.0, -58.0, -70.0,
])
@export var escalation_key: PackedStringArray = PackedStringArray([
	"the_lull", "first_teeth", "the_long_night", "bone_winter",
	"the_white_death", "ash_and_ice", "the_last_dark",
])
@export var escalation_title: PackedStringArray = PackedStringArray([
	"The Lull",
	"The Cold Finds Its Teeth",
	"The Long Night",
	"Bone Winter",
	"The White Death",
	"Ash and Ice",
	"The Last Dark",
])
@export var escalation_line: PackedStringArray = PackedStringArray([
	"The plain is quiet. It will not stay quiet.",
	"Frost is reaching the inner streets now. The nights bite.",
	"Darkness holds longer than the light does. Ration your heat.",
	"Metal cracks in the open. Nothing unheated survives until morning.",
	"The horizon has gone white and stays white. This is the killing cold.",
	"Ash falls with the snow. The generators are the only reason anyone is alive.",
	"There is no season after this one. Hold the light or lose the city.",
])
## Past the last beat the world keeps sinking at this rate, forever.
@export var endgame_drop_per_day_c: float = -1.8

# --------------------------------------------------------------------------
#  GREAT FROST STORMS — the campaign's dread schedule
# --------------------------------------------------------------------------
# These days are FIXED, not random. The player can see every one of them coming
# from day one, and gets escalating warnings before each. That is the whole point:
# the storm is not a surprise, it is a deadline.

@export var frost_day: PackedInt32Array = PackedInt32Array([3, 7, 12, 18, 25, 33])
@export var frost_intensity: PackedFloat32Array = PackedFloat32Array([
	0.50, 0.66, 0.78, 0.88, 0.96, 1.00,
])
## Total length including ramp-in and fade-out.
@export var frost_duration_ticks: PackedInt32Array = PackedInt32Array([
	2400, 3000, 3600, 4200, 4800, 4800,
])
@export var frost_title: PackedStringArray = PackedStringArray([
	"First Frost", "The Second Frost", "Deepfall",
	"The Silent Storm", "The Great Frost", "Nightfall",
])
## After the scripted list runs out, a storm every N days, forever.
@export var frost_repeat_every_days: int = 6
@export var frost_repeat_intensity: float = 1.0
@export var frost_repeat_duration_ticks: int = 4800
@export var frost_repeat_title: String = "Nightfall"

## Storms open at 0.50 of the day — late afternoon, so the ramp peaks right at dusk
## and the worst of it overlaps the night assault.
@export var frost_start_progress: float = 0.50
@export var frost_ramp_ticks: int = 900
@export var frost_fade_ticks: int = 1200
## Degrees subtracted at intensity 1.0 before era scaling.
@export var frost_bite_c: float = 24.0
## Late-campaign storms bite harder than early ones by up to this fraction.
@export var frost_bite_era_scale: float = 0.35

## Warning ladder, in ticks before the storm opens. 9600 = a full day of notice.
@export var warning_offsets_ticks: PackedInt32Array = PackedInt32Array([9600, 4800, 1800, 600])
@export var warning_lines: PackedStringArray = PackedStringArray([
	"Barometers are falling across the plain. Bank every joule you can.",
	"The sky is going the colour of old iron. Close the outer districts.",
	"The wind has stopped. It always stops first.",
	"It is on the wall. Everyone inside, now.",
])

# --------------------------------------------------------------------------
#  ORDINARY WEATHER
# --------------------------------------------------------------------------
# A day is planned one full day in advance from Rng.stream("climate"), so the
# forecast the player reads is the weather they will actually get.

## Weight of each day archetype at campaign start (calm, snowy, harsh, brutal)...
@export var archetype_weight_base: PackedFloat32Array = PackedFloat32Array([0.45, 0.35, 0.15, 0.05])
## ...and how that weight moves as campaign severity goes 0 -> 1.
@export var archetype_weight_slope: PackedFloat32Array = PackedFloat32Array([-0.40, 0.05, 0.20, 0.15])
## Campaign day at which severity reaches 1.0.
@export var severity_full_day: int = 30

## Per-archetype weather weights, row-major: 4 archetypes x 4 weather kinds
## (clear, overcast, snowfall, blizzard).
@export var archetype_weather_weights: PackedFloat32Array = PackedFloat32Array([
	0.60, 0.30, 0.10, 0.00,
	0.15, 0.30, 0.50, 0.05,
	0.05, 0.20, 0.50, 0.25,
	0.00, 0.10, 0.35, 0.55,
])

@export var segments_min: int = 3
@export var segments_max: int = 5

## Degrees each weather kind subtracts at full intensity, index-aligned with Weather.
@export var weather_temp_c: PackedFloat32Array = PackedFloat32Array([0.0, -1.5, -3.0, -9.0])
## Extra degrees at night only. A clear night radiates heat away; cloud holds it in.
@export var weather_night_c: PackedFloat32Array = PackedFloat32Array([-3.0, 2.0, 1.0, 0.0])
## Baseline wind 0..1 per weather kind.
@export var weather_wind: PackedFloat32Array = PackedFloat32Array([0.12, 0.20, 0.42, 0.88])
## Visibility 0..1 at full intensity per weather kind. A whiteout is a whiteout.
@export var weather_visibility: PackedFloat32Array = PackedFloat32Array([1.0, 0.92, 0.70, 0.30])
## Visibility inside a Great Frost at full intensity.
@export var storm_visibility: float = 0.14
## Wind a full-intensity Great Frost adds on top of the base weather.
@export var storm_wind: float = 0.6

@export var segment_intensity_min: float = 0.45
@export var segment_intensity_max: float = 1.00
## Intensities are scaled by (1 - k) + k * severity, so early storms are softer.
@export var segment_intensity_severity_k: float = 0.40

# --------------------------------------------------------------------------
#  WHAT THE REST OF THE GAME READS OFF THE CLIMATE
# --------------------------------------------------------------------------

## Heat loss multiplier = 1 + wind*k_wind + storm*k_storm + cold term.
@export var heat_loss_wind_k: float = 0.55
@export var heat_loss_storm_k: float = 1.40
## Below this ambient the cold term starts adding leak...
@export var heat_loss_cold_ref_c: float = -20.0
## ...at one extra multiple per this many degrees below the reference.
@export var heat_loss_cold_span_c: float = 45.0
@export var heat_loss_max: float = 6.0

## An unsheltered cell at or above this is safe.
@export var exposure_safe_c: float = -5.0
## An unsheltered cell at or below this kills fast. Between the two, exposure ramps 0..1.
@export var exposure_lethal_c: float = -55.0

## Snow depth 0..1. Gain per tick at full-intensity snowfall.
@export var snow_gain_per_tick: float = 0.00006
## Blizzards and storms pile it on faster.
@export var snow_blizzard_mult: float = 2.6
@export var snow_storm_mult: float = 3.4
## Melt per tick under clear sun, only above the melt threshold.
@export var snow_melt_per_tick: float = 0.000012
@export var snow_melt_above_c: float = -25.0

## Cells warmer than ambient by at least this much are pulled from the heat system
## every this many ticks. Cheap, and 0.5 s of staleness is invisible.
@export var heat_pull_interval_ticks: int = 10


## Clamps a hand-edited or hand-authored profile into something the system can run.
## Returns false if it had to repair anything.
func validate() -> bool:
	var ok: bool = true

	day_ticks = maxi(120, day_ticks)

	if phase_starts.size() != ClimateDefs.PHASE_COUNT:
		phase_starts = PackedInt32Array([0, 960, 3072, 5376, 6336, 8256])
		ok = false
	phase_starts[0] = 0
	for i: int in range(1, phase_starts.size()):
		phase_starts[i] = clampi(phase_starts[i], phase_starts[i - 1] + 1, day_ticks - (ClimateDefs.PHASE_COUNT - i))

	if sun_key_progress.size() != sun_key_value.size() or sun_key_progress.size() < 2:
		sun_key_progress = PackedFloat32Array([0.0, 0.44, 0.72, 1.0])
		sun_key_value = PackedFloat32Array([0.0, 1.0, 0.0, 0.0])
		ok = false

	var beats: int = escalation_day.size()
	if escalation_base_c.size() < beats or escalation_key.size() < beats \
			or escalation_title.size() < beats or escalation_line.size() < beats:
		beats = mini(mini(escalation_day.size(), escalation_base_c.size()),
				mini(mini(escalation_key.size(), escalation_title.size()), escalation_line.size()))
		escalation_day = escalation_day.slice(0, beats)
		escalation_base_c = escalation_base_c.slice(0, beats)
		escalation_key = escalation_key.slice(0, beats)
		escalation_title = escalation_title.slice(0, beats)
		escalation_line = escalation_line.slice(0, beats)
		ok = false
	if beats == 0:
		escalation_day = PackedInt32Array([1])
		escalation_base_c = PackedFloat32Array([-18.0])
		escalation_key = PackedStringArray(["the_lull"])
		escalation_title = PackedStringArray(["The Lull"])
		escalation_line = PackedStringArray(["The plain is quiet."])
		ok = false

	var storms: int = frost_day.size()
	if frost_intensity.size() < storms or frost_duration_ticks.size() < storms or frost_title.size() < storms:
		storms = mini(frost_day.size(), mini(frost_intensity.size(),
				mini(frost_duration_ticks.size(), frost_title.size())))
		frost_day = frost_day.slice(0, storms)
		frost_intensity = frost_intensity.slice(0, storms)
		frost_duration_ticks = frost_duration_ticks.slice(0, storms)
		frost_title = frost_title.slice(0, storms)
		ok = false

	if archetype_weight_base.size() != ClimateDefs.ARCHETYPE_COUNT:
		archetype_weight_base = PackedFloat32Array([0.45, 0.35, 0.15, 0.05])
		ok = false
	if archetype_weight_slope.size() != ClimateDefs.ARCHETYPE_COUNT:
		archetype_weight_slope = PackedFloat32Array([-0.40, 0.05, 0.20, 0.15])
		ok = false
	if archetype_weather_weights.size() != ClimateDefs.ARCHETYPE_COUNT * ClimateDefs.WEATHER_COUNT:
		archetype_weather_weights = PackedFloat32Array([
			0.60, 0.30, 0.10, 0.00,
			0.15, 0.30, 0.50, 0.05,
			0.05, 0.20, 0.50, 0.25,
			0.00, 0.10, 0.35, 0.55,
		])
		ok = false
	for arr: PackedFloat32Array in [weather_temp_c, weather_night_c, weather_wind, weather_visibility]:
		if arr.size() != ClimateDefs.WEATHER_COUNT:
			ok = false
	if weather_temp_c.size() != ClimateDefs.WEATHER_COUNT:
		weather_temp_c = PackedFloat32Array([0.0, -1.5, -3.0, -9.0])
	if weather_night_c.size() != ClimateDefs.WEATHER_COUNT:
		weather_night_c = PackedFloat32Array([-3.0, 2.0, 1.0, 0.0])
	if weather_wind.size() != ClimateDefs.WEATHER_COUNT:
		weather_wind = PackedFloat32Array([0.12, 0.20, 0.42, 0.88])
	if weather_visibility.size() != ClimateDefs.WEATHER_COUNT:
		weather_visibility = PackedFloat32Array([1.0, 0.92, 0.70, 0.30])

	if warning_offsets_ticks.size() == 0:
		warning_offsets_ticks = PackedInt32Array([day_ticks, 1800, 600])
		ok = false

	segments_min = maxi(1, segments_min)
	segments_max = maxi(segments_min, segments_max)
	severity_full_day = maxi(2, severity_full_day)
	frost_start_progress = clampf(frost_start_progress, 0.0, 0.95)
	frost_ramp_ticks = maxi(1, frost_ramp_ticks)
	frost_fade_ticks = maxi(1, frost_fade_ticks)
	frost_repeat_every_days = maxi(0, frost_repeat_every_days)
	heat_pull_interval_ticks = maxi(1, heat_pull_interval_ticks)
	solar_lag = clampf(solar_lag, 0.00001, 1.0)
	weather_lag = clampf(weather_lag, 0.00001, 1.0)
	return ok


## Tick within the day at which night begins. The single most load-bearing number in the HUD.
func night_start_tick() -> int:
	return phase_starts[ClimateDefs.Phase.NIGHT]


## 0 at day 1, 1.0 at `severity_full_day` and beyond. Drives weather nastiness.
func severity_for_day(day: int) -> float:
	return clampf(float(day - 1) / float(maxi(1, severity_full_day - 1)), 0.0, 1.0)


## Baseline ambient for a fractional day (day 1.0 = first dawn), before sun and weather.
func base_temperature_for_day(day_float: float) -> float:
	var n: int = escalation_day.size()
	if day_float <= float(escalation_day[0]):
		return escalation_base_c[0]
	for i: int in range(1, n):
		if day_float <= float(escalation_day[i]):
			var lo: float = float(escalation_day[i - 1])
			var hi: float = float(escalation_day[i])
			var t: float = (day_float - lo) / maxf(0.0001, hi - lo)
			return lerpf(escalation_base_c[i - 1], escalation_base_c[i], t)
	return escalation_base_c[n - 1] + endgame_drop_per_day_c * (day_float - float(escalation_day[n - 1]))


## Index of the escalation beat in force on `day`.
func era_index_for_day(day: int) -> int:
	var idx: int = 0
	for i: int in escalation_day.size():
		if day >= escalation_day[i]:
			idx = i
	return idx


## Sun elevation 0..1 for a day progress 0..1.
func sun_at(progress: float) -> float:
	var n: int = sun_key_progress.size()
	var p: float = clampf(progress, 0.0, 1.0)
	if p <= sun_key_progress[0]:
		return sun_key_value[0]
	for i: int in range(1, n):
		if p <= sun_key_progress[i]:
			var span: float = maxf(0.000001, sun_key_progress[i] - sun_key_progress[i - 1])
			var t: float = (p - sun_key_progress[i - 1]) / span
			return lerpf(sun_key_value[i - 1], sun_key_value[i], smoothstep(0.0, 1.0, t))
	return sun_key_value[n - 1]


## Great Frost scheduled for this day, or an empty dictionary.
## Keys: intensity (float), duration_ticks (int), title (String), index (int).
func frost_for_day(day: int) -> Dictionary:
	for i: int in frost_day.size():
		if frost_day[i] == day:
			return {
				"intensity": float(frost_intensity[i]),
				"duration_ticks": int(frost_duration_ticks[i]),
				"title": String(frost_title[i]),
				"index": i,
			}
	if frost_repeat_every_days > 0 and frost_day.size() > 0:
		var last: int = frost_day[frost_day.size() - 1]
		if day > last and (day - last) % frost_repeat_every_days == 0:
			return {
				"intensity": frost_repeat_intensity,
				"duration_ticks": frost_repeat_duration_ticks,
				"title": frost_repeat_title,
				"index": frost_day.size() + (day - last) / frost_repeat_every_days - 1,
			}
	return {}


## First scheduled Great Frost strictly after `from_day`, searching `horizon` days.
## Returns {} if none inside the horizon. Purely a function of the tuning table —
## no randomness — which is exactly why the player can plan around it.
func next_frost_after(from_day: int, horizon: int = 120) -> Dictionary:
	for d: int in range(from_day, from_day + maxi(1, horizon) + 1):
		var f: Dictionary = frost_for_day(d)
		if not f.is_empty():
			f["day"] = d
			return f
	return {}
