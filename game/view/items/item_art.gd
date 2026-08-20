class_name LcnItemArt
extends RefCounted
## [D2] WHAT ONE THING ON A BELT LOOKS LIKE.
##
## Two questions, one table: what SHAPE is this item, and what COLOUR is it.
## Both are answered from content — `LogiItem.category` and `LogiItem.tint`,
## which [P03] already declares on every `.tres` in `game/content/logistics/`
## and whose own doc comment says the belt renderer is what reads them. Nothing
## here hardcodes an item id, so an item added tomorrow gets a silhouette and a
## colour without this file being touched.
##
## WHY SILHOUETTE AND NOT JUST COLOUR. A belt read at speed is read by shape
## first: a stream of flat slabs is plate, a stream of round nuggets is ore, a
## stream of tall shells is ammunition. Colour alone collapses the moment the
## night grade pulls everything toward blue, and it collapses completely for a
## colour-blind player. Five categories, five outlines.
##
## WHY THE TINT IS NOT USED RAW. Coal ships `Color(0.16, 0.16, 0.18)`, which is
## darker than the belt it rides on and darker than the ground under the belt —
## drawn literally it is a black dot on a black plank at night. Every fill is
## therefore pushed to a legibility floor against the dark, and every item gets
## a rim one step brighter than its body so the outline survives the grade.
##
## Geometry is emitted as a flat TRIANGLE LIST in world pixels, fan-triangulated
## from a unit polygon and cached per (shape, radius). The layer that draws it
## hands one array per item kind to `canvas_item_add_triangle_array`, so a
## thousand items on screen is a handful of draw calls, not a thousand.

## Silhouettes. One per `LogiItem.category`, plus PIP — the four-vertex body
## every item collapses to once its silhouette is smaller than the eye can
## resolve. Detail that cannot be seen is detail that is only paid for.
enum Shape { NUGGET, SLAB, COG, SHELL, LUMP, PIP }

const CATEGORY_SHAPE: Dictionary[StringName, int] = {
	&"raw": Shape.NUGGET,
	&"plate": Shape.SLAB,
	&"component": Shape.COG,
	&"ammo": Shape.SHELL,
	&"fuel": Shape.LUMP,
	&"build": Shape.SLAB,
}

## An item is a quarter of a tile long (LogiTypes.SPACING), so this is the
## largest a body can be without a compressed belt reading as one solid bar at
## close zoom — which is a real state, and must not be faked by geometry.
const BODY_RADIUS_PX: float = 3.4
## Below this the fill is lifted toward slate until it clears the belt it rides.
const MIN_LUMINANCE: float = 0.30
## Colour a too-dark item is lifted toward: cold, so coal still reads as coal.
const LIFT_TOWARD: Color = Color(0.62, 0.66, 0.74)
const FALLBACK_TINT: Color = Color(0.72, 0.74, 0.78)
## Radii are cached in sixteenths of a pixel. Finer than an eye can tell apart,
## coarse enough that a smoothly changing zoom does not mint a new array a frame.
const RADIUS_QUANTUM: float = 16.0

## Unit outlines, counter-clockwise, in a box roughly [-1, 1]. Fan-triangulated
## from vertex 0, so every one of them has to stay convex.
## `static var` rather than `const`: a PackedVector2Array literal is not a
## constant expression in GDScript, and the alternative — a flat float table
## unpacked at load — is unreadable for no gain. Nothing writes to it.
static var OUTLINES: Array[PackedVector2Array] = [
	# NUGGET — a rounded lump of ore, deliberately not a circle.
	PackedVector2Array([Vector2(0.0, -1.0), Vector2(0.74, -0.66), Vector2(1.0, 0.06),
		Vector2(0.62, 0.80), Vector2(-0.10, 1.0), Vector2(-0.80, 0.62),
		Vector2(-1.0, -0.14), Vector2(-0.66, -0.80)]),
	# SLAB — a flat plate seen from above, long across the belt.
	PackedVector2Array([Vector2(-1.18, -0.52), Vector2(1.18, -0.52), Vector2(1.34, -0.16),
		Vector2(1.34, 0.20), Vector2(1.18, 0.56), Vector2(-1.18, 0.56),
		Vector2(-1.34, 0.20), Vector2(-1.34, -0.16)]),
	# COG — a hexagonal component, the machined look.
	PackedVector2Array([Vector2(0.0, -1.06), Vector2(0.92, -0.53), Vector2(0.92, 0.53),
		Vector2(0.0, 1.06), Vector2(-0.92, 0.53), Vector2(-0.92, -0.53)]),
	# SHELL — a round pointed at one end. Tall, so a stream of them reads as ammo.
	PackedVector2Array([Vector2(0.0, -1.30), Vector2(0.56, -0.62), Vector2(0.60, 0.80),
		Vector2(0.0, 1.16), Vector2(-0.60, 0.80), Vector2(-0.56, -0.62)]),
	# LUMP — broken coal, all facets.
	PackedVector2Array([Vector2(-0.12, -1.04), Vector2(0.78, -0.62), Vector2(1.02, 0.24),
		Vector2(0.44, 0.98), Vector2(-0.52, 0.92), Vector2(-1.02, 0.10),
		Vector2(-0.84, -0.66)]),
	# PIP — the far-zoom body. Two triangles, no silhouette to read anyway.
	PackedVector2Array([Vector2(-0.92, -0.92), Vector2(0.92, -0.92),
		Vector2(0.92, 0.92), Vector2(-0.92, 0.92)]),
]

