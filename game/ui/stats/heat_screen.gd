class_name LcnHeatScreen
extends LcnStatsScreen
## Supply, demand and deficit over the day, with the nights shaded. [P20]
##
## This is the shape of your survival. Heat is the power grid, the morale system
## and the ammunition supply at once, so one chart of supply against demand,
## with every night painted behind it, answers more questions than any table
## can: whether you built enough before dusk, how deep the hole went, how long
## it took to climb out, and whether the accumulators you paid for actually
## carried anything.
##
## Below the chart, six read-outs that are the ones a player checks after a bad
## night: the worst deficit, how long the grid was short, the lowest the buffer
## fell, how many buildings froze, how much heat the turrets ate, and how much
## the pipes lost on the way.

const STRIP_H: float = 74.0
const PLOT_GAP: float = 8.0

var _buffer_plot: LcnGraphPlot = null
var _stats: Array[Dictionary] = []


func screen_title() -> String:
	return "Heat"


func screen_subtitle() -> String:
	return "What the grid promised, what it delivered, and where it broke."


func _build() -> void:
	make_plot()
	plot.title = "Supply against demand — heat per second"
	plot.zero_baseline = true
	plot.empty_note = "The grid has not been running long enough to chart."

	_buffer_plot = LcnGraphPlot.new()
	_buffer_plot.setup(_theme())
	_buffer_plot.title = "Buffer and pipe loss"
	_buffer_plot.zero_baseline = true
	_buffer_plot.empty_note = ""
	add_child(_buffer_plot)


func _layout() -> void:
	if plot == null:
		return
	var body_h: float = maxf(120.0, size.y - STRIP_H - PLOT_GAP)
	var main_h: float = body_h * 0.62
	plot.position = Vector2.ZERO
	plot.size = Vector2(size.x, main_h)
	_buffer_plot.position = Vector2(0.0, main_h + PLOT_GAP)
	_buffer_plot.size = Vector2(size.x, maxf(80.0, body_h - main_h - PLOT_GAP))


func _refresh() -> void:
	var t: LcnStatTrack = track()
	plot.track = t
	plot.bands = bands_for(t)
	plot.marks = marks_for(t, [LcnStatsJournal.Kind.STORM, LcnStatsJournal.Kind.WAVE])
	if plot.entries.is_empty():
		plot.add_entry(&"heat_supply", "Supply", LcnStatsDefs.colour_of(&"heat_supply"),
			LcnGraphPlot.Mode.LEVEL, true)
		plot.add_entry(&"heat_demand", "Demand", LcnStatsDefs.colour_of(&"heat_demand"))
		plot.add_entry(&"heat_deficit", "Deficit", LcnStatsDefs.colour_of(&"heat_deficit"),
			LcnGraphPlot.Mode.LEVEL, true)
	_buffer_plot.track = t
	_buffer_plot.bands = plot.bands
	if _buffer_plot.entries.is_empty():
		_buffer_plot.add_entry(&"heat_buffer", "Buffer",
			LcnStatsDefs.colour_of(&"heat_buffer"), LcnGraphPlot.Mode.LEVEL, true)
		_buffer_plot.add_entry(&"heat_loss", "Pipe loss",
			LcnStatsDefs.colour_of(&"heat_loss"))
		_buffer_plot.add_entry(&"heat_frozen", "Frozen buildings",
			LcnStatsDefs.colour_of(&"heat_frozen"))
	plot.refresh()
	_buffer_plot.refresh()

	if dirty("%s/%d" % [String(window_id), 0 if t == null else t.latest_tick]):
		_stats = _read_stats(t)
		queue_redraw()


