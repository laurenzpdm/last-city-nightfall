class_name ClimateTestSuite
extends RefCounted
## Tests for [P09] Climate & Nightfall.
##
## Run headlessly:
##   godot --headless --path . res://tests/climate/climate_tests.tscn
## or from a shared runner:
##   var r: Dictionary = ClimateTestSuite.new().run()
##
## Autoloads are required (Sim, SimClock, Bus, Rng), so this cannot be driven
## with `--script` — Godot does not create autoloads for a bare MainLoop script.

var _passed: int = 0
var _failed: int = 0
var _failures: PackedStringArray = PackedStringArray()
var _current: String = ""


## Fake heat system used to prove the pull-based warmth hook works even when
## [P02] is written by another agent and only agrees on the method name.
class FakeHeat extends SimSystem:
	var field: Dictionary[Vector2i, float] = {}

	func system_name() -> StringName:
		return &"heat"

	func warmth_field() -> Dictionary:
		return field


func run() -> Dictionary:
	_passed = 0
	_failed = 0
	_failures = PackedStringArray()

	var cases: Array[Dictionary] = [
		{"name": "cycle_length_exact", "fn": _test_cycle_length_exact},
		{"name": "phase_arc_exact", "fn": _test_phase_arc_exact},
		{"name": "night_boundaries", "fn": _test_night_boundaries},
		{"name": "temperature_curve", "fn": _test_temperature_curve_within_a_day},
		{"name": "campaign_gets_colder", "fn": _test_campaign_gets_colder},
		{"name": "storm_schedule_is_fixed", "fn": _test_storm_schedule_is_fixed},
		{"name": "storm_envelope_shape", "fn": _test_storm_envelope_shape},
		{"name": "storm_is_telegraphed", "fn": _test_storm_is_telegraphed},
		{"name": "storm_actually_bites", "fn": _test_storm_actually_bites},
		{"name": "replay_determinism", "fn": _test_replay_determinism},
		{"name": "seeds_change_weather_not_storm_days", "fn": _test_seeds_change_weather_not_storm_days},
		{"name": "heat_hook", "fn": _test_heat_hook_push_and_pull},
		{"name": "fields_stay_in_bounds", "fn": _test_fields_stay_in_bounds},
		{"name": "serialize_metrics_roundtrip", "fn": _test_serialize_metrics_and_roundtrip},
		{"name": "commands", "fn": _test_commands},
	]

	var timings: Array[Dictionary] = []
	for case: Dictionary in cases:
		var before_fail: int = _failed
		var t0: int = Time.get_ticks_msec()
		var fn: Callable = case["fn"]
		fn.call()
		timings.append({
			"name": String(case["name"]),
			"ms": Time.get_ticks_msec() - t0,
			"failed": _failed - before_fail,
		})

	return {
		"name": "climate",
		"passed": _passed,
		"failed": _failed,
		"failures": _failures,
		"timings": timings,
	}


# ==========================================================================
#  TESTS
# ==========================================================================

## A day is exactly day_ticks long — not approximately, exactly. Everything the
## player plans around (night countdowns, wave timing, shift rotation) rests on this.
func _test_cycle_length_exact() -> void:
	_current = "cycle_length_exact"
	var c: ClimateSystem = _new_world(11)
	var dt: int = c.profile().day_ticks
	var counts: Dictionary = {"day": 0, "night": 0, "last_day": 0}
	var on_day: Callable = func(d: int) -> void:
		counts["day"] = int(counts["day"]) + 1
		counts["last_day"] = d
	var on_night: Callable = func(_d: int) -> void:
		counts["night"] = int(counts["night"]) + 1
	Bus.day_started.connect(on_day)
	Bus.night_started.connect(on_night)

	var open_at: int = c.opening_tick()
	_ok(c.day() == 1, "day starts at 1, got %d" % c.day())
	_ok(c.clock_tick() == open_at,
			"a run begins at the profile's opening tick %d, got %d" % [open_at, c.clock_tick()])
	_ok(is_equal_approx(c.day_progress(), float(open_at) / float(dt)),
			"progress starts at %.4f, got %.4f" % [float(open_at) / float(dt), c.day_progress()])
	_ok(c.phase_of_day() != &"night" and c.phase_of_day() != &"deep_night",
			"a new game does not open in the dark, got %s" % c.phase_of_day())

	_advance_to_clock(c, dt - 1)
	_ok(c.day() == 1, "still day 1 one tick before rollover, got %d" % c.day())
	_ok(c.phase_of_day() == &"deep_night", "last tick of the day is deep night, got %s" % c.phase_of_day())

	SimClock.advance(1)
	_ok(c.day() == 2, "day rolls to 2 at exactly %d ticks, got %d" % [dt, c.day()])
	_ok(is_equal_approx(c.day_progress(), 0.0), "progress resets to 0, got %f" % c.day_progress())
	_ok(c.phase_of_day() == &"dawn", "new day starts at dawn, got %s" % c.phase_of_day())

	SimClock.advance(dt * 3)
	_ok(c.day() == 5, "four full days elapsed -> day 5, got %d" % c.day())
	_ok(int(counts["day"]) == 4, "day_started fired 4 times, got %d" % int(counts["day"]))
	_ok(int(counts["night"]) == 4, "night_started fired 4 times, got %d" % int(counts["night"]))
	_ok(int(counts["last_day"]) == 5, "last day_started carried day 5, got %d" % int(counts["last_day"]))

	Bus.day_started.disconnect(on_day)
	Bus.night_started.disconnect(on_night)


