class_name LcnHud
extends CanvasLayer
## The heads-up display. [P17]
##
## One CanvasLayer, one probe, one alert model, seven panels that paint
## themselves. The contract with the rest of the build is deliberately tiny:
##
## [codeblock]
##   var hud := LcnHud.new()
##   add_child(hud)                      # that is the whole installation
##   hud.refresh(play_controller)        # optional: build-mode read-out
##   hud.select(building_id)             # optional: drive the selection panel
## [/codeblock]
##
## It reads the simulation through LcnHudProbe and never writes to it. The only
## thing it ever asks the rest of the game for is a camera move, and that goes
## out on `Bus.camera_focus_requested` like everything else.
##
## THE RULE THIS HUD IS BUILT AROUND: **calm when the city is healthy, urgent
## when it is not.** One stress value drives plate brightness, panel rims, the
## edge vignette and whether the alert stack exists at all, so a base that is
## running well shows a clock, a grid readout and a shelf of stocks — and a base
## that is dying is impossible to misread.
##
## Cost: the sim is polled ten times a second, not per frame, and each panel
## redraws only when its own signature string changes. A steady city costs a
## handful of microseconds a frame; see `last_refresh_us` and tests/hud/.

const DESIGN_MARGIN: float = 16.0
const GAP: float = 10.0
## Above [P13]'s post-process (layer 60). Film grain and a chromatic split are
## right for a frozen city and wrong for a column of numbers: under them a
## segment meter reads as static and small type grows colour fringes. The world
## keeps the treatment, the interface stays crisp. Still below [P19]'s overlay
## legends (70/72), which are meant to sit on top of everything.
const LAYER: int = 65
## Wall-clock fallback poll, for when the simulation clock is not moving.
const PAUSED_POLL_SECONDS: float = 0.25

var style: LcnHudStyle = null
var probe: LcnHudProbe = null
var alerts: LcnHudAlerts = null

var clock_panel: LcnHudClock = null
var heat_panel: LcnHudHeat = null
var vitals_panel: LcnHudVitals = null
var wave_panel: LcnHudWave = null
var resource_panel: LcnHudResources = null
var alert_panel: LcnHudAlertStack = null
var selection_panel: LcnHudSelection = null
var tooltip: LcnHudTooltip = null

## Microseconds the last data refresh took. Read by the perf test.
var last_refresh_us: int = 0
var selected_id: int = -1
## Buildings and citizens mint ids independently, so the panel has to remember
## which of the two it is looking at.
var selected_is_citizen: bool = false

## Which composition the screen is in. `LcnHudLayout.State`. Read by the panels
## through `emphasis`, by the vignette, and by the audit suite.
var state: int = LcnHudLayout.State.LULL
## The stage director: places [P22]'s card and tells us when one is up.
var stage: LcnHudStage = null

var _root: Control = null
var _vignette: Control = null
var _scrim: Control = null
var _footer: Control = null
var _widgets: Array[LcnHudWidget] = []
var _context: Object = null
var _camera: Node = null
var _camera_poll: float = 0.0
var _urgency: float = 0.0
var _urgency_target: float = 0.0
var _since_poll: float = 0.0
var _last_layout: Vector2 = Vector2.ZERO
var _footer_signature: String = ""
var _rects: Dictionary = {}
var _panels_by_name: Dictionary = {}
var _scrim_alpha: float = 0.0
var _footer_ceiling: float = 0.0
## The card size the last solve was made against, so a card that grows gets a
## new composition on the frame it grows rather than on the next poll.
var _last_card_size: Vector2 = Vector2.ZERO


## Name and layer are set in _init, not _ready: `LcnLayers.audit()` identifies a
## canvas by node NAME, and boot runs that audit over a tree that may contain a
## HUD which has not been notified yet. A node that only names itself once it is
## ready is a node the allocation table cannot see.
func _init() -> void:
	name = "LcnHud"
	layer = LAYER


## How [P18] and [P19] ask where the composition put their strips. A group and a
## method, never a path: both parts work without a HUD in the build, and both
## fall back to their own bottom margin when this answers an empty rect.
const CHROME_GROUP: StringName = &"lcn_hud_chrome"


