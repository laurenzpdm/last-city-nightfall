class_name LcnScenery
extends RefCounted
## What is standing on the plain when nobody built it. [P13]
##
## THE DEFECT THIS EXISTS FOR. Open `artifacts/*/shots/opening.world.png` from
## the last build: outside the settlement there is NOTHING. Not a rock, not a
## dead tree, not a wreck — a hundred by sixty tiles of shaded gradient with a
## thin ribbon of belts across the middle. A critic said the frame "reads as
## empty" and that the city "does not occupy the screen", and half of that
## sentence is about the city being small and half of it is about the other
## ninety per cent of the screen having nothing in it at any distance.
##
## The [P13] preview settlement used to scatter 260 props around itself, which
## is why the frame lab's photographs looked furnished and the actual game did
## not: the props were part of the PLACEHOLDER, so they vanished the moment a
## real simulation supplied real buildings. This class replaces that with
## scenery derived from the TERRAIN, so it is there in every run, and it is
## there for a reason a player can read — outcrops on the rock shelves, dead
## stands in the deep drifts, wrecks and ruin where something used to be.
##
## IT IS NOT MANUFACTURED EVIDENCE, and the line matters in this project. A
## screenshot of buildings the simulation does not have is a lie about the run
## (see LcnWorldModel.preview_allowed). A boulder on a rock tile is not a claim
## about anything the simulation owns; it is the same statement the ground
## shader is already making about that tile in paint, made in silhouette so it
## has a size and casts a shadow. Nothing here is placed where the city is, is
## selectable, blocks anything, or appears in any state dump.
##
## Deterministic and cached by chunk: the same world seed and the same tile
## always produce the same rock, so a frame is the same frame twice and the
## camera can leave and come back.

const TILE: int = 32
## Tiles per generated block. Matches the terrain chunk so a block's terrain
## reads come out of one cached chunk instead of four.
const CHUNK: int = 32
## Candidate slots per chunk. Most are refused by the terrain; this is the
## ceiling, not the count.
const PER_CHUNK: int = 44
## Below this the camera is a map, and scenery at map scale is grain.
const MIN_ZOOM: float = 0.30
## City presence above which the ground belongs to the settlement and the plain
## stops. Blurred over 8 tiles per texel, so this reaches well past the walls.
## Measured, not guessed: at 0.16 a 76-building opening settlement cleared so
## much ground that a real run carried NINE pieces of scenery on screen while
## the frame lab's placeholder city carried a hundred and twenty. The field is
## blurred over sixteen tiles, so a third of full presence is still comfortably
## outside anything anybody built — the rocks come up to the wall and stop.
const CITY_CLEAR: float = 0.34

## chunk key -> Array[Dictionary] of {arch, cell, pos, seed}
var _chunks: Dictionary[int, Array] = {}
var _seed: int = 0
var _visible: Array[Dictionary] = []
var _last_rect: Rect2 = Rect2()
var _last_stamp: int = -1
var _generated: int = 0


func setup(world_seed: int) -> void:
	_seed = world_seed & 0x7FFFFFF
	clear()


## Drops every generated block. Called when the world changes under it.
func clear() -> void:
	_chunks.clear()
	_visible.clear()
	_last_rect = Rect2()
	_last_stamp = -1


