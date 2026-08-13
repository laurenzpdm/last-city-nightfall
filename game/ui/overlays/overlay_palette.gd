class_name LcnOverlayPalette
extends RefCounted
## [P19] The colour authority for the readability lenses.
##
## An overlay that separates its channels by HUE ALONE is unreadable for roughly
## one man in twelve, so nothing here relies on hue alone:
##
##   * every network slot carries a **dash pattern** as well as a colour, so two
##     grids stay distinguishable in greyscale, in a screenshot, and for a player
##     with any of the three common colour deficiencies;
##   * every severity carries a **shape** — a ring for "starved", a pulsing box
##     for "choking", a hatch for "frozen" — so red/green is never the carrier
##     of the message;
##   * the thermal ramp swaps its whole axis per deficiency instead of nudging a
##     hue: blue-orange is safe for protan/deutan and useless for tritan, so
##     tritan gets teal-red and monochrome gets pure luminance.
##
## `Settings.accessibility` drives all of it:
##   colorblind_mode          off | protanopia | deuteranopia | tritanopia | monochrome
##   high_contrast_overlays   thicker strokes, stronger fills, black text outlines
##   reduce_motion            read by the lenses; the palette exposes it for them

enum Vision { NORMAL, PROTAN, DEUTAN, TRITAN, MONO }

const SLOT_COUNT: int = 8

## Dash pattern per network slot: [dash, gap] in world px at 32 px tiles.
## Slot 0 is solid. This is the second channel that lets two networks tell each
## other apart with no colour information at all.
const SLOT_DASHES: Array[Vector2] = [
	Vector2(0.0, 0.0),
	Vector2(15.0, 9.0),
	Vector2(5.0, 5.0),
	Vector2(23.0, 7.0),
	Vector2(2.5, 6.5),
	Vector2(11.0, 4.0),
	Vector2(3.5, 3.5),
	Vector2(29.0, 11.0),
]

## Legend glyph per slot — a third, purely typographic channel.
const SLOT_MARKS: Array[String] = ["|", "=", ":", "-", ".", "+", "*", "#"]

## Wide, evenly spaced hues that survive the cold dark background.
const NET_NORMAL: Array[Color] = [
	Color(0.361, 0.784, 0.980),
	Color(1.000, 0.686, 0.259),
	Color(0.506, 0.780, 0.518),
	Color(0.898, 0.451, 0.451),
	Color(0.729, 0.408, 0.784),
	Color(0.996, 0.945, 0.463),
	Color(0.302, 0.816, 0.882),
	Color(0.941, 0.384, 0.573),
]

## Okabe-Ito, the standard set that stays separable under red-green deficiency.
const NET_RG: Array[Color] = [
	Color(0.337, 0.706, 0.914),
	Color(0.902, 0.624, 0.000),
	Color(0.941, 0.894, 0.259),
	Color(0.800, 0.475, 0.655),
	Color(0.000, 0.447, 0.698),
	Color(0.835, 0.369, 0.000),
	Color(0.949, 0.949, 0.949),
	Color(0.475, 0.565, 0.639),
]

## Tritan separates along red-cyan instead of blue-yellow.
const NET_TRITAN: Array[Color] = [
	Color(0.910, 0.263, 0.247),
	Color(0.000, 0.729, 0.686),
	Color(1.000, 0.612, 0.792),
	Color(0.490, 0.180, 0.408),
	Color(0.800, 0.800, 0.800),
	Color(0.431, 0.549, 0.627),
	Color(1.000, 0.847, 0.847),
	Color(0.298, 0.196, 0.353),
]

const NET_MONO: Array[Color] = [
	Color(0.980, 0.980, 0.980),
	Color(0.760, 0.780, 0.800),
	Color(0.560, 0.590, 0.620),
	Color(0.400, 0.430, 0.470),
	Color(0.880, 0.900, 0.920),
	Color(0.660, 0.690, 0.720),
	Color(0.480, 0.510, 0.550),
	Color(0.320, 0.350, 0.390),
]

# --- thermal ramps --------------------------------------------------------
# Stops are (temperature C, colour). Interpolated in linear order.
# The axis is chosen per deficiency, not merely tinted.

const RAMP_NORMAL: Array = [
	[-45.0, Color(0.043, 0.078, 0.180)],
	[-30.0, Color(0.090, 0.220, 0.450)],
	[-18.0, Color(0.145, 0.400, 0.678)],
	[-8.0, Color(0.290, 0.639, 0.851)],
	[0.0, Color(0.639, 0.847, 0.925)],
	[8.0, Color(0.949, 0.902, 0.780)],
	[16.0, Color(0.988, 0.702, 0.322)],
	[26.0, Color(0.996, 0.427, 0.153)],
	[40.0, Color(1.000, 0.878, 0.639)],
]