## The day is an arc with six named beats, in order, each of an exact length.
func _test_phase_arc_exact() -> void:
	_current = "phase_arc_exact"
	var c: ClimateSystem = _new_world(3)
	var starts: PackedInt32Array = c.profile().phase_starts
	var dt: int = c.profile().day_ticks

	# Walked over a WHOLE day measured on the climate clock, starting from the
	# opening tick, so the six beats are still checked to the tick even though the
	# run no longer begins on the first one.
	var seen: Array[StringName] = [c.phase_of_day()]
	var first_tick: Dictionary = {String(c.phase_of_day()): c.clock_tick() % dt}
	for _i: int in dt - 1:
		SimClock.advance(1)
		var p: StringName = c.phase_of_day()
		if p != seen[seen.size() - 1]:
			seen.append(p)
			first_tick[String(p)] = c.clock_tick() % dt

	# The arc is the same six beats in the same order; the run simply joins it at
	# `morning`, so the sequence read from the opening tick is rotated by one.
	var expected: Array[StringName] = []
	var first_idx: int = ClimateDefs.PHASE_NAMES.find(seen[0])
	_ok(first_idx >= 0, "the opening phase is one of the six, got %s" % seen[0])
	for i: int in ClimateDefs.PHASE_COUNT:
		expected.append(ClimateDefs.PHASE_NAMES[(maxi(0, first_idx) + i) % ClimateDefs.PHASE_COUNT])
	_ok(seen.size() == expected.size(), "six phases in one day, got %d (%s)" % [seen.size(), str(seen)])
	for i: int in mini(seen.size(), expected.size()):
		_ok(seen[i] == expected[i], "phase %d is %s, got %s" % [i, expected[i], seen[i]])
	for i: int in ClimateDefs.PHASE_COUNT:
		var key: String = String(ClimateDefs.PHASE_NAMES[i])
		_ok(int(first_tick.get(key, -1)) == starts[i],
				"%s begins at tick %d, got %d" % [key, starts[i], int(first_tick.get(key, -1))])


## seconds_until_night() is the HUD's most important number. It has to be right
## to the tick, hit exactly zero at nightfall, and never go negative.
func _test_night_boundaries() -> void:
	_current = "night_boundaries"
	var c: ClimateSystem = _new_world(5)
	var p: ClimateProfile = c.profile()
	var night: int = p.night_start_tick()
	var dt: int = p.day_ticks

	var open_at: int = c.opening_tick()
	_ok(not c.is_night(), "the opening moment is not night")
	_ok(is_equal_approx(c.seconds_until_night(), float(night - open_at) * SimClock.DT),
			"countdown at the opening is %.2f s, got %.2f" % [
				float(night - open_at) * SimClock.DT, c.seconds_until_night()])
	_ok(c.seconds_until_night() > 120.0,
			"and a new run gets at least two minutes of daylight to read the city, got %.2f s"
					% c.seconds_until_night())
	_ok(is_equal_approx(c.daylight_seconds(), 316.8), "daylight is 316.8 s, got %.2f" % c.daylight_seconds())
	_ok(is_equal_approx(c.night_length_seconds(), 163.2), "night is 163.2 s, got %.2f" % c.night_length_seconds())

	_advance_to_clock(c, night - 1)
	_ok(not c.is_night(), "one tick before nightfall it is still day")
	_ok(is_equal_approx(c.seconds_until_night(), SimClock.DT),
			"countdown is one tick, got %.4f" % c.seconds_until_night())

	SimClock.advance(1)
	_ok(c.is_night(), "night at exactly tick %d" % night)
	_ok(is_equal_approx(c.seconds_until_night(), 0.0), "countdown clamps to 0 during night")
	_ok(is_equal_approx(c.seconds_until_dawn(), float(dt - night) * SimClock.DT),
			"dawn countdown starts full, got %.2f" % c.seconds_until_dawn())

	SimClock.advance(dt - night - 1)
	_ok(c.is_night(), "still night on the last tick of the day")
	_ok(is_equal_approx(c.seconds_until_dawn(), SimClock.DT),
			"dawn is one tick away, got %.4f" % c.seconds_until_dawn())

	# Monotonic all the way down, never negative.
	var c2: ClimateSystem = _new_world(6)
	var prev: float = c2.seconds_until_night()
	var monotone: bool = true
	for _i: int in night:
		SimClock.advance(1)
		var now: float = c2.seconds_until_night()
		if now > prev + 0.0001 or now < -0.0001:
			monotone = false
			break
		prev = now
	_ok(monotone, "countdown decreases monotonically and never goes negative")