## Below this body diameter ON SCREEN a silhouette is four grey pixels whatever
## its outline is, so every kind collapses to PIP. Measured, not guessed: a
## SLAB and a NUGGET are indistinguishable under about six pixels across.
const SILHOUETTE_MIN_SCREEN_PX: float = 6.0


## The shape actually drawn for a look at this size: the real silhouette when it
## can be read, PIP when it cannot.
static func shape_at(look_shape: int, screen_diameter_px: float) -> int:
	return look_shape if screen_diameter_px >= SILHOUETTE_MIN_SCREEN_PX else Shape.PIP

static var _unit: Dictionary[int, PackedVector2Array] = {}
static var _scaled: Dictionary[int, PackedVector2Array] = {}
static var _looks: Dictionary[StringName, Dictionary] = {}
static var _misses: Dictionary[StringName, bool] = {}


## Shape, fill and rim for one item id. Cached; the registry is asked once.
## Returns {shape:int, fill:Color, rim:Color, name:String}.
static func look(kind: StringName) -> Dictionary:
	if _looks.has(kind):
		return _looks[kind]
	var tint: Color = FALLBACK_TINT
	var category: StringName = &"raw"
	var display: String = String(kind)
	var res: Resource = _item_resource(kind)
	if res != null:
		tint = res.get("tint") as Color
		category = res.get("category") as StringName
		var dn: String = String(res.get("display_name"))
		if dn != "":
			display = dn
	elif not _misses.has(kind):
		# Once per id per process. An item on a belt with no definition behind it
		# is a content bug, and drawing it as a grey pip in silence is how it
		# would survive to Steam.
		_misses[kind] = true
		Log.warn("items", "no LogiItem for '%s' — drawing it as a grey pip" % String(kind))
	var fill: Color = legible(tint)
	var out: Dictionary = {
		"shape": int(CATEGORY_SHAPE.get(category, Shape.NUGGET)),
		"fill": fill,
		"rim": rim_of(fill),
		"name": display,
	}
	_looks[kind] = out
	return out


## The fill actually drawn: the content tint, lifted until it can be seen
## against a dark belt at night.
static func legible(tint: Color) -> Color:
	var c := Color(tint.r, tint.g, tint.b, 1.0)
	var lum: float = c.get_luminance()
	if lum >= MIN_LUMINANCE:
		return c
	# Lift toward slate rather than toward white: white erases the hue that
	# tells iron ore from copper ore, and those two differ by hue alone.
	var t: float = clampf((MIN_LUMINANCE - lum) / maxf(MIN_LUMINANCE, 0.0001), 0.0, 1.0)
	return c.lerp(LIFT_TOWARD, t * 0.78)


## The outline colour for a body. Bright enough to survive the night grade.
static func rim_of(fill: Color) -> Color:
	return Color(minf(fill.r * 1.45 + 0.16, 1.0), minf(fill.g * 1.45 + 0.17, 1.0),
		minf(fill.b * 1.45 + 0.19, 1.0), 1.0)


## Triangle list for one silhouette at one radius, in world pixels, centred on
## the origin. The caller adds the item position to every vertex.
static func triangles(shape: int, radius: float) -> PackedVector2Array:
	var key: int = clampi(shape, 0, OUTLINES.size() - 1) * 100000 + int(round(
		clampf(radius, 0.1, 400.0) * RADIUS_QUANTUM))
	if _scaled.has(key):
		return _scaled[key]
	var unit: PackedVector2Array = unit_triangles(shape)
	var out := PackedVector2Array()
	out.resize(unit.size())
	var r: float = float(int(round(clampf(radius, 0.1, 400.0) * RADIUS_QUANTUM))) / RADIUS_QUANTUM
	for i: int in unit.size():
		out[i] = unit[i] * r
	_scaled[key] = out
	return out


## The unit fan for a silhouette, triangulated once per process.
static func unit_triangles(shape: int) -> PackedVector2Array:
	var s: int = clampi(shape, 0, OUTLINES.size() - 1)
	if _unit.has(s):
		return _unit[s]
	var poly: PackedVector2Array = OUTLINES[s]
	var out := PackedVector2Array()
	out.resize(maxi(0, poly.size() - 2) * 3)
	var w: int = 0
	for i: int in range(1, poly.size() - 1):
		out[w] = poly[0]
		out[w + 1] = poly[i]
		out[w + 2] = poly[i + 1]
		w += 3
	_unit[s] = out
	return out


## Vertices one item of this shape costs. Lets a layer size its buffers before
## it starts filling them, instead of growing an array per item.
static func vertex_count(shape: int) -> int:
	return unit_triangles(shape).size()


## Test seam: drop every cache so a suite can re-resolve against fresh content.
static func reset_for_tests() -> void:
	_unit.clear()
	_scaled.clear()
	_looks.clear()
	_misses.clear()


static func _item_resource(kind: StringName) -> Resource:
	# Duck-typed on purpose: this layer must still draw in a test scene where
	# Registry has not scanned, and a missing definition is a warning, not a
	# crash.
	var reg: Object = Engine.get_singleton(&"Registry") if Engine.has_singleton(&"Registry") else null
	if reg == null:
		var tree: SceneTree = Engine.get_main_loop() as SceneTree
		if tree != null and tree.root != null:
			reg = tree.root.get_node_or_null(^"Registry")
	if reg == null or not reg.has_method("get_item"):
		return null
	return reg.call("get_item", "logistics", kind) as Resource
