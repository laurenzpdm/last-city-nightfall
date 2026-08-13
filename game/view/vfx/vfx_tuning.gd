class_name LcnVfxTuning
extends RefCounted
## Every number [P14] uses, in one file. [P14] VFX & Weather
##
## The rest of the part reads from here and nowhere else, so a look can be
## retuned without touching a system, and so a critic can read the whole art
## direction of the effects layer in two screens instead of grepping for magic
## floats.
##
## THE BUDGET IS THE DESIGN. The renderer holds 60 fps at 1700 buildings in 8
## draw calls and the tick budget is 50 ms with heat already taking 86% of it.
## So every cap below is a hard cap, not a target: emitters are pooled and
## reused, particle counts are fixed at construction (a GPUParticles2D restarts
## when `amount` changes, which is a hitch), and live density is scaled with
## `amount_ratio` instead. Nothing here allocates per frame.

# ---------------------------------------------------------------- hard caps --

## Live transient particles in the additive burst buffer (muzzle flash, sparks,
## embers thrown by an explosion, ice shards). Oldest die first when full.
const BURST_ADD_MAX: int = 640
## Live transient particles in the mixed buffer (smoke, debris, ash, snow splat).
const BURST_MIX_MAX: int = 480
## Live tracer/beam segments drawn per frame.
const BEAM_MAX: int = 96
## Emission points uploaded to one GPU point-field per frame.
const POINTS_MAX: int = 48
## Buildings inspected per classification sweep. Sorted by screen importance
## first, so the cap drops the structures a player is least likely to look at.
const SOURCE_SCAN_MAX: int = 220
## Frames between rebuilds of the industry source list. Sources change on the
## scale of a construction, not of a frame.
const SOURCE_REFRESH_FRAMES: int = 6
## Frames between rebuilds of the damaged/freezing structure list.
const DECAY_REFRESH_FRAMES: int = 12
## Frames between refreshes of the turret -> weapon profile table.
const WEAPON_REFRESH_FRAMES: int = 90
## Enemy kinds remembered for a death effect. A wave is hundreds, not thousands.
const ENEMY_MEMORY_MAX: int = 2048

# ------------------------------------------------------------------ weather --

## Snow layers. Near flakes are big, fast and blurred; far flakes are a haze.
## amount is the fixed GPU buffer; ratio is what the weather scales.
## `size` multiplies a 32 px sprite, so 0.17 is a six-pixel mote and 0.55 an
## eighteen-pixel crystal. Two calibration passes against real frames are baked
## into these numbers: the first shipped 1.05/1.9/3.4, a hundred-pixel snowflake
## per particle, which read as decorative symbols printed over the city; the
## correction to 0.10/0.18/0.34 at 870 particles was invisible on a 1920x1080
## frame. Distance is carried by the two far layers being soft motes and only
## the near layer being a crystal you can see the arms of.
##
## 3700 particles is a large number and a cheap one: three GPUParticles2D are
## three draw calls whatever they hold, the stepping is on the GPU, and the
## measured cost of the whole weather layer is 6 draw calls and a fraction of a
## millisecond (tests/vfx/vfx_gpu.tscn prints both). Sparse snow was the thing
## that read as wrong.
const SNOW_LAYERS: Array[Dictionary] = [
	{"name": "SnowFar", "amount": 1800, "size": 0.16, "fall": 36.0, "alpha": 0.50,
		"drift": 0.45, "spin": 0.0, "z": 52, "art": "mote"},
	{"name": "SnowMid", "amount": 1300, "size": 0.29, "fall": 68.0, "alpha": 0.72,
		"drift": 0.75, "spin": 1.2, "z": 54, "art": "mote"},
	# z 59 puts the near layer ABOVE the whiteout veil (58). Snow a metre from
	# the camera is in front of the fog, not inside it, and keeping it there is
	# what stops a Great Frost turning into a flat blue filter with the flakes
	# dissolved into it.
	{"name": "SnowNear", "amount": 600, "size": 0.52, "fall": 116.0, "alpha": 0.62,
		"drift": 1.15, "spin": 2.4, "z": 59, "art": "flake"},
]

