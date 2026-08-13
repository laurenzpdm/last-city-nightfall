class_name NarrativeFlavour
extends RefCounted
## The small writing. What people say in Caldera Nine when nothing important is
## happening, which is most of the time and is when a city is actually built.
##
## THE TEST OF A LINE, and it is enforced in tests/narrative/:
## it names something that exists here. The Hearth, Kettle Row, the East Wall,
## the Long Shaft, the Drop, the second boiler, the sledway, the Ash Stair, a
## ration, a tarp, a valve, a number. A line that would fit any frozen city in
## any game has failed and is deleted, not rewritten.
##
## Every bank is GATED on the same fact table the events use, so nothing is ever
## said that is not true right now. Nobody complains about the cold at plus four
## degrees, and nobody says the queue at the kitchen moved while the larder is
## empty. That gate is the difference between flavour and noise.
##
## Selection is deterministic: Rng.stream("narrative") only, and a bank never
## repeats a line until it has been all the way round. A city that says the same
## sentence twice in five minutes stops being a place.

# =========================================================================
#  the banks
# =========================================================================

## The cold, when the houses are losing.
const COLD: Array[String] = [
	"A woman on Kettle Row has stopped taking her boots off at night. She says it costs her twenty minutes in the morning and she does not have twenty minutes.",
	"The inside of the window at the Survey Hall has half a finger of frost on it and it has not melted at noon for three days.",
	"They have started sleeping four to a bunk on the north side. Not for room. For the heat that comes off a back.",
	"A man came off the rim road with his glove frozen to the sled rope and they had to cut the rope.",
	"The children on the Ash Stair have a game where you hold the iron rail with a bare hand and count. Nobody gets past four.",
	"There is ice inside the pipe at the far end of Kettle Row. You can hear it when the pressure comes up, a knock like someone asking to be let in.",
	"Two of the night shift came back with white fingers and did not say anything about it until the shift after.",
	"The tarp over the east stack froze into one sheet and they burned a whole hour of coal thawing it enough to lift.",
	"An old man sat down against the warm side of the second boiler and had to be told twice that it was his to sit against and not his to stay at.",
	"The water in the buckets on the Ash Stair is solid from the top down and there is no point breaking it before dawn.",
	"Somebody has been sleeping in the radiator housing behind Kettle Row. There is a blanket in there and nobody will say whose.",
	"A girl asked her mother whether the Hearth ever goes out. Her mother said no. Then she went and looked at it herself.",
]

## Hunger, when the larder is thin.
const HUNGER: Array[String] = [
	"The queue at the kitchen has started forming an hour before the whistle. Nobody organised it. It just does that now.",
	"They are grinding the last of the bark into the flour on the quiet. Everybody knows. Nobody says it at the table.",
	"A man in the Long Shaft swapped his ration card for a pair of dry socks and both of them think they got the better end of it.",
	"The soup at the kitchen has gone from grey to a lighter grey and the cook will not be drawn on why.",
	"Somebody got into the granary through the roof and took four days of grain. They left the rest, which is somehow worse.",
	"The children get fed first at the field kitchen now. It was not a law. The women in the queue simply stopped moving until it happened.",
	"A boy fainted on the sledway and swore it was the cold. The cold was minus nine and he had not eaten since the day before.",
	"The kitchen has begun serving the evening bowl a half hour late so that people sleep sooner after it.",
	"They weighed the ration out on the ore scales today because the kitchen scale broke. It reads to the gram and nobody wanted to watch.",
	"There is a rumour that the Survey Hall still has a crate of the original stores. There is not, and someone has already been down there to check.",
	"A woman offered her wedding ring at the granary door for an extra bowl. The clerk gave her the bowl and gave her back the ring, and both of them are in trouble for it.",
	"Two men had a fight on the Ash Stair about a spilled bowl and neither of them could stay standing long enough to finish it.",
]

