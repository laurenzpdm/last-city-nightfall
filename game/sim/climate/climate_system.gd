class_name ClimateSystem
extends SimSystem
## [P09] Climate & Nightfall — the game's heartbeat and its dread pump.
##
## Owns the day/night arc, the temperature model, the weather, and the fixed
## schedule of Great Frost storms that paces the whole campaign. Runs first
## (order 10) so every other system reads a settled climate for this tick.
##
## Contract for other parts:
##   * Time / pacing:  phase_of_day(), day(), day_progress(), is_night(),
##                     seconds_until_night(), seconds_until_dawn()
##   * Temperature:    ambient_temperature(), local_temperature(cell),
##                     exposure_at(cell), heat_loss_multiplier()
##   * Heat hook:      set_local_offset() / add_local_offset() / clear_local_offsets(),
##                     or expose `warmth_field() -> Dictionary` on the heat system
##                     and climate pulls it automatically.
##   * Weather:        weather(), weather_intensity(), wind(), visibility(),
##                     light_level(), snow_depth(), storm_intensity()
##   * Telegraphing:   next_storm(), seconds_until_storm(), forecast()
##
## All tuning lives in ClimateProfile (game/sim/climate/climate_profile.gd,
## overridable by a .tres in game/content/biomes/). Nothing is hardcoded here.

const TAG: String = "climate"
const RNG_STREAM: String = "climate"

var _profile: ClimateProfile = null

# --- clock ---
var _sim_tick: int = 0
var _clock_tick: int = 0          ## sim tick + _offset; the climate's own timeline
var _offset: int = 0              ## set by debug/tutorial commands to skip ahead
var _day_ticks: int = 9600
var _day: int = 1
var _tick_in_day: int = 0
var _phase_idx: int = ClimateDefs.Phase.DAWN
var _sun: float = 0.0

# --- temperature ---
var _ambient: float = -18.0
var _solar_c: float = 0.0
var _weather_c: float = 0.0

# --- weather ---
var _weather_kind: int = ClimateDefs.Weather.CLEAR
var _weather_intensity: float = 0.0
var _wind: float = 0.0
var _visibility: float = 1.0
var _snow: float = 0.0

# --- storms ---
var _storm_i: float = 0.0
var _storm_active: bool = false
var _storm_title: String = ""
var _storm_day: int = 0

# --- campaign ---
var _era_idx: int = 0

# --- plans + telegraphing ---
var _plans: Dictionary[int, ClimateDayPlan] = {}
var _warnings: Array[Dictionary] = []
var _warn_scheduled: Dictionary[int, bool] = {}

# --- local temperature grid, written by [P02] heat ---
var _local: Dictionary[Vector2i, float] = {}
## Weak on purpose: [P02] holds a reference back to climate, and two RefCounted
## systems pointing at each other would leak the whole world on teardown.
var _heat_ref: WeakRef = null
var _heat_has_warmth_at: bool = false


func _init() -> void:
	order = 10


func system_name() -> StringName:
	return &"climate"


# ==========================================================================
#  LIFECYCLE
# ==========================================================================

func setup() -> void:
	_profile = _load_profile()
	_day_ticks = _profile.day_ticks
	_sim_tick = 0
	_clock_tick = 0
	_offset = 0
	_day = 1
	_tick_in_day = 0
	_phase_idx = ClimateDefs.Phase.DAWN
	_era_idx = _profile.era_index_for_day(1)
	_plans.clear()
	_warnings.clear()
	_warn_scheduled.clear()
	_local.clear()
	_heat_ref = null
	_heat_has_warmth_at = false
	_storm_i = 0.0
	_storm_active = false
	_storm_title = ""
	_storm_day = 0
	_snow = 0.0

	_ensure_plan(1)
	_ensure_plan(2)
	_schedule_storm_warnings(_plans[1])
	_schedule_storm_warnings(_plans[2])

	# Seed the lagged accumulators at their steady-state value so the first
	# minute of the game is not a thermal transient.
	_sun = _profile.sun_at(0.0)
	_update_weather(0)
	_solar_c = lerpf(_profile.solar_cold_c, _profile.solar_warm_c, _sun)
	_weather_c = _weather_target(false)
	_ambient = _profile.base_temperature_for_day(1.0) + _solar_c + _weather_c

	Log.info(TAG, "day 1 begins — %s, %.1f C, forecast: %s" % [
		_profile.display_name, _ambient, _plans[1].forecast_text(),
	])
	Bus.day_started.emit(1)


func post_setup() -> void:
	# [P02] may not exist yet during parallel development; everything here is optional.
	_refresh_heat_binding()
	if _heat_system() != null:
		Log.debug(TAG, "heat system found (warmth_at=%s); local warmth resolved every %d ticks"
				% [str(_heat_has_warmth_at), _profile.heat_pull_interval_ticks])


