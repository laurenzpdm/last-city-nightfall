extends TestCase
## Silhouettes and the draw atlas. [P13]
##
## DEFECT (critic, defect 5): "building variety is about six sprites repeated,
## and two structurally identical hearths appear at different scales in one
## frame. Silhouettes must be distinct enough to identify a building by shape
## alone at far zoom."
##
## DEFECT (critic, defect 6): entity drawing cost 37 ms of CPU and 797 draw calls
## for 206 buildings. The fix is one atlas, so these tests guard the atlas.

var f: LcnSpriteFactory = null


func suite_name() -> String:
	return "render/sprites"


## The disk cache is switched off for the whole suite, because a silhouette test
## that reads user://art_cache certifies whatever was baked BEFORE the change it
## is meant to be judging. That is not hypothetical: the survey hall's redesign
## measured green here at its old 0.958 overlap with the heat plant, from a cache
## written minutes earlier. ART_VERSION exists for the shipping game; a test
## must test the baker.
func before_all() -> void:
	LcnArtCache.set_enabled(false)
	f = LcnSpriteFactory.new()


func after_all() -> void:
	LcnArtCache.set_enabled(true)


## Every building in game/content/buildings must reach a drawable archetype, and
## the ones a player has to tell apart must not land on the same one.
func test_shipped_buildings_get_distinct_silhouettes() -> void:
	var ids: Array[StringName] = []
	var dir := DirAccess.open("res://game/content/buildings")
	if dir == null:
		skip("no building content in this build")
		return
	for file: String in dir.get_files():
		if file.ends_with(".tres"):
			ids.append(StringName(file.get_basename()))
	assert_gt(float(ids.size()), 10.0, "there is a real catalogue to check")

	var by_arch: Dictionary[StringName, Array] = {}
	for id: StringName in ids:
		var arch: StringName = LcnSpriteFactory.archetype_for(id)
		assert_has(LcnSpriteFactory.archetypes(), arch, "%s maps to a real archetype" % id)
		var list: Array = by_arch.get(arch, [])
		list.append(String(id))
		by_arch[arch] = list

	# The specific collisions the critic saw: the great hearth and a coal
	# generator drawn as the same object, and every heat building collapsing
	# onto one boiler shape.
	assert_ne(LcnSpriteFactory.archetype_for(&"the_hearth"),
		LcnSpriteFactory.archetype_for(&"coal_generator"),
		"the Hearth does not share a shape with a coal generator")
	assert_ne(LcnSpriteFactory.archetype_for(&"warmth_radiator"),
		LcnSpriteFactory.archetype_for(&"heat_accumulator"),
		"a radiator does not share a shape with an accumulator")
	assert_ne(LcnSpriteFactory.archetype_for(&"granary"),
		LcnSpriteFactory.archetype_for(&"storage_yard"),
		"a granary does not share a shape with a storage yard")
	assert_ne(LcnSpriteFactory.archetype_for(&"ore_drill"),
		LcnSpriteFactory.archetype_for(&"scrap_collector"),
		"a drill does not share a shape with a scrap collector")

	var worst: int = 0
	var worst_arch: String = ""
	for arch2: StringName in by_arch:
		var n: int = (by_arch[arch2] as Array).size()
		if n > worst:
			worst = n
			worst_arch = "%s: %s" % [arch2, str(by_arch[arch2])]
	assert_le(float(worst), 3.0, "no archetype carries more than three shipped buildings (%s)" % worst_arch)
	assert_ge(float(by_arch.size()), 12.0,
		"the shipped catalogue resolves to %d distinct shapes" % by_arch.size())


## DEFECT: a 5x5 building drawn as a 3x3 sprite scaled 1.67x.
func test_sprites_are_baked_at_their_footprint_never_stretched() -> void:
	var small: Dictionary = f.building(&"hearth", Vector2i(3, 3))
	var big: Dictionary = f.building(&"hearth", Vector2i(5, 5))
	assert_eq(small["tiles"] as Vector2i, Vector2i(3, 3), "asked for 3x3, baked 3x3")
	assert_eq(big["tiles"] as Vector2i, Vector2i(5, 5), "asked for 5x5, baked 5x5")
	var sw: int = (small["texture"] as ImageTexture).get_width()
	var bw: int = (big["texture"] as ImageTexture).get_width()
	assert_eq(sw, 3 * 32 + LcnSpriteFactory.PAD * 2, "3x3 sprite is three tiles wide")
	assert_eq(bw, 5 * 32 + LcnSpriteFactory.PAD * 2, "5x5 sprite is five tiles wide")
	assert_gt(float(big["lift"]), float(small["lift"]), "and the bigger one is genuinely taller")
	# Not a uniform blow-up: the lift is damped, so detail density stays constant
	# instead of the whole drawing being magnified.
	assert_lt(float(big["lift"]) / float(small["lift"]), 5.0 / 3.0,
		"lift grows slower than the footprint, so it is a bigger building not a zoomed one")