## The dark outside the wall.
const NIGHT: Array[String] = [
	"The watch on the East Wall counts the lamps along Kettle Row every hour. Fourteen tonight. There were fifteen at dusk.",
	"Something moved on the rim at the edge of the lamplight and stopped when the light swung onto it. That is the part nobody likes.",
	"The whistle at the North Gate is kept greased now. It froze once and the man who was supposed to blow it had to run instead.",
	"You can tell how bad the night is by the Hearth. When it runs hard the snow on the roofs above Kettle Row goes black.",
	"The watch has taken to walking the wall in pairs. Not because of an order. Because of the sound the ice makes on the far side.",
	"A lamp went out on the west drift and the man carrying it was found forty paces on, walking the wrong way in the dark.",
	"They keep a kettle on the wall for the watch. It is the only kettle in the Nine that nobody has ever tried to steal.",
	"The dogs went quiet an hour before anything came last time. There are no dogs left, so there is nothing to go quiet now.",
	"Deep night on the caldera floor is so still that you can hear the boiler cycle from the far side of the rim.",
	"Someone has scratched a tally into the inside of the North Gate. Nobody has told them to stop.",
	"There is a stretch of wall by the sledway where the frost never forms. The watch stands there and does not talk about why.",
	"The lamps get turned down to save oil after the first hour and every watch argues about it and every watch does it anyway.",
]

## A Great Frost, while it is blowing.
const STORM: Array[String] = [
	"The wind came up the caldera wall and took the tarp off the timber stack and the timber with it.",
	"You cannot see the Hearth from the North Gate. It is four hundred paces and a fire the size of a house.",
	"They have roped the Ash Stair. Not to hold it up. To hold people on it.",
	"The snow is coming in flat. It is going into the pipe lagging and it will be water in the lagging when this ends.",
	"The whistle blew at the North Gate and nobody on Kettle Row heard it.",
	"Three of the night shift are sitting it out in the workshop because the walk back is two hundred paces and that is now too far.",
	"A man went out to close a valve at the far end and they sent a second man out on a rope to find the first.",
	"The Hearth is burning at a rate that would have been unthinkable on the first day and it is still losing ground to the wind.",
	"The frost is getting through the west drift boards. You can see it moving along the grain.",
	"Everyone who has a wall between themselves and the west is against it, and everyone who does not is in the corridor.",
	"There is snow inside the Survey Hall, in a long drift, exactly the shape of the gap under the door.",
	"When the Frost eases for a moment you can hear the ice on the rim cracking and settling, and then it starts again.",
]

## The morning after a night that was fought.
const AFTER_ASSAULT: Array[String] = [
	"They are pulling the frozen ones off the wire at the East Wall with hooks because hands do not work for it.",
	"There is a scorch mark eight paces long on the snow below the turret and nobody wants to be the one to shovel it.",
	"The turret on the east side ran dry twelve minutes before dawn and the crew stood there with it anyway.",
	"A section of the East Wall has a dent in it shaped like something's shoulder.",
	"The watch that held the North Gate has not gone to sleep. They are sitting in the kitchen with bowls in front of them, not eating.",
	"They counted the spent casings this morning out of habit and then stopped counting because the number was not going to help.",
	"Somebody has propped the broken palisade section back up with a sled. It will hold for a night. Everyone knows it will hold for a night.",
	"The snow between the gate and the second boiler is churned to grey mud and it will freeze into that shape by evening.",
	"There is blood on the sledway that is not ours and it does not behave like blood.",
	"The Hearth ran flat out for six hours and the pipes on the north run are ticking as they cool.",
	"A watchman came off the wall and asked what day it was, and then asked again ten minutes later.",
	"They have started keeping the gate bar in place through the daylight hours as well.",
]

## Obituary follow-ups, by cause. NarrativeSystem picks the bank by the cause on
## the record so the sentence after a name is never generic.
const GRIEF: Dictionary = {
	&"cold": [
		"They found them sitting up, which is what the cold does, and which is why the ones who find them never get used to it.",
		"There was no bunk and no canvas and there had been no bunk and no canvas for four days.",
		"The hands had to be broken to get them straight. The man who did it went outside afterwards and stayed out a while.",
	],
	&"starvation": [
		"They had been giving half of their bowl to somebody smaller and had told nobody, which is why nobody stopped them.",
		"The ration card in the coat pocket had four days unclipped on it. Four days of not going to the queue.",
		"They weighed nothing at all going onto the sled. The two men carrying it did not comment on it and both of them noticed.",
	],
	&"illness": [
		"The fever went along the bunks in the order they are laid out. You could stand at the door and name who was next.",
		"They were coughing on the Ash Stair for six days and working for five of them.",
		"The care house had the bed ready by then. It was ready two days after it was needed.",
	],
	&"injury": [
		"The bandage was clean, which means somebody spent one of the clean bandages, which means somebody thought there was a chance.",
		"They were carried in from the wall and lasted until the light, and the crew that carried them went straight back out.",
		"It was a fall on the Ash Stair in the dark, and the Ash Stair has been asking for it since the first week.",
	],
	&"exhaustion": [
		"They finished the shift. That is the part that will be repeated, and it should not be the part that is repeated.",
		"They sat down against the pipe run to get warm before walking back and did not get up again.",
		"The foreman had marked them down for the next rotation as well. The mark is still on the board.",
	],
	&"old_age": [
		"They walked in with the founding column and they had a view about how the Hearth should be run and they were mostly right.",
		"They were the last person in the Nine who could remember what the vent looked like before the generator went over it.",
		"They asked to be put where they could see the fire and somebody moved a cot to do it.",
	],
}

