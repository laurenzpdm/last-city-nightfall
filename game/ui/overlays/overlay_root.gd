class_name LcnOverlayRoot
extends Node
## [P19] The lens system: mode state, hotkeys, the per-frame sample, and the two
## canvas layers everything is drawn on.
##
## LAYERING. The two numbers come from `LcnLayers` and are deliberately NOT
## restated here. This file used to carry its own `WORLD_LAYER = 70`, which put
## world-space lenses above the HUD and painted FROZEN badges across the clock;
## boot's `enforce()` corrected it on every launch and said so in a WARN, which
## is a disagreement surviving rather than a bug being fixed. A part that reads
## the allocation table cannot drift away from it.
##
## `OVERLAY_WORLD` follows the viewport, so the lenses draw in WORLD coordinates,
## above [P13]'s post stack but under the HUD. Above the post stack because the
## night grade, the bloom and the cold chromatic split exist to make the world
## feel cold, and a diagnostic graded along with them stops being readable at
## exactly the hour the player most needs to read it. Under the HUD because a
## lens is paint on the ground, and the ground does not get to cover the clock.
## The legend is chrome rather than a lens, so it lives in screen space on
## `OVERLAY_UI`, on top with the rest of the chrome.
##
## COST. Sampling the simulation is throttled to 4 Hz and is the only thing that
## touches sim objects; drawing at 60 Hz walks flat Packed arrays and batches
## into a handful of draw calls per lens. Both numbers are measured, not
## asserted — see the "overlay" line in the log.
##
## HOTKEYS. F1..F6 select a lens; ALT+1..ALT+6 do the same and are always free;
## a bare number key is claimed ONLY when no other part has already bound it, so
## adding this system can never steal the sim-speed keys from [P16]. The rail on
## screen prints whatever was actually claimed.
##
## For [P17]/[P18]:
##   LcnOverlayRoot.instance()      the live root, or null
##   root.set_mode(LcnOverlayDefs.Mode.BOTTLENECK)
##   root.mode                      current lens
##   Bus.overlay_mode_changed       emitted on every change

const GROUP: StringName = &"lcn_overlay_root"
const SETTINGS_REFRESH: float = 0.5
const LOG_EVERY: int = 600
## Frames of quiet owed between two density lines. See the density block in `_process`.
const DENSITY_LOG_GAP: int = 120

## Which lens a --harness --visual run shows at which tick, so the reference
## scenario's own screenshots walk through the whole system instead of
## photographing the resting state seven times.
## The thresholds are chosen against what the reference run actually DOES: the
## grid splits into three networks around t6800, the deficit peaks and five
## buildings freeze after t9000. Showing the bottleneck lens while nothing is
## choking would be a screenshot of an empty claim.
const HARNESS_SCRIPT: Array[Dictionary] = [
	{"tick": 0, "mode": LcnOverlayDefs.Mode.NONE, "alt": false},
	{"tick": 1200, "mode": LcnOverlayDefs.Mode.HEAT_NETWORK, "alt": false},
	{"tick": 3000, "mode": LcnOverlayDefs.Mode.THERMAL, "alt": false},
	{"tick": 4600, "mode": LcnOverlayDefs.Mode.COVERAGE, "alt": false},
	{"tick": 6400, "mode": LcnOverlayDefs.Mode.HEAT_NETWORK, "alt": true},
	{"tick": 7600, "mode": LcnOverlayDefs.Mode.LOGISTICS, "alt": false},
	{"tick": 8600, "mode": LcnOverlayDefs.Mode.FREEZE, "alt": true},
	{"tick": 9400, "mode": LcnOverlayDefs.Mode.BOTTLENECK, "alt": false},
	{"tick": 10400, "mode": LcnOverlayDefs.Mode.FREEZE, "alt": true},
]

static var _instance: LcnOverlayRoot = null

