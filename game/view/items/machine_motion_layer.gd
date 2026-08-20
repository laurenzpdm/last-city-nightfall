class_name LcnMachineMotionLayer
extends LcnItemDrawLayer
## [D2] THE MOVING PARTS: ARMS, SPLITTERS, AND THE TWO ENDS OF AN UNDERGROUND.
##
## [P03] already swings its arms. `LogiInserter` runs a three-phase cycle with a
## real timer, its own doc comment says "the cycle is deliberately visible,
## because an inserter is the part of a factory a player watches to understand
## why a machine is idle" — and until this file the swing existed only in
## `state.json`. This draws it.
##
## THE ARM. The angle comes straight out of the phase and the timer, sub-tick
## interpolated, so a swing is a swing and not a twelve-step staircase:
##
##   WAITING          parked over the source. Nothing to pick up.
##   OUT,  timer > 0  crossing, carrying a hand of items in the item's colour.
##   OUT,  timer = 0  STUCK AT THE FAR END, still holding. The single most
##                    useful tell in a factory — the machine in front is full
##                    or dead — and it is drawn as exactly that: an arm frozen
##                    over its target with a hand it cannot put down.
##   BACK             returning empty.
##
## THE SPLITTER shows which output takes the next item and how much it is
## holding, so an unbalanced split is visible without opening a panel.
##
## THE UNDERGROUND is the one place items genuinely vanish — `items_for_view()`
## skips tunnel segments because there is nowhere on screen to put them — so the
## mouths swallow and spit, and a scrolling dashed trace runs between them
## carrying the tunnel's own load. Without it a sunken belt looks like two
## unrelated stubs with a hole between them.

const COL_STEEL: Color = Color(0.74, 0.78, 0.86)
const COL_HUB: Color = Color(0.30, 0.33, 0.40)
const COL_IDLE: Color = Color(0.44, 0.50, 0.60)
## An arm holding a hand it cannot put down.
const COL_BLOCKED: Color = Color(1.0, 0.55, 0.18)
const COL_TUNNEL: Color = Color(0.62, 0.72, 0.92)
const COL_SPLIT_NEXT: Color = Color(1.0, 0.80, 0.42)

## Ticks of doing nothing after which an arm is drawn as idle. Matches
## `LogiWorld.IDLE_POLL_AFTER`, which is when [P03] itself stops asking.
const IDLE_AFTER: int = 20
## Below this many screen pixels per tile a one-tile machine is not a machine,
## it is a speck. Everything here stops at that point.
const MIN_TILE_PX: float = 7.0

var arms_drawn: int = 0
var splitters_drawn: int = 0
var tunnels_drawn: int = 0


func _init() -> void:
	super()
	name = "MachineMotion"
	var mat := CanvasItemMaterial.new()
	mat.light_mode = CanvasItemMaterial.LIGHT_MODE_UNSHADED
	material = mat


func _draw() -> void:
	arms_drawn = 0
	splitters_drawn = 0
	tunnels_drawn = 0
	drawn = 0
	if read == null:
		draw_us = 0
		return
	var t0: int = Time.get_ticks_usec()
	tris_reset()
	lines_reset()

	# Tunnels first: the trace belongs under the mouths that feed it.
	for t: Dictionary in read.tunnels:
		_tunnel(t)
	if TILE * zoom >= MIN_TILE_PX:
		for sp: Dictionary in read.splitters:
			_splitter(sp)
		for a: Dictionary in read.arms:
			_arm(a)

	tris_flush()
	lines_flush(maxf(wpx(1.5), 0.6))
	drawn = arms_drawn + splitters_drawn + tunnels_drawn
	draw_us = Time.get_ticks_usec() - t0


# --------------------------------------------------------------------- arms --

## Where an arm is in its swing, 0 at the source and 1 at the target.
## `timer` is what [P03] left on the clock at the end of the last tick; the view
## spends `alpha` of a tick more of it, which is what makes the swing smooth
## instead of stepping twenty times a second.
static func swing_fraction(phase: int, timer: float, half: float, alpha_t: float) -> float:
	var left: float = timer - alpha_t * SimClock.DT
	var done: float = 1.0 if left <= 0.0 else clampf(1.0 - left / maxf(half, 0.0001), 0.0, 1.0)
	match phase:
		LogiInserter.Phase.OUT:
			return done
		LogiInserter.Phase.BACK:
			return 1.0 - done
	return 0.0


