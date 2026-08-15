class_name NarrativeCampaign
extends RefCounted
## The spine of the winter, and the account it renders at the end.
##
## A chapter is not a timer either. Each one opens when the world says it has
## opened: the first night arrives when [P09] says it is night, the Great Frost
## chapter opens when a Great Frost is actually blowing, the last chapter opens
## when the escalation curve has run out of room. Chapters only ever go forward,
## so a run's shape is stable even when the weather is not.
##
## The chapter index is published into the fact table as `chapter`, which is how
## an authored event in game/content/events/ can say "only in the long cold"
## without knowing anything about this file.
##
## THE ENDING. `reckoning()` is the Frostpunk question asked with this run's own
## numbers: the city stood, and here is the ledger of what standing cost. It
## reads the law book for what was signed, the death toll for what it did, and
## this part's own chronicle for what the player chose when nobody was forcing
## them. It never scolds and it never congratulates. It counts.

# =========================================================================
#  the chapters
# =========================================================================

class Chapter extends RefCounted:
	var key: StringName = &""
	var title: String = ""
	var subtitle: String = ""
	var prose: String = ""
	var conditions: Array[NarrativeCondition] = []

	func opens(facts: Dictionary) -> bool:
		for c: NarrativeCondition in conditions:
			if not c.holds(facts):
				return false
		return true


static func _chapter(key: StringName, title: String, subtitle: String, prose: String,
		conditions: Array[NarrativeCondition]) -> Chapter:
	var c := Chapter.new()
	c.key = key
	c.title = title
	c.subtitle = subtitle
	c.prose = prose
	c.conditions = conditions
	return c


## The opening beat's clause. It is `day >= 1` — always true, because the opening
## is the opening — and it is worded, because the card prints it to the player.
static func _opening_condition() -> NarrativeCondition:
	var c := NarrativeCondition.make(&"day", NarrativeDefs.Cmp.GE, 1.0)
	c.phrasing = ("It is day {value}. The column stopped here because there was "
		+ "nowhere further to stop.")
	return c