## Weather kind -> {snow, whiteout, gust}. `snow` scales every layer's ratio,
## `whiteout` is the opaque veil that actually costs the player sight, `gust`
## is spindrift torn off the settled drifts.
const WEATHER: Dictionary[StringName, Dictionary] = {
	&"clear":       {"snow": 0.00, "whiteout": 0.00, "gust": 0.05},
	&"overcast":    {"snow": 0.10, "whiteout": 0.00, "gust": 0.10},
	&"snowfall":    {"snow": 0.55, "whiteout": 0.06, "gust": 0.25},
	&"blizzard":    {"snow": 1.00, "whiteout": 0.34, "gust": 0.70},
	&"great_frost": {"snow": 1.00, "whiteout": 0.62, "gust": 1.00},
}

## Hard ceiling on the whiteout veil. A Great Frost must genuinely cost sight —
## that is the whole point of the storm — but the city has to stay findable, so
## the veil never goes fully opaque and the HUD sits above it either way.
const WHITEOUT_MAX: float = 0.62
## Ceiling used instead when accessibility.reduce_motion is on. Still a real
## loss of visibility, without the churning.
const WHITEOUT_MAX_CALM: float = 0.34
## Seconds a whiteout takes to build or clear. Weather that snaps looks scripted.
const WHITEOUT_LERP: float = 0.55

## Wind speed in pixels/second at wind() == 1.0.
const WIND_SPEED_PX: float = 210.0
## Fraction of the wind vector that is vertical. Snow that blows purely sideways
## reads as rain in a gale; a little vertical shear reads as weather.
const WIND_VERTICAL: float = 0.22
## How fast the wind direction wanders, in radians per second of world time.
const WIND_TURN_RATE: float = 0.043

# ------------------------------------------------------------------ ambient --

## Embers rising off anything with a firebox.
const EMBER_AMOUNT: int = 220
const EMBER_LIFETIME: float = 2.6
## Smoke plumes. Long-lived, wind-bent, thicker with industry.
const SMOKE_AMOUNT: int = 260
const SMOKE_LIFETIME: float = 5.5
## Sparks off a machine that is actually crafting this tick.
const SPARK_AMOUNT: int = 140
const SPARK_LIFETIME: float = 0.7
## Hot air off radiators. The post stack already refracts the frame over the heat
## field ([P13]); this is the visible carrier so the refraction has something to
## sit on at low zoom.
const HAZE_AMOUNT: int = 120
const HAZE_LIFETIME: float = 2.2
## Visible breath. Small on purpose — this is a detail, not an effect.
const BREATH_AMOUNT: int = 180
const BREATH_LIFETIME: float = 1.5
## Below this air temperature breath is visible at all; at BREATH_FULL_C it is
## at its densest.
const BREATH_START_C: float = 4.0
const BREATH_FULL_C: float = -22.0
## Damage smoke off structures that have lost health.
const DAMAGE_AMOUNT: int = 200
const DAMAGE_LIFETIME: float = 3.4
## A structure smokes once it has lost this fraction of its health.
const DAMAGE_AT: float = 0.12

# -------------------------------------------------------------------- combat --

## Seconds a hitscan tracer stays on screen. Long enough to read at 60 fps,
## short enough that a full battery does not turn the frame into string.
const TRACER_LIFE: float = 0.11
## Seconds a muzzle flash lasts.
const MUZZLE_LIFE: float = 0.075
## Length of a muzzle flash in pixels at flash birth.
const MUZZLE_LEN: float = 26.0
## Seconds a flamethrower cone is held on screen after its signal tick. [P07]
## re-announces a sustained cone every CONE_SIGNAL_TICKS, so this must outlast
## that gap or the cone strobes.
const CONE_LIFE: float = 0.55
## Impact spark count for a normal hit, and for a splash weapon.
const IMPACT_SPARKS: int = 7
const EXPLOSION_SPARKS: int = 22
const EXPLOSION_DEBRIS: int = 10
## Pixels of splash radius above which a hit is drawn as an explosion.
const EXPLOSION_AT_PX: float = 24.0

