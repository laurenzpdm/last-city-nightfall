class_name LcnPalette
extends RefCounted
## THE colour authority for Last City: Nightfall. [P13]
##
## Every view/ and ui/ part imports colours from here instead of typing hex codes,
## so the whole game shifts together when the art direction is tuned.
##
##   const P := preload("res://game/view/render/palette.gd")
##   my_rect.color = P.COLD_HIGH
##   var g: Dictionary = P.grade_at(0.78)   # dusk grade
##
## The direction in one sentence: a cold blue-grey world lit by small warm orange
## islands. Cold is the default state of every pixel; warmth is *earned* by heat.
##
## Anchors (locked, do not drift):
##   cold  #0b1220 -> #1d2c44
##   warm  #ff8a3d -> #ffd9a0
##   snow  #e8eef7
##
## LIGHTING MODEL (second pass). A grade is no longer a colour filter over the
## frame. It is a *light rig*: a directional key (`sun_dir`/`sun_col`/`sun_energy`),
## a sky fill (`sky_col`/`sky_energy`), and a snow-bounce term that only exists
## where the city is (`bounce`/`bounce_col`), with the wilderness pushed down by
## `wild`. The ground shader and the entity tint both evaluate the same three
## terms, which is why dusk now reads as low orange light *falling on* drifts
## instead of an orange wash over everything, and why deep night can be genuinely
## dark 60 tiles out while the city stays readable in silhouette.

# ---------------------------------------------------------------- cold ramp --
## Void behind everything. Also the outline colour that gives sprites silhouette.
const COLD_ABYSS: Color = Color(0.020, 0.031, 0.059)      # #05080f
const COLD_DEEP: Color = Color(0.043, 0.071, 0.125)       # #0b1220  ANCHOR
const COLD_MID: Color = Color(0.071, 0.110, 0.188)        # #121c30
const COLD_HIGH: Color = Color(0.114, 0.173, 0.267)       # #1d2c44  ANCHOR
const COLD_RIM: Color = Color(0.173, 0.255, 0.376)        # #2c4160
const STEEL: Color = Color(0.239, 0.322, 0.443)           # #3d5271
const STEEL_LIGHT: Color = Color(0.353, 0.443, 0.573)     # #5a7192

# ---------------------------------------------------------------- snow ramp --
## These four are the INTERFACE ramp: HUD body text, secondary text, panel
## hairlines. They are anchors for readability, not for the ground.
const SNOW_SHADOW: Color = Color(0.498, 0.573, 0.678)     # #7f92ad
const SNOW_MID: Color = Color(0.765, 0.812, 0.878)        # #c3cfe0
const SNOW: Color = Color(0.910, 0.933, 0.969)            # #e8eef7  ANCHOR
const SNOW_LIT: Color = Color(0.976, 0.988, 1.000)        # #f9fcff

# ------------------------------------------------------------- ground snow --
## The GROUND ramp, which is a different problem from the interface ramp and
## used to share it. Snow lit by an overcast polar sky is not white — it is a
## pale blue-grey that only reaches white on a crest the sun actually catches.
## Painting the plain at interface-white is exactly how a midday frame came out
## at 0.72 mean luminance with no shadow anywhere in it, and a critic called the
## whole build washed out on the strength of it.
##
## Held one ramp so cold reads as one colour: every step is on the same
## blue-violet line, and nothing on the ground is ever neutral grey.
const GROUND_SNOW_SHADOW: Color = Color(0.318, 0.396, 0.545)   # #51658b
const GROUND_SNOW_MID: Color = Color(0.588, 0.659, 0.769)      # #96a8c4
const GROUND_SNOW_LIT: Color = Color(0.831, 0.878, 0.941)      # #e0e9f6

# ---------------------------------------------------------------- warm ramp --
const EMBER: Color = Color(1.000, 0.369, 0.169)           # #ff5e2b
const WARM_EDGE: Color = Color(1.000, 0.541, 0.239)       # #ff8a3d  ANCHOR
const WARM_MID: Color = Color(1.000, 0.690, 0.400)        # #ffb066
const WARM_CORE: Color = Color(1.000, 0.851, 0.627)       # #ffd9a0  ANCHOR
const WARM_WHITE: Color = Color(1.000, 0.949, 0.855)      # #fff2da

# ------------------------------------------------------------------ accents --
const DANGER: Color = Color(0.886, 0.255, 0.227)          # #e2413a
const CAUTION: Color = Color(0.949, 0.729, 0.243)         # #f2ba3e
const GOOD: Color = Color(0.373, 0.784, 0.596)            # #5fc898
const ICE_BLUE: Color = Color(0.541, 0.749, 0.851)        # #8abfd9
const ASH: Color = Color(0.208, 0.204, 0.216)             # #353437
const RUST: Color = Color(0.482, 0.271, 0.169)            # #7b452b

