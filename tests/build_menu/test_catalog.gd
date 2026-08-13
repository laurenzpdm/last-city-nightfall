extends TestCase
## [P18] The build palette's index: search, tabs, pins and the quickbar.
##
## These run against the REAL content in game/content/buildings/, not against a
## fixture, because the thing being tested is "does typing three letters find
## the building a player meant" and a mock cannot answer that.

var world: SimFixture = null
var catalog: LcnBuildCatalog = null


func requires_systems() -> PackedStringArray:
	return PackedStringArray(["build"])


func setup() -> void:
	world = SimFixture.new(7).start()
	catalog = LcnBuildCatalog.new()
	catalog.rebuild(world.system(&"build"))


func teardown() -> void:
	world.stop()


func test_it_indexes_every_definition() -> void:
	var build: SimSystem = world.system(&"build")
	assert_eq(catalog.size(), (build.call(&"all_defs") as Array).size(),
		"every building definition reaches the palette")
	assert_true(catalog.has(&"coal_generator"), "the generator is in the book")
	assert_not_null(catalog.entry(&"coal_generator"), "and it resolves to an entry")
	assert_eq(catalog.entry(&"coal_generator").display_name, "Coal Generator", "with its authored name")


func test_categories_are_in_city_growth_order() -> void:
	var cats: Array[StringName] = catalog.categories()
	assert_not_empty(cats, "content declares categories")
	assert_eq(cats[0], &"power", "power comes first — nothing else matters without heat")
	var seen_power: int = cats.find(&"power")
	var seen_defense: int = cats.find(&"defense")
	if seen_defense >= 0:
		assert_lt(float(seen_power), float(seen_defense), "you make heat before you defend it")


func test_entries_sort_by_tier_then_author_order() -> void:
	var view: Array[LcnBuildCatalog.Entry] = catalog.view(&"power", "")
	assert_not_empty(view, "the power tab has content")
	for i: int in range(1, view.size()):
		var a: LcnBuildCatalog.Entry = view[i - 1]
		var b: LcnBuildCatalog.Entry = view[i]
		var ordered: bool = a.tier < b.tier \
			or (a.tier == b.tier and a.sort_order <= b.sort_order)
		assert_true(ordered, "%s before %s" % [a.display_name, b.display_name])


func test_typing_finds_the_obvious_thing_first() -> void:
	var hits: Array[LcnBuildCatalog.Entry] = catalog.view(LcnBuildCatalog.TAB_ALL, "coal")
	assert_not_empty(hits, "'coal' matches something")
	assert_eq(String(hits[0].id), "coal_generator", "and the generator is the first answer")

	var pipes: Array[LcnBuildCatalog.Entry] = catalog.view(LcnBuildCatalog.TAB_ALL, "pipe")
	assert_not_empty(pipes, "'pipe' matches the mains")
	assert_eq(String(pipes[0].id), "heat_pipe", "the plain pipe outranks the insulated one")


func test_fuzzy_initials_work() -> void:
	var hits: Array[LcnBuildCatalog.Entry] = catalog.view(LcnBuildCatalog.TAB_ALL, "hgb")
	var found: bool = false
	for e: LcnBuildCatalog.Entry in hits:
		if e.id == &"housing_block":
			found = true
			break
	assert_true(found, "'hgb' reaches Housing Block by subsequence")


func test_search_ignores_the_tab() -> void:
	# A player who types "rad" wants the radiator, not "no results in Storage".
	var hits: Array[LcnBuildCatalog.Entry] = catalog.view(&"storage", "radiator")
	assert_not_empty(hits, "a query searches the whole catalogue")
	assert_eq(String(hits[0].id), "warmth_radiator", "and finds it")


func test_scoring_ladder_is_ordered() -> void:
	var exact: int = LcnBuildCatalog.match_score("Coal Generator", "coal_generator", "", "coal generator")
	var prefix: int = LcnBuildCatalog.match_score("Coal Generator", "coal_generator", "", "coal")
	var word: int = LcnBuildCatalog.match_score("Coal Generator", "coal_generator", "", "gen")
	var inside: int = LcnBuildCatalog.match_score("Coal Generator", "coal_generator", "", "enera")
	var fuzzy: int = LcnBuildCatalog.match_score("Coal Generator", "coal_generator", "", "clgn")
	assert_gt(float(exact), float(prefix), "exact beats prefix")
	assert_gt(float(prefix), float(word), "prefix beats word start")
	assert_gt(float(word), float(inside), "word start beats a substring")
	assert_gt(float(inside), float(fuzzy), "a substring beats a subsequence")
	assert_eq(LcnBuildCatalog.match_score("Coal Generator", "coal_generator", "", "zzz"), 0,
		"nonsense matches nothing")


