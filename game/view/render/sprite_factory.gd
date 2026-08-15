class_name LcnSpriteFactory
extends RefCounted
## Procedural sprite bakery. [P13]
##
## Every building, prop and agent in the game is DRAWN here, in code, as
## anti-aliased vector art. No flat coloured rectangles, no imported PNG blobs.
##
## Projection: square 32px grid seen from above with a vertical lift, so a
## building shows a top face and a front face. That is enough to give every
## structure a real silhouette while keeping footprints perfectly grid-aligned —
## the thing a builder game cannot compromise on.
##
## Silhouette rule: a player must name a building from its outline alone at
## zoomed-out scale. Every archetype below therefore owns one unmistakable
## shape feature (chimney / sawtooth / dome / lattice / barrel / arch).
##
##   var f := LcnSpriteFactory.new()
##   var s: Dictionary = f.building(&"heat_plant")
##   draw_texture(s["texture"], world_pos + s["offset"])

const TILE: int = 32
## Transparent margin so snow lips, aerials and glows are not clipped.
const PAD: int = 10
const SS: int = 3

const OUTLINE: Color = Color(0.016, 0.024, 0.047, 0.92)
const SEAM: Color = Color(0.031, 0.047, 0.086, 0.55)

const METAL_TOP: Color = Color(0.298, 0.361, 0.471)
const METAL_FT: Color = Color(0.192, 0.243, 0.333)
const METAL_FB: Color = Color(0.078, 0.102, 0.157)
const DARK_TOP: Color = Color(0.180, 0.220, 0.298)
const DARK_FT: Color = Color(0.110, 0.141, 0.204)
const DARK_FB: Color = Color(0.047, 0.063, 0.098)
const RUST_TOP: Color = Color(0.353, 0.259, 0.192)
const RUST_FT: Color = Color(0.243, 0.169, 0.125)
const RUST_FB: Color = Color(0.110, 0.078, 0.059)

## Transparent gutter between atlas entries, so linear filtering at zoomed-out
## scale cannot drag one sprite's pixels into its neighbour's.
const ATLAS_GAP: int = 4
## Everything the renderer can draw as a figure. The first four are the city's
## own people and each one is a different SHAPE — see `_bake_person` and
## tests/render/test_sprites.gd::test_the_city_roles_are_distinguishable_by_shape_alone.
## `swarm` and `brute` are the two generic hostile fallbacks for an enemy id
## nobody has drawn yet; the eleven designed creatures are ENEMY_KINDS.
const AGENT_KINDS: Array[StringName] = [
	&"citizen", &"worker", &"porter", &"soldier", &"swarm", &"brute",
]
## The city's own people, in the order a player meets them.
const PERSON_KINDS: Array[StringName] = [&"citizen", &"worker", &"porter", &"soldier"]

var _cache: Dictionary[StringName, Dictionary] = {}
var _atlas: Dictionary = {}
var _atlas_keys: Dictionary[StringName, bool] = {}


# ------------------------------------------------------------------ catalog --

## Footprint and apparent height of every archetype the renderer can draw.
##
## `lift` is per TILE of depth, not absolute, so a 5x5 hearth and a 3x2 coal
## generator are drawn at the same detail density instead of one being a
## rubber-stamped enlargement of the other — which is exactly what a critic
## caught in the first pass: two structurally identical hearths at two scales in
## one frame. `lift_min` keeps a 1x1 mast tall.
static func spec(arch: StringName) -> Dictionary:
	match arch:
		&"hearth": return {"tiles": Vector2i(5, 5), "lift": 108.0, "warm": 1.0}
		&"generator": return {"tiles": Vector2i(3, 2), "lift": 66.0, "warm": 0.85}
		&"heat_plant": return {"tiles": Vector2i(3, 3), "lift": 62.0, "warm": 0.9}
		&"radiator": return {"tiles": Vector2i(2, 2), "lift": 54.0, "warm": 0.75}
		&"accumulator": return {"tiles": Vector2i(2, 2), "lift": 46.0, "warm": 0.30}
		&"foundry": return {"tiles": Vector2i(3, 3), "lift": 50.0, "warm": 0.8}
		&"workshop": return {"tiles": Vector2i(4, 3), "lift": 40.0, "warm": 0.45}
		&"assembler": return {"tiles": Vector2i(4, 4), "lift": 46.0, "warm": 0.5}
		&"research_hall": return {"tiles": Vector2i(3, 3), "lift": 44.0, "warm": 0.6}
		&"kitchen": return {"tiles": Vector2i(3, 2), "lift": 36.0, "warm": 0.65}
		&"habitat": return {"tiles": Vector2i(4, 4), "lift": 52.0, "warm": 0.55}
		&"greenhouse": return {"tiles": Vector2i(3, 2), "lift": 34.0, "warm": 0.7}
		&"depot": return {"tiles": Vector2i(3, 3), "lift": 30.0, "warm": 0.15}
		&"silo": return {"tiles": Vector2i(3, 3), "lift": 66.0, "warm": 0.10}
		&"mine": return {"tiles": Vector2i(2, 2), "lift": 60.0, "warm": 0.25}
		&"drill": return {"tiles": Vector2i(3, 3), "lift": 84.0, "warm": 0.20}
		&"collector": return {"tiles": Vector2i(2, 2), "lift": 28.0, "warm": 0.12}
		&"crate": return {"tiles": Vector2i(1, 1), "lift": 26.0, "warm": 0.05}
		&"turret": return {"tiles": Vector2i(2, 2), "lift": 40.0, "warm": 0.2}
		&"pylon": return {"tiles": Vector2i(1, 1), "lift": 70.0, "warm": 0.3}
		&"watchtower": return {"tiles": Vector2i(2, 2), "lift": 76.0, "warm": 0.35}
		&"wall": return {"tiles": Vector2i(1, 1), "lift": 15.0, "warm": 0.0}
		&"pipe": return {"tiles": Vector2i(1, 1), "lift": 9.0, "warm": 0.35}
		&"belt": return {"tiles": Vector2i(1, 1), "lift": 6.0, "warm": 0.0}
		&"splitter": return {"tiles": Vector2i(1, 2), "lift": 24.0, "warm": 0.0}
		&"underground": return {"tiles": Vector2i(1, 1), "lift": 18.0, "warm": 0.0}
		&"arm": return {"tiles": Vector2i(1, 1), "lift": 24.0, "warm": 0.0}
		&"long_arm": return {"tiles": Vector2i(1, 1), "lift": 32.0, "warm": 0.0}
		&"road": return {"tiles": Vector2i(1, 1), "lift": 1.0, "warm": 0.0}
		&"ruin": return {"tiles": Vector2i(1, 1), "lift": 13.0, "warm": 0.0}
		&"dead_tree": return {"tiles": Vector2i(1, 1), "lift": 46.0, "warm": 0.0}
		&"rock": return {"tiles": Vector2i(1, 1), "lift": 20.0, "warm": 0.0}
		&"wreck": return {"tiles": Vector2i(2, 1), "lift": 22.0, "warm": 0.0}
	return {"tiles": Vector2i(2, 2), "lift": 34.0, "warm": 0.0}


## Every archetype, sorted. Used by tests and by the art-sheet dump.
static func archetypes() -> Array[StringName]:
	return [
		&"accumulator", &"arm", &"assembler", &"belt", &"collector", &"crate",
		&"dead_tree", &"depot", &"drill", &"foundry", &"generator", &"greenhouse",
		&"habitat", &"hearth", &"heat_plant", &"kitchen", &"long_arm", &"mine",
		&"pipe", &"pylon", &"radiator", &"research_hall", &"road", &"rock",
		&"ruin", &"silo", &"splitter", &"turret", &"underground", &"wall",
		&"watchtower", &"workshop", &"wreck",
	]


## Maps an arbitrary building id from [P11]/content onto a drawable archetype.
## Unknown ids resolve to a generic workshop block rather than vanishing, so a
## new building always renders as *something* readable.
##
## Order matters: the narrow infrastructure shapes are matched first, because
## ids like "heat_pipe" and "rubble_road" contain a broader word too.
static func archetype_for(kind: StringName) -> StringName:
	var k: String = String(kind).to_lower()
	if k.contains("pipe") or k.contains("conduit") or k.contains("duct") or k.contains("trunk"):
		return &"pipe"
	# The belt FAMILY is matched before the plain belt, because every one of these
	# ids also contains a broader transport word and every one of them is a
	# different machine on the ground: a player reading a line has to see where it
	# forks, where it dives and where something lifts items off it.
	if k.contains("underground") or k.contains("sunken") or k.contains("tunnel") or k.contains("subway"):
		return &"underground"
	if k.contains("splitter") or k.contains("split") or k.contains("balancer") or k.contains("divider"):
		return &"splitter"
	if k.contains("long_arm") or k.contains("longarm") or k.contains("stacker"):
		return &"long_arm"
	if k.contains("inserter") or k.contains("grabber") or k.contains("claw") or k.contains("manipulator"):
		return &"arm"
	if k.contains("belt") or k.contains("conveyor") or k.contains("lane"):
		return &"belt"
	if k.contains("road") or k.contains("path") or k.contains("pave") or k.contains("track"):
		return &"road"
	if k.contains("wall") or k.contains("barrier") or k.contains("gate") or k.contains("palisade"):
		return &"wall"
	if k.contains("turret") or k.contains("gun") or k.contains("cannon") or k.contains("defen") or k.contains("emplace"):
		return &"turret"
	if k.contains("tower") or k.contains("radar") or k.contains("watch") or k.contains("scan") or k.contains("beacon"):
		return &"watchtower"
	if k.contains("pylon") or k.contains("mast") or k.contains("relay") or k.contains("antenna"):
		return &"pylon"
	# The Hearth is the one building in the game with its own silhouette. It is the
	# thing every road points at, so it must never share a shape with anything.
	if k.contains("hearth") or k.contains("great_") or k.contains("reactor"):
		return &"hearth"
	if k.contains("generator") or k.contains("engine") or k.contains("dynamo"):
		return &"generator"
	if k.contains("foundry") or k.contains("smelt") or k.contains("refin") or k.contains("forge") or k.contains("kiln"):
		return &"foundry"
	if k.contains("assembl") or k.contains("fabricat"):
		return &"assembler"
	if k.contains("survey") or k.contains("research") or k.contains("laborator") or k.contains("observ"):
		return &"research_hall"
	if k.contains("radiator") or k.contains("warmth") or k.contains("emitter") \
			or k.contains("recuperat") or k.contains("exchanger") or k.contains("vent"):
		return &"radiator"
	if k.contains("accumulator") or k.contains("buffer") or k.contains("battery") or k.contains("cistern"):
		return &"accumulator"
	if k.contains("boiler") or k.contains("furnace") or k.contains("heat") or k.contains("steam") \
			or k.contains("geo") or k.contains("thermal") or k.contains("core"):
		return &"heat_plant"
	if k.contains("hous") or k.contains("home") or k.contains("hab") or k.contains("shelter") \
			or k.contains("tent") or k.contains("barrack") or k.contains("dorm") \
			or k.contains("lodg") or k.contains("quarters"):
		return &"habitat"
	if k.contains("kitchen") or k.contains("canteen") or k.contains("mess") or k.contains("cook"):
		return &"kitchen"
	if k.contains("green") or k.contains("farm") or k.contains("hydro") or k.contains("food") \
			or k.contains("garden"):
		return &"greenhouse"
	if k.contains("silo") or k.contains("granary") or k.contains("tank") or k.contains("cylinder"):
		return &"silo"
	# A single-tile container before the yard, so "steel bunker" does not become a
	# three-tile depot the player cannot fit where the belt actually ends.
	if k.contains("crate") or k.contains("chest") or k.contains("box") or k.contains("container") \
			or k.contains("request") or k.contains("requisition") or k.contains("locker"):
		return &"crate"
	if k.contains("depot") or k.contains("store") or k.contains("warehouse") \
			or k.contains("stock") or k.contains("yard"):
		return &"depot"
	if k.contains("drill") or k.contains("derrick") or k.contains("bore") or k.contains("well"):
		return &"drill"
	if k.contains("collector") or k.contains("scrap") or k.contains("salvage") \
			or k.contains("picker") or k.contains("sorter") or k.contains("breaker"):
		return &"collector"
	if k.contains("mine") or k.contains("extract") or k.contains("quarry") or k.contains("pump"):
		return &"mine"
	if k.contains("tree") or k.contains("stump") or k.contains("pine"):
		return &"dead_tree"
	if k.contains("outcrop") or k.contains("boulder") or k.contains("rock"):
		return &"rock"
	if k.contains("wreck") or k.contains("hulk") or k.contains("carcass"):
		return &"wreck"
	if k.contains("ruin") or k.contains("rubble") or k.contains("debris"):
		return &"ruin"
	return &"workshop"


# ------------------------------------------------------------------- public --

## Baked sprite for an archetype at a specific footprint. Cached in memory and
## on disk. Keys: texture, offset (draw position relative to footprint top-left),
## tiles, lift, warm, light_offset, light_radius.
##
## Pass `tiles` whenever the building definition has a size of its own. The
## sprite is then DRAWN at that footprint rather than drawn once and stretched:
## a 5x5 structure gets 5x5 worth of detail, and two buildings that happen to
## share an archetype never appear as the same picture at two zoom levels.
func building(arch: StringName, tiles: Vector2i = Vector2i.ZERO) -> Dictionary:
	var sp: Dictionary = spec(arch)
	var nat: Vector2i = sp["tiles"]
	var t: Vector2i = nat
	if tiles.x > 0 and tiles.y > 0:
		t = Vector2i(clampi(tiles.x, 1, 12), clampi(tiles.y, 1, 12))
	var key: StringName = StringName("%s_%dx%d" % [arch, t.x, t.y])
	var hit: Dictionary = _cache.get(key, {})
	if not hit.is_empty():
		return hit

	# pow(.., 0.72), not the linear ratio: a building twice the footprint is
	# taller but NOT a 2x magnification of the same drawing, so the detail in it
	# stays the same size on screen and two sizes of the same archetype no longer
	# read as one picture at two zoom levels.
	var ratio: float = pow(float(t.x * t.y) / float(maxi(1, nat.x * nat.y)), 0.36)
	var lift: float = float(sp["lift"]) * clampf(ratio, 0.60, 1.70)
	var tex: ImageTexture = LcnArtCache.get_texture(
		"bld_%s_%dx%d" % [arch, t.x, t.y], func() -> Image: return _bake_building(arch, t, lift)
	)
	var entry: Dictionary = {
		"texture": tex,
		"offset": Vector2(-PAD, -PAD - lift),
		"tiles": t,
		"lift": lift,
		"warm": float(sp["warm"]),
		"light_offset": Vector2(float(t.x) * TILE * 0.5, float(t.y) * TILE * 0.5 - lift * 0.45),
		"light_radius": maxf(96.0, float(maxi(t.x, t.y)) * TILE * 2.6),
	}
	_cache[key] = entry
	return entry


## The rotatable turret barrel, drawn pointing +X with its pivot at (6, centre).
func turret_barrel() -> Dictionary:
	var hit: Dictionary = _cache.get(&"_barrel", {})
	if not hit.is_empty():
		return hit
	var tex: ImageTexture = LcnArtCache.get_texture("bld_barrel", func() -> Image: return _bake_barrel())
	var entry: Dictionary = {"texture": tex, "pivot": Vector2(8.0, 9.0)}
	_cache[&"_barrel"] = entry
	return entry


## Small agent sprites: &"citizen", &"worker", &"soldier", &"swarm", &"brute".
func agent(kind: StringName) -> Dictionary:
	var key: StringName = StringName("_agent_%s" % kind)
	var hit: Dictionary = _cache.get(key, {})
	if not hit.is_empty():
		return hit
	var tex: ImageTexture = LcnArtCache.get_texture(
		"agent_%s" % kind, func() -> Image: return _bake_agent(kind)
	)
	var entry: Dictionary = {"texture": tex, "offset": Vector2(-float(tex.get_width()) * 0.5, -float(tex.get_height()) + 5.0)}
	_cache[key] = entry
	return entry


## Soft radial cookie used by every Light2D and by additive glow draws.
static func glow_texture(size: int = 256) -> ImageTexture:
	return LcnArtCache.get_texture("glow_%d" % size, func() -> Image: return _bake_glow(size))


## Long soft shadow blob, stretched at draw time. Cheaper and far prettier than
## rasterising a real shadow polygon every frame.
static func shadow_texture(size: int = 96) -> ImageTexture:
	return LcnArtCache.get_texture("shadow_%d" % size, func() -> Image: return _bake_shadow(size))


# ------------------------------------------------------------- bake: shared --

func _bake_building(arch: StringName, tiles: Vector2i, lift: float) -> Image:
	var w: int = tiles.x * TILE
	var d: int = tiles.y * TILE
	var c := LcnVectorCanvas.new(w + PAD * 2, d + int(lift) + PAD * 2, SS)
	var g := Rect2(float(PAD), float(PAD) + lift, float(w), float(d))
	match arch:
		&"hearth": _draw_hearth(c, g)
		&"radiator": _draw_radiator(c, g)
		&"accumulator": _draw_accumulator(c, g)
		&"silo": _draw_silo(c, g)
		&"kitchen": _draw_kitchen(c, g)
		&"drill": _draw_drill(c, g)
		&"collector": _draw_collector(c, g)
		&"generator": _draw_generator(c, g)
		&"heat_plant": _draw_heat_plant(c, g)
		&"foundry": _draw_foundry(c, g)
		&"workshop": _draw_workshop(c, g)
		&"assembler": _draw_assembler(c, g)
		&"research_hall": _draw_research_hall(c, g)
		&"crate": _draw_crate(c, g)
		&"splitter": _draw_splitter(c, g)
		&"underground": _draw_underground(c, g)
		&"arm": _draw_arm(c, g)
		&"long_arm": _draw_long_arm(c, g)
		&"habitat": _draw_habitat(c, g)
		&"greenhouse": _draw_greenhouse(c, g)
		&"depot": _draw_depot(c, g)
		&"mine": _draw_mine(c, g)
		&"turret": _draw_turret(c, g)
		&"pylon": _draw_pylon(c, g)
		&"watchtower": _draw_watchtower(c, g)
		&"wall": _draw_wall(c, g)
		&"pipe": _draw_pipe(c, g)
		&"belt": _draw_belt(c, g)
		&"road": _draw_road(c, g)
		&"ruin": _draw_ruin(c, g)
		&"dead_tree": _draw_dead_tree(c, g)
		&"rock": _draw_rock(c, g)
		&"wreck": _draw_wreck(c, g)
		_: _draw_workshop(c, g)
	var img: Image = c.to_image()
	LcnVectorCanvas.apply_grain(img, 0.028, int(String(arch).hash()) & 0xFFFF)
	return img


## Draws a rectangular mass: front face, top face, roof seam and silhouette.
func _mass(c: LcnVectorCanvas, r: Rect2, h: float, top: Color, ft: Color, fb: Color, outline: bool = true) -> void:
	var roof_y: float = r.end.y - h
	c.fill_polygon_gradient(PackedVector2Array([
		Vector2(r.position.x, roof_y),
		Vector2(r.end.x, roof_y),
		Vector2(r.end.x, r.end.y),
		Vector2(r.position.x, r.end.y),
	]), ft, fb, Vector2(0.0, roof_y), Vector2(0.0, r.end.y))
	# Left edge catches the key light, right edge falls into shadow.
	c.fill_polygon_gradient(PackedVector2Array([
		Vector2(r.position.x, roof_y),
		Vector2(r.position.x + r.size.x * 0.34, roof_y),
		Vector2(r.position.x + r.size.x * 0.34, r.end.y),
		Vector2(r.position.x, r.end.y),
	]), Color(1, 1, 1, 0.10), Color(1, 1, 1, 0.0), r.position, Vector2(r.position.x + r.size.x * 0.34, 0.0))
	c.fill_polygon_gradient(PackedVector2Array([
		Vector2(r.end.x - r.size.x * 0.26, roof_y),
		Vector2(r.end.x, roof_y),
		Vector2(r.end.x, r.end.y),
		Vector2(r.end.x - r.size.x * 0.26, r.end.y),
	]), Color(0, 0, 0, 0.0), Color(0, 0, 0, 0.26), Vector2(r.end.x - r.size.x * 0.26, 0.0), Vector2(r.end.x, 0.0))

	var top_rect := Rect2(r.position.x, r.position.y - h, r.size.x, r.size.y)
	# A ROOF, not a filled rectangle. Top-down, the roof plane is most of what the
	# player sees of a structure, so a flat gradient there means every industrial
	# block in the frame is the same grey slab — which is exactly what the frames
	# showed. Three cheap things fix it: the far edge falls away, the near eave
	# catches the light, and the whole plate is bevelled in from the silhouette.
	c.fill_rect_gradient(top_rect, top.lightened(0.10), top.darkened(0.34))
	c.fill_rect_gradient(
		Rect2(top_rect.position.x, top_rect.position.y, top_rect.size.x, top_rect.size.y * 0.30),
		Color(0, 0, 0, 0.30), Color(0, 0, 0, 0.0))
	c.fill_rect_gradient(
		Rect2(top_rect.position.x, top_rect.end.y - top_rect.size.y * 0.22,
			top_rect.size.x, top_rect.size.y * 0.22),
		Color(1, 1, 1, 0.0), Color(1, 1, 1, 0.13))
	# Panel seams and a ridge beam. A roof is most of what a top-down camera sees
	# of a building, and an unbroken filled rectangle up there is what made every
	# industrial block read as the same grey slab at far zoom.
	var panels: int = clampi(int(top_rect.size.x / 15.0), 2, 7)
	for i: int in panels - 1:
		var px: float = lerpf(top_rect.position.x, top_rect.end.x, float(i + 1) / float(panels))
		c.stroke_polyline(PackedVector2Array([
			Vector2(px, top_rect.position.y + 1.0), Vector2(px, top_rect.end.y - 1.0),
		]), Color(SEAM.r, SEAM.g, SEAM.b, 0.40), 1.1)
		c.stroke_polyline(PackedVector2Array([
			Vector2(px + 1.0, top_rect.position.y + 1.0), Vector2(px + 1.0, top_rect.end.y - 1.0),
		]), Color(1.0, 1.0, 1.0, 0.055), 1.0)
	var ridge_y: float = top_rect.position.y + top_rect.size.y * 0.42
	c.stroke_polyline(PackedVector2Array([
		Vector2(top_rect.position.x + 1.0, ridge_y), Vector2(top_rect.end.x - 1.0, ridge_y),
	]), Color(1.0, 1.0, 1.0, 0.085), 2.0)
	c.stroke_polyline(PackedVector2Array([
		Vector2(top_rect.position.x + 1.0, ridge_y + 2.0), Vector2(top_rect.end.x - 1.0, ridge_y + 2.0),
	]), Color(SEAM.r, SEAM.g, SEAM.b, 0.35), 1.2)
	c.stroke_polyline(PackedVector2Array([Vector2(r.position.x, roof_y), Vector2(r.end.x, roof_y)]), SEAM, 1.4)
	if outline:
		c.stroke_rect(Rect2(r.position.x, r.position.y - h, r.size.x, r.size.y + h), OUTLINE, 1.7)


## A wobbly closed blob, the base shape for drifts, soot patches and puddles.
static func _blob(centre: Vector2, rx: float, ry: float, seed_value: int, wobble: float = 0.34) -> PackedVector2Array:
	var n: int = 14
	var out := PackedVector2Array()
	out.resize(n)
	for i: int in n:
		var a: float = TAU * float(i) / float(n)
		var k: float = 1.0 + (LcnNoise.value(cos(a) * 1.6 + 3.0, sin(a) * 1.6 + 3.0, seed_value) - 0.5) * 2.0 * wobble
		out[i] = centre + Vector2(cos(a) * rx * k, sin(a) * ry * k)
	return out