var mode: int = LcnOverlayDefs.Mode.NONE
var alt_held: bool = false
var snap: LcnOverlaySnapshot = LcnOverlaySnapshot.new()
var pal: LcnOverlayPalette = LcnOverlayPalette.new()
## ONE arbiter for every word this part puts into world space, shared by the
## status layer and the active lens. The player sees one frame, so one frame is
## what gets budgeted — a per-layer rectangle list is exactly how a freeze lens
## temperature came to be printed over a status layer "no crew".
var field: LcnLabelField = LcnLabelField.new()

var _world: CanvasLayer = null
var _ui: CanvasLayer = null
var _legend: LcnOverlayLegend = null
var _icons: LcnStatusIcons = null
var _lenses: Dictionary[int, LcnOverlayLayer] = {}
var _camera: GameCamera = null
var _view: Rect2 = Rect2()
var _wpp: float = 1.0
var _settings_timer: float = 0.0
var _frames: int = 0
## The last footprint this part told [P17] about, so a re-solve is asked for on
## the frame the size changes and on no other frame.
var _published_size: Vector2 = Vector2.ZERO
var _sample_us: float = 0.0
var _draw_us: float = 0.0
var _keys: PackedStringArray = PackedStringArray()
var _plain_keys: Dictionary[int, int] = {}   ## keycode -> mode
var _harness_mode: int = -1
## Last lens whose density read reached the log, and the lens the field in hand
## was actually filled for. See the density block in `_process`.
var _logged_mode: int = -1
var _drawn_mode: int = -1
var _log_after: int = 3


static func instance() -> LcnOverlayRoot:
	return _instance if is_instance_valid(_instance) else null


func _ready() -> void:
	name = "OverlayRoot"
	add_to_group(GROUP)
	_instance = self
	process_priority = 40   # after the camera has settled this frame

	_world = CanvasLayer.new()
	_world.name = "OverlayWorld"
	_world.layer = LcnLayers.OVERLAY_WORLD
	_world.follow_viewport_enabled = true
	add_child(_world)

	_ui = CanvasLayer.new()
	_ui.name = "OverlayUi"
	_ui.layer = LcnLayers.OVERLAY_UI
	add_child(_ui)

	_icons = LcnStatusIcons.new()
	_world.add_child(_icons)

	_add_lens(LcnOverlayDefs.Mode.HEAT_NETWORK, LcnHeatNetworkLens.new())
	_add_lens(LcnOverlayDefs.Mode.BOTTLENECK, LcnBottleneckLens.new())
	_add_lens(LcnOverlayDefs.Mode.THERMAL, LcnThermalLens.new())
	_add_lens(LcnOverlayDefs.Mode.FREEZE, LcnFreezeLens.new())
	_add_lens(LcnOverlayDefs.Mode.LOGISTICS, LcnLogisticsLens.new())
	_add_lens(LcnOverlayDefs.Mode.COVERAGE, LcnCoverageLens.new())

	_legend = LcnOverlayLegend.new()
	_ui.add_child(_legend)

	_claim_hotkeys()
	_refresh_settings()

	Bus.world_ready.connect(_on_world_ready)
	Bus.building_placed.connect(_on_structure_changed)
	Bus.building_removed.connect(_on_structure_removed)
	Bus.network_changed.connect(_on_network_changed)
	if Sim.alive:
		_on_world_ready()
	# Read off the live nodes rather than a constant: the log's job is to say what
	# the tree actually is. Reporting an intended number is how this line kept
	# printing 70 through every launch on which boot had already corrected it.
	Log.info("overlay", "ready — 6 lenses on canvas layer %d, legend on %d, keys %s" % [
		_world.layer, _ui.layer, " ".join(_keys.slice(1))])


func _exit_tree() -> void:
	if _instance == self:
		_instance = null