# ---------------------------------------------------------------- terrain ----
## Terrain families the renderer knows how to draw. A grid system that names its
## terrain (see LcnSimProbe) is mapped onto these; anything unknown falls back
## to SNOW so a new terrain never renders as a magenta hole.
enum Terrain {
	SNOW_DEEP,
	SNOW,
	ICE,
	ROCK,
	GRAVEL,
	ASH_FIELD,
	PAVED,
	WATER_FROZEN,
	RUBBLE,
}

const TERRAIN_COUNT: int = 9

## Per-terrain draw recipe: base / low / high tones plus a grain amount.
## Kept as data so a tuning pass is one table edit, not a code hunt.
static func terrain_tones(kind: int) -> Dictionary:
	match kind:
		Terrain.SNOW_DEEP:
			return {
				"base": Color(0.671, 0.729, 0.827), "low": Color(0.396, 0.478, 0.620),
				"high": Color(0.910, 0.941, 0.980), "grain": 0.045, "ridges": 1.0,
			}
		Terrain.SNOW:
			return {
				"base": Color(0.588, 0.647, 0.749), "low": Color(0.325, 0.400, 0.533),
				"high": Color(0.855, 0.894, 0.949), "grain": 0.060, "ridges": 0.62,
			}
		Terrain.ICE:
			return {
				"base": Color(0.322, 0.435, 0.557), "low": Color(0.153, 0.239, 0.361),
				"high": Color(0.686, 0.831, 0.925), "grain": 0.035, "ridges": 0.0,
			}
		Terrain.ROCK:
			# The exposed bones of the plain. Blue-violet rather than grey, so
			# bare rock reads as cold stone and never as a hole.
			#
			# AN ALBEDO IS A REFLECTANCE, NOT A BRIGHTNESS, and this table had
			# forgotten it. Rock shipped at a base of 0.13 luminance — which is
			# what wet slate looks like AT NIGHT — and then the light rig
			# multiplied it down again after dark, so the far plain was black at
			# every hour and the night had nothing in it twice over. It is also
			# the whole of `LATE DAY`: on day three the camera pulls out to hold a
			# bigger city, the bands of open plain the frame suite reads land on
			# the rock ring beyond the snow, and the same 0.99 daylight measured
			# 0.30 on day one's snow and 0.14 on day three's stone. The ramp is
			# lifted to something a rock shelf actually reflects under an
			# overcast polar sky; the darkness stays the rig's job, where it can
			# be taken away again at noon.
			return {
				"base": Color(0.208, 0.231, 0.310), "low": Color(0.106, 0.122, 0.184),
				"high": Color(0.400, 0.428, 0.512), "grain": 0.075, "ridges": 0.0,
			}
		Terrain.GRAVEL:
			return {
				"base": Color(0.251, 0.271, 0.341), "low": Color(0.129, 0.145, 0.200),
				"high": Color(0.447, 0.470, 0.545), "grain": 0.140, "ridges": 0.0,
			}
		Terrain.ASH_FIELD:
			# Warm volcanic grit, not a hole in the map. The caldera floor is where
			# the whole city stands: at the old values it read as a black disc and
			# every road, wall and citizen inside it was invisible.
			#
			# It went dark AGAIN the moment the plain around it became a real
			# snowfield, because a 0.26 albedo beside a 0.60 one is a hole
			# whatever its absolute value is. The band is widened rather than
			# lifted — `low` holds so a soot stain and a wet melt ring still have
			# somewhere to go, `high` comes up so the faceted strata read as grit
			# with a grain rather than as one flat tone, and the whole ramp loses
			# a little of its brown so it sits under a cold sky without turning
			# the settlement sepia.
			return {
				"base": Color(0.310, 0.288, 0.268), "low": Color(0.162, 0.146, 0.134),
				"high": Color(0.502, 0.462, 0.408), "grain": 0.130, "ridges": 0.0,
			}
		Terrain.PAVED:
			return {
				"base": Color(0.259, 0.298, 0.376), "low": Color(0.145, 0.176, 0.239),
				"high": Color(0.400, 0.447, 0.529), "grain": 0.050, "ridges": 0.0,
			}
		Terrain.WATER_FROZEN:
			return {
				"base": Color(0.145, 0.204, 0.302), "low": Color(0.086, 0.129, 0.204),
				"high": Color(0.435, 0.561, 0.663), "grain": 0.030, "ridges": 0.0,
			}
		Terrain.RUBBLE:
			return {
				"base": Color(0.263, 0.263, 0.286), "low": Color(0.133, 0.133, 0.149),
				"high": Color(0.443, 0.431, 0.431), "grain": 0.170, "ridges": 0.0,
			}
	return terrain_tones(Terrain.SNOW)


