extends TestCase
## [P22] The system, against a real world.
##
## This suite deliberately does NOT declare `requires_systems(["narrative"])`.
## That contract skips a suite whose dependency has not landed, and the thing
## most likely to break about this part is the thing that puts it into the tick
## at all — a skip there would be a silent green over exactly the failure that
## matters. If the system is not in the world, these tests go red.

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
#  it is in the tick at all
# =========================================================================

func test_the_system_is_in_the_world() -> void:
	assert_not_null(narrative(),
		"nothing installed [P22] into Sim.systems; every event below is unreachable")
	assert_has(world.system_names(), "narrative")


func test_it_ticks_after_everything_it_reads() -> void:
	var n: NarrativeSystem = narrative()
	assert_eq(n.order, NarrativeDefs.SYSTEM_ORDER)
	var seen_before: bool = false
	for s: SimSystem in Sim.systems:
		if s == n:
			assert_true(seen_before, "narrative must tick after society")
			return
		if s.system_name() == &"society":
			seen_before = true


func test_it_loaded_the_authored_events() -> void:
	var n: NarrativeSystem = narrative()
	assert_ge(float(n.events.size()), 20.0, "no events reached the system")
	assert_eq(n.content_problems, 0, "content failed validation at load")


func test_it_serializes_into_the_run() -> void:
	world.run(40)
	var state: Dictionary = world.state()
	assert_has(state["systems"] as Dictionary, "narrative",
		"the harness state dump must contain the winter")
	var mine: Dictionary = (state["systems"] as Dictionary)["narrative"]
	for key: String in ["chapter", "events_fired", "journal", "facts", "flags"]:
		assert_has(mine, key)


func test_it_publishes_metrics() -> void:
	world.run(40)
	var m: Dictionary = world.metrics()
	for key: String in ["narrative.chapter", "narrative.events_fired",
			"narrative.pending", "narrative.journal"]:
		assert_has(m, key)


# =========================================================================
#  the world is actually read
# =========================================================================

func test_the_fact_table_is_filled_from_the_simulation() -> void:
	world.run(60)
	var n: NarrativeSystem = narrative()
	assert_gt(n.fact(&"day"), 0.0, "the day is never read")
	assert_gt(n.fact(&"hope"), 0.0, "hope is never read")
	assert_gt(n.fact(&"population"), 0.0, "the population is never read")
	for key: StringName in NarrativeDefs.fact_keys():
		assert_true(n.world.facts.has(key),
			"fact '%s' is declared and never filled" % String(key))


func test_a_missing_part_is_recorded_rather_than_read_as_zero() -> void:
	world.run(20)
	var n: NarrativeSystem = narrative()
	assert_true(n.world.has(&"citizens"),
		"this build has [P05]; the world scan should say so")
	assert_ne(n.world.source_list(), "nothing yet")


# =========================================================================
#  the campaign spine
# =========================================================================

func test_the_opening_beat_arrives_on_the_first_day() -> void:
	world.run(NarrativeDefs.SAMPLE_EVERY + 1)
	var n: NarrativeSystem = narrative()
	assert_ge(float(n.chapter_index), 0.0, "the campaign never started")
	assert_eq(String(n.chapter()["key"]), "the_column_stopped")
	assert_ge(float(n.pending.size()), 1.0, "the opening is not in front of the player")


func test_the_opening_card_carries_its_cause() -> void:
	world.run(NarrativeDefs.SAMPLE_EVERY + 1)
	var card: Dictionary = narrative().top_card()
	assert_eq(String(card["category"]), "beat")
	assert_not_empty(card["causes"], "a beat with no stated cause is a cutscene")
	assert_gt(float(String(card["body"]).length()), 200.0)


func test_chapters_only_go_forward() -> void:
	world.run(600)
	var n: NarrativeSystem = narrative()
	var high: int = n.chapter_index
	world.run(600)
	assert_ge(float(n.chapter_index), float(high), "the winter went backwards")


# =========================================================================
#  events fire on state, and say so
# =========================================================================

func test_an_event_fires_and_names_the_state_that_caused_it() -> void:
	# Drive the city into a state an authored event is written for, through the
	# same command path a player uses, and check that the card quotes it.
	world.run(40)
	var n: NarrativeSystem = narrative()
	var before: int = n._events_fired
	Sim.submit_command({"system": &"narrative", "op": "raise", "event": &"the_grid_split"})
	world.run(2)
	assert_gt(float(n._events_fired), float(before), "the event never fired")
	var found: Dictionary = {}
	for card: Dictionary in n.pending_cards():
		if String(card["id"]) == "the_grid_split":
			found = card
	assert_not_empty(found, "the card is not waiting on the player")
	assert_not_empty(found["causes"], "the card does not say why it arrived")
	assert_has(String((found["causes"] as Array)[0]), "(",
		"a cause must carry the live number in it")


func test_a_dilemma_is_answered_through_the_command_path() -> void:
	world.run(40)
	var n: NarrativeSystem = narrative()
	Sim.submit_command({"system": &"narrative", "op": "raise", "event": &"the_delegation"})
	world.run(2)
	var card: Dictionary = _card(n, "the_delegation")
	assert_not_empty(card, "the delegation never arrived")
	assert_size(card["options"], 2)
	var resolved: int = n._dilemmas_resolved
	Narrative.choose(&"the_delegation", 0)
	world.run(2)
	assert_eq(n._dilemmas_resolved, resolved + 1, "the answer did nothing")
	assert_empty(_card(n, "the_delegation"), "the card is still on the pile")


