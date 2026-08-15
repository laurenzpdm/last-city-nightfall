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
## Where the legend sits when there is NO HUD in this build to ask. It used to be
## `108`, "measured against the real stores shelf in artifacts/p00_shots" — a
## number taken off one screenshot at one resolution with one number of chips on
## the shelf, which is exactly the kind of constant that is wrong everywhere
## else. When [P17] is present the solver answers instead and this is unused.
const BOTTOM_CLEARANCE: float = 108.0
## Same contract for the lens rail: a fallback fraction, only when nobody can be
## asked where [P17]'s right column ends.
const RAIL_TOP_FRACTION: float = 0.375
const RAIL_ROW: float = 28.0
const RAIL_BOX_H: float = 24.0

## Screen rects handed down by `LcnHudLayout` through [P17]. Empty means "no HUD
## in this build" and the fallbacks above are used instead.
var legend_slot: Rect2 = Rect2()
var rail_slot: Rect2 = Rect2()
var hint_slot: Rect2 = Rect2()

## The rectangle the panel ACTUALLY painted last frame, which is what
## `chrome_rects()` publishes and what the audit measures. A part that reports
## the size it wanted rather than the size it drew cannot be audited: both
## rectangles agree, and the screen still has two things on one strip.
var drawn_rect: Rect2 = Rect2()

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
		drawn_rect = Rect2()
		_draw_hint()
		return
	_build_rows()
	_draw_panel()


# --- the always-there hint -------------------------------------------------

func _draw_hint() -> void:
	var r: Rect2 = hint_rect()
	_text(Vector2(r.position.x, r.end.y - 4.0), _hint_text(), 13,
		LcnOverlayPalette.with_a(LcnOverlayPalette.INK_DIM, 0.7))


func _hint_text() -> String:
	return "%s  overlays      ALT  details" % _key_summary()


## Where the always-there overlay reminder goes. It shares the hotkey strip's
## baseline on the opposite side of the screen when [P17] is present.
func hint_rect() -> Rect2:
	var size: Vector2 = get_viewport_rect().size
	var w: float = 200.0
	if _font != null:
		w = _font.get_string_size(_hint_text(), HORIZONTAL_ALIGNMENT_LEFT, -1.0, 13).x
	if hint_slot.size.x > 1.0:
		return Rect2(hint_slot.end.x - w, hint_slot.position.y, w, 18.0)
	return Rect2(size.x - w - MARGIN, size.y - BOTTOM_CLEARANCE - 14.0, w, 18.0)


func _key_summary() -> String:
	if keys.size() < 2:
		return "F1-F6"
	return "%s-%s" % [keys[1], keys[keys.size() - 1]]


# --- the lens rail ---------------------------------------------------------

## Screen size the lens rail needs, so [P17]'s solver can reserve it under the
## right-hand column instead of the rail guessing a fraction of the height.
func rail_size() -> Vector2:
	if _font == null:
		return Vector2(180.0, RAIL_ROW * float(LcnOverlayDefs.MODE_COUNT - 1))
	var w: float = 0.0
	for m: int in range(1, LcnOverlayDefs.MODE_COUNT):
		var key: String = keys[m] if m < keys.size() else "?"
		var text: String = "%s  %s" % [key, LcnOverlayDefs.MODE_TITLES[m]]
		w = maxf(w, _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 14).x + 18.0)
	return Vector2(w, RAIL_ROW * float(LcnOverlayDefs.MODE_COUNT - 2) + RAIL_BOX_H)


## Screen height the panel needs for `for_mode`. Takes the mode as an argument
## rather than reading `self.mode`, because the root knows the mode a frame
## before this node is told it — and the layout is solved on that earlier frame.
func height_for(for_mode: int) -> float:
	var was: int = mode
	mode = for_mode
	_build_rows()
	mode = was
	return _panel_height()


## Everything in the panel that is not a row: two pads, the title, the blurb,
## the headline and the footer. Named because two functions need it and a
## literal `122` in both is how they drift apart.
const PANEL_CHROME: float = PAD * 2.0 + 26.0 + 20.0 + 22.0 + 26.0


