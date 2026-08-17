extends SceneTree
## THE EVENTS OF CALDERA NINE. [P22] owns this file.
##
## Every event in the game is written here and emitted as one .tres per event
## into game/content/events/. Registry picks them up by directory scan; nothing
## in the running game ever loads this script.
##
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##       --script game/narrative/_write_the_events.gd
##
## It exists because the events are a piece of WRITING before they are a data
## structure. Twenty six separate .tres files cannot be read as a document,
## cannot be checked for repeated phrasing, and cannot be edited for voice.
## This can. It also means the sub-resources are built by the engine and saved
## by ResourceSaver, so a hand-typed .tres can never be subtly malformed.
##
## RULES THE CONTENT OBEYS, enforced by NarrativeEventDef.validate() and by
## tests/narrative:
##   * every event has at least one condition over a fact the sim measures
##   * every dilemma has at least two options and every option takes something
##   * no option is better than its sibling on every axis at once
##   * every line is about THIS caldera: the Hearth, Kettle Row, the Drop, the
##     East Wall, the Long Shaft, a name, a number

const OUT: String = "res://game/content/events"

const GE: int = NarrativeDefs.Cmp.GE
const LE: int = NarrativeDefs.Cmp.LE
const GT: int = NarrativeDefs.Cmp.GT
const LT: int = NarrativeDefs.Cmp.LT

var written: int = 0
var problems: int = 0


func _init() -> void:
	_write_all()
	print("events written: %d, problems: %d" % [written, problems])
	quit(1 if problems > 0 else 0)


func _c(fact: StringName, cmp: int, value: float, sustained: float = 0.0) -> NarrativeCondition:
	return NarrativeCondition.make(fact, cmp, value, sustained)


func _opt(label: String, body: String, cost: String, gain: String, outcome: String,
		effects: Dictionary, tags: Array = [], is_default: bool = false) -> NarrativeOption:
	var o := NarrativeOption.new()
	o.label = label
	o.body = body
	o.cost_line = cost
	o.gain_line = gain
	o.outcome = outcome
	var typed: Dictionary[StringName, float] = {}
	for k: Variant in effects.keys():
		typed[StringName(String(k))] = float(effects[k])
	o.effects = typed
	var t: Array[StringName] = []
	for x: Variant in tags:
		t.append(StringName(String(x)))
	o.tags = t
	o.is_default = is_default
	return o


func _event(id: String, title: String, category: StringName, lede: String, body: String,
		all_of: Array, options: Array = [], extra: Dictionary = {}) -> void:
	var e := NarrativeEventDef.new()
	e.id = StringName(id)
	e.title = title
	e.category = category
	e.lede = lede
	e.body = body
	var conds: Array[NarrativeCondition] = []
	for c: Variant in all_of:
		conds.append(c as NarrativeCondition)
	e.all_of = conds
	var opts: Array[NarrativeOption] = []
	for o: Variant in options:
		opts.append(o as NarrativeOption)
	e.options = opts
	e.priority = int(extra.get("priority", 50))
	e.min_day = int(extra.get("min_day", 1))
	e.max_day = int(extra.get("max_day", 0))
	e.once = bool(extra.get("once", true))
	e.cooldown_hours = float(extra.get("cooldown_hours", 24.0))
	e.deadline_hours = float(extra.get("deadline_hours", 0.0))
	e.cause_prose = String(extra.get("cause_prose", ""))
	e.closing = String(extra.get("closing", ""))
	if extra.has("any_of"):
		var any: Array[NarrativeCondition] = []
		for c: Variant in extra["any_of"] as Array:
			any.append(c as NarrativeCondition)
		e.any_of = any
	if extra.has("none_of"):
		var none: Array[NarrativeCondition] = []
		for c: Variant in extra["none_of"] as Array:
			none.append(c as NarrativeCondition)
		e.none_of = none
	if extra.has("requires_flags"):
		var rf: Array[StringName] = []
		for f: Variant in extra["requires_flags"] as Array:
			rf.append(StringName(String(f)))
		e.requires_flags = rf
	if extra.has("forbids_flags"):
		var ff: Array[StringName] = []
		for f: Variant in extra["forbids_flags"] as Array:
			ff.append(StringName(String(f)))
		e.forbids_flags = ff
	if extra.has("tags"):
		var tg: Array[StringName] = []
		for t: Variant in extra["tags"] as Array:
			tg.append(StringName(String(t)))
		e.tags = tg
	e.resource_name = title

	var issues: PackedStringArray = e.validate()
	if not issues.is_empty():
		for line: String in issues:
			printerr("EVENT '%s' %s" % [id, line])
		problems += issues.size()
		return
	var path: String = "%s/%s.tres" % [OUT, id]
	var code: int = ResourceSaver.save(e, path)
	if code != OK:
		printerr("could not write %s (%d)" % [path, code])
		problems += 1
		return
	written += 1


# =========================================================================
#  the content
# =========================================================================

func _write_all() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	_dilemmas()
	_reports()
	_scouts()


# ---------------------------------------------------------------- dilemmas --

