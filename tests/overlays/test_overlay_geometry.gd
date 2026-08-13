extends TestCase
## [P19] The maths behind the lenses, tested headlessly.
##
## The isoline the warmth lens draws, the dash pattern that animates flow, the
## leader line that connects a dying building to the tile choking it and the
## hatch that carries "frozen" without colour are all pure geometry. Testing
## them here means a screenshot only ever has to answer "does it look right",
## never "is it correct".

func suite_name() -> String:
	return "overlay_geometry"


# --- contour ---------------------------------------------------------------

## A field that is warm in the middle and cold at the edges must produce a
## CLOSED isoline: every vertex is shared by exactly two segment endpoints.
func test_contour_of_a_warm_blob_is_closed() -> void:
	var w: int = 16
	var h: int = 16
	var field := PackedFloat32Array()
	field.resize(w * h)
	for y: int in h:
		for x: int in w:
			var d: float = Vector2(float(x) - 7.5, float(y) - 7.5).length()
			field[y * w + x] = 20.0 - d * 4.0
	var out := PackedVector2Array()
	LcnOverlayGeometry.contour(field, w, h, 0.0, out)
	assert_gt(float(out.size()), 8.0, "the isoline exists")
	assert_eq(out.size() % 2, 0, "segments come in pairs")

	var degree: Dictionary[String, int] = {}
	for p: Vector2 in out:
		var key: String = "%.3f,%.3f" % [p.x, p.y]
		degree[key] = degree.get(key, 0) + 1
	var odd: int = 0
	for k: String in degree:
		if degree[k] % 2 == 1:
			odd += 1
	assert_eq(odd, 0, "a closed ring leaves no loose ends")


func test_contour_is_empty_when_the_level_is_never_crossed() -> void:
	var field := PackedFloat32Array()
	field.resize(64)
	field.fill(-20.0)
	var out := PackedVector2Array()
	LcnOverlayGeometry.contour(field, 8, 8, 0.0, out)
	assert_empty(out, "a uniformly freezing field has no survival line")


## The isoline has to sit where the interpolation says, not on a cell boundary,
## or the survival line reads a tile off from where the city actually dies.
func test_contour_interpolates_between_samples() -> void:
	var field := PackedFloat32Array([-10.0, 10.0, -10.0, 10.0])
	var out := PackedVector2Array()
	LcnOverlayGeometry.contour(field, 2, 2, 0.0, out)
	assert_eq(out.size(), 2, "one segment through the cell")
	assert_near(out[0].x, 0.5, 0.001, "halfway between -10 and +10")
	assert_near(out[1].x, 0.5, 0.001)


func test_contour_survives_a_degenerate_field() -> void:
	var out := PackedVector2Array()
	LcnOverlayGeometry.contour(PackedFloat32Array(), 0, 0, 0.0, out)
	LcnOverlayGeometry.contour(PackedFloat32Array([1.0]), 1, 1, 0.0, out)
	LcnOverlayGeometry.contour(PackedFloat32Array([1.0, 2.0]), 8, 8, 0.0, out)
	assert_empty(out, "no crash, no garbage")


# --- dashes ----------------------------------------------------------------

func test_dashes_cover_the_line_and_stay_inside_it() -> void:
	var out := PackedVector2Array()
	LcnOverlayGeometry.dashes(Vector2.ZERO, Vector2(100.0, 0.0), 6.0, 4.0, 0.0, out)
	assert_gt(float(out.size()), 10.0, "the run is dashed, not solid")
	for p: Vector2 in out:
		assert_between(p.x, -0.001, 100.001, "no dash escapes the segment")
		assert_near(p.y, 0.0, 0.001, "and none leaves the line")


## The phase is what makes heat visibly FLOW. Advancing it has to move the
## pattern along the line rather than redraw the same thing.
func test_dash_phase_moves_the_pattern() -> void:
	var a := PackedVector2Array()
	var b := PackedVector2Array()
	LcnOverlayGeometry.dashes(Vector2.ZERO, Vector2(100.0, 0.0), 6.0, 4.0, 0.0, a)
	LcnOverlayGeometry.dashes(Vector2.ZERO, Vector2(100.0, 0.0), 6.0, 4.0, 3.0, b)
	assert_ne(a, b, "a different phase draws a different pattern")


func test_zero_dash_is_a_solid_line() -> void:
	var out := PackedVector2Array()
	LcnOverlayGeometry.dashes(Vector2.ZERO, Vector2(50.0, 0.0), 0.0, 0.0, 0.0, out)
	assert_eq(out.size(), 2, "one segment")
	assert_eq(out[0], Vector2.ZERO)
	assert_eq(out[1], Vector2(50.0, 0.0))


func test_dashes_terminate_on_a_zero_length_run() -> void:
	var out := PackedVector2Array()
	LcnOverlayGeometry.dashes(Vector2(5.0, 5.0), Vector2(5.0, 5.0), 4.0, 4.0, 0.0, out)
	assert_empty(out)