## Props overlapping `rect`, back to front by foot line. `stamp` is the model's
## building stamp: new construction clears the ground it stands on, so the
## blocks are regenerated when the city changes shape and not once per frame.
func in_view(model: LcnWorldModel, field: LcnTerrainField, rect: Rect2, stamp: int) -> Array[Dictionary]:
	if stamp != _last_stamp:
		_chunks.clear()
		_last_stamp = stamp
		_last_rect = Rect2()
	if rect.position.is_equal_approx(_last_rect.position) \
			and rect.size.is_equal_approx(_last_rect.size):
		return _visible
	_last_rect = rect
	_visible = []
	var size: Vector2i = model.world_size()
	var c0 := Vector2i(
		int(floor(rect.position.x / float(TILE * CHUNK))),
		int(floor(rect.position.y / float(TILE * CHUNK))))
	var c1 := Vector2i(
		int(floor(rect.end.x / float(TILE * CHUNK))),
		int(floor(rect.end.y / float(TILE * CHUNK))))
	for cy: int in range(c0.y, c1.y + 1):
		for cx: int in range(c0.x, c1.x + 1):
			if cx < 0 or cy < 0 or cx * CHUNK >= size.x or cy * CHUNK >= size.y:
				continue
			for p: Dictionary in _block(model, field, cx, cy):
				var pos: Vector2 = p["pos"]
				if pos.x < rect.position.x - 64.0 or pos.x > rect.end.x + 64.0:
					continue
				if pos.y < rect.position.y - 96.0 or pos.y > rect.end.y + 64.0:
					continue
				_visible.append(p)
	_visible.sort_custom(_by_foot)
	return _visible


static func _by_foot(a: Dictionary, b: Dictionary) -> bool:
	return float((a["pos"] as Vector2).y) < float((b["pos"] as Vector2).y)


func generated_blocks() -> int:
	return _chunks.size()


func _block(model: LcnWorldModel, field: LcnTerrainField, cx: int, cy: int) -> Array:
	var key: int = cx * 100003 + cy
	var hit: Array = _chunks.get(key, [])
	if not hit.is_empty() or _chunks.has(key):
		return hit
	var out: Array[Dictionary] = []
	var size: Vector2i = model.world_size()
	for i: int in PER_CHUNK:
		var hx: float = LcnNoise.hash3(cx, cy, _seed + i * 7 + 1)
		var hy: float = LcnNoise.hash3(cx, cy, _seed + i * 7 + 2)
		var roll: float = LcnNoise.hash3(cx, cy, _seed + i * 7 + 3)
		var pick: float = LcnNoise.hash3(cx, cy, _seed + i * 7 + 5)
		var cell := Vector2i(
			cx * CHUNK + int(hx * float(CHUNK)),
			cy * CHUNK + int(hy * float(CHUNK)))
		if cell.x < 1 or cell.y < 1 or cell.x >= size.x - 1 or cell.y >= size.y - 1:
			continue
		# The city's ground is the city's. This is what keeps a boulder out of
		# the middle of somebody's belt line without asking [P11] anything.
		if field != null and field.city_at(cell) > CITY_CLEAR:
			continue
		var arch: StringName = _for_terrain(model.terrain_at(cell), roll, pick)
		if arch == &"":
			continue
		out.append({
			"arch": arch,
			"cell": cell,
			"pos": Vector2(float(cell.x), float(cell.y)) * float(TILE),
			"seed": int(roll * 65535.0),
		})
	_chunks[key] = out
	_generated += 1
	return out


## What grows, falls or rusts on each surface — and how much of it. A rock shelf
## is dense with outcrops because that is what a rock shelf IS; a deep drift has
## almost nothing, because whatever was there is under it.
static func _for_terrain(terrain: int, roll: float, pick: float) -> StringName:
	match terrain:
		LcnPalette.Terrain.ROCK:
			if roll > 0.82:
				return &""
			return &"ruin" if pick > 0.90 else &"rock"
		LcnPalette.Terrain.GRAVEL:
			if roll > 0.46:
				return &""
			if pick > 0.88:
				return &"wreck"
			return &"ruin" if pick > 0.72 else &"rock"
		LcnPalette.Terrain.SNOW:
			if roll > 0.30:
				return &""
			if pick > 0.88:
				return &"wreck"
			if pick > 0.64:
				return &"ruin"
			return &"dead_tree" if pick > 0.26 else &"rock"
		LcnPalette.Terrain.SNOW_DEEP:
			if roll > 0.16:
				return &""
			return &"dead_tree" if pick > 0.45 else &"rock"
	# Ice, open water and anything paved carry nothing: a boulder on lake ice is
	# a mistake the eye catches immediately.
	return &""