func step(tick: int) -> void:
	_sim_tick = tick
	_clock_tick = maxi(0, tick + _offset)

	@warning_ignore("integer_division")
	var new_day: int = _clock_tick / _day_ticks + 1
	_tick_in_day = _clock_tick % _day_ticks
	if new_day != _day:
		_roll_to_day(new_day)

	var next_phase: int = _phase_index_at(_tick_in_day)
	_sun = _profile.sun_at(day_progress())

	_update_storm()
	_update_weather(next_phase)
	_update_temperature(next_phase)
	_emit_phase_change(next_phase)
	_flush_warnings()

	if _clock_tick % _profile.heat_pull_interval_ticks == 0:
		_pull_local_from_heat()


# ==========================================================================
#  PUBLIC API — TIME
# ==========================================================================

## &"dawn", &"morning", &"afternoon", &"dusk", &"night" or &"deep_night".
func phase_of_day() -> StringName:
	return ClimateDefs.phase_name(_phase_idx)


## Raw ClimateDefs.Phase index, for systems that want to compare ordering.
func phase_index() -> int:
	return _phase_idx


## Human-facing phase name, e.g. "Deep Night".
func phase_label() -> String:
	return ClimateDefs.phase_label(_phase_idx)


## 0.0 at the first instant of dawn, approaching 1.0 at the end of deep night.
func day_progress() -> float:
	return float(_tick_in_day) / float(_day_ticks)


## 0.0 at the first tick of the current phase, approaching 1.0 at its last.
## [P13] maps (phase_of_day, phase_progress) onto its colour arc — that pair is
## the join between this system's six phases and the palette's nine keyframes,
## and it is why dawn on screen is the same instant as dawn in the sim.
func phase_progress() -> float:
	var start: int = _profile.phase_starts[_phase_idx]
	var stop: int = _day_ticks
	if _phase_idx + 1 < ClimateDefs.PHASE_COUNT:
		stop = _profile.phase_starts[_phase_idx + 1]
	return clampf(float(_tick_in_day - start) / float(maxi(1, stop - start)), 0.0, 1.0)


## 1-based campaign day.
func day() -> int:
	return _day


## True through night and deep night.
func is_night() -> bool:
	return _phase_idx >= ClimateDefs.Phase.NIGHT


func is_deep_night() -> bool:
	return _phase_idx == ClimateDefs.Phase.DEEP_NIGHT


## The HUD's most important number. 0.0 once night has already fallen.
func seconds_until_night() -> float:
	if is_night():
		return 0.0
	return float(_profile.night_start_tick() - _tick_in_day) * SimClock.DT


## Counterpart for the other half of the cycle. 0.0 while it is daylight.
func seconds_until_dawn() -> float:
	if not is_night():
		return 0.0
	return float(_day_ticks - _tick_in_day) * SimClock.DT


## Seconds until the current phase gives way to the next one.
func seconds_until_phase_change() -> float:
	var next_start: int = _day_ticks
	if _phase_idx + 1 < ClimateDefs.PHASE_COUNT:
		next_start = _profile.phase_starts[_phase_idx + 1]
	return float(next_start - _tick_in_day) * SimClock.DT


func day_length_seconds() -> float:
	return float(_day_ticks) * SimClock.DT


func daylight_seconds() -> float:
	return float(_profile.night_start_tick()) * SimClock.DT


func night_length_seconds() -> float:
	return float(_day_ticks - _profile.night_start_tick()) * SimClock.DT


## Sun elevation 0..1. Render and vfx drive sky colour and shadow length off this.
func light_level() -> float:
	return _sun


# ==========================================================================
#  PUBLIC API — TEMPERATURE
# ==========================================================================

## Global outdoor temperature in Celsius. [P02] heat reads this every tick.
func ambient_temperature() -> float:
	return _ambient


## Ambient plus whatever warmth the heat network delivers to this cell.
func local_temperature(cell: Vector2i) -> float:
	return _ambient + _local.get(cell, 0.0)


## Degrees of warmth currently delivered to a cell above ambient. Sums what was
## pushed in with whatever [P02] radiates onto the tile, so climate and heat
## always agree on what a citizen standing there feels.
func local_offset(cell: Vector2i) -> float:
	return _local.get(cell, 0.0) + _heat_warmth_at(cell)


## [P02] heat writes into this grid. Absolute set, in degrees above ambient.
func set_local_offset(cell: Vector2i, celsius: float) -> void:
	if absf(celsius) < 0.0001:
		_local.erase(cell)
	else:
		_local[cell] = celsius


## [P02] heat accumulates from several sources into one cell.
func add_local_offset(cell: Vector2i, celsius: float) -> void:
	set_local_offset(cell, _local.get(cell, 0.0) + celsius)


## Degrees the heat network radiates onto a tile, 0 when [P02] is absent.
func _heat_warmth_at(cell: Vector2i) -> float:
	var h: SimSystem = _heat_system()
	if not _heat_has_warmth_at or h == null:
		return 0.0
	var v: Variant = h.call(&"warmth_at", cell)
	if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
		return float(v)
	return 0.0


## Heat calls this before rewriting the field each tick.
func clear_local_offsets() -> void:
	_local.clear()


## Copy of the warmth grid, for overlays and tests. Never the live dictionary.
func local_offset_grid() -> Dictionary:
	return _local.duplicate()