const RAMP_TRITAN: Array = [
	[-45.0, Color(0.031, 0.157, 0.149)],
	[-30.0, Color(0.043, 0.318, 0.302)],
	[-18.0, Color(0.000, 0.514, 0.478)],
	[-8.0, Color(0.278, 0.706, 0.667)],
	[0.0, Color(0.702, 0.808, 0.796)],
	[8.0, Color(0.925, 0.855, 0.847)],
	[16.0, Color(0.949, 0.573, 0.545)],
	[26.0, Color(0.847, 0.180, 0.180)],
	[40.0, Color(1.000, 0.741, 0.741)],
]

## Evenly stepped on purpose: with no hue at all, luminance carries the entire
## scale, so the steps have to stay far enough apart that six degrees is still a
## visible difference at the hot end as well as the cold one.
const RAMP_MONO: Array = [
	[-45.0, Color(0.040, 0.044, 0.052)],
	[-30.0, Color(0.130, 0.138, 0.150)],
	[-18.0, Color(0.250, 0.261, 0.281)],
	[-8.0, Color(0.380, 0.395, 0.419)],
	[0.0, Color(0.500, 0.516, 0.539)],
	[8.0, Color(0.630, 0.646, 0.669)],
	[16.0, Color(0.750, 0.766, 0.789)],
	[26.0, Color(0.880, 0.892, 0.910)],
	[40.0, Color(1.000, 1.000, 1.000)],
]

# --- semantic colours -----------------------------------------------------

const INK: Color = Color(0.937, 0.957, 0.988)
const INK_DIM: Color = Color(0.686, 0.741, 0.816)
const PANEL: Color = Color(0.020, 0.035, 0.063, 0.82)
const PANEL_EDGE: Color = Color(0.420, 0.522, 0.647, 0.75)

## Semantic colours per vision mode: [NORMAL, PROTAN, DEUTAN, TRITAN, MONO].
## Protan and deutan both drop the red-green axis, so "bad" moves to vermillion
## and "good" to sky blue — a pair those eyes still separate cleanly.
const C_GOOD: Array[Color] = [
	Color(0.373, 0.784, 0.596),
	Color(0.337, 0.706, 0.914),
	Color(0.337, 0.706, 0.914),
	Color(0.000, 0.729, 0.686),
	Color(0.902, 0.918, 0.937),
]
const C_WARN: Array[Color] = [
	Color(0.949, 0.729, 0.243),
	Color(0.941, 0.894, 0.259),
	Color(0.941, 0.894, 0.259),
	Color(1.000, 0.612, 0.792),
	Color(0.678, 0.702, 0.741),
]
const C_BAD: Array[Color] = [
	Color(0.941, 0.255, 0.212),
	Color(0.835, 0.369, 0.000),
	Color(0.835, 0.369, 0.000),
	Color(0.910, 0.180, 0.180),
	Color(1.000, 1.000, 1.000),
]
const C_ICE: Array[Color] = [
	Color(0.541, 0.808, 0.933),
	Color(0.647, 0.847, 0.988),
	Color(0.647, 0.847, 0.988),
	Color(1.000, 0.816, 0.878),
	Color(0.914, 0.929, 0.961),
]
const C_INFO: Array[Color] = [
	Color(0.561, 0.651, 0.784),
	Color(0.561, 0.651, 0.784),
	Color(0.561, 0.651, 0.784),
	Color(0.624, 0.714, 0.706),
	Color(0.678, 0.706, 0.753),
]
const C_VOID: Array[Color] = [
	Color(0.690, 0.431, 0.796),
	Color(0.690, 0.431, 0.796),
	Color(0.690, 0.431, 0.796),
	Color(0.490, 0.180, 0.408),
	Color(0.357, 0.384, 0.439),
]

# --- live configuration ---------------------------------------------------

var vision: int = Vision.NORMAL
var high_contrast: bool = false
var reduce_motion: bool = false

## Multipliers derived from high_contrast, applied by every lens.
var fill_alpha: float = 1.0
var stroke_scale: float = 1.0

var _nets: Array[Color] = NET_NORMAL
var _ramp: Array = RAMP_NORMAL


func _init(colorblind_mode: String = "off", contrast: bool = false, motion_off: bool = false) -> void:
	configure(colorblind_mode, contrast, motion_off)