func _dilemmas() -> void:

	_event("the_delegation", "A Delegation at the Hall", NarrativeDefs.CAT_DILEMMA,
		"Forty of them came up the Ash Stair and stopped at the door.",
		"They are not carrying anything. That is the first thing you notice, and "
		+ "it is deliberate: somebody thought about how this would look.\n\n"
		+ "The woman at the front does the talking. She works the second boiler "
		+ "and she has the burn on her forearm that everybody on that shift has. "
		+ "She says the Nine has stopped being a place where things get decided "
		+ "and started being a place where things get announced. She says she is "
		+ "not asking you to change any of it. She is asking you to come out and "
		+ "say it to them yourself.\n\n"
		+ "Discontent stands at {discontent}. Behind her, {population} people are "
		+ "waiting to hear what kind of answer this is.",
		[_c(&"discontent", GE, 55.0, 6.0), _c(&"population", GE, 8.0)],
		[
			_opt("Go out and speak to them",
				"You go down the Ash Stair without the Watch and you stand in the "
				+ "cold with them for as long as it takes.",
				"An hour of daylight, and every promise you make out there is one "
				+ "you have to keep. The Watch will not like being left inside.",
				"They go back to their shifts having been answered by a person "
				+ "rather than by a notice on the door.",
				"You talked for an hour and you did not lie once, which took "
				+ "longer. They went back down the stair in ones and twos and the "
				+ "second boiler was running again by the evening whistle. Nothing "
				+ "was actually fixed. Everybody knows that too.",
				{&"discontent": -9.0, &"hope": 3.0, &"approval:workers": 12.0,
					&"approval:watch": -10.0, &"stock:coal": -20.0}),
			_opt("Send the Watch to move them on",
				"Four men with the bar off the North Gate. It takes about six "
				+ "minutes and nobody is hurt.",
				"They will remember it, and so will everyone who watched from "
				+ "Kettle Row. The Hearthside will not send their children up "
				+ "here again.",
				"The doorway is clear, the shift is back on time, and you have "
				+ "not conceded a single thing.",
				"They were gone in six minutes and the Watch did it without "
				+ "raising a hand, which the Watch will tell you about. The woman "
				+ "from the second boiler was the last to leave. She looked at the "
				+ "door for a while before she went.",
				{&"discontent": 6.0, &"hope": -5.0, &"approval:workers": -18.0,
					&"approval:families": -8.0, &"approval:watch": 10.0},
				["cruel"], true),
		],
		{"priority": 80, "deadline_hours": 6.0, "once": false, "cooldown_hours": 72.0,
			"cause_prose": "Nobody organised this. It accumulated.",
			"tags": ["society"]})

	_event("the_frozen_column", "A Column on the Rim Road", NarrativeDefs.CAT_DILEMMA,
		"Nineteen people came over the north rim at dusk and stopped at the gate.",
		"They have three sleds and no fuel. They have been walking since the "
		+ "vent they were sitting on gave out, which by their account was eleven "
		+ "days ago, and they lost four on the way. They knew this place was "
		+ "here because the survey maps have it marked as well.\n\n"
		+ "There are {population} people in {city} tonight and {food_days} of "
		+ "food. Nineteen more is nineteen more bowls, nineteen more bodies "
		+ "against the cold, and nineteen more people with no bunk.\n\n"
		+ "The gate is shut. It is minus twenty out there and they are not going "
		+ "to walk anywhere else.",
		[_c(&"day", GE, 3.0), _c(&"population", GE, 10.0)],
		[
			_opt("Open the gate",
				"They come in tonight. The kitchen stretches, the bunks do not, "
				+ "and the Latecomers get nineteen new members before morning.",
				"Nineteen more mouths against a larder measured in days, and "
				+ "nineteen people sleeping in the open until something is built.",
				"Nineteen pairs of hands, most of them able, all of them owing "
				+ "you the fact that they are alive.",
				"They came in and sat down where they stood and the kitchen "
				+ "opened again at an hour it does not normally open. By morning "
				+ "two of them were already on the sled crews. One of them was not "
				+ "moving and had not been for a while, and nobody had noticed in "
				+ "the dark.",
				{&"arrivals": 19.0, &"food": -140.0, &"hope": 6.0,
					&"approval:latecomers": 25.0, &"approval:workers": -8.0,
					&"discontent": 5.0}),
			_opt("Keep the gate shut",
				"You send out what can be spared through the wicket and you do "
				+ "not open the bar. What they do after that is theirs to decide.",
				"Every person on the wall watches you do it, and the Congregation "
				+ "will have something to say about it at the Hearth tomorrow.",
				"The larder holds. Nobody in the Nine sleeps outside who was not "
				+ "already sleeping outside.",
				"They stayed at the gate for most of the night and then they went "
				+ "along the rim, west, which is the wrong way. In the morning the "
				+ "watch reported three shapes still on the road at the limit of "
				+ "the lamps. By noon there were none.",
				{&"hope": -12.0, &"discontent": 8.0, &"approval:faithful": -22.0,
					&"approval:families": -12.0},
				["cruel"], true),
		],
		{"priority": 85, "deadline_hours": 4.0,
			"cause_prose": "They came because your generator is the only light on any "
			+ "map that still works."})

	_event("the_cold_ward", "The Care House Is Losing", NarrativeDefs.CAT_DILEMMA,
		"The fever is going along the bunks in the order they are laid out.",
		"{sick} people are down with it. The care house is at the cold end of "
		+ "the west line and it was put there because it was the building nobody "
		+ "else wanted, which was a decision somebody made in week one without "
		+ "thinking of it as a decision.\n\n"
		+ "The physician has stopped asking for medicine, which she knows there "
		+ "is none of, and started asking for heat, which there is. It is just "
		+ "somewhere else.",
		[_c(&"sick", GE, 4.0, 3.0), _c(&"population", GE, 8.0)],
		[
			_opt("Turn the west line up",
				"Full pressure to the care house, taken off the workshop run for "
				+ "as long as this lasts.",
				"The workshop runs cold and slow, and everything the workshop was "
				+ "going to make this week is now next week's problem.",
				"The ward gets warm enough that people stop shivering, which is "
				+ "most of what a fever needs.",
				"The coughing thinned out over two days. The workshop lost most "
				+ "of a week and the foreman came up to say so, at length, and he "
				+ "was right, and it did not change the decision.",
				{&"stock:coal": -60.0, &"hope": 4.0, &"approval:infirm": 20.0,
					&"approval:workers": -12.0}),
			_opt("Move them into the workshop",
				"The sick go where the heat already is. The machines keep running "
				+ "around them.",
				"You have put the fever in the one building the whole day shift "
				+ "passes through. The Hearthside will work out what that means "
				+ "before you have finished saying it.",
				"Nothing is taken off the grid. The ward empties into a room that "
				+ "is already warm.",
				"They were carried across on the sleds and laid out between the "
				+ "benches and the machines did not stop. Within four days it was "
				+ "in the day shift as well. It was always going to be, and doing "
				+ "it this way made it faster.",
				{&"discontent": 9.0, &"approval:families": -16.0,
					&"approval:infirm": 6.0, &"hope": -4.0},
				["cruel"], true),
		],
		{"priority": 70, "deadline_hours": 8.0, "once": false, "cooldown_hours": 96.0})

	_event("the_last_timber", "The Timber Runs Out", NarrativeDefs.CAT_DILEMMA,
		"There is not enough wood in the yard to lag the mains before the Frost.",
		"The stack is down to {stock_timber}. The nearest standing timber is "
		+ "four days of hauling and the Frost is {storm_hours} away, which is "
		+ "not four days.\n\n"
		+ "There is wood in {city}. It is in the sledway decking, in the roof of "
		+ "the Survey Hall, and in the bunk frames on Kettle Row. All of it is "
		+ "doing a job. All of it would burn.",
		[_c(&"stock_timber", LE, 30.0, 2.0), _c(&"day", GE, 2.0)],
		[
			_opt("Take the sledway decking",
				"The boards come up and go into the lagging. The sledway becomes "
				+ "packed ice and a rope line.",
				"Every load from the shaft now takes half again as long, and the "
				+ "rim road in the dark becomes something people are frightened "
				+ "of with reason.",
				"The mains are lagged before the Frost arrives. The pipes hold.",
				"They had the decking up in a morning and the lagging on by dusk. "
				+ "The first loaded sled to come down the iced way went into the "
				+ "wall of the second boiler house and took a man's leg with it. "
				+ "The pipes held all through the Frost, which is also true.",
				{&"stock:timber": 60.0, &"discontent": 7.0, &"approval:workers": -14.0,
					&"hope": -3.0}),
			_opt("Break up the bunk frames",
				"The frames on Kettle Row come apart. People sleep on the floor "
				+ "and on what they can find.",
				"Sleeping on a floor in a caldera is sleeping in the cold, and "
				+ "the people it happens to will be the ones with the least.",
				"More timber than the sledway would have given, and the shaft "
				+ "keeps running at full rate.",
				"They took eleven frames apart on the north side of the row and "
				+ "the lagging went on. Two of the people who lost a frame were "
				+ "not in a state to be sleeping on a floor. One of them was still "
				+ "working the day it stopped mattering.",
				{&"stock:timber": 90.0, &"hope": -8.0, &"discontent": 6.0,
					&"approval:families": -18.0, &"deaths": 1.0},
				["cruel"], true),
		],
		{"priority": 75, "deadline_hours": 6.0, "once": false, "cooldown_hours": 120.0})

	_event("the_thief", "Somebody Got Into the Granary", NarrativeDefs.CAT_DILEMMA,
		"Four days of grain, taken through the roof, and the rest left behind.",
		"They knew where the crossbeam was weak and they knew the clerk walks "
		+ "the yard at the half hour. That is not a stranger. That is somebody "
		+ "who has been inside the Nine since the column stopped here.\n\n"
		+ "The Watch have a name. The name belongs to a man with two children "
		+ "and a bad hand, and the clerk who gave it up has asked, twice, "
		+ "whether he can take it back.\n\n"
		+ "There are {food_days} of food left. The whole city knows the number "
		+ "and the whole city knows four days of it walked out of the roof.",
		[_c(&"food_days", LE, 6.0, 2.0), _c(&"population", GE, 12.0), _c(&"day", GE, 2.0)],
		[
			_opt("Make an example of him",
				"He is put out of the gate at first light with what he came in "
				+ "with, and the reason is read out at the kitchen.",
				"You have taken a father away from two children in front of "
				+ "everybody, over grain, and nobody who watched it will forget "
				+ "which of those two things you chose.",
				"Nothing goes missing from the granary again this winter. Not "
				+ "one thing.",
				"He went out at first light and did not argue, which was worse. "
				+ "The granary was not touched again. The children were taken in "
				+ "by the row and are fed by people who have less than he did.",
				{&"discontent": -6.0, &"hope": -9.0, &"approval:watch": 14.0,
					&"approval:families": -20.0, &"flag:a_name_was_read_out": 1.0},
				["cruel"]),
			_opt("Put it back and say nothing",
				"The grain that is left goes back in the store. No name is read "
				+ "out. The crossbeam gets fixed.",
				"The Watch know you knew. The clerk knows you knew. By the end of "
				+ "the week the row knows, and the store is a suggestion rather "
				+ "than a store.",
				"Two children keep a father, and nobody stands in the cold "
				+ "watching a man be sent out to die of a decision.",
				"Nothing was said and the beam was fixed the same day. Over the "
				+ "next fortnight the granary lost a little more, in smaller "
				+ "amounts, from more than one person. None of it was ever worth "
				+ "reading a name out for either.",
				{&"food": -60.0, &"discontent": 5.0, &"approval:watch": -12.0,
					&"hope": 4.0},
				[], true),
		],
		{"priority": 65, "deadline_hours": 12.0})

	_event("the_drop", "The Dead Are Still by the East Wall", NarrativeDefs.CAT_DILEMMA,
		"There are more of them than the tarp is long.",
		"The ground is four metres of permafrost and nobody is digging a grave "
		+ "in it. They have been stacked against the East Wall since the first "
		+ "one, under canvas, in the order they arrived, and the pile is now at "
		+ "{deaths}.\n\n"
		+ "There is a vent shaft on the west side of the caldera that goes down "
		+ "further than anybody has ever been. The Watch call it the Drop. It is "
		+ "warm at the mouth of it, which is the part nobody says out loud.\n\n"
		+ "The Congregation want them where they can be visited. The Watch want "
		+ "them gone before the thaw that is not coming.",
		[_c(&"deaths", GE, 5.0, 2.0)],
		[
			_opt("Open the Drop",
				"They go down the west shaft, all of them, at night, and the "
				+ "mouth is boarded over afterwards.",
				"There is nowhere to stand and be sad. The Congregation will hold "
				+ "the vigil at the Hearth instead, which puts forty people in "
				+ "front of the generator every evening.",
				"The East Wall is clear. The Watch stop standing where the pile "
				+ "was and looking at it.",
				"It took most of a night and the men who did it were given the "
				+ "morning off and none of them slept. The wall is clear. "
				+ "Somebody has scratched the names into the boards over the "
				+ "mouth, all of them, in a hand that got worse as it went.",
				{&"discontent": -5.0, &"hope": -6.0, &"approval:faithful": -24.0,
					&"approval:watch": 12.0, &"flag:the_drop_is_open": 1.0},
				["cruel"]),
			_opt("Leave them where they are",
				"The pile stays. More canvas is found. Somebody is put on it to "
				+ "keep it decent.",
				"It grows, in full view of the wall the watch stand on every "
				+ "night, and when the fever comes it will come from there.",
				"Every family in the Nine knows exactly where their people are.",
				"More canvas was found and the pile was made decent, which took "
				+ "one person off the shaft permanently. The Congregation come "
				+ "down on the seventh evening and read the names out. So does "
				+ "everybody else, eventually, because they can.",
				{&"discontent": 6.0, &"hope": 3.0, &"approval:faithful": 18.0,
					&"approval:watch": -10.0, &"flag:the_wall_is_a_graveyard": 1.0},
				[], true),
		],
		{"priority": 72, "deadline_hours": 10.0})

	_event("the_hearth_gamble", "The Hearth Will Not Reach Them", NarrativeDefs.CAT_DILEMMA,
		"The grid is short by {heat_deficit} and the far end of Kettle Row is "
		+ "already below freezing indoors.",
		"The engineer has two answers and does not like either of them.\n\n"
		+ "The first is to run the Hearth past the number stamped on the plate "
		+ "on its side. It will hold. It has held before. The plate was written "
		+ "by people who assumed there would be spare parts.\n\n"
		+ "The second is to shut the far end of the west line and accept that "
		+ "the houses on it are not houses tonight. There are people in them. "
		+ "There are {homeless} people already outside who would be glad of them.",
		[_c(&"heat_deficit", GT, 2.0, 2.0), _c(&"day", GE, 2.0)],
		[
			_opt("Run it past the plate",
				"Full draw, all night, and a man sitting with it in case of the "
				+ "thing nobody wants to name.",
				"Coal at a rate the yard cannot sustain, and a generator that is "
				+ "now one bad hour away from being the story of how this ended.",
				"Every pipe in {city} carries heat tonight and nobody freezes in "
				+ "a building you decided not to warm.",
				"It ran all night at a draw that made the housing tick. Nobody "
				+ "froze. In the morning the engineer went over it with a lamp "
				+ "for two hours and came out and said nothing at all, and has "
				+ "been going over it with a lamp every morning since.",
				{&"stock:coal": -90.0, &"hope": 5.0, &"discontent": -4.0}),
			_opt("Shut the west line",
				"The valve goes over at dusk. Everyone on that run is told to "
				+ "come in toward the Hearth and find a floor.",
				"Some of them will not come in, because the ones who will not "
				+ "come in are always the ones who cannot.",
				"The Hearth runs inside its numbers, the coal lasts, and the rest "
				+ "of the grid is comfortable for the first time in days.",
				"The valve went over at dusk and most of them came in and slept "
				+ "on the floor of the Survey Hall. Most of them.",
				{&"hope": -7.0, &"discontent": 8.0, &"deaths": 1.0,
					&"approval:latecomers": -18.0},
				["cruel"], true),
		],
		{"priority": 78, "deadline_hours": 4.0, "once": false, "cooldown_hours": 96.0})

	_event("the_small_hands", "The Machines Want Small Hands", NarrativeDefs.CAT_DILEMMA,
		"{stalled_machines} machines are standing idle for want of somebody who "
		+ "fits inside them.",
		"The housings on the sorters were built to be serviced from the inside "
		+ "by somebody who could get an arm and a shoulder through a gap the "
		+ "width of a ledger. No adult in {city} can do it. Eleven children can.\n\n"
		+ "The foreman has not asked. He has simply mentioned it, twice, in the "
		+ "way that people mention a thing they want somebody else to say first.",
		[_c(&"stalled_machines", GE, 3.0, 4.0), _c(&"population", GE, 12.0),
			_c(&"day", GE, 3.0)],
		[
			_opt("Send them in",
				"The children go into the housings under supervision, for an "
				+ "hour at a time, with the machines cold.",
				"The Hearthside will not forgive it, and the machines are only "
				+ "cold until somebody decides an hour of downtime is too much.",
				"Every stalled machine in the Nine is running again by the end "
				+ "of the week.",
				"They were in and out in an hour and they thought it was an "
				+ "adventure, which is the part that will stay with the people "
				+ "who watched. Every sorter is running. Within a fortnight "
				+ "somebody had them going in with the machine warm, to save the "
				+ "hour, and nobody had to give that order either.",
				{&"hope": -8.0, &"discontent": 6.0, &"approval:families": -26.0,
					&"approval:workers": 14.0, &"flag:the_children_work": 1.0},
				["cruel"]),
			_opt("Cut the housings open",
				"The plate comes off the sorters with a torch. They can be "
				+ "serviced from outside afterwards, permanently.",
				"Iron plate and three days of the workshop's whole capacity, "
				+ "spent on machines that already exist instead of on anything "
				+ "new, and the sorters run cold and lossy forever after.",
				"Nobody's child goes inside a machine in {city}, this week or "
				+ "any week after it.",
				"It took three days and most of the plate in the yard and the "
				+ "sorters lost a fifth of their rate for good. The foreman has "
				+ "not mentioned it again. The eleven children are at the Ash "
				+ "Stair doing what children do, which is being loud about "
				+ "nothing at the exact hour the night shift is trying to sleep.",
				{&"stock:iron_plate": -70.0, &"discontent": 4.0,
					&"approval:workers": -10.0, &"approval:families": 16.0},
				[], true),
		],
		{"priority": 68, "deadline_hours": 12.0})

	_event("the_second_vent", "There Is Another Vent", NarrativeDefs.CAT_DILEMMA,
		"The scouts came back off the north rise with a survey marker and a "
		+ "direction.",
		"Nine days of walking, they say. Open, breathing, and wider at the "
		+ "mouth than this one. The old maps have it as Site Fourteen and there "
		+ "is a crossing-out beside it in a hand nobody in {city} recognises.\n\n"
		+ "Nine days out is nine days back. A party big enough to survive it is "
		+ "a party big enough to be missed here. And if it is real, it is not a "
		+ "place to move to. It is a place to know about.",
		[_c(&"day", GE, 5.0), _c(&"population", GE, 20.0)],
		[
			_opt("Send a party",
				"Eight people, twenty days of food, and the best sled. They go "
				+ "at first light.",
				"Eight pairs of hands out of the rotation for the better part of "
				+ "three weeks, and twenty days of food out of a larder that has "
				+ "{food_days} in it.",
				"You find out whether there is anywhere else. Nobody in this "
				+ "caldera has known that since the column stopped.",
				"They went at first light and the whole of Kettle Row came out "
				+ "for it, which nobody had arranged. The shaft ran three short "
				+ "for the rest of the month and everybody knew why and nobody "
				+ "complained about it, which has not happened before.",
				{&"food": -180.0, &"hope": 9.0, &"approval:workers": -8.0,
					&"flag:the_party_went_out": 1.0}),
			_opt("Keep everybody here",
				"The marker goes in a drawer in the Survey Hall. The scouts are "
				+ "told, plainly, why.",
				"The scouts will tell people, because scouts always do, and the "
				+ "Nine will spend the winter knowing there was a door and that "
				+ "you decided not to open it.",
				"Eight people stay on the rotation and twenty days of food stay "
				+ "in the granary at the exact point in the winter where both "
				+ "matter most.",
				"The marker is in the second drawer of the map table with the "
				+ "crossing-out still on it. By the end of the week everybody "
				+ "knew, and by the end of the month it had turned into a thing "
				+ "people say about you rather than a thing that happened.",
				{&"hope": -6.0, &"discontent": 4.0, &"approval:latecomers": -10.0},
				[], true),
		],
		{"priority": 60, "deadline_hours": 24.0})

	_event("the_wall_or_the_hearth", "The Wall or the Hearth", NarrativeDefs.CAT_DILEMMA,
		"There are {enemies_alive} of them inside the lamps and the East Wall "
		+ "is not going to hold the night.",
		"The watch commander is not asking for reinforcements. He knows what "
		+ "there is. He is asking where he should die, which is a different "
		+ "question and he has phrased it politely.\n\n"
		+ "Hold the wall and the workshops behind it stay standing. Fall back "
		+ "to the Hearth and everything outside the inner ring is theirs until "
		+ "morning, and the Hearth keeps running, and the people around it keep "
		+ "breathing.",
		[_c(&"enemies_alive", GE, 12.0), _c(&"is_night", GE, 1.0)],
		[
			_opt("Hold the East Wall",
				"Everybody stays where they are. The gate stays barred and the "
				+ "line stays on the wall until dawn or until it does not.",
				"The watch on that wall are not all coming back off it, and you "
				+ "are the one who told them to be there.",
				"The workshops, the granary and the sorters are all behind that "
				+ "line, and all of them are still there in the morning.",
				"They held it. The count in the morning was short by more than "
				+ "anybody wanted to say at the kitchen, and the workshops opened "
				+ "on time, and both of those facts were read out in the same "
				+ "breath by somebody who did not know how else to do it.",
				{&"deaths": 2.0, &"hope": -5.0, &"approval:watch": 16.0,
					&"discontent": -3.0}),
			_opt("Fall back to the Hearth",
				"Everybody in, behind the inner ring, and the outer city is left "
				+ "to whatever is out there until the light comes.",
				"Whatever they get into overnight is gone, and rebuilding it "
				+ "comes out of a yard that is already short.",
				"The watch come off the wall alive, all of them, and stand round "
				+ "a generator that does not go out.",
				"They came in at a run and the ring held all night and everybody "
				+ "who went behind it came out the other side. The sorter shed "
				+ "was open to the sky by morning and the granary door was off "
				+ "its hinges. Nobody who came in has said it was the wrong call. "
				+ "Nobody has said it was the right one either.",
				{&"stock:timber": -80.0, &"stock:iron_plate": -40.0,
					&"discontent": 5.0, &"hope": 2.0, &"approval:watch": -6.0},
				[], true),
		],
		{"priority": 95, "deadline_hours": 2.0, "once": false, "cooldown_hours": 48.0})

	_event("the_half_ration", "The Clerk Wants an Answer", NarrativeDefs.CAT_DILEMMA,
		"There are {food_days} of food left and the kitchen opens in an hour.",
		"The ration clerk has been doing the arithmetic in the margin of the "
		+ "ledger for three days and has finally brought the ledger up here "
		+ "rather than the answer.\n\n"
		+ "Full bowls for four more days, and then nothing at all. Or half "
		+ "bowls from tonight, and eight days, and a city that finds out at the "
		+ "kitchen queue rather than from you.",
		[_c(&"food_days", LE, 4.0, 3.0), _c(&"population", GE, 10.0)],
		[
			_opt("Half rations from tonight",
				"The scoop gets smaller at the evening whistle. It is not "
				+ "announced. It is simply smaller.",
				"People doing shaft work on half a bowl start making the kind of "
				+ "mistakes that end up in the care house, and everybody in the "
				+ "queue does the same arithmetic the clerk did.",
				"Eight days instead of four. Eight days is long enough for "
				+ "something to arrive.",
				"The scoop was smaller and the queue noticed inside a minute. "
				+ "Nobody said anything at the kitchen. The talking started "
				+ "afterwards, on the stair, and it has not stopped.",
				{&"hope": -7.0, &"discontent": 9.0, &"food": 90.0,
					&"approval:workers": -14.0}),
			_opt("Full bowls while there are any",
				"Nothing changes at the kitchen. The scoop stays the size it has "
				+ "always been, right up until the day there is nothing in it.",
				"Four days, and then a morning where the kitchen does not open "
				+ "at all and everybody in the Nine finds out at once.",
				"Four days of people being able to work, think and stand up, "
				+ "which is four days to fix it.",
				"The scoop stayed the same size and the shaft crews made their "
				+ "quota all four days, which they would not have done otherwise. "
				+ "The kitchen did not open on the fifth morning. There was a "
				+ "queue anyway, for about an hour.",
				{&"hope": 3.0, &"discontent": -2.0, &"food": -40.0,
					&"approval:workers": 10.0, &"approval:families": -12.0},
				[], true),
		],
		{"priority": 82, "deadline_hours": 3.0, "once": false, "cooldown_hours": 96.0})

	_event("the_informer", "Somebody Has Been Writing Names Down", NarrativeDefs.CAT_DILEMMA,
		"A list came up from the row with eleven names on it and no explanation.",
		"The handwriting is the shift clerk's. The names are the eleven people "
		+ "who were loudest at the kitchen on the night the ration changed. "
		+ "Nobody asked him for it. He made it because he thought it was the "
		+ "kind of thing that would be wanted, which is the part that should "
		+ "worry you most.\n\n"
		+ "Discontent stands at {discontent}. The list is on the table. What "
		+ "happens next is going to tell {population} people what kind of place "
		+ "this is.",
		[_c(&"discontent", GE, 48.0, 4.0), _c(&"laws_signed", GE, 3.0),
			_c(&"day", GE, 4.0)],
		[
			_opt("Keep the list",
				"It goes in the drawer. The clerk is thanked. Nothing is done "
				+ "with it, this week.",
				"There is now a drawer in the Survey Hall with eleven names in "
				+ "it, and there will be a second list, because the clerk has "
				+ "been told he was right.",
				"You know who they are before they know they are anybody, and "
				+ "the loud stop being loud remarkably quickly.",
				"It went in the drawer. Within a fortnight there were four lists "
				+ "and none of them had been asked for. The kitchen has gone "
				+ "quiet in the evenings, which is what you wanted, and it is "
				+ "not the same quiet.",
				{&"discontent": -8.0, &"hope": -7.0, &"approval:watch": 12.0,
					&"approval:workers": -16.0, &"flag:the_lists_exist": 1.0},
				["cruel"]),
			_opt("Burn it in front of him",
				"The list goes in the Hearth with the clerk standing there, and "
				+ "he is told why, and he is left in his job.",
				"He will tell people, and everyone who was loud at the kitchen "
				+ "learns that being loud has no consequences at all.",
				"Nobody in {city} is on a list. That is a sentence you can still "
				+ "say out loud.",
				"It burned in about four seconds and he watched all of it. He "
				+ "told the row before the end of the shift. The kitchen has got "
				+ "louder rather than quieter and one of the eleven has started "
				+ "holding meetings in the second workshop.",
				{&"discontent": 7.0, &"hope": 6.0, &"approval:workers": 14.0,
					&"approval:watch": -14.0},
				[], true),
		],
		{"priority": 66, "deadline_hours": 8.0})


