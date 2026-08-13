class_name ClimateDayPlan
extends RefCounted
## One day of weather, rolled a full day in advance so the forecast the player
## reads is the weather they actually get. [P09] Climate & Nightfall.
##
## A plan is pure data: it is generated once from `Rng.stream("climate")`, then
## only ever sampled. Sampling never touches the RNG, so the number of times a
## plan is read cannot shift the sequence for the next day.

var day: int = 1                       ## 1-based campaign day
var start_tick: int = 0                ## absolute tick this day begins on
var day_ticks: int = 9600
var archetype: int = ClimateDefs.Archetype.CALM

## Weather segments, all index-aligned. `seg_start` is relative to the day start,
## strictly ascending, and always begins at 0.
var seg_start: PackedInt32Array = PackedInt32Array()
var seg_kind: PackedInt32Array = PackedInt32Array()
var seg_intensity: PackedFloat32Array = PackedFloat32Array()

## Deterministic gust phases so wind can wander without spending RNG every tick.
var gust_phase_a: float = 0.0
var gust_phase_b: float = 0.0

# --- Great Frost layer (fixed schedule, not random) ---
var has_storm: bool = false
var storm_start_tick: int = 0          ## absolute
var storm_duration_ticks: int = 0      ## includes ramp and fade
var storm_ramp_ticks: int = 900
var storm_fade_ticks: int = 1200
var storm_peak: float = 0.0            ## 0..1
var storm_title: String = ""
var storm_index: int = -1


func end_tick() -> int:
	return start_tick + day_ticks


## Weather kind (ClimateDefs.Weather) at a tick relative to this day's start.
func kind_at(rel_tick: int) -> int:
	if seg_kind.is_empty():
		return ClimateDefs.Weather.CLEAR
	return seg_kind[_segment_index(rel_tick)]


## Weather intensity 0..1 at a tick relative to this day's start.
## Segments cross-fade over `blend` ticks so weather never snaps.
func intensity_at(rel_tick: int, blend: int = 300) -> float:
	if seg_intensity.is_empty():
		return 0.0
	var i: int = _segment_index(rel_tick)
	var raw: float = seg_intensity[i]
	if i + 1 < seg_start.size():
		var next_start: int = seg_start[i + 1]
		var into: int = next_start - rel_tick
		if into < blend and seg_kind[i + 1] == seg_kind[i]:
			var t: float = 1.0 - float(into) / float(maxi(1, blend))
			raw = lerpf(raw, seg_intensity[i + 1], smoothstep(0.0, 1.0, t))
	return clampf(raw, 0.0, 1.0)


## Storm envelope 0..1 at an ABSOLUTE tick. Ramps in, holds at peak, fades out.
func storm_intensity_at(abs_tick: int) -> float:
	if not has_storm:
		return 0.0
	var t: int = abs_tick - storm_start_tick
	if t < 0 or t >= storm_duration_ticks:
		return 0.0
	var e: float = 1.0
	if t < storm_ramp_ticks:
		e = smoothstep(0.0, 1.0, float(t) / float(maxi(1, storm_ramp_ticks)))
	var tail: int = storm_duration_ticks - t
	if tail < storm_fade_ticks:
		e = minf(e, smoothstep(0.0, 1.0, float(tail) / float(maxi(1, storm_fade_ticks))))
	return storm_peak * e


func storm_end_tick() -> int:
	return storm_start_tick + storm_duration_ticks


## Dominant weather kind of the day, used for the one-line forecast in the HUD.
func dominant_kind() -> int:
	if seg_kind.is_empty():
		return ClimateDefs.Weather.CLEAR
	var worst: int = ClimateDefs.Weather.CLEAR
	for i: int in seg_kind.size():
		if seg_kind[i] > worst:
			worst = seg_kind[i]
	return worst


## Player-facing forecast line for this day.
func forecast_text() -> String:
	if has_storm:
		return "%s — %s at dusk" % [ClimateDefs.weather_label(dominant_kind()), storm_title]
	return ClimateDefs.weather_label(dominant_kind())


func to_dict() -> Dictionary:
	return {
		"day": day,
		"start_tick": start_tick,
		"archetype": String(ClimateDefs.archetype_name(archetype)),
		"seg_start": Array(seg_start),
		"seg_kind": Array(seg_kind),
		"seg_intensity": _rounded(seg_intensity),
		"gust_a": snappedf(gust_phase_a, 0.0001),
		"gust_b": snappedf(gust_phase_b, 0.0001),
		"storm": has_storm,
		"storm_start_tick": storm_start_tick,
		"storm_duration_ticks": storm_duration_ticks,
		"storm_peak": snappedf(storm_peak, 0.001),
		"storm_title": storm_title,
	}


static func from_dict(d: Dictionary, ticks_per_day: int) -> ClimateDayPlan:
	var p := ClimateDayPlan.new()
	p.day = int(d.get("day", 1))
	p.start_tick = int(d.get("start_tick", 0))
	p.day_ticks = ticks_per_day
	p.archetype = ClimateDefs.ARCHETYPE_NAMES.find(StringName(String(d.get("archetype", "calm"))))
	if p.archetype < 0:
		p.archetype = ClimateDefs.Archetype.CALM
	p.seg_start = PackedInt32Array(d.get("seg_start", []))
	p.seg_kind = PackedInt32Array(d.get("seg_kind", []))
	p.seg_intensity = PackedFloat32Array(d.get("seg_intensity", []))
	p.gust_phase_a = float(d.get("gust_a", 0.0))
	p.gust_phase_b = float(d.get("gust_b", 0.0))
	p.has_storm = bool(d.get("storm", false))
	p.storm_start_tick = int(d.get("storm_start_tick", 0))
	p.storm_duration_ticks = int(d.get("storm_duration_ticks", 0))
	p.storm_peak = float(d.get("storm_peak", 0.0))
	p.storm_title = String(d.get("storm_title", ""))
	return p


func _segment_index(rel_tick: int) -> int:
	var idx: int = 0
	for i: int in seg_start.size():
		if rel_tick >= seg_start[i]:
			idx = i
		else:
			break
	return idx


func _rounded(src: PackedFloat32Array) -> Array:
	var out: Array = []
	for i: int in src.size():
		out.append(snappedf(src[i], 0.001))
	return out