## True when snow visibly piles on this terrain (drives the accumulation layer).
static func terrain_takes_snow(kind: int) -> bool:
	return kind != Terrain.WATER_FROZEN and kind != Terrain.ICE


# --------------------------------------------------------------- day grade ---
## The day is a normalised 0..1 loop: 0.0 midnight, 0.25 dawn, 0.5 noon,
## 0.75 dusk. `grade_at()` interpolates between these keyframes.
##
## Keys of a grade dictionary:
##   name          StringName, human-facing phase name
##   sky           Color, CanvasModulate cast over the world canvas. A HUE cast,
##                 not a brightness cut: darkness is produced by the light rig
##                 below, per surface, so that unlit things go dark and lit
##                 things do not. Multiplying the whole canvas down was the
##                 "flat global multiply" a critic named, and it is also what
##                 made deep night an unreadable void.
##   ambient       Color, colour of light in unlit areas
##   shadow        Color, multiply colour of cast shadows
##   shadow_alpha  float, shadow opacity
##   shadow_dir    Vector2, unit direction shadows are cast toward (screen space)
##   shadow_len    float, shadow length in multiples of building height
##   lift/gain     Color, post-process colour grade
##   sat           float, saturation after grade
##   fog           Color, ground-mist colour
##   fog_amt       float, ground-mist strength
##   light_energy  float, multiplier on every warm Light2D
##   bloom         float, bloom strength multiplier
##   chroma        float, cold chromatic split (also scaled by temperature)
##   star_amt      float, how visible the cold star field is
##
## Light-rig keys (second pass — these are what make light *fall on* things):
##   sun_dir       Vector2, unit direction TOWARD the key light in screen space
##   sun_height    float, 0..1 elevation of that key. A low sun GRAZES the plain
##                 instead of shining down it, which is the whole reason dusk
##                 now picks out drift faces instead of washing the frame
##   sun_col       Color, colour of the key light (sun, or the moon after dark)
##   sun_energy    float, key intensity
##   sky_col       Color, colour of the sky fill on unlit faces
##   sky_energy    float, fill intensity
##   bounce        float, snow-bounce/lamp-spill lift that exists ONLY over the
##                 city — the night legibility floor
##   bounce_col    Color, colour of that lift
##   wild          float, 0..1 extra darkening applied where the city is not.
##                 Deep night is dark *out there*, never over your own streets.
const _GRADE_COLORS: Array[String] = [
	"sky", "ambient", "shadow", "lift", "gain", "fog", "sun_col", "sky_col", "bounce_col",
]
const _GRADE_FLOATS: Array[String] = [
	"shadow_alpha", "shadow_len", "sat", "fog_amt",
	"light_energy", "bloom", "chroma", "star_amt",
	"sun_energy", "sky_energy", "bounce", "wild", "sun_height",
]

## Built once. `grade_at` used to allocate nine dictionaries per call and it is
## called every frame by the renderer and by three UI parts.
static var _keys_cache: Array[Dictionary] = []
static var _grade_cache: Dictionary[int, Dictionary] = {}


