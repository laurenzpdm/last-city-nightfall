extends TestCase
## [P06] The Book of Laws: the graph, the seal and the content itself.
##
## These tests are about the BOOK, not about the meters. They run against the
## real .tres content in game/content/laws, so a law that is added with a
## dangling prerequisite, a one sided exclusion or no cost at all fails here
## rather than silently removing a branch of the game from the player.

const HOUR: int = 400          ## ticks per in-world hour at the default day length
const DAY: int = 1

var book: LawBook = null


func requires_files() -> PackedStringArray:
	return PackedStringArray(["res://game/sim/society/law_book.gd"])


func setup() -> void:
	book = LawBook.new()
	book.load_from_registry()


# --- the content itself ------------------------------------------------------

func test_the_book_loads_clean() -> void:
	var fresh: LawBook = LawBook.new()
	var problems: PackedStringArray = fresh.load_from_registry()
	assert_empty(problems, "every law validates and the graph is sound: %s" % ", ".join(problems))


func test_the_book_is_big_enough_to_be_a_choice() -> void:
	assert_ge(float(book.count()), 24.0, "at least 24 laws in the book")
	assert_ge(float(book.laws_in_branch(SocietyDefs.BRANCH_TRUNK).size()), 10.0,
		"a shared trunk of hard decisions")
	assert_ge(float(book.laws_in_branch(SocietyDefs.BRANCH_ORDER).size()), 6.0, "an order branch")
	assert_ge(float(book.laws_in_branch(SocietyDefs.BRANCH_FAITH).size()), 6.0, "a faith branch")


func test_every_law_is_actually_written() -> void:
	for law: LawDef in book.all():
		assert_gt(float(law.prose.length()), 80.0, "%s has real prose" % String(law.id))
		assert_gt(float(law.argument_for.length()), 20.0, "%s has a case for" % String(law.id))
		assert_gt(float(law.argument_against.length()), 20.0, "%s has a case against" % String(law.id))
		assert_gt(float(law.signed_line.length()), 40.0, "%s says what the morning after looks like"
			% String(law.id))
		assert_ne(law.argument_for, law.argument_against, "%s argues both sides" % String(law.id))


func test_no_law_is_free() -> void:
	# The rule that keeps the book a book. If signing costs nothing then it is
	# a reward with extra steps and the player is not making a decision.
	for law: LawDef in book.all():
		var costs: bool = law.hope_on_sign < 0.0 or law.discontent_on_sign > 0.0 \
			or law.hope_rate < 0.0 or law.discontent_rate > 0.0 \
			or not law.provokes.is_empty() or not law.excludes.is_empty()
		if not costs:
			for f: StringName in law.approval.keys():
				if float(law.approval[f]) < 0.0:
					costs = true
					break
		assert_true(costs, "%s costs the player something" % String(law.id))


func test_every_law_can_be_reached() -> void:
	# Greedy closure over prerequisites, ignoring the seal and the calendar. A
	# law nobody can ever sign is dead content, and dead content in a moral
	# choice system is worse than none: it is a promise the game does not keep.
	var reached: Dictionary[StringName, bool] = {}
	var progress: bool = true
	while progress:
		progress = false
		for law: LawDef in book.all():
			if reached.has(law.id):
				continue
			var ok: bool = true
			for r: StringName in law.requires:
				if not reached.has(r):
					ok = false
					break
			if ok and not law.requires_any.is_empty():
				ok = false
				for r: StringName in law.requires_any:
					if reached.has(r):
						ok = true
						break
			if ok:
				reached[law.id] = true
				progress = true
	for law: LawDef in book.all():
		assert_true(reached.has(law.id), "%s is reachable from an empty book" % String(law.id))