## Work, the shaft, the machine floor.
const WORK: Array[String] = [
	"The drill on the west drift is being run twenty minutes past its cycle every time because stopping it costs more than the wear does.",
	"They have marked the good ore face in the Long Shaft with a bootprint in soot. It is not on any map and everybody finds it.",
	"The sorter jams on anything longer than a forearm and there is a man whose whole job is now standing next to it.",
	"Somebody rebuilt the sledway ramp overnight without being told to and it is four inches better and nobody has mentioned it.",
	"The workshop keeps a tally of hours on the wall. Not of output. Of hours.",
	"The smelter crew have learned to hear the moment the charge takes and they will stop mid-sentence for it.",
	"There is a place on the rim road where a loaded sled will get away from you and there is now a post there.",
	"They swapped the two apprentices between the workshop and the shaft because the small one fits the crawl and the tall one can reach the top shelf.",
	"The whistle for shift change is a length of pipe hit with a spanner. It carries better than the real whistle did.",
	"A man has been coming in an hour early to warm the workshop before the others get there, out of nothing but his own idea.",
	"The ore scales in the yard are out by a kilo and everybody has silently agreed to keep using them so the numbers stay comparable.",
	"Two of the sorters have started singing the count and the foreman has decided he did not hear it.",
]

## The machine, when heat is short.
const MACHINE: Array[String] = [
	"The pressure on the north run drops every time the smelter takes a charge, and Kettle Row can feel it through the floor.",
	"They shut the radiator at the far end of the west line to keep the middle of it warm, and the far end is where the latecomers sleep.",
	"There is a valve behind the Survey Hall that somebody keeps opening at night and nobody has caught them.",
	"The second boiler has a seam that weeps and it has been marked for repair for eleven days.",
	"Frost is standing on the outside of the trunk main. That is not condensation. That is heat leaving.",
	"The accumulator went dry at four in the morning and the whole grid felt it in about a minute.",
	"An engineer put a hand flat on the pipe at the far end of Kettle Row and did not say anything, which said it.",
	"They have cut the pressure to the workshop to hold the houses. The workshop crew found out by the machines slowing down.",
	"Somebody has wrapped a run of pipe in blankets. It is against every rule and it is working.",
	"The Hearth is being run harder than the plate on its side says it should be run and the plate is being ignored.",
	"There is a cold spot in the middle of Kettle Row exactly where a pipe was never joined, and every winter somebody rediscovers it.",
	"The gauge on the second boiler has been reading two low since the first week and everyone who matters knows to add two.",
]

## Word from outside the caldera. These are the only lines in the game that
## describe anywhere other than here, and they are all about why nobody left.
const SCOUT: Array[String] = [
	"The scouting party came back off the rim with a sled of coal and one fewer than went out. Nobody has asked which one yet.",
	"There is a column of frozen carts about nine hours out on the old survey road. They are pointed this way. They did not make it this far.",
	"They found a hut on the west rim with a stove in it that had been lit within the month, and nobody in it.",
	"The scouts brought back a survey marker with NINE stamped on it, from a vent that has been dead a long time.",
	"Eleven hours out there is a stand of dead timber still standing up. It is four days of hauling and it is the last of it within reach.",
	"A scout says the ice on the eastern flat has cracked in a straight line for as far as she could see and she does not want to talk about it.",
	"They found a sledge with the runners gone and the load still roped down. Whoever it was took the runners and walked.",
	"The party that went south came back the same day. They say the temperature drops on the far side of the ridge and it drops fast.",
	"There is a wireless mast on the northern rise, up and iced and silent, and it has been silent since before the column stopped here.",
	"The scouts have started leaving a lamp burning at the halfway cairn on the rim road. It has been lit again by somebody else twice.",
	"A scout brought back a child's boot from the frozen column on the road. Just the one. She has not put it down.",
	"They went out to look at the second vent and it is open and it is breathing and it is nine days of walking from here.",
	"The old survey maps have four more sites marked on them. Three are crossed out in a hand nobody recognises.",
	"There is nothing on the horizon in any direction after the third day, which is the report, and which is why the report is short.",
]

