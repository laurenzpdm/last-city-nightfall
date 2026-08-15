class_name LcnPreviewWorld
extends RefCounted
## A stand-in world so the art direction is always visible. [P13]
##
## Parts are built in parallel: on day one there is no grid, no build system and
## no citizens, and a renderer with nothing to render proves nothing. This class
## synthesises a frozen plain, a plausible settlement and people walking between
## its buildings, entirely inside view/, so a screenshot of the real build shows
## the real lighting, the real shaders and the real sprites.
##
## It is *replaced*, never merged: the moment Sim exposes a grid system,
## LcnWorldModel stops calling any of this. `LcnWorldModel.using_preview()`
## reports which one you are looking at and the renderer logs it every run.
##
## Deterministic by construction — seeded from Rng.seed_value, and it never
## touches an Rng stream, so it cannot perturb simulation replay.

const TILE: int = 32

var size: Vector2i = Vector2i(500, 500)
var centre: Vector2i = Vector2i(250, 250)
var buildings: Array[Dictionary] = []
var agents: Array[Dictionary] = []

var _seed: int = 0
var _roads: Dictionary[int, bool] = {}
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()


func _init(world_seed: int, world_size: Vector2i = Vector2i(500, 500), core: Vector2i = Vector2i(-1, -1)) -> void:
	_seed = world_seed & 0x7FFFFFF
	_rng.seed = _seed ^ 0x5eed13
	size = world_size
	# The settlement needs room for its perimeter wall inside the map.
	var margin: int = 36
	if core.x >= 0:
		centre = Vector2i(
			clampi(core.x, margin, maxi(margin, size.x - margin)),
			clampi(core.y, margin, maxi(margin, size.y - margin)))
	else:
		centre = size / 2


func generate() -> void:
	_lay_roads()
	_place_settlement()
	_spawn_agents()


# ------------------------------------------------------------------ terrain --

func terrain_at(cell: Vector2i) -> int:
	if _roads.has(_key(cell)):
		return LcnPalette.Terrain.PAVED
	var fx: float = float(cell.x)
	var fy: float = float(cell.y)
	var elev: float = LcnNoise.fbm(fx * 0.011, fy * 0.011, _seed + 17, 3)
	elev += (LcnNoise.fbm(fx * 0.045, fy * 0.045, _seed + 91, 2) - 0.5) * 0.22
	if elev < 0.345:
		return LcnPalette.Terrain.WATER_FROZEN
	if elev < 0.395:
		return LcnPalette.Terrain.ICE
	if elev > 0.700:
		return LcnPalette.Terrain.ROCK
	if elev > 0.645:
		return LcnPalette.Terrain.GRAVEL
	var detail: float = LcnNoise.fbm(fx * 0.075, fy * 0.075, _seed + 233, 2)
	# The lee side of the ridges is where the deep drifts pile up.
	if detail > 0.58 and elev < 0.58:
		return LcnPalette.Terrain.SNOW_DEEP
	if detail < 0.30:
		return LcnPalette.Terrain.GRAVEL
	return LcnPalette.Terrain.SNOW


static func _key(cell: Vector2i) -> int:
	return cell.x * 100003 + cell.y


# ---------------------------------------------------------------- settlement --

## A plaza off the generator, three avenues that do not agree with each other,
## and one ring that only ever got two thirds of the way round.
##
## IT USED TO BE A MANDALA. Four avenues of identical length on the two screen
## axes, two complete concentric rings, and a plaza centred on the core: the road
## plan was symmetric under reflection in BOTH axes, so the left of the frame was
## the right of the frame and a critic said the opening settlement "reads as
## generated rather than settled". That is exactly what it was — the output of
## `for i in range(-30, 31)`, four times.
##
## A town is not laid out, it is arrived at. The main street runs where the
## ground let it and is longer one way than the other; the second street meets it
## at an angle nobody would draw; the third is a short spur to the mine. The ring
## road was surveyed all the way round and built as far as the money went. The
## numbers are still FIXED, not random: the frame lab has to photograph the same
## city every run or a shader change and a layout change are indistinguishable.
func _lay_roads() -> void:
	# The plaza sits north-west of the core rather than around it, because the
	# core was dropped first and the market grew on the sheltered side.
	for r: int in range(-7, 3):
		for c: int in range(-8, 4):
			_roads[_key(centre + Vector2i(c, r))] = true
	# The main street: long to the east where the plain is flat, short to the
	# west where it runs into rising ground.
	_street(Vector2i(-17, -2), Vector2i(31, -2), 2)
	# The second street leaves it at an angle. Nothing on this map is at right
	# angles to anything else except the belt line, which is machinery.
	_street(Vector2i(2, -26), Vector2i(-6, 24), 2)
	# A spur to the mine, one lane wide, and a lane down to the south gate.
	_street(Vector2i(-9, -9), Vector2i(-24, -16), 1)
	_street(Vector2i(4, 6), Vector2i(9, 27), 1)
	# The ring road, surveyed as a circle and built in two arcs with a gap in the
	# north-east where it was abandoned.
	_arc(21, 0.10, 0.62)
	_arc(21, 0.72, 1.02)