# =========================================================================
# composition
# =========================================================================
#
# The legend and the lens rail are CHROME, and chrome has neighbours. This part
# used to decide where they went with two constants — a bottom clearance of 108
# measured off one 1920x1080 screenshot, and a rail top at 0.375 of the height —
# and both were wrong the moment the stores shelf changed height, the player
# scaled the interface, or anyone opened the game at 1280x720. [P17]'s
# `LcnHudLayout` now solves the whole bottom rail and the whole right column at
# once; this part publishes how much room it needs and reads back where it got.
#
# Both directions are optional. With no HUD in the build, `legend_slot` stays
# empty and the old constants still draw a legible legend.

## Screen size the legend panel wants, or ZERO when no lens is up. Read by [P17].
##
## The MODE COMES FROM THIS NODE, not from the legend's copy of it. The legend
## only learns the current mode inside `refresh()` during `_process`, so asking
## the legend answered with LAST frame's mode — and [P17] re-solves the layout on
## `Bus.overlay_mode_changed`, which fires BEFORE that. The result was a legend
## that reserved nothing on the frame it came up, fell back to its own
## `BOTTOM_CLEARANCE = 108`, and landed on [P18]'s hotkey strip. One frame of
## staleness, four thousand square pixels of overlap.
func legend_size() -> Vector2:
	if _legend == null or (mode == LcnOverlayDefs.Mode.NONE and not alt_held):
		return Vector2.ZERO
	return Vector2(LcnOverlayLegend.WIDTH, _legend.height_for(mode))


## Screen size the lens rail wants, or ZERO when no lens is up.
func rail_size() -> Vector2:
	if _legend == null or (mode == LcnOverlayDefs.Mode.NONE and not alt_held):
		return Vector2.ZERO
	return _legend.rail_size()


## Every rectangle this part draws in SCREEN space. The audit suite reads it.
func chrome_rects() -> Dictionary:
	var out: Dictionary = {}
	if _legend == null:
		return out
	if mode != LcnOverlayDefs.Mode.NONE or alt_held:
		var ls: Vector2 = legend_size()
		if ls.x > 1.0:
			# WHAT WAS PAINTED, not what was asked for. The panel records its own
			# rectangle in `_draw_panel`; this used to synthesise one from
			# `legend_size()`, which is the WANT — so the audit compared [P17]'s
			# reservation against [P17]'s reservation, agreed with itself, and
			# certified a frame in which [P18]'s hotkey strip was printed through
			# this panel's footer. `drawn_rect` is empty only before the first
			# paint, and then the computed fallback is the best answer there is.
			if _legend.drawn_rect.size.x > 1.0:
				out["legend"] = _legend.drawn_rect
			else:
				var origin: Vector2 = _legend.legend_slot.position
				if _legend.legend_slot.size.x <= 1.0:
					origin = Vector2(LcnOverlayLegend.MARGIN,
						get_viewport().get_visible_rect().size.y - ls.y
						- LcnOverlayLegend.BOTTOM_CLEARANCE)
				out["legend"] = Rect2(origin, ls)
		var rs: Vector2 = rail_size()
		if rs.x > 1.0 and _legend.rail_slot.size.x > 1.0:
			out["rail"] = Rect2(_legend.rail_slot.position, rs)
	else:
		out["lens_hint"] = _legend.hint_rect()
	return out


## Tells [P17] to re-solve the moment this part's footprint changes, instead of
## letting it find out on the next 10 Hz poll.
##
## The legend's height is CONTENT-dependent: a second heat grid appearing adds a
## grid row and the "separate grids do not share heat" warning, 42 px of panel,
## between one sample and the next. For the six frames until the next poll the
## reservation underneath it was the old one — measured at the assault beat of
## `first_night`, reserved 154 px against 185 px drawn, with [P18]'s hotkey strip
## in the gap. The legend now clamps itself to the slot rather than overrunning
## it, so those frames are a shed row instead of an overlap; this is what keeps
## the shed down to the single frame it takes [P17] to answer.
func _republish_size() -> void:
	var want: Vector2 = legend_size()
	if want.is_equal_approx(_published_size):
		return
	_published_size = want
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	for node: Node in tree.get_nodes_in_group(&"lcn_hud_chrome"):
		if node.has_method(&"request_relayout"):
			node.call(&"request_relayout")
			return