func _ready() -> void:
	name = "LcnHud"
	layer = LAYER
	add_to_group(CHROME_GROUP)
	style = LcnHudStyle.new()
	probe = LcnHudProbe.new()
	alerts = LcnHudAlerts.new()

	_root = Control.new()
	_root.name = "HudRoot"
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	# Under every panel and over the world: the scrim is what turns [P22]'s card
	# from a rectangle floating on a lit city into a question being asked.
	_scrim = Control.new()
	_scrim.name = "Scrim"
	_scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_scrim.draw.connect(_draw_scrim)
	_root.add_child(_scrim)

	_vignette = Control.new()
	_vignette.name = "Vignette"
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vignette.draw.connect(_draw_vignette)
	_root.add_child(_vignette)

	clock_panel = LcnHudClock.new()
	heat_panel = LcnHudHeat.new()
	alert_panel = LcnHudAlertStack.new()
	vitals_panel = LcnHudVitals.new()
	wave_panel = LcnHudWave.new()
	resource_panel = LcnHudResources.new()
	selection_panel = LcnHudSelection.new()
	alert_panel.bind_alerts(alerts)
	# Tree order is the keyboard's Tab order, so it runs worst-news-first.
	_install(alert_panel, "Alerts")
	_install(clock_panel, "Clock")
	_install(heat_panel, "Heat")
	_install(vitals_panel, "Vitals")
	_install(wave_panel, "Wave")
	_install(selection_panel, "Selection")
	_install(resource_panel, "Resources")

	_footer = Control.new()
	_footer.name = "Footer"
	_footer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_footer.draw.connect(_draw_footer)
	_root.add_child(_footer)

	tooltip = LcnHudTooltip.new()
	tooltip.name = "Tooltip"
	tooltip.setup(style)
	_root.add_child(tooltip)

	stage = LcnHudStage.new()
	add_child(stage)

	probe.bind()
	Bus.world_ready.connect(_on_world_ready)
	Bus.ui_scale_changed.connect(_on_ui_scale_changed)
	Bus.alert_raised.connect(_on_alert_raised)
	# A lens coming up changes how much of the bottom rail and the right column
	# [P19] needs, which changes where everything else may sit. Without this the
	# composition only caught up on the next probe poll, so pressing F1 shuffled
	# the shelf a tenth of a second later.
	Bus.overlay_mode_changed.connect(_on_overlay_mode_changed)
	get_viewport().size_changed.connect(_relayout)
	_relayout()
	Log.info("hud", "installed (%d panels)" % _widgets.size())


func _install(w: LcnHudWidget, node_name: String) -> void:
	w.name = node_name
	_root.add_child(w)
	w.setup(self, style, probe)
	w.visible = false
	_widgets.append(w)


func _exit_tree() -> void:
	if Bus.world_ready.is_connected(_on_world_ready):
		Bus.world_ready.disconnect(_on_world_ready)
	if Bus.ui_scale_changed.is_connected(_on_ui_scale_changed):
		Bus.ui_scale_changed.disconnect(_on_ui_scale_changed)
	if Bus.alert_raised.is_connected(_on_alert_raised):
		Bus.alert_raised.disconnect(_on_alert_raised)
	if Bus.overlay_mode_changed.is_connected(_on_overlay_mode_changed):
		Bus.overlay_mode_changed.disconnect(_on_overlay_mode_changed)
	# The probe and the alert model live on Bus subscriptions; without this they
	# outlive the HUD that owns them and keep answering signals forever.
	if probe != null:
		probe.dispose()
	if alerts != null:
		alerts.dispose()


# ======================================================================  api ==

## Integrator hook, signature-compatible with the placeholder PlayHud: pass the
## play shell and the footer shows build mode, the ghost's refusal reason and
## what is under the cursor. Optional — the HUD is complete without it.
func refresh(context: Object = null) -> void:
	_context = context


## Drives the selection panel with a BUILDING id. -1 clears it.
func select(id: int) -> void:
	if id == selected_id and not selected_is_citizen:
		return
	selected_id = id
	selected_is_citizen = false
	if id < 0:
		selection_panel.clear_entity()
		_repaint()
		return
	var info: Dictionary = probe.describe_building(id)
	if info.is_empty():
		selection_panel.clear_entity()
		selected_id = -1
		_repaint()
		return
	selection_panel.show_entity(info, false)
	# Straight to the pixels, without waiting for the next poll: a click has to
	# answer immediately, and the player may well have paused to make it.
	_repaint()


## Drives the selection panel with a CITIZEN id.
func select_citizen(id: int) -> void:
	if id == selected_id and selected_is_citizen:
		return
	var citizen: Dictionary = probe.describe_citizen(id)
	if citizen.is_empty():
		return
	selected_id = id
	selected_is_citizen = true
	selection_panel.show_entity(_citizen_view(citizen), true)
	_repaint()


## Selects whatever stands on a map cell — the person on top of it before the
## building under it, because the person is what the player was pointing at.
## Returns the id, or -1.
func select_cell(cell: Vector2i) -> int:
	var who: int = probe.citizen_at_cell(cell)
	if who >= 0:
		select_citizen(who)
		return who
	var id: int = probe.entity_at_cell(cell)
	select(id)
	return id