## Reads the three accessibility settings and rebuilds every derived table.
## Cheap; the overlay root calls it twice a second.
func configure(colorblind_mode: String, contrast: bool, motion_off: bool) -> void:
	vision = vision_from_setting(colorblind_mode)
	high_contrast = contrast
	reduce_motion = motion_off
	fill_alpha = 1.55 if contrast else 1.0
	stroke_scale = 1.45 if contrast else 1.0
	match vision:
		Vision.PROTAN, Vision.DEUTAN:
			_nets = NET_RG
			_ramp = RAMP_NORMAL
		Vision.TRITAN:
			_nets = NET_TRITAN
			_ramp = RAMP_TRITAN
		Vision.MONO:
			_nets = NET_MONO
			_ramp = RAMP_MONO
		_:
			_nets = NET_NORMAL
			_ramp = RAMP_NORMAL


static func vision_from_setting(mode: String) -> int:
	match mode.to_lower():
		"protanopia", "protan", "red":
			return Vision.PROTAN
		"deuteranopia", "deutan", "green":
			return Vision.DEUTAN
		"tritanopia", "tritan", "blue":
			return Vision.TRITAN
		"monochrome", "mono", "achromatopsia", "greyscale", "grayscale":
			return Vision.MONO
	return Vision.NORMAL


static func vision_name(v: int) -> String:
	match v:
		Vision.PROTAN:
			return "protanopia"
		Vision.DEUTAN:
			return "deuteranopia"
		Vision.TRITAN:
			return "tritanopia"
		Vision.MONO:
			return "monochrome"
	return "off"


# --- lookups --------------------------------------------------------------

## Colour of a network slot. Slots repeat past SLOT_COUNT, but the dash pattern
## rotates on a different period so two grids sharing a colour never also share
## a pattern until the player owns 64 separate networks.
func network_color(slot: int) -> Color:
	return _nets[posmod(slot, SLOT_COUNT)]


func network_dash(slot: int) -> Vector2:
	return SLOT_DASHES[posmod(slot / SLOT_COUNT + slot, SLOT_DASHES.size())]


func network_mark(slot: int) -> String:
	return SLOT_MARKS[posmod(slot / SLOT_COUNT + slot, SLOT_MARKS.size())]


func good() -> Color:
	return C_GOOD[vision]


func warn() -> Color:
	return C_WARN[vision]


func bad() -> Color:
	return C_BAD[vision]


func ice() -> Color:
	return C_ICE[vision]


func info() -> Color:
	return C_INFO[vision]


func void_color() -> Color:
	return C_VOID[vision]


## Health-to-colour for a 0..1 "how well is this served" number.
## Shape, not only hue, carries the message at the call sites; this is the tint.
func served_color(served: float) -> Color:
	if served >= 0.999:
		return good()
	if served >= 0.25:
		return warn().lerp(bad(), clampf((0.999 - served) / 0.75, 0.0, 1.0) * 0.55)
	return bad()


## Temperature (Celsius) to colour on the active thermal ramp.
func thermal_color(celsius: float) -> Color:
	var stops: Array = _ramp
	var n: int = stops.size()
	var first: Array = stops[0]
	if celsius <= float(first[0]):
		return first[1]
	for i: int in range(1, n):
		var hi: Array = stops[i]
		if celsius <= float(hi[0]):
			var lo: Array = stops[i - 1]
			var span: float = maxf(0.001, float(hi[0]) - float(lo[0]))
			var t: float = clampf((celsius - float(lo[0])) / span, 0.0, 1.0)
			return (lo[1] as Color).lerp(hi[1] as Color, t)
	return stops[n - 1][1]


## Alpha for a translucent fill, scaled by the high-contrast setting and clamped
## so an overlay never becomes opaque enough to hide the thing it is diagnosing.
func fill(a: float) -> float:
	return clampf(a * fill_alpha, 0.0, 0.62)


## Stroke width in world px for a desired on-screen thickness.
## `world_per_px` is 1.0 / camera zoom, so a line is the same weight at every
## zoom level — which is the whole reason the lenses stay legible zoomed out.
func stroke(screen_px: float, world_per_px: float) -> float:
	return maxf(0.6, screen_px * stroke_scale * world_per_px)


## Colour with its alpha replaced (Color.with_alpha does not exist in 4.x).
static func with_a(c: Color, a: float) -> Color:
	return Color(c.r, c.g, c.b, a)


## Perceived luminance, used by the tests to prove two slots are separable
## without any colour information at all.
static func luma(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b


## Crude perceptual distance between two overlay colours. The test suite uses it
## to keep a future palette edit from quietly making two networks look alike.
static func separation(a: Color, b: Color) -> float:
	var dl: float = absf(luma(a) - luma(b))
	var dr: float = absf(a.r - b.r)
	var dg: float = absf(a.g - b.g)
	var db: float = absf(a.b - b.b)
	return dl * 1.4 + (dr + dg + db) / 3.0