func test_both_paths_lead_somewhere_final() -> void:
	assert_true(book.has(&"new_order"), "the order branch has an end state")
	assert_true(book.has(&"new_faith"), "the faith branch has an end state")
	var order_end: LawDef = book.get_law(&"new_order")
	var faith_end: LawDef = book.get_law(&"new_faith")
	assert_ge(float(order_end.tier), 7.0, "the order end state is deep in the book")
	assert_ge(float(faith_end.tier), 7.0, "the faith end state is deep in the book")


# --- the graph ---------------------------------------------------------------

func test_prerequisites_gate() -> void:
	assert_false(book.can_sign(&"extended_shift", 9, 0),
		"Extended Shift needs Emergency Shift first")
	var av: Dictionary = book.availability(&"extended_shift", 9, 0)
	assert_has(String(av["reason"]), "Emergency Shift", "and says so in words")
	_force_sign(&"emergency_shift", 0)
	assert_true(book.can_sign(&"extended_shift", 9, HOUR * 40), "now it is on the table")


func test_exclusions_are_symmetric_even_when_declared_once() -> void:
	# rite_of_ash declares that it excludes corpse_pits. corpse_pits says
	# nothing about rite_of_ash. Signing the pits must still shut the rite.
	var rite: LawDef = book.get_law(&"rite_of_ash")
	assert_has(rite.excludes, &"corpse_pits", "the rite declares the exclusion")
	var pits: LawDef = book.get_law(&"corpse_pits")
	assert_has_not(pits.excludes, &"rite_of_ash", "the pits do not declare it back")
	_force_sign(&"corpse_pits", 0)
	assert_true(book.is_foreclosed(&"rite_of_ash"), "and the rite is shut anyway")
	assert_true(book.is_foreclosed(&"named_graves"), "as are the graves")
	assert_true(book.is_foreclosed(&"snow_burial"), "and the snow")
	var av: Dictionary = book.availability(&"named_graves", 9, HOUR * 40)
	assert_has(String(av["reason"]), "The Pits", "the refusal names what closed it")


func test_the_book_records_what_you_shut() -> void:
	_force_sign(&"named_graves", 0)
	var closed: Array[StringName] = book.foreclosed_ids()
	assert_has(closed, &"corpse_pits", "the pits are gone")
	assert_has(closed, &"snow_burial", "so is the snow")
	assert_has_not(closed, &"care_house", "unrelated laws are untouched")


func test_the_fork_is_a_fork() -> void:
	assert_true(book.get_law(&"path_of_order").excludes.has(&"path_of_faith")
		or book.get_law(&"path_of_faith").excludes.has(&"path_of_order"),
		"the two paths exclude each other")
	_force_sign(&"path_of_faith", 0)
	assert_true(book.is_foreclosed(&"path_of_order"), "committing to one shuts the other")
	assert_true(book.is_foreclosed(&"martial_law"), "and everything downstream of it")
	assert_eq(String(book.committed_branch()), "faith", "the book knows which way you went")


func test_min_day_holds_the_deep_laws_back() -> void:
	assert_false(book.can_sign(&"path_of_order", 1, 0), "not on the first day")
	var deep: LawDef = book.get_law(&"new_order")
	assert_ge(float(deep.min_day), 5.0, "the end state is days away, not hours")


# --- the seal ----------------------------------------------------------------

func test_a_law_takes_time_to_come_into_force() -> void:
	var res: Dictionary = book.propose(&"care_house", 1, 100, HOUR)
	assert_true(bool(res["ok"]), "proposed")
	assert_eq(String(book.pending_id()), "care_house", "it is being argued")
	assert_null(book.advance(101, HOUR), "not in force one tick later")
	var law: LawDef = book.advance(100 + int(4.0 * HOUR), HOUR)
	assert_not_null(law, "in force after the debate")
	assert_true(book.is_signed(&"care_house"), "and recorded")


func test_only_one_law_is_argued_at_a_time() -> void:
	book.propose(&"care_house", 1, 100, HOUR)
	var second: Dictionary = book.propose(&"double_bunks", 1, 101, HOUR)
	assert_false(bool(second["ok"]), "the room is busy")
	assert_has(String(second["reason"]), "Care House", "and says what with")