## Snow settled on a roof. A flat roof in this climate is fully covered, so the
## interest comes from tone (cold at the back, lit at the front), from the metal
## the wind has scoured bare, and from the lip that overhangs the front edge.
func _snow_roof(c: LcnVectorCanvas, r: Rect2, h: float, coverage: float, seed_value: int,
		roof_col: Color = Color(0.184, 0.224, 0.298)) -> void:
	var top_rect := Rect2(r.position.x, r.position.y - h, r.size.x, r.size.y)
	# THE GROUND SNOW RAMP, not the interface ramp. A 5x5 roof filled from
	# SNOW_MID to SNOW_LIT is a 160 px near-white card, and next to a plain that
	# has been brought down to a polar blue-grey it is the single brightest thing
	# in a midday frame — which is precisely what a critic saw and called washed
	# out. Snow on a roof is the same material as the snow beside it and has to be
	# painted out of the same tin.
	c.fill_rect_gradient(top_rect,
		LcnPalette.GROUND_SNOW_SHADOW.lerp(LcnPalette.GROUND_SNOW_MID, 0.18),
		LcnPalette.GROUND_SNOW_MID.lerp(LcnPalette.GROUND_SNOW_LIT, 0.30))
	# A drift banked against the windward edge. Without it the roof is a flat
	# gradient and every roofed building in the frame is the same rectangle.
	var bank: float = top_rect.size.x * 0.30
	c.fill_polygon(PackedVector2Array([
		Vector2(top_rect.position.x, top_rect.position.y),
		Vector2(top_rect.position.x + bank, top_rect.position.y),
		Vector2(top_rect.position.x + bank * 0.45, top_rect.end.y),
		Vector2(top_rect.position.x, top_rect.end.y),
	]), Color(LcnPalette.GROUND_SNOW_LIT.r, LcnPalette.GROUND_SNOW_LIT.g,
		LcnPalette.GROUND_SNOW_LIT.b, 0.80))
	c.fill_polygon(PackedVector2Array([
		Vector2(top_rect.end.x - bank * 0.5, top_rect.position.y),
		Vector2(top_rect.end.x, top_rect.position.y),
		Vector2(top_rect.end.x, top_rect.end.y),
		Vector2(top_rect.end.x - bank * 0.22, top_rect.end.y),
	]), Color(LcnPalette.GROUND_SNOW_SHADOW.r, LcnPalette.GROUND_SNOW_SHADOW.g,
		LcnPalette.GROUND_SNOW_SHADOW.b, 0.62))

	# Wind-scoured PANELS, not blobs. A roof is built out of plates on ribs, and
	# the wind strips whole plates; scattering soft ellipses of roof colour across
	# a white field instead produced grey clouds sitting on a white card, which is
	# what the second pass shipped and what a critic read as fog on a slab. Every
	# bare patch is now a rectangle on the panel pitch with a snow lip banked
	# against its upwind rib, so the building visibly has a STRUCTURE under the
	# snow — and that is what makes it read as steel rather than as a stain.
	var panels: int = clampi(int(top_rect.size.x / 14.0), 2, 8)
	var pw: float = top_rect.size.x / float(panels)
	var bare: int = clampi(int((1.0 - coverage) * float(panels) * 1.2), 1, panels)
	for i: int in bare:
		var col_i: int = int(LcnNoise.hash3(i, seed_value, 3) * float(panels)) % panels
		var y0f: float = LcnNoise.hash3(i, seed_value, 11)
		var hf: float = lerpf(0.34, 0.86, LcnNoise.hash3(i, seed_value, 19))
		var px: float = top_rect.position.x + pw * float(col_i) + 1.0
		var py: float = lerpf(top_rect.position.y + 1.0,
			top_rect.end.y - top_rect.size.y * hf - 1.0, y0f)
		var plate := Rect2(px, py, pw - 2.0, top_rect.size.y * hf)
		c.fill_rect_gradient(plate,
			Color(roof_col.r * 1.06, roof_col.g * 1.06, roof_col.b * 1.10),
			Color(roof_col.r * 0.66, roof_col.g * 0.66, roof_col.b * 0.74))
		# The lip of the drift banked against the plate's upwind rib. Snow stands
		# up where the wind lifted off the plate, so a bare panel has a raised
		# edge and reads as a hole in a layer, not as paint on one.
		c.fill_polygon(PackedVector2Array([
			Vector2(plate.position.x - 1.4, plate.position.y - 1.6),
			Vector2(plate.end.x + 1.4, plate.position.y - 1.6),
			Vector2(plate.end.x + 0.4, plate.position.y + 1.6),
			Vector2(plate.position.x - 0.4, plate.position.y + 1.6),
		]), Color(LcnPalette.GROUND_SNOW_LIT.r, LcnPalette.GROUND_SNOW_LIT.g,
			LcnPalette.GROUND_SNOW_LIT.b, 0.80))
		c.stroke_rect(plate, Color(SEAM.r, SEAM.g, SEAM.b, 0.75), 1.1)

	# Drift streaks running with the prevailing wind.
	for i: int in 4:
		var y: float = lerpf(top_rect.position.y + 2.0, top_rect.end.y - 2.0,
			(float(i) + 0.4 + LcnNoise.hash3(i, seed_value, 31) * 0.4) / 4.0)
		c.stroke_polyline(PackedVector2Array([
			Vector2(top_rect.position.x + 1.0, y),
			Vector2(top_rect.position.x + top_rect.size.x * 0.5, y - 1.4),
			Vector2(top_rect.end.x - 1.0, y + 0.6),
		]), Color(LcnPalette.GROUND_SNOW_LIT.r, LcnPalette.GROUND_SNOW_LIT.g,
			LcnPalette.GROUND_SNOW_LIT.b, 0.55), 1.3)
	c.stroke_polyline(PackedVector2Array([
		top_rect.position, Vector2(top_rect.end.x, top_rect.position.y),
	]), Color(0.44, 0.51, 0.62, 0.55), 2.0)

	var lip_y: float = r.end.y - h
	c.fill_polygon(PackedVector2Array([
		Vector2(r.position.x - 1.2, lip_y - 2.6),
		Vector2(r.end.x + 1.2, lip_y - 2.6),
		Vector2(r.end.x + 1.2, lip_y + 1.4),
		Vector2(r.position.x - 1.2, lip_y + 1.4),
	]), Color(LcnPalette.GROUND_SNOW_LIT.r, LcnPalette.GROUND_SNOW_LIT.g,
		LcnPalette.GROUND_SNOW_LIT.b, 0.94))
	var drips: int = maxi(2, int(r.size.x / 11.0))
	for i: int in drips:
		var f: float = (float(i) + 0.5) / float(drips)
		var x: float = lerpf(r.position.x + 2.0, r.end.x - 2.0, f)
		var len_px: float = 2.0 + LcnNoise.hash3(i, seed_value, 31) * 5.0
		c.fill_polygon(PackedVector2Array([
			Vector2(x - 1.7, lip_y + 1.0),
			Vector2(x + 1.7, lip_y + 1.0),
			Vector2(x, lip_y + 1.0 + len_px),
		]), Color(LcnPalette.GROUND_SNOW_MID.r, LcnPalette.GROUND_SNOW_MID.g,
			LcnPalette.GROUND_SNOW_MID.b, 0.85))


## A grid of lit windows on a front face, with their bloom pre-baked.
func _windows(c: LcnVectorCanvas, face: Rect2, cols: int, rows: int, lit: Color, seed_value: int) -> void:
	var gap_x: float = face.size.x / float(cols + 1)
	var gap_y: float = face.size.y / float(rows + 1)
	var ww: float = minf(gap_x * 0.62, 7.0)
	var wh: float = minf(gap_y * 0.66, 8.0)
	for j: int in rows:
		for i: int in cols:
			var cx: float = face.position.x + gap_x * float(i + 1)
			var cy: float = face.position.y + gap_y * float(j + 1)
			var on: bool = LcnNoise.hash3(i, j, seed_value) > 0.24
			var col: Color = lit if on else Color(0.086, 0.110, 0.176, 0.95)
			if on:
				c.fill_glow(Vector2(cx, cy), ww * 2.5,
					Color(col.r, col.g, col.b, 0.42), Color(col.r, col.g, col.b, 0.0))
			c.fill_round_rect(Rect2(cx - ww * 0.5, cy - wh * 0.5, ww, wh), 1.2, col)
			if on:
				c.fill_round_rect(Rect2(cx - ww * 0.32, cy - wh * 0.36, ww * 0.64, wh * 0.4), 0.8,
					Color(1.0, 0.98, 0.92, 0.85))


## Vertical stack with a flared cap. The chimney is the single most valuable
## silhouette element in the whole set — it says "this thing burns something".
func _chimney(c: LcnVectorCanvas, x: float, base_y: float, h: float, w: float, seed_value: int) -> void:
	var half: float = w * 0.5
	c.fill_polygon_gradient(PackedVector2Array([
		Vector2(x - half * 0.82, base_y - h),
		Vector2(x + half * 0.82, base_y - h),
		Vector2(x + half, base_y),
		Vector2(x - half, base_y),
	]), Color(0.239, 0.286, 0.376), Color(0.086, 0.110, 0.169), Vector2(x - half, 0.0), Vector2(x + half, 0.0))
	c.fill_round_rect(Rect2(x - half * 1.32, base_y - h - 5.0, half * 2.64, 6.0), 1.5, Color(0.271, 0.318, 0.404))
	c.stroke_rect(Rect2(x - half * 1.32, base_y - h - 5.0, half * 2.64, 6.0), OUTLINE, 1.4)
	c.stroke_polygon(PackedVector2Array([
		Vector2(x - half * 0.82, base_y - h),
		Vector2(x + half * 0.82, base_y - h),
		Vector2(x + half, base_y),
		Vector2(x - half, base_y),
	]), OUTLINE, 1.5)
	for i: int in 3:
		var y: float = base_y - h * (0.28 + 0.24 * float(i))
		c.stroke_polyline(PackedVector2Array([
			Vector2(x - half * 0.9, y), Vector2(x + half * 0.9, y),
		]), Color(0.043, 0.063, 0.110, 0.5), 1.2)
	# Soot halo, so industry visibly dirties its own air.
	c.fill_glow(Vector2(x, base_y - h - 6.0), w * 1.9,
		Color(0.16, 0.15, 0.15, 0.30), Color(0.16, 0.15, 0.15, 0.0))
	c.fill_polygon(PackedVector2Array([
		Vector2(x - half * 1.1, base_y - h - 4.0),
		Vector2(x + half * 1.1, base_y - h - 4.0),
		Vector2(x + half * 0.7, base_y - h - 1.5),
		Vector2(x - half * 0.7, base_y - h - 1.5),
	]), Color(0.05, 0.05, 0.06, 0.75))
	c.fill_glow(Vector2(x, base_y - h - 2.5), w * 0.8,
		Color(1.0, 0.42, 0.18, 0.55), Color(1.0, 0.42, 0.18, 0.0))
	if seed_value % 3 == 0:
		c.stroke_polyline(PackedVector2Array([
			Vector2(x + half, base_y - h * 0.6),
			Vector2(x + half + 4.0, base_y - h * 0.5),
			Vector2(x + half + 4.0, base_y - h * 0.1),
		]), Color(0.176, 0.216, 0.290), 1.6)


func _cylinder(c: LcnVectorCanvas, cx: float, base_y: float, rx: float, ry: float, h: float,
		top: Color, ft: Color, fb: Color) -> void:
	c.fill_ellipse(Vector2(cx, base_y), rx, ry, fb.darkened(0.35))
	c.fill_polygon_gradient(PackedVector2Array([
		Vector2(cx - rx, base_y - h),
		Vector2(cx + rx, base_y - h),
		Vector2(cx + rx, base_y),
		Vector2(cx - rx, base_y),
	]), ft, fb, Vector2(cx - rx, 0.0), Vector2(cx + rx, 0.0))
	c.fill_ellipse(Vector2(cx, base_y), rx, ry, fb)
	c.fill_ellipse(Vector2(cx, base_y - h), rx, ry, top)
	c.fill_ellipse(Vector2(cx, base_y - h + 1.0), rx * 0.72, ry * 0.62, top.lightened(0.12))
	c.stroke_polygon(LcnVectorCanvas.circle_points(Vector2(cx, base_y - h), rx, ry, 26), OUTLINE, 1.5)
	c.stroke_polyline(PackedVector2Array([
		Vector2(cx - rx, base_y - h), Vector2(cx - rx, base_y),
	]), OUTLINE, 1.5)
	c.stroke_polyline(PackedVector2Array([
		Vector2(cx + rx, base_y - h), Vector2(cx + rx, base_y),
	]), OUTLINE, 1.5)
	c.stroke_polyline(PackedVector2Array([
		Vector2(cx - rx, base_y), Vector2(cx - rx * 0.7, base_y + ry * 0.8),
		Vector2(cx + rx * 0.7, base_y + ry * 0.8), Vector2(cx + rx, base_y),
	]), OUTLINE, 1.5)


func _rivets(c: LcnVectorCanvas, r: Rect2, n: int, col: Color) -> void:
	for i: int in n:
		var f: float = (float(i) + 0.5) / float(n)
		c.fill_circle(Vector2(lerpf(r.position.x, r.end.x, f), r.position.y), 0.9, col, 6)
		c.fill_circle(Vector2(lerpf(r.position.x, r.end.x, f), r.end.y), 0.9, col, 6)


# ------------------------------------------------------------ bake: buildings --

## THE generator. Round, huge, radial vent fins, crown of exhaust. It is the
## heart of the city and it must look like the heart of the city.
func _draw_generator(c: LcnVectorCanvas, g: Rect2) -> void:
	var cx: float = g.position.x + g.size.x * 0.5
	var base_y: float = g.end.y - 4.0

	c.fill_ellipse(Vector2(cx, base_y + 2.0), g.size.x * 0.52, g.size.y * 0.24, Color(0.043, 0.059, 0.098, 0.55))
	# Splayed foundation ring.
	c.fill_polygon_gradient(PackedVector2Array([
		Vector2(cx - g.size.x * 0.46, base_y - 16.0),
		Vector2(cx + g.size.x * 0.46, base_y - 16.0),
		Vector2(cx + g.size.x * 0.50, base_y),
		Vector2(cx - g.size.x * 0.50, base_y),
	]), DARK_FT, DARK_FB, Vector2(0.0, base_y - 16.0), Vector2(0.0, base_y))
	c.stroke_polygon(PackedVector2Array([
		Vector2(cx - g.size.x * 0.46, base_y - 16.0),
		Vector2(cx + g.size.x * 0.46, base_y - 16.0),
		Vector2(cx + g.size.x * 0.50, base_y),
		Vector2(cx - g.size.x * 0.50, base_y),
	]), OUTLINE, 1.8)

	_cylinder(c, cx, base_y - 14.0, g.size.x * 0.40, g.size.y * 0.17, 44.0,
		Color(0.286, 0.345, 0.451), Color(0.216, 0.267, 0.365), Color(0.075, 0.098, 0.153))

	# Radial vent slots glowing from the fire inside.
	for i: int in 7:
		var f: float = (float(i) + 0.5) / 7.0
		var x: float = lerpf(cx - g.size.x * 0.34, cx + g.size.x * 0.34, f)
		c.fill_glow(Vector2(x, base_y - 30.0), 9.0, Color(1.0, 0.48, 0.18, 0.55), Color(1.0, 0.48, 0.18, 0.0))
		c.fill_round_rect(Rect2(x - 2.4, base_y - 40.0, 4.8, 20.0), 1.6, Color(1.0, 0.62, 0.27, 0.95))
		c.fill_round_rect(Rect2(x - 1.2, base_y - 38.0, 2.4, 16.0), 1.0, Color(1.0, 0.93, 0.78, 0.95))

	# Banded upper drum.
	_cylinder(c, cx, base_y - 58.0, g.size.x * 0.29, g.size.y * 0.12, 20.0,
		Color(0.322, 0.380, 0.478), Color(0.239, 0.290, 0.384), Color(0.098, 0.125, 0.184))
	c.stroke_polyline(PackedVector2Array([
		Vector2(cx - g.size.x * 0.29, base_y - 68.0), Vector2(cx + g.size.x * 0.29, base_y - 68.0),
	]), Color(0.043, 0.063, 0.110, 0.6), 1.4)

	_chimney(c, cx, base_y - 76.0, 22.0, 11.0, 4)
	# Crown of four small stacks reads instantly even at 4x zoom-out.
	for i: int in 4:
		var ox: float = lerpf(-g.size.x * 0.30, g.size.x * 0.30, float(i) / 3.0)
		if absf(ox) < g.size.x * 0.12:
			continue
		_chimney(c, cx + ox, base_y - 62.0, 12.0, 5.0, i + 1)

	c.fill_polygon(PackedVector2Array([
		Vector2(cx - g.size.x * 0.30, base_y - 78.0),
		Vector2(cx + g.size.x * 0.30, base_y - 78.0),
		Vector2(cx + g.size.x * 0.24, base_y - 80.5),
		Vector2(cx - g.size.x * 0.24, base_y - 80.5),
	]), Color(0.816, 0.859, 0.918, 0.85))
	_snow_roof(c, Rect2(cx - g.size.x * 0.29, base_y - 14.0, g.size.x * 0.58, 6.0), 58.0, 0.30, 11, Color(0.286, 0.345, 0.451))


## Boiler house: squat drum + one dominant offset chimney + a glowing grate.
func _draw_heat_plant(c: LcnVectorCanvas, g: Rect2) -> void:
	var body := Rect2(g.position.x + 2.0, g.position.y + 6.0, g.size.x - 4.0, g.size.y - 8.0)
	_mass(c, body, 30.0, METAL_TOP, METAL_FT, METAL_FB)
	_snow_roof(c, body, 30.0, 0.46, 3, METAL_TOP)

	var roof_y: float = body.end.y - 30.0
	_cylinder(c, body.position.x + body.size.x * 0.38, roof_y + 2.0, body.size.x * 0.30, 5.0, 20.0,
		Color(0.322, 0.365, 0.451), Color(0.239, 0.278, 0.357), Color(0.098, 0.118, 0.169))
	_chimney(c, body.end.x - 9.0, roof_y - 2.0, 30.0, 9.0, 0)

	var face := Rect2(body.position.x + 2.0, roof_y + 3.0, body.size.x - 4.0, 24.0)
	# The grate: the warmest thing in the frame, deliberately.
	var grate := Rect2(face.position.x + face.size.x * 0.16, face.position.y + 6.0, face.size.x * 0.44, 14.0)
	c.fill_glow(grate.get_center(), 26.0, Color(1.0, 0.46, 0.16, 0.50), Color(1.0, 0.46, 0.16, 0.0))
	c.fill_round_rect(grate, 2.0, Color(0.055, 0.055, 0.071))
	for i: int in 4:
		var y: float = grate.position.y + 2.0 + float(i) * (grate.size.y - 4.0) / 3.0
		c.fill_round_rect(Rect2(grate.position.x + 1.6, y, grate.size.x - 3.2, 2.0), 0.8,
			Color(1.0, 0.58 + 0.08 * float(i % 2), 0.22, 0.96))
	c.stroke_rect(grate, OUTLINE, 1.4)
	_windows(c, Rect2(face.position.x + face.size.x * 0.66, face.position.y + 5.0, face.size.x * 0.28, 15.0),
		2, 1, LcnPalette.WARM_CORE, 12)
	_rivets(c, Rect2(body.position.x + 3.0, roof_y + 2.0, body.size.x - 6.0, 22.0), 6, Color(0.055, 0.075, 0.118, 0.7))


## Foundry: long block, twin short stacks, a pour spout throwing orange light.
func _draw_foundry(c: LcnVectorCanvas, g: Rect2) -> void:
	var body := Rect2(g.position.x + 1.0, g.position.y + 8.0, g.size.x - 2.0, g.size.y - 10.0)
	_mass(c, body, 26.0, RUST_TOP.lerp(METAL_TOP, 0.45), RUST_FT.lerp(METAL_FT, 0.4), RUST_FB)
	_snow_roof(c, body, 26.0, 0.40, 21, RUST_TOP.lerp(METAL_TOP, 0.45))
	var roof_y: float = body.end.y - 26.0
	_chimney(c, body.position.x + body.size.x * 0.24, roof_y, 24.0, 8.0, 1)
	_chimney(c, body.position.x + body.size.x * 0.44, roof_y, 17.0, 7.0, 2)

	var spout_x: float = body.end.x - 20.0
	c.fill_polygon(PackedVector2Array([
		Vector2(spout_x - 9.0, roof_y + 5.0),
		Vector2(spout_x + 9.0, roof_y + 5.0),
		Vector2(spout_x + 5.0, roof_y + 15.0),
		Vector2(spout_x - 5.0, roof_y + 15.0),
	]), Color(0.129, 0.106, 0.086))
	c.fill_glow(Vector2(spout_x, roof_y + 17.0), 22.0, Color(1.0, 0.55, 0.14, 0.62), Color(1.0, 0.55, 0.14, 0.0))
	c.fill_polygon(PackedVector2Array([
		Vector2(spout_x - 3.4, roof_y + 13.0),
		Vector2(spout_x + 3.4, roof_y + 13.0),
		Vector2(spout_x + 5.4, roof_y + 23.0),
		Vector2(spout_x - 5.4, roof_y + 23.0),
	]), Color(1.0, 0.74, 0.32, 0.95))
	c.fill_polygon(PackedVector2Array([
		Vector2(spout_x - 1.6, roof_y + 13.0),
		Vector2(spout_x + 1.6, roof_y + 13.0),
		Vector2(spout_x + 2.6, roof_y + 22.0),
		Vector2(spout_x - 2.6, roof_y + 22.0),
	]), Color(1.0, 0.96, 0.84, 0.95))
	_windows(c, Rect2(body.position.x + 4.0, roof_y + 4.0, body.size.x * 0.44, 16.0), 3, 1, LcnPalette.WARM_MID, 5)


## Workshop: sawtooth north-light roof. Nothing else in the set has teeth.
func _draw_workshop(c: LcnVectorCanvas, g: Rect2) -> void:
	var body := Rect2(g.position.x + 2.0, g.position.y + 5.0, g.size.x - 4.0, g.size.y - 7.0)
	_mass(c, body, 20.0, DARK_TOP, METAL_FT, METAL_FB)
	var roof_y: float = body.end.y - 20.0
	var teeth: int = 3
	var tw: float = body.size.x / float(teeth)
	for i: int in teeth:
		var x0: float = body.position.x + tw * float(i)
		var apex := Vector2(x0 + tw * 0.30, roof_y - 15.0)
		c.fill_polygon(PackedVector2Array([
			Vector2(x0, roof_y - 1.0), apex,
			Vector2(x0 + tw, roof_y - 3.0), Vector2(x0 + tw, roof_y + 1.0), Vector2(x0, roof_y + 1.0),
		]), Color(0.212, 0.259, 0.341))
		# Glazed north face, lit from inside.
		c.fill_polygon(PackedVector2Array([
			Vector2(x0 + 0.8, roof_y - 1.5), apex + Vector2(-0.6, 0.6),
			apex + Vector2(1.6, 2.4), Vector2(x0 + 2.6, roof_y + 0.4),
		]), Color(1.0, 0.78, 0.42, 0.55))
		c.stroke_polyline(PackedVector2Array([
			Vector2(x0, roof_y - 1.0), apex, Vector2(x0 + tw, roof_y - 3.0),
		]), OUTLINE, 1.5)
		c.fill_polygon(PackedVector2Array([
			apex + Vector2(-1.0, -1.2), Vector2(x0 + tw, roof_y - 4.0),
			Vector2(x0 + tw, roof_y - 2.2), apex + Vector2(-1.0, 0.4),
		]), Color(0.855, 0.894, 0.945, 0.86))
	c.stroke_rect(Rect2(body.position.x, body.position.y - 20.0, body.size.x, body.size.y + 20.0), OUTLINE, 1.7)
	_windows(c, Rect2(body.position.x + 3.0, roof_y + 3.0, body.size.x - 6.0, 15.0), 3, 1, LcnPalette.WARM_CORE, 8)
	c.fill_round_rect(Rect2(body.position.x + body.size.x * 0.42, roof_y + 5.0, 11.0, 14.0), 1.0, Color(0.075, 0.094, 0.137))
	c.stroke_rect(Rect2(body.position.x + body.size.x * 0.42, roof_y + 5.0, 11.0, 14.0), OUTLINE, 1.2)


