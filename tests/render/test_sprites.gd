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


# ============================================== THE PEOPLE, AT THE PLAY ZOOM ==
#
# A blind judge looking at a real 1920x1080 frame of this build "could find one
# human figure". The ten enemies were given ten silhouettes last pass and are
# held to 0.62 overlap here; the CITY'S OWN PEOPLE were never graded at all, and
# `_bake_person` drew citizen, worker and soldier from ONE polygon list with a
# different coat colour and a different belt. Three roles, one shape.
#
# Colour is not the answer at this scale. `LcnEntityRenderer.agent_scale` holds
# every figure at MIN_AGENT_PX on screen, so at zoom 0.60 a citizen and a
# soldier are both seventeen pixels tall — the height difference the world
# sprites have is spent by the figure floor before it reaches the eye. What
# survives is the OUTLINE and the ASPECT RATIO, and that is what these two tests
# measure: each sprite rasterised to the screen height the renderer will
# actually give it, then compared as a shape.
#
# That is a stricter frame than the enemy test above, which normalises at a
# common WORLD scale and therefore gets size for free. It is also the honest
# one for the townspeople, because they all arrive at the same screen height.

## Every render kind the city itself can put in the street. Enemies are graded
## by test_the_ten_enemies_are_distinguishable_by_shape_alone.
const HUMAN_KINDS: Array[StringName] = [&"citizen", &"worker", &"porter", &"soldier"]

## The screen height the figure floor gives a person at play zoom.
const PLAY_PX: int = 17
## Cells across the mask. A figure this size cannot be wider than twice its
## height without being something other than a person.
const ROLE_W: int = 34
const ROLE_H: int = 20


## THE ROLES READ APART AS SHAPES, at seventeen pixels, with no colour.
##
## Fails at 1.000 against the old `_bake_person`, which returned the same
## polygon for all three of its kinds.
func test_the_city_roles_are_distinguishable_by_shape_alone() -> void:
	var masks: Dictionary[StringName, PackedByteArray] = {}
	for kind: StringName in HUMAN_KINDS:
		var m: PackedByteArray = _mask_at_play_height(f.agent(kind))
		var on: int = 0
		for v: int in m:
			on += v
		assert_gt(float(on), 24.0,
			"%s is a figure and not a smudge at %d px (%d cells)" % [kind, PLAY_PX, on])
		masks[kind] = m
	var worst: float = 0.0
	var pair: String = ""
	for i: int in HUMAN_KINDS.size():
		for j: int in range(i + 1, HUMAN_KINDS.size()):
			var same: float = _similarity(masks[HUMAN_KINDS[i]], masks[HUMAN_KINDS[j]])
			if same > worst:
				worst = same
				pair = "%s vs %s" % [HUMAN_KINDS[i], HUMAN_KINDS[j]]
	assert_lt(worst, 0.62,
		"closest city-role silhouette pair is %s at %.3f overlap at play zoom" % [pair, worst])


## ...and they are not the enemy either. A hooded citizen crossing the plaza and
## a drift hound coming out of the dark are the one pair in this game that must
## never be confused, and they arrive at the same seventeen pixels.
func test_a_person_never_reads_as_a_creature() -> void:
	var worst: float = 0.0
	var pair: String = ""
	for hk: StringName in HUMAN_KINDS:
		var hm: PackedByteArray = _mask_at_play_height(f.agent(hk))
		for ek: StringName in LcnSpriteFactory.ENEMY_KINDS:
			var em: PackedByteArray = _mask_at_play_height(f.agent(ek))
			var same: float = _similarity(hm, em)
			if same > worst:
				worst = same
				pair = "%s vs %s" % [hk, ek]
	assert_lt(worst, 0.70,
		"closest person/creature pair is %s at %.3f overlap at play zoom" % [pair, worst])


## The sprite as the screen gets it: scaled so its HEIGHT is exactly the figure
## floor, aspect preserved, standing on the bottom row, centred horizontally —
## which is what `LcnEntityRenderer._draw_agent` does about the feet.
static func _mask_at_play_height(sprite: Dictionary) -> PackedByteArray:
	var img: Image = (sprite["texture"] as ImageTexture).get_image()
	var out := PackedByteArray()
	out.resize(ROLE_W * ROLE_H)
	var w: int = img.get_width()
	var h: int = img.get_height()
	var s: float = float(PLAY_PX) / float(maxi(h, 1))
	var ox: float = (float(ROLE_W) - float(w) * s) * 0.5
	var oy: float = float(ROLE_H) - float(h) * s - 1.0
	for y: int in ROLE_H:
		for x: int in ROLE_W:
			var sx: int = int((float(x) - ox) / s)
			var sy: int = int((float(y) - oy) / s)
			var on: int = 0
			if sx >= 0 and sy >= 0 and sx < w and sy < h and img.get_pixel(sx, sy).a > 0.45:
				on = 1
			out[y * ROLE_W + x] = on
	return out


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


# =========================================================== THE TEN ENEMIES ==
#
# `world_renderer._on_enemy_spawned` mapped every spawn with
#
#     &"brute" if String(kind).to_lower().contains("brute") else &"swarm"
#
# and not one of the ten ids in game/content/enemies/ contains "brute". So the
# expression was not merely coarse — it was FALSE for every input the simulation
# can produce, and every enemy in the game drew one 18x16 sprite. These three
# tests fail against that expression, which is the point of them: the first two
# fail on the mapping, the third on the art it maps to.


