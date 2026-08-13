extends TestCase
## [P18] The Book of Laws model.
##
## The interesting behaviour is FORECLOSURE: content states exclusive slots and
## conflicts, and a law screen that does not turn that into a sentence before
## the player signs has failed at the one job it has.

class FakeLaw extends Resource:
	@export var id: StringName = &""
	@export var title: String = ""
	@export var prose: String = ""
	@export var summary: String = ""
	@export var chapter: StringName = &""
	@export var slot: StringName = &""
	@export var sort_order: int = 0
	@export var cost: Dictionary = {}
	@export var upkeep: Dictionary = {}
	@export var requires: Array = []
	@export var forecloses: Array = []
	@export var effects: Array = []


class FakeRegistry extends RefCounted:
	var items: Array = []

	func all(category: String) -> Array:
		return items if category == "laws" else []


class FakeSociety extends RefCounted:
	var signed: Array = []
	var refuse: Dictionary = {}

	func enacted_laws() -> Array:
		return signed

	func can_enact(id: StringName) -> Dictionary:
		if refuse.has(id):
			return {"ok": false, "reason": String(refuse[id])}
		return {"ok": true}


func _law(id: String, title: String, slot: String = "") -> FakeLaw:
	var l := FakeLaw.new()
	l.id = StringName(id)
	l.title = title
	l.prose = "%s. The council writes it down and the city lives with it." % title
	l.chapter = &"order"
	l.slot = StringName(slot)
	l.cost = {&"timber": 40}
	return l


func _registry() -> FakeRegistry:
	var child_labour: FakeLaw = _law("child_labour", "Child Labour", "children")
	child_labour.effects = ["Every workshop gains a pair of small hands.", "Hope falls."]
	var child_shelters: FakeLaw = _law("child_shelters", "Child Shelters", "children")
	var soup: FakeLaw = _law("soup", "Soup")
	soup.requires = [&"child_labour"]
	soup.upkeep = {&"coal": 2}
	var reg := FakeRegistry.new()
	reg.items = [soup, child_shelters, child_labour]
	return reg


func _model(society: Object = null) -> LcnLawModel:
	var m := LcnLawModel.new()
	m.rebuild(society, _registry())
	return m


# ----------------------------------------------------------------- basics ----

func test_it_reads_the_prose_and_the_price() -> void:
	var m: LcnLawModel = _model()
	assert_eq(m.laws.size(), 3, "every law in the book")
	var law: LcnLawModel.LawRecord = m.law(&"child_labour")
	assert_ne(law.prose, "", "the authored text is carried through, in full")
	assert_eq(law.cost_label(), "40 Timber", "the price is spelled out")
	assert_size(law.effects, 2, "and the authored consequences survive")


func test_upkeep_is_kept_separate_from_the_signing_cost() -> void:
	var m: LcnLawModel = _model()
	assert_eq(LcnUiFormat.items(m.law(&"soup").upkeep), "2 Coal", "what it keeps costing")


# ----------------------------------------------------------- foreclosure -----

func test_an_exclusive_slot_forecloses_its_siblings() -> void:
	var m: LcnLawModel = _model()
	var labour: LcnLawModel.LawRecord = m.law(&"child_labour")
	assert_has(labour.forecloses_titles, "Child Shelters",
		"signing one law in a slot buries the other, and the screen must say which")
	assert_has(labour.weight_line(), "Child Shelters", "in a sentence, before the signature")


func test_foreclosure_is_symmetric() -> void:
	var m: LcnLawModel = _model()
	assert_has(m.law(&"child_shelters").forecloses_titles, "Child Labour",
		"the cost of a choice is visible from both sides of it")


func test_signing_closes_the_sibling() -> void:
	var society := FakeSociety.new()
	var m: LcnLawModel = _model(society)
	assert_eq(m.law(&"child_shelters").status, LcnLawModel.Status.AVAILABLE, "both are open")

	society.signed = [&"child_labour"]
	m.refresh_state(society)
	assert_eq(m.law(&"child_labour").status, LcnLawModel.Status.ENACTED, "one is signed")
	assert_eq(m.law(&"child_shelters").status, LcnLawModel.Status.FORECLOSED, "the other is gone")
	assert_has(m.law(&"child_shelters").blocked_reason, "Child Labour",
		"and the screen says what closed it")


func test_requirements_block_until_met() -> void:
	var society := FakeSociety.new()
	var m: LcnLawModel = _model(society)
	assert_eq(m.law(&"soup").status, LcnLawModel.Status.BLOCKED, "soup waits on its prerequisite")
	assert_has(m.law(&"soup").blocked_reason, "Child Labour", "which is named")

	society.signed = [&"child_labour"]
	m.refresh_state(society)
	assert_eq(m.law(&"soup").status, LcnLawModel.Status.AVAILABLE, "and opens once it is signed")


func test_the_society_system_can_refuse_on_its_own_terms() -> void:
	var society := FakeSociety.new()
	society.refuse[&"child_labour"] = "The council will not hear it before dawn."
	var m: LcnLawModel = _model(society)
	assert_eq(m.law(&"child_labour").status, LcnLawModel.Status.BLOCKED, "[P06] has the last word")
	assert_eq(m.law(&"child_labour").blocked_reason, "The council will not hear it before dawn.",
		"and its reason is shown verbatim")


func test_signed_count_and_chapters() -> void:
	var society := FakeSociety.new()
	society.signed = [&"child_labour"]
	var m: LcnLawModel = _model(society)
	assert_eq(m.signed_count(), 1, "one signature")
	assert_size(m.chapters(), 1, "one chapter in this fixture")
	assert_size(m.laws_in(&"order"), 3, "and it holds every law")


func test_the_enact_command_is_the_only_way_in() -> void:
	var cmd: Dictionary = LcnLawModel.enact_command(&"child_labour")
	assert_eq(String(cmd["system"]), "society", "addressed to [P06]")
	assert_eq(String(cmd["op"]), "enact_law", "with the enact op")
	assert_eq(String(cmd["law"]), "child_labour", "naming the law")


func test_an_empty_book_is_honest() -> void:
	var m := LcnLawModel.new()
	m.rebuild(null, null)
	assert_true(m.is_empty(), "no content, no laws")
	assert_false(m.has_system(), "and no system to sign them with")


func test_it_reads_a_book_published_by_the_system() -> void:
	var society := _CodeBook.new()
	var m := LcnLawModel.new()
	m.rebuild(society, null)
	assert_eq(m.laws.size(), 1, "a system that keeps its laws in code is read too")
	assert_eq(m.law(&"curfew").title, "Curfew", "with its title")
	assert_true(m.has_system(), "and signing is live")


class _CodeBook extends RefCounted:
	func book_of_laws() -> Array:
		return [{"id": "curfew", "title": "Curfew", "prose": "Nobody walks after dark."}]

	func enacted_laws() -> Array:
		return []
