class_name LcnBeltFlowLayer
extends LcnItemDrawLayer
## [D2] THE STATE OF EVERY BELT, PAINTED ON THE BELT.
##
## Factorio is watchable because a belt tells you what it is doing before you
## click it. Four states, four readings, no lens and no tooltip:
##
##   STARVED     cold and nearly dark. Chevrons still scroll — the belt is
##               running — but there is almost nothing on it. Feed it.
##   FLOWING     warm amber chevrons, brightness rising with throughput.
##   SATURATED   a solid hot bar. Compressed and moving: this line is full and
##               it is delivering. The best state a belt can be in.
##   BACKED UP   red, and STILL. The chevrons stop. Motion is the tell: a
##               stopped belt in a moving factory is visible from across the
##               map, which is exactly how long it takes a player to notice a
##               jam in the game this is measured against.
##
## The distinction that matters and is easy to get wrong: SATURATED and BACKED
## UP are both *full*. Fullness alone cannot separate them, and a lens that
## colours by fullness alone calls a working trunk line a fault. They are
## separated by throughput — `rate` against the belt's rated `belt_rate()` —
## which is why the classifier lives in `LcnItemFlowRead` next to both numbers.
##
## The whole surface is ADDITIVE and unshaded. A belt state is light thrown onto
## the belt, so it survives the hour grade and the night cast instead of being
## graded down at the exact hour a player needs to read it, and it never muddies
## [P13]'s belt art underneath.

## Half-width of the painted band, in world pixels. A belt tile is 32 across;
## this leaves the slats and the frame visible either side.
const HALF_W: float = 9.0
## The band is allowed to grow this far when the zoom would otherwise take it
## under a couple of screen pixels.
const HALF_W_MAX: float = 15.0
## Chevrons per tile at close zoom.
const CHEVRONS_PER_TILE: int = 2
const CHEVRON_LEN_PX: float = 5.5
const CHEVRON_WING_PX: float = 5.0
## Bars drawn across a jammed tile. Static on purpose.
const JAM_BARS: int = 3

const COL_STARVED: Color = Color(0.32, 0.46, 0.64)
const COL_FLOWING: Color = Color(0.98, 0.64, 0.24)
const COL_SATURATED: Color = Color(1.0, 0.82, 0.46)
const COL_JAMMED: Color = Color(1.0, 0.24, 0.18)

const STATE_COLORS: Array[Color] = [COL_STARVED, COL_FLOWING, COL_SATURATED, COL_JAMMED]

var chevrons: int = 0


func _init() -> void:
	super()
	name = "BeltFlow"
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	mat.light_mode = CanvasItemMaterial.LIGHT_MODE_UNSHADED
	material = mat


## Colour for a flow state. Public so a suite can assert the four are distinct
## without reaching into the draw call.
static func state_color(state: int) -> Color:
	return STATE_COLORS[clampi(state, 0, STATE_COLORS.size() - 1)]


func _draw() -> void:
	drawn = 0
	chevrons = 0
	if read == null or read.belts.is_empty():
		draw_us = 0
		return
	var t0: int = Time.get_ticks_usec()
	tris_reset()
	lines_reset()

	var wide: bool = band >= 3 or item_fade <= 0.02
	var pulse: float = 1.0 if reduce_motion else 0.72 + 0.28 * sin(clock * 5.5)
	# One tile has to be worth more than a couple of screen pixels before a
	# chevron inside it means anything. Below that the band alone carries the
	# reading, and density does the rest.
	var chevrons_worth_it: bool = TILE * zoom >= 13.0

	for b: Dictionary in read.belts:
		var centre: Vector2 = LogiTypes.cell_center(b["cell_v"])
		if not on_screen(centre, TILE):
			continue
		var state: int = int(b["state"])
		var flow: float = float(b["flow"])
		var fill: float = float(b["fill"])
		var dir: Vector2 = Vector2(LogiTypes.dir_vec(int(b["rot"])))
		var col: Color = state_color(state)
		var half: float = minf(HALF_W_MAX, atleast(HALF_W, 2.0))
		var a: float = 0.0

		match state:
			LcnItemFlowRead.Flow.STARVED:
				a = 0.10 + 0.10 * flow
			LcnItemFlowRead.Flow.FLOWING:
				a = 0.16 + 0.30 * flow
			LcnItemFlowRead.Flow.SATURATED:
				a = 0.30 + 0.34 * flow
			LcnItemFlowRead.Flow.BACKED_UP:
				a = 0.52 * pulse

		if wide:
			# Far out, individual items are gone and the useful quantity is how
			# much is moving through here. Density widens the ribbon and load
			# brightens it, so a trunk main reads thicker than a feeder.
			half = minf(HALF_W_MAX, atleast(HALF_W * (0.45 + 0.75 * maxf(flow, fill)), 2.0))
			a = minf(0.85, a * 1.5 + 0.10 * fill)

		var along: Vector2 = dir * (TILE * 0.5)
		tris_band(centre - along, centre + along, half, Color(col.r, col.g, col.b, a))
		drawn += 1

		if state == LcnItemFlowRead.Flow.BACKED_UP:
			_jam_bars(centre, dir, half, col, pulse)
		elif chevrons_worth_it and not wide:
			_chevrons(centre, dir, float(b["speed"]), col, a)

	tris_flush()
	lines_flush(maxf(wpx(1.6), 0.6))
	draw_us = Time.get_ticks_usec() - t0


## Chevrons scrolling at the belt's own tiles-per-second. This is the single
## most important animation in the part: it is how a player sees that a line is
## RUNNING, separately from whether anything is on it.
func _chevrons(centre: Vector2, dir: Vector2, speed: float, col: Color, a: float) -> void:
	var perp: Vector2 = dir.orthogonal()
	var step: float = TILE / float(CHEVRONS_PER_TILE)
	# Phase is in world pixels travelled, wrapped into one chevron spacing, so
	# every tile of one line is in step with every other tile of that line.
	var phase: float = 0.0 if reduce_motion else fposmod(clock * speed * TILE, step)
	var len_w: float = atleast(CHEVRON_LEN_PX, 2.0)
	var wing_w: float = atleast(CHEVRON_WING_PX, 2.0)
	var c := Color(col.r, col.g, col.b, minf(1.0, a * 2.1 + 0.14))
	for i: int in CHEVRONS_PER_TILE:
		var d: float = -TILE * 0.5 + phase + step * (float(i) + 0.5)
		if d < -TILE * 0.5 or d > TILE * 0.5:
			continue
		var apex: Vector2 = centre + dir * d
		var back: Vector2 = apex - dir * len_w
		lines_push(apex, back + perp * wing_w, c)
		lines_push(apex, back - perp * wing_w, c)
		chevrons += 1


## A jam does not scroll. Bars across the belt, drawn in the same place every
## frame, which is what makes a stopped line stand out among moving ones.
func _jam_bars(centre: Vector2, dir: Vector2, half: float, col: Color, pulse: float) -> void:
	var perp: Vector2 = dir.orthogonal()
	var c := Color(col.r, col.g, col.b, minf(1.0, 0.42 * pulse + 0.22))
	var bar_w: float = atleast(1.8, 1.0)
	for i: int in JAM_BARS:
		var d: float = TILE * (-0.30 + 0.30 * float(i))
		var at: Vector2 = centre + dir * d
		tris_band(at - perp * half, at + perp * half, bar_w, c)