## Cells that were pushed into climate. Warmth that [P02] radiates through
## warmth_at() is not counted here — ask the heat system for that census.
func warm_cell_count() -> int:
	return _local.size()


## 0 = comfortable, 1 = lethal exposure, for an unsheltered citizen on this cell.
func exposure_at(cell: Vector2i) -> float:
	return exposure_for_temperature(local_temperature(cell))


## Same curve, applied to the open plain.
func freezing_severity() -> float:
	return exposure_for_temperature(_ambient)


func exposure_for_temperature(celsius: float) -> float:
	var safe: float = _profile.exposure_safe_c
	var lethal: float = _profile.exposure_lethal_c
	if celsius >= safe:
		return 0.0
	if celsius <= lethal:
		return 1.0
	return clampf((safe - celsius) / maxf(0.001, safe - lethal), 0.0, 1.0)


## What [P02] multiplies its per-tick heat losses by. 1.0 on a still, mild day;
## north of 4 in a late-campaign Great Frost.
func heat_loss_multiplier() -> float:
	var cold: float = maxf(0.0, _profile.heat_loss_cold_ref_c - _ambient) \
			/ maxf(1.0, _profile.heat_loss_cold_span_c)
	var m: float = 1.0 \
			+ _wind * _profile.heat_loss_wind_k \
			+ _storm_i * _profile.heat_loss_storm_k \
			+ cold
	return clampf(m, 1.0, _profile.heat_loss_max)


# ==========================================================================
#  PUBLIC API — WEATHER AND STORMS
# ==========================================================================

## &"clear", &"overcast", &"snowfall", &"blizzard" or &"great_frost".
func weather() -> StringName:
	if _storm_i > 0.05:
		return ClimateDefs.GREAT_FROST
	return ClimateDefs.weather_name(_weather_kind)


func weather_label() -> String:
	if _storm_i > 0.05:
		return _storm_title if _storm_title != "" else ClimateDefs.GREAT_FROST_LABEL
	return ClimateDefs.weather_label(_weather_kind)


## Intensity of the ordinary weather layer, 0..1.
func weather_intensity() -> float:
	return _weather_intensity


## 0..1. Drives heat loss, vfx drift and turret accuracy.
func wind() -> float:
	return _wind


## 0..1 from the weather alone. Combine with light_level() for what a player can see.
func visibility() -> float:
	return _visibility


## Settled snow, 0..1. Grid and vfx read it; it slows movement and buries roads.
func snow_depth() -> float:
	return _snow


## 0..1 envelope of the Great Frost currently blowing. 0 when there is none.
func storm_intensity() -> float:
	return _storm_i


func is_storm_active() -> bool:
	return _storm_active


func storm_title() -> String:
	return _storm_title


## The next scheduled Great Frost. Fixed by the tuning table, never random —
## the player can read it off the HUD from the first minute of the campaign.
## Keys: day, title, intensity, start_tick, seconds_until, duration_seconds.
func next_storm() -> Dictionary:
	var candidate: Dictionary = _profile.frost_for_day(_day)
	var found_day: int = _day
	if candidate.is_empty() or _storm_start_tick_for_day(_day) <= _clock_tick:
		candidate = _profile.next_frost_after(_day + 1)
		found_day = int(candidate.get("day", 0))
	if candidate.is_empty():
		return {}
	var start: int = _storm_start_tick_for_day(found_day)
	return {
		"day": found_day,
		"title": String(candidate.get("title", ClimateDefs.GREAT_FROST_LABEL)),
		"intensity": float(candidate.get("intensity", 1.0)),
		"start_tick": start,
		"seconds_until": float(maxi(0, start - _clock_tick)) * SimClock.DT,
		"duration_seconds": float(int(candidate.get("duration_ticks", 0))) * SimClock.DT,
	}


## Seconds until the next Great Frost opens. -1.0 if one is already blowing.
func seconds_until_storm() -> float:
	if _storm_active:
		return -1.0
	var n: Dictionary = next_storm()
	if n.is_empty():
		return -1.0
	return float(n.get("seconds_until", -1.0))


## Rolled weather for today and the days already planned, plus every scheduled
## Great Frost inside the window. What the forecast panel renders.
func forecast(days: int = 3) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for d: int in range(_day, _day + maxi(1, days)):
		var entry: Dictionary = {"day": d}
		var plan: ClimateDayPlan = _plans.get(d)
		if plan != null:
			entry["known"] = true
			entry["weather"] = String(ClimateDefs.weather_name(plan.dominant_kind()))
			entry["text"] = plan.forecast_text()
		else:
			entry["known"] = false
			entry["weather"] = "unknown"
			entry["text"] = "Beyond the forecast"
		var f: Dictionary = _profile.frost_for_day(d)
		entry["storm"] = not f.is_empty()
		entry["storm_title"] = String(f.get("title", ""))
		entry["storm_intensity"] = float(f.get("intensity", 0.0))
		entry["low_c"] = snappedf(_profile.base_temperature_for_day(float(d) + 0.95)
				+ _profile.solar_cold_c, 0.1)
		out.append(entry)
	return out


# ==========================================================================
#  PUBLIC API — CAMPAIGN PRESSURE
# ==========================================================================