func _pull_slots() -> void:
	if _legend == null:
		return
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	for node: Node in tree.get_nodes_in_group(&"lcn_hud_chrome"):
		if not node.has_method(&"solved_rect"):
			continue
		_legend.legend_slot = node.call(&"solved_rect", &"legend") as Rect2
		_legend.rail_slot = node.call(&"solved_rect", &"rail") as Rect2
		_legend.hint_slot = node.call(&"solved_rect", &"lens_hint") as Rect2
		return


func _add_lens(m: int, lens: LcnOverlayLayer) -> void:
	lens.visible = false
	_world.add_child(lens)
	_lenses[m] = lens


# =========================================================================
# hotkeys
# =========================================================================

## F1..F6 are the canonical bindings. A bare number key is taken only when the
## integrator's table has not reserved it AND InputMap says nobody else wants it
## — [P16] owns 1/2/3 for sim speed and this part must not quietly break them.
## Whatever is actually claimed is what the on-screen rail prints, so the help
## can never lie.
##
## The table is asked FIRST and the InputMap second, because the InputMap answer
## depends on whether [P16]'s camera has installed the action map yet, and with a
## display attached this part installs itself before boot builds the camera. That
## race silently handed 1/2/3 to the lenses in every real session — see
## `LcnLayers.key_is_reserved`.
func _claim_hotkeys() -> void:
	_keys.resize(LcnOverlayDefs.MODE_COUNT)
	_plain_keys.clear()
	var numbers: Array[int] = [0, KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6]
	_keys[0] = ""
	for m: int in range(1, LcnOverlayDefs.MODE_COUNT):
		var code: int = numbers[m]
		if not LcnLayers.RESERVED_TIME.has(code) and _key_is_free(code):
			_plain_keys[code] = m
		# The RAIL always prints the F-row, because the F-row always works —
		# F1..F5 through [P16]'s action map, F6 through `_input` below — and a
		# rail that printed whichever key happened to be free came out as
		# "F1 F2 F3 4 5 6", six labels in two vocabularies, with the bottom-right
		# hint summarising them as "F1-6". A plain number key, where 1/2/3 are
		# not already the sim speeds, still toggles its lens; it is a shortcut,
		# not a second name for the same control.
		_keys[m] = "F%d" % m


static func _key_is_free(code: int) -> bool:
	var probe := InputEventKey.new()
	probe.physical_keycode = code
	probe.pressed = true
	for action: StringName in InputMap.get_actions():
		if InputMap.event_is_action(probe, action, true):
			return false
	return true


func _input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null:
		return
	if key.physical_keycode == KEY_ALT:
		alt_held = key.pressed
		return
	if not key.pressed or key.echo:
		return
	var code: int = key.physical_keycode
	if key.alt_pressed:
		var alt_mode: int = _mode_for_number(code)
		if alt_mode > 0:
			_toggle(alt_mode)
			get_viewport().set_input_as_handled()
		return
	if code == KEY_F6:
		_toggle(LcnOverlayDefs.Mode.COVERAGE)
		get_viewport().set_input_as_handled()
		return
	if _plain_keys.has(code):
		_toggle(_plain_keys[code])
		get_viewport().set_input_as_handled()


static func _mode_for_number(code: int) -> int:
	match code:
		KEY_1:
			return LcnOverlayDefs.Mode.HEAT_NETWORK
		KEY_2:
			return LcnOverlayDefs.Mode.BOTTLENECK
		KEY_3:
			return LcnOverlayDefs.Mode.THERMAL
		KEY_4:
			return LcnOverlayDefs.Mode.FREEZE
		KEY_5:
			return LcnOverlayDefs.Mode.LOGISTICS
		KEY_6:
			return LcnOverlayDefs.Mode.COVERAGE
	return 0


func _toggle(m: int) -> void:
	set_mode(LcnOverlayDefs.Mode.NONE if m == mode else m)