func test_every_archetype_bakes_something_with_an_outline() -> void:
	for arch: StringName in LcnSpriteFactory.archetypes():
		var s: Dictionary = f.building(arch)
		var img: Image = (s["texture"] as ImageTexture).get_image()
		assert_gt(float(img.get_width()), 0.0, "%s has a texture" % arch)
		var opaque: int = 0
		for y: int in range(0, img.get_height(), 2):
			for x: int in range(0, img.get_width(), 2):
				if img.get_pixel(x, y).a > 0.5:
					opaque += 1
		var total: int = (img.get_height() / 2) * (img.get_width() / 2)
		var fill: float = float(opaque) / float(maxi(total, 1))
		assert_gt(fill, 0.04, "%s draws something (fill %.3f)" % [arch, fill])
		assert_lt(fill, 0.92, "%s is a silhouette, not a filled rectangle (fill %.3f)" % [arch, fill])


## Two archetypes whose alpha masks are nearly identical are the same building to
## a player at far zoom, whatever colours are inside them.
func test_archetype_silhouettes_are_measurably_different() -> void:
	var masks: Dictionary[StringName, PackedByteArray] = {}
	var probe: Array[StringName] = [
		&"hearth", &"generator", &"heat_plant", &"radiator", &"accumulator",
		&"silo", &"depot", &"habitat", &"drill", &"watchtower", &"pylon", &"greenhouse",
		# The three production halls. They are the same class of object — a big
		# roofed box a crew works inside — so they are the easiest pair in the
		# catalogue to let collapse into one shape, and the survey hall's first
		# draft did exactly that against the heat plant at 0.96 overlap.
		&"workshop", &"assembler", &"research_hall",
	]
	for arch: StringName in probe:
		masks[arch] = _mask(f.building(arch))
	var worst: float = 0.0
	var pair: String = ""
	for i: int in probe.size():
		for j: int in range(i + 1, probe.size()):
			var same: float = _similarity(masks[probe[i]], masks[probe[j]])
			if same > worst:
				worst = same
				pair = "%s vs %s" % [probe[i], probe[j]]
	assert_lt(worst, 0.82, "closest silhouette pair is %s at %.3f overlap" % [pair, worst])


## The single-tile infrastructure is judged at the scale it is actually played
## at, not at city zoom: three tiles across the frame, which is roughly what a
## player sees while routing a line. Half the catalogue by COUNT is this family —
## belt, splitter, underground, inserter, long arm, container — and every one of
## them used to be the same picture, so "a 1x1 is too small to draw" is exactly
## the reasoning that lost the player the ability to read a factory.
##
## Same 0.82 bar as far zoom. The tightest pair here is belt against pipe: both
## are genuinely a flat strip laid across a tile and they are told apart by the
## cleats and the heat glow, not by outline. Everything added since is well clear.
func test_single_tile_machines_read_apart_at_routing_zoom() -> void:
	var probe: Array[StringName] = [
		&"belt", &"splitter", &"underground", &"arm", &"long_arm", &"crate",
		&"pipe", &"wall", &"road",
	]
	var masks: Dictionary[StringName, PackedByteArray] = {}
	for arch: StringName in probe:
		masks[arch] = _mask_at(f.building(arch), 96.0)
	var worst: float = 0.0
	var pair: String = ""
	for i: int in probe.size():
		for j: int in range(i + 1, probe.size()):
			var same: float = _similarity(masks[probe[i]], masks[probe[j]])
			if same > worst:
				worst = same
				pair = "%s vs %s" % [probe[i], probe[j]]
	assert_lt(worst, 0.82, "closest single-tile pair is %s at %.3f overlap" % [pair, worst])


## What survives of a shape when you zoom all the way out — rasterised at a
## COMMON world scale, not normalised per sprite, because at far zoom a 5x5
## hearth and a 3x3 silo differ by their size as much as by their outline and a
## per-sprite normalisation would throw that away.
const MASK_N: int = 40
const MASK_SPAN: float = 320.0


