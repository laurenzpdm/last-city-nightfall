extends TestCase
## [P22] The writing, checked as a body of text rather than as 26 files.
##
## Three things this suite exists to make impossible:
##
## 1. An event that fires on nothing. Every trigger clause has to name a fact
##    the simulation actually measures, so "caused" is a property of the data
##    and not of the author's good intentions.
## 2. A dilemma with an obvious answer. Every option pays for itself, and no
##    option is better than its sibling on every axis at once.
## 3. A line that could be about anywhere. Flavour has to name something that
##    exists in this caldera, and the banned-word list catches the register that
##    generic grimdark falls into when nobody is looking.

## A line is about THIS city if it names one of these, or quotes a number.
const ANCHORS: Array[String] = [
	"hearth", "boiler", "pipe", "coal", "timber", "scrap", "iron", "stone",
	"ration", "bread", "soup", "kitchen", "bunk", "blanket", "canvas", "tarp",
	"gate", "wall", "watch", "turret", "shaft", "drift", "drill", "sled",
	"whistle", "ledger", "lamp", "ice", "snow", "frost", "rime", "caldera",
	"vent", "generator", "ash", "kettle", "drop", "stair", "survey", "rim",
	"sledway", "grate", "valve", "radiator", "furnace", "smelter", "workshop",
	"granary", "stove", "chimney", "smoke", "ember", "glove", "boot", "nine",
	"machine", "sorter", "ore", "shift", "foreman", "bowl", "queue", "scale",
	"congregation", "physician", "care house", "cart", "mast", "marker", "oil",
	"crew", "apprentice", "rope", "beam", "roof", "window", "floor", "cot",
	"lagging", "casing", "grain", "flour", "bark", "column", "map", "engineer",
	"clerk", "child", "children",
]

## Register, not vocabulary. Every one of these is a word that arrives when the
## writing has stopped being about a specific cold place and started being about
## a mood, and every one of them has been in a first draft of this file.
const BANNED: Array[String] = [
	"eldritch", "unspeakable", "ancient evil", "the void", "dark lord",
	"prophecy", "destiny", "chosen one", "unholy", "abomination", "cursed",
	"doom itself", "primordial", "otherworldly", "malevolent",
]

var _defs: Array[NarrativeEventDef] = []


func before_all() -> void:
	_defs.clear()
	for res: Resource in Registry.all("events"):
		var def := res as NarrativeEventDef
		if def != null:
			_defs.append(def)


# =========================================================================
#  the events
# =========================================================================

func test_the_events_are_actually_there() -> void:
	assert_ge(float(_defs.size()), 20.0,
		"game/content/events should hold the authored events; found %d" % _defs.size())


func test_every_event_validates() -> void:
	for def: NarrativeEventDef in _defs:
		var problems: PackedStringArray = def.validate()
		assert_empty(problems, "'%s': %s" % [String(def.id), ", ".join(problems)])


func test_every_id_is_unique() -> void:
	var seen: Dictionary[StringName, bool] = {}
	for def: NarrativeEventDef in _defs:
		assert_false(seen.has(def.id), "duplicate event id '%s'" % String(def.id))
		seen[def.id] = true


func test_every_trigger_names_a_measured_fact() -> void:
	for def: NarrativeEventDef in _defs:
		assert_not_empty(def.all_of,
			"'%s' has no conditions, so it is a timer" % String(def.id))
		for c: NarrativeCondition in def.all_of + def.any_of + def.none_of:
			assert_true(NarrativeDefs.has_fact(c.fact),
				"'%s' triggers on '%s', which NarrativeWorld never fills" % [
					String(def.id), String(c.fact)])


func test_every_dilemma_has_two_priced_options() -> void:
	var dilemmas: int = 0
	for def: NarrativeEventDef in _defs:
		if not def.is_dilemma():
			continue
		dilemmas += 1
		assert_ge(float(def.options.size()), 2.0, String(def.id))
		for o: NarrativeOption in def.options:
			assert_true(o.has_price(),
				"'%s' option '%s' costs nothing" % [String(def.id), o.label])
			assert_ne(o.cost_line.strip_edges(), "",
				"'%s' option '%s' does not print its price" % [String(def.id), o.label])
			assert_ne(o.outcome.strip_edges(), "",
				"'%s' option '%s' has no consequence written" % [String(def.id), o.label])
	assert_ge(float(dilemmas), 8.0, "a winter needs more than %d decisions in it" % dilemmas)


