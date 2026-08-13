class_name LcnOverlayLegend
extends Control
## [P19] The key. Screen space, above the post-process, never scaled by zoom.
##
## A lens without a legend is a colour wash. This panel is what makes a
## screenshot of this game diagnosable by someone who has never played it: the
## name of the lens, one sentence saying what it shows, the single worst thing
## currently happening to the grid in plain words, and then the actual numbers
## the simulation used to decide that.
##
## It is also the hotkey teacher: every lens is listed with the key that reaches
## it, the active one highlighted, and the list is built from the keys the
## overlay root really managed to claim rather than from a comment.

const PAD: float = 14.0
const WIDTH: float = 508.0
const ROW: float = 21.0
const MARGIN: float = 22.0
## The panel sits this far off the bottom edge, leaving [P17]'s HUD strip room
## to exist underneath it instead of fighting it for the same pixels.
const BOTTOM_CLEARANCE: float = 78.0

var pal: LcnOverlayPalette = null
var snap: LcnOverlaySnapshot = null
var mode: int = LcnOverlayDefs.Mode.NONE
var alt: bool = false
var keys: PackedStringArray = PackedStringArray()
var zoom_label: String = ""

var _font: Font = null
var _rows: Array[Dictionary] = []


func _init() -> void:
	name = "OverlayLegend"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_font = ThemeDB.fallback_font


func refresh(p: LcnOverlayPalette, s: LcnOverlaySnapshot, m: int, alt_held: bool,
		hotkeys: PackedStringArray, zoom_text: String) -> void:
	pal = p
	snap = s
	mode = m
	alt = alt_held
	keys = hotkeys
	zoom_label = zoom_text
	queue_redraw()


func _draw() -> void:
	if pal == null or _font == null:
		return
	_draw_rail()
	if mode == LcnOverlayDefs.Mode.NONE and not alt:
		_draw_hint()
		return
	_build_rows()
	_draw_panel()


# --- the always-there hint -------------------------------------------------

func _draw_hint() -> void:
	var size: Vector2 = get_viewport_rect().size
	var text: String = "%s  overlays      ALT  details" % _key_summary()
	var w: float = _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 13).x
	_text(Vector2(size.x - w - MARGIN, size.y - BOTTOM_CLEARANCE), text, 13,
		LcnOverlayPalette.with_a(LcnOverlayPalette.INK_DIM, 0.7))


func _key_summary() -> String:
	if keys.size() < 2:
		return "F1-F6"
	return "%s-%s" % [keys[1], keys[keys.size() - 1]]


# --- the lens rail ---------------------------------------------------------

func _draw_rail() -> void:
	var size: Vector2 = get_viewport_rect().size
	if mode == LcnOverlayDefs.Mode.NONE and not alt:
		return
	var x: float = size.x - MARGIN
	var y: float = MARGIN + 108.0     # under the [P17]/play HUD strip
	for m: int in range(1, LcnOverlayDefs.MODE_COUNT):
		var active: bool = m == mode
		var key: String = keys[m] if m < keys.size() else "?"
		var text: String = "%s  %s" % [key, LcnOverlayDefs.MODE_TITLES[m]]
		var w: float = _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 14).x
		var box := Rect2(Vector2(x - w - 18.0, y), Vector2(w + 18.0, 24.0))
		draw_rect(box, Color(0.02, 0.035, 0.063, 0.86 if active else 0.5), true)
		if active:
			draw_rect(box, LcnOverlayPalette.with_a(pal.good(), 0.9), false, 1.6)
			draw_rect(Rect2(box.position, Vector2(3.0, box.size.y)), pal.good(), true)
		_text(box.position + Vector2(11.0, 17.0), text, 14,
			LcnOverlayPalette.INK if active else LcnOverlayPalette.with_a(LcnOverlayPalette.INK_DIM, 0.75))
		y += 28.0


# --- the panel -------------------------------------------------------------