## Index 0 is the opening and always holds. Everything after it needs the world
## to have got there.
static func chapters() -> Array[Chapter]:
	var out: Array[Chapter] = []

	out.append(_chapter(&"the_column_stopped", "The Column Stopped Here",
		"Day one, before the light goes",
		"The survey called this place Caldera Nine. It was the ninth vent the "
		+ "column found still breathing under the ice, and the first one wide "
		+ "enough to stand a generator in. That is the entire reason there are "
		+ "people here and not eleven hours further on.\n\n"
		+ "The sleds are unpacked. The Hearth is lit and it is the only thing "
		+ "for four hundred miles that is warm on purpose. Nobody has decided "
		+ "yet whether this is a camp or a city, and it will not be decided by "
		+ "anyone saying it out loud. It will be decided by what is standing "
		+ "when the light comes back.",
		# `day >= 1` is the gate, and the gate is right: index 0 always holds.
		# What was wrong was letting the card SAY it. Every condition is printed
		# under BECAUSE, so the first card in the game explained itself with
		# "The day (1) is at or above 1." — a tautology, on the opening beat,
		# under an otherwise excellent piece of prose, making a good feature look
		# foolish on its most trivial case.
		#
		# `phrasing` is [P22]'s own override for exactly this, and the rule it
		# protects still holds: the sentence carries the live number, and
		# tests/narrative asserts that a beat without a stated cause is a
		# cutscene. So the clause keeps its number and stops being a truism.
		[_opening_condition()]))

	out.append(_chapter(&"the_first_night", "The First Night",
		"The dark comes up the caldera wall",
		"The temperature outside is {temperature} and falling, and the light is "
		+ "going out of the rim the way water goes out of a cracked pot.\n\n"
		+ "Whatever is out there does not need to see. We do. Every lamp on the "
		+ "wall is oil we are not burning in the morning, and every hour the "
		+ "Hearth runs hard is coal that does not exist yet. The people on "
		+ "Kettle Row are going to find out tonight whether the pipes reach "
		+ "them, and there is no longer time to do anything about the answer.",
		[NarrativeCondition.make(&"is_night", NarrativeDefs.Cmp.GE, 1.0)]))

	out.append(_chapter(&"what_the_survey_missed", "What the Survey Did Not Say",
		"The second day, and the numbers arrive",
		"The survey was written in a summer, by people who were paid to be "
		+ "optimistic and who then went home. The ore assays poorer than the "
		+ "page says. The timber within reach is four days of hauling and there "
		+ "is a bottom to it. The vent is real and the vent is generous and "
		+ "everything else on that map is a hope somebody wrote down.\n\n"
		+ "{population} people are eating today. That number is now the number "
		+ "that everything else is measured against.",
		[NarrativeCondition.make(&"day", NarrativeDefs.Cmp.GE, 2.0)]))

	out.append(_chapter(&"the_great_frost", "The First Great Frost",
		"The weather stops being weather",
		"This is not a cold night. A cold night is something the Hearth argues "
		+ "with and usually wins. This is the air itself dropping out from "
		+ "under the city, and it will hold for as long as it holds.\n\n"
		+ "Everything that was marginal is now a decision. Every pipe that was "
		+ "nearly lagged is a pipe that is not lagged. Every person who was "
		+ "nearly housed is outside. The Frost does not take the weak first. It "
		+ "takes whoever you left at the end of the line.",
		[NarrativeCondition.make(&"storm_active", NarrativeDefs.Cmp.GE, 1.0)]))

	out.append(_chapter(&"the_long_cold", "The Long Cold",
		"It is no longer a bad week",
		"The city has stopped talking about when this ends. That happened "
		+ "quietly, over about two days, and nobody marked it.\n\n"
		+ "The dead now number {deaths}. The ledger has a column for it, which it "
		+ "did not have on the first day, because on the first day nobody thought "
		+ "the column would be needed often enough to rule a line for it. The "
		+ "Hearth runs. The wall holds or it does not. This is the shape of the "
		+ "rest of it.",
		[NarrativeCondition.make(&"era", NarrativeDefs.Cmp.GE, 2.0)]))

	out.append(_chapter(&"what_we_are_now", "What We Are Now",
		"The book has pages in it",
		"There is a Book of Laws in the Survey Hall with {laws_signed} pages "
		+ "signed in it, and every one of them was signed because the "
		+ "alternative was worse on the day. That is true. It is also true that "
		+ "nobody outside this caldera will ever have to weigh the day against "
		+ "the page.\n\n"
		+ "The people know what they agreed to. They agreed to it. They will "
		+ "also remember exactly who put it in front of them.",
		[NarrativeCondition.make(&"laws_signed", NarrativeDefs.Cmp.GE, 6.0),
			NarrativeCondition.make(&"day", NarrativeDefs.Cmp.GE, 4.0)]))

	out.append(_chapter(&"the_last_furnace", "The Last Furnace",
		"As cold as this place gets",
		"The curve has run out of worse. Whatever the sky is doing now is the "
		+ "most it can do, and the Hearth is the last thing in the caldera "
		+ "still making heat instead of losing it.\n\n"
		+ "Outside temperature {temperature}. Hope {hope}. If this city is here "
		+ "in the morning it will be because of decisions that were taken days "
		+ "ago by someone who could not see this far ahead, and if it is not, it "
		+ "will be for the same reason.",
		[NarrativeCondition.make(&"severity", NarrativeDefs.Cmp.GE, 0.9)]))

	return out


static func chapter_count() -> int:
	return chapters().size()


# =========================================================================
#  the reckoning
# =========================================================================