## Tooltip plumbing, called by the widgets. `panel` is the owning panel's rect,
## which the card is placed outside of.
func show_tooltip(anchor: Rect2, panel: Rect2, title: String, body: String) -> void:
	if tooltip != null:
		tooltip.show_for(anchor, panel, title, body)


func hide_tooltip() -> void:
	if tooltip != null:
		tooltip.hide_tip()


## 0..1 city stress, smoothed. The renderer or the audio mixer may read it.
func urgency() -> float:
	return _urgency


# ==================================================================  lifecycle =

func _on_world_ready() -> void:
	probe.bind()
	alerts.clear()
	select(-1)
	for w: LcnHudWidget in _widgets:
		w.invalidate()


func _on_overlay_mode_changed(_mode: StringName) -> void:
	_place_panels()


func _on_ui_scale_changed(_value: float) -> void:
	style.refresh_from_settings()
	_relayout()


## An alert is the one thing that must not wait for the next poll.
func _on_alert_raised(severity: int, _key: StringName, _text: String, _pos: Vector2) -> void:
	if severity >= 1:
		_force_refresh()


func _process(delta: float) -> void:
	style.beat += delta
	var t0: int = Time.get_ticks_usec()
	_since_poll += delta
	if probe.refresh():
		_after_probe()
		_since_poll = 0.0
	elif _since_poll > PAUSED_POLL_SECONDS:
		# The tick-based rate limit never fires while the game is PAUSED, and a
		# paused city is exactly when a player reads the interface. Fall back to
		# a slow wall-clock poll so selection, tooltips and stocks stay live.
		_since_poll = 0.0
		_force_refresh()
	last_refresh_us = Time.get_ticks_usec() - t0

	# [P22] can change the size of the one thing allowed on the stage between one
	# poll and the next, and every rectangle the stage carries — the card's own
	# slot and the ticker's strip under it — is solved against that size. Waiting
	# for the 10 Hz poll meant six frames of a composition arranged around a card
	# that is no longer the card on screen.
	if stage != null and not stage.card_size.is_equal_approx(_last_card_size):
		_last_card_size = stage.card_size
		_place_panels()

	var want_scrim: float = 1.0 if (stage != null and stage.card_visible()) else 0.0
	var scrim_next: float = move_toward(_scrim_alpha, want_scrim,
		delta * (4.0 if not style.reduce_motion else 100.0))
	if not is_equal_approx(scrim_next, _scrim_alpha):
		_scrim_alpha = scrim_next
		_scrim.queue_redraw()

	var speed: float = 2.4 if not style.reduce_motion else 100.0
	var next: float = move_toward(_urgency, _urgency_target, delta * speed)
	if not is_equal_approx(next, _urgency):
		_urgency = next
		style.urgency = _urgency
		_vignette.queue_redraw()
	# Only the panels that actually breathe get a per-frame redraw, and only
	# while something is wrong.
	if _urgency > 0.05 and not style.reduce_motion:
		if alert_panel.visible:
			alert_panel.queue_redraw()
		if clock_panel.visible and _urgency > 0.4:
			clock_panel.queue_redraw()
		if wave_panel.visible:
			wave_panel.queue_redraw()
	_refresh_footer()
	_camera_poll -= delta
	if _camera == null and _camera_poll <= 0.0:
		_camera_poll = 0.5
		_bind_camera()


func _force_refresh() -> void:
	if probe.refresh(true):
		_after_probe()


## Re-lays every panel and puts them back where they belong. Cheap: each panel
## still decides for itself whether anything actually changed.
func _repaint() -> void:
	for w: LcnHudWidget in _widgets:
		w.refresh()
	_place_panels()


func _after_probe() -> void:
	alerts.refresh(probe, SimClock.seconds())
	_urgency_target = maxf(probe.stress(), _alert_pressure())
	style.urgency = _urgency
	if selected_id >= 0:
		if selected_is_citizen:
			var who: Dictionary = probe.describe_citizen(selected_id)
			if not who.is_empty():
				selection_panel.show_entity(_citizen_view(who), true)
		else:
			var info: Dictionary = probe.describe_building(selected_id)
			if not info.is_empty():
				selection_panel.show_entity(info, false)
	_repaint()


func _alert_pressure() -> float:
	match alerts.worst_severity():
		LcnHudStyle.Sev.CRITICAL:
			return 1.0
		LcnHudStyle.Sev.DANGER:
			return 0.72
		LcnHudStyle.Sev.WARN:
			return 0.35
	return 0.0


# =====================================================================  layout =