## When the city is holding together. Rare, and never triumphant.
const MERCY: Array[String] = [
	"Someone has put a bench on the warm side of the Hearth and three people were sitting on it at once this morning.",
	"A child was born on Kettle Row at some point in the night and the whole row knew before the whistle.",
	"The kitchen had enough to give seconds to the shaft crew and did it without being asked twice.",
	"They got the lamps lit along the whole of the sledway for the first time since the column stopped here.",
	"The care house has an empty bed in it. One. It has been noticed by everybody who walks past.",
	"There was an argument on the Ash Stair about football, of all things, and it went on for twenty minutes.",
	"The night shift came off the wall and there was a fire going in the kitchen and nobody had ordered that either.",
	"Two of the latecomers have been given a bunk on Kettle Row proper and the row did the deciding itself.",
	"A man has started teaching the apprentices to read off the ledger sheets in the hour after the shift.",
	"The Hearth has been steady for a day and a night and people have stopped looking at it every time they pass.",
]

## When the city is coming apart.
const ANGER: Array[String] = [
	"There were forty of them outside the Survey Hall and they did not come in, and that is the part that should worry you.",
	"Somebody has written a number on the wall by the North Gate. It is the number of the dead and it is accurate.",
	"The shaft crew took their full break today for the first time in two weeks and dared anyone to say something.",
	"A foreman was shoved on the sledway and the four men who saw it have all forgotten who did it.",
	"They are meeting in the second workshop after the whistle. Not hiding it. Not inviting anyone either.",
	"The ration queue went quiet when the clerk came out. Not angry. Quiet. Quiet is worse.",
	"Someone cut the lamp rope on the Ash Stair, which is petty, and which is how it starts.",
	"The Hearthside have stopped sending their children to the workshop and they have not said why and they do not have to.",
	"There is a list going round with names on it. Nobody will say what the list is for.",
	"A man stood up at the kitchen and said the count out loud, all of it, every name, and then sat down and ate.",
	"The Watch have started standing in threes. Not against the dark. Against the row.",
	"They have stopped calling it the Survey Hall. They have started calling it your hall.",
]

## The city's own record. Written by whoever is keeping the ledger that week.
const LOG: Array[String] = [
	"Ledger, evening: coal at the yard measured, not estimated. The difference between the two numbers is four days.",
	"Ledger: the north pipe run relagged with sacking. Sacking taken from the granary. Noted here so that the granary knows.",
	"Ledger: two sleds broken on the rim road this week. One repairable. The runners off the other went to the East Wall.",
	"Ledger: shift board rewritten. Six names moved. Two names removed for the usual reason.",
	"Ledger: the Hearth burned through the night at full draw. Consumption entered below. Do not average this week against last.",
	"Ledger, morning: headcount taken at the kitchen rather than at the bunks, because the bunks are no longer where people sleep.",
	"Ledger: the second boiler is off the schedule and onto the watch list. Whoever reads this next, look at the seam.",
	"Ledger: lamp oil issued to the wall against the standing order. I signed for it. It was minus twenty six.",
	"Ledger: the tally on the North Gate has been transcribed here so that it does not have to stay on the gate.",
	"Ledger: ore from the west drift assaying poorer than the survey said. The survey was written in summer, by people who left.",
	"Ledger: no entry for the dead today. First time in nine days. Recording the absence so it counts as something.",
	"Ledger: closing the week. Timber down, coal down, people down, walls up. Make of that what you will, whoever you are.",
]


# =========================================================================
#  the banks, indexed
# =========================================================================

const BANK_COLD: StringName = &"cold"
const BANK_HUNGER: StringName = &"hunger"
const BANK_NIGHT: StringName = &"night"
const BANK_STORM: StringName = &"storm"
const BANK_ASSAULT: StringName = &"assault"
const BANK_WORK: StringName = &"work"
const BANK_MACHINE: StringName = &"machine"
const BANK_SCOUT: StringName = &"scout"
const BANK_MERCY: StringName = &"mercy"
const BANK_ANGER: StringName = &"anger"
const BANK_LOG: StringName = &"log"

## Sorted. Every iteration goes through this, never over a Dictionary's keys.
const BANK_IDS: Array[StringName] = [
	&"anger", &"assault", &"cold", &"hunger", &"log", &"machine", &"mercy",
	&"night", &"scout", &"storm", &"work",
]