## The epilogue, assembled from this run and nothing else.
##
## `outcome` is &"held", &"lost" or &"unfinished". Everything else is counted,
## never asserted: the strongest sentence available is the one that only quotes
## the ledger back.
static func reckoning(outcome: StringName, facts: Dictionary, journal: NarrativeJournal,
		laws: Array[Dictionary], end_reason: String) -> Dictionary:
	var dead: int = int(facts.get(&"deaths", 0.0))
	var alive: int = int(facts.get(&"population", 0.0))
	var day: int = int(facts.get(&"day", 1.0))

	var cruel: PackedStringArray = PackedStringArray()
	var costly: PackedStringArray = PackedStringArray()
	var signed: int = 0
	for law: Dictionary in laws:
		if not bool(law.get("signed", false)):
			continue
		signed += 1
		var tags: Array = law.get("tags", [])
		if tags.has("cruel"):
			cruel.append(String(law.get("title", "")))
		elif tags.has("costly"):
			costly.append(String(law.get("title", "")))

	var hard_choices: int = 0
	for row: Dictionary in journal.entries:
		if String(row.get("kind", "")) == String(NarrativeDefs.CAT_DILEMMA) and row.has("choice"):
			hard_choices += 1

	var lines: PackedStringArray = PackedStringArray()
	lines.append(_verdict_line(outcome, day, alive, dead, end_reason))
	lines.append(_toll_line(facts, dead))
	lines.append(_law_line(signed, cruel, costly))
	lines.append(_choice_line(hard_choices, journal))
	lines.append(_closing_line(outcome, alive, dead, cruel.size()))

	return {
		"outcome": String(outcome),
		"title": _title_for(outcome),
		"day": day,
		"alive": alive,
		"dead": dead,
		"laws_signed": signed,
		"cruel_laws": _to_array(cruel),
		"costly_laws": _to_array(costly),
		"decisions": hard_choices,
		"end_reason": end_reason,
		"lines": _to_array(lines),
		"text": "\n\n".join(lines),
	}


static func _title_for(outcome: StringName) -> String:
	match outcome:
		&"held": return "The City Stood"
		&"lost": return "The City Did Not Stand"
	return "The Winter, So Far"


## The simulation's end reasons are single words on purpose, because [P06] logs
## them. An epilogue is not a log. Each one gets the sentence it deserves, and
## an unrecognised reason is quoted rather than guessed at.
static func _why_it_ended(reason: String) -> String:
	match reason:
		"exiled":
			return ("the council was put out of its own gate by the people it was "
				+ "keeping alive")
		"despair":
			return ("there was nobody left in the Nine who believed the next morning "
				+ "was worth getting up for")
		"extinct":
			return "there was nobody left at all"
		"":
			return "it stopped"
	return "the record gives it as '%s'" % reason


static func _verdict_line(outcome: StringName, day: int, alive: int, dead: int,
		end_reason: String) -> String:
	match outcome:
		&"held":
			return ("Caldera Nine was still standing on day %d. %s alive in it and "
				+ "%s not, and both of those numbers were produced by the same set "
				+ "of decisions.") % [day, _people(alive, true), _people(dead, true)]
		&"lost":
			return ("Caldera Nine ended on day %d, and it ended because %s. %s had "
				+ "already died before that, and %s there to see it.") % [
					day, _why_it_ended(end_reason), _people(dead, false),
					_people(alive, true)]
	return ("Day %d. %s alive, %s dead. The winter is not finished with this place "
		+ "and neither is this account.") % [day, _people(alive, false),
			_people(dead, false)]


## "1 person was" / "17 people were". A ledger that says "1 people" is a ledger
## nobody trusts with the rest of the numbers.
static func _people(n: int, with_verb: bool = false) -> String:
	var noun: String = "1 person" if n == 1 else "%d people" % n
	if not with_verb:
		return noun
	return noun + (" was" if n == 1 else " were")


static func _toll_line(facts: Dictionary, dead: int) -> String:
	if dead <= 0:
		return ("Nobody died. That is not luck and it is not mercy; it is the only "
			+ "line in this ledger that was entirely a choice, made early, and paid "
			+ "for in things that do not have names.")
	# [key, what one of them did, what several of them did]
	var causes: Array = [
		[&"deaths_cold", "froze", "froze"],
		[&"deaths_starvation", "starved", "starved"],
		[&"deaths_illness", "went with the fever", "went with the fever"],
		[&"deaths_injury", "died of an injury", "died of injuries"],
		[&"deaths_exhaustion", "was worked until they stopped",
			"were worked until they stopped"],
	]
	var parts: PackedStringArray = PackedStringArray()
	var only: String = ""
	for row: Array in causes:
		var n: int = int(facts.get(row[0] as StringName, 0.0))
		if n <= 0:
			continue
		parts.append("%d %s" % [n, String(row[1] if n == 1 else row[2])])
		if only == "":
			only = String(row[1])
	if parts.is_empty():
		return ("%s died and the ledger does not say of what, which is its own "
			+ "answer.") % _people(dead, false)
	# One death is a person, not a row in a table, and the sentence has to be
	# built as one or the epilogue reads like a spreadsheet at the worst moment.
	if dead == 1 and parts.size() == 1:
		return ("The one %s. They have a name, it is written down somewhere in the "
			+ "Nine, and it was read out at the kitchen by somebody who knew them.") % only
	return ("Of the %d: %s. Every one of them has a name written down somewhere in "
		+ "the Nine, and every one of those names was read out at the kitchen by "
		+ "somebody who knew them.") % [dead, _join_list(parts)]


