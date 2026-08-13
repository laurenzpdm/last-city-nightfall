extends TestCase
## [P22] Can a human see a dilemma and answer it?
##
## This is the suite that would have caught the build-menu phase. Everything
## else in tests/narrative/ proves the winter is CORRECT; this proves it is
## REACHABLE, which is a different claim and the one that was worth 4.2/10.
##
## It builds the real presenter, puts it in the real scene tree, raises a real
## dilemma, reads the text off the real Labels, presses the real Button, and
## checks the simulation acted on it. Nothing is mocked, and `is_inside_tree()`
## is asserted rather than assumed, because an `add_child` Godot refused is the
## exact failure mode that hid behind a green gate for a whole phase.

var world: SimFixture
var card: LcnNarrativeCard = null
var _forced: bool = false


func before_all() -> void:
	LcnNarrativeBootstrap.hook()


func setup() -> void:
	world = SimFixture.new(7).start()
	LcnNarrativeBootstrap.ensure()
	_forced = LcnLayers.force_install
	# The gate can only run a suite headless, and a presenter that stands down
	# without a display server would make this whole suite vacuous.
	LcnLayers.force_install = true
	LcnNarrativeBootstrap.reset()
	LcnNarrativeBootstrap.hook()
	card = LcnNarrativeBootstrap.install_card()


func teardown() -> void:
	if card != null and is_instance_valid(card):
		card.get_parent().remove_child(card)
		card.free()
	card = null
	LcnLayers.force_install = _forced
	LcnNarrativeBootstrap.reset()
	LcnNarrativeBootstrap.hook()
	world.stop()


func test_the_card_is_actually_in_the_scene_tree() -> void:
	assert_not_null(card, "nothing draws events, so every dilemma decides itself")
	assert_true(card.is_inside_tree(),
		"the card was created and never parented — an orphan is not an interface")
	assert_eq(card.layer, LcnNarrativeCard.LAYER)
	assert_true(card.is_in_group(LcnNarrativeCard.GROUP))


func test_installing_twice_does_not_produce_two_cards() -> void:
	var again: LcnNarrativeCard = LcnNarrativeBootstrap.install_card()
	assert_eq(again, card, "a second install must find the first one")
	var found: int = 0
	for node: Node in card.get_tree().get_nodes_in_group(LcnNarrativeCard.GROUP):
		found += 1
	assert_eq(found, 1, "%d presenters in the tree" % found)


func test_a_dilemma_reaches_the_screen_with_its_price_on_it() -> void:
	_raise(&"the_frozen_column")
	card._refresh()
	assert_true(card._panel.visible, "a decision is waiting and nothing is drawn")
	assert_eq(card._title.text, "A Column on the Rim Road")
	assert_gt(float(card._body.text.length()), 200.0, "the body is empty")
	assert_ge(float(card._because.get_child_count()), 1.0,
		"the card does not tell the player what caused it")
	var texts: PackedStringArray = _option_texts()
	assert_has(texts, "Open the gate")
	assert_has(texts, "Keep the gate shut")
	var joined: String = "\n".join(_all_text(card._options))
	assert_has(joined, "COSTS", "the price is not printed before it is paid")
	assert_has(joined, "GAINS", "the other side of the trade is not printed")


func test_the_causes_on_screen_carry_live_numbers() -> void:
	_raise(&"the_frozen_column")
	card._refresh()
	var joined: String = "\n".join(_all_text(card._because))
	assert_has(joined, "(", "no live value reached the card")
	assert_true(_has_digit(joined), "the reasons on screen are wordless")


func test_pressing_a_button_changes_the_simulation() -> void:
	_raise(&"the_frozen_column")
	card._refresh()
	var n: NarrativeSystem = world.system(&"narrative") as NarrativeSystem
	var citizens: SimSystem = Sim.get_system(&"citizens")
	assert_not_null(citizens, "this test needs [P05]")
	var before: int = int(citizens.call("population"))
	var button: Button = _button_labelled("Open the gate")
	assert_not_null(button, "the option is not a thing a mouse can press")
	button.emit_signal("pressed")
	world.run(3)
	assert_gt(float(int(citizens.call("population"))), float(before),
		"nineteen people were let in and the city did not grow")
	assert_empty(_card_ids(n), "the answered card is still waiting")


func test_a_notice_can_be_read_and_dismissed() -> void:
	_raise(&"the_first_law")
	card._refresh()
	var button: Button = _button_labelled("Read")
	assert_not_null(button, "a notice with no way to dismiss it blocks the queue")
	button.emit_signal("pressed")
	world.run(3)
	assert_has_not(_card_ids(world.system(&"narrative") as NarrativeSystem), "the_first_law")


func test_the_ticker_shows_what_the_city_is_saying() -> void:
	world.run(3000)
	card._refresh()
	assert_gt(float(card._ticker.text.length()), 20.0,
		"nothing overheard reaches the screen")


func test_the_card_draws_nothing_when_nothing_is_waiting() -> void:
	var n: NarrativeSystem = world.system(&"narrative") as NarrativeSystem
	n.pending.clear()
	card._refresh()
	assert_false(card._panel.visible, "an empty card is drawn over the city")


# =========================================================================
#  helpers
# =========================================================================

func _raise(id: StringName) -> void:
	Sim.submit_command({"system": &"narrative", "op": "raise", "event": id})
	world.run(2)
	var n: NarrativeSystem = world.system(&"narrative") as NarrativeSystem
	# Put it at the front: the suite is about the presenter, not about priority.
	for i: int in n.pending.size():
		if String(n.pending[i]["id"]) == String(id):
			var card_data: Dictionary = n.pending[i]
			n.pending.remove_at(i)
			n.pending.insert(0, card_data)
			return


func _card_ids(n: NarrativeSystem) -> PackedStringArray:
	var out := PackedStringArray()
	for c: Dictionary in n.pending:
		out.append(String(c["id"]))
	return out


func _option_texts() -> PackedStringArray:
	var out := PackedStringArray()
	for b: Button in _buttons(card._options):
		out.append(b.text)
	return out


func _button_labelled(text: String) -> Button:
	for b: Button in _buttons(card._options):
		if b.text == text:
			return b
	return null


func _buttons(root: Node) -> Array[Button]:
	var out: Array[Button] = []
	for child: Node in root.get_children():
		var b := child as Button
		if b != null:
			out.append(b)
		out.append_array(_buttons(child))
	return out


func _all_text(root: Node) -> PackedStringArray:
	var out := PackedStringArray()
	for child: Node in root.get_children():
		var l := child as Label
		if l != null:
			out.append(l.text)
		var b := child as Button
		if b != null:
			out.append(b.text)
		out.append_array(_all_text(child))
	return out


func _has_digit(s: String) -> bool:
	for i: int in 10:
		if s.contains(str(i)):
			return true
	return false
