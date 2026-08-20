class_name LcnStats
extends CanvasLayer
## [P20] Statistics and production graphs. The screen you read the run off.
##
## One node owns the whole part:
##
## [codeblock]
##   var stats := LcnStats.new()
##   add_child(stats)          # that is the whole installation
##   stats.set_open(true)      # optional; P or G does it for the player
## [/codeblock]
##
## What it contains:
##   * [LcnStatsRecorder] — three ring-buffered resolutions of every meaningful
##     quantity, sampled off `Bus.tick_advanced`, measured under 0.2 ms a tick;
##   * [LcnStatsJournal] — every law, technology, wave and storm, pinned to the
##     tick, so a bend in a curve has a cause written next to it;
##   * four screens — production, heat, society and the after-action report.
##
## LAYER 76. Above [P18]'s build menu (74) and below the modal band (80) that
## `LcnLayers` reserves for the tutorial and the pause menu. A full-screen report
## has to cover the palette; it must not cover a tutorial gate telling the player
## what to do next.
##
## HOTKEYS. `P` and `G` both open it — P because thirty thousand hours of
## Factorio have taught the audience that P is production statistics, G because
## `LcnLayers` does not reserve it and a player who has rebound P still has a way
## in. Tab walks the screens, `,` and `.` widen and narrow the window, Escape
## closes. Nothing is consumed unless the screen is actually open, so a closed
## statistics screen is invisible to the keyboard.
##
## It never pauses the clock and never writes to the simulation. Everything it
## shows came out of a running world through a read-only accessor.

const GROUP: StringName = &"lcn_stats"
## Above [P18] (74), below the modal band `LcnLayers` reserves at 80.
const LAYER: int = 76
const REFRESH_HZ: float = 6.0
const MARGIN: float = 34.0
const HEADER_H: float = 62.0
const FOOTER_H: float = 24.0

const TAB_PRODUCTION: int = 0
const TAB_HEAT: int = 1
const TAB_SOCIETY: int = 2
const TAB_NIGHT: int = 3

## Window buttons, widest last, mapped to the recorder's three tracks.
const WINDOWS: Array[Dictionary] = [
	{"id": &"fine", "label": "MINUTE"},
	{"id": &"mid", "label": "HOUR"},
	{"id": &"run", "label": "WHOLE RUN"},
]

signal opened()
signal closed()
signal tab_changed(tab: int)

var theme_ref: LcnStatsTheme = null
var recorder: LcnStatsRecorder = null
var journal: LcnStatsJournal = null

var screens: Array[LcnStatsScreen] = []
var tab: int = TAB_PRODUCTION
var window_id: StringName = LcnStatsRecorder.T_MID
var is_open: bool = false
## Set false to stop the report raising itself at dawn.
var auto_report: bool = true
## Microseconds the last refresh took. The perf claim, measured.
var last_refresh_usec: int = 0

var _chrome: Control = null
var _body: Control = null
var _accum: float = 0.0
var _hot: Array[Dictionary] = []
var _hot_index: int = -1
var _last_size: Vector2 = Vector2.ZERO
var _pending_night: Dictionary = {}


func _init() -> void:
	# The name `LcnLayers.SLOTS` matches on. The integrator's table enforces the
	# canvas layer by NODE NAME, so renaming this node silently opts the whole
	# part out of the one check that stops a screen drawing under the HUD.
	name = "LcnStatsRoot"
	layer = LAYER


func _ready() -> void:
	# Two installers reach for this part — `boot._install_pending()` and this
	# part's own `.tres` bootstrap — precisely so that neither being absent can
	# leave it unreachable. Whichever loses the race stands down here rather than
	# quietly recording the same world twice into two histories.
	if not get_tree().get_nodes_in_group(GROUP).is_empty():
		Log.info("ui.stats", "a statistics screen is already installed; standing down")
		queue_free()
		return
	add_to_group(GROUP)
	process_mode = Node.PROCESS_MODE_ALWAYS
	theme_ref = LcnStatsTheme.new()
	recorder = LcnStatsRecorder.new()
	journal = LcnStatsJournal.new()
	journal.listen()

	_chrome = Control.new()
	_chrome.name = "Chrome"
	# Sized by hand in `_relayout`, NOT anchored: the layer carries the user's
	# ui_scale, so the logical rectangle is the viewport divided by that scale
	# and an anchor preset would fight it every frame.
	_chrome.mouse_filter = Control.MOUSE_FILTER_STOP
	_chrome.draw.connect(_draw_chrome)
	_chrome.gui_input.connect(_on_chrome_input)
	add_child(_chrome)

	_body = Control.new()
	_body.name = "Body"
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_chrome.add_child(_body)

	_add_screen(LcnProductionScreen.new())
	_add_screen(LcnHeatScreen.new())
	_add_screen(LcnSocietyScreen.new())
	_add_screen(LcnNightScreen.new())

	Bus.tick_advanced.connect(_on_tick)
	Bus.world_ready.connect(_on_world_ready)
	Bus.day_started.connect(_on_day_started)
	if Sim.alive:
		_on_world_ready()

	visible = false
	_relayout()
	Log.info("ui.stats", "installed on layer %d — P or G opens it, %d screens, %s"
		% [LAYER, screens.size(), _memory_note()])