## The dominance rule, asserted here as well as in validate() because this is
## the property the whole part is judged on and it deserves a named test.
func test_no_dilemma_has_an_obvious_answer() -> void:
	for def: NarrativeEventDef in _defs:
		if not def.is_dilemma():
			continue
		assert_empty(def._check_no_obvious_answer(), String(def.id))


func test_every_deadline_has_a_default_that_hurts() -> void:
	for def: NarrativeEventDef in _defs:
		if def.deadline_hours <= 0.0 or not def.is_dilemma():
			continue
		var i: int = def.default_option_index()
		assert_between(float(i), 0.0, float(def.options.size() - 1), String(def.id))
		assert_true(def.options[i].has_price(),
			"'%s' decides itself into an option that costs nothing" % String(def.id))


func test_every_token_in_the_writing_resolves() -> void:
	var world := NarrativeWorld.new()
	world._fill_missing()
	for def: NarrativeEventDef in _defs:
		for text: String in [def.lede, def.body, def.cause_prose, def.closing]:
			assert_empty(world.unknown_tokens(text),
				"'%s' uses a token nothing fills: %s" % [String(def.id),
					", ".join(world.unknown_tokens(text))])
		for o: NarrativeOption in def.options:
			for text: String in [o.body, o.cost_line, o.gain_line, o.outcome]:
				assert_empty(world.unknown_tokens(text),
					"'%s' option '%s' uses an unknown token" % [String(def.id), o.label])


func test_the_prose_is_about_this_city() -> void:
	for def: NarrativeEventDef in _defs:
		assert_true(_anchored(def.body),
			"'%s' body names nothing that exists in Caldera Nine" % String(def.id))


# =========================================================================
#  the campaign spine
# =========================================================================

func test_the_campaign_has_a_spine() -> void:
	var chapters: Array[NarrativeCampaign.Chapter] = NarrativeCampaign.chapters()
	assert_ge(float(chapters.size()), 5.0, "a campaign needs beats")
	var world := NarrativeWorld.new()
	world._fill_missing()
	var seen: Dictionary[StringName, bool] = {}
	for ch: NarrativeCampaign.Chapter in chapters:
		assert_false(seen.has(ch.key), "duplicate chapter key '%s'" % String(ch.key))
		seen[ch.key] = true
		assert_ne(ch.title.strip_edges(), "", String(ch.key))
		assert_gt(float(ch.prose.length()), 200.0,
			"chapter '%s' is a stub" % String(ch.key))
		assert_true(_anchored(ch.prose), "chapter '%s' is about nowhere" % String(ch.key))
		assert_empty(world.unknown_tokens(ch.prose),
			"chapter '%s' uses an unknown token" % String(ch.key))
		for c: NarrativeCondition in ch.conditions:
			assert_true(NarrativeDefs.has_fact(c.fact),
				"chapter '%s' opens on '%s', which nothing measures" % [
					String(ch.key), String(c.fact)])


## The first chapter must open on an empty world, or a run starts with no
## opening at all.
func test_the_opening_always_opens() -> void:
	var world := NarrativeWorld.new()
	world._fill_missing()
	world.facts[&"day"] = 1.0
	var chapters: Array[NarrativeCampaign.Chapter] = NarrativeCampaign.chapters()
	assert_true(chapters[0].opens(world.facts), "the opening beat does not open")


func test_the_reckoning_counts_rather_than_scolds() -> void:
	var world := NarrativeWorld.new()
	world._fill_missing()
	world.facts[&"day"] = 9.0
	world.facts[&"population"] = 41.0
	world.facts[&"deaths"] = 17.0
	world.facts[&"deaths_cold"] = 11.0
	world.facts[&"deaths_starvation"] = 6.0
	var journal := NarrativeJournal.new()
	var laws: Array[Dictionary] = [
		{"title": "Child Labour", "signed": true, "tags": ["cruel"]},
		{"title": "Care House", "signed": true, "tags": ["costly"]},
		{"title": "Corpse Pits", "signed": false, "tags": ["cruel"]},
	]
	var r: Dictionary = NarrativeCampaign.reckoning(&"held", world.facts, journal, laws, "")
	assert_eq(r["dead"], 17, "the toll is quoted from the run")
	assert_eq(r["laws_signed"], 2, "only signed pages count")
	assert_has(r["cruel_laws"], "Child Labour")
	assert_has_not(r["cruel_laws"], "Corpse Pits")
	assert_has(String(r["text"]), "11 froze", "the epilogue names the causes")
	assert_has(String(r["text"]), "41", "the epilogue names the survivors")