func _arm(a: Dictionary) -> void:
	var hub: Vector2 = LogiTypes.cell_center(a["cell"])
	if not on_screen(hub, TILE * 2.0):
		return
	var from: Vector2 = LogiTypes.cell_center(a["from"])
	var reach: float = maxf(from.distance_to(hub), TILE * 0.5)
	var frac: float = swing_fraction(int(a["phase"]), float(a["timer"]), float(a["half"]), alpha)
	# Always the same way round the circle, so an arm never appears to snap back
	# through the machine it just crossed.
	var ang: float = (from - hub).angle() + PI * frac
	var hand: Vector2 = hub + Vector2(cos(ang), sin(ang)) * (reach * 0.84)

	var held: int = int(a["held"])
	var idle: int = int(a["idle"])
	var stuck: bool = held > 0 and idle >= 1
	var col: Color = COL_STEEL
	if not bool(a["enabled"]):
		col = COL_HUB
	elif stuck:
		col = COL_BLOCKED
	elif idle >= IDLE_AFTER:
		col = COL_IDLE

	var thick: float = atleast(2.2, 1.2)
	tris_band(hub, hand, thick, Color(col.r, col.g, col.b, 0.92))
	# A counterweight behind the pivot: it is what makes the swing read as a
	# swing rather than a line growing out of a box.
	var back: Vector2 = hub - (hand - hub).normalized() * (reach * 0.26)
	tris_band(hub, back, thick * 0.8, Color(col.r, col.g, col.b, 0.55))
	_disc(hub, atleast(3.0, 1.6), Color(COL_HUB.r, COL_HUB.g, COL_HUB.b, 0.85))

	if held > 0:
		var look: Dictionary = LcnItemArt.look(StringName(a["held_kind"]))
		var r: float = maxf(LcnItemArt.BODY_RADIUS_PX, wpx(2.4))
		var tris: PackedVector2Array = LcnItemArt.triangles(int(look["shape"]), r)
		# A stack arm carries a hand of several; show up to four of them so the
		# tier ladder is visible on the belt instead of only in a tooltip.
		var shown: int = mini(held, 4)
		var spread: Vector2 = (hand - hub).normalized().orthogonal() * (r * 1.15)
		for i: int in shown:
			var off: float = float(i) - float(shown - 1) * 0.5
			tris_push(tris, hand + spread * off, look["fill"])
	if stuck:
		# The tell, drawn as a ring the arm cannot get past.
		_ring(hand, atleast(6.0, 3.0), atleast(1.4, 1.0),
			Color(COL_BLOCKED.r, COL_BLOCKED.g, COL_BLOCKED.b,
				0.55 if reduce_motion else 0.35 + 0.35 * sin(clock * 6.0)))
	arms_drawn += 1


# ---------------------------------------------------------------- splitters --