## A straight run of road from a to b, `half` tiles either side of the line.
## Bresenham-free: it is a rasterised segment, which is what a surveyed street is.
func _street(from: Vector2i, to: Vector2i, half: int) -> void:
	var a := Vector2(from)
	var b := Vector2(to)
	var steps: int = int(maxf(absf(b.x - a.x), absf(b.y - a.y))) * 2
	for s: int in range(steps + 1):
		var p: Vector2 = a.lerp(b, float(s) / float(maxi(steps, 1)))
		var cell := Vector2i(int(round(p.x)), int(round(p.y)))
		for dy: int in range(-half, half + 1):
			for dx: int in range(-half, half + 1):
				_roads[_key(centre + cell + Vector2i(dx, dy))] = true


## An arc of the ring road, `from`..`to` in turns (0..1).
func _arc(radius: int, from: float, to: float) -> void:
	var steps: int = int(float(radius) * TAU * (to - from) * 2.0)
	for s: int in range(maxi(steps, 1) + 1):
		var ang: float = lerpf(from, to, float(s) / float(maxi(steps, 1))) * TAU
		var cell := Vector2i(int(round(cos(ang) * float(radius))),
			int(round(sin(ang) * float(radius) * 0.88)))
		for dy: int in range(-1, 1):
			for dx: int in range(-1, 2):
				_roads[_key(centre + cell + Vector2i(dx, dy))] = true


func _place_settlement() -> void:
	var id: int = 1
	buildings.append({"id": id, "kind": &"generator_core", "cell": centre - Vector2i(1, 1)})
	id += 1

	# Industry hugs the north-west avenue, housing spreads south and east.
	var plan: Array[Dictionary] = [
		{"kind": &"heat_plant", "at": Vector2i(-11, -8)},
		{"kind": &"heat_plant", "at": Vector2i(6, -12)},
		{"kind": &"foundry", "at": Vector2i(-19, -6)},
		{"kind": &"workshop", "at": Vector2i(-11, 4)},
		{"kind": &"workshop", "at": Vector2i(-19, 4)},
		{"kind": &"workshop", "at": Vector2i(9, 6)},
		{"kind": &"depot", "at": Vector2i(-20, 10)},
		{"kind": &"depot", "at": Vector2i(6, 16)},
		{"kind": &"mine_shaft", "at": Vector2i(-25, -16)},
		{"kind": &"greenhouse", "at": Vector2i(11, -6)},
		{"kind": &"greenhouse", "at": Vector2i(16, -6)},
		# A SETTLEMENT, NOT A SUBDIVISION. These used to be 5, 10, 15 across and
		# 4, 10 down: two perfect rows of three, which is the single loudest
		# "this was generated" cue a city-builder frame can carry, and a critic
		# named it. People build where the ground and the road let them, so the
		# rows are broken up and nothing shares a spacing with its neighbour.
		# Still fixed numbers, not noise: a placeholder city has to be the same
		# city in every frame or a shader change and a layout change are
		# indistinguishable between two runs of the frame lab.
		{"kind": &"habitat", "at": Vector2i(5, 3)},
		{"kind": &"habitat", "at": Vector2i(11, 5)},
		{"kind": &"habitat", "at": Vector2i(16, 3)},
		{"kind": &"habitat", "at": Vector2i(4, 10)},
		{"kind": &"habitat", "at": Vector2i(9, 12)},
		{"kind": &"habitat", "at": Vector2i(15, 9)},
		{"kind": &"habitat", "at": Vector2i(-9, 12)},
		{"kind": &"habitat", "at": Vector2i(-16, 10)},
		{"kind": &"habitat", "at": Vector2i(-5, 18)},
		{"kind": &"habitat", "at": Vector2i(-12, 16)},
		{"kind": &"watchtower", "at": Vector2i(-4, -20)},
		{"kind": &"watchtower", "at": Vector2i(18, 18)},
	]
	for p: Dictionary in plan:
		buildings.append({"id": id, "kind": p["kind"], "cell": centre + (p["at"] as Vector2i)})
		id += 1

	# Pylons follow the avenues; the eye should be able to trace the grid. A
	# pylon line IS regular — it is surveyed infrastructure and it should read
	# that way — but the two runs no longer step in lockstep, so the frame does
	# not fold onto itself about the plaza.
	for i: int in range(-24, 25, 8):
		if absi(i) < 6:
			continue
		buildings.append({"id": id, "kind": &"pylon", "cell": centre + Vector2i(i, -3)})
		id += 1
	for j: int in range(-21, 26, 9):
		if absi(j) < 6:
			continue
		buildings.append({"id": id, "kind": &"pylon", "cell": centre + Vector2i(3, j)})
		id += 1

	# Defensive line on the perimeter, guns pointing outward.
	#
	# This used to be four identical sides: a wall every third tile, all the way
	# round, on all four sides. In the frame lab it showed up as two columns of
	# evenly spaced black dashes at mirrored positions down the left and right of
	# the screen — the most machine-made thing in the picture. A wall a city
	# actually built has been repaired in places, run out of steel in others and
	# been rebuilt tighter where something came through, so each side now has its
	# own spacing and its own gaps, and no side is another side reflected.
	var ring: int = 29
	var sides: Array[Dictionary] = [
		{"step": 3, "phase": 0, "gap": Vector2i(11, 15), "dir": Vector2i(1, 0), "off": Vector2i(0, -1)},
		{"step": 4, "phase": 1, "gap": Vector2i(-19, -13), "dir": Vector2i(1, 0), "off": Vector2i(0, 1)},
		{"step": 3, "phase": 2, "gap": Vector2i(-8, -5), "dir": Vector2i(0, 1), "off": Vector2i(-1, 0)},
		{"step": 5, "phase": 0, "gap": Vector2i(17, 24), "dir": Vector2i(0, 1), "off": Vector2i(1, 0)},
	]
	for sd: Dictionary in sides:
		var step: int = sd["step"]
		var dir: Vector2i = sd["dir"]
		var off: Vector2i = sd["off"]
		var gap: Vector2i = sd["gap"]
		var i2: int = -ring + int(sd["phase"])
		while i2 <= ring:
			# The gate, and one breach nobody has got round to closing.
			if absi(i2) >= 4 and not (i2 >= gap.x and i2 <= gap.y):
				buildings.append({"id": id, "kind": &"wall",
					"cell": centre + dir * i2 + off * ring})
				id += 1
			i2 += step
	for t: Vector2i in [
		Vector2i(-ring, -ring), Vector2i(ring, -ring), Vector2i(-ring, ring), Vector2i(ring, ring),
		Vector2i(0, -ring - 2), Vector2i(0, ring + 2), Vector2i(-ring - 2, 0), Vector2i(ring + 2, 0),
	]:
		buildings.append({"id": id, "kind": &"turret", "cell": centre + t})
		id += 1

	# Belt and pipe runs, the automation spine.
	for i3: int in range(-18, 0):
		buildings.append({"id": id, "kind": &"belt", "cell": centre + Vector2i(i3, -7)})
		id += 1
	for i4: int in range(-10, 6):
		buildings.append({"id": id, "kind": &"pipe", "cell": centre + Vector2i(i4, 7)})
		id += 1