# =========================================================================
#  the flavour
# =========================================================================

func test_there_are_at_least_a_hundred_and_twenty_lines() -> void:
	var lines: PackedStringArray = NarrativeFlavour.every_line()
	assert_ge(float(lines.size()), 120.0,
		"the brief asks for 120 distinct pieces of flavour; there are %d" % lines.size())


func test_no_flavour_line_is_repeated() -> void:
	var seen: Dictionary[String, bool] = {}
	for line: String in NarrativeFlavour.every_line():
		assert_false(seen.has(line), "repeated line: %s" % line.substr(0, 60))
		seen[line] = true


func test_every_flavour_line_is_about_this_city() -> void:
	for line: String in NarrativeFlavour.every_line():
		assert_true(_anchored(line),
			"could be about anywhere: %s" % line.substr(0, 80))


func test_no_flavour_line_reaches_for_grimdark() -> void:
	for line: String in NarrativeFlavour.every_line():
		var low: String = line.to_lower()
		for word: String in BANNED:
			assert_false(low.contains(word),
				"'%s' in: %s" % [word, line.substr(0, 70)])


func test_every_flavour_line_is_a_sentence() -> void:
	for line: String in NarrativeFlavour.every_line():
		assert_gt(float(line.length()), 40.0, "too short to say anything: %s" % line)
		assert_true(line.ends_with(".") or line.ends_with("?"),
			"unfinished: %s" % line.substr(0, 60))


func test_every_flavour_bank_is_gated_on_a_real_fact() -> void:
	var banks_seen: Dictionary[StringName, bool] = {}
	for gate: Dictionary in NarrativeFlavour.gates():
		var bank: StringName = StringName(gate["bank"])
		banks_seen[bank] = true
		assert_not_empty(NarrativeFlavour.bank(bank), "bank '%s' is empty" % String(bank))
		assert_not_empty(gate["all_of"],
			"bank '%s' speaks unconditionally" % String(bank))
		for c: NarrativeCondition in (gate["all_of"] as Array[NarrativeCondition]):
			assert_true(NarrativeDefs.has_fact(c.fact),
				"bank '%s' gates on '%s'" % [String(bank), String(c.fact)])
	for id: StringName in NarrativeFlavour.BANK_IDS:
		assert_true(banks_seen.has(id), "bank '%s' has no gate, so it never speaks" % String(id))


func test_every_death_cause_has_something_to_say() -> void:
	for cause: StringName in [&"cold", &"starvation", &"illness", &"injury",
			&"exhaustion", &"old_age"]:
		assert_not_empty(NarrativeFlavour.grief_bank(cause),
			"nothing is written for a death by %s" % String(cause))


# =========================================================================
#  the fact table itself
# =========================================================================

func test_every_fact_is_labelled_and_formatted() -> void:
	for key: StringName in NarrativeDefs.fact_keys():
		var row: Array = NarrativeDefs.FACTS[key]
		assert_size(row, 3, "fact '%s' is malformed" % String(key))
		assert_ne(String(row[0]).strip_edges(), "", String(key))
		var shown: String = NarrativeDefs.fact_value_text(key, 12.5)
		assert_ne(shown, "", String(key))
		assert_has_not(shown, "%", "fact '%s' leaks a format specifier" % String(key))


func test_a_condition_explains_itself_with_the_live_number() -> void:
	var facts: Dictionary = {&"discontent": 66.42}
	var c: NarrativeCondition = NarrativeCondition.make(&"discontent",
		NarrativeDefs.Cmp.GE, 62.0)
	assert_true(c.holds(facts))
	var text: String = c.explain(facts)
	assert_has(text, "66.4", "the explanation must quote the live value")
	assert_has(text, "62", "the explanation must quote the threshold")


func test_a_boolean_condition_reads_like_english() -> void:
	var c: NarrativeCondition = NarrativeCondition.make(&"is_night",
		NarrativeDefs.Cmp.GE, 1.0)
	var text: String = c.explain({&"is_night": 1.0})
	assert_eq(text, "Night: yes.", "a yes or no is stated, never compared")


func _anchored(text: String) -> bool:
	var low: String = text.to_lower()
	for anchor: String in ANCHORS:
		if low.contains(anchor):
			return true
	for i: int in 10:
		if low.contains(str(i)):
			return true
	return low.contains("{")