## The HUD is authored in design pixels and scaled once, here, so a widget never
## has to think about ui_scale. Font scale is applied separately inside the
## style, which is what lets a player enlarge the text without inflating the
## panels around it.
## A panel's LOGICAL size depends on `font_scale` and on its content — never on
## `ui_scale`, which is applied once on this CanvasLayer. That is what makes the
## fit below a single pass rather than a fixed-point iteration: measure the
## panels at any scale, and the answer is the same.
func _relayout() -> void:
	style.refresh_from_settings()
	var vp: Vector2 = Vector2(get_viewport().get_visible_rect().size)
	# THE PLAYER'S SCALE IS HONOURED IN FULL, and that is a decision that was made
	# twice. An earlier version of this file capped `ui_scale` so the composition
	# could always promise the world a third of the screen; measured, that cap
	# refused a request of 1.5 and handed back 1.05, and refused 1.0-with-large-
	# type and handed back 0.90. Quietly overruling an accessibility setting to
	# protect a layout target is the wrong way round: a player who enlarges the
	# interface has traded stage for legibility on purpose, and a stage that is
	# small because they asked for it is not a defect.
	#
	# What the composition owes them instead is that NOTHING OVERLAPS at any
	# scale, which is enforced by clamping panels against the room they actually
	# have — see `_apply_caps` and the `max_height` on the three growable panels.
	# `tests/d7/run_layout_audit.tscn` checks the stage floor at ui 1.0, where it
	# is the designer's promise, and checks overlap everywhere.
	_resize_root(vp, style.ui_scale)
	for w0: LcnHudWidget in _widgets:
		w0.invalidate()
		w0.refresh()
	_place_panels()
	_vignette.queue_redraw()
	_footer.queue_redraw()


func _resize_root(vp: Vector2, ui: float) -> void:
	style.ui_scale = ui
	scale = Vector2(ui, ui)
	var logical: Vector2 = vp / maxf(0.01, ui)
	_root.size = logical
	_root.position = Vector2.ZERO
	_scrim.size = logical
	_vignette.size = logical
	_footer.size = logical
	tooltip.size = logical
	_last_layout = logical


## Panel name → the widget that draws it. The one place the two vocabularies
## meet, so the solver never has to know about node names and the widgets never
## have to know about the solver.
func _panel_map() -> Dictionary:
	if _panels_by_name.is_empty():
		_panels_by_name = {
			"clock": clock_panel, "heat": heat_panel, "alerts": alert_panel,
			"vitals": vitals_panel, "wave": wave_panel, "stores": resource_panel,
			"selection": selection_panel,
		}
	return _panels_by_name


## What composition the screen should be in right now. Night or an assault beats
## a build; a build beats the lull.
func _resolve_state() -> int:
	# The composition leads the event rather than following it. Switching only on
	# `is_night` meant the frame at dusk — clock red, ATTENTION reading "Attack in
	# 40 seconds", wave panel counting down — was still laid out and lit as a
	# quiet afternoon. Forty seconds is exactly when a player needs the heat grid
	# and the attention stack to be the loudest things on the screen.
	var night: bool = probe != null and (probe.is_night
		or (probe.seconds_to_night >= 0.0 and probe.seconds_to_night < 45.0))
	var attack: bool = probe != null and (probe.wave_active or probe.enemies_alive > 0
		or (probe.wave_seconds >= 0.0 and probe.wave_seconds < 45.0))
	var building: bool = false
	if _context != null and _context.has_method("get"):
		building = bool(_context.get("build_mode"))
	if not building and _build_menu_block() > 0.0:
		building = true
	return LcnHudLayout.state_for(night, attack, building)


## Screen pixels of the left edge that [P18]'s open build panels own, so the left
## rail can slide out from under them instead of being covered. Asked of the live
## node through a group and a method name, never a path — and zero when [P18] is
## not in this build at all.
func _build_menu_block() -> float:
	var tree: SceneTree = get_tree()
	if tree == null:
		return 0.0
	var menu: Node = tree.get_first_node_in_group(&"lcn_build_menu")
	if menu == null or not menu.has_method(&"left_block"):
		return 0.0
	return float(menu.call(&"left_block"))


## The screen rectangle the composition reserved for `key`, or an empty Rect2
## when this solve did not place one. `hint`, `lens_hint`, `legend`, `rail`,
## `stage` and `card` are the keys other parts ask for.
func solved_rect(key: StringName) -> Rect2:
	return _rects.get(String(key), Rect2()) as Rect2


## "The strip I asked you to reserve for me is the wrong size now." Called by any
## part whose published size changed between polls — [P19]'s legend grows two
## rows the moment a second heat grid appears.
##
## The composition is otherwise re-solved on the probe's 10 Hz poll, which is
## right for a panel whose CONTENTS changed and wrong for one whose SIZE did:
## a hundred milliseconds is six frames of a strip that is too short for what is
## standing on it. Cheap enough to call on the frame it changes — one solve over
## eight rectangles — and the caller is expected to only call it on a change.
func request_relayout() -> void:
	_place_panels()