## Switches lens. Safe to call from [P17]/[P18] or a tutorial step.
func set_mode(m: int) -> void:
	var next: int = clampi(m, 0, LcnOverlayDefs.MODE_COUNT - 1)
	if next == mode:
		return
	mode = next
	for k: int in _lenses:
		_lenses[k].visible = k == mode
	snap.mark_dirty()
	Bus.overlay_mode_changed.emit(LcnOverlayDefs.mode_id(mode))
	Log.debug("overlay", "lens -> %s" % LcnOverlayDefs.mode_id(mode))


## Which key actually reaches a lens, for a HUD or a tutorial prompt.
func hotkey_for(m: int) -> String:
	return _keys[m] if m >= 0 and m < _keys.size() else ""


# =========================================================================
# frame
# =========================================================================

func _on_world_ready() -> void:
	snap.bind()
	snap.mark_dirty()
	_camera = GameCamera.current()
	if _camera != null and _camera.has_method(&"set_overlay_modes"):
		var ids := PackedStringArray()
		for m: int in range(1, 6):
			ids.append(String(LcnOverlayDefs.MODE_IDS[m]))
		_camera.set_overlay_modes(ids)
		if not _camera.overlay_requested.is_connected(_on_camera_overlay):
			_camera.overlay_requested.connect(_on_camera_overlay)


func _on_camera_overlay(index: int) -> void:
	set_mode(clampi(index, 0, LcnOverlayDefs.MODE_COUNT - 1))


func _on_structure_changed(_id: int, _kind: StringName, _cell: Vector2i) -> void:
	snap.mark_dirty()


func _on_structure_removed(_id: int, _cell: Vector2i) -> void:
	snap.mark_dirty()


func _on_network_changed(_nid: int) -> void:
	snap.mark_dirty()


func _process(delta: float) -> void:
	_frames += 1
	_settings_timer -= delta
	if _settings_timer <= 0.0:
		_refresh_settings()
	if not snap.alive:
		snap.bind()
		if not snap.alive:
			return
	if _camera == null or not is_instance_valid(_camera):
		_camera = GameCamera.current()
		if _camera != null:
			_on_world_ready()

	_drive_harness()
	_update_view()

	# Sim time, not wall time: a screenshot run animates identically on every
	# machine, and a determinism replay of a visual scenario stays a diff of the
	# game rather than a diff of the frame rate.
	var t: float = SimClock.seconds() + SimClock.alpha * SimClock.DT

	var sections: int = LcnOverlaySnapshot.S_HEAT | LcnOverlaySnapshot.S_BUILD
	snap.sample(SimClock.tick, sections)
	_sample_us = _sample_us * 0.9 + float(snap.last_cost_us) * 0.1
	if mode == LcnOverlayDefs.Mode.THERMAL:
		snap.sample_warmth(_view)

	var detail: int = _camera.detail_level() if _camera != null else 1
	# THE DENSITY READ, IN THE LOG, ONCE PER LENS PER RUN. A critic counted the
	# chips in one frame by hand and was right about every one of them; a build
	# that cannot count its own will let it happen again.
	#
	# Read HERE, before the budget is reopened, because the field at this instant
	# holds the frame that finished — `_process` runs before the draw, so logging
	# after `begin()` reported a census of nothing on every lens in the run, which
	# is exactly the shape of a number that looks like a pass and measures air.
	# And once per lens rather than every N frames, because "every 600 frames"
	# printed nothing at all: a visual run does not last 600 frames.
	# Throttled as well as change-driven: `tests/d7/run_layout_audit.tscn` cycles
	# every lens at every resolution and turned one line per lens into forty
	# identical ones, which is how a useful log line becomes noise a reader skips.
	if _drawn_mode == mode and mode != _logged_mode and _frames > _log_after:
		_logged_mode = mode
		_log_after = _frames + DENSITY_LOG_GAP
		Log.info("overlay", "density · %s @ zoom %.2f — %s" % [
			LcnOverlayDefs.mode_id(mode), _zoom(), field.summary()])
	_drawn_mode = mode

	# The frame's word budget is opened HERE, before either layer draws, because
	# the budget belongs to the frame and not to a layer. `_zoom()` is the same
	# number the rail prints, so the density a critic counts on screen and the
	# density this part logs are the same measurement.
	field.begin(_view, _wpp, LcnLabelField.budget_for(_zoom()), _chrome_world())
	_icons.sync(snap, pal, _view, _wpp, t, alt_held, detail, field)
	_icons.queue_redraw()
	var lens: LcnOverlayLayer = _lenses.get(mode)
	if lens != null:
		lens.sync(snap, pal, _view, _wpp, t, alt_held, detail, field)
		lens.queue_redraw()
	_pull_slots()
	_legend.refresh(pal, snap, mode, alt_held, _keys, _zoom_text())
	_republish_size()

	var us: float = float(_icons.draw_us) + (float(lens.draw_us) if lens != null else 0.0)
	_draw_us = _draw_us * 0.9 + us * 0.1
	if _frames % LOG_EVERY == 0:
		Log.info("overlay", "%s | sample %.2f ms (4 Hz) | draw %.2f ms | %d heat nodes, %d structures, %d grids" % [
			LcnOverlayDefs.mode_id(mode), _sample_us / 1000.0, _draw_us / 1000.0,
			snap.node_count, snap.bld_count, snap.nets.size()])