func test_locked_buildings_are_shown_and_flagged() -> void:
	var locked: Array[LcnBuildCatalog.Entry] = []
	for e: LcnBuildCatalog.Entry in catalog.view(LcnBuildCatalog.TAB_ALL, ""):
		if e.is_locked():
			locked.append(e)
	if locked.is_empty():
		skip("no content is gated behind research in this build")
		return
	var target: LcnBuildCatalog.Entry = locked[0]
	assert_true(String(target.unlock_id) != "", "a locked entry names its gate")

	world.cmd_now({"system": &"build", "op": "grant_unlock", "unlock": String(target.unlock_id)})
	catalog.rebuild(world.system(&"build"))
	assert_true(catalog.entry(target.id).unlocked, "granting the unlock opens it in the palette")


func test_pins_and_recents_feed_the_quickbar() -> void:
	assert_empty(catalog.quickbar_ids(), "a fresh catalogue has an empty quickbar")
	assert_true(catalog.toggle_favourite(&"heat_pipe"), "pinning reports the new state")
	assert_true(catalog.is_favourite(&"heat_pipe"), "and it sticks")
	catalog.note_used(&"coal_generator")
	catalog.note_used(&"housing_block")
	var quick: Array[StringName] = catalog.quickbar_ids()
	assert_eq(String(quick[0]), "heat_pipe", "pins come first")
	assert_eq(String(quick[1]), "housing_block", "then the most recent placement")
	assert_eq(String(quick[2]), "coal_generator", "then the one before that")
	assert_false(catalog.toggle_favourite(&"heat_pipe"), "toggling again unpins")


func test_recent_list_is_an_mru_without_duplicates() -> void:
	catalog.note_used(&"heat_pipe")
	catalog.note_used(&"wall")
	catalog.note_used(&"heat_pipe")
	var recent: Array[StringName] = catalog.recent_ids()
	assert_eq(String(recent[0]), "heat_pipe", "the last thing placed is first")
	assert_eq(recent.count(&"heat_pipe"), 1, "and it appears exactly once")


func test_state_round_trips() -> void:
	catalog.toggle_favourite(&"wall")
	catalog.note_used(&"the_hearth")
	var saved: Dictionary = catalog.to_dict()
	var fresh := LcnBuildCatalog.new()
	fresh.rebuild(world.system(&"build"))
	fresh.from_dict(saved)
	assert_true(fresh.is_favourite(&"wall"), "pins survive a save")
	assert_eq(String(fresh.recent_ids()[0]), "the_hearth", "so does the recent list")


func test_unknown_ids_are_dropped_on_load() -> void:
	catalog.from_dict({"favourites": ["a_building_that_never_existed"], "recent": ["nor_this"]})
	assert_empty(catalog.favourite_ids(), "a stale pin from an older build is discarded")
	assert_empty(catalog.recent_ids(), "and so is a stale recent entry")


func _query_snapshot() -> Array:
	var out: Array = []
	var fresh := LcnBuildCatalog.new()
	fresh.rebuild(world.system(&"build"))
	for e: LcnBuildCatalog.Entry in fresh.view(LcnBuildCatalog.TAB_ALL, "he"):
		out.append("%s:%d" % [String(e.id), e.score])
	return out


func test_the_view_is_deterministic() -> void:
	assert_deterministic(_query_snapshot, "the same query produces the same list every time")


func test_it_survives_a_missing_build_system() -> void:
	var orphan := LcnBuildCatalog.new()
	orphan.rebuild(null)
	assert_eq(orphan.size(), 0, "no build system means an empty palette, not a crash")
	assert_empty(orphan.view(LcnBuildCatalog.TAB_ALL, "coal"), "and searching it is safe")
	assert_eq(String(orphan.tabs()[0]["id"]), String(LcnBuildCatalog.TAB_ALL),
		"the All tab still exists so the panel has something to draw")