func _draw_panel() -> void:
	var size: Vector2 = get_viewport_rect().size
	var h: float = PAD * 2.0 + 26.0 + 20.0 + 22.0 + float(_rows.size()) * ROW + 26.0
	var origin := Vector2(MARGIN, size.y - h - BOTTOM_CLEARANCE)
	var panel := Rect2(origin, Vector2(WIDTH, h))
	draw_rect(panel, LcnOverlayPalette.PANEL, true)
	draw_rect(panel, LcnOverlayPalette.PANEL_EDGE, false, 1.5)
	draw_rect(Rect2(origin, Vector2(4.0, h)), _accent(), true)

	var x: float = origin.x + PAD
	var y: float = origin.y + PAD + 16.0
	var key: String = keys[mode] if mode < keys.size() else "-"
	_text(Vector2(x, y), "%s   %s" % [LcnOverlayDefs.MODE_TITLES[mode], key], 18, LcnOverlayPalette.INK)
	y += 20.0
	_text(Vector2(x, y), LcnOverlayDefs.MODE_BLURBS[mode], 13,
		LcnOverlayPalette.with_a(LcnOverlayPalette.INK_DIM, 0.85))
	y += 24.0
	if snap != null:
		_text(Vector2(x, y), snap.headline(), 15, _accent())
	y += 20.0

	for r: Dictionary in _rows:
		var swatch: Variant = r.get("swatch")
		var tx: float = x
		if swatch != null:
			var c: Color = swatch
			var sw := Rect2(Vector2(x, y - 10.0), Vector2(22.0, 12.0))
			draw_rect(sw, c, true)
			draw_rect(sw, LcnOverlayPalette.with_a(LcnOverlayPalette.INK, 0.35), false, 1.0)
			tx += 30.0
		_text(Vector2(tx, y), String(r.get("text", "")), 14,
			r.get("color", LcnOverlayPalette.INK) as Color)
		y += ROW

	var foot: String = "ALT hold: details      %s: cycle" % (keys[mode] if mode < keys.size() else "key")
	if zoom_label != "":
		foot += "      " + zoom_label
	_text(Vector2(x, origin.y + h - PAD), foot, 12,
		LcnOverlayPalette.with_a(LcnOverlayPalette.INK_DIM, 0.7))


## Red is reserved for something the player is actually LOSING. A binding
## constraint that thermal mass is still covering is amber: crying wolf on the
## headline is how a player learns to stop reading it.
func _accent() -> Color:
	if snap == null:
		return pal.good()
	if snap.frozen_count() > 0 or float(snap.totals.get("deficit", 0.0)) > 0.5:
		return pal.bad()
	if snap.starved_count() > 0 or not snap.bottlenecks.is_empty():
		return pal.warn()
	return pal.good()


func _text(at: Vector2, text: String, size: int, c: Color) -> void:
	if text == "":
		return
	_font.draw_string_outline(get_canvas_item(), at, text, HORIZONTAL_ALIGNMENT_LEFT,
		-1.0, size, 4 if pal.high_contrast else 3, Color(0.0, 0.0, 0.0, 0.85))
	_font.draw_string(get_canvas_item(), at, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size, c)


# --- rows per lens ---------------------------------------------------------

func _build_rows() -> void:
	_rows.clear()
	if snap == null:
		return
	match mode:
		LcnOverlayDefs.Mode.HEAT_NETWORK:
			_rows_networks()
		LcnOverlayDefs.Mode.BOTTLENECK:
			_rows_bottlenecks()
		LcnOverlayDefs.Mode.THERMAL:
			_rows_thermal()
		LcnOverlayDefs.Mode.FREEZE:
			_rows_freeze()
		LcnOverlayDefs.Mode.LOGISTICS:
			_rows_logistics()
		LcnOverlayDefs.Mode.COVERAGE:
			_rows_coverage()
		_:
			_rows_summary()


func _row(text: String, c: Color = LcnOverlayPalette.INK, swatch: Variant = null) -> void:
	if _rows.size() >= 12:
		return
	_rows.append({"text": text, "color": c, "swatch": swatch})


func _rows_summary() -> void:
	var t: Dictionary = snap.totals
	_row("%d building(s) on %d grid(s)" % [snap.node_count, snap.nets.size()])
	_row("delivered %.0f of %.0f u/s, loss %.0f" % [
		float(t.get("delivered", 0.0)), float(t.get("demand", 0.0)), float(t.get("loss", 0.0))])


func _rows_networks() -> void:
	if snap.nets.is_empty():
		_row("no heat network yet — place a hearth and run a pipe", pal.warn())
		return
	for n: Dictionary in snap.nets:
		var slot: int = int(n.get("slot", 0))
		var deficit: float = float(n.get("deficit", 0.0))
		var producers: int = int(n.get("producers", 0))
		var text: String = "%s GRID %d   %.0f/%.0f u/s   %d node(s)" % [
			pal.network_mark(slot), int(n.get("id", 0)),
			float(n.get("delivered", 0.0)), float(n.get("demand", 0.0)),
			int(n.get("nodes", 0))]
		var c: Color = LcnOverlayPalette.INK
		if producers == 0:
			text += "   NO SOURCE"
			c = pal.bad()
		elif deficit > 0.5:
			text += "   short %.0f" % deficit
			c = pal.bad()
		elif float(n.get("buffer", 0.0)) > 0.0:
			text += "   buffer %.0f" % float(n.get("buffer", 0.0))
		_row(text, c, pal.network_color(slot))
	if snap.nets.size() > 1:
		_row("separate grids do not share heat", pal.warn())