## Temperature has a real diurnal arc with thermal inertia: warmest in the
## afternoon, coldest at the leading edge of dawn after a full night of loss.
func _test_temperature_curve_within_a_day() -> void:
	_current = "temperature_curve"
	var c: ClimateSystem = _new_world(21)
	var dt: int = c.profile().day_ticks

	var hi: float = -1e9
	var lo: float = 1e9
	var hi_phase: StringName = &""
	var lo_phase: StringName = &""
	for _i: int in dt:
		SimClock.advance(1)
		var t: float = c.ambient_temperature()
		if t > hi:
			hi = t
			hi_phase = c.phase_of_day()
		if t < lo:
			lo = t
			lo_phase = c.phase_of_day()

	_ok(hi_phase == &"afternoon" or hi_phase == &"dusk",
			"warmest moment is afternoon/dusk, got %s" % hi_phase)
	_ok(lo_phase == &"deep_night" or lo_phase == &"dawn",
			"coldest moment is deep night/dawn, got %s" % lo_phase)
	_ok(hi - lo >= 8.0, "diurnal swing is at least 8 C, got %.2f" % (hi - lo))
	_ok(hi < 0.0, "even the warmest hour of day 1 is below freezing, got %.2f" % hi)

	# The pure campaign curve, independent of weather rolls.
	var p: ClimateProfile = c.profile()
	var strictly_falling: bool = true
	var prev: float = p.base_temperature_for_day(1.0)
	for d: int in range(2, 61):
		var v: float = p.base_temperature_for_day(float(d))
		if v >= prev:
			strictly_falling = false
			break
		prev = v
	_ok(strictly_falling, "baseline temperature falls every single day for 60 days")
	_ok(p.base_temperature_for_day(60.0) < -90.0,
			"the late campaign is lethal cold, got %.1f" % p.base_temperature_for_day(60.0))


## Averaged over a whole day, week eight is dramatically colder than day one —
## weather noise cannot hide the campaign curve.
func _test_campaign_gets_colder() -> void:
	_current = "campaign_gets_colder"
	var c: ClimateSystem = _new_world(33)
	var dt: int = c.profile().day_ticks

	var mean_first: float = _mean_ambient_over_day(c, dt)
	SimClock.advance(dt * 6)
	_ok(c.day() == 8, "second sample starts on day 8, got %d" % c.day())
	_ok(c.era_key() == &"the_long_night",
			"day 8 crosses into the_long_night, got %s" % c.era_key())
	var mean_eighth: float = _mean_ambient_over_day(c, dt)

	_ok(mean_eighth < mean_first - 8.0,
			"day 8 mean %.1f C is >8 C below day 1 mean %.1f C" % [mean_eighth, mean_first])
	_ok(c.severity() > 0.2, "severity has climbed by day 9, got %.2f" % c.severity())