# ----------------------------------------------------------------- reports --

func _reports() -> void:

	_event("the_first_death", "The First One", NarrativeDefs.CAT_OBITUARY,
		"Somebody died in {city} today, and it is the first time.",
		"The ledger has no column for it. Somebody ruled a line down the right "
		+ "hand side of the page and wrote a heading over it, and that heading "
		+ "is now a permanent feature of how this city keeps its records.\n\n"
		+ "The name was read out at the kitchen at the evening whistle, because "
		+ "nobody could think of what else to do, and that is how it is going "
		+ "to be done from now on.",
		[_c(&"deaths", GE, 1.0)],
		[],
		{"priority": 90, "cause_prose": "There was no law about this and there is "
			+ "still no law about it."})

	_event("the_ultimatum", "A Demand With a Date On It", NarrativeDefs.CAT_REPORT,
		"{demand_faction_text} have stopped asking and started setting a "
		+ "deadline.",
		"The terms, as they were given: {demand_text}\n\n"
		+ "Discontent stands at {discontent} and there are {grievances_worded} "
		+ "against the Hall. This is not a mood any more. It is a "
		+ "position, with a date on it, held by people who work the machines "
		+ "that keep everybody alive.\n\n"
		+ "The Book of Laws is in the Survey Hall. If the answer is a law, it "
		+ "is in there, and it will take hours of argument to come into force "
		+ "once it is signed. Those hours come out of the deadline, not out of "
		+ "the time before it.",
		[_c(&"demands", GE, 1.0), _c(&"discontent", GE, 40.0)],
		[],
		{"priority": 88, "once": false, "cooldown_hours": 36.0,
			"cause_prose": "A faction issues terms when a grievance has been open "
			+ "long enough that asking stopped working."})

	_event("the_grid_split", "The Grid Is in Pieces", NarrativeDefs.CAT_REPORT,
		"There are {networks} separate heat networks in {city} and only one of "
		+ "them has the Hearth on it.",
		"The engineer walked the whole run this morning with a lamp and came "
		+ "back with the answer, which is that at some point a pipe was placed "
		+ "that does not touch the pipe next to it.\n\n"
		+ "Everything on the far side of that gap is being kept alive by "
		+ "nothing at all. The people in it do not know that yet. They know "
		+ "their rooms are cold and they assume it is the weather.",
		[_c(&"networks", GE, 2.0, 1.0), _c(&"day", GE, 1.0)],
		[],
		{"priority": 74, "once": false, "cooldown_hours": 48.0,
			"cause_prose": "A network is a connected run of pipe. Two networks means "
			+ "a gap somebody did not see."})

	_event("the_frozen_works", "Frozen Solid", NarrativeDefs.CAT_REPORT,
		"{frozen_buildings} structures in {city} have gone below the "
		+ "temperature at which they do anything at all.",
		"Frozen is not slow. Frozen is a machine with ice inside the housing "
		+ "and a crew standing next to it with their hands under their arms.\n\n"
		+ "It does not come back on its own. Heat has to reach it, and heat is "
		+ "reaching it through the same pipes that are the reason it froze.",
		[_c(&"frozen_buildings", GE, 2.0, 1.0)],
		[],
		{"priority": 76, "once": false, "cooldown_hours": 24.0})

	_event("the_belts_run", "The Line Moves On Its Own", NarrativeDefs.CAT_REPORT,
		"There are {belt_lines} belt lines running in {city} and nobody is "
		+ "carrying anything along them.",
		"It took two people a day to build and it does the work of four people "
		+ "for as long as there is heat in the grid to turn it.\n\n"
		+ "The four people are now doing something else. That is the whole "
		+ "argument for the thing, and it is also the reason the shaft crews "
		+ "watched it being built without saying anything.",
		[_c(&"belt_lines", GE, 1.0)],
		[],
		{"priority": 55, "cause_prose": "This is the first time material has moved "
			+ "through this city without a person under it."})

	_event("the_first_law", "A Page in the Book", NarrativeDefs.CAT_REPORT,
		"The Book of Laws in the Survey Hall has a signature in it.",
		"It was an empty book on the first day. Somebody had carried it eleven "
		+ "hours through the ice because the column's charter said there had to "
		+ "be one, and for three days it sat on the map table being a joke.\n\n"
		+ "It is not a joke now. Everything that goes into it is permanent, "
		+ "everything that goes into it forecloses something else, and every "
		+ "page in it will be read back to you by somebody who lived under it.",
		[_c(&"laws_signed", GE, 1.0)],
		[],
		{"priority": 62})

	_event("the_long_cold_report", "It Is Getting Worse On a Schedule",
		NarrativeDefs.CAT_REPORT,
		"{era_text}. Outside temperature {temperature}.",
		"The survey team who wrote the climate pages left before the first "
		+ "winter and their numbers were taken from a summer. The real curve is "
		+ "steeper and it is not finished.\n\n"
		+ "This is the part where a city either has margin or discovers that it "
		+ "does not. There are {buildings} structures standing and the grid is "
		+ "short by {heat_deficit}.",
		[_c(&"era", GE, 2.0)],
		[],
		{"priority": 70, "once": false, "cooldown_hours": 96.0})

	_event("the_muster", "Something Is Assembling", NarrativeDefs.CAT_REPORT,
		"The watch on the East Wall have stopped counting them individually.",
		"Pressure on the wall is at {threat_pressure} and the thing about that "
		+ "number is that it has been climbing every night rather than "
		+ "oscillating. Whatever is out there is not wandering in. It is being "
		+ "brought.\n\n"
		+ "There are {turrets} guns on the wall and {turret_uptime} of them "
		+ "have heat enough to fire. Both of those numbers are decisions "
		+ "somebody took days ago.",
		[_c(&"threat_pressure", GE, 0.6, 2.0)],
		[],
		{"priority": 84, "once": false, "cooldown_hours": 48.0})

	_event("the_empty_bed", "There Is a Bed Free", NarrativeDefs.CAT_REPORT,
		"The care house has an empty bed in it for the first time since it "
		+ "opened.",
		"Nobody put a notice up. It was noticed by the third person to walk "
		+ "past the door and it was all over Kettle Row by the evening whistle.\n\n"
		+ "Hope stands at {hope}, which is not a number anybody in the Nine has "
		+ "ever been told, and which they can nonetheless read off the fact "
		+ "that the physician was sitting down at four in the afternoon.",
		[_c(&"hope", GE, 62.0, 6.0), _c(&"sick", LE, 0.0), _c(&"day", GE, 2.0)],
		[],
		{"priority": 45, "once": false, "cooldown_hours": 120.0})

	_event("the_machines_stand", "The Floor Is Quiet", NarrativeDefs.CAT_REPORT,
		"{stalled_machines} machines are stopped and the crews are standing "
		+ "next to them.",
		"A stopped machine in {city} is not a machine waiting for a part. It "
		+ "is a machine waiting for a decision that was supposed to have been "
		+ "taken upstream of it: heat that is somewhere else, an input that "
		+ "nobody routed, or a crew that is on the wall instead.\n\n"
		+ "The crews are still being fed. That is the arithmetic that makes an "
		+ "idle machine expensive.",
		[_c(&"stalled_machines", GE, 4.0, 3.0)],
		[],
		{"priority": 58, "once": false, "cooldown_hours": 48.0})

	_event("the_research_bench", "Somebody Worked Something Out",
		NarrativeDefs.CAT_REPORT,
		"The bench in the Survey Hall has produced its first finished thing.",
		"It is not an invention. Nobody in this caldera is inventing anything. "
		+ "It is somebody having the time to sit with a problem for long enough "
		+ "to notice what the column already knew and had written down badly.\n\n"
		+ "{research_done} of those are now done. Every one of them changes "
		+ "something that is already standing, which is the only kind that "
		+ "matters at this temperature.",
		[_c(&"research_done", GE, 1.0)],
		[],
		{"priority": 52})