## THE DAY HAD NO ARC, AND IT WAS MEASURED IN THE SHIPPED FRAMES, NOT GUESSED.
##
## `artifacts/CRIT/shots/*.world.png` at the zoom a session actually sits at,
## sampled over two fixed bands of open plain (x 60-400 and x 1500-1860,
## y 380-940), median luminance:
##
##     midday 0.182 · dusk 0.082 · deep_night 0.057 · dawn 0.070
##     day-three afternoon 0.099
##
## Three sentences follow from that table and all three are art-direction
## failures, not engine ones:
##
##   1. Snow at noon was an 18% grey card. Its 10th-to-90th percentile spread
##      was 0.119 — the whole daylit plain lived inside one eighth of the
##      available range, so nothing on it could read as a shape.
##   2. Dusk was midday at half a stop and the SAME HUE (red-minus-blue -0.029
##      against midday's -0.027). Dusk is supposed to be the one hour of the day
##      that is a different colour, and it was not.
##   3. Deep night's plain measured 0.057 with a spread of 0.039 and 0.006 of
##      local structure. Off the streets there was nothing out there at all —
##      dark AND empty, which is the failure mode a night is not allowed to have.
##
## So the key and fill energies below carry the day now instead of the palette
## carrying it. Daylight roughly doubles (noon key 0.64 -> 1.18, fill 0.33 ->
## 0.62) because a snowfield in sun is the brightest thing this game will ever
## draw and it was being rendered darker than its own HUD panels. Dusk's key
## goes UP, to 1.44, while its fill goes DOWN to 0.28 and its height stays at
## 0.16: a hard low copper key against a cold fill splits every drift into a lit
## face and a blue one, which is a different PICTURE from noon rather than a
## darker one. And the night moon drops from 0.72 elevation to 0.30 and doubles
## in energy while `wild` comes off 0.88 to 0.60 — the plain stays dark, but it
## is dark the way a moonlit snowfield is dark, with crests catching the moon
## and troughs going to black, instead of dark the way an unlit quad is.
##
## The city's own legibility is untouched: `bounce`, `bounce_col` and the warm
## term in `light_at` are exactly what they were, so a burning hearth is still
## bought with heat and a frozen district still goes out.
static func _keyframes() -> Array[Dictionary]:
	if not _keys_cache.is_empty():
		return _keys_cache
	_keys_cache = [
		{
			# Moonlight on snow: a cold key from high left, a deep blue fill, and
			# a bounce term that keeps the settlement legible while the plain
			# beyond it goes properly black.
			"t": 0.00, "name": &"deep_night",
			"sky": Color(0.790, 0.835, 0.960), "ambient": Color(0.090, 0.130, 0.230),
			"shadow": Color(0.020, 0.035, 0.090), "shadow_alpha": 0.48,
			"shadow_dir": Vector2(0.05, 0.55), "shadow_len": 0.9,
			"lift": Color(0.002, 0.005, 0.013), "gain": Color(0.86, 0.92, 1.10),
			"sat": 0.94, "fog": Color(0.048, 0.068, 0.140), "fog_amt": 0.15,
			"light_energy": 1.30, "bloom": 0.50, "chroma": 1.00, "star_amt": 1.00,
			"sun_dir": Vector2(-0.42, -0.55), "sun_col": Color(0.50, 0.64, 1.00), "sun_energy": 0.66,
			"sun_height": 0.14,
			"sky_col": Color(0.098, 0.145, 0.310), "sky_energy": 0.050,
			"bounce": 0.85, "bounce_col": Color(1.00, 0.72, 0.42), "wild": 0.78,
		},
		{
			"t": 0.19, "name": &"night",
			"sky": Color(0.820, 0.860, 0.965), "ambient": Color(0.120, 0.165, 0.290),
			"shadow": Color(0.025, 0.040, 0.098), "shadow_alpha": 0.50,
			"shadow_dir": Vector2(-0.35, 0.60), "shadow_len": 1.2,
			"lift": Color(0.003, 0.006, 0.016), "gain": Color(0.90, 0.95, 1.10),
			"sat": 0.94, "fog": Color(0.056, 0.080, 0.155), "fog_amt": 0.16,
			"light_energy": 1.25, "bloom": 0.52, "chroma": 0.85, "star_amt": 0.85,
			"sun_dir": Vector2(0.30, -0.60), "sun_col": Color(0.52, 0.66, 1.00), "sun_energy": 0.64,
			"sun_height": 0.15,
			"sky_col": Color(0.110, 0.160, 0.330), "sky_energy": 0.060,
			"bounce": 0.80, "bounce_col": Color(1.00, 0.74, 0.45), "wild": 0.74,
		},
		{
			# Dawn: a long low key from the east, still a cold fill behind it.
			"t": 0.27, "name": &"dawn",
			"sky": Color(0.930, 0.950, 0.995), "ambient": Color(0.330, 0.420, 0.600),
			"shadow": Color(0.055, 0.078, 0.165), "shadow_alpha": 0.68,
			"shadow_dir": Vector2(-0.86, 0.51), "shadow_len": 2.7,
			"lift": Color(0.004, 0.010, 0.026), "gain": Color(0.95, 0.99, 1.12),
			"sat": 1.00, "fog": Color(0.200, 0.265, 0.410), "fog_amt": 0.28,
			"light_energy": 0.60, "bloom": 0.50, "chroma": 0.55, "star_amt": 0.25,
			"sun_dir": Vector2(0.90, -0.44), "sun_col": Color(1.00, 0.70, 0.52), "sun_energy": 1.39,
			"sun_height": 0.20,
			"sky_col": Color(0.235, 0.330, 0.560), "sky_energy": 0.74,
			"bounce": 0.34, "bounce_col": Color(1.00, 0.80, 0.60), "wild": 0.16,
		},
		{
			"t": 0.37, "name": &"morning",
			"sky": Color(0.985, 0.990, 1.000), "ambient": Color(0.600, 0.670, 0.790),
			"shadow": Color(0.071, 0.098, 0.196), "shadow_alpha": 0.64,
			"shadow_dir": Vector2(-0.52, 0.62), "shadow_len": 1.6,
			"lift": Color(0.002, 0.006, 0.018), "gain": Color(0.99, 1.00, 1.06),
			"sat": 1.00, "fog": Color(0.330, 0.395, 0.520), "fog_amt": 0.15,
			"light_energy": 0.26, "bloom": 0.34, "chroma": 0.35, "star_amt": 0.0,
			"sun_dir": Vector2(0.58, -0.64), "sun_col": Color(1.00, 0.955, 0.900), "sun_energy": 1.99,
			"sun_height": 0.58,
			"sky_col": Color(0.265, 0.380, 0.700), "sky_energy": 1.13,
			"bounce": 0.10, "bounce_col": Color(1.00, 0.86, 0.68), "wild": 0.02,
		},
		{
			"t": 0.50, "name": &"noon",
			"sky": Color(1.000, 1.000, 1.000), "ambient": Color(0.820, 0.860, 0.930),
			"shadow": Color(0.086, 0.118, 0.220), "shadow_alpha": 0.62,
			"shadow_dir": Vector2(-0.10, 0.56), "shadow_len": 0.75,
			"lift": Color(0.000, 0.003, 0.012), "gain": Color(1.02, 1.02, 1.03),
			"sat": 1.02, "fog": Color(0.400, 0.470, 0.610), "fog_amt": 0.10,
			"light_energy": 0.14, "bloom": 0.30, "chroma": 0.22, "star_amt": 0.0,
			# THE DAYLIGHT LOBE PAYS FOR ITS OWN STRUCTURE, AND FOR ONE COMMIT IT
			# DID NOT. Read this before touching `sun_energy` on any of the four
			# daylit keyframes, because the mistake it records was made here.
			#
			# The note that used to stand in this slot cut noon 1.40 -> 1.30 and
			# afternoon 1.36 -> 1.26 to stop the crust clipping, and it was right
			# that the crust was clipping. What it did not do was re-grade the
			# SHIPPED frames afterwards. In the same commit the ground's coverage
			# bar moved inside the drift field for the first time, so roughly half
			# the open plain stopped being crust and started being `scoured` — a
			# darker tone, lying in the low ground, where `ao` was already darkest.
			# Three darkenings landed on the same pixels at once: a smaller key, a
			# highlight shoulder, and an albedo that had halved.
			#
			# What that cost, measured by `tests/render/run_ground_frame.gd`, which
			# grades the harness PNGs and belongs to nobody:
			#
			#   artifacts/CRIT (2026-08-18, pre-commit)  midday p10 0.236 p50 0.356
			#                                            ARC 1.76   15 checks, 0 fail
			#   after the cut                            midday p10 0.142 p50 0.245
			#                                            ARC 1.04   ARC RED
			#
			# ARC_SEPARATION is the darkest tenth of the daylit plain over the
			# brightest tenth of the night plain. At 1.04 the day and the night had
			# MET: the shadow side of a noon drift was the same value as a moonlit
			# crest, which is the arc this whole game is about, closed. The commit's
			# own text names that failure — it rejects a shoulder at 0.60 for
			# causing exactly it — and then ships it anyway with the same numbers.
			#
			# So the key comes back, and further than it was, because the plain it
			# is lighting is genuinely darker than the one those numbers were set
			# for. The clipping the cut was aimed at is handled where it belongs,
			# by the HIGHLIGHT SHOULDER at the bottom of terrain.gdshader: with the
			# key at 2.05 the daylit plain's brightest tenth measures 0.436, and the
			# shoulder does not begin until 0.86, so nothing in a midday frame is
			# inside the roll-off at all — it is a guard rail against the crest of
			# one lit drift, not an exposure cut on the whole day.
			#
			# The lift is proportional across dawn/morning/noon/afternoon so the
			# hours keep their spacing, and it stops at dusk: dusk, twilight and
			# both night keys are untouched, which is why deep_night grades
			# bit-identical across every step of this change.
			"sun_dir": Vector2(0.10, -0.86), "sun_col": Color(1.00, 0.980, 0.945), "sun_energy": 2.05,
			"sun_height": 0.95,
			"sky_col": Color(0.290, 0.420, 0.760), "sky_energy": 1.17,
			"bounce": 0.0, "bounce_col": Color(1.00, 0.88, 0.70), "wild": 0.0,
		},
		{
			"t": 0.63, "name": &"afternoon",
			"sky": Color(1.000, 0.995, 0.990), "ambient": Color(0.760, 0.760, 0.790),
			"shadow": Color(0.078, 0.090, 0.196), "shadow_alpha": 0.66,
			"shadow_dir": Vector2(0.46, 0.60), "shadow_len": 1.5,
			"lift": Color(0.002, 0.005, 0.016), "gain": Color(1.01, 1.00, 1.01),
			"sat": 1.00, "fog": Color(0.380, 0.410, 0.510), "fog_amt": 0.13,
			"light_energy": 0.44, "bloom": 0.40, "chroma": 0.30, "star_amt": 0.0,
			# Lifted with noon and by the same factor, so the two hours stay the
			# same distance apart. This is the key `midday` and `third_day_city`
			# are both photographed under, so it is the one the ARC check in
			# `tests/render/run_ground_frame.gd` actually reads. See the note on
			# the noon keyframe for what it cost when it was cut.
			"sun_dir": Vector2(-0.50, -0.70), "sun_col": Color(1.00, 0.940, 0.858), "sun_energy": 1.99,
			"sun_height": 0.52,
			"sky_col": Color(0.255, 0.375, 0.720), "sky_energy": 1.11,
			"bounce": 0.10, "bounce_col": Color(1.00, 0.86, 0.66), "wild": 0.03,
		},
		{
			# Dusk. The orange belongs to the KEY, not to the frame: lit faces go
			# copper, everything the sun cannot reach falls into a blue fill. The
			# old flat multiply tinted snow forty tiles from any light source.
			"t": 0.74, "name": &"dusk",
			"sky": Color(1.000, 0.985, 0.975), "ambient": Color(0.500, 0.420, 0.430),
			"shadow": Color(0.055, 0.055, 0.130), "shadow_alpha": 0.72,
			"shadow_dir": Vector2(0.86, 0.50), "shadow_len": 2.9,
			"lift": Color(0.008, 0.008, 0.024), "gain": Color(1.04, 0.99, 0.98),
			"sat": 1.06, "fog": Color(0.180, 0.190, 0.290), "fog_amt": 0.22,
			"light_energy": 1.00, "bloom": 0.50, "chroma": 0.40, "star_amt": 0.10,
			# THE FILL WAS TOO SMALL FOR THE KEY TO BE A KEY. At 0.28 against a
			# 1.44 copper key the blue hemisphere was a fifth of the light in the
			# frame, so even a face the low sun cannot reach was lit copper, and
			# `artifacts/H4b_v3/shots/dusk.world.png` is a rust-orange dune field
			# at nineteen below. A real dusk is the other way round: a big soft
			# blue dome and one narrow warm source low on one side. Doubling the
			# fill and easing the key is what puts the orange back on the drift
			# faces that are actually turned toward it and leaves the rest blue.
			"sun_dir": Vector2(-0.93, -0.37), "sun_col": Color(1.00, 0.520, 0.245), "sun_energy": 1.22,
			"sun_height": 0.16,
			"sky_col": Color(0.165, 0.240, 0.520), "sky_energy": 0.62,
			"bounce": 0.30, "bounce_col": Color(1.00, 0.76, 0.50), "wild": 0.22,
		},
		{
			"t": 0.83, "name": &"twilight",
			"sky": Color(0.900, 0.895, 0.975), "ambient": Color(0.250, 0.250, 0.370),
			"shadow": Color(0.040, 0.045, 0.110), "shadow_alpha": 0.58,
			"shadow_dir": Vector2(0.55, 0.58), "shadow_len": 1.8,
			"lift": Color(0.010, 0.014, 0.032), "gain": Color(1.00, 0.96, 1.02),
			"sat": 0.98, "fog": Color(0.160, 0.160, 0.245), "fog_amt": 0.28,
			"light_energy": 1.20, "bloom": 0.54, "chroma": 0.65, "star_amt": 0.55,
			"sun_dir": Vector2(-0.80, -0.60), "sun_col": Color(0.74, 0.52, 0.58), "sun_energy": 0.56,
			"sun_height": 0.26,
			"sky_col": Color(0.140, 0.185, 0.390), "sky_energy": 0.40,
			"bounce": 0.62, "bounce_col": Color(1.00, 0.74, 0.46), "wild": 0.44,
		},
		{
			"t": 1.00, "name": &"deep_night",
			"sky": Color(0.790, 0.835, 0.960), "ambient": Color(0.090, 0.130, 0.230),
			"shadow": Color(0.020, 0.035, 0.090), "shadow_alpha": 0.48,
			"shadow_dir": Vector2(0.05, 0.55), "shadow_len": 0.9,
			"lift": Color(0.002, 0.005, 0.013), "gain": Color(0.86, 0.92, 1.10),
			"sat": 0.94, "fog": Color(0.048, 0.068, 0.140), "fog_amt": 0.15,
			"light_energy": 1.30, "bloom": 0.50, "chroma": 1.00, "star_amt": 1.00,
			"sun_dir": Vector2(-0.42, -0.55), "sun_col": Color(0.50, 0.64, 1.00), "sun_energy": 0.66,
			"sun_height": 0.14,
			"sky_col": Color(0.098, 0.145, 0.310), "sky_energy": 0.050,
			"bounce": 0.85, "bounce_col": Color(1.00, 0.72, 0.42), "wild": 0.78,
		},
	]
	return _keys_cache