func _panel_height() -> float:
	return PANEL_CHROME + float(_rows.size()) * ROW


## How many rows fit in `h` screen pixels. Never below one: a legend with a
## title and no numbers is still a legend, and one with a negative row count is
## a crash.
static func rows_that_fit(h: float) -> int:
	return maxi(1, int(floorf((h - PANEL_CHROME) / ROW)))


func _draw_rail() -> void:
	var size: Vector2 = get_viewport_rect().size
	if mode == LcnOverlayDefs.Mode.NONE and not alt:
		return
	var x: float = size.x - MARGIN
	var y: float = maxf(MARGIN + 108.0, size.y * RAIL_TOP_FRACTION)
	if rail_slot.size.x > 1.0:
		x = rail_slot.end.x
		y = rail_slot.position.y
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
	var h: float = _panel_height()
	var origin := Vector2(MARGIN, size.y - h - BOTTOM_CLEARANCE)
	# THE PANEL NEVER OUTGROWS THE STRIP IT WAS GIVEN.
	#
	# `legend_size()` publishes what this panel WANTS and [P17]'s solver reserves
	# it, but the want is content-dependent — a second heat grid appearing adds
	# two rows — and the reservation is one poll behind the content. Measured in
	# `artifacts/d7/cur_1920/shots/assault.png`: reserved 154 px, drawn 185 px,
	# and the 31 px difference was [P18]'s hotkey strip printed straight through
	# this panel's own footer line. That is the exact defect `LcnHudLayout` was
	# written to kill, still on screen, and invisible to the audit because BOTH
	# rectangles it compared came from the same wrong reported height.
	#
	# So the slot is authority. When the content does not fit, rows are shed and
	# the panel says how many — a legend that is one line short is legible; a
	# legend with somebody else's hotkeys printed across it is not.
	if legend_slot.size.x > 1.0:
		origin = legend_slot.position
		var fits: int = rows_that_fit(legend_slot.size.y)
		if _rows.size() > fits:
			# `fits - 1`, because the "+N more" line is itself a row and has to
			# come out of the same budget. Keeping `fits` rows and then adding
			# the notice made the panel exactly one row taller than the strip —
			# 164 px in a 150 px slot — which the audit failed on, correctly, the
			# first time this clamp was written.
			var keep: int = maxi(0, fits - 1)
			var hidden: int = _rows.size() - keep
			_rows.resize(keep)
			# Appended directly, not through `_row`, which refuses past twelve
			# rows — the one row that must never be the one dropped is the row
			# that says rows were dropped.
			_rows.append({"text": "+%d more — %s cycles the lens" % [hidden,
				keys[mode] if mode < keys.size() else "the lens key"],
				"color": LcnOverlayPalette.with_a(LcnOverlayPalette.INK_DIM, 0.8),
				"swatch": null})
		h = _panel_height()
	var panel := Rect2(origin, Vector2(WIDTH, h))
	drawn_rect = panel
	draw_rect(panel, LcnOverlayPalette.PANEL, true)
	draw_rect(panel, LcnOverlayPalette.PANEL_EDGE, false, 1.5)
	draw_rect(Rect2(origin, Vector2(4.0, h)), _accent(), true)

	var x: float = origin.x + PAD
	var y: float = origin.y + PAD + 16.0
	var key: String = keys[mode] if mode < keys.size() else "-"
	_text(Vector2(x, y), "%s   %s" % [LcnOverlayDefs.MODE_TITLES[mode], key], 18, LcnOverlayPalette.INK)
	y += 20.0
	# Every line below is clipped to the plate. The panel is a fixed width and the
	# sentences in it are generated from live numbers, so "how wide can this get"
	# is not a question this file can answer — only "how wide is it allowed to be".
	var inner: float = WIDTH - PAD * 2.0
	_text(Vector2(x, y), LcnOverlayDefs.MODE_BLURBS[mode], 13,
		LcnOverlayPalette.with_a(LcnOverlayPalette.INK_DIM, 0.85), inner)
	y += 24.0
	if snap != null:
		_text(Vector2(x, y), snap.headline(), 15, _accent(), inner)
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
			r.get("color", LcnOverlayPalette.INK) as Color, inner - (tx - x))
		y += ROW

	var foot: String = "ALT hold: details      %s: cycle" % (keys[mode] if mode < keys.size() else "key")
	if zoom_label != "":
		foot += "      " + zoom_label
	_text(Vector2(x, origin.y + h - PAD), foot, 12,
		LcnOverlayPalette.with_a(LcnOverlayPalette.INK_DIM, 0.7), inner)


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


