extends TestCase
## [P20] The recording layer, without a world. Ring buffers, resolutions,
## formatting and the two pieces of judgement this part makes: which item is the
## bottleneck, and what nearly ended the night.
##
## Everything here is pure data, so it runs in-process in microseconds and it
## fails for exactly one reason when it fails.


func suite_name() -> String:
	return "stats_history"


# =============================================================== the ring ====

func test_series_keeps_the_newest_and_forgets_the_oldest() -> void:
	var s := LcnStatSeries.new(4)
	for i: int in 4:
		s.push(float(i))
	assert_eq(s.size(), 4, "the ring fills")
	assert_true(s.is_full(), "and knows it is full")
	assert_near(s.at(0), 0.0, 0.001, "index 0 is the oldest")
	assert_near(s.last(), 3.0, 0.001, "the last is the newest")
	s.push(4.0)
	assert_eq(s.size(), 4, "it never grows past its capacity")
	assert_near(s.at(0), 1.0, 0.001, "the oldest was evicted")
	assert_near(s.last(), 4.0, 0.001, "the newest is on the end")
	assert_near(s.span(), 3.0, 0.001, "span is newest minus oldest")


func test_series_reads_out_of_range_as_zero_instead_of_crashing() -> void:
	var s := LcnStatSeries.new(4)
	s.push(7.0)
	assert_near(s.at(-1), 0.0, 0.001, "before the beginning")
	assert_near(s.at(99), 0.0, 0.001, "past the end")
	assert_near(LcnStatSeries.new(4).last(), 0.0, 0.001, "an empty series has no last")


func test_a_counter_series_can_never_go_backwards() -> void:
	# A rate is a difference. If a counter dips, even by a float rounding, the
	# graph draws a negative production rate and the player is told the factory
	# un-made a plate.
	var s := LcnStatSeries.new(8, true)
	s.push(100.0)
	s.push(99.0)
	assert_near(s.last(), 100.0, 0.001, "a dip is clamped to the previous value")
	s.push(101.0)
	assert_near(s.last(), 101.0, 0.001, "a real increase still lands")


func test_nan_and_infinity_never_reach_the_chart() -> void:
	var s := LcnStatSeries.new(4)
	s.push(NAN)
	s.push(INF)
	assert_near(s.at(0), 0.0, 0.001, "NaN becomes zero")
	assert_near(s.at(1), 0.0, 0.001, "infinity becomes zero")


func test_halving_keeps_every_other_sample_starting_at_the_oldest() -> void:
	var s := LcnStatSeries.new(8)
	for i: int in 8:
		s.push(float(i))
	s.halve()
	assert_eq(s.size(), 4, "half the samples survive")
	assert_near(s.at(0), 0.0, 0.001, "index 0 is still the oldest moment")
	assert_near(s.at(1), 2.0, 0.001, "and the stride doubled")
	assert_near(s.at(3), 6.0, 0.001, "right up to the newest kept sample")
	s.push(9.0)
	assert_eq(s.size(), 5, "and it keeps recording afterwards")
	assert_near(s.last(), 9.0, 0.001, "onto the end")


func test_bounds_track_evictions() -> void:
	var s := LcnStatSeries.new(3)
	s.push(5.0)
	s.push(1.0)
	s.push(9.0)
	assert_near(s.min_value(), 1.0, 0.001, "min across the ring")
	assert_near(s.max_value(), 9.0, 0.001, "max across the ring")
	s.push(4.0)
	assert_near(s.max_value(), 9.0, 0.001, "still 9 after one eviction")
	s.push(4.0)
	assert_near(s.max_value(), 9.0, 0.001, "9 is still retained")
	s.push(4.0)
	assert_near(s.max_value(), 4.0, 0.001, "and gone once it has been evicted")


# ============================================================== the track ====

func test_a_track_aligns_every_series_on_the_same_tick() -> void:
	var t := LcnStatTrack.new(10, 8, false)
	t.declare(&"a")
	t.declare(&"b")
	t.push_sample(10, {&"a": 1.0, &"b": 2.0})
	t.push_sample(20, {&"a": 3.0})
	assert_eq(t.sample_count(), 2, "both samples landed")
	assert_near(t.series(&"b").last(), 2.0, 0.001,
		"a key missing from a sample holds its previous value rather than a hole")
	assert_eq(t.tick_at(0), 10, "sample 0 is the first tick pushed")
	assert_eq(t.tick_at(1), 20, "and the tick maths follows the stride")