## Stable key of the escalation beat currently in force, e.g. &"bone_winter".
func era_key() -> StringName:
	return StringName(_profile.escalation_key[_era_idx])


func era_title() -> String:
	return String(_profile.escalation_title[_era_idx])


func era_index() -> int:
	return _era_idx


## 0 at campaign start, 1.0 once the world is as bad as the curve says it gets.
func severity() -> float:
	return _profile.severity_for_day(_day)


## The live tuning table. Read-only for other parts.
func profile() -> ClimateProfile:
	return _profile


# ==========================================================================
#  COMMANDS (debug, tutorial, scenarios) — routed by Sim.submit_command
# ==========================================================================

## {"system":"climate","op":"skip_to_phase","phase":"night"}
## {"system":"climate","op":"set_day","day":7}
## {"system":"climate","op":"force_storm","intensity":0.9,"duration_ticks":3000}
func handle_command(cmd: Dictionary) -> void:
	var op: String = String(cmd.get("op", ""))
	match op:
		"skip_to_phase":
			var want: StringName = StringName(String(cmd.get("phase", "night")))
			var idx: int = ClimateDefs.PHASE_NAMES.find(want)
			if idx < 0:
				Log.warn(TAG, "skip_to_phase: unknown phase '%s'" % want)
				return
			var target: int = _profile.phase_starts[idx]
			var delta: int = target - _tick_in_day
			if delta <= 0:
				delta += _day_ticks
			_offset += delta
			_resync_after_jump()
			Log.info(TAG, "skipped to %s (day %d)" % [want, _day])
		"set_day":
			var want_day: int = maxi(1, int(cmd.get("day", 1)))
			_offset += (want_day - _day) * _day_ticks
			_resync_after_jump()
			Log.info(TAG, "jumped to day %d" % _day)
		"force_storm":
			var plan: ClimateDayPlan = _plans.get(_day)
			if plan == null:
				return
			plan.has_storm = true
			plan.storm_start_tick = _clock_tick
			plan.storm_peak = clampf(float(cmd.get("intensity", 1.0)), 0.0, 1.0)
			plan.storm_duration_ticks = maxi(60, int(cmd.get("duration_ticks", 2400)))
			var cap: int = maxi(1, int(float(plan.storm_duration_ticks) * 0.4))
			plan.storm_ramp_ticks = mini(_profile.frost_ramp_ticks, cap)
			plan.storm_fade_ticks = mini(_profile.frost_fade_ticks, cap)
			plan.storm_title = String(cmd.get("title", ClimateDefs.GREAT_FROST_LABEL))
			Log.info(TAG, "forced storm '%s' at %.2f" % [plan.storm_title, plan.storm_peak])
		_:
			Log.warn(TAG, "unknown command op '%s'" % op)


# ==========================================================================
#  SERIALIZATION
# ==========================================================================

func serialize() -> Dictionary:
	var plans: Array = []
	var days: Array[int] = _sorted_plan_days()
	for d: int in days:
		plans.append(_plans[d].to_dict())
	return {
		"day": _day,
		"phase": String(phase_of_day()),
		"ambient_temp": snappedf(_ambient, 0.01),
		"storm_intensity": snappedf(_storm_i, 0.001),
		"seconds_to_night": snappedf(seconds_until_night(), 0.05),
		"tick_in_day": _tick_in_day,
		"offset": _offset,
		"day_progress": snappedf(day_progress(), 0.0001),
		"sun": snappedf(_sun, 0.001),
		"solar_c": snappedf(_solar_c, 0.001),
		"weather_c": snappedf(_weather_c, 0.001),
		"weather": String(weather()),
		"weather_kind": String(ClimateDefs.weather_name(_weather_kind)),
		"weather_intensity": snappedf(_weather_intensity, 0.001),
		"wind": snappedf(_wind, 0.001),
		"visibility": snappedf(_visibility, 0.001),
		"snow": snappedf(_snow, 0.0001),
		"heat_loss_mult": snappedf(heat_loss_multiplier(), 0.001),
		"era": String(era_key()),
		"era_index": _era_idx,
		"storm_active": _storm_active,
		"storm_title": _storm_title,
		"storm_day": _storm_day,
		"next_storm": next_storm(),
		"plans": plans,
		"pending_warnings": _warnings.duplicate(true),
		"profile": String(_profile.id),
	}