func test_the_seal_has_to_dry() -> void:
	book.propose(&"care_house", 1, 100, HOUR)
	var t: int = 100 + int(4.0 * HOUR)
	book.advance(t, HOUR)
	assert_false(book.can_sign(&"double_bunks", 1, t + HOUR), "one hour later, no")
	assert_gt(float(book.cooldown_ticks_left(t)), 0.0, "there is a countdown")
	var later: int = t + int(SocietyDefs.SIGN_COOLDOWN_HOURS * float(HOUR)) + 1
	assert_true(book.can_sign(&"double_bunks", 1, later), "eighteen hours later, yes")


func test_withdrawing_clears_the_table() -> void:
	book.propose(&"care_house", 1, 100, HOUR)
	assert_eq(String(book.withdraw()), "care_house", "withdrawn")
	assert_eq(String(book.pending_id()), "", "nothing is being argued")
	assert_true(book.can_sign(&"double_bunks", 1, 101), "and the room is free again")


# --- the policy vector -------------------------------------------------------

func test_policy_offsets_sum_onto_the_default() -> void:
	assert_near(book.policy_value(&"work_hours"), 10.0, 0.001, "a plain day is ten hours")
	_force_sign(&"emergency_shift", 0)
	assert_near(book.policy_value(&"work_hours"), 14.0, 0.001, "Emergency Shift adds four")
	_force_sign(&"extended_shift", 1)
	assert_near(book.policy_value(&"work_hours"), 18.0, 0.001, "and Extended Shift another four")


func test_flags_are_set_membership() -> void:
	assert_false(book.policy_flag(SocietyDefs.FLAG_CHILD_LABOUR), "not by default")
	_force_sign(&"child_labour", 0)
	assert_true(book.policy_flag(SocietyDefs.FLAG_CHILD_LABOUR), "once signed")
	assert_false(book.policy_flag(SocietyDefs.FLAG_MARTIAL_LAW), "and only what was signed")


func test_the_dead_get_somewhere_to_go() -> void:
	assert_near(book.policy_value(&"corpse_capacity"), 0.0, 0.001, "nowhere, at first")
	_force_sign(&"corpse_pits", 0)
	assert_gt(book.policy_value(&"corpse_capacity"), 20.0, "the pits swallow a lot")


func test_relieved_and_provoked_grievances_are_tracked() -> void:
	_force_sign(&"corpse_pits", 0)
	assert_has(book.relieved_grievances(), &"dead_unburied", "the pits answer the dead")
	_force_sign(&"child_labour", 1)
	assert_has(book.provoked_grievances(), &"children", "and the children are a new problem")


# --- persistence -------------------------------------------------------------

func test_serialize_roundtrip() -> void:
	_force_sign(&"soup_ration", 10)
	_force_sign(&"corpse_pits", 20)
	book.propose(&"care_house", 9, 30, HOUR)
	var before: Dictionary = book.serialize()
	var other: LawBook = LawBook.new()
	other.load_from_registry()
	other.deserialize(before)
	assert_eq(other.serialize(), before, "a book survives a save")
	assert_eq(other.signed_ids(), book.signed_ids(), "in the same order")
	assert_near(other.policy_value(&"ration"), book.policy_value(&"ration"), 0.0001,
		"with the same policy")


# --- helpers -----------------------------------------------------------------

## Puts a law straight into force, bypassing the seal. Only the seal tests care
## about the seal; every other test wants the consequence, not the ceremony.
func _force_sign(id: StringName, tick: int) -> void:
	var law: LawDef = book.get_law(id)
	if law == null:
		fail("no such law '%s'" % String(id))
		return
	book._signed[id] = tick
	book._signed_order.append(id)
	book._dirty = true
