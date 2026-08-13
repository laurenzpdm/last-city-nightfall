class_name LcnVfxBreath
extends Node2D
## Visible breath. [P14]
##
## The smallest thing in this part and the one that does the most for the claim
## that a world is inhabited. Citizens exhale steam when the air is cold enough
## to condense it, from BREATH_START_C down, at full density by BREATH_FULL_C —
## so on a mild afternoon nobody steams, and in a Great Frost the whole street
## is breathing.
##
## It reads the same [method CitizenSystem.agents_for_view] the renderer draws
## the little figures off, so the puff always comes out of a person who is
## actually there, and it costs one pooled emitter for the entire population.
##
## Deliberately NOT tied to the citizen's own warmth. A cold citizen breathing
## harder would be a lovely idea and a bad one: [P19]'s lenses own per-citizen
## condition, and a second, quieter channel saying the same thing in the corner
## of the eye is how a player learns to distrust both.

## Citizens exhaling at once. Everyone on screen is neither affordable nor
## desirable — a street where every single figure puffs in lockstep reads as a
## machine, not as a crowd.
const BREATHERS: int = 26
## Frames between choosing which citizens are exhaling. Long enough that a puff
## finishes before its owner is replaced.
const ROTATE_FRAMES: int = 34

var field: LcnVfxPointField = null

var _citizens: SimSystem = null
var _has_agents: bool = false
var _pts: PackedVector2Array = PackedVector2Array()
var _frames: int = 0
var _rotate: int = 0
var _density: float = 0.0
var _population: int = 0


func setup() -> void:
	field = LcnVfxPointField.new()
	field.name = "Breath"
	add_child(field)
	field.configure({
		"amount": LcnVfxTuning.BREATH_AMOUNT, "lifetime": LcnVfxTuning.BREATH_LIFETIME,
		"texture": LcnVfxArt.texture("haze"), "z": 19,
		"direction": Vector2.UP, "spread_deg": 34.0,
		"speed_min": 8.0, "speed_max": 20.0, "gravity": Vector2(0.0, -9.0),
		"damping": 1.4, "scale_min": 0.055, "scale_max": 0.13,
		"ramp": LcnVfxArt.ramp([
			Color(LcnVfxTuning.BREATH.r, LcnVfxTuning.BREATH.g, LcnVfxTuning.BREATH.b, 0.0),
			Color(LcnVfxTuning.BREATH.r, LcnVfxTuning.BREATH.g, LcnVfxTuning.BREATH.b, 0.30),
			Color(LcnVfxTuning.BREATH.r, LcnVfxTuning.BREATH.g,
				LcnVfxTuning.BREATH.b, 0.0)] as Array[Color]),
	})


func bind_sim() -> void:
	_citizens = Sim.get_system(&"citizens")
	_has_agents = _citizens != null and _citizens.has_method("agents_for_view")


func update(view: Rect2, ambient_c: float, wind: Vector2, quality: float) -> void:
	_frames += 1
	_density = clampf(inverse_lerp(LcnVfxTuning.BREATH_START_C,
		LcnVfxTuning.BREATH_FULL_C, ambient_c), 0.0, 1.0)
	if _density <= 0.02 or not _has_agents:
		field.set_density(0.0)
		return
	# Breath is only legible at all when the camera is close enough to see a
	# person. Below that it is a haze over the whole city and a waste of a
	# particle buffer.
	if view.size.x > 2600.0:
		field.set_density(0.0)
		return
	if _frames % ROTATE_FRAMES == 1:
		_pick(view)
	field.set_view(view)
	field.set_wind(wind, 0.30, Vector2(0.0, -9.0))
	field.set_points(_pts)
	field.set_density(_density * clampf(quality, 0.0, 1.0) * 0.85)


## Takes a rotating stride through the roster so different people breathe on
## different beats, without sorting the population every frame.
func _pick(view: Rect2) -> void:
	_pts.clear()
	var rows: Array = _citizens.call("agents_for_view")
	_population = rows.size()
	if _population == 0:
		return
	_rotate = (_rotate + 7) % maxi(1, _population)
	var grown: Rect2 = view.grow(48.0)
	var stride: int = maxi(1, _population / BREATHERS)
	var i: int = _rotate
	var taken: int = 0
	var guard: int = 0
	while taken < BREATHERS and guard < _population:
		var row: Variant = rows[i % _population]
		guard += stride
		i += stride
		if typeof(row) != TYPE_DICTIONARY:
			continue
		var pos: Vector2 = (row as Dictionary).get("pos", Vector2.ZERO)
		if not grown.has_point(pos):
			continue
		# Mouth height, not foot height: the sprite stands on its cell.
		_pts.append(pos + Vector2(0.0, -11.0))
		taken += 1


func stats() -> Dictionary:
	return {
		"breathing": _pts.size(),
		"population": _population,
		"breath_density": snappedf(_density, 0.001),
	}
