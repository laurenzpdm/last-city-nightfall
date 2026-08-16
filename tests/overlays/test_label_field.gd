extends TestCase
## [P19] The arbiter that decides which words get onto the world.
##
## `run_lens_density.tscn` is the suite that counts a real frame of a real lens.
## This one asks the smaller question underneath it: does the rule itself hold,
## for inputs a real frame would take twenty minutes of night to produce? Each
## test here names one of the five rules and one of the defects a critic counted
## on screen at zoom 0.70.

var f: LcnLabelField


func suite_name() -> String:
	return "overlay_label_field"


func setup() -> void:
	f = LcnLabelField.new()
	f.begin(Rect2(0.0, 0.0, 1000.0, 1000.0), 1.0, 12, [])


## `at` is the top-left; every box here is 100x20, the size of a chip.
func _chip(x: float, y: float) -> Rect2:
	return Rect2(x, y, 100.0, 20.0)


# ================================================================  rule 1  ==

func test_a_word_off_the_edge_is_not_a_word() -> void:
	assert_false(f.request(_chip(4000.0, 4000.0), "GRID 3", LcnLabelField.Rank.IDENTITY),
		"nothing outside the visible world is placed")
	assert_eq(f.chips.size(), 0)
	assert_eq(int(f.stats()["culled_offscreen"]), 1, "and it says why")


# ================================================================  rule 2  ==

## `build.png`: `= GRID 3 0/0 heat/s NO SOURCE` printed across the clock panel,
## and `| GRID 1 47/47 heat/s` on the "2:21" numeral. ARCHITECTURE.md §3.
func test_nothing_is_drawn_on_the_clock() -> void:
	var clock := Rect2(400.0, 0.0, 300.0, 200.0)
	f.begin(Rect2(0.0, 0.0, 1000.0, 1000.0), 1.0, 12, [clock] as Array[Rect2])
	assert_false(f.request(_chip(450.0, 100.0), "= GRID 3   0/0 heat/s   NO SOURCE",
		LcnLabelField.Rank.IDENTITY), "a lens badge does not get the clock's pixels")
	assert_eq(int(f.stats()["culled_chrome"]), 1)
	assert_eq(f.chrome_hits(), 0, "and nothing placed is standing on chrome")
	assert_true(f.request(_chip(50.0, 100.0), "= GRID 3   0/0 heat/s   NO SOURCE",
		LcnLabelField.Rank.IDENTITY), "the same badge is fine over the world")


## A verdict that merely comes NEAR a panel is refused too: a plate touching the
## clock's rim is a plate a player reads as part of the clock.
func test_the_keep_out_has_a_margin() -> void:
	var panel := Rect2(400.0, 0.0, 300.0, 200.0)
	f.begin(Rect2(0.0, 0.0, 1000.0, 1000.0), 1.0, 12, [panel] as Array[Rect2])
	assert_false(f.request(_chip(302.0, 100.0), "FROZEN  -24°C", LcnLabelField.Rank.VERDICT),
		"a chip ending 2 px short of the panel is still refused")
	assert_true(f.request(_chip(280.0, 100.0), "FROZEN  -24°C", LcnLabelField.Rank.VERDICT),
		"clear air is clear air")


# ================================================================  rule 3  ==

## `SURVIVAL LINE -10°C` was stamped three times on ONE closed contour.
func test_a_contour_is_named_once() -> void:
	var placed: int = 0
	for i: int in 8:
		if f.request(_chip(0.0, float(i) * 60.0), "SURVIVAL LINE  -10°C",
				LcnLabelField.Rank.IDENTITY, 1):
			placed += 1
	assert_eq(placed, 1, "one line, one name, however many times the lens asks")
	assert_eq(f.count_of("SURVIVAL LINE  -10°C"), 1)