func deserialize(data: Dictionary) -> void:
	_day = maxi(1, int(data.get("day", 1)))
	_tick_in_day = clampi(int(data.get("tick_in_day", 0)), 0, _day_ticks - 1)
	_offset = int(data.get("offset", 0))
	_clock_tick = (_day - 1) * _day_ticks + _tick_in_day
	_ambient = float(data.get("ambient_temp", -18.0))
	_solar_c = float(data.get("solar_c", 0.0))
	_weather_c = float(data.get("weather_c", 0.0))
	_snow = float(data.get("snow", 0.0))
	_storm_i = float(data.get("storm_intensity", 0.0))
	_storm_active = bool(data.get("storm_active", false))
	_storm_title = String(data.get("storm_title", ""))
	_storm_day = int(data.get("storm_day", 0))
	_era_idx = clampi(int(data.get("era_index", 0)), 0, _profile.escalation_key.size() - 1)
	_phase_idx = _phase_index_at(_tick_in_day)
	_sun = _profile.sun_at(day_progress())

	_plans.clear()
	for raw: Variant in data.get("plans", []):
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var plan: ClimateDayPlan = ClimateDayPlan.from_dict(raw, _day_ticks)
		_plans[plan.day] = plan
	_ensure_plan(_day)
	_ensure_plan(_day + 1)

	_warnings.clear()
	for raw: Variant in data.get("pending_warnings", []):
		if typeof(raw) == TYPE_DICTIONARY:
			_warnings.append(raw)


func metrics() -> Dictionary:
	return {
		"day": _day,
		"phase": String(phase_of_day()),
		"ambient_temp": snappedf(_ambient, 0.01),
		"storm_intensity": snappedf(_storm_i, 0.001),
		"seconds_to_night": snappedf(seconds_until_night(), 0.05),
		"light": snappedf(_sun, 0.001),
		"wind": snappedf(_wind, 0.001),
		"visibility": snappedf(_visibility, 0.001),
		"snow": snappedf(_snow, 0.0001),
		"heat_loss_mult": snappedf(heat_loss_multiplier(), 0.001),
		"weather": String(weather()),
	}


# ==========================================================================
#  INTERNALS — clock and phases
# ==========================================================================

func _phase_index_at(tick_in_day: int) -> int:
	var idx: int = 0
	for i: int in ClimateDefs.PHASE_COUNT:
		if tick_in_day >= _profile.phase_starts[i]:
			idx = i
		else:
			break
	return idx


func _emit_phase_change(next_phase: int) -> void:
	if next_phase == _phase_idx:
		return
	_phase_idx = next_phase
	match next_phase:
		ClimateDefs.Phase.DAWN:
			_alert(0, ClimateDefs.KEY_DAWN, "Dawn. The city made it through.")
		ClimateDefs.Phase.DUSK:
			_alert(1, ClimateDefs.KEY_DUSK, "Dusk. Night in %s."
					% ClimateDefs.format_clock(seconds_until_night()))
		ClimateDefs.Phase.NIGHT:
			Bus.night_started.emit(_day)
			_alert(1, ClimateDefs.KEY_NIGHT, "Night has fallen on day %d. %.0f°C outside."
					% [_day, _ambient])
		ClimateDefs.Phase.DEEP_NIGHT:
			_alert(0, ClimateDefs.KEY_NIGHT, "Deep night. Dawn in %s."
					% ClimateDefs.format_clock(seconds_until_dawn()))
		_:
			pass
	Log.debug(TAG, "phase -> %s (day %d, %.1f C)" % [phase_of_day(), _day, _ambient])


func _roll_to_day(new_day: int) -> void:
	_day = new_day
	_prune(new_day)
	_ensure_plan(new_day)
	_ensure_plan(new_day + 1)
	Bus.day_started.emit(new_day)
	_check_era()
	Log.info(TAG, "day %d — %s, forecast: %s" % [
		new_day, era_title(), _plans[new_day].forecast_text(),
	])
	_schedule_storm_warnings(_plans[new_day])
	_schedule_storm_warnings(_plans[new_day + 1])


## After a commanded jump the derived clock state has to be rebuilt from scratch.
func _resync_after_jump() -> void:
	_clock_tick = maxi(0, _sim_tick + _offset)
	@warning_ignore("integer_division")
	var d: int = _clock_tick / _day_ticks + 1
	_tick_in_day = _clock_tick % _day_ticks
	_warnings.clear()
	_warn_scheduled.clear()
	if d != _day:
		_roll_to_day(d)
	else:
		_ensure_plan(d)
		_ensure_plan(d + 1)
		_schedule_storm_warnings(_plans[d])
		_schedule_storm_warnings(_plans[d + 1])
	_phase_idx = _phase_index_at(_tick_in_day)
	_sun = _profile.sun_at(day_progress())
	_check_era()


func _check_era() -> void:
	var idx: int = _profile.era_index_for_day(_day)
	if idx == _era_idx:
		return
	_era_idx = idx
	var title: String = era_title()
	var line: String = String(_profile.escalation_line[idx])
	_alert(1, ClimateDefs.KEY_ERA, "%s — %s" % [title, line])
	Bus.narrative_event.emit(&"climate_era", {
		"key": String(era_key()),
		"title": title,
		"line": line,
		"day": _day,
		"base_c": snappedf(_profile.base_temperature_for_day(float(_day)), 0.1),
	})
	Log.info(TAG, "escalation beat: %s (day %d)" % [title, _day])


# ==========================================================================
#  INTERNALS — weather planning
# ==========================================================================

func _plan_for(abs_tick: int) -> ClimateDayPlan:
	@warning_ignore("integer_division")
	var d: int = maxi(0, abs_tick) / _day_ticks + 1
	var plan: ClimateDayPlan = _plans.get(d)
	if plan == null:
		plan = _ensure_plan(d)
	return plan