## Assembly hall: a low hall under an overhead gantry crane. The bridge standing
## clear of the roof on two rail towers is the only horizontal beam in open air
## anywhere in the set, so the one building that makes finished goods is findable
## across a district without reading a label.
func _draw_assembler(c: LcnVectorCanvas, g: Rect2) -> void:
	var body := Rect2(g.position.x + 2.0, g.position.y + 9.0, g.size.x - 4.0, g.size.y - 11.0)
	var h: float = 22.0
	_mass(c, body, h, DARK_TOP, METAL_FT, METAL_FB)
	var roof_top: float = body.position.y - h
	var roof_bot: float = body.end.y - h

	# The gantry stands on the back rail, so it rises into open sky rather than
	# into its own roof.
	var rail_y: float = roof_top + 5.0
	var beam_y: float = rail_y - 21.0
	for s: int in 2:
		var tx: float = body.position.x + 9.0 if s == 0 else body.end.x - 9.0
		var tower := PackedVector2Array([
			Vector2(tx - 3.2, beam_y), Vector2(tx + 3.2, beam_y),
			Vector2(tx + 5.4, rail_y + 3.0), Vector2(tx - 5.4, rail_y + 3.0),
		])
		c.fill_polygon(tower, Color(0.243, 0.278, 0.353))
		c.stroke_polygon(tower, OUTLINE, 1.4)
		for i: int in 3:
			var f: float = (float(i) + 0.5) / 3.0
			c.stroke_polyline(PackedVector2Array([
				Vector2(tx - lerpf(3.0, 5.0, f), lerpf(beam_y, rail_y, f)),
				Vector2(tx + lerpf(3.0, 5.0, f + 0.3), lerpf(beam_y, rail_y, f + 0.3)),
			]), Color(0.180, 0.212, 0.278), 1.1)
	var beam := Rect2(body.position.x + 3.0, beam_y - 5.0, body.size.x - 6.0, 6.4)
	c.fill_rect_gradient(beam, Color(0.322, 0.361, 0.443), Color(0.153, 0.180, 0.239))
	c.stroke_rect(beam, OUTLINE, 1.5)
	# Trolley parked off centre, hook down: a crane at rest still reads as a crane.
	var trolley: float = lerpf(beam.position.x + 8.0, beam.end.x - 8.0, 0.63)
	c.fill_round_rect(Rect2(trolley - 6.0, beam.end.y - 1.0, 12.0, 7.0), 1.6, Color(0.322, 0.290, 0.216))
	c.stroke_rect(Rect2(trolley - 6.0, beam.end.y - 1.0, 12.0, 7.0), OUTLINE, 1.2)
	c.stroke_polyline(PackedVector2Array([
		Vector2(trolley, beam.end.y + 6.0), Vector2(trolley, beam.end.y + 19.0),
	]), Color(0.196, 0.224, 0.286), 1.5)
	c.fill_polygon(PackedVector2Array([
		Vector2(trolley - 3.4, beam.end.y + 19.0), Vector2(trolley + 3.4, beam.end.y + 19.0),
		Vector2(trolley + 1.8, beam.end.y + 24.0), Vector2(trolley - 1.8, beam.end.y + 24.0),
	]), Color(0.271, 0.310, 0.388))

	# Glazed roof monitor down the front half of the spine: this hall works nights.
	var mon := Rect2(body.position.x + 7.0, lerpf(roof_top, roof_bot, 0.46),
		body.size.x - 14.0, (roof_bot - roof_top) * 0.26)
	c.fill_rect_gradient(mon, Color(0.204, 0.243, 0.318), Color(0.114, 0.141, 0.196))
	c.stroke_rect(mon, OUTLINE, 1.5)
	var glass := Rect2(mon.position.x + 2.4, mon.position.y + 2.4, mon.size.x - 4.8, mon.size.y * 0.44)
	c.fill_glow(glass.get_center(), glass.size.x * 0.5,
		Color(1.0, 0.72, 0.34, 0.40), Color(1.0, 0.72, 0.34, 0.0))
	c.fill_rect_gradient(glass, Color(1.0, 0.82, 0.48, 0.92), Color(0.98, 0.56, 0.24, 0.86))
	var bays: int = 5
	for i2: int in bays - 1:
		var bx: float = lerpf(glass.position.x, glass.end.x, float(i2 + 1) / float(bays))
		c.stroke_polyline(PackedVector2Array([
			Vector2(bx, glass.position.y), Vector2(bx, glass.end.y),
		]), Color(0.063, 0.078, 0.106, 0.85), 1.4)

	_windows(c, Rect2(body.position.x + 5.0, roof_bot + 4.0, body.size.x - 10.0, 13.0),
		4, 1, LcnPalette.WARM_MID, 21)
	# Loading apron: the doors face the front, and they are where the light spills.
	var door := Rect2(body.position.x + body.size.x * 0.36, roof_bot + 6.0, body.size.x * 0.28, 15.0)
	c.fill_glow(Vector2(door.get_center().x, door.end.y + 2.0), door.size.x * 0.9,
		Color(1.0, 0.62, 0.26, 0.34), Color(1.0, 0.62, 0.26, 0.0))
	c.fill_rect_gradient(door, Color(0.086, 0.106, 0.153), Color(0.043, 0.055, 0.086))
	c.stroke_rect(door, OUTLINE, 1.3)


## Survey hall: two low porches, a set-back hall and a domed drum standing clear
## above both. Wide at the ground and narrow at the crown is the exact inverse of
## every boiler house and workshop slab on the plain, and it is the only round
## roof in the city — the first draft of this shape was a full-footprint block
## and overlapped the heat plant's outline by 96%, which is not a building, it is
## the same building painted a different colour.
func _draw_research_hall(c: LcnVectorCanvas, g: Rect2) -> void:
	var cx: float = g.position.x + g.size.x * 0.5
	var porch_w: float = g.size.x * 0.27
	for s: int in 2:
		var px: float = g.position.x + 2.0 if s == 0 else g.end.x - 2.0 - porch_w
		var porch := Rect2(px, g.position.y + g.size.y * 0.56, porch_w, g.size.y * 0.40)
		_mass(c, porch, 10.0, Color(0.180, 0.212, 0.271),
			Color(0.129, 0.157, 0.212), Color(0.055, 0.071, 0.106))
		c.fill_polygon(PackedVector2Array([
			Vector2(porch.position.x - 1.0, porch.position.y - 10.0),
			Vector2(porch.end.x + 1.0, porch.position.y - 10.0),
			Vector2(porch.end.x + 1.0, porch.position.y - 7.6),
			Vector2(porch.position.x - 1.0, porch.position.y - 7.6),
		]), Color(0.878, 0.914, 0.957, 0.86))

	var body := Rect2(g.position.x + g.size.x * 0.16, g.position.y + g.size.y * 0.14,
		g.size.x * 0.68, g.size.y * 0.60)
	var h: float = 21.0
	_mass(c, body, h, Color(0.204, 0.239, 0.306), Color(0.145, 0.176, 0.239),
		Color(0.059, 0.075, 0.114))
	var roof_top: float = body.position.y - h
	var roof_bot: float = body.end.y - h

	# The drum stands on the back of the roof, so the dome clears the roofline
	# instead of sitting in it.
	var drum_base: float = roof_top + 9.0
	var drum_h: float = 17.0
	var rx: float = g.size.x * 0.21
	c.fill_polygon_gradient(PackedVector2Array([
		Vector2(cx - rx, drum_base - drum_h), Vector2(cx + rx, drum_base - drum_h),
		Vector2(cx + rx, drum_base), Vector2(cx - rx, drum_base),
	]), Color(0.231, 0.271, 0.345), Color(0.090, 0.114, 0.169),
		Vector2(cx - rx, 0.0), Vector2(cx + rx, 0.0))
	for i: int in 3:
		var wx: float = lerpf(cx - rx + 4.0, cx + rx - 4.0, (float(i) + 0.5) / 3.0)
		c.fill_round_rect(Rect2(wx - 2.2, drum_base - drum_h + 4.0, 4.4, 8.0), 1.2,
			Color(1.0, 0.84, 0.52, 0.88))
	c.stroke_rect(Rect2(cx - rx, drum_base - drum_h, rx * 2.0, drum_h), OUTLINE, 1.5)

	var dome_y: float = drum_base - drum_h
	var dome := PackedVector2Array()
	for i2: int in 21:
		var a: float = PI * float(i2) / 20.0
		dome.append(Vector2(cx - cos(a) * rx, dome_y - sin(a) * rx * 0.96))
	c.fill_polygon(dome, Color(0.239, 0.282, 0.361))
	# Snow holds on the shoulders of a dome and slides off the crown, which is what
	# stops it reading as a plain grey ball.
	for s2: int in 2:
		var sx: float = -1.0 if s2 == 0 else 1.0
		var cap := PackedVector2Array()
		for i3: int in 6:
			var a2: float = PI * (0.05 + 0.32 * float(i3) / 5.0)
			cap.append(Vector2(cx - sx * cos(a2) * rx, dome_y - sin(a2) * rx * 0.96))
		for i4: int in 6:
			var a3: float = PI * (0.37 - 0.32 * float(i4) / 5.0)
			cap.append(Vector2(cx - sx * cos(a3) * (rx - 3.4), dome_y - 1.8 - sin(a3) * rx * 0.82))
		c.fill_polygon(cap, Color(0.878, 0.914, 0.957, 0.86))
	# The observation slit, lit from inside all night on purpose.
	c.fill_glow(Vector2(cx + rx * 0.24, dome_y - rx * 0.60), rx * 1.2,
		Color(0.66, 0.85, 1.0, 0.32), Color(0.66, 0.85, 1.0, 0.0))
	c.fill_polygon(PackedVector2Array([
		Vector2(cx + rx * 0.06, dome_y),
		Vector2(cx + rx * 0.38, dome_y),
		Vector2(cx + rx * 0.30, dome_y - rx * 0.88),
		Vector2(cx + rx * 0.10, dome_y - rx * 0.90),
	]), Color(1.0, 0.86, 0.56, 0.92))
	c.stroke_polygon(dome, OUTLINE, 1.6)

	# Instrument mast on the crown: thin, with a cross of sensor arms and one cold
	# blue lamp, the only cold light in the catalogue.
	var mast_top: float = dome_y - rx * 0.96 - 15.0
	c.stroke_polyline(PackedVector2Array([
		Vector2(cx, dome_y - rx * 0.90), Vector2(cx, mast_top),
	]), Color(0.247, 0.286, 0.361), 2.4)
	for i5: int in 2:
		var ay: float = lerpf(mast_top + 3.0, dome_y - rx * 0.96 - 2.0, float(i5))
		var aw: float = lerpf(7.0, 4.0, float(i5))
		c.stroke_polyline(PackedVector2Array([
			Vector2(cx - aw, ay), Vector2(cx + aw, ay),
		]), Color(0.220, 0.259, 0.333), 1.5)
	c.fill_circle(Vector2(cx, mast_top - 1.6), 2.0, LcnPalette.ICE_BLUE, 10)
	c.fill_glow(Vector2(cx, mast_top - 1.6), 9.0,
		Color(0.54, 0.75, 0.85, 0.55), Color(0.54, 0.75, 0.85, 0.0))

	# Drawing offices: the whole front face is glass, unlike a workshop.
	_windows(c, Rect2(body.position.x + 4.0, roof_bot + 4.0, body.size.x - 8.0, 14.0),
		3, 1, LcnPalette.WARM_CORE, 44)
	c.fill_glow(Vector2(body.get_center().x, body.end.y - 2.0), body.size.x * 0.7,
		Color(1.0, 0.70, 0.34, 0.20), Color(1.0, 0.70, 0.34, 0.0))


## Habitat: two pitched roofs at different heights, chimney, warm windows.
func _draw_habitat(c: LcnVectorCanvas, g: Rect2) -> void:
	var left := Rect2(g.position.x + 1.0, g.position.y + 10.0, g.size.x * 0.56, g.size.y - 12.0)
	var right := Rect2(g.position.x + g.size.x * 0.50, g.position.y + 16.0, g.size.x * 0.48, g.size.y - 18.0)
	_pitched(c, right, 16.0, 11.0, Color(0.176, 0.216, 0.290), 33)
	_pitched(c, left, 22.0, 15.0, Color(0.204, 0.247, 0.325), 17)
	_chimney(c, left.position.x + left.size.x * 0.72, left.end.y - 37.0, 13.0, 5.5, 3)
	_windows(c, Rect2(left.position.x + 2.0, left.end.y - 20.0, left.size.x - 4.0, 15.0), 2, 1, LcnPalette.WARM_CORE, 4)
	_windows(c, Rect2(right.position.x + 2.0, right.end.y - 15.0, right.size.x - 4.0, 12.0), 2, 1, LcnPalette.WARM_MID, 9)
	# Trodden path of warm light spilling from the door.
	c.fill_glow(Vector2(left.position.x + left.size.x * 0.5, left.end.y + 1.0), 20.0,
		Color(1.0, 0.66, 0.30, 0.30), Color(1.0, 0.66, 0.30, 0.0))


func _pitched(c: LcnVectorCanvas, r: Rect2, wall_h: float, roof_h: float, wall: Color, seed_value: int) -> void:
	var wall_top: float = r.end.y - wall_h
	c.fill_polygon_gradient(PackedVector2Array([
		Vector2(r.position.x, wall_top), Vector2(r.end.x, wall_top),
		Vector2(r.end.x, r.end.y), Vector2(r.position.x, r.end.y),
	]), wall, wall.darkened(0.5), Vector2(0.0, wall_top), Vector2(0.0, r.end.y))
	var ridge := Vector2(r.position.x + r.size.x * 0.5, wall_top - roof_h)
	var roof := PackedVector2Array([
		Vector2(r.position.x - 2.5, wall_top + 1.0),
		Vector2(ridge.x, ridge.y),
		Vector2(r.end.x + 2.5, wall_top + 1.0),
		Vector2(r.end.x + 2.5, wall_top - 2.0),
		Vector2(ridge.x, ridge.y - 3.0),
		Vector2(r.position.x - 2.5, wall_top - 2.0),
	])
	c.fill_polygon(PackedVector2Array([
		Vector2(r.position.x - 2.5, wall_top + 1.0), ridge, Vector2(r.end.x + 2.5, wall_top + 1.0),
	]), Color(0.145, 0.180, 0.247))
	c.fill_polygon(PackedVector2Array([
		Vector2(r.position.x - 2.5, wall_top + 1.0), ridge,
		Vector2(ridge.x, ridge.y + 2.4), Vector2(r.position.x - 1.0, wall_top + 1.0),
	]), Color(0.239, 0.286, 0.373))
	# Snow always lies on the windward pitch.
	var snow_pts := PackedVector2Array()
	snow_pts.append(ridge + Vector2(0.0, -1.0))
	for i: int in 6:
		var f: float = float(i) / 5.0
		var p: Vector2 = ridge.lerp(Vector2(r.position.x - 2.5, wall_top + 1.0), f)
		snow_pts.append(p + Vector2(0.0, -1.2 - LcnNoise.hash3(i, seed_value, 5) * 1.6))
	snow_pts.append(Vector2(r.position.x - 3.4, wall_top + 1.6))
	for i: int in 6:
		var f2: float = 1.0 - float(i) / 5.0
		var p2: Vector2 = ridge.lerp(Vector2(r.position.x - 2.5, wall_top + 1.0), f2)
		snow_pts.append(p2 + Vector2(0.0, 2.2))
	c.fill_polygon(snow_pts, Color(0.898, 0.929, 0.965, 0.92))
	c.stroke_polygon(roof, OUTLINE, 1.6)
	c.stroke_rect(Rect2(r.position.x, wall_top, r.size.x, wall_h), OUTLINE, 1.5)
	c.stroke_polyline(PackedVector2Array([ridge, Vector2(ridge.x, wall_top + 1.0)]), Color(0.043, 0.063, 0.110, 0.35), 1.1)


## Greenhouse: barrel-vault glass arch full of warm interior light.
func _draw_greenhouse(c: LcnVectorCanvas, g: Rect2) -> void:
	var body := Rect2(g.position.x + 2.0, g.position.y + 8.0, g.size.x - 4.0, g.size.y - 10.0)
	_mass(c, body, 8.0, Color(0.176, 0.212, 0.278), Color(0.129, 0.161, 0.220), Color(0.055, 0.071, 0.110))
	var base_y: float = body.end.y - 8.0
	var cx: float = body.position.x + body.size.x * 0.5
	var rx: float = body.size.x * 0.5
	var arch := PackedVector2Array()
	for i: int in 15:
		var a: float = PI * float(i) / 14.0
		arch.append(Vector2(cx - cos(a) * rx, base_y - sin(a) * 22.0))
	arch.append(Vector2(cx + rx, base_y))
	arch.append(Vector2(cx - rx, base_y))
	c.fill_polygon(arch, Color(0.078, 0.098, 0.129))
	c.fill_glow(Vector2(cx, base_y - 8.0), rx * 1.5, Color(1.0, 0.72, 0.36, 0.58), Color(1.0, 0.72, 0.36, 0.0))
	var inner := PackedVector2Array()
	for i: int in 15:
		var a2: float = PI * float(i) / 14.0
		inner.append(Vector2(cx - cos(a2) * (rx - 2.2), base_y - sin(a2) * 19.0))
	inner.append(Vector2(cx + rx - 2.2, base_y - 1.5))
	inner.append(Vector2(cx - rx + 2.2, base_y - 1.5))
	c.fill_polygon_gradient(inner, Color(1.0, 0.80, 0.44, 0.90), Color(0.98, 0.55, 0.24, 0.85),
		Vector2(0.0, base_y - 22.0), Vector2(0.0, base_y))
	for i: int in 5:
		var f: float = (float(i) + 0.5) / 5.0
		var a3: float = PI * f
		c.stroke_polyline(PackedVector2Array([
			Vector2(cx - cos(a3) * rx, base_y - sin(a3) * 22.0),
			Vector2(cx - cos(a3) * (rx * 0.2), base_y),
		]), Color(0.063, 0.078, 0.106, 0.85), 1.5)
	c.stroke_polygon(arch, OUTLINE, 1.7)
	# Snow only clings to the shallow top of the vault.
	c.fill_polygon(PackedVector2Array([
		Vector2(cx - rx * 0.52, base_y - 21.0), Vector2(cx + rx * 0.52, base_y - 21.0),
		Vector2(cx + rx * 0.44, base_y - 23.6), Vector2(cx - rx * 0.44, base_y - 23.6),
	]), Color(0.898, 0.929, 0.965, 0.88))


## Depot: long low shed, three bay doors, cantilever canopy.
## Depot: an OPEN storage yard, not another shed. A low perimeter kerb with
## crate stacks of uneven height inside it, so the outline is a ragged low
## skyline rather than one more roofed block. The critic's frames were full of
## roofed blocks and a player could not tell a warehouse from a boiler house at
## far zoom; this is the one that had to stop being a box.
func _draw_depot(c: LcnVectorCanvas, g: Rect2) -> void:
	var yard := Rect2(g.position.x + 1.0, g.position.y + 4.0, g.size.x - 2.0, g.size.y - 6.0)
	# Hard standing.
	c.fill_rect_gradient(yard, Color(0.145, 0.165, 0.212), Color(0.098, 0.118, 0.157))
	c.stroke_rect(yard, Color(0.055, 0.071, 0.110, 0.85), 1.6)
	for i: int in 4:
		var ly: float = lerpf(yard.position.y + 4.0, yard.end.y - 4.0, (float(i) + 0.5) / 4.0)
		c.stroke_polyline(PackedVector2Array([
			Vector2(yard.position.x + 3.0, ly), Vector2(yard.end.x - 3.0, ly),
		]), Color(0.196, 0.220, 0.271, 0.55), 1.0)

	# Crate stacks. Heights deliberately uneven and staggered in depth, which is
	# what makes the silhouette a skyline instead of a rectangle.
	var cols: int = maxi(3, int(yard.size.x / 22.0))
	for i2: int in cols:
		var f: float = (float(i2) + 0.5) / float(cols)
		var cx: float = lerpf(yard.position.x + 9.0, yard.end.x - 9.0, f)
		var stacks: int = 1 + int(LcnNoise.hash3(i2, 5, 601) * 2.99)
		var base_y: float = lerpf(yard.end.y - 3.0, yard.position.y + 12.0,
			LcnNoise.hash3(i2, 11, 733) * 0.55)
		var cw: float = 8.0 + LcnNoise.hash3(i2, 3, 811) * 4.0
		var top: float = base_y
		for j: int in stacks:
			var ch: float = 9.0 + LcnNoise.hash3(i2, j, 907) * 7.0
			var box := Rect2(cx - cw, top - ch, cw * 2.0, ch)
			var tone: Color = RUST_TOP.lerp(METAL_TOP, LcnNoise.hash3(i2, j, 1013))
			c.fill_rect_gradient(box, tone, tone.darkened(0.34))
			c.stroke_rect(box, OUTLINE, 1.4)
			# Banding straps: reads as cargo even at two pixels tall.
			c.stroke_polyline(PackedVector2Array([
				Vector2(box.position.x, box.get_center().y), Vector2(box.end.x, box.get_center().y),
			]), Color(0.078, 0.090, 0.125, 0.75), 1.2)
			c.fill_polygon(PackedVector2Array([
				Vector2(box.position.x - 0.8, box.position.y),
				Vector2(box.end.x + 0.8, box.position.y),
				Vector2(box.end.x - 0.4, box.position.y - 2.4),
				Vector2(box.position.x + 0.4, box.position.y - 2.4),
			]), Color(0.878, 0.910, 0.957, 0.9))
			top -= ch + 1.0

	# One tall gantry crane on the near edge: the yard's identifying feature.
	var gx: float = yard.position.x + 5.0
	var gy: float = yard.end.y - 2.0
	c.stroke_polyline(PackedVector2Array([Vector2(gx, gy), Vector2(gx, gy - 40.0)]),
		Color(0.243, 0.275, 0.341), 3.2)
	c.stroke_polyline(PackedVector2Array([
		Vector2(gx, gy - 40.0), Vector2(gx + yard.size.x * 0.55, gy - 34.0),
	]), Color(0.290, 0.322, 0.388), 2.8)
	c.stroke_polyline(PackedVector2Array([
		Vector2(gx, gy - 30.0), Vector2(gx + yard.size.x * 0.30, gy - 36.5),
	]), Color(0.196, 0.224, 0.286), 1.8)
	c.stroke_polyline(PackedVector2Array([
		Vector2(gx + yard.size.x * 0.42, gy - 35.5), Vector2(gx + yard.size.x * 0.42, gy - 22.0),
	]), Color(0.180, 0.204, 0.259), 1.6)
	c.fill_round_rect(Rect2(gx + yard.size.x * 0.42 - 3.5, gy - 22.0, 7.0, 5.0), 1.2,
		Color(0.322, 0.290, 0.216))
	c.fill_circle(Vector2(gx, gy - 41.5), 2.0, LcnPalette.CAUTION, 10)