## Interpolated colour grade for a normalised time of day (0..1, wraps).
##
## Memoised at 1/2048 of a day — finer than one rendered frame can show and far
## finer than one 20 Hz tick moves — so calling this per frame from four parts
## costs one dictionary lookup instead of nine dictionary allocations.
static func grade_at(day_t: float) -> Dictionary:
	var t: float = fposmod(day_t, 1.0)
	var q: int = int(t * 2048.0)
	var hit: Dictionary = _grade_cache.get(q, {})
	if not hit.is_empty():
		return hit
	var keys: Array[Dictionary] = _keyframes()
	var i: int = 0
	for k: int in range(keys.size() - 1):
		if t >= float(keys[k]["t"]) and t <= float(keys[k + 1]["t"]):
			i = k
			break
	var a: Dictionary = keys[i]
	var b: Dictionary = keys[i + 1]
	var span: float = maxf(0.0001, float(b["t"]) - float(a["t"]))
	var f: float = smoothstep(0.0, 1.0, clampf((t - float(a["t"])) / span, 0.0, 1.0))
	var out: Dictionary = blend(a, b, f)
	if _grade_cache.size() > 4096:
		_grade_cache.clear()
	_grade_cache[q] = out
	return out


## Linear blend of two grade dictionaries. Public so a storm/event system can
## crossfade toward a custom grade without reimplementing the interpolation.
static func blend(a: Dictionary, b: Dictionary, f: float) -> Dictionary:
	var out: Dictionary = {}
	out["name"] = a["name"] if f < 0.5 else b["name"]
	for key: String in _GRADE_COLORS:
		out[key] = (a[key] as Color).lerp(b[key] as Color, f)
	for key: String in _GRADE_FLOATS:
		out[key] = lerpf(float(a[key]), float(b[key]), f)
	out["shadow_dir"] = ((a["shadow_dir"] as Vector2).lerp(b["shadow_dir"] as Vector2, f)).normalized()
	out["sun_dir"] = ((a["sun_dir"] as Vector2).lerp(b["sun_dir"] as Vector2, f)).normalized()
	return out


