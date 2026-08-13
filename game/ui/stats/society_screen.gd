class_name LcnSocietyScreen
extends LcnStatsScreen
## Hope, discontent, population and the dead — annotated with what you did. [P20]
##
## Two charts and a margin of events. The top chart is what they believe: hope
## against discontent, on a fixed 0..1 axis so a glance at the gap between the
## two lines is a glance at whether the city is with you. The bottom chart is
## what is left of them: population against the running total of the dead.
##
## Every law you signed, every technology you finished, every wave and every
## storm is a labelled vertical across both. That is the whole idea — a curve
## that bends is a question, and the mark on it is the answer. A run read back
## this way is a story with causes in it, which is the difference between a save
## file and a campaign you talk about afterwards.

const LIST_W: float = 300.0
const GAP: float = 8.0

var _pop_plot: LcnGraphPlot = null
var _events: Array[Dictionary] = []
var _scroll: int = 0


func screen_title() -> String:
	return "Society"


func screen_subtitle() -> String:
	return "What they believe, how many of them are left, and what you did about it."


func _build() -> void:
	make_plot()
	plot.title = "Hope against discontent"
	# [P06] runs both meters 0..100 (SocietyDefs.METER_MAX). The axis is pinned
	# to that range rather than fitted to the data, so day four is comparable
	# with day one by eye — a chart that rescales itself is a chart you cannot
	# read two of.
	plot.forced_min = 0.0
	plot.forced_max = 100.0
	plot.zero_baseline = true
	plot.empty_note = "Nobody has had an opinion yet."

	_pop_plot = LcnGraphPlot.new()
	_pop_plot.setup(_theme())
	_pop_plot.title = "Population and the dead"
	_pop_plot.zero_baseline = true
	_pop_plot.empty_note = ""
	add_child(_pop_plot)


func _layout() -> void:
	if plot == null:
		return
	var w: float = maxf(240.0, size.x - LIST_W - GAP)
	var half: float = (size.y - GAP) * 0.55
	plot.position = Vector2.ZERO
	plot.size = Vector2(w, half)
	_pop_plot.position = Vector2(0.0, half + GAP)
	_pop_plot.size = Vector2(w, maxf(90.0, size.y - half - GAP))


func _refresh() -> void:
	var t: LcnStatTrack = track()
	var kinds: Array[int] = [LcnStatsJournal.Kind.LAW, LcnStatsJournal.Kind.RESEARCH,
		LcnStatsJournal.Kind.LOSS, LcnStatsJournal.Kind.END]
	plot.track = t
	plot.bands = bands_for(t)
	plot.marks = marks_for(t, kinds)
	if plot.entries.is_empty():
		plot.add_entry(&"hope", "Hope", LcnStatsDefs.colour_of(&"hope"),
			LcnGraphPlot.Mode.LEVEL, true)
		plot.add_entry(&"discontent", "Discontent", LcnStatsDefs.colour_of(&"discontent"),
			LcnGraphPlot.Mode.LEVEL, true)
	_pop_plot.track = t
	_pop_plot.bands = plot.bands
	_pop_plot.marks = marks_for(t, [LcnStatsJournal.Kind.WAVE, LcnStatsJournal.Kind.STORM])
	if _pop_plot.entries.is_empty():
		_pop_plot.add_entry(&"pop", "Population", LcnStatsDefs.colour_of(&"pop"),
			LcnGraphPlot.Mode.LEVEL, true)
		_pop_plot.add_entry(&"deaths", "Dead (total)", LcnStatsDefs.colour_of(&"deaths"))
		_pop_plot.add_entry(&"sick", "Sick", LcnStatsDefs.colour_of(&"sick"))
		_pop_plot.add_entry(&"homeless", "Homeless", LcnStatsDefs.colour_of(&"homeless"))
	plot.refresh()
	_pop_plot.refresh()

	if dirty("%s/%d/%d" % [String(window_id), 0 if t == null else t.latest_tick, _scroll]):
		_events = _read_events()
		queue_redraw()


## The margin list: everything that happened, newest first. The chart can only
## label what fits; this is the full record, and it is the thing a player scrolls
## back through when they want to know what they did on day two.
func _read_events() -> Array[Dictionary]:
	if journal == null:
		return []
	var all: Array[Dictionary] = journal.marks.duplicate()
	all.reverse()
	return all


func _draw() -> void:
	var t: LcnStatsTheme = _theme()
	clear_hot()
	var x0: float = plot.position.x + plot.size.x + GAP
	var w: float = maxf(120.0, size.x - x0)
	t.plate(self, Rect2(Vector2(x0, 0.0), Vector2(w, size.y)), t.PANEL, t.RIM_SOFT)
	var small: int = t.fs(t.FS_SMALL)
	var tiny: int = t.fs(t.FS_TINY)
	t.caps(self, Vector2(x0 + 10.0, 20.0), "The record", t.fs(t.FS_SMALL), t.TEXT_DIM)
	draw_line(Vector2(x0 + 8.0, 26.0), Vector2(x0 + w - 8.0, 26.0), t.RIM_SOFT, 1.0)

	if _events.is_empty():
		t.text(self, Vector2(x0 + 10.0, 48.0), "Nothing has happened yet.",
			small, t.TEXT_FAINT)
		return

	var y: float = 40.0
	var row_h: float = float(small) + float(tiny) + 9.0
	var shown: int = 0
	for i: int in range(_scroll, _events.size()):
		if y + row_h > size.y - 6.0:
			break
		var m: Dictionary = _events[i]
		var colour: Color = LcnStatsJournal.kind_colour(int(m["kind"]))
		if shown % 2 == 1:
			draw_rect(Rect2(Vector2(x0 + 4.0, y - float(small)),
				Vector2(w - 8.0, row_h - 2.0)), t.ROW_ODD, true)
		draw_rect(Rect2(Vector2(x0 + 8.0, y - float(small) + 2.0), Vector2(3.0, float(small))),
			colour, true)
		t.text(self, Vector2(x0 + 17.0, y), String(m["text"]), small, t.TEXT)
		t.text(self, Vector2(x0 + 17.0, y + float(tiny) + 4.0),
			"%s  ·  %s" % [LcnStatsJournal.kind_label(int(m["kind"])),
				LcnStatsTheme.ticks_as_clock(int(m["tick"]))], tiny, t.TEXT_FAINT)
		y += row_h
		shown += 1
	if _scroll + shown < _events.size():
		t.text_right(self, x0 + w - 8.0, size.y - 8.0,
			"%d earlier — scroll" % (_events.size() - _scroll - shown), tiny, t.TEXT_FAINT)


func _gui_input(event: InputEvent) -> void:
	var wheel := event as InputEventMouseButton
	if wheel != null and wheel.pressed:
		if wheel.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_scroll = clampi(_scroll + 2, 0, maxi(0, _events.size() - 1))
			invalidate()
			queue_redraw()
			accept_event()
			return
		if wheel.button_index == MOUSE_BUTTON_WHEEL_UP:
			_scroll = clampi(_scroll - 2, 0, maxi(0, _events.size() - 1))
			invalidate()
			queue_redraw()
			accept_event()
			return
	super._gui_input(event)