## Every rectangle the HUD is drawing, in SCREEN pixels, by name. The audit suite
## reads this; so does anything that wants to know where it may not draw.
func chrome_rects() -> Dictionary:
	var out: Dictionary = {}
	for name_key: String in _panel_map():
		var w: LcnHudWidget = _panel_map()[name_key]
		if w != null and w.visible and w.size.x > 1.0:
			out[name_key] = Rect2(w.position * style.ui_scale, w.size * style.ui_scale)
	if stage != null and stage.card_rect.size.x > 1.0:
		out["card"] = stage.card_rect
	if stage != null and stage.ticker_rect.size.x > 1.0:
		out["ticker"] = stage.ticker_rect
	return out


## Hands the caps the last solve produced to the panels they belong to. Returns
## true when anything actually changed, which is the signal to solve again.
func _apply_caps() -> bool:
	var moved: bool = false
	if _rects.has("alerts_max_h"):
		var a: float = (_rects["alerts_max_h"] as Rect2).size.y
		moved = moved or not is_equal_approx(a, alert_panel.max_height)
		alert_panel.max_height = a
	if _rects.has("selection_max_h"):
		var s2: float = (_rects["selection_max_h"] as Rect2).size.y
		moved = moved or not is_equal_approx(s2, selection_panel.max_height)
		selection_panel.max_height = s2
	if resource_panel != null:
		var chips: int = LcnHudLayout.chip_budget(state, _last_layout.x * style.ui_scale,
			style.ui_scale, LcnHudResources.CHIP.x, LcnHudResources.PAD)
		moved = moved or chips != resource_panel.chip_budget
		resource_panel.chip_budget = chips
	return moved


func _place_panels() -> void:
	var w: float = _last_layout.x
	if w <= 0.0:
		return
	var view: Vector2 = _last_layout * style.ui_scale
	state = _resolve_state()

	var sizes: Dictionary = {}
	for name_key: String in _panel_map():
		var widget: LcnHudWidget = _panel_map()[name_key]
		if widget != null and widget.visible:
			sizes[name_key] = widget.size

	var extra: Dictionary = {"left_block": _build_menu_block()}
	if stage != null and stage.card_size.x > 1.0:
		extra["card"] = stage.card_size
	var tree: SceneTree = get_tree()
	if tree != null:
		var menu: Node = tree.get_first_node_in_group(&"lcn_build_menu")
		if menu != null and menu.has_method(&"hint_size"):
			extra["hint"] = menu.call(&"hint_size") as Vector2
		var lens: Node = tree.get_first_node_in_group(&"lcn_overlay_root")
		if lens != null and lens.has_method(&"legend_size"):
			extra["legend"] = lens.call(&"legend_size") as Vector2
			extra["rail"] = lens.call(&"rail_size") as Vector2

	# SOLVED TWICE, and it has to be. The first solve is what tells the attention
	# stack and the selection panel how much room they actually have; both then
	# shed rows and change height, which changes where everything below them goes.
	# Solving once left the lens rail placed against last frame's selection panel
	# and 26,000 px² of overlap on screen until the next poll caught up — a
	# composition that is only correct one frame late is a composition that is
	# wrong every time the player changes anything.
	_rects = LcnHudLayout.solve(view, style.ui_scale, state, sizes, extra)
	# Three passes at most. Each one is a solve over eight rectangles and two
	# panel re-layouts, and it converges in one on every configuration measured;
	# the bound is there so a pathological content size can cost a frame rather
	# than a hang.
	for _pass: int in 3:
		if not _apply_caps():
			break
		for name_key3: String in _panel_map():
			var widget3: LcnHudWidget = _panel_map()[name_key3]
			if widget3 != null and widget3.visible:
				widget3.refresh()
				sizes[name_key3] = widget3.size
		_rects = LcnHudLayout.solve(view, style.ui_scale, state, sizes, extra)
	_footer_ceiling = (_rects["footer_ceiling"] as Rect2).position.y / style.ui_scale

	for name_key2: String in _panel_map():
		var widget2: LcnHudWidget = _panel_map()[name_key2]
		if widget2 == null or not _rects.has(name_key2):
			continue
		var r: Rect2 = _rects[name_key2]
		widget2.position = (r.position / style.ui_scale).round()
		widget2.clamp_height(r.size.y / style.ui_scale)
		widget2.emphasis = LcnHudLayout.emphasis_of(state, name_key2)
	if stage != null:
		stage.slot = _rects.get("card", Rect2())
		stage.ticker_slot = _rects.get("ticker", Rect2())