## Mine: A-frame headgear with a winding wheel. Unmistakable diagonal bracing.
func _draw_mine(c: LcnVectorCanvas, g: Rect2) -> void:
	var body := Rect2(g.position.x + 3.0, g.position.y + 14.0, g.size.x - 6.0, g.size.y - 16.0)
	_mass(c, body, 14.0, DARK_TOP, DARK_FT, DARK_FB)
	var base_y: float = body.end.y - 14.0
	var cx: float = body.position.x + body.size.x * 0.5
	var top := Vector2(cx, base_y - 34.0)
	for s: int in 2:
		var sx: float = -1.0 if s == 0 else 1.0
		c.fill_polygon(PackedVector2Array([
			Vector2(cx + sx * 3.0, top.y), Vector2(cx + sx * 5.5, top.y),
			Vector2(cx + sx * (body.size.x * 0.42 + 2.5), base_y),
			Vector2(cx + sx * (body.size.x * 0.42 - 1.0), base_y),
		]), Color(0.239, 0.204, 0.169))
	for i: int in 4:
		var f: float = (float(i) + 0.6) / 4.6
		var y: float = lerpf(top.y, base_y, f)
		var half: float = lerpf(4.0, body.size.x * 0.42, f)
		c.stroke_polyline(PackedVector2Array([Vector2(cx - half, y), Vector2(cx + half, y)]),
			Color(0.212, 0.180, 0.149), 1.8)
		c.stroke_polyline(PackedVector2Array([
			Vector2(cx - half, y), Vector2(cx + lerpf(4.0, body.size.x * 0.42, f - 0.18), y - 6.0),
		]), Color(0.180, 0.153, 0.129), 1.3)
	c.fill_circle(top + Vector2(0.0, 2.0), 7.5, Color(0.263, 0.224, 0.184), 22)
	c.fill_circle(top + Vector2(0.0, 2.0), 5.0, Color(0.129, 0.110, 0.094), 20)
	for i: int in 6:
		var a: float = TAU * float(i) / 6.0
		c.stroke_polyline(PackedVector2Array([
			top + Vector2(0.0, 2.0), top + Vector2(cos(a), sin(a)) * 6.6 + Vector2(0.0, 2.0),
		]), Color(0.302, 0.263, 0.212), 1.2)
	c.stroke_polygon(LcnVectorCanvas.circle_points(top + Vector2(0.0, 2.0), 7.5, 7.5, 22), OUTLINE, 1.5)
	c.fill_glow(Vector2(cx, base_y + 6.0), 16.0, Color(1.0, 0.62, 0.26, 0.26), Color(1.0, 0.62, 0.26, 0.0))
	c.fill_polygon(PackedVector2Array([
		Vector2(cx - 8.0, base_y + 2.0), Vector2(cx + 8.0, base_y + 2.0),
		Vector2(cx + 6.0, base_y + 10.0), Vector2(cx - 6.0, base_y + 10.0),
	]), Color(0.043, 0.047, 0.055))


## Turret: sandbagged octagonal emplacement, armoured mantlet, ammo drum.
## The rotating barrel is a separate sprite so combat can aim it.
func _draw_turret(c: LcnVectorCanvas, g: Rect2) -> void:
	var cx: float = g.position.x + g.size.x * 0.5
	var base_y: float = g.end.y - 2.0
	c.fill_ellipse(Vector2(cx, base_y + 1.0), 17.0, 6.5, Color(0.043, 0.059, 0.098, 0.55))

	# Sandbag ring. Rounded lumps read as "improvised defence" at any zoom.
	for i: int in 9:
		var f: float = float(i) / 8.0
		var x: float = lerpf(cx - 16.0, cx + 16.0, f)
		var y: float = base_y - 3.0 - sin(f * PI) * 1.6
		c.fill_ellipse(Vector2(x, y), 3.2, 2.4, Color(0.239, 0.216, 0.184))
		c.fill_ellipse(Vector2(x - 0.6, y - 0.7), 2.2, 1.4, Color(0.318, 0.290, 0.247))
		c.fill_ellipse(Vector2(x, y - 2.6), 2.6, 1.6, Color(0.816, 0.855, 0.910, 0.72))

	var oct := PackedVector2Array()
	for i: int in 8:
		var a: float = TAU * float(i) / 8.0 + PI / 8.0
		oct.append(Vector2(cx + cos(a) * 13.0, base_y - 14.0 + sin(a) * 5.6))
	c.fill_polygon_gradient(PackedVector2Array([
		Vector2(cx - 12.6, base_y - 14.0), Vector2(cx + 12.6, base_y - 14.0),
		Vector2(cx + 12.0, base_y - 3.0), Vector2(cx - 12.0, base_y - 3.0),
	]), Color(0.204, 0.243, 0.318), Color(0.063, 0.082, 0.125),
		Vector2(0.0, base_y - 14.0), Vector2(0.0, base_y - 3.0))
	# Warning chevrons — reads as "military" instantly.
	for i: int in 5:
		var f2: float = (float(i) + 0.5) / 5.0
		var x2: float = lerpf(cx - 11.0, cx + 11.0, f2)
		c.fill_polygon(PackedVector2Array([
			Vector2(x2 - 2.6, base_y - 12.4), Vector2(x2 + 0.6, base_y - 12.4),
			Vector2(x2 - 1.4, base_y - 5.0), Vector2(x2 - 4.6, base_y - 5.0),
		]), LcnPalette.CAUTION * Color(1, 1, 1, 0.62))
	c.fill_polygon(oct, Color(0.267, 0.310, 0.396))
	c.fill_polygon(LcnVectorCanvas.scale_points(oct, Vector2(cx, base_y - 14.0), Vector2(0.72, 0.72)),
		Color(0.180, 0.216, 0.286))
	c.stroke_polygon(oct, OUTLINE, 1.6)

	# Mantlet + gun cradle, drawn slightly right of centre so the barrel sprite
	# sits naturally on top of it at rest.
	c.fill_round_rect(Rect2(cx - 8.0, base_y - 26.0, 16.0, 12.0), 2.4, Color(0.290, 0.333, 0.416))
	c.fill_round_rect(Rect2(cx - 8.0, base_y - 26.0, 6.0, 12.0), 2.0, Color(0.376, 0.416, 0.494))
	c.stroke_rect(Rect2(cx - 8.0, base_y - 26.0, 16.0, 12.0), OUTLINE, 1.5)
	c.fill_polygon(PackedVector2Array([
		Vector2(cx - 8.4, base_y - 26.4), Vector2(cx + 8.4, base_y - 26.4),
		Vector2(cx + 7.0, base_y - 28.8), Vector2(cx - 7.0, base_y - 28.8),
	]), Color(0.878, 0.914, 0.957, 0.85))

	# Ammo drum on the left flank.
	_cylinder(c, cx - 15.0, base_y - 6.0, 5.0, 2.2, 9.0,
		Color(0.404, 0.298, 0.196), Color(0.294, 0.216, 0.145), Color(0.129, 0.094, 0.063))
	c.fill_round_rect(Rect2(cx - 18.0, base_y - 12.6, 6.0, 1.6), 0.7, LcnPalette.CAUTION * Color(1, 1, 1, 0.8))
	# Ready light.
	c.fill_glow(Vector2(cx + 9.0, base_y - 27.0), 7.0, Color(1.0, 0.30, 0.22, 0.80), Color(1.0, 0.30, 0.22, 0.0))
	c.fill_circle(Vector2(cx + 9.0, base_y - 27.0), 1.8, Color(1.0, 0.52, 0.42), 10)


func _bake_barrel() -> Image:
	var c := LcnVectorCanvas.new(34, 18, SS)
	c.fill_polygon(PackedVector2Array([
		Vector2(4.0, 5.5), Vector2(26.0, 6.6), Vector2(26.0, 11.4), Vector2(4.0, 12.5),
	]), Color(0.243, 0.286, 0.365))
	c.fill_polygon(PackedVector2Array([
		Vector2(4.0, 5.5), Vector2(26.0, 6.6), Vector2(26.0, 8.2), Vector2(4.0, 7.6),
	]), Color(0.353, 0.396, 0.478))
	c.fill_round_rect(Rect2(25.0, 5.4, 6.0, 7.2), 1.4, Color(0.176, 0.216, 0.286))
	c.fill_round_rect(Rect2(8.0, 3.0, 8.0, 4.0), 1.2, Color(0.196, 0.235, 0.310))
	c.stroke_polygon(PackedVector2Array([
		Vector2(4.0, 5.0), Vector2(31.0, 5.4), Vector2(31.0, 12.6), Vector2(4.0, 13.0),
	]), OUTLINE, 1.5)
	c.fill_circle(Vector2(8.0, 9.0), 4.2, Color(0.286, 0.329, 0.412), 16)
	c.stroke_polygon(LcnVectorCanvas.circle_points(Vector2(8.0, 9.0), 4.2, 4.2, 16), OUTLINE, 1.3)
	return c.to_image()


## Pylon: thin lattice mast. The only tall-and-skinny silhouette in the set.
func _draw_pylon(c: LcnVectorCanvas, g: Rect2) -> void:
	var cx: float = g.position.x + g.size.x * 0.5
	var base_y: float = g.end.y - 5.0
	var top_y: float = base_y - 62.0
	c.fill_ellipse(Vector2(cx, base_y + 1.0), 11.0, 4.5, Color(0.043, 0.059, 0.098, 0.45))
	c.fill_polygon(PackedVector2Array([
		Vector2(cx - 9.0, base_y), Vector2(cx + 9.0, base_y),
		Vector2(cx + 7.0, base_y - 5.0), Vector2(cx - 7.0, base_y - 5.0),
	]), Color(0.161, 0.192, 0.251))
	var legs: Array[PackedVector2Array] = []
	for s: int in 2:
		var sx: float = -1.0 if s == 0 else 1.0
		var pts := PackedVector2Array([
			Vector2(cx + sx * 2.0, top_y), Vector2(cx + sx * 3.4, top_y),
			Vector2(cx + sx * 8.5, base_y - 3.0), Vector2(cx + sx * 6.2, base_y - 3.0),
		])
		legs.append(pts)
		c.fill_polygon(pts, Color(0.243, 0.278, 0.353))
	for i: int in 7:
		var f: float = float(i) / 6.0
		var y: float = lerpf(top_y + 3.0, base_y - 4.0, f)
		var half: float = lerpf(2.6, 7.4, f)
		var f2: float = float(i + 1) / 6.0
		var y2: float = lerpf(top_y + 3.0, base_y - 4.0, f2)
		var half2: float = lerpf(2.6, 7.4, f2)
		c.stroke_polyline(PackedVector2Array([Vector2(cx - half, y), Vector2(cx + half, y)]),
			Color(0.212, 0.247, 0.318), 1.3)
		c.stroke_polyline(PackedVector2Array([Vector2(cx - half, y), Vector2(cx + half2, y2)]),
			Color(0.192, 0.224, 0.290), 1.1)
		c.stroke_polyline(PackedVector2Array([Vector2(cx + half, y), Vector2(cx - half2, y2)]),
			Color(0.192, 0.224, 0.290), 1.1)
	for pts2: PackedVector2Array in legs:
		c.stroke_polygon(pts2, OUTLINE, 1.3)
	c.fill_polygon(PackedVector2Array([
		Vector2(cx - 12.0, top_y + 2.0), Vector2(cx + 12.0, top_y + 2.0),
		Vector2(cx + 11.0, top_y + 4.4), Vector2(cx - 11.0, top_y + 4.4),
	]), Color(0.267, 0.302, 0.376))
	c.stroke_rect(Rect2(cx - 12.0, top_y + 2.0, 24.0, 2.4), OUTLINE, 1.2)
	for s2: int in 2:
		var sx2: float = -1.0 if s2 == 0 else 1.0
		c.fill_circle(Vector2(cx + sx2 * 10.0, top_y + 6.4), 2.0, Color(0.518, 0.573, 0.667), 10)
	c.fill_glow(Vector2(cx, top_y - 1.0), 9.0, Color(1.0, 0.42, 0.26, 0.70), Color(1.0, 0.42, 0.26, 0.0))
	c.fill_circle(Vector2(cx, top_y - 1.0), 2.4, Color(1.0, 0.60, 0.36), 12)
	c.fill_polygon(PackedVector2Array([
		Vector2(cx - 12.0, top_y + 1.0), Vector2(cx + 12.0, top_y + 1.0),
		Vector2(cx + 10.0, top_y - 0.6), Vector2(cx - 10.0, top_y - 0.6),
	]), Color(0.878, 0.914, 0.957, 0.75))


## Watchtower: stubby mast with a dish. Reads as "sensor", never as "gun".
func _draw_watchtower(c: LcnVectorCanvas, g: Rect2) -> void:
	var cx: float = g.position.x + g.size.x * 0.5
	var base_y: float = g.end.y - 4.0
	var body := Rect2(cx - 9.0, base_y - 14.0, 18.0, 14.0)
	_mass(c, body, 24.0, METAL_TOP, METAL_FT, METAL_FB)
	var head_y: float = base_y - 40.0
	c.fill_polygon(PackedVector2Array([
		Vector2(cx - 11.0, head_y), Vector2(cx + 11.0, head_y),
		Vector2(cx + 8.5, head_y + 9.0), Vector2(cx - 8.5, head_y + 9.0),
	]), Color(0.263, 0.310, 0.396))
	c.stroke_polygon(PackedVector2Array([
		Vector2(cx - 11.0, head_y), Vector2(cx + 11.0, head_y),
		Vector2(cx + 8.5, head_y + 9.0), Vector2(cx - 8.5, head_y + 9.0),
	]), OUTLINE, 1.5)
	c.fill_round_rect(Rect2(cx - 8.0, head_y + 2.0, 16.0, 4.4), 1.2, Color(0.98, 0.72, 0.36, 0.9))
	c.fill_glow(Vector2(cx, head_y + 4.2), 16.0, Color(1.0, 0.68, 0.32, 0.34), Color(1.0, 0.68, 0.32, 0.0))
	# Dish.
	c.fill_polygon(PackedVector2Array([
		Vector2(cx + 2.0, head_y - 12.0), Vector2(cx + 12.0, head_y - 8.0),
		Vector2(cx + 10.0, head_y - 1.0), Vector2(cx + 1.0, head_y - 3.0),
	]), Color(0.310, 0.353, 0.435))
	c.stroke_polygon(PackedVector2Array([
		Vector2(cx + 2.0, head_y - 12.0), Vector2(cx + 12.0, head_y - 8.0),
		Vector2(cx + 10.0, head_y - 1.0), Vector2(cx + 1.0, head_y - 3.0),
	]), OUTLINE, 1.4)
	c.stroke_polyline(PackedVector2Array([Vector2(cx, head_y - 2.0), Vector2(cx + 6.0, head_y - 6.0)]),
		Color(0.176, 0.212, 0.278), 1.6)
	c.stroke_polyline(PackedVector2Array([Vector2(cx, head_y), Vector2(cx, head_y - 18.0)]),
		Color(0.212, 0.251, 0.322), 1.5)
	c.fill_circle(Vector2(cx, head_y - 19.0), 1.9, LcnPalette.DANGER, 10)
	c.fill_glow(Vector2(cx, head_y - 19.0), 7.0, Color(0.95, 0.28, 0.22, 0.55), Color(0.95, 0.28, 0.22, 0.0))


func _draw_wall(c: LcnVectorCanvas, g: Rect2) -> void:
	var body := Rect2(g.position.x, g.position.y + 6.0, g.size.x, g.size.y - 6.0)
	_mass(c, body, 11.0, Color(0.204, 0.235, 0.298), Color(0.145, 0.169, 0.224), Color(0.063, 0.078, 0.110))
	for i: int in 3:
		var y: float = body.end.y - 11.0 + 2.6 + float(i) * 3.0
		c.stroke_polyline(PackedVector2Array([
			Vector2(body.position.x + 1.0, y), Vector2(body.end.x - 1.0, y),
		]), Color(0.055, 0.071, 0.106, 0.55), 1.0)
	c.fill_polygon(PackedVector2Array([
		Vector2(body.position.x, body.position.y - 11.0),
		Vector2(body.end.x, body.position.y - 11.0),
		Vector2(body.end.x, body.position.y - 8.6),
		Vector2(body.position.x, body.position.y - 8.6),
	]), Color(0.878, 0.914, 0.957, 0.88))


func _draw_pipe(c: LcnVectorCanvas, g: Rect2) -> void:
	var cy: float = g.position.y + g.size.y * 0.5
	c.fill_round_rect(Rect2(g.position.x - 1.0, cy - 7.0, g.size.x + 2.0, 12.0), 4.0, Color(0.129, 0.157, 0.212))
	c.fill_round_rect(Rect2(g.position.x - 1.0, cy - 6.0, g.size.x + 2.0, 6.0), 3.0, Color(0.239, 0.286, 0.365))
	c.fill_round_rect(Rect2(g.position.x - 1.0, cy - 5.4, g.size.x + 2.0, 2.2), 1.1, Color(0.376, 0.427, 0.514))
	for i: int in 2:
		var x: float = g.position.x + g.size.x * (0.22 + 0.56 * float(i))
		c.fill_round_rect(Rect2(x - 2.0, cy - 8.0, 4.0, 14.0), 1.4, Color(0.192, 0.231, 0.302))
		c.stroke_rect(Rect2(x - 2.0, cy - 8.0, 4.0, 14.0), OUTLINE, 1.1)
	c.fill_glow(Vector2(g.position.x + g.size.x * 0.5, cy - 2.0), 13.0,
		Color(1.0, 0.55, 0.22, 0.30), Color(1.0, 0.55, 0.22, 0.0))
	c.stroke_polyline(PackedVector2Array([
		Vector2(g.position.x + 3.0, cy - 2.5), Vector2(g.end.x - 3.0, cy - 2.5),
	]), Color(1.0, 0.66, 0.30, 0.55), 1.4)


func _draw_belt(c: LcnVectorCanvas, g: Rect2) -> void:
	var cy: float = g.position.y + g.size.y * 0.5
	c.fill_round_rect(Rect2(g.position.x - 1.0, cy - 9.0, g.size.x + 2.0, 17.0), 2.0, Color(0.114, 0.137, 0.184))
	c.fill_rect(Rect2(g.position.x - 1.0, cy - 7.0, g.size.x + 2.0, 13.0), Color(0.176, 0.212, 0.271))
	for i: int in 4:
		var x: float = g.position.x + float(i) * (g.size.x / 4.0) + 2.0
		c.fill_polygon(PackedVector2Array([
			Vector2(x, cy - 6.0), Vector2(x + 4.0, cy - 0.5),
			Vector2(x, cy + 5.0), Vector2(x - 1.6, cy + 5.0),
			Vector2(x + 2.2, cy - 0.5), Vector2(x - 1.6, cy - 6.0),
		]), Color(0.318, 0.361, 0.435))
	c.stroke_polyline(PackedVector2Array([
		Vector2(g.position.x - 1.0, cy - 7.0), Vector2(g.end.x + 1.0, cy - 7.0),
	]), Color(0.043, 0.059, 0.098, 0.8), 1.4)
	c.stroke_polyline(PackedVector2Array([
		Vector2(g.position.x - 1.0, cy + 6.0), Vector2(g.end.x + 1.0, cy + 6.0),
	]), Color(0.043, 0.059, 0.098, 0.8), 1.4)


## One lane of belt deck with cleats, shared by the belt and the splitter so a
## junction is visibly made of the same line it interrupts.
func _lane(c: LcnVectorCanvas, g: Rect2, cy: float) -> void:
	c.fill_round_rect(Rect2(g.position.x - 1.0, cy - 8.0, g.size.x + 2.0, 15.0), 2.0,
		Color(0.114, 0.137, 0.184))
	c.fill_rect(Rect2(g.position.x - 1.0, cy - 6.0, g.size.x + 2.0, 11.0), Color(0.176, 0.212, 0.271))
	for i: int in 3:
		var x: float = g.position.x + 2.0 + float(i) * (g.size.x / 3.0)
		c.fill_polygon(PackedVector2Array([
			Vector2(x, cy - 5.0), Vector2(x + 3.4, cy - 0.5),
			Vector2(x, cy + 4.0), Vector2(x - 1.4, cy + 4.0),
			Vector2(x + 1.9, cy - 0.5), Vector2(x - 1.4, cy - 5.0),
		]), Color(0.318, 0.361, 0.435))
	c.stroke_polyline(PackedVector2Array([
		Vector2(g.position.x - 1.0, cy - 6.0), Vector2(g.end.x + 1.0, cy - 6.0),
	]), Color(0.043, 0.059, 0.098, 0.8), 1.3)
	c.stroke_polyline(PackedVector2Array([
		Vector2(g.position.x - 1.0, cy + 5.0), Vector2(g.end.x + 1.0, cy + 5.0),
	]), Color(0.043, 0.059, 0.098, 0.8), 1.3)


## Splitter: two lanes with the cross-over chute between them and one paddle
## housing bridging both. The housing is the only part of the belt family that
## stands proud of the deck, so a junction is findable along a run of belt
## instead of being three tiles that look exactly like the thirty around them.
func _draw_splitter(c: LcnVectorCanvas, g: Rect2) -> void:
	var cx: float = g.position.x + g.size.x * 0.5
	var lane_a: float = g.position.y + g.size.y * 0.24
	var lane_b: float = g.position.y + g.size.y * 0.76

	# Chute first: both lanes then sit on top of it, which is the right read.
	c.fill_polygon(PackedVector2Array([
		Vector2(g.position.x + 3.0, lane_a - 3.5),
		Vector2(g.end.x - 3.0, lane_b - 3.5),
		Vector2(g.end.x - 3.0, lane_b + 3.5),
		Vector2(g.position.x + 3.0, lane_a + 3.5),
	]), Color(0.129, 0.157, 0.212))
	_lane(c, g, lane_a)
	_lane(c, g, lane_b)

	var hw: float = 7.5
	var y0: float = lane_a - 7.0
	var y1: float = lane_b + 7.0
	var hh: float = 24.0
	c.fill_polygon_gradient(PackedVector2Array([
		Vector2(cx - hw, y1 - hh), Vector2(cx + hw, y1 - hh),
		Vector2(cx + hw, y1), Vector2(cx - hw, y1),
	]), METAL_FT, METAL_FB, Vector2(0.0, y1 - hh), Vector2(0.0, y1))
	c.fill_rect_gradient(Rect2(cx - hw, y0 - hh, hw * 2.0, y1 - y0),
		METAL_TOP, METAL_TOP.darkened(0.30))
	# The paddle itself, laid diagonally across the housing lid: the machine's
	# whole function drawn as one line.
	c.stroke_polyline(PackedVector2Array([
		Vector2(cx - hw + 2.0, y0 - hh + 5.0), Vector2(cx + hw - 2.0, y1 - hh - 5.0),
	]), Color(0.427, 0.478, 0.573), 2.6)
	c.stroke_polyline(PackedVector2Array([
		Vector2(cx - hw + 2.0, y0 - hh + 7.4), Vector2(cx + hw - 2.0, y1 - hh - 2.6),
	]), Color(SEAM.r, SEAM.g, SEAM.b, 0.60), 1.4)
	c.stroke_rect(Rect2(cx - hw, y0 - hh, hw * 2.0, y1 - y0 + hh), OUTLINE, 1.6)
	c.fill_polygon(PackedVector2Array([
		Vector2(cx - hw - 1.0, y0 - hh - 2.4), Vector2(cx + hw + 1.0, y0 - hh - 2.4),
		Vector2(cx + hw + 1.0, y0 - hh + 0.8), Vector2(cx - hw - 1.0, y0 - hh + 0.8),
	]), Color(0.878, 0.914, 0.957, 0.85))
	for s: int in 2:
		var ly: float = lerpf(y1 - hh + 4.0, y1 - 4.0, float(s))
		c.fill_circle(Vector2(cx, ly), 1.6, LcnPalette.CAUTION, 8)
		c.fill_glow(Vector2(cx, ly), 6.0, Color(0.95, 0.73, 0.24, 0.40), Color(0.95, 0.73, 0.24, 0.0))