## Great Frost days are fixed by the tuning table, identical for every seed, and
## always open at the same moment of the day. The player can plan a whole
## campaign around them from minute one.
func _test_storm_schedule_is_fixed() -> void:
	_current = "storm_schedule_is_fixed"
	var c: ClimateSystem = _new_world(1234)
	var p: ClimateProfile = c.profile()
	var dt: int = p.day_ticks
	var rel: int = int(p.frost_start_progress * float(dt))

	var first: Dictionary = c.next_storm()
	_ok(int(first.get("day", 0)) == 3, "first Great Frost is day 3, got %d" % int(first.get("day", -1)))
	_ok(int(first.get("start_tick", 0)) == 2 * dt + rel,
			"opens at tick %d, got %d" % [2 * dt + rel, int(first.get("start_tick", -1))])
	_ok(String(first.get("title", "")) == "First Frost",
			"named 'First Frost', got '%s'" % String(first.get("title", "")))
	# Counted from where the run actually starts, not from midnight of day 1.
	var lead: float = float(2 * dt + rel - c.clock_tick()) * SimClock.DT
	_ok(is_equal_approx(float(first.get("seconds_until", 0.0)), lead),
			"lead time is %.1f s, got %.1f" % [lead, float(first.get("seconds_until", 0.0))])

	# Walk past the day-3 storm; the next one must be day 7.
	SimClock.advance(3 * dt)
	var second: Dictionary = c.next_storm()
	_ok(int(second.get("day", 0)) == 7, "second Great Frost is day 7, got %d" % int(second.get("day", -1)))
	_ok(int(second.get("start_tick", 0)) == 6 * dt + rel,
			"day 7 storm opens at %d, got %d" % [6 * dt + rel, int(second.get("start_tick", -1))])

	# The schedule is a pure function of the profile, not of the RNG.
	var days_a: Array[int] = _scheduled_storm_days(p, 60)
	var c2: ClimateSystem = _new_world(999999)
	var days_b: Array[int] = _scheduled_storm_days(c2.profile(), 60)
	_ok(days_a == days_b, "storm calendar identical across seeds: %s vs %s" % [str(days_a), str(days_b)])
	_ok(days_a.has(3) and days_a.has(7) and days_a.has(12) and days_a.has(18) and days_a.has(25),
			"scripted storms present in the calendar: %s" % str(days_a))
	_ok(days_a.size() >= 9, "the repeat rule keeps storms coming past day 33, got %d in 60 days" % days_a.size())


## The storm is an envelope, not a flag: it ramps in, holds, fades out, and is
## exactly zero outside its window.
func _test_storm_envelope_shape() -> void:
	_current = "storm_envelope_shape"
	var c: ClimateSystem = _new_world(77)
	var p: ClimateProfile = c.profile()
	var dt: int = p.day_ticks
	var open_at: int = 2 * dt + int(p.frost_start_progress * float(dt))

	_advance_to_clock(c, open_at - 1)
	_ok(is_equal_approx(c.storm_intensity(), 0.0), "no storm one tick before it opens, got %.3f" % c.storm_intensity())
	_ok(not c.is_storm_active(), "storm inactive before it opens")

	var peak: float = 0.0
	var peak_tick: int = 0
	var began: int = 0
	for _i: int in 3000:
		SimClock.advance(1)
		var v: float = c.storm_intensity()
		if v > 0.0 and began == 0:
			began = c.clock_tick()
		if v > peak:
			peak = v
			peak_tick = c.clock_tick()

	_ok(began >= open_at, "storm starts no earlier than scheduled (%d vs %d)" % [began, open_at])
	_ok(began <= open_at + 2, "storm starts on schedule, got %d vs %d" % [began, open_at])
	_ok(absf(peak - 0.50) < 0.02, "first frost peaks at its scripted 0.50 intensity, got %.3f" % peak)
	_ok(peak_tick > open_at + p.frost_ramp_ticks - 1, "peak is reached after the ramp, got %d" % peak_tick)
	_ok(is_equal_approx(c.storm_intensity(), 0.0),
			"storm has faded to exactly 0 by tick %d, got %.4f" % [c.clock_tick(), c.storm_intensity()])
	_ok(not c.is_storm_active(), "storm reported inactive after it passes")
	_ok(c.day() == 3, "the whole first frost fits inside day 3, got day %d" % c.day())


