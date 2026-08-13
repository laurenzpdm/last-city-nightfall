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