func _splitter(sp: Dictionary) -> void:
	var outs: Array = sp["outputs"]
	if outs.is_empty():
		return
	var dir: Vector2 = Vector2(LogiTypes.dir_vec(int(sp["rot"])))
	var next_out: int = int(sp["next_out"])
	var buffered: int = int(sp["buffered"])
	var busy: float = clampf(float(sp["rate"]) / 8.0, 0.0, 1.0)
	var any: bool = false
	for i: int in outs.size():
		var c: Vector2 = LogiTypes.cell_center(outs[i])
		if not on_screen(c, TILE):
			continue
		any = true
		var chosen: bool = i == next_out
		var col: Color = COL_SPLIT_NEXT if chosen else COL_STEEL
		var a: float = (0.30 + 0.55 * busy) if chosen else (0.16 + 0.24 * busy)
		# An arrow leaving on this side, brighter on the side that takes the
		# next item. Which output is favoured is the whole question a player
		# asks of a splitter.
		var tip: Vector2 = c + dir * (TILE * 0.42)
		var tail: Vector2 = c - dir * (TILE * 0.22)
		tris_band(tail, tip, atleast(2.4, 1.2), Color(col.r, col.g, col.b, a))
		var perp: Vector2 = dir.orthogonal() * atleast(5.0, 2.5)
		var back: Vector2 = tip - dir * atleast(6.0, 3.0)
		lines_push(tip, back + perp, Color(col.r, col.g, col.b, minf(1.0, a + 0.3)))
		lines_push(tip, back - perp, Color(col.r, col.g, col.b, minf(1.0, a + 0.3)))
	if not any:
		return
	# Buffered pips on the body, so a splitter holding a plug is visible.
	var cells: Array = sp["cells"]
	if not cells.is_empty() and buffered > 0:
		var body: Vector2 = LogiTypes.cell_center(cells[0])
		var pip: float = atleast(1.8, 1.0)
		for i2: int in mini(buffered, 4):
			_disc(body + dir.orthogonal() * (float(i2) - 1.5) * pip * 2.6, pip,
				Color(COL_SPLIT_NEXT.r, COL_SPLIT_NEXT.g, COL_SPLIT_NEXT.b, 0.8))
	splitters_drawn += 1


# --------------------------------------------------------------- undergrounds --

func _tunnel(t: Dictionary) -> void:
	var a: Vector2 = LogiTypes.cell_center(t["from"])
	var b: Vector2 = LogiTypes.cell_center(t["to"])
	if not on_screen(a, TILE * 2.0) and not on_screen(b, TILE * 2.0):
		return
	var d: Vector2 = b - a
	var length: float = d.length()
	if length < 0.001:
		return
	var dir: Vector2 = d / length
	var load: float = float(t["load"])
	var col: Color = LcnBeltFlowLayer.state_color(int(t["state"]))
	var alpha_line: float = 0.18 + 0.42 * maxf(load, float(t["flow"]))

	# The buried run: dashes moving at the belt's own speed. This stands in for
	# the items themselves, which the sim deliberately does not publish for a
	# tunnel because there is no tile under them to draw them on.
	var gap: float = TILE * 0.5
	var dash: float = TILE * 0.24
	var phase: float = 0.0 if reduce_motion else fposmod(clock * float(t["speed"]) * TILE, gap)
	var walked: float = phase
	while walked < length:
		var s: Vector2 = a + dir * walked
		var e: Vector2 = a + dir * minf(walked + dash, length)
		lines_push(s, e, Color(col.r, col.g, col.b, alpha_line))
		walked += gap

	# The mouths: a bracket swallowing at the entrance, opening at the exit.
	_mouth(a, dir, col, alpha_line + 0.2, true)
	_mouth(b, dir, col, alpha_line + 0.2, false)
	tunnels_drawn += 1


func _mouth(at: Vector2, dir: Vector2, col: Color, a: float, into: bool) -> void:
	if not on_screen(at, TILE):
		return
	var perp: Vector2 = dir.orthogonal() * atleast(7.0, 3.0)
	var depth: Vector2 = dir * atleast(6.0, 3.0) * (1.0 if into else -1.0)
	var c := Color(col.r, col.g, col.b, minf(1.0, a))
	lines_push(at - perp - depth, at - perp + depth, c)
	lines_push(at + perp - depth, at + perp + depth, c)
	lines_push(at - perp + depth, at + perp + depth, c)


# ------------------------------------------------------------------ helpers --

func _disc(at: Vector2, r: float, col: Color) -> void:
	var tris: PackedVector2Array = LcnItemArt.triangles(LcnItemArt.Shape.COG, r)
	tris_push(tris, at, col)


func _ring(at: Vector2, r: float, thickness: float, col: Color) -> void:
	var steps: int = 10
	var prev: Vector2 = at + Vector2(r, 0.0)
	for i: int in range(1, steps + 1):
		var ang: float = TAU * float(i) / float(steps)
		var p: Vector2 = at + Vector2(cos(ang), sin(ang)) * r
		tris_band(prev, p, thickness * 0.5, col)
		prev = p