## Underground belt: a hooded mouth over one half of the tile and an open black
## throat over the other. A straight belt is the same all the way across; this
## one is deliberately not, which is the whole silhouette.
func _draw_underground(c: LcnVectorCanvas, g: Rect2) -> void:
	var cy: float = g.position.y + g.size.y * 0.5
	_lane(c, g, cy)

	var mouth_x: float = g.position.x + g.size.x * 0.42
	c.fill_polygon(PackedVector2Array([
		Vector2(mouth_x, cy - 6.0), Vector2(g.end.x + 1.0, cy - 4.6),
		Vector2(g.end.x + 1.0, cy + 3.6), Vector2(mouth_x, cy + 5.0),
	]), Color(0.020, 0.027, 0.047))
	# Chevrons diving into the hole, fading as they go: direction, then depth.
	for i: int in 2:
		var x: float = mouth_x + 3.0 + float(i) * 6.0
		c.stroke_polyline(PackedVector2Array([
			Vector2(x, cy - 3.6), Vector2(x + 3.4, cy - 0.5), Vector2(x, cy + 2.8),
		]), Color(0.98, 0.72, 0.36, 0.50 - 0.22 * float(i)), 1.4)

	var hood := Rect2(g.position.x + 1.0, cy - 9.0, g.size.x * 0.44, 15.0)
	_mass(c, hood, 15.0, METAL_TOP, METAL_FT, METAL_FB)
	# Visor sloping off the hood into the throat — the overhang that makes the
	# outline asymmetric even when the tile is four pixels wide.
	var visor := PackedVector2Array([
		Vector2(hood.end.x, hood.position.y - 15.0),
		Vector2(hood.end.x + 8.0, hood.position.y - 6.0),
		Vector2(hood.end.x + 8.0, hood.position.y - 1.0),
		Vector2(hood.end.x, hood.position.y - 8.0),
	])
	c.fill_polygon(visor, Color(0.239, 0.282, 0.361))
	c.stroke_polygon(visor, OUTLINE, 1.4)
	c.fill_polygon(PackedVector2Array([
		Vector2(hood.position.x - 1.0, hood.position.y - 15.0),
		Vector2(hood.end.x + 1.0, hood.position.y - 15.0),
		Vector2(hood.end.x + 1.0, hood.position.y - 12.4),
		Vector2(hood.position.x - 1.0, hood.position.y - 12.4),
	]), Color(0.878, 0.914, 0.957, 0.88))


## Inserter: pedestal, column and one jointed arm holding a part over the lane.
## Short reach and a bent elbow — that is what separates it at a glance from the
## long arm working the same belt two tiles away.
func _draw_arm(c: LcnVectorCanvas, g: Rect2) -> void:
	var cx: float = g.position.x + g.size.x * 0.42
	var base_y: float = g.end.y - 5.0
	c.fill_ellipse(Vector2(cx, base_y + 1.0), 9.0, 3.6, Color(0.043, 0.059, 0.098, 0.45))
	var plinth := PackedVector2Array([
		Vector2(cx - 6.0, base_y - 8.0), Vector2(cx + 6.0, base_y - 8.0),
		Vector2(cx + 7.6, base_y), Vector2(cx - 7.6, base_y),
	])
	c.fill_polygon_gradient(plinth, METAL_FT, METAL_FB,
		Vector2(0.0, base_y - 8.0), Vector2(0.0, base_y))
	c.stroke_polygon(plinth, OUTLINE, 1.4)
	c.fill_ellipse(Vector2(cx, base_y - 8.0), 6.0, 2.4, METAL_TOP)

	var top_y: float = base_y - 27.0
	var column := PackedVector2Array([
		Vector2(cx - 3.0, top_y), Vector2(cx + 3.0, top_y),
		Vector2(cx + 4.0, base_y - 8.0), Vector2(cx - 4.0, base_y - 8.0),
	])
	c.fill_polygon(column, Color(0.267, 0.306, 0.384))
	c.stroke_polygon(column, OUTLINE, 1.3)

	var elbow := Vector2(cx + 10.0, top_y - 6.0)
	var hand := Vector2(cx + 14.0, top_y + 7.0)
	c.stroke_polyline(PackedVector2Array([Vector2(cx, top_y), elbow]),
		Color(0.322, 0.361, 0.443), 4.6)
	c.stroke_polyline(PackedVector2Array([elbow, hand]), Color(0.263, 0.302, 0.380), 3.6)
	c.fill_circle(Vector2(cx, top_y), 3.4, Color(0.353, 0.396, 0.482), 12)
	c.fill_circle(elbow, 2.6, Color(0.353, 0.396, 0.482), 12)
	# The part in the claw. An inserter doing nothing is indistinguishable from a
	# post, and this machine is never doing nothing for long.
	c.fill_glow(hand + Vector2(0.0, 2.0), 9.0,
		Color(1.0, 0.66, 0.30, 0.42), Color(1.0, 0.66, 0.30, 0.0))
	c.fill_round_rect(Rect2(hand.x - 2.8, hand.y + 0.6, 5.6, 4.6), 1.0, LcnPalette.WARM_MID)
	c.stroke_polyline(PackedVector2Array([
		hand + Vector2(-3.2, -1.4), hand, hand + Vector2(3.2, -1.4),
	]), Color(0.310, 0.349, 0.427), 1.6)
	c.fill_circle(Vector2(cx - 4.4, base_y - 10.4), 1.4, LcnPalette.CAUTION, 8)


## Long arm: the same pedestal carrying a level lattice boom with a counterweight
## on the tail. It overhangs its own tile at both ends, which nothing else a
## single tile wide does, so "this one reaches further" is readable as shape.
func _draw_long_arm(c: LcnVectorCanvas, g: Rect2) -> void:
	var cx: float = g.position.x + g.size.x * 0.44
	var base_y: float = g.end.y - 5.0
	c.fill_ellipse(Vector2(cx, base_y + 1.0), 10.0, 4.0, Color(0.043, 0.059, 0.098, 0.45))
	for s: int in 2:
		var sx: float = -1.0 if s == 0 else 1.0
		c.fill_polygon(PackedVector2Array([
			Vector2(cx + sx * 3.0, base_y - 12.0), Vector2(cx + sx * 5.0, base_y - 12.0),
			Vector2(cx + sx * 10.0, base_y), Vector2(cx + sx * 7.0, base_y),
		]), Color(0.212, 0.251, 0.322))
	var plinth := PackedVector2Array([
		Vector2(cx - 6.4, base_y - 10.0), Vector2(cx + 6.4, base_y - 10.0),
		Vector2(cx + 8.0, base_y), Vector2(cx - 8.0, base_y),
	])
	c.fill_polygon_gradient(plinth, METAL_FT, METAL_FB,
		Vector2(0.0, base_y - 10.0), Vector2(0.0, base_y))
	c.stroke_polygon(plinth, OUTLINE, 1.4)

	var pivot := Vector2(cx, base_y - 32.0)
	var column := PackedVector2Array([
		Vector2(pivot.x - 3.2, pivot.y), Vector2(pivot.x + 3.2, pivot.y),
		Vector2(cx + 4.4, base_y - 10.0), Vector2(cx - 4.4, base_y - 10.0),
	])
	c.fill_polygon(column, Color(0.267, 0.306, 0.384))
	c.stroke_polygon(column, OUTLINE, 1.3)

	var tip := Vector2(g.end.x + 7.0, pivot.y + 3.0)
	var tail := Vector2(g.position.x - 5.0, pivot.y - 2.0)
	c.stroke_polyline(PackedVector2Array([tail, tip]), Color(0.322, 0.361, 0.443), 3.4)
	c.stroke_polyline(PackedVector2Array([
		tail + Vector2(0.0, 4.6), tip + Vector2(0.0, 4.6),
	]), Color(0.216, 0.251, 0.322), 2.2)
	for i: int in 5:
		var f: float = float(i) / 4.0
		var f2: float = float(i + 1) / 4.0
		c.stroke_polyline(PackedVector2Array([
			tail.lerp(tip, f), tail.lerp(tip, f2) + Vector2(0.0, 4.6),
		]), Color(0.196, 0.231, 0.298), 1.2)
	# Counterweight on the tail: the visual answer to "why is it not falling over".
	c.fill_rect_gradient(Rect2(tail.x - 1.0, tail.y - 1.0, 8.0, 9.0),
		Color(0.290, 0.263, 0.204), Color(0.145, 0.129, 0.098))
	c.stroke_rect(Rect2(tail.x - 1.0, tail.y - 1.0, 8.0, 9.0), OUTLINE, 1.3)
	c.fill_circle(pivot, 3.6, Color(0.353, 0.396, 0.482), 12)
	c.stroke_polyline(PackedVector2Array([
		tip + Vector2(-3.4, 5.0), tip + Vector2(0.0, 8.2), tip + Vector2(3.0, 5.0),
	]), Color(0.310, 0.349, 0.427), 1.6)
	c.fill_glow(tip + Vector2(0.0, 8.0), 9.0,
		Color(1.0, 0.66, 0.30, 0.40), Color(1.0, 0.66, 0.30, 0.0))
	c.fill_round_rect(Rect2(tip.x - 2.8, tip.y + 6.4, 5.6, 4.6), 1.0, LcnPalette.WARM_MID)


## Container: a banded box under an overhanging lid. The lid is the point — it is
## the smallest thing in the game with a real roof, so a chest at the end of a
## belt reads as storage rather than as another block of wall.
func _draw_crate(c: LcnVectorCanvas, g: Rect2) -> void:
	var box := Rect2(g.position.x + 5.0, g.position.y + 7.0, g.size.x - 10.0, g.size.y - 12.0)
	var h: float = 18.0
	_mass(c, box, h, RUST_TOP.lerp(METAL_TOP, 0.30), RUST_FT, RUST_FB)
	var front_y: float = box.end.y - h

	var lid := Rect2(box.position.x - 3.2, box.position.y - h - 4.6, box.size.x + 6.4, 5.4)
	c.fill_rect_gradient(lid, Color(0.310, 0.271, 0.208), Color(0.161, 0.141, 0.110))
	c.stroke_rect(lid, OUTLINE, 1.4)
	c.fill_polygon(PackedVector2Array([
		Vector2(lid.position.x + 0.8, lid.position.y - 2.0),
		Vector2(lid.end.x - 0.8, lid.position.y - 2.0),
		Vector2(lid.end.x - 0.8, lid.position.y + 0.4),
		Vector2(lid.position.x + 0.8, lid.position.y + 0.4),
	]), Color(0.878, 0.914, 0.957, 0.88))

	# Corner straps and a cross brace: cargo, at two pixels tall.
	for s: int in 2:
		var bx: float = box.position.x + 1.6 if s == 0 else box.end.x - 1.6
		c.stroke_polyline(PackedVector2Array([
			Vector2(bx, front_y), Vector2(bx, box.end.y),
		]), Color(0.078, 0.090, 0.125, 0.85), 1.6)
	c.stroke_polyline(PackedVector2Array([
		Vector2(box.position.x + 2.0, box.end.y - 2.0), Vector2(box.end.x - 2.0, front_y + 2.0),
	]), Color(0.098, 0.110, 0.145, 0.70), 1.4)
	c.stroke_polyline(PackedVector2Array([
		Vector2(box.position.x + 1.0, front_y + h * 0.52), Vector2(box.end.x - 1.0, front_y + h * 0.52),
	]), Color(0.078, 0.090, 0.125, 0.75), 1.5)
	# One lamp, so a full container is findable in the dark at the end of a line.
	c.fill_circle(Vector2(box.get_center().x, front_y + 3.4), 1.5, LcnPalette.GOOD, 8)
	c.fill_glow(Vector2(box.get_center().x, front_y + 3.4), 7.0,
		Color(0.37, 0.78, 0.60, 0.42), Color(0.37, 0.78, 0.60, 0.0))


## Cleared, gritted road surface. Flat by design: roads must never occlude.
func _draw_road(c: LcnVectorCanvas, g: Rect2) -> void:
	c.fill_rect_gradient(g, Color(0.243, 0.271, 0.325), Color(0.176, 0.200, 0.247))
	for i: int in 26:
		var x: float = g.position.x + LcnNoise.hash3(i, 3, 71) * g.size.x
		var y: float = g.position.y + LcnNoise.hash3(i, 9, 17) * g.size.y
		c.fill_circle(Vector2(x, y), 0.7 + LcnNoise.hash3(i, 5, 41) * 1.5,
			Color(0.098, 0.106, 0.129, 0.75), 6)
	c.fill_polygon(PackedVector2Array([
		g.position, Vector2(g.end.x, g.position.y),
		Vector2(g.end.x, g.position.y + 2.2), Vector2(g.position.x, g.position.y + 2.2),
	]), Color(0.573, 0.624, 0.706, 0.45))
	c.stroke_rect(g, Color(0.086, 0.098, 0.129, 0.55), 1.2)


func _draw_ruin(c: LcnVectorCanvas, g: Rect2) -> void:
	var cx: float = g.position.x + g.size.x * 0.5
	var base_y: float = g.end.y - 4.0
	c.fill_ellipse(Vector2(cx, base_y), 13.0, 5.0, Color(0.043, 0.059, 0.098, 0.42))
	for i: int in 5:
		var h: float = 4.0 + LcnNoise.hash3(i, 3, 91) * 9.0
		var w: float = 4.0 + LcnNoise.hash3(i, 9, 17) * 6.0
		var x: float = cx + (LcnNoise.hash3(i, 21, 5) - 0.5) * 22.0
		var r := Rect2(x - w * 0.5, base_y - h, w, h)
		c.fill_polygon_gradient(PackedVector2Array([
			Vector2(r.position.x + 0.6, r.position.y), Vector2(r.end.x, r.position.y + 1.2),
			Vector2(r.end.x - 0.4, r.end.y), Vector2(r.position.x, r.end.y),
		]), Color(0.204, 0.212, 0.224), Color(0.075, 0.078, 0.086), r.position, Vector2(0.0, r.end.y))
		c.stroke_polygon(PackedVector2Array([
			Vector2(r.position.x + 0.6, r.position.y), Vector2(r.end.x, r.position.y + 1.2),
			Vector2(r.end.x - 0.4, r.end.y), Vector2(r.position.x, r.end.y),
		]), OUTLINE, 1.2)
		c.fill_polygon(PackedVector2Array([
			Vector2(r.position.x + 0.4, r.position.y), Vector2(r.end.x, r.position.y + 1.2),
			Vector2(r.end.x, r.position.y - 0.6), Vector2(r.position.x + 0.4, r.position.y - 1.8),
		]), Color(0.855, 0.894, 0.945, 0.82))


func _draw_dead_tree(c: LcnVectorCanvas, g: Rect2) -> void:
	var cx: float = g.position.x + g.size.x * 0.5
	var base_y: float = g.end.y - 3.0
	c.fill_ellipse(Vector2(cx, base_y), 8.0, 3.4, Color(0.043, 0.059, 0.098, 0.40))
	c.fill_polygon(PackedVector2Array([
		Vector2(cx - 4.8, base_y), Vector2(cx + 4.8, base_y),
		Vector2(cx + 2.4, base_y - 34.0), Vector2(cx - 2.2, base_y - 34.0),
	]), Color(0.129, 0.118, 0.110))
	c.fill_polygon(PackedVector2Array([
		Vector2(cx - 4.8, base_y), Vector2(cx - 1.4, base_y),
		Vector2(cx - 0.4, base_y - 34.0), Vector2(cx - 2.2, base_y - 34.0),
	]), Color(0.180, 0.165, 0.153))
	c.stroke_polygon(PackedVector2Array([
		Vector2(cx - 4.8, base_y), Vector2(cx + 4.8, base_y),
		Vector2(cx + 2.4, base_y - 34.0), Vector2(cx - 2.2, base_y - 34.0),
	]), OUTLINE, 1.3)
	var branches: Array[Vector2] = [
		Vector2(-1.0, 0.70), Vector2(1.0, 0.58), Vector2(-1.0, 0.42),
		Vector2(1.0, 0.30), Vector2(-1.0, 0.18), Vector2(1.0, 0.06),
	]
	for i: int in branches.size():
		var b: Vector2 = branches[i]
		var y: float = base_y - 30.0 * b.y - 2.0
		var len_px: float = 9.0 + LcnNoise.hash3(i, 4, 3) * 7.0
		c.stroke_polyline(PackedVector2Array([
			Vector2(cx, y),
			Vector2(cx + b.x * len_px * 0.6, y - len_px * 0.35),
			Vector2(cx + b.x * len_px, y - len_px * 0.9),
		]), Color(0.118, 0.110, 0.102), 3.0)
		c.stroke_polyline(PackedVector2Array([
			Vector2(cx + b.x * len_px * 0.6, y - len_px * 0.35),
			Vector2(cx + b.x * len_px * 0.9, y - len_px * 0.2),
		]), Color(0.106, 0.098, 0.094), 1.4)
		c.stroke_polyline(PackedVector2Array([
			Vector2(cx + b.x * len_px * 0.6, y - len_px * 0.42),
			Vector2(cx + b.x * len_px, y - len_px * 0.96),
		]), Color(0.847, 0.886, 0.941, 0.62), 1.1)
	c.stroke_polyline(PackedVector2Array([
		Vector2(cx - 1.4, base_y - 30.0), Vector2(cx - 1.0, base_y - 4.0),
	]), Color(0.855, 0.894, 0.945, 0.55), 1.3)


func _draw_rock(c: LcnVectorCanvas, g: Rect2) -> void:
	var cx: float = g.position.x + g.size.x * 0.5
	var base_y: float = g.end.y - 3.0
	c.fill_ellipse(Vector2(cx, base_y), 13.0, 5.0, Color(0.043, 0.059, 0.098, 0.45))
	var body := PackedVector2Array([
		Vector2(cx - 13.0, base_y), Vector2(cx - 9.0, base_y - 12.0),
		Vector2(cx - 2.0, base_y - 16.0), Vector2(cx + 6.0, base_y - 13.0),
		Vector2(cx + 12.0, base_y - 4.0), Vector2(cx + 12.0, base_y),
	])
	c.fill_polygon_gradient(body, Color(0.208, 0.243, 0.310), Color(0.075, 0.090, 0.129),
		Vector2(0.0, base_y - 16.0), Vector2(0.0, base_y))
	c.fill_polygon(PackedVector2Array([
		Vector2(cx - 9.0, base_y - 12.0), Vector2(cx - 2.0, base_y - 16.0),
		Vector2(cx + 1.0, base_y - 11.0), Vector2(cx - 6.0, base_y - 7.0),
	]), Color(0.271, 0.310, 0.384))
	c.fill_polygon(PackedVector2Array([
		Vector2(cx - 9.6, base_y - 12.4), Vector2(cx - 2.0, base_y - 16.6),
		Vector2(cx + 6.0, base_y - 13.6), Vector2(cx + 4.0, base_y - 11.6),
		Vector2(cx - 2.4, base_y - 13.8), Vector2(cx - 8.0, base_y - 10.4),
	]), Color(0.878, 0.914, 0.957, 0.85))
	c.stroke_polygon(body, OUTLINE, 1.5)


func _draw_wreck(c: LcnVectorCanvas, g: Rect2) -> void:
	var base_y: float = g.end.y - 4.0
	var cx: float = g.position.x + g.size.x * 0.5
	c.fill_ellipse(Vector2(cx, base_y + 1.0), g.size.x * 0.44, 6.0, Color(0.043, 0.059, 0.098, 0.45))
	var hull := PackedVector2Array([
		Vector2(cx - 26.0, base_y), Vector2(cx - 22.0, base_y - 14.0),
		Vector2(cx + 4.0, base_y - 17.0), Vector2(cx + 20.0, base_y - 9.0),
		Vector2(cx + 24.0, base_y),
	])
	c.fill_polygon_gradient(hull, Color(0.259, 0.192, 0.145), Color(0.098, 0.071, 0.055),
		Vector2(0.0, base_y - 17.0), Vector2(0.0, base_y))
	c.stroke_polygon(hull, OUTLINE, 1.6)
	for i: int in 4:
		var x: float = cx - 18.0 + float(i) * 11.0
		c.stroke_polyline(PackedVector2Array([Vector2(x, base_y - 14.0), Vector2(x + 1.0, base_y - 1.0)]),
			Color(0.180, 0.129, 0.098), 1.6)
	c.fill_circle(Vector2(cx - 15.0, base_y - 2.0), 5.0, Color(0.086, 0.078, 0.075), 16)
	c.fill_circle(Vector2(cx + 12.0, base_y - 2.0), 5.0, Color(0.086, 0.078, 0.075), 16)
	c.fill_polygon(PackedVector2Array([
		Vector2(cx - 22.4, base_y - 14.4), Vector2(cx + 4.0, base_y - 17.6),
		Vector2(cx + 3.0, base_y - 15.4), Vector2(cx - 21.4, base_y - 12.4),
	]), Color(0.855, 0.894, 0.945, 0.80))


# ------------------------------------------------- bake: second-pass shapes --
# Seven shapes added because a critic could not tell a granary from a warehouse
# from a heat accumulator at far zoom — everything industrial was the same block.
# Each of these owns exactly one outline feature: the hearth a stepped ziggurat
# with a burning crown, the radiator a fin stack, the accumulator a tank pair,
# the silo three cylinders, the kitchen a lean-to awning, the drill an A-frame
# derrick, the collector a low arm.


## THE HEARTH. The one structure the whole city is arranged around: a stepped
## ziggurat with a ring of fire at the top and four buttress stacks. Nothing else
## in the game is round-shouldered and this tall.
func _draw_hearth(c: LcnVectorCanvas, g: Rect2) -> void:
	var cx: float = g.position.x + g.size.x * 0.5
	var base_y: float = g.end.y - 3.0
	var w: float = g.size.x
	var dep: float = g.size.y

	c.fill_ellipse(Vector2(cx, base_y + 2.0), w * 0.56, dep * 0.26, Color(0.043, 0.059, 0.098, 0.6))

	# Three stacked plinths, each narrower and taller than the one below.
	var steps: Array[float] = [0.50, 0.40, 0.30]
	var hs: Array[float] = [18.0, 22.0, 26.0]
	var y: float = base_y
	for i: int in 3:
		var hw: float = w * steps[i]
		var h: float = hs[i]
		var top: float = y - h
		c.fill_polygon_gradient(PackedVector2Array([
			Vector2(cx - hw * 0.94, top), Vector2(cx + hw * 0.94, top),
			Vector2(cx + hw, y), Vector2(cx - hw, y),
		]), METAL_FT.lerp(DARK_FT, float(i) * 0.22), DARK_FB,
			Vector2(0.0, top), Vector2(0.0, y))
		c.stroke_polygon(PackedVector2Array([
			Vector2(cx - hw * 0.94, top), Vector2(cx + hw * 0.94, top),
			Vector2(cx + hw, y), Vector2(cx - hw, y),
		]), OUTLINE, 1.8)
		# A band of grate light on each tier: heat leaking out of the whole mass.
		for j: int in 5:
			var f: float = (float(j) + 0.5) / 5.0
			var gx: float = lerpf(cx - hw * 0.74, cx + hw * 0.74, f)
			c.fill_round_rect(Rect2(gx - 2.2, top + h * 0.32, 4.4, h * 0.42), 1.6,
				Color(1.0, 0.55 + 0.06 * float(j % 2), 0.22, 0.93))
		c.fill_glow(Vector2(cx, top + h * 0.5), hw * 0.9,
			Color(1.0, 0.46, 0.16, 0.28), Color(1.0, 0.46, 0.16, 0.0))
		y = top

	# The crown: an open fire bowl with a ring of flame.
	var crown_r: float = w * 0.22
	c.fill_ellipse(Vector2(cx, y + 2.0), crown_r * 1.20, crown_r * 0.44, Color(0.129, 0.153, 0.208))
	c.stroke_polygon(LcnVectorCanvas.circle_points(Vector2(cx, y + 2.0), crown_r * 1.20, crown_r * 0.44, 30),
		OUTLINE, 1.7)
	c.fill_glow(Vector2(cx, y - 2.0), crown_r * 2.4, Color(1.0, 0.52, 0.18, 0.72), Color(1.0, 0.42, 0.12, 0.0), 40)
	c.fill_ellipse(Vector2(cx, y + 1.0), crown_r * 0.92, crown_r * 0.32, Color(1.0, 0.72, 0.32, 0.98))
	c.fill_ellipse(Vector2(cx, y + 0.0), crown_r * 0.52, crown_r * 0.20, LcnPalette.WARM_WHITE)
	for i: int in 5:
		var a: float = -1.7 + float(i) * 0.85
		var fx: float = cx + cos(a) * crown_r * 0.72
		c.fill_polygon(PackedVector2Array([
			Vector2(fx - 3.2, y + 1.0), Vector2(fx, y - 13.0 - float(i % 2) * 6.0),
			Vector2(fx + 3.2, y + 1.0),
		]), Color(1.0, 0.60, 0.22, 0.72))

	# Four buttress stacks at the corners, which is what reads at far zoom.
	for i: int in 4:
		var sx: float = cx + (w * 0.40 if (i % 2) == 0 else -w * 0.40)
		var sy: float = base_y - (6.0 if i < 2 else 16.0)
		_chimney(c, sx, sy, 34.0 + float(i % 2) * 8.0, 8.0, i * 3 + 1)