func test_a_track_is_due_exactly_once_per_stride() -> void:
	var t := LcnStatTrack.new(10, 8, false)
	t.declare(&"a")
	assert_true(t.is_due(0), "a fresh track is due immediately")
	t.push_sample(0, {&"a": 1.0})
	assert_false(t.is_due(9), "not due before the stride has elapsed")
	assert_true(t.is_due(10), "due on the stride")


func test_a_fixed_track_evicts_and_its_oldest_tick_moves() -> void:
	var t := LcnStatTrack.new(10, 4, false)
	t.declare(&"a")
	for i: int in 6:
		t.push_sample(i * 10, {&"a": float(i)})
	assert_eq(t.sample_count(), 4, "it stays at capacity")
	assert_eq(t.tick_at(0), 20, "the window slid forward")
	assert_eq(t.latest_tick, 50, "and the newest is the last tick pushed")
	assert_eq(t.tick_at(t.sample_count() - 1), 50,
		"tick_at agrees with latest_tick at the right edge")


func test_a_growing_track_doubles_its_stride_instead_of_forgetting_the_start() -> void:
	# The whole-run claim: a ten-hour campaign costs the same memory as a
	# ten-minute one and the first hour is still on the chart.
	var t := LcnStatTrack.new(10, 4, true)
	t.declare(&"a", true)
	for i: int in 4:
		t.push_sample(i * 10, {&"a": float(i)})
	assert_eq(t.stride, 10, "the stride starts where it was built")
	t.push_sample(40, {&"a": 4.0})
	assert_eq(t.stride, 20, "the fifth sample doubles the stride")
	assert_eq(t.halvings, 1, "and it says so")
	assert_eq(t.tick_at(0), 0, "the beginning of the run is still index 0")
	assert_eq(t.sample_count(), 3, "half the samples plus the new one")
	assert_eq(t.tick_at(t.sample_count() - 1), 40,
		"and the derived tick of the newest sample is the tick it was pushed on")


func test_rate_per_minute_differences_a_counter() -> void:
	var t := LcnStatTrack.new(20, 16, false)   # one sample a second
	t.declare(&"made", true)
	for i: int in 11:
		t.push_sample(i * 20, {&"made": float(i) * 2.0})
	# 2 per sample, one sample a second, so 120 a minute.
	assert_near(t.rate_per_minute(&"made", 5), 120.0, 0.5,
		"a counter differenced over five seconds is 120 a minute")


func test_memory_stays_bounded() -> void:
	var t := LcnStatTrack.new(10, 240, false)
	for i: int in 60:
		t.declare(StringName("k%d" % i))
	for i2: int in 5000:
		t.push_sample(i2 * 10, {})
	assert_eq(t.sample_count(), 240, "five thousand pushes, two hundred and forty kept")
	assert_true(t.memory_bytes() < 80000,
		"sixty series at this resolution is under 80 KB (%d)" % t.memory_bytes())


# =============================================================== the defs ====

func test_every_declared_series_has_a_label_a_colour_and_an_explanation() -> void:
	var keys: Array[StringName] = LcnStatsDefs.ordered_keys()
	assert_true(keys.size() >= 25, "the table covers the whole simulation (%d)" % keys.size())
	for k: StringName in keys:
		assert_true(LcnStatsDefs.label_of(k) != "", "%s has a label" % k)
		assert_true(LcnStatsDefs.hint_of(k).length() > 20,
			"%s explains itself in a sentence" % k)
		assert_true(LcnStatsDefs.colour_of(k).a > 0.5, "%s has a visible colour" % k)


func test_counters_are_marked_as_counters() -> void:
	assert_eq(LcnStatsDefs.kind_of(&"kills"), LcnStatsDefs.Kind.COUNTER,
		"kills only ever go up")
	assert_eq(LcnStatsDefs.kind_of(&"hope"), LcnStatsDefs.Kind.LEVEL,
		"hope is a reading")
	assert_eq(LcnStatsDefs.kind_of(&"night"), LcnStatsDefs.Kind.FLAG,
		"night is a band")
	assert_eq(LcnStatsDefs.kind_of(LcnStatsDefs.produced_key(&"iron_plate")),
		LcnStatsDefs.Kind.COUNTER, "an item's production total is a counter")
	assert_eq(LcnStatsDefs.kind_of(LcnStatsDefs.stock_key(&"iron_plate")),
		LcnStatsDefs.Kind.LEVEL, "but what is in the yard is a level")