# =====================================================================  scrim =

## The world dims behind a decision. Drawn on the HUD layer, which is over the
## world and under [P22]'s card, so a question being asked reads as one thing
## instead of as a rectangle that happens to be there. It fades rather than
## snapping, it is skipped entirely when nothing is asking, and the stage
## rectangle is left brightest in the middle so the city is still legible behind
## the card — a scrim that blacks out the game is a loading screen.
func _draw_scrim() -> void:
	if _scrim_alpha <= 0.01:
		return
	var w: float = _scrim.size.x
	var h: float = _scrim.size.y
	var deep: Color = LcnHudStyle.P.COLD_ABYSS
	_scrim.draw_rect(Rect2(0.0, 0.0, w, h),
		Color(deep.r, deep.g, deep.b, 0.52 * _scrim_alpha), true)


# ==================================================================  vignette =

## The room goes dark at the edges when the city is in trouble. It is the only
## full-screen effect the HUD owns, it is never animated when the player asked
## for reduced motion, and at urgency 0 it draws nothing at all.
func _draw_vignette() -> void:
	if _urgency <= 0.02 and (probe == null or not probe.is_night):
		return
	var w: float = _vignette.size.x
	var h: float = _vignette.size.y
	var band: float = minf(h * 0.30, 220.0)
	var danger: Color = style.sev_colour(LcnHudStyle.Sev.DANGER)
	var pulse: float = 1.0
	if _urgency > 0.6:
		pulse = 0.82 + 0.18 * style.pulse(2.0)
	var strength: float = _urgency * 0.30 * pulse
	if strength > 0.004:
		_band(Rect2(0.0, 0.0, w, band), Vector2(0.0, 1.0), danger, strength)
		_band(Rect2(0.0, h - band, w, band), Vector2(0.0, -1.0), danger, strength * 0.9)
		_band(Rect2(0.0, 0.0, band * 0.8, h), Vector2(1.0, 0.0), danger, strength * 0.7)
		_band(Rect2(w - band * 0.8, 0.0, band * 0.8, h), Vector2(-1.0, 0.0), danger,
			strength * 0.7)
	if probe != null and probe.is_night:
		var cold: Color = LcnHudStyle.P.COLD_DEEP
		var night: float = 0.18 * clampf(1.0 - probe.light_level * 2.0, 0.0, 1.0)
		_band(Rect2(0.0, 0.0, w, band * 0.7), Vector2(0.0, 1.0), cold, night)
		_band(Rect2(0.0, h - band * 0.7, w, band * 0.7), Vector2(0.0, -1.0), cold, night)


## One edge gradient, drawn as a four-point polygon with per-vertex alpha.
func _band(rect: Rect2, fade_dir: Vector2, colour: Color, alpha: float) -> void:
	var p0: Vector2 = rect.position
	var p1: Vector2 = rect.position + Vector2(rect.size.x, 0.0)
	var p2: Vector2 = rect.position + rect.size
	var p3: Vector2 = rect.position + Vector2(0.0, rect.size.y)
	var strong := Color(colour.r, colour.g, colour.b, alpha)
	var weak := Color(colour.r, colour.g, colour.b, 0.0)
	var cols: PackedColorArray
	if fade_dir.y > 0.0:
		cols = PackedColorArray([strong, strong, weak, weak])
	elif fade_dir.y < 0.0:
		cols = PackedColorArray([weak, weak, strong, strong])
	elif fade_dir.x > 0.0:
		cols = PackedColorArray([strong, weak, weak, strong])
	else:
		cols = PackedColorArray([weak, strong, strong, weak])
	_vignette.draw_polygon(PackedVector2Array([p0, p1, p2, p3]), cols)


# ====================================================================  footer =

## Toasts and the build-mode read-out. Kept in one small Control at the bottom
## so the big panels never redraw for a passing message.
func _refresh_footer() -> void:
	var sig: String = _footer_sig()
	if sig == _footer_signature:
		return
	_footer_signature = sig
	_footer.queue_redraw()


func _footer_sig() -> String:
	var parts: PackedStringArray = PackedStringArray()
	for t: Dictionary in alerts.toasts():
		parts.append("%s%d" % [t.get("text", ""), int(t.get("count", 1))])
	if _context != null:
		parts.append(_context_line())
	parts.append(_works_line())
	return "|".join(parts)