func _exit_tree() -> void:
	if journal != null:
		journal.stop()


# ==================================================================  public ==

## Opens or closes the screen. The clock keeps running either way.
func set_open(on: bool) -> void:
	if is_open == on:
		return
	is_open = on
	visible = on
	if on:
		_relayout()
		_refresh(true)
		opened.emit()
	else:
		closed.emit()


func toggle() -> void:
	set_open(not is_open)


## Opens on a named screen. Used by the tutorial, the alert row and the rig.
func show_tab(new_tab: int) -> void:
	set_tab(new_tab)
	set_open(true)


func set_tab(new_tab: int) -> void:
	var t: int = clampi(new_tab, 0, maxi(0, screens.size() - 1))
	if t == tab and screens[t].visible:
		return
	tab = t
	for i: int in screens.size():
		screens[i].visible = i == tab
	screens[tab].invalidate()
	_refresh(true)
	_chrome.queue_redraw()
	tab_changed.emit(tab)


func set_window(id: StringName) -> void:
	window_id = id
	for s: LcnStatsScreen in screens:
		s.set_window(id)
	_chrome.queue_redraw()


func screen(index: int) -> LcnStatsScreen:
	if index < 0 or index >= screens.size():
		return null
	return screens[index]


func night_screen() -> LcnNightScreen:
	return screens[TAB_NIGHT] as LcnNightScreen


## Reports written so far, newest last. The harness and the tests read this.
func reports() -> Array[Dictionary]:
	return night_screen().reports


# ==================================================================  drive ===

func _on_tick(tick: int) -> void:
	recorder.on_tick(tick)


func _on_world_ready() -> void:
	journal.clear()
	recorder.bind()
	night_screen().reports.clear()
	for s: LcnStatsScreen in screens:
		s.invalidate()
	Log.info("ui.stats", "recording %d item series across %d tracks (%s)" % [
		recorder.items.size(), 3, _memory_note()])


## Dawn. The journal has just closed a night, so the report can be written.
func _on_day_started(_day: int) -> void:
	# One frame of slack: `day_started` and the journal's own handler race, and
	# the report needs the closed band, not the open one.
	_write_report.call_deferred()


func _write_report() -> void:
	if journal.nights.is_empty():
		return
	var last: Dictionary = journal.nights[journal.nights.size() - 1]
	if int(last.get("to_tick", -1)) < 0:
		return
	var report: Dictionary = LcnNightReport.build(recorder, journal, last)
	if report.is_empty():
		return
	var panel: LcnNightScreen = night_screen()
	# The live report for this night is already the last entry; replace it.
	if not panel.reports.is_empty() and int((panel.reports[panel.reports.size() - 1]
			as Dictionary).get("from_tick", -1)) == int(report["from_tick"]):
		panel.reports[panel.reports.size() - 1] = report
	else:
		panel.capture(report)
	panel.index = -1
	panel.invalidate()
	Log.info("ui.stats", "night %d: %s — %s" % [
		int(report["night"]), String(report["verdict"]), String(report["headline"])])
	if auto_report and not Harness.active:
		show_tab(TAB_NIGHT)


func _process(delta: float) -> void:
	if not is_open:
		return
	if _last_size != _viewport_size():
		_relayout()
	_accum += delta
	if _accum < 1.0 / REFRESH_HZ:
		return
	_accum = 0.0
	_refresh(false)


func _refresh(force: bool) -> void:
	var t0: int = Time.get_ticks_usec()
	var s: LcnStatsScreen = screens[tab]
	if force:
		s.invalidate()
	s.refresh()
	last_refresh_usec = Time.get_ticks_usec() - t0


# ==================================================================  layout ==

func _add_screen(s: LcnStatsScreen) -> void:
	s.setup(theme_ref, recorder, journal)
	s.set_window(window_id)
	s.visible = screens.is_empty()
	_body.add_child(s)
	screens.append(s)


func _viewport_size() -> Vector2:
	var vp: Viewport = get_viewport()
	if vp == null:
		return Vector2(1920.0, 1080.0)
	return vp.get_visible_rect().size