func test_item_keys_round_trip_and_read_as_english() -> void:
	assert_eq(String(LcnStatsDefs.item_of(LcnStatsDefs.produced_key(&"steel_plate"))),
		"steel_plate", "a produced key carries its item")
	assert_eq(String(LcnStatsDefs.item_of(LcnStatsDefs.consumed_key(&"steel_plate"))),
		"steel_plate", "and so does a consumed key")
	assert_eq(LcnStatsDefs.item_label(&"steel_plate"), "Steel Plate",
		"an id becomes a name without anyone authoring it twice")


func test_item_colours_are_stable_and_distinct() -> void:
	var items: Array[StringName] = [&"ammo_shell", &"circuit", &"coal", &"copper_coil",
		&"gear", &"grain", &"heat_core", &"insulation", &"iron_plate",
		&"pipe_segment", &"slag", &"steel_plate", &"stone", &"timber"]
	items.sort()
	LcnStatsDefs.assign_palette(items)
	var a: Color = LcnStatsDefs.item_colour(&"iron_plate")
	LcnStatsDefs.assign_palette(items)
	assert_true(a.is_equal_approx(LcnStatsDefs.item_colour(&"iron_plate")),
		"the same content produces the same legend, every run, forever")
	assert_true(LcnStatsDefs.item_colour(LcnStatsDefs.produced_key(&"iron_plate"))
		.is_equal_approx(a), "a prefixed key resolves to the same colour")

	# Every pair has to be separable at a glance on a dark plate. 0.16 in
	# straight RGB distance is roughly the point at which two lines in a legend
	# stop being tellable apart.
	for i: int in items.size():
		for j: int in range(i + 1, items.size()):
			var ci: Color = LcnStatsDefs.item_colour(items[i])
			var cj: Color = LcnStatsDefs.item_colour(items[j])
			var d: float = absf(ci.r - cj.r) + absf(ci.g - cj.g) + absf(ci.b - cj.b)
			assert_true(d > 0.16, "%s and %s are tellable apart (%.3f)" % [
				items[i], items[j], d])
	assert_true(LcnStatsDefs.item_colour(&"an_item_no_recipe_makes").a > 0.5,
		"and an item the graph does not know about still draws as something")


# ============================================================ formatting ====

func test_numbers_stay_human() -> void:
	assert_eq(LcnStatsTheme.compact(0.0), "0", "zero is zero")
	assert_eq(LcnStatsTheme.compact(0.42), "0.42", "under one keeps two decimals")
	assert_eq(LcnStatsTheme.compact(4.2), "4.2", "under ten keeps one")
	assert_eq(LcnStatsTheme.compact(420.0), "420", "hundreds are whole")
	assert_eq(LcnStatsTheme.compact(4200.0), "4.2 k", "thousands read as k")
	assert_eq(LcnStatsTheme.compact(4200000.0), "4.20 M", "millions read as M")
	assert_eq(LcnStatsTheme.compact(-4200.0), "-4.2 k", "and the sign survives")


func test_axis_steps_land_on_numbers_a_human_would_choose() -> void:
	for pair: Array in [[1.0, 0.25], [10.0, 2.5], [100.0, 25.0], [7.0, 2.0], [0.1, 0.025]]:
		var step: float = LcnStatsTheme.nice_step(float(pair[0]), 4)
		assert_near(step, float(pair[1]), float(pair[1]) * 0.01,
			"a span of %s steps by %s" % [pair[0], pair[1]])
	assert_near(LcnStatsTheme.nice_step(0.0, 4), 1.0, 0.001,
		"an empty span does not divide by zero")


func test_the_clock_reads_as_a_clock() -> void:
	assert_eq(LcnStatsTheme.ticks_as_clock(0), "0:00", "tick zero")
	assert_eq(LcnStatsTheme.ticks_as_clock(1200), "1:00", "twelve hundred ticks is a minute")
	assert_eq(LcnStatsTheme.ticks_as_clock(72000), "1:00:00", "and an hour rolls over")
	assert_eq(LcnStatsTheme.duration(38.0), "38 s", "a short stretch")
	assert_eq(LcnStatsTheme.duration(252.0), "4 min 12 s", "a long one")


