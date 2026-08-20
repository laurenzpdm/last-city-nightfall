extends TestCase
## THE TWO LEGIBILITY MASKS, checked in the sheet the renderer actually binds.
## [P13]
##
## `LcnEntityRenderer._draw_agent_edge` looks its masks up by key and draws
## NOTHING when the lookup misses. That is the right behaviour at runtime — a
## missing mask must never crash a frame — and it is exactly the shape of bug
## this project keeps paying for: the night went quietly back to a dark
## silhouette on a dark plain and every contrast number stayed green, because the
## contour alone still cleared them.
##
## So the masks are asserted HERE, in the packed atlas, by key, with their
## coverage measured. `tests/render/night_contrast.tscn` then asks whether the
## result is legible; this suite asks whether the parts are there at all.

var f: LcnSpriteFactory = null
var _sheet: Dictionary = {}


func suite_name() -> String:
	return "render/agent_masks"


## Bake fresh, for the reason test_sprites.gd states: a mask test that reads
## user://art_cache certifies whatever was baked before the change it is judging.
func before_all() -> void:
	LcnArtCache.set_enabled(false)
	f = LcnSpriteFactory.new()
	_sheet = f.atlas()


func after_all() -> void:
	LcnArtCache.set_enabled(true)


func _walkers() -> Array[StringName]:
	var out: Array[StringName] = []
	out.append_array(LcnSpriteFactory.AGENT_KINDS)
	out.append_array(LcnSpriteFactory.ENEMY_KINDS)
	return out


## Every walking thing carries a fill and a rim in the SAME sheet as its sprite,
## at the SAME size, so the renderer can reuse one destination rect and one
## texture binding for all three.
func test_every_walker_has_both_masks_in_the_atlas() -> void:
	var regions: Dictionary = _sheet["regions"]
	for kind: StringName in _walkers():
		var sprite: Rect2 = regions.get(LcnSpriteFactory.agent_key(kind), Rect2())
		assert_true(sprite.size.x > 0.0, "%s has no sprite in the atlas" % kind)
		for key: StringName in [
				LcnSpriteFactory.fill_key(kind), LcnSpriteFactory.rim_key(kind)]:
			var m: Rect2 = regions.get(key, Rect2())
			assert_true(m.size.x > 0.0, "%s is missing from the atlas — the "
				% key + "renderer draws nothing when a mask key misses, so the "
				+ "night silently goes back to a dark shape on a dark plain")
			assert_eq(m.size, sprite.size, "%s is %s but its sprite is %s; the "
				% [key, str(m.size), str(sprite.size)]
				+ "renderer reuses one destination rect for both")


## THE FILL HAS TO COVER THE BODY. A fill that is present but nearly transparent
## draws a bright contour around an unlifted mass, which is a wireframe: the
## first tuning of this pass shipped exactly that and it was caught by LOOKING at
## `artifacts/P13/frames/wave.png`, not by any number.
##
## Measured against the sprite's own solid area, so a wide creature and a narrow
## one are held to the same standard.
## Measured over the pixels that ACTUALLY NEED LIFTING — the dark chassis — and
## not over the whole body. A blanket figure fails the wrong creature: the frost
## shade is drawn as a luminous translucent hood and is 66% bright pixels by
## area, so it legitimately takes almost no lift and its whole-body coverage is
## 0.34. The invariant that matters is the one `_extract_fill` promises: whatever
## is dark gets lifted, whatever is hot is left alone.
const FILL_MIN_COVER: float = 0.95
## How much of the mask may sit over a creature's own BRIGHT pixels. This is the
## other half of the requirement and the one a flat silhouette fails: the ten
## were each drawn with a hot part — a core, an eye, a crucible — and painting
## over those turns eleven drawings into eleven pale shapes.
const FILL_MAX_OVER_BRIGHT: float = 0.35
const BRIGHT_AT: float = 0.55