## `max_w` is a hard clip, not a hint: Godot's `draw_string` truncates at the
## width it is given. -1 means "no limit", which is right for the rail and the
## hint (they are sized to their own text) and wrong for a panel row, which is
## somebody's sentence about the grid inside a fixed 508 px plate. Measured in
## `fixed_1920/shots/deep_night.png`: "8 cooling toward the line; soonest is the
## coal_generator, already below the line" ran 40 px out of the right edge of
## its own panel and onto the city.
func _text(at: Vector2, text: String, size: int, c: Color, max_w: float = -1.0) -> void:
	if text == "":
		return
	_font.draw_string_outline(get_canvas_item(), at, text, HORIZONTAL_ALIGNMENT_LEFT,
		max_w, size, 4 if pal.high_contrast else 3, Color(0.0, 0.0, 0.0, 0.85))
	_font.draw_string(get_canvas_item(), at, text, HORIZONTAL_ALIGNMENT_LEFT, max_w, size, c)


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


## "1 building" / "4 buildings". THE LENS LEGEND WAS THE ONLY SURFACE IN THE GAME
## THAT WROTE "(s)".
##
## Eleven rows of it — "89 node(s)", "8 turret(s)", "5 chokepoint(s)",
## "23 damaged structure(s)" — against a HUD, a build sheet and a narrative layer
## that all inflect properly and have helpers for it
## (`LcnHudFormat.in_words`, `bottleneck_sentence`). It reads as a debug print
## sitting inside the one panel whose entire job is to make a screenshot of this
## game diagnosable, which is exactly where a form-feed voice does most damage.
static func _n(count: int, word: String, plural: String = "") -> String:
	if count == 1:
		return "1 %s" % word
	return "%d %s" % [count, plural if plural != "" else word + "s"]


## Never an id. `String(kind)` put "turret_mount" and "coal_generator" into the
## freeze and bottleneck rows — `LcnHudFormat` opens with "Never print an id" and
## carries the registry lookup that makes it possible, and this panel simply was
## not calling it.
static func _title(kind: StringName) -> String:
	return LcnHudFormat.building_title(kind)


func _rows_summary() -> void:
	var t: Dictionary = snap.totals
	_row("%s on %s" % [_n(snap.node_count, "building"), _n(snap.nets.size(), "grid")])
	_row("delivered %.0f of %.0f heat/s, loss %.0f" % [
		float(t.get("delivered", 0.0)), float(t.get("demand", 0.0)), float(t.get("loss", 0.0))])