# ------------------------------------------------------------------ scouts --

func _scouts() -> void:

	_event("word_from_the_road", "What Is on the Survey Road",
		NarrativeDefs.CAT_SCOUT,
		"The party that went east came back a day early and did not want to "
		+ "make a report in front of people.",
		"Nine hours out, on the old survey road, there is a column of carts. "
		+ "Fourteen of them, roped in a line, pointed this way. They are "
		+ "standing up because there is nothing out there to knock them over.\n\n"
		+ "The scouts did not open any of them. They counted the carts, they "
		+ "wrote down the number, and they came back. The one thing they did "
		+ "bring is a child's boot, which one of them has not put down since.",
		[_c(&"day", GE, 4.0)],
		[],
		{"priority": 56, "cause_prose": "Scouts go out because the yard is short. "
			+ "This is what is out there instead of what the yard is short of."})

	_event("the_silent_mast", "The Mast on the Northern Rise",
		NarrativeDefs.CAT_SCOUT,
		"There is a wireless mast eleven hours north, iced to the guys, and it "
		+ "has power.",
		"The scouts could hear the transformer humming from the bottom of the "
		+ "rise. The hut at the base is locked from the inside and the window "
		+ "is frosted over from the inside as well.\n\n"
		+ "Whatever it is transmitting, it is not transmitting to {city}. The "
		+ "column had a receiver on the second sled and it has been silent "
		+ "since the day the column stopped here, and somebody checks it every "
		+ "week anyway.",
		[_c(&"day", GE, 6.0)],
		[],
		{"priority": 54})

	_event("the_crossed_sites", "Three Are Crossed Out", NarrativeDefs.CAT_SCOUT,
		"The survey map has four other sites on it and three of them have a "
		+ "line through them.",
		"The crossings-out are in ink, in a hand that is not on the charter "
		+ "and is not on any of the sled manifests. They were made after the "
		+ "map was printed and before it reached this caldera.\n\n"
		+ "Site Nine has no line through it. That is the entire reason there "
		+ "are {population} people here, and nobody has ever established who "
		+ "did the crossing out or what they were counting.",
		[_c(&"day", GE, 7.0), _c(&"population", GE, 5.0)],
		[],
		{"priority": 50})