# ------------------------------------------------------------------- agents --

## The crowd of a working town: mostly crew, a quarter idle, porters on the
## depot run and a few on the wall. Four SHAPES, so a still of the placeholder
## city shows the same mix of figures a real session does.
func _spawn_agents() -> void:
	var kinds: Array[StringName] = [
		&"worker", &"citizen", &"worker", &"porter", &"citizen",
		&"worker", &"soldier", &"porter", &"citizen", &"worker",
	]
	for i: int in 46:
		var a: float = _rng.randf() * TAU
		var r: float = _rng.randf() * 22.0
		var pos := Vector2(float(centre.x) + cos(a) * r, float(centre.y) + sin(a) * r) * float(TILE)
		agents.append({
			"id": 90000 + i,
			"kind": kinds[i % kinds.size()],
			"pos": pos,
			"target": pos,
			"speed": 0.9 + _rng.randf() * 0.7,
		})
	for i2: int in agents.size():
		_retarget(agents[i2], i2)


func _retarget(a: Dictionary, salt: int) -> void:
	var choices: Array[Dictionary] = []
	for b: Dictionary in buildings:
		if b["id"] >= 10000:
			continue
		choices.append(b)
	if choices.is_empty():
		return
	var idx: int = absi(int(LcnNoise.hash3(int(a["id"]), salt, _seed) * 9973.0)) % choices.size()
	var cell: Vector2i = choices[idx]["cell"]
	a["target"] = Vector2(float(cell.x) + 1.0, float(cell.y) + 2.2) * float(TILE)


## One deterministic tick of walking. No delta, no randf() — SimClock only.
func step_agents(tick: int) -> void:
	for i: int in agents.size():
		var a: Dictionary = agents[i]
		var pos: Vector2 = a["pos"]
		var target: Vector2 = a["target"]
		var to: Vector2 = target - pos
		var dist: float = to.length()
		if dist < 6.0:
			_retarget(a, tick + i)
			continue
		var step: float = float(a["speed"]) * 1.35
		# A little lateral wander so the crowd does not march in straight lines.
		var wobble: Vector2 = Vector2(-to.y, to.x).normalized() * sin(float(tick) * 0.09 + float(i)) * 0.35
		a["pos"] = pos + to / dist * step + wobble