# ========================================================= the bottleneck ====

func test_the_bottleneck_is_the_item_machines_are_stopped_on() -> void:
	# Iron plate has the worse ratio on paper. Copper coil is the one six
	# machines are actually standing still waiting for. The screen must name
	# copper, because that is the one that has stopped the factory.
	var rec := _fake_recorder([&"iron_plate", &"copper_coil"], {
		&"iron_plate": {"made": 60.0, "used": 200.0, "stock": 400.0},
		&"copper_coil": {"made": 30.0, "used": 34.0, "stock": 0.0},
	})
	var model := LcnProductionModel.new()
	model.bind(rec, _FakeProduction.new([
		{"reason": "missing_input", "item": "copper_coil"},
		{"reason": "missing_input", "item": "copper_coil"},
		{"reason": "missing_input", "item": "copper_coil"},
		{"reason": "missing_input", "item": "copper_coil"},
		{"reason": "missing_input", "item": "copper_coil"},
		{"reason": "missing_input", "item": "copper_coil"},
	]))
	model.refresh(LcnStatsRecorder.T_FINE, -1, true)
	assert_eq(String(model.bottleneck()), "copper_coil",
		"the item six machines are waiting for, not the one with the worst ratio")
	assert_true(model.headline().contains("6 machines"),
		"and the sentence counts them: '%s'" % model.headline())
	assert_true(model.headline().contains("Copper Coil"),
		"by name: '%s'" % model.headline())


func test_a_healthy_factory_is_told_it_is_healthy() -> void:
	var rec := _fake_recorder([&"iron_plate"], {
		&"iron_plate": {"made": 60.0, "used": 20.0, "stock": 900.0},
	})
	var model := LcnProductionModel.new()
	model.bind(rec, _FakeProduction.new([]))
	model.refresh(LcnStatsRecorder.T_FINE, -1, true)
	assert_eq(String(model.bottleneck()), "", "nothing is blamed")
	assert_true(model.headline().contains("Nothing is starved"),
		"and it says so out loud: '%s'" % model.headline())


func test_a_backed_up_line_is_named_as_backed_up_not_as_short() -> void:
	var rec := _fake_recorder([&"slag"], {
		&"slag": {"made": 40.0, "used": 0.0, "stock": 5000.0},
	})
	var model := LcnProductionModel.new()
	model.bind(rec, _FakeProduction.new([
		{"reason": "output_full", "item": "slag"},
		{"reason": "output_full", "item": "slag"},
	]))
	model.refresh(LcnStatsRecorder.T_FINE, -1, true)
	assert_eq(String(model.bottleneck()), "slag", "the jammed item is the problem")
	assert_true(model.headline().contains("backing up"),
		"worded as a jam, not a shortage: '%s'" % model.headline())


func test_the_table_sorts_by_every_column_and_ties_break_stably() -> void:
	var rec := _fake_recorder([&"a_item", &"b_item", &"c_item"], {
		&"a_item": {"made": 10.0, "used": 0.0, "stock": 1.0},
		&"b_item": {"made": 30.0, "used": 0.0, "stock": 2.0},
		&"c_item": {"made": 10.0, "used": 0.0, "stock": 3.0},
	})
	var model := LcnProductionModel.new()
	model.bind(rec, _FakeProduction.new([]))
	model.refresh(LcnStatsRecorder.T_FINE, -1, true)
	model.sort_by(&"made", false)
	assert_eq(String(model.rows()[0]["item"]), "b_item", "biggest maker first")
	assert_eq(String(model.rows()[1]["item"]), "a_item",
		"and a tie breaks on the id, so the table never shuffles between frames")
	model.sort_by(&"stock", true)
	assert_eq(String(model.rows()[0]["item"]), "a_item", "ascending by stock")


# ======================================================== the night report ===