func _rows_bottlenecks() -> void:
	if snap.bottlenecks.is_empty():
		_row("nothing is choking the grid right now", pal.good())
	for b: Dictionary in snap.bottlenecks:
		var cell: Array = b.get("cell", [0, 0])
		if String(b.get("reason", "")) == "capacity":
			_row("%s (%d, %d) at capacity %.0f/%.0f u/s — %d draw through it" % [
				String(b.get("kind", "line")), int(cell[0]), int(cell[1]),
				float(b.get("load", 0.0)), float(b.get("capacity", 0.0)),
				int(b.get("consumers", 0))], pal.bad())
		else:
			_row("grid %d generating everything it has — %d draw on it" % [
				int(b.get("net", 0)), int(b.get("consumers", 0))], pal.bad())
	var starved: int = snap.starved_count()
	if starved > 0:
		_row("%d building(s) below full heat; ring size is how short" % starved, pal.warn())


func _rows_thermal() -> void:
	_row("outside air %.0f C" % snap.ambient_c, pal.ice())
	_row("warmest tile on screen %.0f C" % snap.warm_max, pal.warn())
	_row("survival line %.0f C — outside it a working building freezes" % LcnThermalLens.SURVIVAL_C,
		pal.ice())
	_row("comfort line +%.0f C — below it every building costs more heat" % LcnThermalLens.COMFORT_C,
		pal.good())
	_row("palette: %s" % LcnOverlayPalette.vision_name(pal.vision),
		LcnOverlayPalette.with_a(LcnOverlayPalette.INK_DIM, 0.8))


func _rows_freeze() -> void:
	var frozen: int = snap.frozen_count()
	if frozen > 0:
		_row("%d building(s) frozen — they do nothing until they thaw" % frozen, pal.ice())
	var soon: int = 0
	var worst: float = 1.0e9
	var worst_kind: StringName = &""
	for i: int in snap.node_count:
		var eta: float = snap.freeze_eta(i)
		if eta < 0.0 or eta > LcnFreezeLens.ALARM_SECONDS:
			continue
		soon += 1
		if eta < worst:
			worst = eta
			worst_kind = snap.node_kind[i]
	if soon > 0:
		var when: String = "already below the line"
		if worst >= 1.0:
			when = "in %ds" % int(round(worst))
		_row("%d cooling toward the line; soonest is the %s, %s" % [
			soon, String(worst_kind), when], pal.bad())
	elif frozen == 0:
		_row("nothing is freezing", pal.good())
	_row("gauge tick = that building's own freeze point", LcnOverlayPalette.INK_DIM)
	var damaged: int = 0
	for j: int in snap.bld_count:
		if snap.bld_hp[j] < 0.999:
			damaged += 1
	if damaged > 0:
		_row("%d damaged structure(s)" % damaged, pal.warn())


func _rows_logistics() -> void:
	var probe: LcnOverlayProbe = snap.probe
	if not probe.has_logistics():
		_row("no belt system in this build yet — showing fuel only", pal.warn())
	var burners: int = 0
	var dry: int = 0
	var low: int = 0
	for i: int in snap.node_count:
		if (snap.node_flags[i] & LcnOverlayDefs.F_PRODUCER) == 0:
			continue
		burners += 1
		if (snap.node_flags[i] & LcnOverlayDefs.F_STARVED_FUEL) != 0:
			dry += 1
		elif snap.node_fuel[i] < LcnLogisticsLens.BUNKER_LOW:
			low += 1
	_row("%d generator(s): %d out of fuel, %d running low" % [burners, dry, low],
		pal.bad() if dry > 0 else (pal.warn() if low > 0 else pal.good()))
	if probe.has_stalls():
		var stalls: int = probe.stalls().size()
		_row("%d machine(s) stalled" % stalls, pal.bad() if stalls > 0 else pal.good())


func _rows_coverage() -> void:
	var turrets: int = 0
	var reach: float = 0.0
	for i: int in snap.bld_count:
		if (snap.bld_flags[i] & LcnOverlaySnapshot.B_TURRET) != 0:
			turrets += 1
			reach = maxf(reach, snap.bld_reach[i])
	if turrets == 0:
		_row("no turrets built", pal.warn())
	else:
		_row("%d turret(s), longest reach %.0f tiles" % [turrets, reach], pal.good())
	if not snap.probe.has_combat():
		_row("no combat system yet — reach is the weapon definition, unverified",
			LcnOverlayPalette.INK_DIM)
	if not snap.probe.has_citizens():
		_row("no citizen system yet — crew coverage unavailable",
			LcnOverlayPalette.INK_DIM)
	var unpowered: int = 0
	for j: int in snap.node_count:
		var f: int = snap.node_flags[j]
		if (f & LcnOverlayDefs.F_CONSUMER) == 0:
			continue
		if (f & LcnOverlayDefs.F_NO_NETWORK) != 0 or (f & LcnOverlayDefs.F_UNREACHABLE) != 0:
			unpowered += 1
	if unpowered > 0:
		_row("%d structure(s) on no grid at all (hatched)" % unpowered, pal.bad())
	if snap.grid != null:
		_row("%d chokepoint(s) marked on the approach lanes" % snap.grid.chokepoints().size(),
			LcnOverlayPalette.INK_DIM)