## Nothing in this game kills you without warning. The Great Frost ladder must
## fire every rung, in order, before the storm opens.
func _test_storm_is_telegraphed() -> void:
	_current = "storm_is_telegraphed"
	var c: ClimateSystem = _new_world(7)
	var p: ClimateProfile = c.profile()
	var dt: int = p.day_ticks
	var open_at: int = 2 * dt + int(p.frost_start_progress * float(dt))

	var warn_ticks: Array[int] = []
	var began_tick: Array[int] = []
	var narrative_steps: Array[int] = []
	var on_alert: Callable = func(_sev: int, key: StringName, _text: String, _pos: Vector2) -> void:
		if key == ClimateDefs.KEY_STORM_WARNING:
			warn_ticks.append(c.clock_tick())
		elif key == ClimateDefs.KEY_STORM_BEGAN:
			began_tick.append(c.clock_tick())
	var on_narrative: Callable = func(id: StringName, payload: Dictionary) -> void:
		if id == ClimateDefs.KEY_STORM_WARNING:
			narrative_steps.append(int(payload.get("step", -1)))
	Bus.alert_raised.connect(on_alert)
	Bus.narrative_event.connect(on_narrative)

	SimClock.advance(open_at + 400)

	Bus.alert_raised.disconnect(on_alert)
	Bus.narrative_event.disconnect(on_narrative)

	var offsets: PackedInt32Array = p.warning_offsets_ticks
	_ok(warn_ticks.size() == offsets.size(),
			"every rung of the warning ladder fired: expected %d, got %d" % [offsets.size(), warn_ticks.size()])
	for i: int in mini(warn_ticks.size(), offsets.size()):
		_ok(warn_ticks[i] == open_at - offsets[i],
				"warning %d at tick %d, got %d" % [i, open_at - offsets[i], warn_ticks[i]])
	_ok(warn_ticks.size() > 0 and warn_ticks[0] <= open_at - dt,
			"the first warning lands a full day before the storm")
	_ok(began_tick.size() == 1, "exactly one storm-began alert, got %d" % began_tick.size())
	_ok(began_tick.size() > 0 and began_tick[0] >= open_at,
			"the storm alert comes after every warning")
	_ok(narrative_steps == [0, 1, 2, 3], "narrative rungs are ordered 0..3, got %s" % str(narrative_steps))


## The storm has to actually hurt. Same seed, same weather rolls, storms removed
## from the calendar: the difference is the bite of the Great Frost alone.
func _test_storm_actually_bites() -> void:
	_current = "storm_actually_bites"
	var dt: int = 9600
	var sample_at: int = 2 * dt + 5900   # mid-plateau of the day-3 storm

	var with_storm: ClimateSystem = _new_world(4242)
	_advance_to_clock(with_storm, sample_at)
	var t_storm: float = with_storm.ambient_temperature()
	var i_storm: float = with_storm.storm_intensity()
	var w_storm: StringName = with_storm.weather()
	var kind_storm: String = String(with_storm.serialize().get("weather_kind", ""))
	var wi_storm: float = with_storm.weather_intensity()
	var loss_storm: float = with_storm.heat_loss_multiplier()
	var vis_storm: float = with_storm.visibility()

	var no_storm: ClimateSystem = _new_world(4242)
	# Removing storms consumes no RNG, so the weather rolls stay bit-identical.
	no_storm.profile().frost_day = PackedInt32Array()
	no_storm.profile().frost_repeat_every_days = 0
	_advance_to_clock(no_storm, sample_at)
	var t_calm: float = no_storm.ambient_temperature()
	var kind_calm: String = String(no_storm.serialize().get("weather_kind", ""))
	var wi_calm: float = no_storm.weather_intensity()
	var loss_calm: float = no_storm.heat_loss_multiplier()
	var vis_calm: float = no_storm.visibility()

	_ok(kind_storm == kind_calm and is_equal_approx(wi_storm, wi_calm),
			"control run has identical base weather (%s/%.3f vs %s/%.3f)" % [kind_storm, wi_storm, kind_calm, wi_calm])
	_ok(i_storm > 0.45, "storm is at plateau intensity for the sample, got %.3f" % i_storm)
	_ok(w_storm == ClimateDefs.GREAT_FROST, "weather reports great_frost during the storm, got %s" % w_storm)
	_ok(t_storm < t_calm - 9.0,
			"the Great Frost costs at least 9 C: %.2f vs %.2f (delta %.2f)" % [t_storm, t_calm, t_calm - t_storm])
	_ok(loss_storm > loss_calm + 0.4,
			"heat loss multiplier climbs in a storm: %.2f vs %.2f" % [loss_storm, loss_calm])
	_ok(vis_storm < vis_calm - 0.2,
			"visibility collapses in a storm: %.2f vs %.2f" % [vis_storm, vis_calm])