## A caller that genuinely wants two says two, and gets exactly two.
func test_copies_is_the_callers_declaration_and_it_is_honoured() -> void:
	var placed: int = 0
	for i: int in 8:
		if f.request(_chip(0.0, float(i) * 60.0), "OUT OF FUEL",
				LcnLabelField.Rank.VERDICT, 2):
			placed += 1
	assert_eq(placed, 2)


## The ladder of 22 "building" chips did not repeat one STRING — a clustered
## chip reads "building ×22" and its neighbour "building ×3". They are the same
## thing being named twice, so the key is what is deduplicated, not the text.
func test_two_different_counts_of_the_same_problem_are_one_thing() -> void:
	assert_true(f.request(_chip(0.0, 0.0), "building  ×22", LcnLabelField.Rank.AMBIENT,
		1, "building"))
	assert_false(f.request(_chip(0.0, 300.0), "building  ×3", LcnLabelField.Rank.AMBIENT,
		1, "building"), "different text, same fact, one chip")


## The backstop under rule 3. The coverage lens files every turret's range under
## one key and asks for eight, which is right until four turrets have the same
## reach — and then the frame reads "9 tiles" four times. Found in a REAL run at
## zoom 1.00 by `tests/boot/run_reachability.tscn`, after this suite was already
## green at the three zooms it measures. A cap the caller cannot raise.
func test_one_string_never_appears_more_than_twice_however_many_copies_were_asked_for() -> void:
	f.begin(Rect2(0.0, 0.0, 100000.0, 100000.0), 1.0, 12, [])
	var placed: int = 0
	for i: int in 8:
		if f.request(Rect2(float(i) * 200.0, 0.0, 100.0, 20.0), "9 tiles",
				LcnLabelField.Rank.FIGURE, 8, "range"):
			placed += 1
	assert_eq(placed, LcnLabelField.MAX_SAME_TEXT, "eight asked for, two drawn")
	assert_le(float(f.worst_repeat()), float(LcnLabelField.MAX_SAME_TEXT))
	# And the key's own allowance still works for genuinely different readings.
	assert_true(f.request(Rect2(9000.0, 0.0, 100.0, 20.0), "12 tiles",
		LcnLabelField.Rank.FIGURE, 8, "range"), "a different reading is a different word")


# ================================================================  rule 4  ==

## "30°C" over "no crew", "27°C" over "building". The frame the critic counted
## had 41 chips and they were printed through each other.
func test_no_two_words_ever_overlap() -> void:
	for i: int in 40:
		# Deliberately stacked four pixels apart — the freeze lens asking for a
		# temperature on every building in a dense district.
		f.request(_chip(100.0, 100.0 + float(i) * 4.0), "%d°C" % (10 + i),
			LcnLabelField.Rank.AMBIENT, 40, "temperature")
	assert_eq(f.overlap_count(), 0, "measured over what was placed, not asserted from the rule")
	assert_le(float(f.chips.size()), 3.0, "and the pile becomes a handful")


## A badge, a gauge or a glyph takes its pixels without spending a word, and a
## verdict cannot then be printed across the icon it is explaining.
func test_a_reserved_mark_is_not_a_chip_but_it_is_still_occupied() -> void:
	f.reserve(Rect2(100.0, 100.0, 40.0, 40.0))
	assert_eq(f.chips.size(), 0, "a mark is not a word")
	assert_false(f.request(_chip(110.0, 110.0), "FROZEN", LcnLabelField.Rank.VERDICT),
		"but it owns its pixels")
	assert_eq(int(f.stats()["culled_overlap"]), 1)


# ================================================================  rule 5  ==

func test_the_budget_falls_with_the_zoom() -> void:
	assert_eq(LcnLabelField.budget_for(0.50), 10)
	assert_eq(LcnLabelField.budget_for(0.60), 11)
	assert_eq(LcnLabelField.budget_for(0.70), 12)
	assert_gt(float(LcnLabelField.budget_for(1.60)), float(LcnLabelField.budget_for(0.50)),
		"leaning in earns more words, not fewer")
	assert_le(float(LcnLabelField.budget_for(9.0)), 20.0, "and it is capped either way")


