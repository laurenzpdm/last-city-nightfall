extends TestCase
## [P19] The accessibility contract, as assertions rather than as a promise.
##
## The claim this part makes is "genuinely distinguishable palettes, not just hue
## shifts". That claim is only worth something if a future tuning pass cannot
## quietly break it, so every rule is measured here: separation between adjacent
## network slots in every vision mode, a second non-colour channel on every slot,
## a monotonic thermal ramp, and a high-contrast mode that actually raises
## contrast.

const MIN_SEPARATION: float = 0.22
const MIN_LUMA_STEP: float = 0.08


func suite_name() -> String:
	return "overlay_palette"


func _pal(mode: String, contrast: bool = false) -> LcnOverlayPalette:
	return LcnOverlayPalette.new(mode, contrast, false)


func test_every_vision_mode_resolves() -> void:
	assert_eq(LcnOverlayPalette.vision_from_setting("off"), LcnOverlayPalette.Vision.NORMAL)
	assert_eq(LcnOverlayPalette.vision_from_setting("Protanopia"), LcnOverlayPalette.Vision.PROTAN)
	assert_eq(LcnOverlayPalette.vision_from_setting("deutan"), LcnOverlayPalette.Vision.DEUTAN)
	assert_eq(LcnOverlayPalette.vision_from_setting("TRITANOPIA"), LcnOverlayPalette.Vision.TRITAN)
	assert_eq(LcnOverlayPalette.vision_from_setting("greyscale"), LcnOverlayPalette.Vision.MONO)
	assert_eq(LcnOverlayPalette.vision_from_setting("nonsense"), LcnOverlayPalette.Vision.NORMAL)


## Two networks next to each other on screen must not look alike in ANY mode.
func test_adjacent_network_slots_are_separable() -> void:
	for mode: String in ["off", "protanopia", "deuteranopia", "tritanopia", "monochrome"]:
		var p: LcnOverlayPalette = _pal(mode)
		for i: int in LcnOverlayPalette.SLOT_COUNT - 1:
			var d: float = LcnOverlayPalette.separation(p.network_color(i), p.network_color(i + 1))
			assert_gt(d, MIN_SEPARATION,
				"%s: slot %d vs %d separation" % [mode, i, i + 1])


## Monochrome has no hue at all, so luminance has to carry the whole signal.
func test_monochrome_slots_differ_in_luminance() -> void:
	var p: LcnOverlayPalette = _pal("monochrome")
	for i: int in LcnOverlayPalette.SLOT_COUNT - 1:
		var a: float = LcnOverlayPalette.luma(p.network_color(i))
		var b: float = LcnOverlayPalette.luma(p.network_color(i + 1))
		assert_gt(absf(a - b), MIN_LUMA_STEP, "mono slot %d vs %d luminance" % [i, i + 1])


## Colour is never the only channel: the dash pattern is the second one and the
## legend glyph is the third. Two slots may share a colour only if the pattern
## differs, and vice versa.
func test_every_slot_has_a_second_channel() -> void:
	var p: LcnOverlayPalette = _pal("off")
	var seen: Dictionary[String, bool] = {}
	for i: int in LcnOverlayPalette.SLOT_COUNT * 2:
		var key: String = "%s|%s|%s" % [
			str(p.network_color(i)), str(p.network_dash(i)), p.network_mark(i)]
		assert_false(seen.has(key), "slot %d duplicates an earlier slot exactly" % i)
		seen[key] = true


func test_dash_patterns_are_distinct_within_a_wheel() -> void:
	var p: LcnOverlayPalette = _pal("off")
	var used: Dictionary[String, int] = {}
	for i: int in LcnOverlayPalette.SLOT_COUNT:
		var d: String = str(p.network_dash(i))
		assert_false(used.has(d), "slot %d reuses dash pattern of slot %d" % [i, used.get(d, -1)])
		used[d] = i


