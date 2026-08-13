extends TestCase
## [P18] The number vocabulary. Boring, and load-bearing: every panel and every
## warning sentence is built out of these, so a regression here is a regression
## in eleven screens at once.


func test_numbers_read_like_numbers() -> void:
	assert_eq(LcnUiFormat.num(0.0), "0", "zero")
	assert_eq(LcnUiFormat.num(30.0), "30", "a round number keeps no decimals")
	assert_eq(LcnUiFormat.num(4.5), "4.5", "one decimal survives")
	assert_eq(LcnUiFormat.num(0.35), "0.35", "small values keep two")
	assert_eq(LcnUiFormat.num(1240.0), "1,240", "thousands are grouped")
	assert_eq(LcnUiFormat.num(-1240.0), "-1,240", "and so are negatives")
	assert_eq(LcnUiFormat.group(0), "0", "zero groups to itself")
	assert_eq(LcnUiFormat.group(1000000), "1,000,000", "millions group")


func test_signed_and_percent() -> void:
	assert_eq(LcnUiFormat.signed(12.0), "+12", "gains are marked")
	assert_eq(LcnUiFormat.signed(-12.0), "-12", "losses carry their own sign")
	assert_eq(LcnUiFormat.percent(0.5), "50%", "half")
	assert_eq(LcnUiFormat.percent(0.125, 1), "12.5%", "one decimal when asked")


func test_durations() -> void:
	assert_eq(LcnUiFormat.duration(45.0), "45 s", "under a minute reads in seconds")
	assert_eq(LcnUiFormat.duration(135.0), "2:15", "minutes and seconds")
	assert_eq(LcnUiFormat.duration(3870.0), "1:04:30", "hours when a run is long")
	assert_eq(LcnUiFormat.ticks_as_time(900), "45 s", "900 ticks at 20 Hz is 45 seconds")


func test_item_lists_are_sorted_and_named() -> void:
	var bill: Dictionary = {&"scrap": 45, &"iron_plate": 20}
	assert_eq(LcnUiFormat.items(bill), "20 Iron Plate, 45 Scrap", "sorted by id, titled")
	assert_eq(LcnUiFormat.items({}), "nothing", "an empty bill says so")


func test_compact_items_fit_a_list_row() -> void:
	var bill: Dictionary = {&"scrap": 45, &"iron_plate": 20, &"steel_plate": 40}
	assert_eq(LcnUiFormat.items_compact(bill), "20 iron · 45 scrap · 40 steel",
		"a palette row has 140 pixels, not 400")
	assert_eq(LcnUiFormat.short_item(&"copper_coil"), "copper", "first word, lower case")


func test_names_sort_by_text_not_by_pointer() -> void:
	# Godot compares StringName by pointer. Everything ordered in this part goes
	# through sorted_names precisely because `keys.sort()` does not do this.
	var sorted: Array[StringName] = LcnUiFormat.sorted_names(
		[&"zinc", &"iron_plate", &"aluminium", &"coal"])
	assert_eq(String(sorted[0]), "aluminium", "alphabetical, first")
	assert_eq(String(sorted[3]), "zinc", "alphabetical, last")


func test_foreign_reads_never_crash_on_a_missing_field() -> void:
	assert_eq(LcnUiFormat.as_text(null), "", "a missing string reads as empty")
	assert_eq(LcnUiFormat.as_number(null), 0.0, "a missing number reads as zero")
	assert_eq(LcnUiFormat.as_int(null), 0, "and as an integer zero")
	assert_false(LcnUiFormat.as_flag(null), "a missing flag is false")
	assert_eq(String(LcnUiFormat.as_name(null)), "", "a missing id is empty")
	assert_eq(LcnUiFormat.as_text({}), "", "and a container is not a string")
	assert_eq(LcnUiFormat.as_number("nope"), 0.0, "nor is a word a number")
	assert_eq(LcnUiFormat.as_text(&"iron"), "iron", "a real value still passes through")
	assert_eq(LcnUiFormat.as_number(3), 3.0, "and so does a real number")


func test_prose_lists() -> void:
	assert_eq(LcnUiFormat.prose_list(PackedStringArray(["a"])), "a", "one")
	assert_eq(LcnUiFormat.prose_list(PackedStringArray(["a", "b"])), "a and b", "two")
	assert_eq(LcnUiFormat.prose_list(PackedStringArray(["a", "b", "c"])), "a, b and c", "three")
	assert_eq(LcnUiFormat.prose_list(PackedStringArray(["a", "b"]), "or"), "a or b", "a chosen conjunction")


func test_footprint_and_bearing() -> void:
	assert_eq(LcnUiFormat.footprint(Vector2i.ONE), "1 x 1 tile", "the single tile case")
	assert_eq(LcnUiFormat.footprint(Vector2i(3, 2)), "3 x 2  (6 tiles)", "area is spelled out")
	assert_eq(LcnUiFormat.bearing(Vector2i(0, 0), Vector2i(0, 0)), "right here", "no distance")
	assert_eq(LcnUiFormat.bearing(Vector2i(0, 0), Vector2i(10, 0)), "10 tiles east", "+x is east")
	assert_eq(LcnUiFormat.bearing(Vector2i(0, 0), Vector2i(0, -6)), "6 tiles north", "-y is north")
	assert_eq(LcnUiFormat.bearing(Vector2i(4, 4), Vector2i(3, 4)), "1 tile west", "singular tile")


func test_category_names() -> void:
	assert_eq(LcnUiFormat.category_name(&"defense"), "Defence", "the game speaks British")
	assert_eq(LcnUiFormat.category_name(&"deep_storage"), "Deep Storage", "unknown ids still read")