# --- leader lines ----------------------------------------------------------

## The elbow starts at the victim and ends exactly on the culprit; the returned
## direction is what the arrowhead is drawn along.
func test_leader_connects_victim_to_culprit() -> void:
	var out := PackedVector2Array()
	var from := Vector2(0.0, 0.0)
	var to := Vector2(200.0, 60.0)
	var dir: Vector2 = LcnOverlayGeometry.leader(from, to, out)
	assert_eq(out.size(), 4, "two segments make the elbow")
	assert_eq(out[0], from, "starts on the building")
	assert_eq(out[3], to, "ends on the tile that is choking it")
	assert_near(dir.length(), 1.0, 0.001, "the arrow direction is normalised")


func test_leader_bends_along_the_dominant_axis() -> void:
	var wide := PackedVector2Array()
	LcnOverlayGeometry.leader(Vector2.ZERO, Vector2(300.0, 20.0), wide)
	assert_near(wide[1].y, 0.0, 0.001, "a mostly-horizontal run leaves horizontally")
	var tall := PackedVector2Array()
	LcnOverlayGeometry.leader(Vector2.ZERO, Vector2(20.0, 300.0), tall)
	assert_near(tall[1].x, 0.0, 0.001, "a mostly-vertical run leaves vertically")


# --- decoration ------------------------------------------------------------

func test_box_and_brackets_stay_on_the_rect() -> void:
	var r := Rect2(10.0, 20.0, 40.0, 30.0)
	var box := PackedVector2Array()
	LcnOverlayGeometry.box(r, box)
	assert_eq(box.size(), 8, "four sides")
	for p: Vector2 in box:
		assert_true(r.grow(0.001).has_point(p), "outline hugs the rect")
	var br := PackedVector2Array()
	LcnOverlayGeometry.brackets(r, 8.0, br)
	assert_eq(br.size(), 16, "two arms on each of four corners")
	for p2: Vector2 in br:
		assert_true(r.grow(0.001).has_point(p2), "brackets never overhang")


## Brackets must never meet in the middle of a one-tile building, or the mark
## becomes a filled box over the thing it is pointing at.
func test_brackets_shrink_on_a_tiny_rect() -> void:
	var r := Rect2(0.0, 0.0, 8.0, 8.0)
	var out := PackedVector2Array()
	LcnOverlayGeometry.brackets(r, 40.0, out)
	for p: Vector2 in out:
		assert_le(p.x, 4.0 + 0.001, "arms stay under half the width")


func test_hatch_fills_a_rect_without_leaving_it() -> void:
	var r := Rect2(5.0, 5.0, 40.0, 20.0)
	var out := PackedVector2Array()
	LcnOverlayGeometry.hatch(r, 6.0, out)
	assert_gt(float(out.size()), 4.0, "several strokes")
	for p: Vector2 in out:
		assert_between(p.x, 4.999, 45.001, "hatch stays inside horizontally")
		assert_between(p.y, 4.999, 25.001, "and vertically")


func test_ring_closes_on_itself() -> void:
	var out := PackedVector2Array()
	LcnOverlayGeometry.ring(Vector2(100.0, 100.0), 20.0, 16, out)
	assert_eq(out.size(), 32, "16 segments")
	assert_near(out[0].distance_to(out[out.size() - 1]), 0.0, 0.001, "the ring closes")
	for p: Vector2 in out:
		assert_near(p.distance_to(Vector2(100.0, 100.0)), 20.0, 0.001, "and is round")


func test_arrow_points_where_it_is_told() -> void:
	var out := PackedVector2Array()
	LcnOverlayGeometry.arrow(Vector2(50.0, 0.0), Vector2.RIGHT, 10.0, out)
	assert_eq(out.size(), 4, "two strokes")
	assert_eq(out[0], Vector2(50.0, 0.0), "both start at the tip")
	assert_eq(out[2], Vector2(50.0, 0.0))
	assert_lt(out[1].x, 50.0, "and trail behind it")


func test_cluster_key_buckets_by_district() -> void:
	assert_eq(LcnOverlayGeometry.cluster_key(Vector2(10.0, 10.0), 100.0), Vector2i(0, 0))
	assert_eq(LcnOverlayGeometry.cluster_key(Vector2(110.0, 10.0), 100.0), Vector2i(1, 0))
	assert_eq(LcnOverlayGeometry.cluster_key(Vector2(-10.0, -10.0), 100.0), Vector2i(-1, -1))


func test_direction_bits_match_the_vector_table() -> void:
	for d: int in 4:
		var v: Vector2i = LcnOverlayDefs.DIR_VECTORS[d]
		var bit: int = LcnOverlayDefs.dir_bit(Vector2i.ZERO, v)
		assert_eq(bit, 1 << d, "direction %s maps to bit %d" % [str(v), d])
	assert_eq(LcnOverlayDefs.dir_bit(Vector2i.ZERO, Vector2i.ZERO), 0, "no direction to itself")
