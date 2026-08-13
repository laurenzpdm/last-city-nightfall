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
const SNOW_SHADOW: Color = Color(0.498, 0.573, 0.678)     # #7f92ad
const SNOW_MID: Color = Color(0.765, 0.812, 0.878)        # #c3cfe0
const SNOW: Color = Color(0.910, 0.933, 0.969)            # #e8eef7  ANCHOR
const SNOW_LIT: Color = Color(0.976, 0.988, 1.000)        # #f9fcff

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
const ASH: Color = Color(0.169, 0.149, 0.129)             # #2b2621
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
				"base": Color(0.851, 0.886, 0.937), "low": Color(0.663, 0.729, 0.816),
				"high": Color(0.976, 0.988, 1.000), "grain": 0.055, "ridges": 1.0,
			}
		Terrain.SNOW:
			return {
				"base": Color(0.749, 0.796, 0.867), "low": Color(0.545, 0.612, 0.714),
				"high": Color(0.902, 0.929, 0.969), "grain": 0.070, "ridges": 0.55,
			}
		Terrain.ICE:
			return {
				"base": Color(0.435, 0.545, 0.647), "low": Color(0.247, 0.345, 0.463),
				"high": Color(0.706, 0.827, 0.902), "grain": 0.040, "ridges": 0.0,
			}
		Terrain.ROCK:
			return {
				"base": Color(0.157, 0.196, 0.271), "low": Color(0.075, 0.102, 0.157),
				"high": Color(0.286, 0.341, 0.427), "grain": 0.090, "ridges": 0.0,
			}
		Terrain.GRAVEL:
			return {
				"base": Color(0.208, 0.243, 0.310), "low": Color(0.114, 0.141, 0.196),
				"high": Color(0.353, 0.396, 0.475), "grain": 0.150, "ridges": 0.0,
			}
		Terrain.ASH_FIELD:
			# Warm volcanic grit, not a hole in the map. The caldera floor is where
			# the whole city stands: at the old values it read as a black disc and
			# every road, wall and citizen inside it was invisible.
			return {
				"base": Color(0.262, 0.232, 0.203), "low": Color(0.171, 0.150, 0.128),
				"high": Color(0.392, 0.344, 0.288), "grain": 0.130, "ridges": 0.0,
			}
		Terrain.PAVED:
			return {
				"base": Color(0.196, 0.231, 0.302), "low": Color(0.094, 0.118, 0.169),
				"high": Color(0.310, 0.353, 0.435), "grain": 0.050, "ridges": 0.0,
			}
		Terrain.WATER_FROZEN:
			return {
				"base": Color(0.086, 0.129, 0.208), "low": Color(0.043, 0.071, 0.125),
				"high": Color(0.353, 0.478, 0.580), "grain": 0.030, "ridges": 0.0,
			}
		Terrain.RUBBLE:
			return {
				"base": Color(0.184, 0.184, 0.200), "low": Color(0.086, 0.086, 0.102),
				"high": Color(0.353, 0.341, 0.341), "grain": 0.170, "ridges": 0.0,
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
##   sky           Color, CanvasModulate tint for the world canvas
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
static func _keyframes() -> Array[Dictionary]:
	return [
		{
			"t": 0.00, "name": &"deep_night",
			"sky": Color(0.115, 0.150, 0.255), "ambient": Color(0.090, 0.130, 0.230),
			"shadow": Color(0.030, 0.050, 0.100), "shadow_alpha": 0.30,
			"shadow_dir": Vector2(0.05, 0.55), "shadow_len": 0.9,
			"lift": Color(0.010, 0.018, 0.040), "gain": Color(0.86, 0.92, 1.10),
			"sat": 0.78, "fog": Color(0.075, 0.106, 0.192), "fog_amt": 0.30,
			"light_energy": 1.60, "bloom": 1.30, "chroma": 1.00, "star_amt": 1.00,
		},
		{
			"t": 0.19, "name": &"night",
			"sky": Color(0.150, 0.195, 0.320), "ambient": Color(0.120, 0.165, 0.290),
			"shadow": Color(0.035, 0.055, 0.110), "shadow_alpha": 0.34,
			"shadow_dir": Vector2(-0.35, 0.60), "shadow_len": 1.2,
			"lift": Color(0.008, 0.015, 0.034), "gain": Color(0.90, 0.95, 1.10),
			"sat": 0.82, "fog": Color(0.086, 0.118, 0.208), "fog_amt": 0.26,
			"light_energy": 1.45, "bloom": 1.20, "chroma": 0.85, "star_amt": 0.85,
		},
		{
			"t": 0.27, "name": &"dawn",
			"sky": Color(0.420, 0.500, 0.660), "ambient": Color(0.330, 0.420, 0.600),
			"shadow": Color(0.075, 0.102, 0.180), "shadow_alpha": 0.44,
			"shadow_dir": Vector2(-0.86, 0.51), "shadow_len": 2.7,
			"lift": Color(0.004, 0.010, 0.026), "gain": Color(0.95, 0.99, 1.12),
			"sat": 0.88, "fog": Color(0.290, 0.360, 0.490), "fog_amt": 0.42,
			"light_energy": 1.10, "bloom": 0.85, "chroma": 0.55, "star_amt": 0.25,
		},
		{
			"t": 0.37, "name": &"morning",
			"sky": Color(0.720, 0.780, 0.880), "ambient": Color(0.600, 0.670, 0.790),
			"shadow": Color(0.110, 0.140, 0.220), "shadow_alpha": 0.42,
			"shadow_dir": Vector2(-0.52, 0.62), "shadow_len": 1.6,
			"lift": Color(0.002, 0.006, 0.018), "gain": Color(0.99, 1.00, 1.06),
			"sat": 0.90, "fog": Color(0.470, 0.540, 0.650), "fog_amt": 0.26,
			"light_energy": 0.75, "bloom": 0.60, "chroma": 0.35, "star_amt": 0.0,
		},
		{
			"t": 0.50, "name": &"noon",
			"sky": Color(0.925, 0.950, 0.995), "ambient": Color(0.820, 0.860, 0.930),
			"shadow": Color(0.150, 0.185, 0.270), "shadow_alpha": 0.38,
			"shadow_dir": Vector2(-0.10, 0.56), "shadow_len": 0.75,
			"lift": Color(0.000, 0.003, 0.012), "gain": Color(1.02, 1.02, 1.03),
			"sat": 0.72, "fog": Color(0.640, 0.690, 0.770), "fog_amt": 0.16,
			"light_energy": 0.45, "bloom": 0.45, "chroma": 0.22, "star_amt": 0.0,
		},
		{
			"t": 0.63, "name": &"afternoon",
			"sky": Color(0.880, 0.845, 0.815), "ambient": Color(0.760, 0.740, 0.740),
			"shadow": Color(0.140, 0.150, 0.230), "shadow_alpha": 0.42,
			"shadow_dir": Vector2(0.46, 0.60), "shadow_len": 1.5,
			"lift": Color(0.002, 0.005, 0.016), "gain": Color(1.04, 1.00, 0.98),
			"sat": 0.82, "fog": Color(0.610, 0.610, 0.660), "fog_amt": 0.22,
			"light_energy": 0.70, "bloom": 0.60, "chroma": 0.30, "star_amt": 0.0,
		},
		{
			"t": 0.74, "name": &"dusk",
			"sky": Color(0.720, 0.505, 0.395), "ambient": Color(0.540, 0.410, 0.380),
			"shadow": Color(0.090, 0.085, 0.150), "shadow_alpha": 0.50,
			"shadow_dir": Vector2(0.86, 0.50), "shadow_len": 2.9,
			"lift": Color(0.008, 0.008, 0.024), "gain": Color(1.12, 0.97, 0.90),
			"sat": 0.98, "fog": Color(0.520, 0.360, 0.320), "fog_amt": 0.40,
			"light_energy": 1.05, "bloom": 0.95, "chroma": 0.40, "star_amt": 0.10,
		},
		{
			"t": 0.83, "name": &"twilight",
			"sky": Color(0.330, 0.295, 0.400), "ambient": Color(0.250, 0.250, 0.370),
			"shadow": Color(0.055, 0.060, 0.115), "shadow_alpha": 0.42,
			"shadow_dir": Vector2(0.55, 0.58), "shadow_len": 1.8,
			"lift": Color(0.010, 0.014, 0.032), "gain": Color(1.00, 0.96, 1.02),
			"sat": 0.88, "fog": Color(0.250, 0.240, 0.330), "fog_amt": 0.34,
			"light_energy": 1.30, "bloom": 1.10, "chroma": 0.65, "star_amt": 0.55,
		},
		{
			"t": 1.00, "name": &"deep_night",
			"sky": Color(0.115, 0.150, 0.255), "ambient": Color(0.090, 0.130, 0.230),
			"shadow": Color(0.030, 0.050, 0.100), "shadow_alpha": 0.30,
			"shadow_dir": Vector2(0.05, 0.55), "shadow_len": 0.9,
			"lift": Color(0.010, 0.018, 0.040), "gain": Color(0.86, 0.92, 1.10),
			"sat": 0.78, "fog": Color(0.075, 0.106, 0.192), "fog_amt": 0.30,
			"light_energy": 1.60, "bloom": 1.30, "chroma": 1.00, "star_amt": 1.00,
		},
	]


## Interpolated colour grade for a normalised time of day (0..1, wraps).
static func grade_at(day_t: float) -> Dictionary:
	var t: float = fposmod(day_t, 1.0)
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
	return blend(a, b, f)


## Linear blend of two grade dictionaries. Public so a storm/event system can
## crossfade toward a custom grade without reimplementing the interpolation.
static func blend(a: Dictionary, b: Dictionary, f: float) -> Dictionary:
	var out: Dictionary = {}
	out["name"] = a["name"] if f < 0.5 else b["name"]
	for key: String in ["sky", "ambient", "shadow", "lift", "gain", "fog"]:
		out[key] = (a[key] as Color).lerp(b[key] as Color, f)
	for key: String in [
		"shadow_alpha", "shadow_len", "sat", "fog_amt",
		"light_energy", "bloom", "chroma", "star_amt",
	]:
		out[key] = lerpf(float(a[key]), float(b[key]), f)
	out["shadow_dir"] = ((a["shadow_dir"] as Vector2).lerp(b["shadow_dir"] as Vector2, f)).normalized()
	return out


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


## Warm light colour for a heat source, hotter sources shifting toward white.
static func heat_light_color(intensity01: float) -> Color:
	var f: float = clampf(intensity01, 0.0, 1.0)
	if f < 0.5:
		return EMBER.lerp(WARM_EDGE, f * 2.0)
	return WARM_EDGE.lerp(WARM_CORE, (f - 0.5) * 2.0)


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
