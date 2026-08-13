class_name WarmthField
extends RefCounted
## The radiant warmth layer: degrees Celsius added on top of the climate's
## ambient temperature, per tile. Every heated building bleeds warmth into the
## tiles around it and overlapping sources add, which is exactly why a good city
## plan *looks* like a city plan — dense, overlapping, pipes short.
##
## Cost control: the falloff footprint of a source is a stamp that only depends
## on its size and radius, so it is computed once per shape and shared. Per
## refresh only the DELTA of a source's strength is painted into the field, so a
## city of a hundred radiators costs a handful of dictionary writes per tick
## instead of a hundred full redraws.

const MIN_WEIGHT: float = 0.02   ## stamp cells below this are not worth carrying
const MIN_VALUE: float = 0.01    ## field cells below this are erased (stays sparse)
const MIN_DELTA: float = 0.02    ## strength change below this is not repainted

var _field: Dictionary[Vector2i, float] = {}
var _origin: Dictionary[int, Vector2i] = {}
var _shape: Dictionary[int, String] = {}
var _strength: Dictionary[int, float] = {}
var _applied: Dictionary[int, float] = {}
var _stamps: Dictionary[String, Array] = {}

var repaints: int = 0            ## diagnostic: cell writes since creation


## Degrees above ambient at a tile. O(1). This is THE function citizens,
## buildings and the overlay layer read.
func value_at(cell: Vector2i) -> float:
	return _field.get(cell, 0.0)


## Registers or moves a radiant source. Cheap to call every tick — nothing is
## painted until flush().
func set_source(id: int, origin: Vector2i, size: Vector2i, radius: float, strength: float) -> void:
	var key: String = _shape_key(size, radius)
	if _shape.has(id) and (_shape[id] != key or _origin[id] != origin):
		_paint(id, -_applied.get(id, 0.0))
		_applied[id] = 0.0
	_shape[id] = key
	_origin[id] = origin
	_strength[id] = maxf(0.0, strength)
	if not _stamps.has(key):
		_stamps[key] = _build_stamp(size, radius)


func remove_source(id: int) -> void:
	if not _shape.has(id):
		return
	_paint(id, -_applied.get(id, 0.0))
	_shape.erase(id)
	_origin.erase(id)
	_strength.erase(id)
	_applied.erase(id)


## Paints every source whose strength moved far enough to matter.
func flush() -> void:
	var ids: Array = _strength.keys()
	ids.sort()
	for id: int in ids:
		var cur: float = _strength[id]
		var app: float = _applied.get(id, 0.0)
		var delta: float = cur - app
		if absf(delta) < MIN_DELTA:
			continue
		_paint(id, delta)
		_applied[id] = cur


func clear() -> void:
	_field.clear()
	_origin.clear()
	_shape.clear()
	_strength.clear()
	_applied.clear()


func warm_cells() -> int:
	return _field.size()


func total() -> float:
	var s: float = 0.0
	for k: Vector2i in _field:
		s += _field[k]
	return s


## Mean warmth across the heated area — the single number that says "is this
## city warm?". Zero when nothing is heated.
func average() -> float:
	if _field.is_empty():
		return 0.0
	return total() / float(_field.size())


func peak() -> float:
	var m: float = 0.0
	for k: Vector2i in _field:
		m = maxf(m, _field[k])
	return m


## Sorted, JSON-safe copy for saves and for the overlay layer.
func snapshot() -> Array:
	var keys: Array = _field.keys()
	keys.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.y != b.y:
			return a.y < b.y
		return a.x < b.x)
	var out: Array = []
	for k: Vector2i in keys:
		out.append([k.x, k.y, snappedf(_field[k], 0.01)])
	return out


func _paint(id: int, delta: float) -> void:
	if absf(delta) <= 0.0:
		return
	var key: String = _shape.get(id, "")
	if key == "":
		return
	var stamp: Array = _stamps.get(key, [])
	var origin: Vector2i = _origin.get(id, Vector2i.ZERO)
	for entry: Array in stamp:
		var cell: Vector2i = origin + (entry[0] as Vector2i)
		var v: float = _field.get(cell, 0.0) + delta * float(entry[1])
		if absf(v) < MIN_VALUE:
			_field.erase(cell)
		else:
			_field[cell] = v
		repaints += 1


func _shape_key(size: Vector2i, radius: float) -> String:
	return "%dx%d@%d" % [size.x, size.y, int(roundf(radius * 4.0))]


## Smoothstep falloff from the edge of the footprint: a warm plateau over the
## building itself, a soft shoulder, nothing past the radius. Uses only
## multiply/add/sqrt so the result is bit-identical on every platform.
func _build_stamp(size: Vector2i, radius: float) -> Array:
	var out: Array = []
	if radius <= 0.0:
		return out
	var r: int = int(ceilf(radius))
	var w: int = maxi(1, size.x)
	var h: int = maxi(1, size.y)
	for x: int in range(-r, w + r):
		for y: int in range(-r, h + r):
			var dx: float = 0.0
			if x < 0:
				dx = float(-x)
			elif x > w - 1:
				dx = float(x - (w - 1))
			var dy: float = 0.0
			if y < 0:
				dy = float(-y)
			elif y > h - 1:
				dy = float(y - (h - 1))
			var d: float = sqrt(dx * dx + dy * dy)
			if d > radius:
				continue
			var t: float = clampf(1.0 - d / radius, 0.0, 1.0)
			var weight: float = t * t * (3.0 - 2.0 * t)
			if weight < MIN_WEIGHT:
				continue
			out.append([Vector2i(x, y), weight])
	return out
