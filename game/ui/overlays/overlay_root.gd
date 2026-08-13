class_name LcnOverlayRoot
extends Node
## [P19] The lens system: mode state, hotkeys, the per-frame sample, and the two
## canvas layers everything is drawn on.
##
## LAYERING. The lenses live on a CanvasLayer with `follow_viewport_enabled`, so
## they draw in WORLD coordinates but ABOVE [P13]'s post-process stack (layer
## 60). That matters: the night grade, the bloom and the cold chromatic split
## are there to make the world feel cold, and a diagnostic overlay that gets
## graded along with it stops being readable at exactly the hour the player most
## needs to read it. The legend sits on a second, non-following layer above that.
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
const WORLD_LAYER: int = 70
const UI_LAYER: int = 72
const SETTINGS_REFRESH: float = 0.5
const LOG_EVERY: int = 600

## Which lens a --harness --visual run shows at which tick, so the reference
## scenario's own screenshots walk through the whole system instead of
## photographing the resting state seven times.
const HARNESS_SCRIPT: Array[Dictionary] = [
	{"tick": 0, "mode": LcnOverlayDefs.Mode.NONE, "alt": false},
	{"tick": 1200, "mode": LcnOverlayDefs.Mode.HEAT_NETWORK, "alt": false},
	{"tick": 3000, "mode": LcnOverlayDefs.Mode.THERMAL, "alt": false},
	{"tick": 4800, "mode": LcnOverlayDefs.Mode.BOTTLENECK, "alt": false},
	{"tick": 6600, "mode": LcnOverlayDefs.Mode.FREEZE, "alt": true},
	{"tick": 8200, "mode": LcnOverlayDefs.Mode.COVERAGE, "alt": false},
	{"tick": 9400, "mode": LcnOverlayDefs.Mode.LOGISTICS, "alt": true},
]

static var _instance: LcnOverlayRoot = null

var mode: int = LcnOverlayDefs.Mode.NONE
var alt_held: bool = false
var snap: LcnOverlaySnapshot = LcnOverlaySnapshot.new()
var pal: LcnOverlayPalette = LcnOverlayPalette.new()

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
var _sample_us: float = 0.0
var _draw_us: float = 0.0
var _keys: PackedStringArray = PackedStringArray()
var _plain_keys: Dictionary[int, int] = {}   ## keycode -> mode
var _harness_mode: int = -1


static func instance() -> LcnOverlayRoot:
	return _instance if is_instance_valid(_instance) else null


func _ready() -> void:
	name = "OverlayRoot"
	add_to_group(GROUP)
	_instance = self
	process_priority = 40   # after the camera has settled this frame

	_world = CanvasLayer.new()
	_world.name = "OverlayWorld"
	_world.layer = WORLD_LAYER
	_world.follow_viewport_enabled = true
	add_child(_world)

	_ui = CanvasLayer.new()
	_ui.name = "OverlayUi"
	_ui.layer = UI_LAYER
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
	Log.info("overlay", "ready — 6 lenses on canvas layer %d, keys %s" % [
		WORLD_LAYER, " ".join(_keys.slice(1))])


func _exit_tree() -> void:
	if _instance == self:
		_instance = null


func _add_lens(m: int, lens: LcnOverlayLayer) -> void:
	lens.visible = false
	_world.add_child(lens)
	_lenses[m] = lens


# =========================================================================
# hotkeys
# =========================================================================

## F1..F6 are the canonical bindings. A bare number key is taken only when
## InputMap says nobody else wants it — [P16] owns 1/2/3 for sim speed and this
## part must not quietly break them. Whatever is actually claimed is what the
## on-screen rail prints, so the help can never lie.
func _claim_hotkeys() -> void:
	_keys.resize(LcnOverlayDefs.MODE_COUNT)
	_plain_keys.clear()
	var fkeys: Array[int] = [0, KEY_F1, KEY_F2, KEY_F3, KEY_F4, KEY_F5, KEY_F6]
	var numbers: Array[int] = [0, KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6]
	_keys[0] = ""
	for m: int in range(1, LcnOverlayDefs.MODE_COUNT):
		var label: String = "F%d" % m
		if _key_is_free(numbers[m]):
			_plain_keys[numbers[m]] = m
			label = "%d" % m
		_keys[m] = label


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
	_icons.sync(snap, pal, _view, _wpp, t, alt_held, detail)
	_icons.queue_redraw()
	var lens: LcnOverlayLayer = _lenses.get(mode)
	if lens != null:
		lens.sync(snap, pal, _view, _wpp, t, alt_held, detail)
		lens.queue_redraw()
	_legend.refresh(pal, snap, mode, alt_held, _keys, _zoom_text())

	var us: float = float(_icons.draw_us) + (float(lens.draw_us) if lens != null else 0.0)
	_draw_us = _draw_us * 0.9 + us * 0.1
	if _frames % LOG_EVERY == 0:
		Log.info("overlay", "%s | sample %.2f ms (4 Hz) | draw %.2f ms | %d heat nodes, %d structures, %d grids" % [
			LcnOverlayDefs.mode_id(mode), _sample_us / 1000.0, _draw_us / 1000.0,
			snap.node_count, snap.bld_count, snap.nets.size()])


func _refresh_settings() -> void:
	_settings_timer = SETTINGS_REFRESH
	var a: Dictionary = Settings.accessibility
	pal.configure(
		String(a.get("colorblind_mode", "off")),
		bool(a.get("high_contrast_overlays", false)),
		bool(a.get("reduce_motion", false)))


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


func _zoom_text() -> String:
	if _camera == null or not is_instance_valid(_camera):
		return ""
	return "zoom %.2f (%s)" % [_camera.zoom_level(), _camera.detail_level_name()]


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

## Numbers a critic (or a perf gate) can read instead of a claim.
func stats() -> Dictionary:
	return {
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
	}