func _relayout() -> void:
	var scale_f: float = clampf(float(Settings.get_value("graphics", "ui_scale", 1.0)), 0.6, 2.0)
	scale = Vector2(scale_f, scale_f)
	var vp: Vector2 = _viewport_size()
	_last_size = vp
	var logical: Vector2 = vp / maxf(0.01, scale_f)
	_chrome.size = logical
	var frame: Rect2 = _frame_rect()
	_body.position = frame.position + Vector2(12.0, HEADER_H)
	_body.size = Vector2(maxf(200.0, frame.size.x - 24.0),
		maxf(160.0, frame.size.y - HEADER_H - FOOTER_H))
	for s: LcnStatsScreen in screens:
		s.position = Vector2.ZERO
		s.size = _body.size
		s.invalidate()
	_chrome.queue_redraw()


func _frame_rect() -> Rect2:
	var logical: Vector2 = _chrome.size
	return Rect2(Vector2(MARGIN, MARGIN), logical - Vector2(MARGIN, MARGIN) * 2.0)


# ====================================================================  draw ==

func _draw_chrome() -> void:
	var t: LcnStatsTheme = theme_ref
	var ci: CanvasItem = _chrome
	_hot.clear()
	ci.draw_rect(Rect2(Vector2.ZERO, _chrome.size), t.SCRIM, true)
	var frame: Rect2 = _frame_rect()
	t.plate(ci, frame, t.PANEL, t.RIM)
	ci.draw_rect(Rect2(frame.position + Vector2(1.0, 1.0),
		Vector2(frame.size.x - 2.0, HEADER_H - 8.0)), t.PANEL_HEAD, true)

	var x: float = frame.position.x + 18.0
	var base: float = frame.position.y + 32.0
	x += t.caps(ci, Vector2(x, base), "Statistics", t.fs(t.FS_TITLE), t.ACCENT, 2.4) + 22.0

	# Tabs.
	var small: int = t.fs(t.FS_SMALL)
	for i: int in screens.size():
		var label: String = screens[i].screen_title().to_upper()
		var w: float = t.caps_width(label, small) + 22.0
		var r := Rect2(Vector2(x, frame.position.y + 14.0), Vector2(w, 26.0))
		var active: bool = i == tab
		var hovered: bool = _hot_index >= 0 and _hot_index < _hot.size() \
			and StringName(String(_hot[_hot_index]["id"])) == &"tab" \
			and int(_hot[_hot_index]["arg"]) == i
		if active:
			ci.draw_rect(r, t.ROW_SELECTED, true)
			ci.draw_rect(Rect2(Vector2(r.position.x, r.position.y + r.size.y - 2.0),
				Vector2(r.size.x, 2.0)), t.ACCENT, true)
		elif hovered:
			ci.draw_rect(r, t.ROW_HOVER, true)
		t.caps(ci, Vector2(x + 11.0, r.position.y + 18.0), label, small,
			t.TEXT_BRIGHT if active else t.TEXT_DIM)
		_hot.append({"rect": r, "id": &"tab", "arg": i})
		x += w + 4.0

	# Window selector, right-aligned.
	var right: float = frame.position.x + frame.size.x - 18.0
	for i2: int in range(WINDOWS.size() - 1, -1, -1):
		var entry: Dictionary = WINDOWS[i2]
		var narrower: float = 0.0
		if i2 > 0:
			narrower = _window_seconds(StringName(String((WINDOWS[i2 - 1] as Dictionary)["id"])))
		var label2: String = _window_label(entry, narrower)
		var w2: float = t.caps_width(label2, small) + 18.0
		var r2 := Rect2(Vector2(right - w2, frame.position.y + 14.0), Vector2(w2, 26.0))
		var on: bool = StringName(String(entry["id"])) == window_id
		ci.draw_rect(r2, t.ROW_SELECTED if on else Color(0, 0, 0, 0.18), true)
		ci.draw_rect(r2, t.ACCENT if on else t.RIM_SOFT, false, 1.0)
		t.caps(ci, Vector2(r2.position.x + 9.0, r2.position.y + 18.0), label2, small,
			t.TEXT_BRIGHT if on else t.TEXT_FAINT)
		_hot.append({"rect": r2, "id": &"window", "arg": String(entry["id"])})
		right -= w2 + 5.0

	# Subtitle under the tab row.
	t.text(ci, Vector2(frame.position.x + 18.0, frame.position.y + HEADER_H - 12.0),
		screens[tab].screen_subtitle(), t.fs(t.FS_SMALL), t.TEXT_FAINT)

	# Footer: the keys, and the honest cost of the recorder.
	var foot_y: float = frame.position.y + frame.size.y - 9.0
	t.text(ci, Vector2(frame.position.x + 18.0, foot_y),
		"TAB screens   ,  .  window   ← → reports   ESC close",
		t.fs(t.FS_TINY), t.TEXT_FAINT)
	t.text_right(ci, frame.position.x + frame.size.x - 18.0, foot_y,
		"%s  ·  recording %.3f ms/tick" % [_memory_note(),
			recorder.microseconds_per_tick() / 1000.0],
		t.fs(t.FS_TINY), t.TEXT_FAINT)