func _rows_networks() -> void:
	if snap.nets.is_empty():
		_row("no heat network yet — place a hearth and run a pipe", pal.warn())
		return
	for n: Dictionary in snap.nets:
		var slot: int = int(n.get("slot", 0))
		var deficit: float = float(n.get("deficit", 0.0))
		var producers: int = int(n.get("producers", 0))
		var text: String = "%s GRID %d   %.0f/%.0f heat/s   %s" % [
			pal.network_mark(slot), int(n.get("id", 0)),
			float(n.get("delivered", 0.0)), float(n.get("demand", 0.0)),
			_n(int(n.get("nodes", 0)), "node")]
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
	# A GRID THAT IS OUT OF HEAT IS ONE FACT, NOT THREE.
	#
	# [P02] attributes a `supply` bottleneck to every consumer cluster it choked,
	# so a single starved grid arrives here as several rows — and they were worded
	# identically, which is how `artifacts/play1/shots/dawn.png` came to print
	#   grid 1 generating everything it has — 10 draw on it
	#   grid 1 generating everything it has — 8 draw on it
	#   grid 1 generating everything it has — 3 draw on it
	# three lines that read as a stutter and cost the panel three of its twelve
	# rows to say one thing. Capacity bottlenecks stay one row each: those really
	# are different tiles and the tile is the whole point.
	var starving: Dictionary[int, int] = {}
	for b: Dictionary in snap.bottlenecks:
		var cell: Array = b.get("cell", [0, 0])
		if String(b.get("reason", "")) == "capacity":
			_row("%s (%d, %d) at capacity %.0f/%.0f heat/s — %d draw through it" % [
				_title(StringName(String(b.get("kind", "line")))),
				int(cell[0]), int(cell[1]),
				float(b.get("load", 0.0)), float(b.get("capacity", 0.0)),
				int(b.get("consumers", 0))], pal.bad())
		else:
			var net: int = int(b.get("net", 0))
			starving[net] = int(starving.get(net, 0)) + int(b.get("consumers", 0))
	var nets: Array = starving.keys()
	nets.sort()
	for net2: int in nets:
		_row("grid %d is generating everything it has — %s drawing on it" % [
			net2, _n(int(starving[net2]), "building")], pal.bad())
	var starved: int = snap.starved_count()
	if starved > 0:
		_row("%s below full heat; ring size is how short" % _n(starved, "building"),
			pal.warn())


func _rows_thermal() -> void:
	_row("outside air %.0f°C" % snap.ambient_c, pal.ice())
	_row("warmest tile on screen %.0f°C" % snap.warm_max, pal.warn())
	_row("survival line %.0f°C — outside it a working building freezes" % LcnThermalLens.SURVIVAL_C,
		pal.ice())
	_row("comfort line +%.0f°C — below it every building costs more heat" % LcnThermalLens.COMFORT_C,
		pal.good())
	_row("palette: %s" % LcnOverlayPalette.vision_name(pal.vision),
		LcnOverlayPalette.with_a(LcnOverlayPalette.INK_DIM, 0.8))


func _rows_freeze() -> void:
	var frozen: int = snap.frozen_count()
	if frozen > 0:
		_row("%s frozen — %s nothing until %s thaw%s" % [_n(frozen, "building"),
			"it does" if frozen == 1 else "they do",
			"it" if frozen == 1 else "they", "s" if frozen == 1 else ""], pal.ice())
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
		var when: String = "already below it"
		if worst >= 1.0:
			when = "in %ds" % int(round(worst))
		# Short enough to survive the 508 px plate. The old sentence ran off the
		# right edge and `_text`'s hard clip cut it mid-word — "already below t" —
		# which is a clip working exactly as designed on a sentence nobody sized.
		_row("%s cooling toward the line; %s %s" % [_n(soon, "building"),
			_title(worst_kind).to_lower(), when], pal.bad())
	elif frozen == 0:
		_row("nothing is freezing", pal.good())
	_row("gauge tick = that building's own freeze point", LcnOverlayPalette.INK_DIM)
	var damaged: int = 0
	for j: int in snap.bld_count:
		if snap.bld_hp[j] < 0.999:
			damaged += 1
	if damaged > 0:
		_row(_n(damaged, "damaged structure"), pal.warn())


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
	_row("%s: %d out of fuel, %d running low" % [_n(burners, "generator"), dry, low],
		pal.bad() if dry > 0 else (pal.warn() if low > 0 else pal.good()))
	if probe.has_stalls():
		var stalls: int = probe.stalls().size()
		_row("%s stalled" % _n(stalls, "machine"), pal.bad() if stalls > 0 else pal.good())


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
		_row("%s, longest reach %.0f tiles" % [_n(turrets, "turret"), reach], pal.good())
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
		_row("%s on no grid at all (hatched)" % _n(unpowered, "structure"), pal.bad())
	if snap.grid != null:
		_row("%s marked on the approach lanes" % _n(snap.grid.chokepoints().size(), "chokepoint"),
			LcnOverlayPalette.INK_DIM)