## What the city is quietly getting on with: sites under construction and the
## research in progress. Bottom-right, small, and absent when there is neither —
## this is background, not news.
func _works_line() -> String:
	var parts: PackedStringArray = PackedStringArray()
	if probe.sites_pending > 0:
		parts.append("%d site%s building" % [probe.sites_pending,
			"" if probe.sites_pending == 1 else "s"])
	if probe.research_title != "":
		parts.append("%s %s" % [probe.research_title,
			LcnHudFormat.percent(probe.research_progress)])
	return "  ·  ".join(parts)


func _context_line() -> String:
	if _context == null:
		return ""
	var line: String = ""
	if bool(_context.get("build_mode")) and _context.has_method("palette_label"):
		line = "BUILD  ·  %s" % String(_context.call("palette_label"))
		if _context.has_method("ghost_reason"):
			var why: String = String(_context.call("ghost_reason"))
			if why != "":
				line += "  ·  cannot place here: %s" % why
	elif _context.has_method("hovered_cell"):
		line = LcnHudFormat.cell(_context.call("hovered_cell") as Vector2i)
	return line


func _draw_footer() -> void:
	if style == null:
		return
	var w: float = _footer.size.x
	var h: float = _footer.size.y
	var line: String = _context_line()
	if line != "":
		var size_px: int = style.fs(12)
		var text_w: float = style.text_width(line, size_px)
		var rect := Rect2((w - text_w) * 0.5 - 14.0, h - 34.0, text_w + 28.0, 24.0)
		style.draw_plate(_footer, rect, 0.25, LcnHudStyle.Sev.CALM, 7717)
		style.draw_text(_footer, Vector2(rect.position.x + 14.0, rect.position.y + 16.0),
			line, size_px, style.ink_dim())

	var works: String = _works_line()
	if works != "":
		# The city's quiet business shares the stores shelf's own baseline on the
		# far side. It used to be pinned to `h - 14`, which put it under the
		# shelf at every resolution where the shelf was not exactly 96 px tall.
		var works_y: float = h - 14.0
		if resource_panel != null and resource_panel.visible:
			works_y = resource_panel.position.y + resource_panel.size.y - 14.0
		style.draw_text_right(_footer, w - 18.0, works_y, works, style.fs(11),
			style.ink_faint())

	# Above the WHOLE bottom rail, not just above the shelf. The solver already
	# worked out where the rail's ceiling is — [P18]'s hotkey strip and [P19]'s
	# legend are both under it — so ask it rather than guessing a constant that
	# goes stale the first time another part adds a strip.
	var ceiling: float = _footer_ceiling if _footer_ceiling > 0.0 else h - DESIGN_MARGIN
	var y: float = minf(h - 52.0, ceiling - 14.0)
	var toast_list: Array[Dictionary] = alerts.toasts()
	for i: int in range(toast_list.size() - 1, -1, -1):
		var t: Dictionary = toast_list[i]
		var text: String = String(t.get("text", ""))
		var n: int = int(t.get("count", 1))
		if n > 1:
			text += "  ×%d" % n
		var fs: int = style.fs(12)
		var tw: float = style.text_width(text, fs)
		var r := Rect2((w - tw) * 0.5 - 12.0, y - 20.0, tw + 24.0, 24.0)
		style.draw_plate(_footer, r, 0.3, int(t.get("sev", 1)), 5150 + i)
		style.draw_text(_footer, Vector2(r.position.x + 12.0, r.position.y + 16.0), text, fs,
			style.ink())
		y -= 28.0


# =====================================================================  input =

func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	var focus: Control = _root.get_viewport().gui_get_focus_owner()
	var inside: bool = focus != null and _root.is_ancestor_of(focus)
	if key.physical_keycode == KEY_TAB and not inside:
		# Tab from the world puts the keyboard on the most urgent thing there is.
		var target: LcnHudWidget = _first_focusable()
		if target != null:
			target.grab_focus()
			get_viewport().set_input_as_handled()
	elif key.physical_keycode == KEY_ESCAPE and inside:
		focus.release_focus()
		hide_tooltip()
		get_viewport().set_input_as_handled()


func _first_focusable() -> LcnHudWidget:
	for w: LcnHudWidget in [alert_panel, selection_panel, heat_panel, clock_panel,
			wave_panel, vitals_panel, resource_panel]:
		if w != null and w.visible and not w.hot.is_empty():
			return w
	return null


## Binds to [P16]'s camera when it exists so clicking the world drives the
## selection panel. Absent camera, absent selection — the panel simply never
## opens, and everything else still works.
func _bind_camera() -> void:
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	var cam: Node = get_viewport().get_camera_2d()
	if cam == null or not cam.has_signal(&"selection_changed"):
		cam = _find_camera(tree.root, 0)
	if cam == null or not cam.has_signal(&"selection_changed"):
		return
	_camera = cam
	if not cam.is_connected(&"selection_changed", _on_camera_selection):
		cam.connect(&"selection_changed", _on_camera_selection)