## How a kill reads, per enemy family. Chosen off the enemy id so a player learns
## what died from the corner of their eye.
##  ice    — a frozen thing comes apart into shards
##  ember  — a burning thing bursts and gutters out
##  beast  — a body falls: ash, a puff, no fireworks
const DEATH_STYLE: Dictionary[StringName, StringName] = {
	&"frost_shade": &"ice", &"hoarfrost_breaker": &"ice", &"permafrost_borer": &"ice",
	&"rime_sapper": &"ice", &"the_long_cold": &"ice",
	&"ash_spitter": &"ember", &"cinder_leech": &"ember",
	&"drift_hound": &"beast", &"pale_stalker": &"beast", &"keener": &"beast",
}
const DEATH_STYLE_DEFAULT: StringName = &"beast"

# ------------------------------------------------------------------ industry --

## kind -> effect class. Anything unlisted is classified from its sprite
## archetype instead, so a building added by another part still smokes.
##  furnace  — open fire: embers, a tall plume, real light
##  works    — machinery: sparks when it crafts, a thin plume
##  vent     — radiated heat: haze only, no soot
const FX_CLASS: Dictionary[StringName, StringName] = {
	&"the_hearth": &"furnace", &"coal_generator": &"furnace",
	&"geothermal_tap": &"furnace", &"smelter": &"furnace",
	&"workshop": &"works", &"assembly_hall": &"works", &"rubble_sorter": &"works",
	&"field_kitchen": &"works", &"ore_drill": &"works", &"scrap_collector": &"works",
	&"survey_hall": &"works",
	&"warmth_radiator": &"vent", &"heat_booster_pump": &"vent",
	&"recuperator": &"vent", &"heat_accumulator": &"vent",
	# A pipe is a buried conduit, not a vent. Left in, the mains alone filled the
	# entire emission-point budget and the radiators they feed — the things that
	# actually put warmth into the air — never got an emitter.
	&"heat_pipe": &"none", &"heat_pipe_insulated": &"none",
	&"heat_trunk_main": &"none", &"rubble_road": &"none", &"wall": &"none",
}

# ------------------------------------------------------------------- colours --

const EMBER_HOT: Color = Color(1.000, 0.851, 0.627)
const EMBER_MID: Color = Color(1.000, 0.541, 0.239)
const EMBER_DIM: Color = Color(0.780, 0.220, 0.090)
const SMOKE_LIGHT: Color = Color(0.420, 0.430, 0.470)
const SMOKE_DARK: Color = Color(0.140, 0.135, 0.140)
const SNOW_FLAKE: Color = Color(0.976, 0.988, 1.000)
const ICE: Color = Color(0.541, 0.749, 0.851)
const ICE_PALE: Color = Color(0.800, 0.900, 0.960)
const ASH: Color = Color(0.169, 0.149, 0.129)
const BREATH: Color = Color(0.870, 0.920, 0.960)
const SPARK: Color = Color(1.000, 0.930, 0.700)


## The effect class for a building kind, falling back to its sprite archetype so
## a kind this table has never heard of still behaves sensibly.
static func fx_class(kind: StringName, arch: StringName) -> StringName:
	var direct: StringName = FX_CLASS.get(kind, &"")
	if direct != &"":
		return direct
	var a: String = String(arch)
	if a.contains("generator") or a.contains("hearth") or a.contains("furnace") \
			or a.contains("smelt"):
		return &"furnace"
	if a.contains("pipe") or a.contains("road") or a.contains("wall"):
		return &"none"
	if a.contains("radiator") or a.contains("accumulator"):
		return &"vent"
	if a.contains("workshop") or a.contains("factory") or a.contains("drill") \
			or a.contains("assembly") or a.contains("mine"):
		return &"works"
	return &"none"


## How a kill of `kind` should read.
static func death_style(kind: StringName) -> StringName:
	return DEATH_STYLE.get(kind, DEATH_STYLE_DEFAULT)


## Weather row for a climate weather name, with a sane default for a name this
## table has not been taught.
static func weather_row(name: StringName) -> Dictionary:
	return WEATHER.get(name, WEATHER[&"snowfall"])