func _memory_note() -> String:
	return "%.0f KB of history" % (float(recorder.memory_bytes()) / 1024.0)


## The button says what the track ACTUALLY covers, read off the track. A button
## labelled MINUTE over a two-minute window is a small lie that costs a player
## an hour of wondering why their numbers do not add up.
## A RANGE PICKER HAS TO GET WIDER LEFT TO RIGHT.
##
## These labels are measured, not authored — each button says how much history
## its track actually holds — and in the first seconds of a run the measurement
## inverts them. `artifacts/play_tour/shots/06_lcn_stats.png` shows the row as
## "LAST 10 S | LAST 5 S | WHOLE RUN": the coarse track samples rarely, so early
## on it spans LESS time than the fine one, and the middle button offers the
## player a narrower window than the button to its left. So a window that has
## not yet outgrown its narrower neighbour keeps its authored name instead of
## advertising a span that is briefly a lie about the ordering.
func _window_label(entry: Dictionary, floor_seconds: float = 0.0) -> String:
	var id := StringName(String(entry["id"]))
	if id == LcnStatsRecorder.T_RUN:
		return "WHOLE RUN"
	var seconds: float = _window_seconds(id)
	if seconds <= floor_seconds or seconds <= 0.0:
		return String(entry["label"])
	if seconds < 90.0:
		return "LAST %d S" % int(round(seconds))
	return "LAST %d MIN" % int(round(seconds / 60.0))


## Seconds of history a track holds right now; 0 when it holds too few to span.
func _window_seconds(id: StringName) -> float:
	if recorder == null:
		return 0.0
	var t: LcnStatTrack = recorder.track(id)
	if t == null or t.sample_count() < 2:
		return 0.0
	return t.window_seconds()


# ===================================================================  input ==

func _on_chrome_input(event: InputEvent) -> void:
	var motion := event as InputEventMouseMotion
	if motion != null:
		var i: int = _hot_at(motion.position)
		if i != _hot_index:
			_hot_index = i
			_chrome.queue_redraw()
		return
	var click := event as InputEventMouseButton
	if click == null or not click.pressed or click.button_index != MOUSE_BUTTON_LEFT:
		return
	var j: int = _hot_at(click.position)
	if j < 0:
		return
	var e: Dictionary = _hot[j]
	if StringName(String(e["id"])) == &"tab":
		set_tab(int(e["arg"]))
	else:
		set_window(StringName(String(e["arg"])))
	_chrome.accept_event()


func _hot_at(pos: Vector2) -> int:
	for i: int in _hot.size():
		if (_hot[i]["rect"] as Rect2).has_point(pos):
			return i
	return -1


## Consumes nothing unless the screen is open, except the two keys that open it.
func _input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.ctrl_pressed or key.meta_pressed or key.alt_pressed:
		return
	if _typing():
		return
	var code: int = key.physical_keycode
	if not is_open:
		if code == KEY_P or code == KEY_G:
			toggle()
			_consume()
		return
	match code:
		KEY_P, KEY_G, KEY_ESCAPE:
			set_open(false)
			_consume()
		KEY_TAB:
			set_tab((tab + (-1 if key.shift_pressed else 1) + screens.size()) % screens.size())
			_consume()
		KEY_COMMA:
			_step_window(-1)
			_consume()
		KEY_PERIOD:
			_step_window(1)
			_consume()
		KEY_LEFT:
			night_screen().step(-1)
			_consume()
		KEY_RIGHT:
			night_screen().step(1)
			_consume()


func _step_window(delta: int) -> void:
	var i: int = 0
	for j: int in WINDOWS.size():
		if StringName(String((WINDOWS[j] as Dictionary)["id"])) == window_id:
			i = j
			break
	set_window(StringName(String((WINDOWS[clampi(i + delta, 0, WINDOWS.size() - 1)]
		as Dictionary)["id"])))


func _consume() -> void:
	var vp: Viewport = get_viewport()
	if vp != null:
		vp.set_input_as_handled()


func _typing() -> bool:
	var vp: Viewport = get_viewport()
	if vp == null:
		return false
	var focus: Control = vp.gui_get_focus_owner()
	return focus is LineEdit or focus is TextEdit