## Same seed in, byte-identical world out. Non-negotiable (ARCHITECTURE §3).
func _test_replay_determinism() -> void:
	_current = "replay_determinism"

	# Long window, climate only: 25000 ticks reaches past the day-3 Great Frost,
	# so storm scheduling and three days of weather rolls are inside the compare.
	var long_ticks: int = 25000
	_new_world(8675309)
	SimClock.advance(long_ticks)
	var a: String = JSON.stringify(Sim.serialize())

	_new_world(8675309)
	SimClock.advance(long_ticks)
	var b: String = JSON.stringify(Sim.serialize())
	_ok(a == b, "two runs of seed 8675309 for %d ticks produce identical state" % long_ticks)

	# Replaying in unequal chunks must not change anything either.
	_new_world(8675309)
	SimClock.advance(1)
	SimClock.advance(long_ticks - 4001)
	SimClock.advance(4000)
	_ok(a == JSON.stringify(Sim.serialize()), "chunked advance matches one long advance")

	# Shorter window with the WHOLE build ticking, so climate is proven
	# deterministic in the presence of every other system that exists today.
	var full_ticks: int = 2400
	_new_world(20260813, false)
	SimClock.advance(full_ticks)
	var fa: String = JSON.stringify(Sim.serialize())
	_new_world(20260813, false)
	SimClock.advance(full_ticks)
	var fb: String = JSON.stringify(Sim.serialize())
	_ok(fa == fb, "full-simulation replay of %d ticks is identical" % full_ticks)


## The weather is seeded; the dread calendar is not.
func _test_seeds_change_weather_not_storm_days() -> void:
	_current = "seeds_change_weather_not_storm_days"
	var fingerprints: Array[String] = []
	var storm_days: Array[String] = []
	for s: int in [1, 2, 3, 4, 5]:
		var c: ClimateSystem = _new_world(s)
		var state: Dictionary = c.serialize()
		fingerprints.append(JSON.stringify(state.get("plans", [])))
		storm_days.append(str(_scheduled_storm_days(c.profile(), 40)))

	var unique: Dictionary = {}
	for f: String in fingerprints:
		unique[f] = true
	_ok(unique.size() == fingerprints.size(),
			"five seeds give five different weeks of weather, got %d distinct" % unique.size())

	var same_calendar: bool = true
	for sd: String in storm_days:
		if sd != storm_days[0]:
			same_calendar = false
	_ok(same_calendar, "the storm calendar never varies by seed")


## [P02] can either push warmth in or expose warmth_field() and be pulled from.
func _test_heat_hook_push_and_pull() -> void:
	_current = "heat_hook"
	# Whole build live: [P02] is really there and really being asked for warmth.
	var c: ClimateSystem = _new_world(12, false)
	SimClock.advance(100)
	var ambient: float = c.ambient_temperature()
	var cell := Vector2i(4, -7)

	_ok(is_equal_approx(c.local_temperature(cell), ambient), "an unheated cell sits at ambient")
	c.set_local_offset(cell, 30.0)
	_ok(is_equal_approx(c.local_offset(cell), 30.0), "set_local_offset stores the offset")
	_ok(is_equal_approx(c.local_temperature(cell), ambient + 30.0),
			"local temperature is ambient + offset, got %.2f" % c.local_temperature(cell))
	c.add_local_offset(cell, 5.5)
	_ok(is_equal_approx(c.local_offset(cell), 35.5), "add_local_offset accumulates, got %.2f" % c.local_offset(cell))
	_ok(c.exposure_at(cell) < c.freezing_severity(),
			"a warmed cell is less lethal than the open plain (%.3f vs %.3f)" % [c.exposure_at(cell), c.freezing_severity()])
	_ok(c.warm_cell_count() == 1, "one warmed cell tracked, got %d" % c.warm_cell_count())

	var grid: Dictionary = c.local_offset_grid()
	grid[Vector2i(0, 0)] = 99.0
	_ok(c.warm_cell_count() == 1, "local_offset_grid() hands back a copy, not the live grid")

	c.clear_local_offsets()
	_ok(c.warm_cell_count() == 0, "clear_local_offsets empties the grid")
	_ok(is_equal_approx(c.local_temperature(cell), ambient), "cleared cell is back at ambient")

	# The real [P02] heat system exposes warmth_at(); with nothing built it must
	# radiate nothing, and must never clobber what was pushed in.
	var real_heat: SimSystem = Sim.get_system(&"heat")
	_ok(real_heat != null, "the real heat system is present for this integration test")
	c.set_local_offset(cell, 12.0)
	SimClock.advance(c.profile().heat_pull_interval_ticks * 2)
	_ok(is_equal_approx(c.local_offset(cell), 12.0),
			"pushed warmth survives alongside a live heat system, got %.2f" % c.local_offset(cell))
	c.clear_local_offsets()

	# Pull path: register a heat system that only agrees on the method name.
	var fake := FakeHeat.new()
	fake.field[Vector2i(2, 2)] = 18.0
	fake.field[Vector2i(3, 2)] = 6.0
	Sim.by_name[&"heat"] = fake
	SimClock.advance(c.profile().heat_pull_interval_ticks * 2)
	_ok(c.warm_cell_count() == 2, "climate pulled 2 cells from the heat system, got %d" % c.warm_cell_count())
	_ok(is_equal_approx(c.local_offset(Vector2i(2, 2)), 18.0),
			"pulled warmth value is correct, got %.2f" % c.local_offset(Vector2i(2, 2)))

	# Exposure curve endpoints.
	_ok(is_equal_approx(c.exposure_for_temperature(0.0), 0.0), "0 C is not exposure")
	_ok(is_equal_approx(c.exposure_for_temperature(-80.0), 1.0), "-80 C is full exposure")
	_ok(absf(c.exposure_for_temperature(-30.0) - 0.5) < 0.02,
			"halfway point of the exposure ramp, got %.3f" % c.exposure_for_temperature(-30.0))