func _ensure_plan(d: int) -> ClimateDayPlan:
	var existing: ClimateDayPlan = _plans.get(d)
	if existing != null:
		return existing
	var plan: ClimateDayPlan = _roll_plan(d)
	_plans[d] = plan
	return plan


## Rolls one day of weather from Rng.stream("climate"). Called exactly once per
## day, in ascending day order, so the draw sequence is fixed by the seed alone.
func _roll_plan(d: int) -> ClimateDayPlan:
	var r: RandomNumberGenerator = Rng.stream(RNG_STREAM)
	var plan := ClimateDayPlan.new()
	plan.day = d
	plan.day_ticks = _day_ticks
	plan.start_tick = (d - 1) * _day_ticks

	var sev: float = _profile.severity_for_day(d)
	plan.archetype = _pick_archetype(r, sev)
	plan.gust_phase_a = r.randf() * TAU
	plan.gust_phase_b = r.randf() * TAU

	var count: int = r.randi_range(_profile.segments_min, _profile.segments_max)
	var cuts := PackedInt32Array([0])
	for i: int in range(1, count):
		cuts.append(r.randi_range(1, _day_ticks - 1))
	cuts.sort()

	var scale: float = (1.0 - _profile.segment_intensity_severity_k) \
			+ _profile.segment_intensity_severity_k * (0.5 + 0.5 * sev)
	var last_start: int = -1
	for i: int in cuts.size():
		if cuts[i] == last_start:
			continue
		last_start = cuts[i]
		plan.seg_start.append(cuts[i])
		plan.seg_kind.append(_pick_weather(r, plan.archetype))
		var raw: float = r.randf_range(_profile.segment_intensity_min, _profile.segment_intensity_max)
		plan.seg_intensity.append(clampf(raw * scale, 0.0, 1.0))

	var frost: Dictionary = _profile.frost_for_day(d)
	if not frost.is_empty():
		var rel: int = int(_profile.frost_start_progress * float(_day_ticks))
		plan.has_storm = true
		plan.storm_index = int(frost.get("index", -1))
		plan.storm_start_tick = plan.start_tick + rel
		plan.storm_duration_ticks = mini(int(frost.get("duration_ticks", 2400)), _day_ticks - rel)
		var envelope_cap: int = maxi(1, int(float(plan.storm_duration_ticks) * 0.4))
		plan.storm_ramp_ticks = mini(_profile.frost_ramp_ticks, envelope_cap)
		plan.storm_fade_ticks = mini(_profile.frost_fade_ticks, envelope_cap)
		plan.storm_peak = clampf(float(frost.get("intensity", 1.0)), 0.0, 1.0)
		plan.storm_title = String(frost.get("title", ClimateDefs.GREAT_FROST_LABEL))
	return plan


func _pick_archetype(r: RandomNumberGenerator, sev: float) -> int:
	var weights := PackedFloat32Array()
	var total: float = 0.0
	for i: int in ClimateDefs.ARCHETYPE_COUNT:
		var w: float = maxf(0.0, _profile.archetype_weight_base[i] + _profile.archetype_weight_slope[i] * sev)
		weights.append(w)
		total += w
	if total <= 0.0:
		return ClimateDefs.Archetype.CALM
	var roll: float = r.randf() * total
	var acc: float = 0.0
	for i: int in ClimateDefs.ARCHETYPE_COUNT:
		acc += weights[i]
		if roll < acc:
			return i
	return ClimateDefs.ARCHETYPE_COUNT - 1


func _pick_weather(r: RandomNumberGenerator, archetype: int) -> int:
	var base: int = archetype * ClimateDefs.WEATHER_COUNT
	var total: float = 0.0
	for i: int in ClimateDefs.WEATHER_COUNT:
		total += maxf(0.0, _profile.archetype_weather_weights[base + i])
	if total <= 0.0:
		return ClimateDefs.Weather.CLEAR
	var roll: float = r.randf() * total
	var acc: float = 0.0
	for i: int in ClimateDefs.WEATHER_COUNT:
		acc += maxf(0.0, _profile.archetype_weather_weights[base + i])
		if roll < acc:
			return i
	return ClimateDefs.WEATHER_COUNT - 1


func _prune(current_day: int) -> void:
	var days: Array[int] = _sorted_plan_days()
	for d: int in days:
		if d < current_day - 1:
			_plans.erase(d)
	var scheduled: Array = _warn_scheduled.keys()
	scheduled.sort()
	for d: int in scheduled:
		if d < current_day:
			_warn_scheduled.erase(d)


func _sorted_plan_days() -> Array[int]:
	var keys: Array = _plans.keys()
	keys.sort()
	var out: Array[int] = []
	for k: int in keys:
		out.append(k)
	return out


# ==========================================================================
#  INTERNALS — telegraphing
# ==========================================================================