## The light landing on a surface at `city` (0..1 civilisation presence) and
## `warm` (0..1 local heat), as a multiplier on its albedo.
##
## This is the CPU twin of the ground shader's lighting term: entities are tinted
## with it so a building and the snow it stands on agree about what is lighting
## them. `up` biases the sky fill for a face pointing at the sky (a roof) versus
## one facing the camera (a wall).
static func light_at(grade: Dictionary, city: float, warm: float, up: float = 0.75) -> Color:
	# A high sun favours anything pointing at the sky, a low one favours anything
	# standing up in it. Same `sun_height` the ground shader tilts its light with,
	# so a roof and the snow beside it agree about where dusk is coming from.
	var facing: float = lerpf(1.0 - up, up, clampf(float(grade["sun_height"]), 0.0, 1.0))
	var key: float = float(grade["sun_energy"]) * (0.28 + 0.80 * facing)
	var sun: Color = grade["sun_col"]
	var sky: Color = grade["sky_col"]
	var bc: Color = grade["bounce_col"]
	var fill: float = float(grade["sky_energy"]) * (0.70 + 0.30 * up)
	# The night floor is EARNED. It used to be `bounce * city`, a blue lift over
	# any disc of ground that had buildings on it, which meant a frozen district
	# looked exactly like a burning one and the game about heat in the dark had
	# no dark and no heat. It is driven by local warmth first and by mere
	# presence only faintly, and the ground shader evaluates the same expression.
	var b: float = float(grade["bounce"]) \
		* clampf(warm * 2.30 + clampf(city, 0.0, 1.0) * 0.16, 0.0, 1.0) * 0.46
	var dark: float = 1.0 - float(grade["wild"]) \
		* (1.0 - clampf(warm * 2.6 + city * 0.55, 0.0, 1.0))
	var w: float = clampf(warm, 0.0, 1.0) * (0.55 + 0.45 * clampf(warm, 0.0, 1.0)) * 1.15
	return Color(
		(sun.r * key + sky.r * fill + bc.r * b) * dark + WARM_EDGE.r * w,
		(sun.g * key + sky.g * fill + bc.g * b) * dark + WARM_EDGE.g * w,
		(sun.b * key + sky.b * fill + bc.b * b) * dark + WARM_EDGE.b * w,
		1.0)