## Polled rather than signalled: [P24] owns Settings and has no change signal for
## accessibility yet, and twice a second is free. Every change is logged, so
## "the overlays respect the accessibility settings" is checkable in a run's log
## instead of only by looking at a screenshot.
func _refresh_settings() -> void:
	_settings_timer = SETTINGS_REFRESH
	var a: Dictionary = Settings.accessibility
	var mode: String = String(a.get("colorblind_mode", "off"))
	var contrast: bool = bool(a.get("high_contrast_overlays", false))
	var motion_off: bool = bool(a.get("reduce_motion", false))
	var before: String = "%d|%s|%s" % [pal.vision, str(pal.high_contrast), str(pal.reduce_motion)]
	pal.configure(mode, contrast, motion_off)
	var after: String = "%d|%s|%s" % [pal.vision, str(pal.high_contrast), str(pal.reduce_motion)]
	if before != after or _frames == 0:
		Log.info("overlay", "accessibility: palette=%s high_contrast=%s reduce_motion=%s" % [
			LcnOverlayPalette.vision_name(pal.vision), str(contrast), str(motion_off)])


func _update_view() -> void:
	var vp: Viewport = get_viewport()
	if vp == null:
		return
	if _camera != null and is_instance_valid(_camera):
		_view = _camera.visible_world_rect()
		_wpp = 1.0 / maxf(0.05, _camera.zoom_level())
		if _view.size.x > 1.0:
			return
	var size: Vector2 = vp.get_visible_rect().size
	var xf: Transform2D = vp.get_canvas_transform()
	_wpp = 1.0 / maxf(0.05, xf.get_scale().x)
	_view = xf.affine_inverse() * Rect2(Vector2.ZERO, size)


func _zoom() -> float:
	return 1.0 / maxf(_wpp, 0.0001)


func _zoom_text() -> String:
	if _camera == null or not is_instance_valid(_camera):
		return ""
	return "zoom %.2f (%s)" % [_camera.zoom_level(), _camera.detail_level_name()]