## THE MAPPING IS TRUE FOR THE THINGS THAT ACTUALLY SPAWN. Read off the content
## folder, not off a list in this file, so an enemy added tomorrow without art
## fails here rather than silently becoming a blob at midnight.
func test_every_shipped_enemy_maps_to_its_own_sprite() -> void:
	var dir := DirAccess.open("res://game/content/enemies")
	if dir == null:
		skip("no enemy content in this build")
		return
	var ids: Array[StringName] = []
	for file: String in dir.get_files():
		if file.ends_with(".tres"):
			ids.append(StringName(file.get_basename()))
	assert_ge(float(ids.size()), 10.0, "the designed roster is present (%d)" % ids.size())

	var archs: Dictionary[StringName, bool] = {}
	for id: StringName in ids:
		var arch: StringName = LcnSpriteFactory.agent_arch(id)
		assert_eq(arch, id,
			"%s renders as itself, not as a generic archetype (got '%s')" % [id, arch])
		archs[arch] = true
	assert_eq(archs.size(), ids.size(),
		"%d enemies produce %d distinct render kinds" % [ids.size(), archs.size()])


## Every one of them is in the atlas, so drawing ten creatures still costs the
## draw calls of one. An enemy sprite outside the atlas would bind a second
## texture and break the batch the whole renderer is built on.
func test_every_enemy_sprite_rides_the_one_atlas() -> void:
	var a: Dictionary = f.atlas([])
	var regions: Dictionary = a["regions"]
	for kind: StringName in LcnSpriteFactory.ENEMY_KINDS:
		assert_true(regions.has(LcnSpriteFactory.agent_key(kind)),
			"atlas contains enemy %s" % kind)


## SILHOUETTE, NOT PALETTE. At the zoom this game is played at an enemy is about
## a dozen pixels tall with no readable interior, so two kinds that share an
## outline are the same creature to the player however differently they are
## tinted. Rasterised at a COMMON world scale — a 30 hp hound and a 9000 hp boss
## differ by size as much as by shape, and normalising per sprite would throw
## exactly that away.
##
## The bar is 0.62, tighter than the 0.82 the buildings are held to, because a
## building is identified at leisure and an enemy is identified while it is
## walking at you.
func test_the_ten_enemies_are_distinguishable_by_shape_alone() -> void:
	var kinds: Array[StringName] = LcnSpriteFactory.ENEMY_KINDS
	var masks: Dictionary[StringName, PackedByteArray] = {}
	for kind: StringName in kinds:
		var m: PackedByteArray = _mask_at(f.agent(kind), 64.0)
		var on: int = 0
		for v: int in m:
			on += v
		assert_gt(float(on), 12.0, "%s draws something at play scale (%d cells)" % [kind, on])
		masks[kind] = m
	var worst: float = 0.0
	var pair: String = ""
	for i: int in kinds.size():
		for j: int in range(i + 1, kinds.size()):
			var same: float = _similarity(masks[kinds[i]], masks[kinds[j]])
			if same > worst:
				worst = same
				pair = "%s vs %s" % [kinds[i], kinds[j]]
	assert_lt(worst, 0.62,
		"closest enemy silhouette pair is %s at %.3f overlap" % [pair, worst])


## The boss must not be a big hound. Size IS information in a tower defense:
## 9000 hp and 30 hp arriving in the same frame have to be told apart before
## either of them is in range.
func test_size_carries_the_threat() -> void:
	var hound: Image = (f.agent(&"drift_hound")["texture"] as ImageTexture).get_image()
	var boss: Image = (f.agent(&"the_long_cold")["texture"] as ImageTexture).get_image()
	var breaker: Image = (f.agent(&"hoarfrost_breaker")["texture"] as ImageTexture).get_image()
	assert_gt(float(boss.get_height()), float(hound.get_height()) * 3.0,
		"the boss is over three times the height of the swarm trash (%d vs %d)"
			% [boss.get_height(), hound.get_height()])
	assert_gt(float(breaker.get_height()), float(hound.get_height()) * 1.8,
		"the 900 hp breaker reads as heavy next to the 30 hp hound (%d vs %d)"
			% [breaker.get_height(), hound.get_height()])
	# ...and the flier is the widest thing in the set, because a wingspan is the
	# only cue that survives when everything is twelve pixels tall.
	var stalker: Image = (f.agent(&"pale_stalker")["texture"] as ImageTexture).get_image()
	for kind: StringName in LcnSpriteFactory.ENEMY_KINDS:
		if kind == &"pale_stalker" or kind == &"the_long_cold":
			continue
		var im: Image = (f.agent(kind)["texture"] as ImageTexture).get_image()
		assert_gt(float(stalker.get_width()) / float(stalker.get_height()),
			float(im.get_width()) / float(im.get_height()),
			"the flier is the widest-for-its-height silhouette (vs %s)" % kind)


## An id nobody has drawn must still draw SOMETHING. The fallback is the reason
## adding an enemy to the content folder can never produce an invisible one.
func test_an_undrawn_enemy_still_lands_on_an_archetype() -> void:
	assert_eq(LcnSpriteFactory.agent_arch(&"grave_titan"), &"brute",
		"a heavy-sounding unknown falls back to the brute")
	assert_eq(LcnSpriteFactory.agent_arch(&"nibbler"), &"swarm",
		"anything else falls back to the swarm")
	assert_eq(LcnSpriteFactory.agent_arch(&"citizen"), &"citizen",
		"and the townspeople are left alone")