## Warmth radiator: a stack of fins on a squat plinth, glowing between the fins.
func _draw_radiator(c: LcnVectorCanvas, g: Rect2) -> void:
	var cx: float = g.position.x + g.size.x * 0.5
	var base_y: float = g.end.y - 4.0
	var w: float = g.size.x
	c.fill_ellipse(Vector2(cx, base_y + 1.5), w * 0.46, g.size.y * 0.2, Color(0.043, 0.059, 0.098, 0.5))
	var plinth := Rect2(cx - w * 0.36, base_y - 12.0, w * 0.72, 12.0)
	c.fill_rect_gradient(plinth, DARK_FT, DARK_FB)
	c.stroke_rect(plinth, OUTLINE, 1.6)

	var fins: int = 6
	var top_y: float = base_y - 12.0
	c.fill_glow(Vector2(cx, top_y - 16.0), w * 0.66, Color(1.0, 0.48, 0.17, 0.42), Color(1.0, 0.48, 0.17, 0.0))
	for i: int in fins:
		var fy: float = top_y - 4.0 - float(i) * 5.4
		var fw: float = w * (0.42 - float(i) * 0.018)
		c.fill_round_rect(Rect2(cx - fw, fy - 3.4, fw * 2.0, 3.4), 1.2,
			METAL_TOP.lerp(Color(0.44, 0.50, 0.60), float(i) / float(fins)))
		c.fill_round_rect(Rect2(cx - fw + 1.5, fy - 0.6, fw * 2.0 - 3.0, 1.6), 0.7,
			Color(1.0, 0.55, 0.20, 0.85))
		c.stroke_rect(Rect2(cx - fw, fy - 3.4, fw * 2.0, 3.4), Color(0.043, 0.063, 0.110, 0.7), 1.0)
	# Central spine so the fins hang off something.
	c.fill_round_rect(Rect2(cx - 3.4, top_y - 4.0 - float(fins) * 5.4, 6.8, float(fins) * 5.4 + 4.0),
		2.0, METAL_FT)
	c.fill_circle(Vector2(cx, top_y - 6.0 - float(fins) * 5.4), 4.0, LcnPalette.WARM_MID, 14)
	c.stroke_polygon(LcnVectorCanvas.circle_points(Vector2(cx, top_y - 6.0 - float(fins) * 5.4), 4.0, 4.0, 14),
		OUTLINE, 1.2)


## Heat accumulator: two riveted tanks side by side with a level gauge.
func _draw_accumulator(c: LcnVectorCanvas, g: Rect2) -> void:
	var base_y: float = g.end.y - 4.0
	var cx: float = g.position.x + g.size.x * 0.5
	c.fill_ellipse(Vector2(cx, base_y + 1.5), g.size.x * 0.48, g.size.y * 0.2, Color(0.043, 0.059, 0.098, 0.5))
	var rx: float = g.size.x * 0.22
	for i: int in 2:
		var tx: float = cx + (-1.0 if i == 0 else 1.0) * g.size.x * 0.23
		var h: float = 30.0 - float(i) * 4.0
		_cylinder(c, tx, base_y - float(i) * 2.0, rx, g.size.y * 0.14, h,
			Color(0.290, 0.345, 0.435), Color(0.216, 0.263, 0.345), Color(0.075, 0.098, 0.153))
		# Level gauge: how full the buffer is, in warm light.
		c.fill_round_rect(Rect2(tx - 1.6, base_y - float(i) * 2.0 - h * 0.62, 3.2, h * 0.46), 1.2,
			Color(1.0, 0.58, 0.24, 0.85))
		_rivets(c, Rect2(tx - rx + 2.0, base_y - float(i) * 2.0 - h + 4.0, rx * 2.0 - 4.0, h - 8.0), 4,
			Color(0.055, 0.075, 0.118, 0.65))
	c.fill_round_rect(Rect2(cx - g.size.x * 0.26, base_y - 22.0, g.size.x * 0.52, 4.0), 1.6, METAL_FT)
	c.stroke_rect(Rect2(cx - g.size.x * 0.26, base_y - 22.0, g.size.x * 0.52, 4.0), OUTLINE, 1.2)


## Silo / granary: three tall cylinders with conical caps. Unmistakable outline.
func _draw_silo(c: LcnVectorCanvas, g: Rect2) -> void:
	var base_y: float = g.end.y - 3.0
	var cx: float = g.position.x + g.size.x * 0.5
	c.fill_ellipse(Vector2(cx, base_y + 1.5), g.size.x * 0.50, g.size.y * 0.22, Color(0.043, 0.059, 0.098, 0.5))
	var rx: float = g.size.x * 0.155
	for i: int in 3:
		var f: float = float(i) / 2.0
		var tx: float = lerpf(cx - g.size.x * 0.30, cx + g.size.x * 0.30, f)
		var h: float = 44.0 - absf(f - 0.5) * 16.0
		var y0: float = base_y - float(i % 2) * 3.0
		_cylinder(c, tx, y0, rx, g.size.y * 0.10, h,
			Color(0.322, 0.345, 0.392), Color(0.243, 0.267, 0.318), Color(0.086, 0.098, 0.129))
		# Conical cap.
		c.fill_polygon(PackedVector2Array([
			Vector2(tx - rx * 1.08, y0 - h), Vector2(tx, y0 - h - 12.0), Vector2(tx + rx * 1.08, y0 - h),
		]), Color(0.404, 0.435, 0.494))
		c.stroke_polygon(PackedVector2Array([
			Vector2(tx - rx * 1.08, y0 - h), Vector2(tx, y0 - h - 12.0), Vector2(tx + rx * 1.08, y0 - h),
		]), OUTLINE, 1.5)
		c.fill_polygon(PackedVector2Array([
			Vector2(tx - rx * 0.9, y0 - h - 1.5), Vector2(tx, y0 - h - 11.0), Vector2(tx - rx * 0.1, y0 - h - 1.5),
		]), Color(0.910, 0.933, 0.969, 0.85))
		for j: int in 3:
			var by: float = y0 - h * (0.28 + 0.26 * float(j))
			c.stroke_polyline(PackedVector2Array([Vector2(tx - rx, by), Vector2(tx + rx, by)]),
				Color(0.043, 0.063, 0.110, 0.5), 1.2)


## Field kitchen: a lean-to awning over a range, with the only open flame at
## ground level in the whole city.
func _draw_kitchen(c: LcnVectorCanvas, g: Rect2) -> void:
	var body := Rect2(g.position.x + 2.0, g.position.y + 8.0, g.size.x * 0.58, g.size.y - 10.0)
	_mass(c, body, 22.0, RUST_TOP.lerp(METAL_TOP, 0.55), RUST_FT.lerp(METAL_FT, 0.5), METAL_FB)
	_snow_roof(c, body, 22.0, 0.55, 27, RUST_TOP.lerp(METAL_TOP, 0.55))
	var roof_y: float = body.end.y - 22.0
	_chimney(c, body.position.x + 8.0, roof_y, 24.0, 7.0, 2)

	# Canvas awning on two poles, sagging between them.
	var ax0: float = body.end.x - 2.0
	var ax1: float = g.end.x - 2.0
	var ay: float = roof_y + 4.0
	c.fill_polygon(PackedVector2Array([
		Vector2(ax0, ay), Vector2(ax1, ay + 5.0),
		Vector2(ax1, ay + 9.0), Vector2(ax0, ay + 4.0),
	]), Color(0.478, 0.396, 0.310))
	c.stroke_polyline(PackedVector2Array([
		Vector2(ax0, ay), Vector2(lerpf(ax0, ax1, 0.5), ay + 4.0), Vector2(ax1, ay + 5.0),
	]), Color(0.663, 0.573, 0.451), 1.6)
	for i: int in 2:
		var px: float = ax1 - float(i) * 1.0
		c.stroke_polyline(PackedVector2Array([Vector2(px, ay + 5.0), Vector2(px, g.end.y - 3.0)]),
			Color(0.180, 0.157, 0.129), 2.0)
	# The range: a pot over an open fire.
	var fx: float = lerpf(ax0, ax1, 0.45)
	var fy: float = g.end.y - 6.0
	c.fill_glow(Vector2(fx, fy), 20.0, Color(1.0, 0.50, 0.18, 0.62), Color(1.0, 0.42, 0.12, 0.0))
	c.fill_ellipse(Vector2(fx, fy), 7.0, 3.0, Color(1.0, 0.66, 0.28, 0.95))
	c.fill_polygon(PackedVector2Array([
		Vector2(fx - 6.0, fy - 5.0), Vector2(fx + 6.0, fy - 5.0),
		Vector2(fx + 4.6, fy - 13.0), Vector2(fx - 4.6, fy - 13.0),
	]), Color(0.157, 0.176, 0.212))
	c.stroke_polygon(PackedVector2Array([
		Vector2(fx - 6.0, fy - 5.0), Vector2(fx + 6.0, fy - 5.0),
		Vector2(fx + 4.6, fy - 13.0), Vector2(fx - 4.6, fy - 13.0),
	]), OUTLINE, 1.3)


## Ore drill: an A-frame derrick over a spoil heap. The tallest lattice in the
## game after the pylon, and the only one that is triangular.
func _draw_drill(c: LcnVectorCanvas, g: Rect2) -> void:
	var cx: float = g.position.x + g.size.x * 0.5
	var base_y: float = g.end.y - 3.0
	var top_y: float = g.position.y + 4.0
	c.fill_ellipse(Vector2(cx, base_y + 1.0), g.size.x * 0.50, g.size.y * 0.22, Color(0.043, 0.059, 0.098, 0.5))

	# Spoil heap: this is a mine, and mines make a mess.
	c.fill_polygon(_blob(Vector2(cx + g.size.x * 0.26, base_y - 5.0), g.size.x * 0.22, 7.0, 71, 0.30),
		Color(0.184, 0.169, 0.153))

	var half: float = g.size.x * 0.34
	var legs := PackedVector2Array([
		Vector2(cx - half, base_y), Vector2(cx - half * 0.22, top_y),
		Vector2(cx + half * 0.22, top_y), Vector2(cx + half, base_y),
	])
	c.stroke_polyline(PackedVector2Array([legs[0], legs[1]]), Color(0.267, 0.298, 0.361), 3.4)
	c.stroke_polyline(PackedVector2Array([legs[3], legs[2]]), Color(0.212, 0.239, 0.298), 3.4)
	var rungs: int = 7
	for i: int in rungs:
		var f: float = (float(i) + 0.5) / float(rungs)
		var ly: float = lerpf(base_y, top_y, f)
		var lw: float = lerpf(half, half * 0.22, f)
		c.stroke_polyline(PackedVector2Array([Vector2(cx - lw, ly), Vector2(cx + lw, ly)]),
			Color(0.239, 0.267, 0.322), 1.7)
		var nl: float = lerpf(base_y, top_y, (float(i) + 1.5) / float(rungs))
		var nw: float = lerpf(half, half * 0.22, (float(i) + 1.5) / float(rungs))
		c.stroke_polyline(PackedVector2Array([Vector2(cx - lw, ly), Vector2(cx + nw, nl)]),
			Color(0.196, 0.220, 0.271), 1.3)
	c.fill_round_rect(Rect2(cx - half * 0.34, top_y - 5.0, half * 0.68, 6.0), 1.8, METAL_TOP)
	c.stroke_rect(Rect2(cx - half * 0.34, top_y - 5.0, half * 0.68, 6.0), OUTLINE, 1.3)
	c.fill_circle(Vector2(cx, top_y - 2.0), 2.0, LcnPalette.CAUTION, 10)
	# Winch house at the foot.
	var shed := Rect2(cx - g.size.x * 0.40, base_y - 18.0, g.size.x * 0.34, 18.0)
	_mass(c, shed, 14.0, METAL_TOP, METAL_FT, METAL_FB)
	_windows(c, Rect2(shed.position.x + 2.0, shed.end.y - 12.0, shed.size.x - 4.0, 8.0), 2, 1,
		LcnPalette.WARM_MID, 33)


## Scrap collector: a low sorting table with a hydraulic arm reaching sideways.
func _draw_collector(c: LcnVectorCanvas, g: Rect2) -> void:
	var base_y: float = g.end.y - 4.0
	var cx: float = g.position.x + g.size.x * 0.5
	c.fill_ellipse(Vector2(cx, base_y + 1.0), g.size.x * 0.44, g.size.y * 0.18, Color(0.043, 0.059, 0.098, 0.45))
	var table := Rect2(g.position.x + 3.0, base_y - 14.0, g.size.x - 6.0, 14.0)
	c.fill_rect_gradient(table, RUST_FT.lerp(METAL_FT, 0.5), METAL_FB)
	c.fill_rect_gradient(Rect2(table.position.x, table.position.y - 5.0, table.size.x, 5.0),
		Color(0.302, 0.267, 0.220), Color(0.220, 0.196, 0.165))
	c.stroke_rect(Rect2(table.position.x, table.position.y - 5.0, table.size.x, table.size.y + 5.0), OUTLINE, 1.6)
	# Sorted scrap on the table.
	for i: int in 5:
		var sx: float = lerpf(table.position.x + 4.0, table.end.x - 4.0, (float(i) + 0.5) / 5.0)
		c.fill_polygon(_blob(Vector2(sx, table.position.y - 2.0), 3.4, 2.0, 90 + i, 0.5),
			Color(0.365, 0.318, 0.271) if (i % 2) == 0 else Color(0.271, 0.290, 0.333))
	# The arm: one bent limb, and the whole reason this silhouette is not a box.
	var px: float = table.position.x + 5.0
	var py: float = table.position.y - 4.0
	c.stroke_polyline(PackedVector2Array([
		Vector2(px, py), Vector2(px + 5.0, py - 20.0), Vector2(px + 22.0, py - 13.0),
	]), Color(0.259, 0.290, 0.353), 3.6)
	c.stroke_polyline(PackedVector2Array([
		Vector2(px + 22.0, py - 13.0), Vector2(px + 26.0, py - 5.0),
	]), Color(0.212, 0.239, 0.298), 2.6)
	c.fill_circle(Vector2(px + 5.0, py - 20.0), 3.0, Color(0.322, 0.353, 0.420), 12)
	c.fill_circle(Vector2(px + 26.0, py - 4.0), 2.2, LcnPalette.CAUTION, 10)


# ------------------------------------------------------------- draw atlas ----

## Atlas region key for a building sprite.
static func sprite_key(arch: StringName, tiles: Vector2i) -> StringName:
	return StringName("bld_%s_%dx%d" % [arch, tiles.x, tiles.y])


## Atlas region key for a building's EMISSIVE mask — the windows, grilles and
## firelight cut out of the baked sprite. Drawn additively after dark.
static func emissive_key(arch: StringName, tiles: Vector2i) -> StringName:
	return StringName("em_%s_%dx%d" % [arch, tiles.x, tiles.y])


## The lit parts of a sprite, extracted from the sprite itself.
##
## Every archetype already paints its own fire: a window, a grille, an open door,
## a crucible. Those pixels are the only decisively WARM ones in an otherwise
## blue-grey sheet, so they can be separated by hue instead of by hand — which
## means a new archetype gets night lighting for free the moment it is drawn,
## and no draw function has to be rewritten to declare where its light is.
##
## Alpha is how emissive the pixel is; the colour is kept so a window stays amber
## and a forge stays red-hot instead of every light in the city being one tint.
static func _extract_emissive(src: Image) -> Image:
	var w: int = src.get_width()
	var h: int = src.get_height()
	var out: Image = Image.create(w, h, false, Image.FORMAT_RGBA8)
	out.fill(Color(0, 0, 0, 0))
	for y: int in h:
		for x: int in w:
			var c: Color = src.get_pixel(x, y)
			if c.a < 0.35:
				continue
			var warmth: float = c.r - c.b
			if warmth <= 0.055 or c.r < 0.30:
				continue
			var e: float = clampf((warmth - 0.055) * 3.4, 0.0, 1.0) \
				* clampf(c.r * 1.25, 0.0, 1.0)
			if e < 0.02:
				continue
			out.set_pixel(x, y, Color(
				minf(c.r * 1.15, 1.0), minf(c.g * 1.05, 1.0), minf(c.b * 0.9, 1.0),
				e * c.a))
	return out


## Atlas region key for an agent sprite.
static func agent_key(kind: StringName) -> StringName:
	return StringName("agent_%s" % kind)


## Every sprite the entity renderer draws, packed into ONE texture.
##
## This is the batching fix. Godot's canvas renderer starts a new draw call every
## time the bound texture changes, so 206 buildings across 20 archetypes plus a
## separate shadow blob and glow cookie cost hundreds of state changes — measured
## at 797 draw calls and 37 ms of CPU for one frame of a 206-building city. With
## a single atlas the same frame is a handful of calls, because every
## draw_texture_rect_region in a pass binds the same texture.
##
## Returns {texture: ImageTexture, regions: Dictionary[StringName, Rect2]}.
func atlas(extra_buildings: Array = []) -> Dictionary:
	if not _atlas.is_empty() and _atlas_covers(extra_buildings):
		return _atlas
	var entries: Array[Dictionary] = []
	for arch: StringName in archetypes():
		var s: Dictionary = building(arch)
		var im: Image = (s["texture"] as ImageTexture).get_image()
		entries.append({"key": sprite_key(arch, s["tiles"]), "img": im})
		var em: Image = _emissive_for(sprite_key(arch, s["tiles"]), im)
		if em != null:
			entries.append({"key": emissive_key(arch, s["tiles"]), "img": em})
	for req: Variant in extra_buildings:
		var pair: Array = req
		var arch2: StringName = pair[0]
		var t: Vector2i = pair[1]
		var key2: StringName = sprite_key(arch2, t)
		var known: bool = false
		for e: Dictionary in entries:
			if e["key"] == key2:
				known = true
				break
		if known:
			continue
		var s2: Dictionary = building(arch2, t)
		var im2: Image = (s2["texture"] as ImageTexture).get_image()
		entries.append({"key": key2, "img": im2})
		var em2: Image = _emissive_for(key2, im2)
		if em2 != null:
			entries.append({"key": emissive_key(arch2, t), "img": em2})
	for kind: StringName in AGENT_KINDS:
		var a: Dictionary = agent(kind)
		entries.append({"key": agent_key(kind), "img": (a["texture"] as ImageTexture).get_image()})
	# The ten designed enemies ride the SAME atlas as everything else, so ten
	# silhouettes cost the same number of draw calls as the one blob they
	# replace. That is the whole reason they could be added at all.
	for ek: StringName in ENEMY_KINDS:
		var ae: Dictionary = agent(ek)
		entries.append({"key": agent_key(ek), "img": (ae["texture"] as ImageTexture).get_image()})
	entries.append({"key": &"barrel", "img": (turret_barrel()["texture"] as ImageTexture).get_image()})
	entries.append({"key": &"glow", "img": glow_texture(256).get_image()})
	entries.append({"key": &"shadow", "img": shadow_texture(96).get_image()})
	entries.append({"key": &"smear", "img": _smear_texture().get_image()})

	_atlas = _pack(entries)
	_atlas_keys = {}
	for e2: Dictionary in entries:
		_atlas_keys[e2["key"]] = true
	return _atlas


## Cached because extracting a mask is a per-pixel walk over a sprite and the
## atlas is rebuilt every time a footprint the packer has never seen is placed.
func _emissive_for(key: StringName, src: Image) -> Image:
	var img: Image = LcnArtCache.get_image("em_%s" % key,
		func() -> Image: return _extract_emissive(src))
	# A structure with no lit surface at all (a wall, a belt) has nothing to add
	# to the night pass and should not take a slot in the sheet.
	var data: PackedByteArray = img.get_data()
	for i: int in range(3, data.size(), 4):
		if data[i] > 6:
			return img
	return null


func _atlas_covers(extra_buildings: Array) -> bool:
	for req: Variant in extra_buildings:
		var pair: Array = req
		if not _atlas_keys.has(sprite_key(pair[0], pair[1])):
			return false
	return true


## Shelf packer. Sprites are sorted tallest first, which for this catalogue wastes
## under 10% of the sheet — good enough, and it keeps the whole thing one texture.
func _pack(entries: Array[Dictionary]) -> Dictionary:
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return (a["img"] as Image).get_height() > (b["img"] as Image).get_height())
	var gap: int = ATLAS_GAP
	var width: int = 1024
	var x: int = gap
	var y: int = gap
	var shelf: int = 0
	var placed: Array[Dictionary] = []
	for e: Dictionary in entries:
		var img: Image = e["img"]
		var w: int = img.get_width()
		var h: int = img.get_height()
		if x + w + gap > width:
			x = gap
			y += shelf + gap
			shelf = 0
		placed.append({"key": e["key"], "img": img, "pos": Vector2i(x, y)})
		x += w + gap
		shelf = maxi(shelf, h)
	var height: int = y + shelf + gap
	var sheet: Image = Image.create(width, maxi(height, 4), false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0, 0, 0, 0))
	var regions: Dictionary[StringName, Rect2] = {}
	for p: Dictionary in placed:
		var img2: Image = p["img"]
		var pos: Vector2i = p["pos"]
		sheet.blit_rect(img2, Rect2i(Vector2i.ZERO, img2.get_size()), pos)
		regions[p["key"]] = Rect2(Vector2(pos), Vector2(img2.get_size()))
	return {
		"texture": ImageTexture.create_from_image(sheet),
		"regions": regions,
		"size": Vector2i(width, height),
	}


## A soft directional smear used for cast shadows. Bright at one end, gone at the
## other, so a stretched quad of it reads as a shadow falling away from a light.
static func _smear_texture() -> ImageTexture:
	return LcnArtCache.get_texture("smear_64", func() -> Image:
		var n: int = 64
		var img: Image = Image.create(n, n, false, Image.FORMAT_RGBA8)
		for yy: int in n:
			for xx: int in n:
				var u: float = (float(xx) + 0.5) / float(n)
				var v: float = (float(yy) + 0.5) / float(n)
				var edge: float = minf(u, 1.0 - u) * 2.0
				var a: float = pow(clampf(1.0 - v, 0.0, 1.0), 1.35) * smoothstep(0.0, 0.34, edge)
				img.set_pixel(xx, yy, Color(1, 1, 1, a))
		return img)


# ---------------------------------------------------------------- bake: fx --

static func _bake_glow(size: int) -> Image:
	var c := LcnVectorCanvas.new(size, size, 2)
	var r: float = float(size) * 0.5
	c.fill_glow(Vector2(r, r), r, Color(1, 1, 1, 1), Color(1, 1, 1, 0), 48)
	# A tight hot core keeps small lights from looking like fog patches.
	c.fill_glow(Vector2(r, r), r * 0.34, Color(1, 1, 1, 0.85), Color(1, 1, 1, 0), 32)
	return c.to_image()


static func _bake_shadow(size: int) -> Image:
	var c := LcnVectorCanvas.new(size, size, 2)
	var r: float = float(size) * 0.5
	c.fill_polygon_radial(LcnVectorCanvas.circle_points(Vector2(r, r), r, r, 40),
		Color(0, 0, 0, 0.85), Color(0, 0, 0, 0.0), Vector2(r, r), r)
	return c.to_image()


func _bake_agent(kind: StringName) -> Image:
	match kind:
		&"swarm":
			return _bake_swarm()
		&"brute":
			return _bake_brute()
	if ENEMY_KINDS.has(kind):
		return _bake_enemy(kind)
	return _bake_person(kind)