func test_the_night_report_reads_the_window_it_was_given() -> void:
	var rec := LcnStatsRecorder.new()
	for track: LcnStatTrack in [rec.fine, rec.mid, rec.run]:
		for key: StringName in LcnStatsDefs.ordered_keys():
			track.declare(key, LcnStatsDefs.kind_of(key) == LcnStatsDefs.Kind.COUNTER)
	rec.items = [&"iron_plate"]
	for track2: LcnStatTrack in [rec.fine, rec.mid, rec.run]:
		track2.declare(LcnStatsDefs.produced_key(&"iron_plate"), true)
		track2.declare(LcnStatsDefs.consumed_key(&"iron_plate"), true)

	# 100 samples of the mid track: a night from sample 20 to sample 80.
	for i: int in 100:
		var night: bool = i >= 20 and i < 80
		rec.mid.push_sample(i * LcnStatsRecorder.MID_STRIDE, {
			&"night": 1.0 if night else 0.0,
			&"heat_deficit": 3.0 if (night and i < 50) else 0.0,
			&"heat_buffer": 40.0 - (30.0 if night else 0.0),
			&"heat_frozen": 2.0 if (night and i > 40 and i < 45) else 0.0,
			&"deaths": 0.0 if i < 60 else 3.0,
			&"kills": float(i),
			&"hope": 60.0 if not night else 15.0,
			&"discontent": 20.0,
			&"pop": 40.0,
			&"temperature": -20.0 - (15.0 if night else 0.0),
			LcnStatsDefs.produced_key(&"iron_plate"): float(i) * 4.0,
		})

	var journal := LcnStatsJournal.new()
	var band: Dictionary = {"night": 1,
		"from_tick": 20 * LcnStatsRecorder.MID_STRIDE,
		"to_tick": 80 * LcnStatsRecorder.MID_STRIDE}
	var report: Dictionary = LcnNightReport.build(rec, journal, band)

	assert_false(report.is_empty(), "a report was written")
	assert_eq(int(report["night"]), 1, "for the night it was asked about")
	var heat: Dictionary = report["heat"]
	assert_near(float(heat["worst_deficit"]), 3.0, 0.01, "the worst deficit of the night")
	assert_near(float(heat["peak_frozen"]), 2.0, 0.01, "and how many froze at once")
	assert_true(float(heat["deficit_seconds"]) > 100.0,
		"the grid was short for minutes, not seconds (%.0f)" % float(heat["deficit_seconds"]))
	var soc: Dictionary = report["society"]
	assert_near(float(soc["deaths"]), 3.0, 0.01, "three died inside the window")
	assert_near(float(soc["hope_low"]), 15.0, 0.01, "hope bottomed out at 15 of 100")
	var made: Array = report["produced"]
	assert_eq(made.size(), 1, "one item was produced")
	assert_near(float((made[0] as Dictionary)["amount"]), 240.0, 0.5,
		"and the amount is the difference across the night, not the lifetime total")


func test_the_verdict_and_the_closest_call_are_worded_from_the_worst_thing() -> void:
	var quiet: Dictionary = _report_with({"deaths": 0.0, "structures": 0.0,
		"frozen": 0.0, "deficit": 0.0, "hope_low": 80.0, "discontent_high": 10.0})
	assert_eq(String(quiet["verdict"]), "HELD CLEAN", "a clean night")
	assert_true(String(quiet["closest_call"]).contains("Nothing came close"),
		"and nothing to report: '%s'" % String(quiet["closest_call"]))

	var bad: Dictionary = _report_with({"deaths": 9.0, "structures": 1.0,
		"frozen": 4.0, "deficit": 90.0, "hope_low": 10.0, "discontent_high": 90.0})
	assert_eq(String(bad["verdict"]), "MAULED", "nine dead is a mauling")
	assert_true(String(bad["closest_call"]).contains("died"),
		"and the dead outrank every other complaint: '%s'" % String(bad["closest_call"]))

	var frozen: Dictionary = _report_with({"deaths": 0.0, "structures": 0.0,
		"frozen": 6.0, "deficit": 40.0, "hope_low": 60.0, "discontent_high": 20.0})
	assert_eq(String(frozen["verdict"]), "HELD, BARELY", "buildings froze")
	assert_true(String(frozen["closest_call"]).contains("below working temperature"),
		"the freeze is the story: '%s'" % String(frozen["closest_call"]))


# =============================================================== journal ====

func test_the_journal_clips_night_bands_to_the_window_it_is_asked_about() -> void:
	var j := LcnStatsJournal.new()
	j.nights.append({"night": 1, "from_tick": 100, "to_tick": 300})
	j.nights.append({"night": 2, "from_tick": 900, "to_tick": -1})
	var bands: Array[Dictionary] = j.night_bands(200, 1000)
	assert_eq(bands.size(), 2, "both nights overlap the window")
	assert_eq(int(bands[0]["from_tick"]), 200, "the first is clipped at the left edge")
	assert_eq(int(bands[1]["to_tick"]), 1000,
		"and a night still in progress runs to the right edge")
	assert_true(j.night_bands(400, 800).is_empty(), "a gap between nights is empty")