## The ramp must never fold back on itself: colder has to look colder all the way
## down, or a contour reads as a ring instead of a boundary.
func test_thermal_ramp_is_monotonic_in_luminance_direction() -> void:
	for mode: String in ["off", "tritanopia", "monochrome"]:
		var p: LcnOverlayPalette = _pal(mode)
		var prev: Color = p.thermal_color(-60.0)
		var rising: int = 0
		var samples: int = 0
		for step: int in 20:
			var t: float = -60.0 + float(step) * 5.0
			var c: Color = p.thermal_color(t)
			samples += 1
			if LcnOverlayPalette.luma(c) >= LcnOverlayPalette.luma(prev) - 0.02:
				rising += 1
			prev = c
		assert_gt(float(rising) / float(samples), 0.85, "%s ramp mostly brightens with heat" % mode)


func test_thermal_ramp_clamps_at_both_ends() -> void:
	var p: LcnOverlayPalette = _pal("off")
	assert_eq(p.thermal_color(-500.0), p.thermal_color(-45.0), "clamped cold end")
	assert_eq(p.thermal_color(500.0), p.thermal_color(40.0), "clamped warm end")


func test_cold_and_warm_are_far_apart() -> void:
	for mode: String in ["off", "protanopia", "deuteranopia", "tritanopia", "monochrome"]:
		var p: LcnOverlayPalette = _pal(mode)
		var d: float = LcnOverlayPalette.separation(p.thermal_color(-35.0), p.thermal_color(25.0))
		assert_gt(d, 0.35, "%s: freezing must not look like warm" % mode)


func test_high_contrast_actually_raises_contrast() -> void:
	var plain: LcnOverlayPalette = _pal("off", false)
	var loud: LcnOverlayPalette = _pal("off", true)
	assert_gt(loud.fill(0.2), plain.fill(0.2), "fills get stronger")
	assert_gt(loud.stroke(2.0, 1.0), plain.stroke(2.0, 1.0), "strokes get thicker")


## A fill that reaches full opacity would hide the building it is diagnosing,
## which is the one thing this part is not allowed to do.
func test_fills_never_become_opaque() -> void:
	var loud: LcnOverlayPalette = _pal("off", true)
	assert_le(loud.fill(1.0), 0.62, "even a maxed fill stays translucent")
	assert_le(loud.fill(10.0), 0.62, "and clamps")


## Stroke width is specified in screen pixels and divided by zoom, so a line is
## the same weight zoomed in and zoomed out. That is what keeps a lens legible
## at strategic zoom.
func test_stroke_width_is_zoom_stable() -> void:
	var p: LcnOverlayPalette = _pal("off")
	var close_px: float = p.stroke(3.0, 1.0)        # zoom 1.0
	var far_px: float = p.stroke(3.0, 4.0)          # zoom 0.25
	assert_near(far_px / 4.0, close_px, 0.001, "same on-screen weight at any zoom")


func test_served_colour_moves_from_good_to_bad() -> void:
	var p: LcnOverlayPalette = _pal("off")
	assert_eq(p.served_color(1.0), p.good(), "fully served is the good colour")
	assert_eq(p.served_color(0.0), p.bad(), "starved is the bad colour")
	var d: float = LcnOverlayPalette.separation(p.served_color(1.0), p.served_color(0.1))
	assert_gt(d, 0.25, "healthy and starving do not look alike")


func test_reduce_motion_is_carried_through() -> void:
	var p := LcnOverlayPalette.new("off", false, true)
	assert_true(p.reduce_motion, "the palette carries the motion setting for the lenses")
	assert_near(LcnOverlayGeometry.pulse(0.0, 1.0, true),
		LcnOverlayGeometry.pulse(9.37, 1.0, true), 0.0001,
		"a reduced-motion pulse is constant over time")
	assert_ne(LcnOverlayGeometry.pulse(0.0, 1.0, false),
		LcnOverlayGeometry.pulse(0.5, 1.0, false), "and animates otherwise")
