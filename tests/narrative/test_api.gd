extends TestCase
## [P22] The surface [P17], [P18], [P20] and [P23] are allowed to touch.
##
## Everything here has to be plain data. The moment a HUD has to hold a
## NarrativeEventDef to draw a card, this part owns a piece of the UI layer and
## the UI layer cannot be changed without changing the winter.

var world: SimFixture


func before_all() -> void:
	LcnNarrativeBootstrap.hook()


func setup() -> void:
	world = SimFixture.new(7).start()
	LcnNarrativeBootstrap.ensure()


func teardown() -> void:
	world.stop()


func narrative() -> NarrativeSystem:
	return world.system(&"narrative") as NarrativeSystem


# =========================================================================
#  plain data only
# =========================================================================

func test_the_facade_finds_the_system() -> void:
	assert_true(Narrative.available())
	assert_not_null(Narrative.system())


func test_a_card_is_plain_data() -> void:
	world.run(NarrativeDefs.SAMPLE_EVERY + 1)
	var cards: Array[Dictionary] = Narrative.pending()
	assert_not_empty(cards, "nothing is ever waiting, so nothing is ever drawn")
	for card: Dictionary in cards:
		for key: String in ["id", "category", "title", "lede", "body", "causes",
				"options", "hours_left", "day", "priority"]:
			assert_has(card, key, "a card without '%s' cannot be drawn" % key)
		assert_eq(typeof(card["causes"]), TYPE_ARRAY)
		assert_eq(typeof(card["options"]), TYPE_ARRAY)
		for line: Variant in card["causes"]:
			assert_eq(typeof(line), TYPE_STRING, "a cause must arrive as a sentence")


func test_options_arrive_with_their_price_already_worded() -> void:
	Sim.submit_command({"system": &"narrative", "op": "raise", "event": &"the_drop"})
	world.run(2)
	var found: Dictionary = {}
	for card: Dictionary in Narrative.pending():
		if String(card["id"]) == "the_drop":
			found = card
	assert_not_empty(found)
	for raw: Variant in found["options"]:
		var o: Dictionary = raw
		for key: String in ["index", "label", "body", "cost", "gain", "is_default"]:
			assert_has(o, key)
		assert_ne(String(o["cost"]).strip_edges(), "",
			"'%s' does not print what it costs" % String(o["label"]))


## No card, no chapter and no epilogue may contain a printf specifier. Sixty
## eight "String formatting error" lines in one visual run came from a widget
## that formatted a number at draw time; nothing here ever hands a renderer a
## number to format.
func test_nothing_the_ui_receives_carries_a_format_specifier() -> void:
	world.run(1200)
	var suspects: PackedStringArray = PackedStringArray()
	for card: Dictionary in Narrative.pending():
		suspects.append(String(card["title"]))
		suspects.append(String(card["body"]))
		suspects.append(String(card["lede"]))
		for line: Variant in card["causes"]:
			suspects.append(String(line))
	for row: Dictionary in Narrative.chronicle(40):
		suspects.append(String(row.get("text", "")))
	for row: Dictionary in Narrative.feed(20):
		suspects.append(String(row.get("text", "")))
	suspects.append(String(Narrative.reckoning().get("text", "")))
	for text: String in suspects:
		assert_has_not(text, "%s", "a format specifier reached the interface")
		assert_has_not(text, "%d", "a format specifier reached the interface")
		assert_has_not(text, "{", "an unfilled token reached the interface: %s"
			% text.substr(0, 60))


func test_the_chapter_is_readable_without_our_classes() -> void:
	world.run(NarrativeDefs.SAMPLE_EVERY + 1)
	var ch: Dictionary = Narrative.chapter()
	for key: String in ["index", "key", "title", "subtitle", "of"]:
		assert_has(ch, key)
	assert_gt(float(int(ch["of"])), 4.0)


func test_the_feed_and_the_chronicle_are_arrays_of_dictionaries() -> void:
	world.run(2400)
	for row: Dictionary in Narrative.feed(5):
		assert_has(row, "text")
		assert_has(row, "day")
	for row: Dictionary in Narrative.chronicle(5):
		assert_has(row, "title")
		assert_has(row, "causes")


func test_choosing_goes_through_the_command_queue() -> void:
	Sim.submit_command({"system": &"narrative", "op": "raise", "event": &"the_drop"})
	world.run(2)
	var n: NarrativeSystem = narrative()
	var before: int = n.pending.size()
	Narrative.choose(&"the_drop", 0)
	# Not applied yet: the whole point of the command path is that a click lands
	# at the top of the next tick, never mid-step.
	assert_eq(n.pending.size(), before, "the UI wrote simulation state directly")
	world.run(2)
	assert_eq(n.pending.size(), before - 1)


func test_needs_a_decision_only_when_something_has_options() -> void:
	var n: NarrativeSystem = narrative()
	n.pending.clear()
	assert_false(Narrative.needs_a_decision())
	Sim.submit_command({"system": &"narrative", "op": "raise", "event": &"the_first_law"})
	world.run(2)
	assert_false(Narrative.needs_a_decision(), "a notice is not a decision")
	Sim.submit_command({"system": &"narrative", "op": "raise", "event": &"the_drop"})
	world.run(2)
	assert_true(Narrative.needs_a_decision())


func test_flags_survive_a_decision_and_are_readable() -> void:
	Sim.submit_command({"system": &"narrative", "op": "raise", "event": &"the_drop"})
	world.run(2)
	assert_false(Narrative.flag(&"the_drop_is_open"))
	Narrative.choose(&"the_drop", 0)
	world.run(3)
	assert_true(Narrative.flag(&"the_drop_is_open"),
		"an outcome that other parts should be able to see did not stick")


# =========================================================================
#  persistence
# =========================================================================

func test_a_save_and_a_load_do_not_replay_the_winter() -> void:
	Sim.submit_command({"system": &"narrative", "op": "raise", "event": &"the_drop"})
	world.run(4)
	var n: NarrativeSystem = narrative()
	var fired: int = n._events_fired
	var entries: int = n.journal.entries.size()
	var waiting: int = n.pending.size()
	var blob: Dictionary = n.serialize()
	n.deserialize(blob)
	assert_eq(n._events_fired, fired, "loading a save counted the events again")
	assert_eq(n.journal.entries.size(), entries,
		"loading a save wrote the chronicle a second time")
	assert_eq(n.pending.size(), waiting, "the pile changed size across a load")
	var ids: PackedStringArray = PackedStringArray()
	for card: Dictionary in n.pending:
		ids.append(String(card["id"]))
	assert_has(ids, "the_drop", "the waiting decision was lost on load")


func test_a_restored_card_is_still_answerable() -> void:
	Sim.submit_command({"system": &"narrative", "op": "raise", "event": &"the_drop"})
	world.run(4)
	var n: NarrativeSystem = narrative()
	n.deserialize(n.serialize())
	var found: Dictionary = {}
	for card: Dictionary in n.pending_cards():
		if String(card["id"]) == "the_drop":
			found = card
	assert_not_empty(found)
	assert_size(found["options"], 2, "a restored card lost its options")
	assert_true(n.choose(&"the_drop", 1), "a restored card cannot be answered")