func test_the_journal_is_bounded() -> void:
	var j := LcnStatsJournal.new()
	for i: int in LcnStatsJournal.CAPACITY + 50:
		j.add(LcnStatsJournal.Kind.NOTE, "mark %d" % i, i)
	assert_eq(j.marks.size(), LcnStatsJournal.CAPACITY, "it never grows past its cap")
	assert_eq(String(j.marks[0]["text"]), "mark 50", "and it forgets from the front")


func test_marks_are_filtered_by_window_and_by_kind() -> void:
	var j := LcnStatsJournal.new()
	j.add(LcnStatsJournal.Kind.LAW, "Signed Corpse Pits", 100)
	j.add(LcnStatsJournal.Kind.WAVE, "Wave 2", 500)
	j.add(LcnStatsJournal.Kind.LAW, "Signed Child Labour", 900)
	assert_eq(j.between(0, 1000).size(), 3, "everything in the window")
	assert_eq(j.between(200, 1000).size(), 2, "clipped at the left")
	assert_eq(j.between(0, 1000, [LcnStatsJournal.Kind.LAW]).size(), 2,
		"and filtered by kind")


# =============================================================== fixtures ====

## A recorder with a hand-written history, so the models can be tested without
## a simulation. Values are per-minute rates turned into the counter totals the
## real recorder would have written.
func _fake_recorder(items: Array[StringName], values: Dictionary) -> LcnStatsRecorder:
	var rec := LcnStatsRecorder.new()
	rec.items = items
	for track: LcnStatTrack in [rec.fine, rec.mid, rec.run]:
		for item: StringName in items:
			track.declare(LcnStatsDefs.produced_key(item), true)
			track.declare(LcnStatsDefs.consumed_key(item), true)
			track.declare(LcnStatsDefs.stock_key(item), false)
	var samples: int = 121                       # sixty seconds of the fine track
	var per_sample: float = LcnStatsRecorder.FINE_STRIDE * 0.05 / 60.0
	for i: int in samples:
		var row: Dictionary = {}
		for item2: StringName in items:
			var v: Dictionary = values.get(item2, {})
			row[LcnStatsDefs.produced_key(item2)] = float(v.get("made", 0.0)) * per_sample * float(i)
			row[LcnStatsDefs.consumed_key(item2)] = float(v.get("used", 0.0)) * per_sample * float(i)
			row[LcnStatsDefs.stock_key(item2)] = float(v.get("stock", 0.0))
		rec.fine.push_sample(i * LcnStatsRecorder.FINE_STRIDE, row)
	return rec


func _report_with(spec: Dictionary) -> Dictionary:
	var rec := LcnStatsRecorder.new()
	for key: StringName in LcnStatsDefs.ordered_keys():
		rec.mid.declare(key, LcnStatsDefs.kind_of(key) == LcnStatsDefs.Kind.COUNTER)
	var deficit_samples: int = int(float(spec["deficit"]) / rec.mid.sample_seconds())
	for i: int in 40:
		rec.mid.push_sample(i * LcnStatsRecorder.MID_STRIDE, {
			&"deaths": 0.0 if i < 20 else float(spec["deaths"]),
			&"structures_lost": 0.0 if i < 20 else float(spec["structures"]),
			&"heat_frozen": float(spec["frozen"]) if i > 22 and i < 26 else 0.0,
			&"heat_deficit": 2.0 if i >= 10 and i < 10 + deficit_samples else 0.0,
			&"hope": float(spec["hope_low"]),
			&"discontent": float(spec["discontent_high"]),
			&"pop": 30.0,
		})
	return LcnNightReport.build(rec, LcnStatsJournal.new(),
		{"night": 1, "from_tick": 0, "to_tick": 39 * LcnStatsRecorder.MID_STRIDE})


## Stands in for [ProductionSystem]. The model only ever asks it one question.
class _FakeProduction extends RefCounted:
	var stalls: Array[Dictionary] = []

	func _init(rows: Array) -> void:
		for r: Variant in rows:
			stalls.append(r as Dictionary)

	func stalled_machines() -> Array[Dictionary]:
		return stalls