## A Great Frost is never a surprise. Every one of them gets a warning ladder:
## a full day out, then four minutes, ninety seconds, thirty seconds.
func _schedule_storm_warnings(plan: ClimateDayPlan) -> void:
	if plan == null or not plan.has_storm:
		return
	if _warn_scheduled.get(plan.day, false):
		return
	_warn_scheduled[plan.day] = true
	var offsets: PackedInt32Array = _profile.warning_offsets_ticks
	for i: int in offsets.size():
		var at: int = plan.storm_start_tick - offsets[i]
		if at < _clock_tick:
			continue
		var line: String = ""
		if i < _profile.warning_lines.size():
			line = String(_profile.warning_lines[i])
		var lead: float = float(offsets[i]) * SimClock.DT
		var text: String
		if offsets[i] >= _day_ticks:
			text = "%s will reach the city tomorrow at dusk. %s" % [plan.storm_title, line]
		else:
			text = "%s in %s. %s" % [plan.storm_title, ClimateDefs.format_clock(lead), line]
		_warnings.append({
			"tick": at,
			"severity": 1 if i > 0 else 0,
			"key": String(ClimateDefs.KEY_STORM_WARNING),
			"text": text,
			"storm_day": plan.day,
			"storm_title": plan.storm_title,
			"storm_intensity": plan.storm_peak,
			"lead_seconds": lead,
			"step": i,
			"steps": offsets.size(),
		})
	var by_tick: Callable = func(a: Dictionary, b: Dictionary) -> bool: return int(a.get("tick", 0)) < int(b.get("tick", 0))
	_warnings.sort_custom(by_tick)
	Log.info(TAG, "Great Frost '%s' scheduled for day %d, %d warnings queued" % [
		plan.storm_title, plan.day, offsets.size(),
	])


func _flush_warnings() -> void:
	while not _warnings.is_empty():
		var w: Dictionary = _warnings[0]
		if int(w.get("tick", 0)) > _clock_tick:
			break
		_warnings.remove_at(0)
		_alert(int(w.get("severity", 1)), ClimateDefs.KEY_STORM_WARNING, String(w.get("text", "")))
		# Logged as well as raised, so the telegraph is legible in artifacts/log.txt.
		Log.info(TAG, "WARNING %d/%d — %s" % [
			int(w.get("step", 0)) + 1, int(w.get("steps", 0)), String(w.get("text", "")),
		])
		Bus.narrative_event.emit(ClimateDefs.KEY_STORM_WARNING, {
			"storm_day": int(w.get("storm_day", 0)),
			"title": String(w.get("storm_title", "")),
			"intensity": float(w.get("storm_intensity", 0.0)),
			"lead_seconds": float(w.get("lead_seconds", 0.0)),
			"step": int(w.get("step", 0)),
			"steps": int(w.get("steps", 0)),
			"text": String(w.get("text", "")),
		})


# ==========================================================================
#  INTERNALS — per-tick model
# ==========================================================================

func _update_storm() -> void:
	var intensity: float = 0.0
	var title: String = ""
	var source_day: int = 0
	for d: int in [_day - 1, _day]:
		var plan: ClimateDayPlan = _plans.get(d)
		if plan == null:
			continue
		var v: float = plan.storm_intensity_at(_clock_tick)
		if v > intensity:
			intensity = v
			title = plan.storm_title
			source_day = d
	_storm_i = intensity

	var now_active: bool = intensity > 0.02
	if now_active and not _storm_active:
		_storm_active = true
		_storm_title = title
		_storm_day = source_day
		_alert(1, ClimateDefs.KEY_STORM_BEGAN, "%s is on the city. Hold the heat." % title)
		Bus.narrative_event.emit(ClimateDefs.KEY_STORM_BEGAN, {
			"title": title, "day": source_day, "peak": _peak_for_day(source_day),
		})
		Log.info(TAG, "storm '%s' began (day %d)" % [title, source_day])
	elif not now_active and _storm_active:
		_storm_active = false
		_alert(0, ClimateDefs.KEY_STORM_ENDED,
				"%s has passed. The plain is quiet again." % _storm_title)
		Bus.narrative_event.emit(ClimateDefs.KEY_STORM_ENDED, {
			"title": _storm_title, "day": _storm_day,
		})
		Log.info(TAG, "storm '%s' ended" % _storm_title)
	elif now_active:
		_storm_title = title


func _peak_for_day(d: int) -> float:
	var plan: ClimateDayPlan = _plans.get(d)
	return plan.storm_peak if plan != null else 0.0


