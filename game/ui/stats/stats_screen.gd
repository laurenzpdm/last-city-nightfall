class_name LcnStatsScreen
extends Control
## Base class for the four statistics screens. [P20]
##
## Each screen owns one [LcnGraphPlot] and whatever table sits beside it. The
## base holds the three things they all share: the theme, the bound models, and
## the contract that a screen repaints only when its own signature changes.
##
## `refresh()` is called on a slow timer by [LcnStats]. It must be cheap enough
## to call at 6 Hz with an open screen over a settled city, so anything that
## walks the world belongs in the recorder, not here.

const HOT_NONE: int = -1

var theme_ref: LcnStatsTheme = null
var recorder: LcnStatsRecorder = null
var journal: LcnStatsJournal = null
var plot: LcnGraphPlot = null

## Which recorded track this screen is reading: fine / mid / run.
var window_id: StringName = LcnStatsRecorder.T_MID

## Regions a mouse can act on: {rect, id, arg}
var hot: Array[Dictionary] = []
var hot_index: int = HOT_NONE

var _sig: String = ""


func setup(t: LcnStatsTheme, rec: LcnStatsRecorder, log_ref: LcnStatsJournal) -> void:
	theme_ref = t
	recorder = rec
	journal = log_ref
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()


## Screens create their children here. The base creates nothing.
func _build() -> void:
	pass


## Human name for the tab bar.
func screen_title() -> String:
	return "Screen"


## One line under the title: what this screen is for.
func screen_subtitle() -> String:
	return ""


## Called on the refresh timer while visible. Screens override `_refresh`.
func refresh() -> void:
	if recorder == null:
		return
	_refresh()


func _refresh() -> void:
	pass


func set_window(id: StringName) -> void:
	if window_id == id:
		return
	window_id = id
	_sig = ""
	refresh()
	queue_redraw()


func track() -> LcnStatTrack:
	return null if recorder == null else recorder.track(window_id)


## True when the caller should rebuild: the data or the layout moved.
func dirty(signature: String) -> bool:
	if signature == _sig:
		return false
	_sig = signature
	return true


func invalidate() -> void:
	_sig = ""


## The night bands and annotation marks that belong under the current window.
func bands_for(t: LcnStatTrack) -> Array[Dictionary]:
	if journal == null or t == null or t.sample_count() < 2:
		return []
	return journal.night_bands(t.tick_at(0), t.latest_tick)


func marks_for(t: LcnStatTrack, kinds: Array[int]) -> Array[Dictionary]:
	if journal == null or t == null or t.sample_count() < 2:
		return []
	return journal.between(t.tick_at(0), t.latest_tick, kinds)


func _theme() -> LcnStatsTheme:
	if theme_ref == null:
		theme_ref = LcnStatsTheme.new()
	return theme_ref


# ------------------------------------------------------------------ hot bar --

func clear_hot() -> void:
	hot.clear()


func add_hot(rect: Rect2, id: StringName, arg: Variant = null) -> void:
	hot.append({"rect": rect, "id": id, "arg": arg})


func hot_at(pos: Vector2) -> int:
	for i: int in hot.size():
		if (hot[i]["rect"] as Rect2).has_point(pos):
			return i
	return HOT_NONE


func _gui_input(event: InputEvent) -> void:
	var motion := event as InputEventMouseMotion
	if motion != null:
		var i: int = hot_at(motion.position)
		if i != hot_index:
			hot_index = i
			queue_redraw()
		return
	var click := event as InputEventMouseButton
	if click != null and click.pressed and click.button_index == MOUSE_BUTTON_LEFT:
		var i2: int = hot_at(click.position)
		if i2 != HOT_NONE:
			activate(i2)
			accept_event()


## Fires a hot region. Screens override.
func activate(_index: int) -> void:
	pass


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		invalidate()
		_layout()
		queue_redraw()
	elif what == NOTIFICATION_MOUSE_EXIT and hot_index != HOT_NONE:
		hot_index = HOT_NONE
		queue_redraw()


## Screens place their children here.
func _layout() -> void:
	pass


## Builds the standard plot child. Screens call this from `_build`.
func make_plot() -> LcnGraphPlot:
	plot = LcnGraphPlot.new()
	plot.setup(_theme())
	add_child(plot)
	return plot