func _find_camera(node: Node, depth: int) -> Node:
	if depth > 4:
		return null
	for child: Node in node.get_children():
		if child is Camera2D and child.has_signal(&"selection_changed"):
			return child
		var found: Node = _find_camera(child, depth + 1)
		if found != null:
			return found
	return null


func _on_camera_selection(ids: PackedInt32Array, cell_rect: Rect2i) -> void:
	if ids.is_empty():
		if cell_rect.size == Vector2i.ZERO:
			select(-1)
			return
		select_cell(cell_rect.position)
		return
	select(ids[0])


## One citizen, in the selection panel's shape. [P05]'s `citizen_info` carries
## needs on a 0..100 scale plus its own written `condition` and `doing` phrases —
## those phrases are used as written, because the part that models a person is
## better placed to describe them than the part that draws rectangles.
## Cold, hungry, exhausted, ill or hurt — [P05]'s own thresholds, on its own
## 0..100 needs scale.
func _citizen_in_trouble(info: Dictionary) -> bool:
	return _need(info, "warmth", 100.0) < 40.0 \
		or _need(info, "hunger", 0.0) > 60.0 \
		or _need(info, "fatigue", 0.0) > 80.0 \
		or _need(info, "illness", 0.0) > 0.5 \
		or _need(info, "injury", 0.0) > 0.5 \
		or _need(info, "health", 100.0) < 60.0


func _need(info: Dictionary, key: String, fallback: float) -> float:
	if not info.has(key):
		return fallback
	var v: float = float(info[key])
	return v * 100.0 if v <= 1.0001 and v > 0.0 else v


func _citizen_view(info: Dictionary) -> Dictionary:
	var lines: Array[Dictionary] = []
	var problems: Array[String] = []
	var rows: Array = [
		["Warmth", "warmth", "Body warmth. Below 40 they start falling ill; below "
			+ "12 the cold begins taking their health."],
		["Health", "health", "How badly hurt or ill they are. It only comes back "
			+ "with warmth, food and rest."],
		["Hunger", "hunger", "How hungry they are. Kitchens and a short walk to "
			+ "them are what bring it down."],
		["Fatigue", "fatigue", "How tired they are. Longer shifts raise it and "
			+ "only a bed lowers it."],
		["Morale", "morale", "Whether this one still believes in the city. It "
			+ "feeds [P06]'s hope and discontent."],
	]
	for row: Array in rows:
		if not info.has(row[1]):
			continue
		var raw: float = float(info[row[1]])
		var value01: float = raw / 100.0 if raw > 1.0001 else raw
		var good: float = value01
		if row[1] == "hunger" or row[1] == "fatigue":
			good = 1.0 - value01
		lines.append({
			"label": String(row[0]), "value": LcnHudFormat.percent(value01),
			"good": good, "tip": String(row[2]),
		})
	for pair: Array in [["Trade", "profession"], ["Works at", "job_name"],
			["Home", "home_name"], ["Shift", "shift"]]:
		var text: String = String(info.get(pair[1], ""))
		if text == "" or text == "-1":
			continue
		lines.append({
			"label": String(pair[0]), "value": LcnHudFormat.titleize(text), "good": 1.0,
			"tip": "Where this citizen belongs in the city. An unhoused or "
				+ "unemployed citizen is a citizen the winter gets to first.",
		})
	if not bool(info.get("housed", true)):
		problems.append("They have nowhere to sleep.")
	# [P05] writes one phrase for how this person is doing. It is only a PROBLEM
	# when something is actually wrong with them — "in good spirits" under a red
	# exclamation mark is how an interface teaches a player to stop reading it.
	var condition: String = String(info.get("condition", ""))
	if condition != "":
		var text: String = LcnHudFormat.titleize(condition) + "."
		if _citizen_in_trouble(info):
			problems.append(text)
		else:
			lines.append({
				"label": "Doing", "value": LcnHudFormat.titleize(condition),
				"good": 1.0,
				"tip": "How this citizen is holding up, in their own words.",
			})
	for key2: String in ["problem", "why", "complaint"]:
		if info.has(key2):
			problems.append(String(info[key2]))
	var cell: Variant = info.get("cell", Vector2i.ZERO)
	return {
		"id": int(info.get("id", -1)),
		"kind": &"citizen",
		"title": String(info.get("name", "Citizen")),
		"cell": cell if cell is Vector2i else LcnHudProbe._to_cell_static(cell),
		"state": 2,
		"lines": lines,
		"problems": problems,
		"task": String(info.get("doing", info.get("task", info.get("activity", "")))),
		"progress": 1.0,
		"hp": 1.0,
		"max_hp": 1.0,
	}