static func _mask(sprite: Dictionary) -> PackedByteArray:
	return _mask_at(sprite, MASK_SPAN)


static func _mask_at(sprite: Dictionary, span: float) -> PackedByteArray:
	var img: Image = (sprite["texture"] as ImageTexture).get_image()
	var out := PackedByteArray()
	out.resize(MASK_N * MASK_N)
	var w: int = img.get_width()
	var h: int = img.get_height()
	var s: float = float(MASK_N) / span
	var ox: float = (float(MASK_N) - float(w) * s) * 0.5
	# Bottom-aligned: buildings sit on the ground, so that is where they line up.
	var oy: float = float(MASK_N) - float(h) * s - 2.0
	for y: int in MASK_N:
		for x: int in MASK_N:
			var sx: int = int((float(x) - ox) / s)
			var sy: int = int((float(y) - oy) / s)
			var on: int = 0
			if sx >= 0 and sy >= 0 and sx < w and sy < h and img.get_pixel(sx, sy).a > 0.45:
				on = 1
			out[y * MASK_N + x] = on
	return out


## Intersection over union of the filled areas. Shared emptiness is not
## similarity, so plain agreement would score every small sprite as identical.
static func _similarity(a: PackedByteArray, b: PackedByteArray) -> float:
	var inter: int = 0
	var uni: int = 0
	for i: int in a.size():
		var x: int = a[i]
		var y: int = b[i]
		if x == 1 and y == 1:
			inter += 1
		if x == 1 or y == 1:
			uni += 1
	return float(inter) / float(maxi(uni, 1))


# ------------------------------------------------------------------- atlas ----

func test_atlas_holds_every_sprite_the_renderer_draws() -> void:
	var a: Dictionary = f.atlas([])
	var regions: Dictionary = a["regions"]
	for arch: StringName in LcnSpriteFactory.archetypes():
		var key: StringName = LcnSpriteFactory.sprite_key(arch, LcnSpriteFactory.spec(arch)["tiles"])
		assert_true(regions.has(key), "atlas contains %s" % key)
	for kind: StringName in LcnSpriteFactory.AGENT_KINDS:
		assert_true(regions.has(LcnSpriteFactory.agent_key(kind)), "atlas contains agent %s" % kind)
	for extra: StringName in [&"glow", &"shadow", &"smear", &"barrel"]:
		assert_true(regions.has(extra), "atlas contains %s — otherwise that pass binds a second texture" % extra)


func test_atlas_regions_do_not_overlap_and_stay_inside_the_sheet() -> void:
	var a: Dictionary = f.atlas([[&"hearth", Vector2i(5, 5)], [&"habitat", Vector2i(4, 4)]])
	var size: Vector2i = a["size"]
	var regions: Dictionary = a["regions"]
	var list: Array = []
	for k: StringName in regions:
		var r: Rect2 = regions[k]
		assert_ge(r.position.x, 0.0, "%s inside the sheet (x)" % k)
		assert_ge(r.position.y, 0.0, "%s inside the sheet (y)" % k)
		assert_le(r.end.x, float(size.x), "%s inside the sheet (right)" % k)
		assert_le(r.end.y, float(size.y), "%s inside the sheet (bottom)" % k)
		list.append([k, r])
	for i: int in list.size():
		for j: int in range(i + 1, list.size()):
			var ra: Rect2 = list[i][1]
			var rb: Rect2 = list[j][1]
			assert_false(ra.intersects(rb),
				"%s and %s do not overlap in the atlas" % [list[i][0], list[j][0]])
	assert_true(regions.has(LcnSpriteFactory.sprite_key(&"hearth", Vector2i(5, 5))),
		"a requested footprint variant lands in the atlas")


func test_atlas_is_one_texture_and_stays_a_sane_size() -> void:
	var a: Dictionary = f.atlas([])
	var tex: ImageTexture = a["texture"]
	assert_not_null(tex, "the atlas is a real texture")
	var px: int = tex.get_width() * tex.get_height()
	assert_lt(float(px), 4.0 * 1024.0 * 1024.0,
		"atlas is %dx%d — small enough to stay resident on any GPU" % [tex.get_width(), tex.get_height()])
	assert_gt(float((a["regions"] as Dictionary).size()), 25.0, "and it earns its size")