# ============================================================== THE CITIZENRY ==
#
# THREE ROLES, ONE POLYGON. Every person in this game — the woman with no job,
# the crew on the belt line, the militia on the wall — was drawn from the SAME
# 14x20 outline with a different coat colour and a different belt, and a blind
# judge looking at a full frame of the running build "could find one human
# figure". Colour cannot fix that: `LcnEntityRenderer.agent_scale` holds every
# figure at MIN_AGENT_PX, so at the zoom this game is played at all four of
# these arrive SEVENTEEN PIXELS TALL and what the eye has to work with is the
# outline and the width. Height is spent by the figure floor before it reaches
# the player; aspect ratio and profile are all that survive.
#
# So each role now takes its own bounding box and its own set of spurs:
#
#   citizen  11x19  narrow, hooded, arms folded in, feet together — a column
#   worker   20x20  square: shoulders out, a bar carried across the body whose
#                   ends leave the outline top-right and bottom-left
#   porter   22x17  low and wide: bent under a crate that overhangs the back,
#                   the only role whose mass is off-centre from its feet
#   soldier  20x24  upright, wide-brimmed helmet, stance apart, a slung rifle
#                   projecting past the shoulder and the hip
#
# Held at 0.62 overlap by tests/render/test_sprites.gd, measured at the screen
# height the renderer actually gives them, and against the eleven creatures too:
# the one pair in this game that must never be confused is a citizen crossing
# the plaza and something coming out of the dark.

## Figure geometry per role, so the silhouette rules live in one readable table
## instead of inside four drawing routines.
const PERSON_COAT: Dictionary[StringName, Color] = {
	&"citizen": Color(0.180, 0.216, 0.290),
	&"worker": Color(0.259, 0.216, 0.169),
	&"porter": Color(0.216, 0.192, 0.235),
	&"soldier": Color(0.145, 0.169, 0.220),
}


func _bake_person(kind: StringName) -> Image:
	match kind:
		&"worker": return _bake_worker()
		&"porter": return _bake_porter()
		&"soldier": return _bake_soldier()
	return _bake_citizen()


## The face of the coat that catches the light, so a figure is not a flat cutout.
func _person_shade(kind: StringName) -> Color:
	return (PERSON_COAT.get(kind, PERSON_COAT[&"citizen"]) as Color).lightened(0.16)


## NARROW. Hood up, arms folded into the coat, feet together — the whole figure
## is one column about half as wide as it is tall, which is what makes it read
## as "person standing in the cold" beside the worker's square and the porter's
## overhang.
func _bake_citizen() -> Image:
	var coat: Color = PERSON_COAT[&"citizen"]
	var c := LcnVectorCanvas.new(12, 19, SS)
	c.fill_ellipse(Vector2(6.0, 17.8), 3.4, 1.3, Color(0.043, 0.059, 0.098, 0.40))
	# MID-STRIDE. The legs are drawn first, one forward and one trailing, and the
	# gap between them survives all the way down to seventeen screen pixels. It
	# is the cheapest cue in the game for "this figure is walking, and it is
	# walking THAT way", and it is the difference between a person and every
	# tapered thing on the plain — a drill cone and a hooded citizen are both a
	# narrow vertical smudge until one of them has feet.
	c.fill_polygon(PackedVector2Array([
		Vector2(3.4, 13.0), Vector2(5.4, 13.0), Vector2(5.0, 18.2), Vector2(2.8, 18.2),
	]), coat.darkened(0.26))
	c.fill_polygon(PackedVector2Array([
		Vector2(7.0, 13.0), Vector2(9.0, 13.0), Vector2(9.2, 17.4), Vector2(7.2, 17.4),
	]), coat.darkened(0.34))
	# NARROW. Half as wide as it is tall where the soldier is two thirds and the
	# worker is wider than tall — at seventeen pixels the ASPECT is the identity,
	# because five columns of coat cannot hold a detail.
	var body := PackedVector2Array([
		Vector2(3.6, 7.4), Vector2(8.2, 7.4), Vector2(8.8, 14.4), Vector2(3.0, 14.4),
	])
	c.fill_polygon(body, coat)
	c.fill_polygon(PackedVector2Array([
		Vector2(3.6, 7.4), Vector2(5.8, 7.4), Vector2(5.6, 14.4), Vector2(3.0, 14.4),
	]), _person_shade(&"citizen"))
	# The hood: a narrow peak, no brim. Nothing leaves the column above the waist.
	var hood := PackedVector2Array([
		Vector2(3.4, 7.2), Vector2(8.4, 7.2), Vector2(7.8, 4.0),
		Vector2(6.0, 2.4), Vector2(4.2, 4.0),
	])
	c.fill_polygon(hood, coat.darkened(0.20))
	c.fill_ellipse(Vector2(6.0, 5.4), 1.7, 1.9, Color(0.086, 0.075, 0.071))
	# The near arm swings clear of the coat, which is the other half of the walk.
	c.stroke_polyline(PackedVector2Array([
		Vector2(3.6, 9.6), Vector2(1.6, 11.8),
	]), coat.darkened(0.08), 1.5)
	c.fill_round_rect(Rect2(3.8, 10.2, 4.2, 1.5), 0.7,
		LcnPalette.WARM_EDGE * Color(1, 1, 1, 0.85))
	c.stroke_polygon(PackedVector2Array([
		Vector2(3.4, 7.0), Vector2(6.0, 2.2), Vector2(8.4, 7.0),
		Vector2(8.8, 14.4), Vector2(3.0, 14.4),
	]), OUTLINE, 1.2)
	c.fill_polygon(PackedVector2Array([
		Vector2(4.4, 4.2), Vector2(6.0, 2.4), Vector2(6.9, 3.2), Vector2(5.1, 4.9),
	]), Color(0.878, 0.914, 0.957, 0.7))
	return c.to_image()


## SQUARE, WITH SPURS. A crew hand carrying a bar across the body: the bar
## leaves the outline at the top right and the bottom left, so the shape has two
## points on a diagonal no other role has. Hard hat, flat brim, shoulders wide.
func _bake_worker() -> Image:
	var coat: Color = PERSON_COAT[&"worker"]
	var c := LcnVectorCanvas.new(24, 18, SS)
	c.fill_ellipse(Vector2(10.0, 16.4), 4.6, 1.5, Color(0.043, 0.059, 0.098, 0.40))
	# The bar, drawn FIRST and running corner to corner, so its two ends leave
	# the body's outline instead of reading as a stripe painted on the coat.
	c.stroke_polyline(PackedVector2Array([
		Vector2(0.9, 14.6), Vector2(23.1, 3.4),
	]), Color(0.298, 0.310, 0.353), 1.6)
	c.stroke_polyline(PackedVector2Array([
		Vector2(0.9, 14.6), Vector2(23.1, 3.4),
	]), Color(0.055, 0.063, 0.086, 0.55), 0.5)
	var body := PackedVector2Array([
		Vector2(4.4, 8.0), Vector2(7.4, 6.2), Vector2(12.4, 6.2), Vector2(15.4, 8.0),
		Vector2(15.8, 15.8), Vector2(4.0, 15.8),
	])
	c.fill_polygon(body, coat)
	c.fill_polygon(PackedVector2Array([
		Vector2(4.4, 8.0), Vector2(7.4, 6.2), Vector2(8.8, 6.2),
		Vector2(8.2, 15.8), Vector2(4.0, 15.8),
	]), _person_shade(&"worker"))
	c.fill_ellipse(Vector2(9.9, 4.4), 2.0, 2.2, Color(0.086, 0.075, 0.071))
	# The hat: a wide flat brim is the one horizontal in a figure of verticals.
	c.fill_round_rect(Rect2(5.9, 2.8, 8.0, 1.5), 0.5, LcnPalette.CAUTION.darkened(0.30))
	c.fill_polygon(PackedVector2Array([
		Vector2(7.2, 2.8), Vector2(12.6, 2.8), Vector2(11.6, 1.0), Vector2(8.2, 1.0),
	]), LcnPalette.CAUTION.darkened(0.12))
	# The far arm reaching up the bar. It is the only limb in the set that leaves
	# the body sideways at shoulder height.
	c.stroke_polyline(PackedVector2Array([
		Vector2(13.6, 9.0), Vector2(18.6, 6.4),
	]), coat.darkened(0.10), 1.7)
	c.fill_round_rect(Rect2(5.0, 11.0, 9.8, 1.6), 0.7,
		LcnPalette.CAUTION * Color(1, 1, 1, 0.85))
	c.stroke_polygon(body, OUTLINE, 1.2)
	return c.to_image()


## LOW AND WIDE, AND OFF ITS OWN CENTRE. Bent forward under a crate that
## overhangs behind the shoulders, so the mass of the silhouette is not above
## the feet. Nothing else in the set leans.
func _bake_porter() -> Image:
	var coat: Color = PERSON_COAT[&"porter"]
	var c := LcnVectorCanvas.new(22, 17, SS)
	c.fill_ellipse(Vector2(8.0, 15.6), 4.2, 1.4, Color(0.043, 0.059, 0.098, 0.40))
	# The crate: a hard rectangle high and to the rear, past the back of the legs.
	var crate := Rect2(9.4, 2.6, 11.4, 7.2)
	c.fill_rect_gradient(crate, Color(0.322, 0.259, 0.184), Color(0.180, 0.141, 0.102))
	c.stroke_rect(crate, OUTLINE, 1.1)
	c.stroke_polyline(PackedVector2Array([
		Vector2(9.4, 6.2), Vector2(20.8, 6.2),
	]), Color(0.055, 0.047, 0.039, 0.7), 0.8)
	# The body, pitched forward under it.
	var body := PackedVector2Array([
		Vector2(3.2, 9.2), Vector2(7.4, 5.4), Vector2(11.6, 6.6),
		Vector2(11.0, 15.4), Vector2(5.0, 15.4), Vector2(3.0, 12.0),
	])
	c.fill_polygon(body, coat)
	c.fill_polygon(PackedVector2Array([
		Vector2(3.2, 9.2), Vector2(7.4, 5.4), Vector2(8.4, 6.0),
		Vector2(5.6, 15.4), Vector2(3.0, 12.0),
	]), _person_shade(&"porter"))
	c.fill_ellipse(Vector2(5.4, 6.6), 1.9, 1.8, Color(0.086, 0.075, 0.071))
	# The strap over the shoulder — it explains the lean in one line.
	c.stroke_polyline(PackedVector2Array([
		Vector2(6.2, 7.4), Vector2(9.8, 9.2), Vector2(11.2, 8.0),
	]), LcnPalette.WARM_EDGE * Color(1, 1, 1, 0.75), 1.0)
	c.stroke_polygon(body, OUTLINE, 1.2)
	return c.to_image()


## UPRIGHT, BRIMMED, FEET APART, AND ARMED. The rifle crosses the back and
## leaves the outline above the near shoulder and below the far hip; the stance
## opens a gap between the boots that no other role has. This is the figure a
## player has to find on the wall at midnight.
func _bake_soldier() -> Image:
	var coat: Color = PERSON_COAT[&"soldier"]
	var c := LcnVectorCanvas.new(20, 24, SS)
	c.fill_ellipse(Vector2(9.6, 22.2), 5.0, 1.5, Color(0.043, 0.059, 0.098, 0.40))
	# The rifle, under the coat so only its ends break the silhouette.
	c.stroke_polyline(PackedVector2Array([
		Vector2(3.0, 4.6), Vector2(16.8, 17.4),
	]), Color(0.153, 0.133, 0.118), 1.4)
	c.stroke_polyline(PackedVector2Array([
		Vector2(14.6, 15.4), Vector2(18.2, 18.8),
	]), Color(0.259, 0.196, 0.141), 2.0)
	# Greatcoat: shoulders square, skirt flaring to a wide hem.
	var body := PackedVector2Array([
		Vector2(5.4, 8.6), Vector2(6.8, 7.0), Vector2(12.6, 7.0), Vector2(14.0, 8.6),
		Vector2(15.2, 17.0), Vector2(4.2, 17.0),
	])
	c.fill_polygon(body, coat)
	c.fill_polygon(PackedVector2Array([
		Vector2(5.4, 8.6), Vector2(6.8, 7.0), Vector2(8.6, 7.0),
		Vector2(8.0, 17.0), Vector2(4.2, 17.0),
	]), _person_shade(&"soldier"))
	# Boots, apart. The gap between them is a silhouette feature, not a detail.
	c.fill_polygon(PackedVector2Array([
		Vector2(4.6, 16.4), Vector2(8.0, 16.4), Vector2(7.4, 22.0), Vector2(4.0, 22.0),
	]), coat.darkened(0.22))
	c.fill_polygon(PackedVector2Array([
		Vector2(11.4, 16.4), Vector2(14.8, 16.4), Vector2(15.4, 22.0), Vector2(12.0, 22.0),
	]), coat.darkened(0.22))
	c.fill_ellipse(Vector2(9.7, 5.2), 2.0, 2.1, Color(0.086, 0.075, 0.071))
	# Helmet: the widest thing at the top of any figure in the game.
	c.fill_round_rect(Rect2(4.8, 3.4, 9.8, 1.4), 0.5, coat.darkened(0.34))
	c.fill_polygon(PackedVector2Array([
		Vector2(6.0, 3.4), Vector2(13.4, 3.4), Vector2(12.2, 1.0), Vector2(7.2, 1.0),
	]), coat.darkened(0.12))
	c.fill_round_rect(Rect2(5.4, 11.0, 8.4, 1.6), 0.7,
		LcnPalette.DANGER * Color(1, 1, 1, 0.85))
	c.stroke_polygon(body, OUTLINE, 1.2)
	c.stroke_polyline(PackedVector2Array([
		Vector2(4.6, 16.4), Vector2(4.0, 22.0), Vector2(7.4, 22.0), Vector2(8.0, 16.4),
	]), OUTLINE, 0.9)
	c.stroke_polyline(PackedVector2Array([
		Vector2(11.4, 16.4), Vector2(12.0, 22.0), Vector2(15.4, 22.0), Vector2(14.8, 16.4),
	]), OUTLINE, 0.9)
	return c.to_image()


## Enemy: no hood, no warmth, spiky negative-space silhouette. It should be
## instantly obvious that this thing is not from the city.
func _bake_swarm() -> Image:
	var c := LcnVectorCanvas.new(18, 16, SS)
	c.fill_ellipse(Vector2(9.0, 14.4), 6.0, 2.0, Color(0.043, 0.020, 0.031, 0.5))
	var body := PackedVector2Array([
		Vector2(3.0, 9.4), Vector2(6.0, 5.0), Vector2(9.0, 3.0), Vector2(12.0, 5.0),
		Vector2(15.0, 9.4), Vector2(12.4, 13.4), Vector2(5.6, 13.4),
	])
	c.fill_polygon_gradient(body, Color(0.129, 0.086, 0.106), Color(0.043, 0.024, 0.035),
		Vector2(0.0, 3.0), Vector2(0.0, 13.4))
	for i: int in 3:
		var sx: float = -1.0 if i != 1 else 1.0
		var y: float = 6.6 + float(i) * 2.4
		c.stroke_polyline(PackedVector2Array([
			Vector2(9.0, y), Vector2(9.0 + sx * 6.5, y - 2.2), Vector2(9.0 + sx * 8.4, y - 5.0),
		]), Color(0.098, 0.063, 0.075), 1.4)
	c.fill_circle(Vector2(7.4, 8.4), 1.5, LcnPalette.DANGER, 10)
	c.fill_circle(Vector2(10.6, 8.4), 1.5, LcnPalette.DANGER, 10)
	c.fill_glow(Vector2(9.0, 8.4), 7.0, Color(0.95, 0.22, 0.20, 0.42), Color(0.95, 0.22, 0.20, 0.0))
	c.stroke_polygon(body, Color(0.016, 0.008, 0.012, 0.9), 1.3)
	return c.to_image()


func _bake_brute() -> Image:
	var c := LcnVectorCanvas.new(30, 28, SS)
	c.fill_ellipse(Vector2(15.0, 25.6), 10.0, 3.2, Color(0.043, 0.020, 0.031, 0.55))
	var body := PackedVector2Array([
		Vector2(4.0, 16.0), Vector2(7.0, 8.0), Vector2(12.0, 4.0), Vector2(19.0, 4.0),
		Vector2(24.0, 9.0), Vector2(26.0, 17.0), Vector2(22.0, 24.0), Vector2(8.0, 24.0),
	])
	c.fill_polygon_gradient(body, Color(0.153, 0.098, 0.114), Color(0.047, 0.028, 0.039),
		Vector2(0.0, 4.0), Vector2(0.0, 24.0))
	for i: int in 5:
		var a: float = -PI * 0.9 + PI * 0.45 * float(i) * 0.5
		c.fill_polygon(PackedVector2Array([
			Vector2(15.0, 12.0) + Vector2(cos(a), sin(a)) * 9.0,
			Vector2(15.0, 12.0) + Vector2(cos(a + 0.16), sin(a + 0.16)) * 9.0,
			Vector2(15.0, 12.0) + Vector2(cos(a + 0.08), sin(a + 0.08)) * 15.0,
		]), Color(0.114, 0.071, 0.086))
	c.fill_polygon(PackedVector2Array([
		Vector2(10.0, 12.0), Vector2(20.0, 12.0), Vector2(18.0, 15.5), Vector2(12.0, 15.5),
	]), Color(0.95, 0.24, 0.20, 0.92))
	c.fill_glow(Vector2(15.0, 13.6), 16.0, Color(0.95, 0.22, 0.18, 0.48), Color(0.95, 0.22, 0.18, 0.0))
	c.stroke_polygon(body, Color(0.016, 0.008, 0.012, 0.92), 1.6)
	return c.to_image()


# =============================================================== THE ENEMIES ==
#
# TEN DESIGNED KINDS, ONE 14 px BLOB. `world_renderer._on_enemy_spawned` mapped
# every id in the game with
#
#     &"brute" if String(kind).to_lower().contains("brute") else &"swarm"
#
# and not one of ash_spitter, cinder_leech, drift_hound, frost_shade,
# hoarfrost_breaker, keener, pale_stalker, permafrost_borer, rime_sapper or
# the_long_cold contains the word "brute". So every enemy this game has ever
# shipped — a 30 hp hound that comes in sixes and a 9000 hp boss — drew the same
# eighteen pixels, and the night was unreadable because there was nothing in it
# to read.
#
# THE RULE THESE TEN OBEY: silhouette first. A player at zoom 0.60 sees a shape
# about twelve pixels tall with no interior detail, so the thing that has to
# carry the identity is the OUTLINE and the aspect ratio, not the palette. Each
# kind therefore takes a different footprint and a different profile, and the
# set was chosen so no two share both:
#
#   drift_hound         wide, low, four legs             — a running animal
#   rime_sapper         round, squat, one bright core    — a walking bomb
#   cinder_leech        segmented arc, head down         — a worm on a cable
#   frost_shade         tall, tapered, hollow, legless   — nothing solid
#   keener              tall, thin, flared head          — a horn on legs
#   pale_stalker        wide wingspan, small body        — the only flier
#   ash_spitter         squat, lopsided, a raised tube   — artillery
#   permafrost_borer    a cone half-sunk in the ground   — a drill
#   hoarfrost_breaker   broad plated slab, two arms      — a wall
#   the_long_cold       twice everything, spired crown   — the boss
#
# The tints match the `tint` on each `game/content/enemies/*.tres`, so the
# creature the designer described is the creature that walks. They are written
# out here rather than read from the Registry because a baked sprite is cached
# on disk by key: art that changes when a data file changes would serve a stale
# image from `LcnArtCache`, and a bake that touches the Registry cannot run in
# the sprite tests.

## Every enemy id in game/content/enemies/, each with its own sprite.
##
## `snow_widow` arrived in the content folder this wave carrying
## `render_arch = &"swarm"`, which is the fallback and not a drawing: the one
## creature in the roster that walks past the guns to get at a housing block was
## about to reach the player as the same eighteen-pixel lump every undesigned
## enemy gets. test_every_shipped_enemy_maps_to_its_own_sprite found it, which
## is what that test is for.
const ENEMY_KINDS: Array[StringName] = [
	&"drift_hound", &"rime_sapper", &"cinder_leech", &"frost_shade", &"keener",
	&"pale_stalker", &"snow_widow", &"ash_spitter", &"permafrost_borer",
	&"hoarfrost_breaker", &"the_long_cold",
]

## Enemy sprites are drawn walking LEFT (-X). `_draw_agent` flips them when the
## thing is moving the other way, which is the whole of "facing" and costs
## nothing: a negative width on the destination rect.
const ENEMY_FACES_LEFT: bool = true


## The render kind for a spawn id. Ten designed enemies each get their own
## sprite; anything the content folder grows later falls back to the old two
## archetypes by name rather than drawing nothing.
##
## This is the function `world_renderer._on_enemy_spawned` must call. The bug it
## replaces was not that the mapping was crude, it was that the mapping was
## never TRUE for any input the game can produce.
static func agent_arch(kind: StringName) -> StringName:
	if ENEMY_KINDS.has(kind) or AGENT_KINDS.has(kind):
		return kind
	var s: String = String(kind).to_lower()
	# Heaviest words first: "hoarfrost_breaker" is a breaker before it is frost.
	for word: String in ["boss", "breaker", "brute", "siege", "borer", "titan"]:
		if s.contains(word):
			return &"brute"
	return &"swarm"


## True when this render kind is one of the ten, i.e. draws hostile art.
static func is_enemy_kind(kind: StringName) -> bool:
	return ENEMY_KINDS.has(kind) or kind == &"swarm" or kind == &"brute"


func _bake_enemy(kind: StringName) -> Image:
	match kind:
		&"drift_hound": return _bake_drift_hound()
		&"rime_sapper": return _bake_rime_sapper()
		&"cinder_leech": return _bake_cinder_leech()
		&"frost_shade": return _bake_frost_shade()
		&"keener": return _bake_keener()
		&"pale_stalker": return _bake_pale_stalker()
		&"snow_widow": return _bake_snow_widow()
		&"ash_spitter": return _bake_ash_spitter()
		&"permafrost_borer": return _bake_permafrost_borer()
		&"hoarfrost_breaker": return _bake_hoarfrost_breaker()
		&"the_long_cold": return _bake_the_long_cold()
	return _bake_swarm()


## Shared chassis tone. Every enemy is built out of the same near-black so the
## whole faction reads as one thing at a glance, and its own `tint` only ever
## appears as the light coming OUT of it — which is what makes an enemy legible
## on a black plain without lighting it like a lamp.
static func _hide(tint: Color, dark: float = 0.86) -> Color:
	return Color(
		lerpf(tint.r * 0.32, 0.055, dark),
		lerpf(tint.g * 0.32, 0.043, dark),
		lerpf(tint.b * 0.32, 0.063, dark), 1.0)


## Six legs' worth of quadruped: long, low, head dropped, tail out behind. The
## only enemy that is wider than it is tall by more than two to one.
func _bake_drift_hound() -> Image:
	var t := Color(0.78, 0.36, 0.32)
	var c := LcnVectorCanvas.new(22, 13, SS)
	c.fill_ellipse(Vector2(11.0, 11.6), 8.0, 1.6, Color(0.043, 0.020, 0.031, 0.5))
	var body := PackedVector2Array([
		Vector2(6.0, 4.4), Vector2(13.0, 3.6), Vector2(16.4, 5.0),
		Vector2(15.6, 8.0), Vector2(7.0, 8.4), Vector2(5.0, 6.6),
	])
	c.fill_polygon_gradient(body, _hide(t, 0.55), _hide(t, 0.95),
		Vector2(0.0, 3.6), Vector2(0.0, 8.4))
	# Four legs, splayed front and back — a running animal, not a table.
	for l: int in 4:
		var lx: float = [6.6, 8.6, 13.0, 15.0][l]
		var sx: float = -1.4 if l < 2 else 1.4
		c.stroke_polyline(PackedVector2Array([
			Vector2(lx, 7.4), Vector2(lx + sx * 0.6, 9.6), Vector2(lx + sx, 11.2),
		]), _hide(t, 0.92), 1.2)
	# Head down and forward: the thing is coming at you.
	c.fill_polygon(PackedVector2Array([
		Vector2(5.2, 5.0), Vector2(1.6, 6.2), Vector2(1.8, 8.0), Vector2(5.6, 7.8),
	]), _hide(t, 0.72))
	c.fill_circle(Vector2(3.0, 6.7), 0.85, t * Color(1.4, 1.0, 1.0, 1.0), 8)
	# Tail, straight out — it lengthens the silhouette down the axis of travel.
	c.stroke_polyline(PackedVector2Array([
		Vector2(16.2, 5.4), Vector2(19.4, 4.2), Vector2(21.0, 5.4),
	]), _hide(t, 0.9), 1.1)
	c.fill_glow(Vector2(3.0, 6.7), 5.0, Color(t.r, t.g, t.b, 0.34), Color(t.r, t.g, t.b, 0.0))
	c.stroke_polygon(body, Color(0.012, 0.008, 0.012, 0.9), 1.0)
	return c.to_image()