## The six read-outs. Every one of them is a difference or an extreme over the
## visible window, so what the strip says and what the chart shows can never
## disagree.
func _read_stats(t: LcnStatTrack) -> Array[Dictionary]:
	if t == null or t.sample_count() < 2:
		return []
	var n: int = t.sample_count()
	var deficit: LcnStatSeries = t.series(&"heat_deficit")
	var buffer: LcnStatSeries = t.series(&"heat_buffer")
	var frozen: LcnStatSeries = t.series(&"heat_frozen")
	var loss: LcnStatSeries = t.series(&"heat_loss")
	var defence: LcnStatSeries = t.series(&"defence_heat")
	var supply: LcnStatSeries = t.series(&"heat_supply")
	var demand: LcnStatSeries = t.series(&"heat_demand")

	# INTERVALS, not samples. n samples span n-1 intervals, so counting samples
	# and multiplying by the stride reported "short for 7 min 40 s of 7 min 20 s
	# charted" — a number a player would rightly stop trusting the screen over.
	var short_intervals: int = 0
	if deficit != null:
		for i: int in range(1, n):
			if deficit.at(i) > 0.01:
				short_intervals += 1
	var window_s: float = t.window_seconds()
	var short_seconds: float = minf(float(short_intervals) * t.sample_seconds(), window_s)
	var margin: float = 0.0
	if supply != null and demand != null:
		margin = supply.last() - demand.last()

	var out: Array[Dictionary] = []
	out.append(_stat("MARGIN NOW", LcnStatsTheme.compact(margin),
		"heat/s spare" if margin >= 0.0 else "heat/s short",
		_theme().GOOD if margin >= 0.0 else _theme().BAD))
	out.append(_stat("WORST DEFICIT",
		LcnStatsTheme.compact(deficit.max_value() if deficit != null else 0.0),
		"heat/s at the worst moment",
		_theme().BAD if deficit != null and deficit.max_value() > 0.01 else _theme().TEXT_DIM))
	out.append(_stat("TIME SHORT", LcnStatsTheme.duration(short_seconds),
		"of %s charted" % LcnStatsTheme.duration(window_s),
		_theme().WARN if short_seconds > 1.0 else _theme().TEXT_DIM))
	var low: float = _buffer_low(buffer, n)
	out.append(_stat("BUFFER LOW", LcnStatsTheme.compact(low),
		"lowest the accumulators fell",
		_theme().WARN if low <= 0.01 else _theme().TEXT_DIM))
	out.append(_stat("FROZE",
		"%d" % int(frozen.max_value() if frozen != null else 0.0),
		"buildings at once",
		_theme().BAD if frozen != null and frozen.max_value() >= 1.0 else _theme().TEXT_DIM))
	var pipe: float = loss.last() if loss != null else 0.0
	var burn: float = 0.0
	if defence != null and defence.size() > 1:
		burn = (defence.last() - defence.first()) / maxf(1.0, t.window_seconds())
	out.append(_stat("SPENT ON", "%s / %s" % [
		LcnStatsTheme.compact(pipe), LcnStatsTheme.compact(burn)],
		"pipes / turrets, heat per second", _theme().TEXT_DIM))
	return out


## The lowest the buffer FELL, which is not the same as its minimum. Every run
## starts with empty accumulators, so a plain minimum reports zero forever and
## tells a player they ran dry on a night they never dipped below eighty per
## cent. The search starts at the first sample the buffer was actually charged.
func _buffer_low(buffer: LcnStatSeries, n: int) -> float:
	if buffer == null or n <= 0:
		return 0.0
	var from: int = -1
	for i: int in n:
		if buffer.at(i) > 0.01:
			from = i
			break
	if from < 0:
		return 0.0
	var low: float = buffer.at(from)
	for j: int in range(from, n):
		low = minf(low, buffer.at(j))
	return low


func _stat(label: String, value: String, note: String, colour: Color) -> Dictionary:
	return {"label": label, "value": value, "note": note, "colour": colour}


func _draw() -> void:
	var t: LcnStatsTheme = _theme()
	var y: float = size.y - STRIP_H
	t.plate(self, Rect2(Vector2(0.0, y), Vector2(size.x, STRIP_H)), t.PANEL, t.RIM_SOFT)
	if _stats.is_empty():
		t.text(self, Vector2(14.0, y + STRIP_H * 0.55), "No readings yet.",
			t.fs(t.FS_BODY), t.TEXT_FAINT)
		return
	var cell: float = size.x / float(_stats.size())
	for i: int in _stats.size():
		var s: Dictionary = _stats[i]
		var x: float = float(i) * cell + 14.0
		if i > 0:
			draw_line(Vector2(float(i) * cell, y + 10.0),
				Vector2(float(i) * cell, y + STRIP_H - 10.0), t.RIM_SOFT, 1.0)
		t.caps(self, Vector2(x, y + 20.0), String(s["label"]), t.fs(t.FS_TINY), t.TEXT_FAINT)
		t.text(self, Vector2(x, y + 45.0), String(s["value"]), t.fs(t.FS_HEAD + 3), s["colour"])
		t.text(self, Vector2(x, y + 63.0), String(s["note"]), t.fs(t.FS_TINY), t.TEXT_FAINT)