func _update_weather(next_phase: int) -> void:
	var plan: ClimateDayPlan = _plan_for(_clock_tick)
	var rel: int = _clock_tick - plan.start_tick
	var kind: int = plan.kind_at(rel)
	_weather_intensity = plan.intensity_at(rel)

	if kind != _weather_kind:
		if kind == ClimateDefs.Weather.BLIZZARD:
			_alert(1, ClimateDefs.KEY_BLIZZARD,
					"Whiteout blizzard. Visibility is gone; turrets will miss.")
		_weather_kind = kind

	var gust: float = 0.5 + 0.5 \
			* sin(float(_clock_tick) * 0.0131 + plan.gust_phase_a) \
			* sin(float(_clock_tick) * 0.0043 + plan.gust_phase_b)
	var base_wind: float = _profile.weather_wind[kind] * (0.5 + 0.5 * _weather_intensity)
	_wind = clampf(base_wind * (0.7 + 0.6 * gust) + _storm_i * _profile.storm_wind, 0.0, 1.0)

	var vis_weather: float = lerpf(1.0, _profile.weather_visibility[kind], _weather_intensity)
	_visibility = minf(vis_weather, lerpf(1.0, _profile.storm_visibility, _storm_i))

	var gain: float = 0.0
	if kind == ClimateDefs.Weather.SNOWFALL:
		gain = _profile.snow_gain_per_tick * _weather_intensity
	elif kind == ClimateDefs.Weather.BLIZZARD:
		gain = _profile.snow_gain_per_tick * _profile.snow_blizzard_mult * _weather_intensity
	gain += _profile.snow_gain_per_tick * _profile.snow_storm_mult * _storm_i
	if gain > 0.0:
		_snow = clampf(_snow + gain, 0.0, 1.0)
	elif _ambient > _profile.snow_melt_above_c and _sun > 0.4 \
			and next_phase < ClimateDefs.Phase.NIGHT:
		_snow = clampf(_snow - _profile.snow_melt_per_tick * _sun, 0.0, 1.0)


## Instantaneous degrees the weather layer is worth right now, before thermal lag.
## A clear night radiates warmth away; cloud traps it; a Great Frost tears it out.
func _weather_target(night: bool) -> float:
	var kind: int = _weather_kind
	var t: float = _profile.weather_temp_c[kind] * _weather_intensity
	if night:
		t += _profile.weather_night_c[kind]
	var bite: float = _profile.frost_bite_c \
			* (1.0 + _profile.frost_bite_era_scale * _profile.severity_for_day(_day))
	return t - bite * _storm_i


func _update_temperature(next_phase: int) -> void:
	var day_float: float = float(_day) + day_progress()
	var base: float = _profile.base_temperature_for_day(day_float)

	# Two lagged accumulators: the sun turns slowly, the weather bites fast.
	var solar_target: float = lerpf(_profile.solar_cold_c, _profile.solar_warm_c, _sun)
	_solar_c = lerpf(_solar_c, solar_target, _profile.solar_lag)
	_weather_c = lerpf(_weather_c, _weather_target(next_phase >= ClimateDefs.Phase.NIGHT),
			_profile.weather_lag)

	_ambient = base + _solar_c + _weather_c


# ==========================================================================
#  INTERNALS — heat integration
# ==========================================================================

## [P02] may push warmth with set_local_offset(), or expose
## `warmth_field() -> Dictionary[Vector2i, float]` and let climate pull it.
## Both paths work; the pull wins when it is available.
func _pull_local_from_heat() -> void:
	_refresh_heat_binding()
	var h: SimSystem = _heat_system()
	if h == null or not h.has_method(&"warmth_field"):
		return
	var raw: Variant = h.call(&"warmth_field")
	# [P02] hands back a WarmthField object; climate reads that per cell through
	# warmth_at() instead. Only a plain {Vector2i: float} is bulk-copied here.
	if typeof(raw) != TYPE_DICTIONARY:
		return
	var field: Dictionary = raw
	_local.clear()
	for k: Variant in field:
		if typeof(k) != TYPE_VECTOR2I:
			continue
		var cell: Vector2i = k
		_local[cell] = float(field[k])


## Heat may be created, replaced or absent; rebind whenever the instance changes.
func _refresh_heat_binding() -> void:
	var h: SimSystem = Sim.get_system(&"heat")
	if h == _heat_system():
		return
	_heat_ref = weakref(h) if h != null else null
	_heat_has_warmth_at = h != null and h.has_method(&"warmth_at")


func _heat_system() -> SimSystem:
	if _heat_ref == null:
		return null
	return _heat_ref.get_ref() as SimSystem


# ==========================================================================
#  INTERNALS — misc
# ==========================================================================

func _storm_start_tick_for_day(d: int) -> int:
	return (d - 1) * _day_ticks + int(_profile.frost_start_progress * float(_day_ticks))


## Severity is capped at 1 on purpose: the harness treats Bus severity >= 2 as a
## failed run, so climate never raises one. Urgency travels in narrative_event.
func _alert(severity_level: int, key: StringName, text: String) -> void:
	Bus.alert_raised.emit(clampi(severity_level, 0, ClimateDefs.MAX_BUS_SEVERITY), key, text, Vector2.ZERO)


func _load_profile() -> ClimateProfile:
	var chosen: ClimateProfile = null
	for res: Resource in Registry.all("biomes"):
		var cp := res as ClimateProfile
		if cp == null:
			continue
		if chosen == null or cp.priority > chosen.priority:
			chosen = cp
	var used: ClimateProfile = null
	if chosen == null:
		used = ClimateProfile.new()
		Log.info(TAG, "no ClimateProfile in game/content/biomes; using built-in defaults")
	else:
		used = chosen.duplicate(true) as ClimateProfile
		Log.info(TAG, "profile '%s' (%s)" % [used.id, used.display_name])
	if not used.validate():
		Log.warn(TAG, "profile '%s' had invalid fields and was repaired" % used.id)
	return used