## Phase name for a time of day, e.g. &"dusk". Cheap; safe to call per frame.
static func phase_at(day_t: float) -> StringName:
	return grade_at(day_t)["name"]


# -------------------------------------------------------------- temperature --
## Colour of a surface at a given temperature in degrees C, used for the heat
## overlay tint and for how blue a cold tile reads. -60C -> deep ice blue,
## +20C -> neutral, +80C -> ember.
static func temperature_tint(celsius: float) -> Color:
	if celsius <= 0.0:
		var f: float = clampf(inverse_lerp(0.0, -60.0, celsius), 0.0, 1.0)
		return Color(1.0, 1.0, 1.0).lerp(Color(0.62, 0.80, 1.05), f)
	var g: float = clampf(inverse_lerp(20.0, 90.0, celsius), 0.0, 1.0)
	return Color(1.0, 1.0, 1.0).lerp(Color(1.25, 0.86, 0.66), g)


## Warm light colour for a heat source. Hotter sources get *brighter*, never
## whiter: the radiator lights used to climb to WARM_CORE (#ffd9a0), which after
## the additive glow pass and bloom landed on screen as a pure white disc and
## read as a rendering fault rather than as warmth. The ramp now tops out at
## amber, and intensity is expressed by energy, which is what fire actually does.
static func heat_light_color(intensity01: float) -> Color:
	var f: float = clampf(intensity01, 0.0, 1.0)
	if f < 0.55:
		return EMBER.lerp(WARM_EDGE, f / 0.55)
	return WARM_EDGE.lerp(WARM_MID, (f - 0.55) / 0.45)