func test_the_budget_is_a_hard_ceiling() -> void:
	f.begin(Rect2(0.0, 0.0, 100000.0, 100000.0), 1.0, 12, [])
	for i: int in 200:
		f.request(Rect2(float(i) * 200.0, 0.0, 100.0, 20.0), "verdict %d" % i,
			LcnLabelField.Rank.VERDICT, 1)
	assert_eq(f.chips.size(), 12, "twelve words at zoom 0.70, and not a thirteenth")


## THE RULE THAT MAKES THE OTHERS SAFE. An ambient chip asked for first must not
## be the reason a verdict asked for later has nowhere to go — draw order is an
## accident of which loop a lens happens to run first, and it decided the frame.
func test_ambient_chips_cannot_crowd_out_a_verdict() -> void:
	f.begin(Rect2(0.0, 0.0, 100000.0, 100000.0), 1.0, 12, [])
	for i: int in 60:
		f.request(Rect2(float(i) * 200.0, 0.0, 100.0, 20.0), "%d°C" % i,
			LcnLabelField.Rank.AMBIENT, 60, "temperature")
	var ambient: int = f.chips.size()
	assert_le(float(ambient), 3.0, "a quarter of a 12-word frame, at most")
	var verdicts: int = 0
	for j: int in 20:
		if f.request(Rect2(float(j) * 200.0, 500.0, 100.0, 20.0), "FROZEN %d" % j,
				LcnLabelField.Rank.VERDICT, 1):
			verdicts += 1
	assert_ge(float(verdicts), 9.0, "and the verdicts still get the rest of the frame")


func test_quotas_are_monotonic_and_never_zero() -> void:
	for b: int in [5, 10, 12, 20]:
		var last: int = 0
		for r: int in LcnLabelField.RANK_COUNT:
			var q: int = LcnLabelField.quota_for(b, r)
			assert_ge(float(q), 1.0, "budget %d rank %d is never a shut door" % [b, r])
			assert_ge(float(q), float(last), "a louder rank never gets less room")
			last = q
		assert_eq(LcnLabelField.quota_for(b, LcnLabelField.Rank.VERDICT), b,
			"and the loudest rank may use the whole frame")


# ==============================================================  the frame  ==

## The same requests in the same order always produce the same frame. A lens
## whose labels flickered as the camera drifted would be worse than one that
## shows too many.
func test_placement_is_deterministic() -> void:
	var run := func() -> String:
		var g := LcnLabelField.new()
		g.begin(Rect2(0.0, 0.0, 1000.0, 1000.0), 1.0, 12, [])
		for i: int in 50:
			g.request(Rect2(float(i % 7) * 90.0, float(i / 7) * 18.0, 100.0, 20.0),
				"chip %d" % i, i % LcnLabelField.RANK_COUNT, 4, "k%d" % (i % 5))
		return "|".join(g.chip_texts)
	assert_deterministic(run, "the same frame keeps the same words")


## The bypass the density suite uses to prove its own assertions bite. It has to
## actually record the mess, or the red it produces means nothing.
func test_the_audit_bypass_records_what_it_stops_enforcing() -> void:
	f.enforce = false
	for i: int in 40:
		assert_true(f.request(_chip(100.0, 100.0 + float(i) * 4.0), "%d°C" % i,
			LcnLabelField.Rank.AMBIENT, 1, "temperature"),
			"with the arbiter off, every word is drawn")
	assert_eq(f.chips.size(), 40)
	assert_gt(float(f.overlap_count()), 0.0,
		"and the overlaps it would have prevented are countable")


func test_stats_reports_every_reason_a_word_was_refused() -> void:
	for name: String in LcnLabelField.CULL_NAMES:
		assert_has(f.stats(), "culled_" + name, "every cull reason is reported")
	assert_has(f.stats(), "chips")
	assert_has(f.stats(), "overlaps")
	assert_has(f.stats(), "chrome_hits")