func test_the_fill_lifts_the_body_and_spares_the_hot_parts() -> void:
	var lifted: int = 0
	var chassis_heavy: int = 0
	for kind: StringName in _walkers():
		var src: Image = (f.agent(kind)["texture"] as ImageTexture).get_image()
		var fill: Image = LcnSpriteFactory._extract_fill(src)
		var solid: int = 0
		var dark: int = 0
		var dark_covered: float = 0.0
		var bright_touched: float = 0.0
		var bright: int = 0
		for y: int in src.get_height():
			for x: int in src.get_width():
				var c: Color = src.get_pixel(x, y)
				if c.a < LcnSpriteFactory.MASK_SOLID:
					continue
				solid += 1
				var l: float = c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722
				if l < LcnSpriteFactory.FILL_FULL_BELOW:
					dark += 1
					dark_covered += fill.get_pixel(x, y).a / maxf(c.a, 0.001)
				if l >= BRIGHT_AT:
					bright += 1
					bright_touched += fill.get_pixel(x, y).a
		assert_true(solid > 0, "%s has no solid body at all" % kind)
		if dark > 0:
			var cover: float = dark_covered / float(dark)
			assert_gt(cover, FILL_MIN_COVER, ("%s: the fill mask reaches only "
				+ "%.2f of its own DARK chassis, so the renderer's body lift "
				+ "cannot reach it and the creature arrives as a bright outline "
				+ "around nothing") % [kind, cover])
			if float(dark) / float(solid) > 0.35:
				chassis_heavy += 1
		if bright > 0:
			var bt: float = bright_touched / float(bright)
			assert_lt(bt, FILL_MAX_OVER_BRIGHT, ("%s: the fill mask sits at %.2f "
				+ "over its own BRIGHT pixels — the core it was drawn with gets "
				+ "painted over") % [kind, bt])
			lifted += 1
	# Both halves must have had something to bite on, or this test asserted a
	# property of an empty set — the exact shape of the false green that let a
	# whole suite "pass" last wave with its precondition never met.
	assert_gt(lifted, 6, "fewer than seven walkers have any bright pixel at all, "
		+ "so the 'spares the hot parts' half of this test asserted almost nothing")
	assert_gt(chassis_heavy, 8, "fewer than nine walkers are mostly dark chassis, "
		+ "so the 'lifts the body' half of this test asserted almost nothing")


## THE RIM IS AN EDGE, NOT A SECOND SILHOUETTE. On the smallest creature in the
## roster (a 22x13 drift hound) a two-pixel band is most of the body; on the
## largest it is a hairline. Both are still edges — but a rim that covers the
## whole body makes the fill invisible and puts the contrast entirely in one
## flat colour.
func test_the_rim_is_a_band_around_the_edge() -> void:
	for kind: StringName in _walkers():
		var src: Image = (f.agent(kind)["texture"] as ImageTexture).get_image()
		var rim: Image = LcnSpriteFactory._extract_rim(src)
		var solid: int = 0
		var band: int = 0
		var interior_hit: int = 0
		for y: int in src.get_height():
			for x: int in src.get_width():
				if src.get_pixel(x, y).a < LcnSpriteFactory.MASK_SOLID:
					# Nothing outside the body may be painted: the band is INNER,
					# so it shares the figure's destination rect exactly.
					assert_lt(rim.get_pixel(x, y).a, 0.02,
						"%s: the rim paints outside its own silhouette at %d,%d"
						% [kind, x, y])
					continue
				solid += 1
				if rim.get_pixel(x, y).a > 0.02:
					band += 1
					# Deep interior: every neighbour within two pixels is solid.
					if _deep(src, x, y):
						interior_hit += 1
		assert_gt(band, 0, "%s has no rim band at all" % kind)
		assert_eq(interior_hit, 0, ("%s: the rim reaches %d pixels of deep "
			+ "interior — that is a fill, not a contour") % [kind, interior_hit])


static func _deep(src: Image, x: int, y: int) -> bool:
	for dy: int in range(-2, 3):
		for dx: int in range(-2, 3):
			var nx: int = x + dx
			var ny: int = y + dy
			if nx < 0 or ny < 0 or nx >= src.get_width() or ny >= src.get_height():
				return false
			if src.get_pixel(nx, ny).a < LcnSpriteFactory.MASK_SOLID:
				return false
	return true


## THE CHASSIS AND THE PLAIN, held against each other as numbers.
##
## `_hide`'s old constants put every enemy at about 5% luminance on ground the
## graded frame renders at 8–15% (`artifacts/P13/frames/night_foes.png`, and now
## the `ground` column of `tests/render/night_contrast.tscn`). This test does not
## re-litigate that — the renderer's ground-keyed lift is what carries the night
## — but it does refuse to let the baked art drift back to a value that has
## nothing left underneath the lift.
func test_the_chassis_is_a_material_not_a_hole() -> void:
	var l: float = LcnSpriteFactory.chassis_luma()
	assert_gt(l, 0.07, ("the shared enemy chassis bakes at %.4f luminance. The "
		+ "night plain in this build's own frames measures 0.06–0.15, so at this "
		+ "value the creature is DARKER THAN THE GROUND IT STANDS ON by less "
		+ "than the frame's own film grain.") % l)
	assert_lt(l, 0.22, ("the shared enemy chassis bakes at %.4f luminance, which "
		+ "is mid-grey: by day, on snow the ground pass renders at 0.6–0.8, the "
		+ "faction stops reading as one dark thing.") % l)