# ------------------------------------------------------------ terrain params --
## Extra per-terrain shading parameters the ground shader needs, packed so the
## whole table can be uploaded as a 4-row palette texture instead of as shader
## uniform arrays (which the GL Compatibility backend is fussy about).
##
## x grain      fine speckle amount
## y ridges     wind-scour ridge amount (snow only)
## z sparkle    crystalline glint amount
## w relief     how much this surface deforms the lighting normal
static func terrain_params(kind: int) -> Color:
	match kind:
		Terrain.SNOW_DEEP: return Color(0.055, 1.00, 0.85, 1.00)
		Terrain.SNOW: return Color(0.070, 0.62, 0.60, 0.80)
		Terrain.ICE: return Color(0.040, 0.10, 1.00, 0.34)
		Terrain.ROCK: return Color(0.090, 0.18, 0.05, 1.00)
		Terrain.GRAVEL: return Color(0.150, 0.10, 0.08, 0.70)
		Terrain.ASH_FIELD: return Color(0.130, 0.40, 0.02, 0.85)
		Terrain.PAVED: return Color(0.050, 0.04, 0.04, 0.22)
		Terrain.WATER_FROZEN: return Color(0.030, 0.05, 0.75, 0.18)
		Terrain.RUBBLE: return Color(0.170, 0.12, 0.06, 0.90)
	return Color(0.070, 0.62, 0.60, 0.80)


## True when this terrain reads as an already-bare, warm or swept surface, so
## the ground shader keeps snow off it even when the sim has not melted it yet.
##
## ASH_FIELD USED TO BE ON THIS LIST AND IT COST THE GAME ITS WEATHER. The
## caldera floor is not a corner of the map: it is the ground the entire
## settlement stands on, and in every frame of `artifacts/CRIT/shots` it is the
## largest single shape on the screen. Telling the shader that snow never lies
## on it meant that the one surface the player looks at for three hours could
## not accumulate anything — no drift banked against a wall, no white in the lee
## of a shed, no difference between a clear morning and an afternoon of
## snowfall. It rendered as a flat warm-grey blob with a feathered edge, and the
## critic's "the ground carries no snow accumulation at play zoom" is that fact
## and nothing else.
##
## It takes snow now. It takes it BADLY — its drift rating is 0.40 against open
## snow's 0.62, so the crust only catches where the drift field is high — which
## is what volcanic grit under a scouring wind should do, and which leaves the
## machine yards bare, the hearth ring wet, the walked routes black, and white
## in the corners nobody heats.
static func terrain_sheds_snow(kind: int) -> bool:
	return kind == Terrain.WATER_FROZEN or kind == Terrain.ICE


## Ramp used by every readability overlay so heat, power and throughput all
## read on the same visual scale. 0 = cold/empty, 1 = saturated/full.
static func flow_ramp(v: float) -> Color:
	var f: float = clampf(v, 0.0, 1.0)
	if f < 0.34:
		return COLD_HIGH.lerp(STEEL_LIGHT, f / 0.34)
	if f < 0.67:
		return STEEL_LIGHT.lerp(WARM_EDGE, (f - 0.34) / 0.33)
	return WARM_EDGE.lerp(WARM_CORE, (f - 0.67) / 0.33)


## Deterministic small colour jitter so identical buildings do not look cloned.
static func jitter(c: Color, amount: float, seed_value: int) -> Color:
	var h: int = (seed_value * 2654435761) & 0x7FFFFFFF
	var f: float = (float(h % 1000) / 1000.0 - 0.5) * 2.0 * amount
	return Color(
		clampf(c.r + f, 0.0, 1.0),
		clampf(c.g + f * 0.92, 0.0, 1.0),
		clampf(c.b + f * 0.84, 0.0, 1.0),
		c.a
	)