## A walking charge. Round, squat, no head, and a core so bright it is the only
## enemy whose interior out-reads its outline — because the read the player
## needs is "that one is about to go off".
func _bake_rime_sapper() -> Image:
	var t := Color(0.90, 0.42, 0.24)
	var c := LcnVectorCanvas.new(16, 16, SS)
	c.fill_ellipse(Vector2(8.0, 14.2), 5.4, 1.7, Color(0.043, 0.020, 0.031, 0.5))
	var body: PackedVector2Array = LcnVectorCanvas.circle_points(Vector2(8.0, 7.6), 5.6, 5.0, 14)
	c.fill_polygon_radial(body, _hide(t, 0.50), _hide(t, 0.96), Vector2(8.0, 6.0), 6.4)
	# Two stubby legs under a body far too big for them.
	for lx: float in [6.0, 10.0]:
		c.stroke_polyline(PackedVector2Array([
			Vector2(lx, 11.4), Vector2(lx, 13.6)]), _hide(t, 0.94), 1.5)
	# Ribbed shell so the core reads as something contained.
	for r: int in 3:
		c.stroke_polyline(PackedVector2Array([
			Vector2(3.4, 6.0 + float(r) * 1.9), Vector2(12.6, 6.0 + float(r) * 1.9),
		]), Color(0.02, 0.014, 0.02, 0.55), 0.7)
	c.fill_circle(Vector2(8.0, 7.4), 2.5, Color(t.r, t.g * 0.85, t.b * 0.7, 0.95), 12)
	c.fill_circle(Vector2(8.0, 7.4), 1.3, Color(1.0, 0.92, 0.72, 1.0), 10)
	c.fill_glow(Vector2(8.0, 7.4), 9.0, Color(t.r, t.g, t.b, 0.5), Color(t.r, t.g, t.b, 0.0))
	c.stroke_polygon(body, Color(0.012, 0.008, 0.012, 0.9), 1.1)
	return c.to_image()


## Segmented, head to the ground, body arched. It siphons, so it is drawn
## attached to something: the profile is a hook, not a walker.
func _bake_cinder_leech() -> Image:
	var t := Color(0.94, 0.55, 0.22)
	var c := LcnVectorCanvas.new(20, 14, SS)
	c.fill_ellipse(Vector2(10.0, 12.4), 7.0, 1.5, Color(0.043, 0.020, 0.031, 0.45))
	# Six segments along an arc. Each is drawn separately, so the outline is a
	# scallop and not a sausage — that is the whole silhouette read.
	for s: int in 6:
		var f: float = float(s) / 5.0
		var px: float = lerpf(4.0, 17.0, f)
		var py: float = 9.6 - sin(f * PI) * 5.0
		var rad: float = 2.6 - f * 0.9
		c.fill_circle(Vector2(px, py), rad, _hide(t, 0.58 + f * 0.34), 10)
		if s % 2 == 0:
			c.fill_circle(Vector2(px, py - rad * 0.3), rad * 0.36,
				Color(t.r, t.g, t.b, 0.75), 8)
	# The proboscis, planted.
	c.stroke_polyline(PackedVector2Array([
		Vector2(4.0, 9.6), Vector2(2.2, 11.4), Vector2(1.4, 12.6),
	]), _hide(t, 0.9), 1.3)
	c.fill_glow(Vector2(9.0, 6.2), 8.0, Color(t.r, t.g, t.b, 0.30), Color(t.r, t.g, t.b, 0.0))
	return c.to_image()


## Legless, tall, and it does not close at the bottom. Every other enemy stands
## on the ground; this one is a column of cold that fades into it, which is the
## fastest possible read for "you cannot block this the usual way".
func _bake_frost_shade() -> Image:
	var t := Color(0.55, 0.78, 0.92)
	var c := LcnVectorCanvas.new(16, 24, SS)
	var body := PackedVector2Array([
		Vector2(8.0, 1.6), Vector2(11.6, 5.0), Vector2(12.4, 12.0),
		Vector2(11.0, 21.0), Vector2(5.0, 21.0), Vector2(3.6, 12.0),
		Vector2(4.4, 5.0),
	])
	# Top-lit and bottom-transparent: it is thickest at the head and gone at the
	# hem. `fill_polygon_gradient` carries the alpha, so the fade is in the
	# silhouette itself rather than painted on afterwards.
	c.fill_polygon_gradient(body,
		Color(0.30, 0.42, 0.55, 0.92), Color(0.10, 0.17, 0.26, 0.05),
		Vector2(0.0, 1.6), Vector2(0.0, 21.0))
	# The hollow. A shade with a solid middle is a ghost costume.
	c.fill_polygon(PackedVector2Array([
		Vector2(8.0, 8.0), Vector2(10.2, 12.0), Vector2(8.0, 17.4), Vector2(5.8, 12.0),
	]), Color(0.02, 0.05, 0.09, 0.72))
	c.fill_ellipse(Vector2(8.0, 4.6), 2.0, 2.4, Color(t.r * 0.5, t.g * 0.6, t.b * 0.7, 0.9))
	c.fill_circle(Vector2(6.9, 4.4), 0.75, Color(0.85, 0.97, 1.0, 0.95), 8)
	c.fill_circle(Vector2(9.1, 4.4), 0.75, Color(0.85, 0.97, 1.0, 0.95), 8)
	c.fill_glow(Vector2(8.0, 6.0), 11.0, Color(t.r, t.g, t.b, 0.34), Color(t.r, t.g, t.b, 0.0))
	c.stroke_polyline(PackedVector2Array([
		Vector2(4.4, 5.0), Vector2(8.0, 1.6), Vector2(11.6, 5.0),
	]), Color(t.r, t.g, t.b, 0.55), 1.0)
	return c.to_image()


## A horn with legs. It does no damage; it makes everything else worse, so it is
## drawn as an instrument — the flared head is the widest thing at the top of any
## silhouette in the set and it is what a player learns to shoot first.
func _bake_keener() -> Image:
	var t := Color(0.72, 0.42, 0.85)
	var c := LcnVectorCanvas.new(18, 24, SS)
	c.fill_ellipse(Vector2(9.0, 22.0), 5.0, 1.6, Color(0.043, 0.020, 0.031, 0.5))
	# The stalk. Narrow relative to the bell, but SOLID: the first draft drew it
	# two pixels wide with a hollow funnel over it and the whole creature put
	# 116 screen pixels on the plate at play zoom — a hairline, and the frame
	# lab said so. Silhouette identity is the flare-over-a-stem, not thinness.
	c.fill_polygon_gradient(PackedVector2Array([
		Vector2(6.4, 8.0), Vector2(11.6, 8.0), Vector2(12.6, 21.4), Vector2(5.4, 21.4),
	]), _hide(t, 0.58), _hide(t, 0.95), Vector2(0.0, 8.0), Vector2(0.0, 21.4))
	for lx: float in [6.6, 11.4]:
		c.stroke_polyline(PackedVector2Array([
			Vector2(lx, 18.0), Vector2(lx + (lx - 9.0) * 0.5, 22.4)]), _hide(t, 0.94), 1.8)
	# The bell, opening upward and forward. Filled, not outlined.
	var bell := PackedVector2Array([
		Vector2(7.4, 9.4), Vector2(0.6, 2.4), Vector2(1.8, 0.4),
		Vector2(17.2, 1.8), Vector2(16.4, 5.6), Vector2(10.8, 9.4),
	])
	c.fill_polygon_gradient(bell, Color(t.r * 0.55, t.g * 0.40, t.b * 0.62, 1.0),
		_hide(t, 0.80), Vector2(0.0, 0.8), Vector2(0.0, 9.0))
	c.stroke_polyline(PackedVector2Array([
		Vector2(0.6, 2.4), Vector2(1.8, 0.4), Vector2(17.2, 1.8),
	]), Color(t.r, t.g, t.b, 0.85), 1.4)
	# The throat: the one bright thing on it, so a player can find the support
	# unit in a pack without counting legs.
	c.fill_polygon(PackedVector2Array([
		Vector2(5.4, 4.4), Vector2(12.6, 5.0), Vector2(10.4, 8.2), Vector2(7.4, 8.0),
	]), Color(t.r, t.g * 0.75, t.b, 0.72))
	c.fill_glow(Vector2(8.6, 4.4), 13.0, Color(t.r, t.g, t.b, 0.42), Color(t.r, t.g, t.b, 0.0))
	c.stroke_polygon(bell, Color(0.014, 0.010, 0.018, 0.85), 1.0)
	return c.to_image()


## The only thing in the game with a wingspan, and it is drawn ABOVE its own
## shadow with a visible gap — the one silhouette cue that survives at any zoom
## and the only way "it ignores your walls" can be read from a still frame.
func _bake_pale_stalker() -> Image:
	var t := Color(0.86, 0.90, 0.96)
	# 32x15. The aspect ratio IS the identity: at play zoom this is a horizontal
	# bar where every other enemy is a lump, and the suite holds it to being the
	# widest-for-its-height shape in the set so it can never quietly narrow.
	var c := LcnVectorCanvas.new(32, 15, SS)
	# The shadow sits low and small; the body is high. The gap is the read.
	c.fill_ellipse(Vector2(16.0, 13.6), 3.8, 1.1, Color(0.043, 0.048, 0.070, 0.55))
	var lwing := PackedVector2Array([
		Vector2(15.0, 4.4), Vector2(6.0, 0.8), Vector2(0.5, 2.6),
		Vector2(4.4, 4.4), Vector2(1.0, 5.8), Vector2(14.2, 6.6),
	])
	var rwing := PackedVector2Array([
		Vector2(17.0, 4.4), Vector2(26.0, 0.8), Vector2(31.5, 2.6),
		Vector2(27.6, 4.4), Vector2(31.0, 5.8), Vector2(17.8, 6.6),
	])
	for wing: PackedVector2Array in [lwing, rwing]:
		c.fill_polygon_gradient(wing, Color(0.25, 0.28, 0.34, 0.95),
			Color(0.08, 0.10, 0.14, 0.85), Vector2(0.0, 0.8), Vector2(0.0, 6.6))
		c.stroke_polygon(wing, Color(0.012, 0.014, 0.020, 0.85), 0.9)
	c.fill_polygon(PackedVector2Array([
		Vector2(16.0, 1.8), Vector2(18.0, 4.4), Vector2(16.0, 9.6), Vector2(14.0, 4.4),
	]), _hide(t, 0.60))
	c.fill_circle(Vector2(16.0, 3.4), 1.0, Color(t.r, t.g, t.b, 0.95), 10)
	c.fill_glow(Vector2(16.0, 4.0), 8.0, Color(t.r, t.g, t.b, 0.22), Color(t.r, t.g, t.b, 0.0))
	return c.to_image()


## THE HOUSEBREAKER. It walks past the pipes, past the guns, past everything
## worth money, and goes where the city sleeps — so it has to be readable as
## something that CLIMBS rather than something that charges. Six long legs
## arched high over a small body slung between them: the silhouette is a bridge
## with daylight under it, and the negative space under the arch is the whole
## identity. Nothing else in the roster is a shape you can see the ground
## through.
func _bake_snow_widow() -> Image:
	var t := Color(0.83, 0.29, 0.45)
	var c := LcnVectorCanvas.new(26, 22, SS)
	# Small shadow, far below a high body: the gap says "up on legs".
	c.fill_ellipse(Vector2(13.0, 20.4), 6.0, 1.3, Color(0.055, 0.024, 0.035, 0.5))
	# Three legs a side. Each rises to a knee well above the body, then drops
	# past it, so the outline is a row of peaks with holes between them.
	var span: Array[float] = [10.4, 6.2, 9.4]
	var knee: Array[float] = [1.6, 3.4, 2.2]
	for i: int in 3:
		for side: int in 2:
			var s: float = -1.0 if side == 0 else 1.0
			var reach: float = span[i]
			c.stroke_polyline(PackedVector2Array([
				Vector2(13.0 + s * 1.6, 10.4 + float(i) * 1.1),
				Vector2(13.0 + s * reach * 0.55, knee[i]),
				Vector2(13.0 + s * reach, 19.6 - float(i) * 1.4),
			]), _hide(t, 0.88), 1.1)
	var body := PackedVector2Array([
		Vector2(9.6, 10.0), Vector2(13.0, 8.2), Vector2(16.4, 10.0),
		Vector2(15.4, 14.2), Vector2(10.6, 14.2),
	])
	c.fill_polygon_gradient(body, _hide(t, 0.42), _hide(t, 0.92),
		Vector2(0.0, 8.2), Vector2(0.0, 14.2))
	# The mark on its back, and the only warm thing on it.
	c.fill_polygon(PackedVector2Array([
		Vector2(13.0, 9.6), Vector2(14.8, 11.8), Vector2(13.0, 13.6), Vector2(11.2, 11.8),
	]), Color(t.r, t.g, t.b, 0.92))
	c.fill_circle(Vector2(12.0, 10.2), 0.7, Color(1.0, 0.86, 0.90, 0.9), 8)
	c.fill_circle(Vector2(14.0, 10.2), 0.7, Color(1.0, 0.86, 0.90, 0.9), 8)
	c.fill_glow(Vector2(13.0, 11.4), 9.0, Color(t.r, t.g, t.b, 0.26), Color(t.r, t.g, t.b, 0.0))
	c.stroke_polygon(body, Color(0.016, 0.008, 0.014, 0.9), 1.0)
	return c.to_image()


## Artillery: a squat asymmetric mass with one tube pointing up and back. It is
## the only enemy whose outline is deliberately UNBALANCED, so it can be picked
## out of a mixed pack without reading any interior detail.
func _bake_ash_spitter() -> Image:
	var t := Color(0.60, 0.52, 0.30)
	# 26x18, LOW AND WIDE. The borer is the other squat siege body in the set and
	# the two used to overlap at 0.675 of each other's area, i.e. they were one
	# creature with two names. The spitter is now decisively a horizontal
	# platform and the borer a vertical cone; there is no zoom at which they
	# resolve to the same shape.
	var c := LcnVectorCanvas.new(26, 18, SS)
	c.fill_ellipse(Vector2(13.0, 16.4), 10.4, 2.0, Color(0.043, 0.031, 0.020, 0.55))
	var body := PackedVector2Array([
		Vector2(1.6, 11.0), Vector2(4.0, 8.2), Vector2(17.0, 7.8),
		Vector2(23.4, 10.4), Vector2(22.2, 15.4), Vector2(3.0, 15.4),
	])
	c.fill_polygon_gradient(body, _hide(t, 0.52), _hide(t, 0.94),
		Vector2(0.0, 7.8), Vector2(0.0, 15.4))
	# The tube. Raised, angled back over the body: a mortar.
	c.fill_polygon(PackedVector2Array([
		Vector2(15.0, 9.2), Vector2(18.4, 8.4), Vector2(25.2, 2.4),
		Vector2(22.6, 0.8), Vector2(15.4, 6.8),
	]), _hide(t, 0.66))
	c.fill_circle(Vector2(24.0, 1.6), 1.6, Color(0.95, 0.52, 0.20, 0.85), 10)
	c.fill_glow(Vector2(24.0, 1.6), 8.0, Color(0.95, 0.5, 0.2, 0.42), Color(0.95, 0.5, 0.2, 0.0))
	# Six short legs across the full width — it is a platform, it does not run.
	for l: int in 6:
		var lx: float = 3.2 + float(l) * 3.6
		c.stroke_polyline(PackedVector2Array([
			Vector2(lx, 14.8), Vector2(lx, 16.8)]), _hide(t, 0.94), 1.3)
	c.fill_polygon(PackedVector2Array([
		Vector2(4.0, 10.8), Vector2(10.0, 10.4), Vector2(9.6, 12.8), Vector2(4.2, 13.0),
	]), Color(0.72, 0.42, 0.16, 0.55))
	c.stroke_polygon(body, Color(0.014, 0.010, 0.008, 0.9), 1.2)
	return c.to_image()


## A cone with its point in the ground and its ridges showing. Half of it is
## missing below the surface, which is why the silhouette is a triangle sitting
## in a spoil ring rather than a body standing on legs.
func _bake_permafrost_borer() -> Image:
	var t := Color(0.45, 0.40, 0.52)
	# 18x26: TALL AND NARROW, the inverse of the ash spitter's platform. A drill
	# standing out of the ground is a spike, and a spike is the one profile in
	# this set that is taller than it is wide by more than half again.
	var c := LcnVectorCanvas.new(18, 26, SS)
	# The spoil ring: it came UP through the snow, so there is a mess around it.
	c.fill_ellipse(Vector2(9.0, 23.0), 8.6, 2.6, Color(0.10, 0.10, 0.13, 0.62))
	c.fill_ellipse(Vector2(9.0, 23.0), 5.6, 1.7, Color(0.045, 0.043, 0.059, 0.85))
	var cone := PackedVector2Array([
		Vector2(9.0, 0.6), Vector2(12.4, 14.0), Vector2(13.0, 22.4),
		Vector2(5.0, 22.4), Vector2(5.6, 14.0),
	])
	c.fill_polygon_gradient(cone, _hide(t, 0.44), _hide(t, 0.90),
		Vector2(0.0, 0.6), Vector2(0.0, 22.4))
	# Helical ridges. Five chevrons up a tall cone read as a screw thread.
	for r: int in 5:
		var y: float = 4.4 + float(r) * 3.6
		var half: float = 1.3 + float(r) * 1.1
		c.stroke_polyline(PackedVector2Array([
			Vector2(9.0 - half, y + 1.4), Vector2(9.0, y - 0.5), Vector2(9.0 + half, y + 1.4),
		]), Color(0.72, 0.76, 0.86, 0.42), 0.9)
	c.fill_circle(Vector2(9.0, 2.8), 1.1, Color(0.62, 0.86, 1.0, 0.8), 10)
	c.fill_glow(Vector2(9.0, 3.6), 10.0, Color(t.r + 0.2, t.g + 0.3, t.b + 0.4, 0.24),
		Color(t.r, t.g, t.b, 0.0))
	c.stroke_polygon(cone, Color(0.012, 0.012, 0.018, 0.9), 1.3)
	return c.to_image()


## 900 hp of plate. Broad, flat-topped, shoulders wider than it is tall, and two
## arms that hang past its feet. If the player reads one thing off this shape it
## should be "that is not going to stop for a wall".
func _bake_hoarfrost_breaker() -> Image:
	var t := Color(0.62, 0.68, 0.78)
	var c := LcnVectorCanvas.new(32, 28, SS)
	c.fill_ellipse(Vector2(16.0, 25.6), 11.5, 3.0, Color(0.043, 0.047, 0.062, 0.6))
	var body := PackedVector2Array([
		Vector2(3.4, 10.0), Vector2(6.0, 6.0), Vector2(26.0, 6.0),
		Vector2(28.6, 10.0), Vector2(27.0, 22.0), Vector2(5.0, 22.0),
	])
	c.fill_polygon_gradient(body, _hide(t, 0.46), _hide(t, 0.92),
		Vector2(0.0, 6.0), Vector2(0.0, 22.0))
	# Plates. Horizontal banding is what says armour at eight pixels.
	for p: int in 3:
		c.stroke_polyline(PackedVector2Array([
			Vector2(4.6, 10.4 + float(p) * 3.8), Vector2(27.4, 10.4 + float(p) * 3.8),
		]), Color(0.70, 0.78, 0.90, 0.20), 1.0)
	# Two heavy arms, hanging below the hem.
	for sx: float in [-1.0, 1.0]:
		var ax: float = 16.0 + sx * 13.0
		c.fill_polygon(PackedVector2Array([
			Vector2(ax - sx * 2.4, 9.0), Vector2(ax + sx * 2.6, 10.4),
			Vector2(ax + sx * 2.0, 25.0), Vector2(ax - sx * 2.2, 24.0),
		]), _hide(t, 0.66))
	# Rime crust on the shoulders: it carries the cold with it.
	c.stroke_polyline(PackedVector2Array([
		Vector2(6.0, 6.4), Vector2(11.0, 5.0), Vector2(16.0, 6.4),
		Vector2(21.0, 5.0), Vector2(26.0, 6.4),
	]), Color(0.78, 0.90, 1.0, 0.62), 1.2)
	c.fill_polygon(PackedVector2Array([
		Vector2(11.0, 12.4), Vector2(21.0, 12.4), Vector2(19.4, 15.6), Vector2(12.6, 15.6),
	]), Color(0.62, 0.84, 1.0, 0.88))
	c.fill_glow(Vector2(16.0, 14.0), 17.0, Color(0.5, 0.75, 1.0, 0.42), Color(0.5, 0.75, 1.0, 0.0))
	c.stroke_polygon(body, Color(0.012, 0.014, 0.020, 0.92), 1.6)
	return c.to_image()


## The boss. It is not a bigger brute; it is a different object — a crowned mass
## with spires coming off it and a cold that reaches past its own outline. At
## 52x48 it is over three times the height of a drift hound in the same frame,
## which is the only honest way to draw 9000 hp next to 30.
func _bake_the_long_cold() -> Image:
	var t := Color(0.36, 0.44, 0.62)
	var c := LcnVectorCanvas.new(52, 48, SS)
	c.fill_ellipse(Vector2(26.0, 43.6), 20.0, 5.0, Color(0.031, 0.039, 0.063, 0.66))
	var body := PackedVector2Array([
		Vector2(8.0, 22.0), Vector2(12.0, 13.0), Vector2(21.0, 8.0),
		Vector2(31.0, 8.0), Vector2(40.0, 13.0), Vector2(44.0, 22.0),
		Vector2(41.0, 38.0), Vector2(11.0, 38.0),
	])
	c.fill_polygon_gradient(body, _hide(t, 0.40), _hide(t, 0.94),
		Vector2(0.0, 8.0), Vector2(0.0, 38.0))
	# The crown: seven ice spires of uneven length. Uneven on purpose — a
	# symmetrical crown reads as a machine part.
	var spire_h: Array[float] = [7.0, 12.0, 9.0, 16.0, 8.5, 13.0, 6.5]
	for s: int in spire_h.size():
		var sx2: float = 13.0 + float(s) * 4.4
		var top: float = 9.0 - spire_h[s]
		c.fill_polygon(PackedVector2Array([
			Vector2(sx2 - 1.8, 11.0), Vector2(sx2, top), Vector2(sx2 + 1.8, 11.0),
		]), Color(0.42, 0.58, 0.78, 0.88))
		c.stroke_polyline(PackedVector2Array([
			Vector2(sx2, top), Vector2(sx2, 11.0)]), Color(0.80, 0.92, 1.0, 0.5), 0.8)
	# Ribs down the mass.
	for r2: int in 4:
		c.stroke_polyline(PackedVector2Array([
			Vector2(10.0, 22.0 + float(r2) * 4.4), Vector2(42.0, 22.0 + float(r2) * 4.4),
		]), Color(0.60, 0.74, 0.94, 0.16), 1.2)
	# Two eyes far apart: the width between them is a size cue on its own.
	for ex: float in [19.0, 33.0]:
		c.fill_ellipse(Vector2(ex, 20.0), 2.6, 1.7, Color(0.58, 0.84, 1.0, 0.95))
		c.fill_circle(Vector2(ex, 20.0), 1.0, Color(0.92, 0.98, 1.0, 1.0), 10)
	c.fill_polygon(PackedVector2Array([
		Vector2(17.0, 27.0), Vector2(35.0, 27.0), Vector2(31.0, 33.0), Vector2(21.0, 33.0),
	]), Color(0.46, 0.72, 1.0, 0.70))
	c.fill_glow(Vector2(26.0, 24.0), 30.0, Color(0.42, 0.66, 1.0, 0.40), Color(0.42, 0.66, 1.0, 0.0))
	c.stroke_polygon(body, Color(0.010, 0.012, 0.020, 0.94), 2.0)
	return c.to_image()