## Nothing this system publishes may ever leave its declared range, for six
## straight days including two Great Frosts.
func _test_fields_stay_in_bounds() -> void:
	_current = "fields_stay_in_bounds"
	var c: ClimateSystem = _new_world(2026)
	var p: ClimateProfile = c.profile()
	var bad: PackedStringArray = PackedStringArray()
	var storm_seen: bool = false
	var blizzard_seen: bool = false
	var kinds: Dictionary = {}
	var coldest: float = 1e9

	for _i: int in p.day_ticks * 8:
		SimClock.advance(1)
		var t: float = c.ambient_temperature()
		coldest = minf(coldest, t)
		if not is_finite(t) or t > 10.0 or t < -200.0:
			bad.append("ambient %f at tick %d" % [t, SimClock.tick])
		if c.wind() < 0.0 or c.wind() > 1.0:
			bad.append("wind %f" % c.wind())
		if c.visibility() < 0.0 or c.visibility() > 1.0:
			bad.append("visibility %f" % c.visibility())
		if c.snow_depth() < 0.0 or c.snow_depth() > 1.0:
			bad.append("snow %f" % c.snow_depth())
		if c.storm_intensity() < 0.0 or c.storm_intensity() > 1.0:
			bad.append("storm %f" % c.storm_intensity())
		if c.heat_loss_multiplier() < 1.0 or c.heat_loss_multiplier() > p.heat_loss_max:
			bad.append("heat_loss %f" % c.heat_loss_multiplier())
		if c.day_progress() < 0.0 or c.day_progress() >= 1.0:
			bad.append("progress %f" % c.day_progress())
		if c.seconds_until_night() < 0.0:
			bad.append("countdown %f" % c.seconds_until_night())
		if c.light_level() < 0.0 or c.light_level() > 1.0:
			bad.append("light %f" % c.light_level())
		if c.storm_intensity() > 0.1:
			storm_seen = true
		kinds[String(c.weather())] = true
		if c.weather() == &"blizzard":
			blizzard_seen = true
		if bad.size() > 3:
			break

	_ok(bad.is_empty(), "every published field stayed in range: %s" % str(bad))
	_ok(c.day() == 9, "eight days advanced cleanly, got day %d" % c.day())
	_ok(storm_seen, "at least one Great Frost blew through the first eight days")
	_ok(blizzard_seen or kinds.has("snowfall"), "ordinary weather actually varies: %s" % str(kinds.keys()))
	_ok(coldest < -40.0, "the world got genuinely lethal within a week, coldest %.1f C" % coldest)
	_ok(c.snow_depth() > 0.0, "snow settled over the week, got %.3f" % c.snow_depth())