func test_an_answer_costs_what_the_card_said_it_would() -> void:
	world.run(40)
	var n: NarrativeSystem = narrative()
	var society: SimSystem = Sim.get_system(&"society")
	assert_not_null(society, "this test needs [P06]")
	Sim.submit_command({"system": &"narrative", "op": "raise", "event": &"the_delegation"})
	world.run(2)
	var before: float = float(society.call("discontent"))
	Narrative.choose(&"the_delegation", 0)
	# One tick to apply the choice, one for the society nudge queued behind it.
	world.run(4)
	assert_lt(float(society.call("discontent")), before,
		"'Go out and speak to them' promises the crowd goes home; discontent did not move")


func test_a_deadline_decides_itself_and_says_who_decided() -> void:
	world.run(40)
	var n: NarrativeSystem = narrative()
	Sim.submit_command({"system": &"narrative", "op": "raise", "event": &"the_delegation"})
	world.run(2)
	var expired: int = n._expired
	# The delegation gives six hours. An hour is day_ticks/24.
	world.run(n._hour_ticks * 7)
	assert_eq(n._expired, expired + 1, "the deadline never ran out")
	assert_empty(_card(n, "the_delegation"))
	var closed: bool = false
	for row: Dictionary in n.journal.last(40):
		if String(row.get("id", "")) == "the_delegation" and row.has("choice"):
			closed = true
			assert_eq(String(row["choice"]), "Send the Watch to move them on",
				"the default must be the option nobody wants")
	assert_true(closed, "the chronicle does not record what happened")


func test_a_notice_scrolls_away_instead_of_blocking_the_queue() -> void:
	world.run(NarrativeDefs.SAMPLE_EVERY + 1)
	var n: NarrativeSystem = narrative()
	assert_ge(float(n.pending.size()), 1.0)
	world.run(n._hour_ticks * int(NarrativeDefs.LINGER_BEAT_HOURS + 2.0))
	for card: Dictionary in n.pending:
		assert_ne(String(card["id"]), "the_column_stopped",
			"an unread notice is holding a slot forever")


func test_the_pile_never_grows_past_the_ceiling() -> void:
	world.run(4000)
	assert_le(float(narrative().pending.size()), float(NarrativeDefs.PENDING_MAX),
		"a city that hands you nine decisions has handed you none")


func test_an_event_marked_once_fires_once() -> void:
	world.run(40)
	var n: NarrativeSystem = narrative()
	Sim.submit_command({"system": &"narrative", "op": "raise", "event": &"the_grid_split"})
	world.run(2)
	Narrative.acknowledge(&"the_grid_split")
	world.run(2)
	var count: int = int(n._fire_count.get(&"the_grid_split", 0))
	world.run(400)
	assert_le(float(int(n._fire_count.get(&"the_grid_split", 0))), float(count + 1),
		"a cooldown is being ignored")


func test_a_dilemma_cannot_be_dismissed() -> void:
	world.run(40)
	var n: NarrativeSystem = narrative()
	Sim.submit_command({"system": &"narrative", "op": "raise", "event": &"the_delegation"})
	world.run(2)
	assert_false(n.acknowledge(&"the_delegation"),
		"a decision must not be dismissable")
	assert_not_empty(_card(n, "the_delegation"))


# =========================================================================
#  the small writing
# =========================================================================

func test_the_city_says_something_while_you_play() -> void:
	world.run(3000)
	var n: NarrativeSystem = narrative()
	assert_gt(float(n._flavour_said), 0.0, "the city is silent")
	assert_not_empty(n.journal.recent_feed(4))


func test_a_bank_does_not_repeat_until_it_has_been_round() -> void:
	var n: NarrativeSystem = narrative()
	var lines: Array[String] = NarrativeFlavour.bank(NarrativeFlavour.BANK_LOG)
	var seen: Dictionary[String, bool] = {}
	for i: int in lines.size():
		var line: String = n._draw(NarrativeFlavour.BANK_LOG, lines)
		assert_false(seen.has(line), "the ledger repeated itself after %d lines" % i)
		seen[line] = true


func test_flavour_is_gated_on_the_world() -> void:
	# The storm bank must be silent when nothing is blowing.
	var n: NarrativeSystem = narrative()
	world.run(40)
	assert_eq(n.fact(&"storm_active"), 0.0, "this test assumes clear weather")
	for gate: Dictionary in NarrativeFlavour.gates():
		if StringName(gate["bank"]) != NarrativeFlavour.BANK_STORM:
			continue
		for c: NarrativeCondition in (gate["all_of"] as Array[NarrativeCondition]):
			assert_false(c.holds(n.world.facts),
				"the storm bank would speak with no storm")


# =========================================================================
#  the ending
# =========================================================================

func test_the_account_is_available_before_the_end() -> void:
	world.run(200)
	var r: Dictionary = narrative().reckoning()
	assert_eq(String(r["outcome"]), "unfinished")
	assert_gt(float(String(r["text"]).length()), 300.0, "the account is a stub")


func _card(n: NarrativeSystem, id: String) -> Dictionary:
	for card: Dictionary in n.pending_cards():
		if String(card["id"]) == id:
			return card
	return {}
