class_name PlayHud
extends CanvasLayer
## The minimum read-out a player needs to make a decision. INTEGRATOR-OWNED.
##
## Four lines, all read straight out of the simulation every frame:
##   * the clock and the cold — day, phase, seconds to nightfall, air temperature
##   * the grid — supply vs demand, deficit, how many networks, how many frozen
##   * the hands — build mode, the selected building, why the ghost is red
##   * the controls, because a build nobody can operate is not playable
##
## [P17] replaces this with the real HUD. Everything here is derived, never
## cached, so it cannot drift from the sim it describes.

const MARGIN: float = 18.0

var _clock: Label = null
var _grid_line: Label = null
var _hands: Label = null
var _help: Label = null
var _panel: ColorRect = null
var _alerts: Label = null
var _alert_until: float = 0.0


func _ready() -> void:
	name = "PlayHud"
	layer = 10

	_panel = ColorRect.new()
	_panel.color = Color(0.03, 0.045, 0.075, 0.62)
	_panel.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_panel.offset_bottom = 96.0
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)

	_clock = _make_label(Vector2(MARGIN, 10.0), 20, Color(0.93, 0.95, 1.0))
	_grid_line = _make_label(Vector2(MARGIN, 36.0), 16, Color(0.98, 0.78, 0.46))
	_hands = _make_label(Vector2(MARGIN, 58.0), 16, Color(0.72, 0.84, 0.98))
	_help = _make_label(Vector2(MARGIN, 78.0), 13, Color(0.55, 0.63, 0.76))
	_help.text = "B build   Q/E pick   R rotate   drag to lay a line   X demolish   " \
		+ "WASD pan   wheel zoom   H home   Space pause   1/2/3 speed"

	_alerts = _make_label(Vector2(MARGIN, 112.0), 16, Color(1.0, 0.55, 0.42))
	Bus.alert_raised.connect(_on_alert)


func _make_label(pos: Vector2, size: int, colour: Color) -> Label:
	var l := Label.new()
	l.position = pos
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", colour)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("shadow_offset_y", 2)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(l)
	return l


func _on_alert(_severity: int, _key: StringName, text: String, _pos: Vector2) -> void:
	_alerts.text = text
	_alert_until = SimClock.seconds() + 6.0


func refresh(play: PlayController) -> void:
	var climate: SimSystem = Sim.get_system(&"climate")
	var heat: SimSystem = Sim.get_system(&"heat")
	var build: SimSystem = Sim.get_system(&"build")

	if climate != null:
		var to_night: float = float(climate.call("seconds_until_night"))
		var when: String = "nightfall in %d:%02d" % [int(to_night) / 60, int(to_night) % 60] \
			if to_night > 0.0 else "dawn in %d:%02d" % [
				int(float(climate.call("seconds_until_dawn"))) / 60,
				int(float(climate.call("seconds_until_dawn"))) % 60]
		_clock.text = "Day %d — %s — %.0f C — %s" % [
			int(climate.call("day")), String(climate.call("phase_label")),
			float(climate.call("ambient_temperature")), when,
		]
	else:
		_clock.text = "Last City: Nightfall"

	if heat != null:
		var t: Dictionary = heat.call("totals")
		_grid_line.text = "Heat %.0f / %.0f u/s   deficit %.0f   loss %.0f   buffer %.0f   networks %d   frozen %d" % [
			float(t.get("delivered", 0.0)), float(t.get("demand", 0.0)),
			float(t.get("deficit", 0.0)), float(t.get("loss", 0.0)),
			float(t.get("buffer", 0.0)), int(t.get("networks", 0)), int(t.get("frozen", 0)),
		]
	else:
		_grid_line.text = ""

	var parts: PackedStringArray = PackedStringArray()
	if play.build_mode:
		parts.append("BUILD: %s" % play.palette_label())
		var why: String = play.ghost_reason()
		if why != "":
			parts.append("cannot place — %s" % why)
	else:
		parts.append("cell %s" % str(play.hovered_cell()))
	var info: String = play.inspect()
	if info != "":
		parts.append(info)
	if build != null:
		parts.append("scrap %d  steel %d  stone %d" % [
			int(build.get("stock").call("count", &"scrap")),
			int(build.get("stock").call("count", &"steel")),
			int(build.get("stock").call("count", &"stone")),
		])
	_hands.text = "   |   ".join(parts)

	if SimClock.seconds() > _alert_until:
		_alerts.text = ""