static func _law_line(signed: int, cruel: PackedStringArray, costly: PackedStringArray) -> String:
	if signed <= 0:
		return ("The Book of Laws was never opened. Whatever this city became, it "
			+ "became without being ordered to, and it took longer, and it cost more "
			+ "in the only currency that was actually short.")
	var s: String = "One law was signed." if signed == 1 else "%d laws were signed." % signed
	if cruel.size() == 1:
		s += (" One of them carried a price that was paid by somebody who was not "
			+ "in the room: %s.") % cruel[0]
	elif cruel.size() > 1:
		s += (" %d of them carried a price that was paid by people who were not in "
			+ "the room: %s.") % [cruel.size(), _join_list(cruel)]
	if costly.size() > 0:
		s += " %s cost the city something it could measure: %s." % [
			"Others" if cruel.size() > 0 else "Some", _join_list(costly)]
	if cruel.is_empty():
		s += (" None of them were the kind you have to argue yourself into, which "
			+ "is a harder way to run a winter and is worth writing down.")
	return s


static func _choice_line(hard: int, journal: NarrativeJournal) -> String:
	if hard <= 0:
		return ("Nobody at the Survey Hall was ever handed a decision with two bad "
			+ "answers on it, which means either this was a short winter or somebody "
			+ "was quietly deciding things before they reached the door.")
	var latest: String = ""
	for i: int in range(journal.entries.size() - 1, -1, -1):
		var row: Dictionary = journal.entries[i]
		if String(row.get("kind", "")) == String(NarrativeDefs.CAT_DILEMMA) and row.has("choice"):
			latest = String(row.get("choice", ""))
			break
	var s: String = "One decision was taken with no good answer available." if hard == 1 \
		else "%d decisions were taken with no good answer available." % hard
	if latest != "":
		s += " The last of them was: %s." % latest
	s += " The people who lived with the outcome were not consulted on any of them, and knew it."
	return s


static func _closing_line(outcome: StringName, alive: int, dead: int, cruel: int) -> String:
	if outcome == &"lost":
		return ("The Hearth is cold. In some number of years the ice will close over "
			+ "the vent, and the survey mark on the north rim will still say NINE, and "
			+ "there will be nobody in the caldera who knows what it was counting.")
	if dead == 0 and cruel == 0:
		return ("There is nothing in this account that anybody has to be talked round "
			+ "to. That is rare enough that the next city to try this should be sent "
			+ "the ledger rather than the story.")
	if cruel > 0 and alive > 0:
		return ("The city survived. It is worth being precise about what that sentence "
			+ "means: %s alive, and the arrangement that kept them alive is written "
			+ "down, in order, in a book with your signature at the bottom of every "
			+ "page.") % _people(alive, true)
	return ("The city survived. Whether that was worth %s is not a question the "
		+ "ledger can settle, and it is the only question anybody in the Nine is "
		+ "going to ask about it afterwards.") % _people(dead, false)


static func _join_list(parts: PackedStringArray) -> String:
	if parts.is_empty():
		return ""
	if parts.size() == 1:
		return parts[0]
	var head: PackedStringArray = parts.slice(0, parts.size() - 1)
	return "%s and %s" % [", ".join(head), parts[parts.size() - 1]]


static func _to_array(s: PackedStringArray) -> Array:
	var out: Array = []
	for line: String in s:
		out.append(line)
	return out