## EVERY RECTANGLE THE INTERFACE IS STANDING ON, IN WORLD COORDINATES.
##
## ARCHITECTURE.md §3 says a lens is paint on the ground and the ground does not
## get to cover the clock, and this part has been obeying the letter of it —
## `OVERLAY_WORLD` (62) is under `HUD` (65), boot enforces it, the reachability
## suite fails if it inverts. It was still wrong on screen. [P17]'s panels are
## translucent by design, so a world badge drawn UNDER the clock panel is a badge
## drawn THROUGH the clock panel: in `artifacts/CRIT/shots/build.png` the badge
## `= GRID 3 0/0 heat/s NO SOURCE` reads across the top of the clock and
## `| GRID 1 47/47 heat/s` collides with the "2:21" numeral, and in
## `deep_night.world.png` a `FROZEN -24°C` plate sits on the same panel. Layer
## order was never going to fix that. The pixels have to be spoken for.
##
## So the HUD's own rectangles come back here every frame and become keep-out.
## Read from [P17]'s `chrome_rects()` — WHAT IS PAINTED, not what was reserved:
## a panel that is mid-animation or has shed a row is a different rectangle from
## the one the composition solved for, and the badge lands on the paint.
##
## Mapped screen -> world through `_view` rather than through the canvas
## transform, so it agrees with the rectangle every lens is already culling
## against whether the camera answered this frame or not.
func _chrome_world() -> Array[Rect2]:
	var out: Array[Rect2] = []
	var vp: Viewport = get_viewport()
	if vp == null or _view.size.x <= 1.0:
		return out
	var screen: Vector2 = vp.get_visible_rect().size
	if screen.x < 1.0 or screen.y < 1.0:
		return out
	var k := Vector2(_view.size.x / screen.x, _view.size.y / screen.y)
	var tree: SceneTree = get_tree()
	if tree == null:
		return out
	for node: Node in tree.get_nodes_in_group(&"lcn_hud_chrome"):
		if not node.has_method(&"chrome_rects"):
			continue
		var rects: Dictionary = node.call(&"chrome_rects") as Dictionary
		var keys: Array = rects.keys()
		keys.sort()   # a keep-out list that changes order changes nothing, but a
		              # deterministic one is a diffable one
		for key: Variant in keys:
			var r: Rect2 = rects[key] as Rect2
			if r.size.x <= 1.0 or r.size.y <= 1.0:
				continue
			out.append(Rect2(_view.position + r.position * k, r.size * k))
	# This part's own chrome counts too: the legend and the lens rail are drawn
	# in screen space on OVERLAY_UI and are just as opaque to a world badge.
	for key2: Variant in ["legend", "rail", "lens_hint"]:
		var mine: Rect2 = chrome_rects().get(key2, Rect2()) as Rect2
		if mine.size.x > 1.0 and mine.size.y > 1.0:
			out.append(Rect2(_view.position + mine.position * k, mine.size * k))
	return out


## A --harness --visual run walks the lenses so the reference scenario's own
## seven screenshots cover the whole system. Never runs for a player.
func _drive_harness() -> void:
	if not (Harness.active and Harness.visual):
		return
	var tick: int = SimClock.tick
	var want: int = LcnOverlayDefs.Mode.NONE
	var want_alt: bool = false
	for entry: Dictionary in HARNESS_SCRIPT:
		if tick >= int(entry["tick"]):
			want = int(entry["mode"])
			want_alt = bool(entry["alt"])
	if want != _harness_mode:
		_harness_mode = want
		set_mode(want)
	alt_held = want_alt


# =========================================================================
# diagnostics
# =========================================================================

## Numbers a critic (or a perf gate) can read instead of a claim. Includes the
## LAST FRAME'S density read — chips, marks, overlaps, words refused and why —
## because "the lenses are legible at the zoom the game is played at" is a claim
## with a number behind it or it is a claim with nothing behind it.
func stats() -> Dictionary:
	var out: Dictionary = {
		"mode": String(LcnOverlayDefs.mode_id(mode)),
		"sample_us": int(_sample_us),
		"draw_us": int(_draw_us),
		"nodes": snap.node_count,
		"structures": snap.bld_count,
		"networks": snap.nets.size(),
		"bottlenecks": snap.bottlenecks.size(),
		"starved": snap.starved_count(),
		"frozen": snap.frozen_count(),
		"vision": LcnOverlayPalette.vision_name(pal.vision),
		"zoom": snappedf(_zoom(), 0.01),
	}
	out.merge(field.stats())
	return out