static func bank(id: StringName) -> Array[String]:
	match id:
		&"cold": return COLD
		&"hunger": return HUNGER
		&"night": return NIGHT
		&"storm": return STORM
		&"assault": return AFTER_ASSAULT
		&"work": return WORK
		&"machine": return MACHINE
		&"scout": return SCOUT
		&"mercy": return MERCY
		&"anger": return ANGER
		&"log": return LOG
	return []


static func grief_bank(cause: StringName) -> Array[String]:
	var raw: Array = GRIEF.get(cause, [])
	var out: Array[String] = []
	for s: Variant in raw:
		out.append(String(s))
	return out


static func grief_causes() -> Array[StringName]:
	var keys: Array = GRIEF.keys()
	keys.sort()
	var out: Array[StringName] = []
	for k: StringName in keys:
		out.append(k)
	return out


## Every line in the part, for the content suite to check as one body of text.
static func every_line() -> PackedStringArray:
	var out := PackedStringArray()
	for id: StringName in BANK_IDS:
		for line: String in bank(id):
			out.append(line)
	for cause: StringName in grief_causes():
		for line: String in grief_bank(cause):
			out.append(line)
	return out


static func total_lines() -> int:
	return every_line().size()


# =========================================================================
#  when each bank is allowed to speak
# =========================================================================
##
## The gate is the whole point. A city that complains about the cold while the
## houses are warm is a city that is generating text, and generated text is
## worth nothing. Each row is {bank, all_of}, evaluated against the same fact
## table the events use.

static func gates() -> Array[Dictionary]:
	var g: Array[Dictionary] = []
	g.append({"bank": BANK_COLD, "weight": 3, "all_of": [
		NarrativeCondition.make(&"avg_warmth", NarrativeDefs.Cmp.LE, 55.0)]})
	g.append({"bank": BANK_HUNGER, "weight": 3, "all_of": [
		NarrativeCondition.make(&"food_days", NarrativeDefs.Cmp.LE, 3.0),
		NarrativeCondition.make(&"population", NarrativeDefs.Cmp.GE, 1.0)]})
	g.append({"bank": BANK_NIGHT, "weight": 2, "all_of": [
		NarrativeCondition.make(&"is_night", NarrativeDefs.Cmp.GE, 1.0),
		NarrativeCondition.make(&"storm_active", NarrativeDefs.Cmp.LE, 0.0)]})
	g.append({"bank": BANK_STORM, "weight": 5, "all_of": [
		NarrativeCondition.make(&"storm_active", NarrativeDefs.Cmp.GE, 1.0)]})
	g.append({"bank": BANK_ASSAULT, "weight": 5, "all_of": [
		NarrativeCondition.make(&"waves_cleared", NarrativeDefs.Cmp.GE, 1.0),
		NarrativeCondition.make(&"is_night", NarrativeDefs.Cmp.LE, 0.0)]})
	g.append({"bank": BANK_WORK, "weight": 2, "all_of": [
		NarrativeCondition.make(&"is_night", NarrativeDefs.Cmp.LE, 0.0),
		NarrativeCondition.make(&"buildings", NarrativeDefs.Cmp.GE, 6.0)]})
	g.append({"bank": BANK_MACHINE, "weight": 4, "all_of": [
		NarrativeCondition.make(&"heat_deficit", NarrativeDefs.Cmp.GT, 0.5)]})
	g.append({"bank": BANK_SCOUT, "weight": 2, "all_of": [
		NarrativeCondition.make(&"day", NarrativeDefs.Cmp.GE, 2.0),
		NarrativeCondition.make(&"is_night", NarrativeDefs.Cmp.LE, 0.0)]})
	g.append({"bank": BANK_MERCY, "weight": 2, "all_of": [
		NarrativeCondition.make(&"hope", NarrativeDefs.Cmp.GE, 55.0),
		NarrativeCondition.make(&"avg_warmth", NarrativeDefs.Cmp.GE, 60.0)]})
	g.append({"bank": BANK_ANGER, "weight": 4, "all_of": [
		NarrativeCondition.make(&"discontent", NarrativeDefs.Cmp.GE, 45.0)]})
	g.append({"bank": BANK_LOG, "weight": 1, "all_of": [
		NarrativeCondition.make(&"day", NarrativeDefs.Cmp.GE, 1.0)]})
	return g