## Contract check: the keys the harness, the HUD and save/load depend on.
func _test_serialize_metrics_and_roundtrip() -> void:
	_current = "serialize_metrics_roundtrip"
	var c: ClimateSystem = _new_world(64)
	SimClock.advance(2 * 9600 + 6000)

	var s: Dictionary = c.serialize()
	for key: String in ["day", "phase", "ambient_temp", "storm_intensity", "seconds_to_night"]:
		_ok(s.has(key), "serialize() carries '%s'" % key)
	var m: Dictionary = c.metrics()
	for key: String in ["day", "phase", "ambient_temp", "storm_intensity", "seconds_to_night"]:
		_ok(m.has(key), "metrics() carries '%s'" % key)

	# Metrics land in a CSV; a comma in a value would corrupt the file.
	var comma_free: bool = true
	for key: String in m:
		if str(m[key]).contains(","):
			comma_free = false
	_ok(comma_free, "no metric value contains a comma")

	var json: String = JSON.stringify(s)
	_ok(json.length() > 0 and JSON.parse_string(json) != null, "serialize() output is JSON-safe")

	var fresh := ClimateSystem.new()
	fresh.setup()
	fresh.deserialize(s)
	_ok(fresh.day() == c.day(), "restored day %d, got %d" % [c.day(), fresh.day()])
	_ok(fresh.phase_of_day() == c.phase_of_day(),
			"restored phase %s, got %s" % [c.phase_of_day(), fresh.phase_of_day()])
	_ok(absf(fresh.ambient_temperature() - c.ambient_temperature()) < 0.02,
			"restored ambient %.2f, got %.2f" % [c.ambient_temperature(), fresh.ambient_temperature()])
	_ok(absf(fresh.seconds_until_night() - c.seconds_until_night()) < 0.06,
			"restored night countdown %.2f, got %.2f" % [c.seconds_until_night(), fresh.seconds_until_night()])


## Scenario and tutorial commands actually move the clock.
func _test_commands() -> void:
	_current = "commands"
	var c: ClimateSystem = _new_world(88)
	SimClock.advance(10)

	Sim.submit_command({"system": "climate", "op": "skip_to_phase", "phase": "night"})
	SimClock.advance(1)
	_ok(c.phase_of_day() == &"night", "skip_to_phase lands on night, got %s" % c.phase_of_day())
	_ok(c.is_night(), "is_night() agrees after the skip")

	Sim.submit_command({"system": "climate", "op": "set_day", "day": 13})
	SimClock.advance(1)
	_ok(c.day() == 13, "set_day jumps to day 13, got %d" % c.day())
	_ok(c.era_key() == &"bone_winter", "day 13 is bone_winter, got %s" % c.era_key())

	Sim.submit_command({"system": "climate", "op": "force_storm", "intensity": 0.9, "duration_ticks": 1200})
	SimClock.advance(600)
	_ok(c.storm_intensity() > 0.5, "forced storm ramps up, got %.2f" % c.storm_intensity())
	_ok(c.is_storm_active(), "forced storm reports active")
	SimClock.advance(900)
	_ok(is_equal_approx(c.storm_intensity(), 0.0), "forced storm ends on schedule, got %.3f" % c.storm_intensity())


# ==========================================================================
#  HELPERS
# ==========================================================================

## Fresh world. `isolate` silences every other part's step() so a climate unit
## test measures climate and not the rest of the build; the determinism and heat
## tests deliberately run with the whole simulation live.
## Advance until the CLIMATE clock reads `target`.
##
## A run begins at ClimateProfile.opening_tick, not at tick 0 of day 1, so
## SimClock.tick and the climate's own clock differ by that constant for the
## whole run. Every assertion below is about the climate's timeline — "the storm
## opens 5760 ticks into day 3" — so every walk to a moment goes through here.
## Advancing by a raw count from tick 0 was only ever correct while the offset
## was zero, and it is exactly what made 36 assertions here go red the moment a
## new game stopped opening in the dark.
func _advance_to_clock(c: ClimateSystem, target: int) -> void:
	var delta: int = target - c.clock_tick()
	if delta < 0:
		_ok(false, "cannot walk backwards to clock tick %d (now %d)" % [target, c.clock_tick()])
		return
	if delta > 0:
		SimClock.advance(delta)


func _new_world(seed_value: int, isolate: bool = true) -> ClimateSystem:
	SimClock.set_manual(true)
	Sim.create_world(seed_value)
	if isolate:
		for s: SimSystem in Sim.systems:
			if s.system_name() != &"climate":
				s.enabled = false
	var c: ClimateSystem = Sim.get_system(&"climate") as ClimateSystem
	if c == null:
		_ok(false, "climate system is registered in Sim")
	return c


func _mean_ambient_over_day(c: ClimateSystem, day_ticks: int) -> float:
	var total: float = 0.0
	for _i: int in day_ticks:
		SimClock.advance(1)
		total += c.ambient_temperature()
	return total / float(day_ticks)


func _scheduled_storm_days(p: ClimateProfile, horizon: int) -> Array[int]:
	var out: Array[int] = []
	for d: int in range(1, horizon + 1):
		if not p.frost_for_day(d).is_empty():
			out.append(d)
	return out


func _ok(condition: bool, message: String) -> void:
	if condition:
		_passed += 1
		return
	_failed += 1
	_failures.append("%s: %s" % [_current, message])
