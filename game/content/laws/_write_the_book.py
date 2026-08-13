#!/usr/bin/env python3
"""THE BOOK OF LAWS. [P06] society owns this file.

Every law in the game is written here and emitted as one .tres per law into the
same directory. Registry picks the .tres files up by directory scan; this script
is never loaded by the game and Godot ignores it.

It exists because the book is a piece of WRITING before it is a data structure.
Thirty one separate .tres files cannot be read as a document, cannot be checked
for repeated phrasing, and cannot be edited for voice. This can.

    python3 game/content/laws/_write_the_book.py

Rules the content obeys, enforced by LawDef.validate() and tests/society:
  * every law costs the player something a player cares about
  * every law has prose, a case for, a case against, and a line for the morning
    after it comes into force
  * every law is reachable from an empty book
  * exclusions are declared once and made symmetric by LawBook
"""
import os, sys

OUT = os.path.dirname(os.path.abspath(__file__))

TRUNK, ORDER, FAITH = "trunk", "order", "faith"

L = []


def law(**kw):
    L.append(kw)


# =====================================================================
#  TRUNK: the things every city out here has to decide
# =====================================================================

law(
    id="emergency_shift", title="Emergency Shift", branch=TRUNK, tier=1,
    section="Labour", sort_order=10,
    prose="The working day is extended to fourteen hours until further notice. There is no further notice written into this law, and everyone who signs it knows that.",
    argument_for="The wall is not finished. The wall does not care that people are tired.",
    argument_against="Four more hours in this cold is not four more hours of work. It is four more hours of frostbite.",
    signed_line="The whistle went at fourteen hours instead of ten. Nobody argued. Two men had to be helped down off the scaffold.",
    hope_on_sign=1.0, discontent_on_sign=3.0, discontent_rate=0.35,
    policy={"work_hours": 4.0},
    approval={"workers": -18.0, "watch": 6.0},
    provokes=["overwork"], tags=["costly"],
)

law(
    id="extended_shift", title="Extended Shift", branch=TRUNK, tier=2,
    section="Labour", sort_order=20, min_day=2, debate_hours=5.0,
    requires=["emergency_shift"],
    prose="Eighteen hours. The law stops using the word shift, because there is no longer anything to be off duty from. It uses the word duty.",
    argument_for="There is a storm four days out and a wall that is two thirds of a wall.",
    argument_against="You are spending people. Say it plainly. You are spending people to buy time.",
    signed_line="The night crew and the day crew are the same crew now. They sleep where they work and eat standing up.",
    hope_on_sign=-2.0, discontent_on_sign=6.0, discontent_rate=0.80,
    policy={"work_hours": 4.0, "labour_pool": 0.10},
    approval={"workers": -30.0, "families": -10.0},
    provokes=["overwork", "sickness"], tags=["cruel"],
)

law(
    id="child_shelter_duty", title="Child Shelter Duty", branch=TRUNK, tier=1,
    section="The Children", sort_order=30,
    excludes=["child_labour"],
    prose="Every child over ten is assigned indoor work: sorting, mending, carrying, minding the younger ones. They stay warm, they stay watched, and they are useful, and the law is careful to list those three in that order.",
    argument_for="A child with nothing to do in a city like this finds something to do, and it is never good.",
    argument_against="They are ten. In four years they will be fourteen and you will have got used to this.",
    signed_line="The children were counted, given armbands and put to sorting scrap in the lee of the workshop. They thought it was a game for about two days.",
    hope_on_sign=2.0, discontent_on_sign=1.5,
    policy={"labour_pool": 0.06, "crowding": 0.15},
    approval={"families": 16.0, "workers": -4.0},
    relieves=["children"],
)

law(
    id="child_labour", title="Child Labour", branch=TRUNK, tier=1,
    section="The Children", sort_order=31,
    excludes=["child_shelter_duty"],
    prose="Children over ten work where they are needed, which means where a grown body will not fit: inside the machine housings, at the bottom of the shaft, along the pipe runs. The law does not set a lower age. It sets a height.",
    argument_for="There are gaps in the works a man cannot reach. Somebody has to reach them.",
    argument_against="We came out here so they would have somewhere to grow up. You are going to send them down a hole.",
    signed_line="They went down at first light with the small lamps. One of them came back up asking whether this counted as being grown up now.",
    hope_on_sign=-6.0, discontent_on_sign=9.0, discontent_rate=0.50,
    policy={"labour_pool": 0.28, "child_risk": 0.10},
    approval={"families": -40.0, "workers": 8.0},
    flags=["child_labour"], provokes=["children", "sickness"], tags=["cruel"],
)

law(
    id="apprentices", title="Apprentices", branch=TRUNK, tier=2,
    section="The Children", sort_order=32, min_day=3,
    requires=["child_shelter_duty"],
    prose="The older children are bound to the engineers. They learn the trade by doing the parts of it nobody senior wants to do, at the hours nobody senior wants to work.",
    argument_for="In ten years somebody will have to know how the generator works. It will not be us.",
    argument_against="You took the indoor promise and you have quietly moved where indoors ends.",
    signed_line="Four of them sign for parts in their own hand now. One has started correcting the foreman, and the foreman has not decided how to feel about it.",
    hope_on_sign=2.0, discontent_on_sign=2.0,
    policy={"labour_pool": 0.14, "child_risk": 0.04},
    approval={"families": -8.0, "workers": 10.0},
)

law(
    id="soup_ration", title="Watered Soup", branch=TRUNK, tier=1,
    section="Food", sort_order=40,
    prose="The ration is cut to three quarters. The kitchens are instructed to make up the difference with water and to serve it hot, because heat in the bowl reads as food to a body that has not had any.",
    argument_for="Three quarters of a meal every day beats a full meal for three days and then nothing at all.",
    argument_against="You cannot dig on this. Try it yourself for a week and then come back and read us the numbers again.",
    signed_line="The bowls came back the same size and lighter. People stopped talking during meals, which is how you could tell.",
    hope_on_sign=-2.5, discontent_on_sign=4.0, discontent_rate=0.30,
    policy={"ration": -0.25},
    approval={"workers": -16.0, "infirm": -10.0},
    provokes=["hunger"], tags=["costly"],
)

law(
    id="sawdust_bread", title="Sawdust in the Bread", branch=TRUNK, tier=2,
    section="Food", sort_order=41, min_day=2,
    requires=["soup_ration"],
    prose="Wood flour, bone meal and whatever else the mill will grind are added to the bread at up to a third by weight. The law requires that this be done. It does not require that it be announced.",
    argument_for="It fills them. It stops the shaking. It gets us to the thaw.",
    argument_against="It gives them nothing. You are feeding people the idea of food and charging their bodies for it.",
    signed_line="The bread came out heavier and darker and it did not go stale, because there was nothing in it that could. Everyone knew by the second morning.",
    hope_on_sign=-4.0, discontent_on_sign=3.0, hope_rate=-0.25,
    policy={"food_yield": 0.35, "medical_care": -0.10},
    approval={"workers": -12.0, "families": -10.0, "infirm": -14.0},
    flags=["sawdust"], provokes=["sickness"], tags=["cruel"],
)

law(
    id="foreman_rations", title="Foreman's Portion", branch=TRUNK, tier=2,
    section="Food", sort_order=42,
    requires=["emergency_shift"],
    prose="Shift leaders, engineers and the generator crew eat first and eat full. The law lists the posts by name. Everyone else can read the list.",
    argument_for="The person who keeps the generator lit should not be light headed while doing it.",
    argument_against="You have just written down, in the book, in ink, who matters.",
    signed_line="The list went up by the kitchen door. People read it on the way in and again on the way out.",
    hope_on_sign=-2.0, discontent_on_sign=5.0, discontent_rate=0.25,
    policy={"labour_pool": 0.12, "ration": -0.05},
    approval={"workers": -20.0, "watch": 14.0},
    provokes=["hunger", "disorder"],
)

law(
    id="snow_burial", title="Snow Burial", branch=TRUNK, tier=1,
    section="The Dead", sort_order=50,
    excludes=["corpse_pits", "named_graves"],
    prose="The dead are carried a mile out past the north marker, laid out and covered. The law specifies the distance. It does not specify what happens after.",
    argument_for="It is clean, it costs nothing, and the cold keeps them better than we ever could.",
    argument_against="A mile out is not a grave. It is a place you cannot bear to walk to.",
    signed_line="There is a line of shapes under the snow past the north marker, and people have started walking out to it on their own.",
    hope_on_sign=-1.0, discontent_on_sign=-2.0,
    policy={"corpse_capacity": 8.0},
    approval={"faithful": -8.0},
    relieves=["dead_unburied"],
)

law(
    id="corpse_pits", title="The Pits", branch=TRUNK, tier=1,
    section="The Dead", sort_order=51,
    excludes=["snow_burial", "named_graves"],
    prose="The dead go into a trench cut through the permafrost by the north gate, and the trench is worked back over with drill spoil. The law does not require a count, a name or a marker. The absence is deliberate and it is what makes the work fast.",
    argument_for="There is a fever in this city and the dead are part of why.",
    argument_against="You are not going to bury them, you are going to lose them. Nobody will be able to say where their own mother went.",
    signed_line="The trench took four hours and swallowed everything we had been keeping under the tarp. By the afternoon you could not tell it from the rest of the ground.",
    hope_on_sign=-4.0, discontent_on_sign=2.0,
    policy={"corpse_capacity": 30.0, "medical_care": 0.05},
    approval={"faithful": -26.0, "families": -12.0, "infirm": 6.0},
    relieves=["dead_unburied", "sickness"], tags=["cruel"],
)

law(
    id="named_graves", title="Named Graves", branch=TRUNK, tier=1,
    section="The Dead", sort_order=52,
    excludes=["snow_burial", "corpse_pits"],
    prose="Every death is dug, marked and recorded by name, and the ground is opened with steam to make that possible. The law sets aside heat for the work. That is the whole cost of it and the whole point of it.",
    argument_for="A city that cannot bury its dead is not a city. It is a work site with people on it.",
    argument_against="You are spending heat on the ones who are already gone while the living queue for what is left.",
    signed_line="There are markers past the north gate now and each one has a name cut into it. People walk out there in weather they would not walk out in for anything else.",
    hope_on_sign=5.0, discontent_on_sign=-3.0, hope_rate=0.25,
    policy={"corpse_capacity": 6.0, "solace": 0.30},
    approval={"faithful": 26.0, "families": 18.0, "workers": -6.0},
    relieves=["dead_unburied"], tags=["costly"],
)

law(
    id="rendering", title="Rendering", branch=TRUNK, tier=3,
    section="The Dead", sort_order=53, min_day=4, debate_hours=6.0,
    requires=["corpse_pits", "sawdust_bread"],
    prose="Organic matter recovered at the north gate is processed at the kitchens. The law is written entirely in that register and never once uses a plainer word, and every person who signs it understands the omission perfectly.",
    argument_for="We are throwing away the only thing in this valley that is not frozen solid.",
    argument_against="There is a line. You have been walking towards it all week and this is it.",
    signed_line="The soup was thicker. Nobody asked. That is the part that will not leave anyone: nobody asked.",
    hope_on_sign=-14.0, discontent_on_sign=10.0, hope_rate=-1.10,
    policy={"food_yield": 0.55, "corpse_capacity": 40.0},
    approval={"faithful": -50.0, "families": -40.0, "infirm": -25.0, "workers": -18.0},
    flags=["rendering"], provokes=["fear", "faithless"], tags=["cruel", "unforgivable"],
)

law(
    id="care_house", title="The Care House", branch=TRUNK, tier=1,
    section="The Sick", sort_order=60,
    prose="One heated building is given over entirely to the sick, staffed off the work roster, and no other use may be made of it. The law is short because the argument was about the heat, not about the words.",
    argument_for="Fever moves through a bunkhouse in a day. Put a door between it and everyone else.",
    argument_against="That is a building, a stove and four pairs of hands doing nothing that keeps the rest of us alive.",
    signed_line="There is a building with a door that shuts and somebody in it who is not also on shift. It is the warmest room in the city and nobody resents it out loud.",
    hope_on_sign=4.0, discontent_on_sign=-3.0,
    policy={"medical_care": 0.55, "labour_pool": -0.06},
    approval={"infirm": 30.0, "families": 14.0, "workers": -4.0},
    relieves=["sickness"], tags=["costly"],
)

law(
    id="triage", title="Triage", branch=TRUNK, tier=2,
    section="The Sick", sort_order=61, min_day=2,
    requires=["care_house"],
    prose="The care house is instructed to sort. Those who will recover are treated. Those who will not are moved to the back room, given something for the pain, and are not treated further. The law names the back room.",
    argument_for="We have medicine for eleven people and nineteen people who need it. Somebody has to choose, and it should be written down rather than whispered.",
    argument_against="You have put a door on the far side of that building and everyone already knows what it is for.",
    signed_line="The back room has a stove of its own and a curtain across it. Nobody goes in there twice.",
    hope_on_sign=-5.0, discontent_on_sign=5.0, discontent_rate=0.30,
    policy={"medical_care": 0.30, "labour_pool": 0.04},
    approval={"infirm": -34.0, "faithful": -14.0, "workers": 6.0},
    flags=["triage"], provokes=["fear", "sickness"], tags=["cruel"],
)

law(
    id="double_bunks", title="Double Bunks", branch=TRUNK, tier=1,
    section="Shelter", sort_order=70,
    prose="Two to a bunk, head to foot, in every room in the city. A house built for twelve will hold twenty, and the extra bodies will hold the room a few degrees above whatever the stove manages on its own.",
    argument_for="There are people on the ice tonight who will not be there in the morning.",
    argument_against="Fever moves through a crowded room the way water moves downhill.",
    signed_line="The carpenters worked through the night. By dawn every room had twice as many beds in it and half as much air.",
    hope_on_sign=2.0, discontent_on_sign=2.0,
    policy={"shelter_capacity": 0.65, "crowding": 0.35},
    approval={"latecomers": 26.0, "families": -10.0, "infirm": -12.0},
    relieves=["homeless"], provokes=["sickness"],
)

law(
    id="night_curfew", title="Night Curfew", branch=TRUNK, tier=1,
    section="Shelter", sort_order=71,
    prose="From dusk the streets are closed and every unit of heat that would have gone to a workshop goes to the housing instead. The machines stand cold until dawn. So does anyone found outside them.",
    argument_for="Nothing we make at night is worth what the night takes out of us to make it.",
    argument_against="The wall does not build itself in daylight only, and the thing out there does not keep office hours.",
    signed_line="The works went quiet at dusk for the first time since we arrived, and the houses were warm enough that you could hear people talking through the walls.",
    hope_on_sign=3.0, discontent_on_sign=-2.0,
    policy={"heat_priority_housing": 1.0, "work_hours": -1.5, "labour_pool": -0.08},
    approval={"families": 20.0, "workers": 8.0, "watch": -8.0},
    relieves=["cold"], flags=["curfew"],
)

# =====================================================================
#  THE FORK
# =====================================================================

FORK_ANY = ["emergency_shift", "soup_ration", "double_bunks", "night_curfew",
            "child_labour", "child_shelter_duty", "care_house"]

law(
    id="path_of_order", title="The Watch", branch=ORDER, tier=3,
    section="Discipline", sort_order=100, min_day=2, debate_hours=5.0,
    requires_any=FORK_ANY, excludes=["path_of_faith"],
    prose="A standing body of volunteers is given authority over the streets, the ration line and the work roster. They answer to the hall and to nothing else. They are given armbands, because the law is clear that they must be visible.",
    argument_for="There were three fights at the ration line today and nobody stopped any of them.",
    argument_against="Every one of them is somebody's neighbour, right up until the morning they are not.",
    signed_line="Eleven armbands went out. By the second day people had stopped calling them by their first names.",
    hope_on_sign=-1.0, discontent_on_sign=-4.0,
    policy={"discipline": 0.45},
    approval={"watch": 34.0, "faithful": -12.0, "workers": -6.0},
    relieves=["disorder"], provokes=["fear", "faithless"],
)

law(
    id="path_of_faith", title="The Ember Congregation", branch=FAITH, tier=3,
    section="Faith", sort_order=100, min_day=2, debate_hours=5.0,
    requires_any=FORK_ANY, excludes=["path_of_order"],
    prose="The generator hall is opened in the evenings, and what happens there is not the hall's business. The law grants the space, the fuel and the hour, and declines to name what is being done with them.",
    argument_for="You keep the fire and you will not say what it is. Let us give it a name.",
    argument_against="Once they have a name for it they will have rules about it, and the rules will not be yours.",
    signed_line="Two hundred people stood around a generator in the dark and said nothing for a long time, and then went home warmer than the heat alone accounts for.",
    hope_on_sign=5.0, discontent_on_sign=-3.0,
    policy={"solace": 0.50},
    approval={"faithful": 36.0, "watch": -12.0},
    relieves=["faithless"], provokes=["disorder"], flags=["prayer"],
)

# =====================================================================
#  ORDER
# =====================================================================

law(
    id="watch_patrols", title="Patrols", branch=ORDER, tier=4,
    section="Discipline", sort_order=110,
    requires=["path_of_order"],
    prose="The Watch walks fixed routes through the night, in pairs, with lamps. Anyone outside without a work chit is walked home. The law does not define walked.",
    argument_for="Somebody has to be awake and looking outward.",
    argument_against="They are not looking outward.",
    signed_line="There are lamps moving between the houses all night now. It is either reassuring or it is not, depending on which house you are standing in.",
    hope_on_sign=-1.0, discontent_on_sign=-3.0, discontent_rate=-0.20,
    policy={"discipline": 0.35},
    approval={"watch": 18.0, "families": -10.0},
    relieves=["disorder"], provokes=["fear"],
)

law(
    id="public_penance", title="The Post", branch=ORDER, tier=5,
    section="Discipline", sort_order=120, min_day=3,
    requires=["watch_patrols"],
    prose="Offenders are bound to a post in the square for a stated number of hours, in the open, in whatever the weather is doing. The law states the hours by offence. It does not state the temperature, and the temperature is what does the work.",
    argument_for="A cell is a warm room and a rest. This is not.",
    argument_against="You are using the cold as a tool. The cold is the enemy. Choose one.",
    signed_line="The first man was up for four hours for stealing coal. Everyone walked past him and everyone looked, and that was the point, and it worked.",
    hope_on_sign=-5.0, discontent_on_sign=-6.0,
    policy={"discipline": 0.55},
    approval={"watch": 14.0, "families": -20.0, "faithful": -14.0, "infirm": -10.0},
    provokes=["fear"], tags=["cruel"],
)

law(
    id="informers", title="Whispers", branch=ORDER, tier=5,
    section="Discipline", sort_order=121, min_day=3,
    requires=["watch_patrols"],
    prose="Any person may report any other person to the Watch, and the report is heard without the reporter being named. The law provides a box by the hall door for the purpose.",
    argument_for="Half the theft in this city happens in rooms we are never invited into.",
    argument_against="You have just turned every conversation in the city into a risk somebody is taking.",
    signed_line="The box was full by the second morning. Most of it was about food. Some of it was about nothing at all, from people who wanted to be seen using the box.",
    hope_on_sign=-4.0, discontent_on_sign=-5.0, hope_rate=-0.35,
    policy={"discipline": 0.45},
    approval={"watch": 16.0, "families": -22.0, "workers": -16.0},
    flags=["informers"], provokes=["fear"], tags=["cruel"],
)

law(
    id="press_gangs", title="Press Gangs", branch=ORDER, tier=6,
    section="Labour", sort_order=130, min_day=4,
    requires=["public_penance"],
    prose="The Watch may take any able person off any queue and put them on any work detail for the remainder of the day. No notice, no appeal. The law says so in one sentence and then stops.",
    argument_for="We are eleven bodies short on the wall and there are forty people standing in a line for soup.",
    argument_against="You have stopped asking. There is no version of this where you start asking again.",
    signed_line="They took nine men out of the ration queue before it reached the pot. Those nine did not eat that day and everyone else ate in silence.",
    hope_on_sign=-6.0, discontent_on_sign=7.0, discontent_rate=0.45,
    policy={"labour_pool": 0.30, "ration": -0.05, "discipline": 0.20},
    approval={"workers": -34.0, "watch": 10.0},
    flags=["press_gangs", "elder_labour"], provokes=["overwork", "fear"], tags=["cruel"],
)

law(
    id="the_pit", title="The Fighting Pit", branch=ORDER, tier=6,
    section="Discipline", sort_order=131, min_day=4,
    requires=["public_penance"],
    prose="A ring is cut into the ice behind the workshops and disputes may be settled in it by consent, with the Watch keeping time. The law calls this a release of tension, and the law is not wrong.",
    argument_for="They are going to hit each other regardless. Let them do it somewhere we can count them afterwards.",
    argument_against="You will be charging admission by the end of the month and you already know it.",
    signed_line="Two hundred people stood around a hole in the ice and shouted themselves hoarse, and for one hour nobody in this city was thinking about the cold. Somebody lost three fingers.",
    hope_on_sign=-3.0, discontent_on_sign=-8.0, discontent_rate=-0.55,
    policy={"discipline": 0.30, "medical_care": -0.08},
    approval={"workers": 12.0, "faithful": -20.0, "infirm": -14.0, "families": -12.0},
    flags=["fighting_pit"], provokes=["sickness"], tags=["cruel"],
)

law(
    id="martial_law", title="Martial Law", branch=ORDER, tier=7,
    section="Discipline", sort_order=140, min_day=4, debate_hours=6.0,
    requires=["informers", "public_penance"],
    prose="The hall's word is the only word. Assembly of more than four persons requires a chit. Work assignment is not appealable. The law is one page long and eleven of its lines begin with the word no.",
    argument_for="There is a crowd in the square and it has not gone home for two days.",
    argument_against="This is the last page you get to write. After this the book writes you.",
    signed_line="The square was cleared before dawn without anyone being hurt, which the hall considers a success and which nobody who was standing in the square considers anything at all.",
    hope_on_sign=-9.0, discontent_on_sign=-14.0, hope_rate=-0.60,
    policy={"discipline": 0.85, "labour_pool": 0.10},
    approval={"watch": 26.0, "workers": -26.0, "families": -28.0, "faithful": -24.0},
    flags=["martial_law"], provokes=["fear"], tags=["cruel"],
)

law(
    id="new_order", title="The New Order", branch=ORDER, tier=8,
    section="Discipline", sort_order=150, min_day=6, debate_hours=8.0,
    requires=["martial_law", "press_gangs"],
    prose="The city is reconstituted as a single work company under the hall. Housing, food, labour and movement are assigned. There is no clause covering how this ends. The omission was raised during the reading and was not addressed.",
    argument_for="It works. Look out of the window. It works.",
    argument_against="Yes. That is what everyone is afraid of.",
    signed_line="Everyone has a number now and the numbers are painted on the doors. The city runs better than it has ever run, and nobody has said a single unnecessary word in a week.",
    hope_on_sign=-12.0, discontent_on_sign=-20.0, hope_rate=-1.00,
    policy={"discipline": 1.00, "labour_pool": 0.25, "work_hours": 2.0},
    approval={"watch": 30.0, "workers": -20.0, "families": -30.0, "faithful": -34.0, "latecomers": -20.0},
    flags=["new_order", "elder_labour"], provokes=["fear", "faithless"], tags=["cruel", "unforgivable"],
)

# =====================================================================
#  FAITH
# =====================================================================

law(
    id="evening_prayer", title="Evening Prayer", branch=FAITH, tier=4,
    section="Faith", sort_order=110,
    requires=["path_of_faith"],
    prose="An hour is set aside at dusk. Attendance is not required, and is noted. The law is careful about that distinction, and everybody in the congregation understood it immediately.",
    argument_for="People need somewhere to put the day when it is over.",
    argument_against="Attendance is noted. Read that sentence again.",
    signed_line="The hour is kept. People who swore they would not go are going, and the people who go are watching who does not.",
    hope_on_sign=4.0, discontent_on_sign=-3.0,
    policy={"solace": 0.35, "work_hours": -0.5},
    approval={"faithful": 22.0, "workers": -6.0},
    relieves=["faithless"], flags=["prayer"],
)

law(
    id="house_of_prayer", title="House of Prayer", branch=FAITH, tier=5,
    section="Faith", sort_order=120, min_day=3,
    requires=["evening_prayer"],
    prose="A heated building is given to the congregation. It is also where the sick are taken, because the congregation asked for that and the hall could not think of a reason to refuse that it was willing to say out loud.",
    argument_for="They will sit with the fevered when nobody else will go near them. They have been doing it already, without being asked.",
    argument_against="You have handed them the sick. Think about what that means the next time you want something from them.",
    signed_line="There is a warm room with a roof on it and people inside who are not on the work roster, and every one of them is there because they chose to be.",
    hope_on_sign=5.0, discontent_on_sign=-4.0,
    policy={"solace": 0.30, "medical_care": 0.35, "labour_pool": -0.05},
    approval={"faithful": 26.0, "infirm": 22.0, "watch": -10.0},
    relieves=["sickness", "faithless"], tags=["costly"],
)

law(
    id="rite_of_ash", title="The Rite of Ash", branch=FAITH, tier=5,
    section="The Dead", sort_order=121, min_day=3,
    requires=["house_of_prayer"], excludes=["corpse_pits", "snow_burial"],
    prose="The dead are given to the generator's intake at the turn of the night, with the congregation present, and their ash is kept in the hall. The law grants the fuel and the hour and requires that the names be read aloud.",
    argument_for="They go into the fire that keeps the rest of us alive. There is worse to be than that.",
    argument_against="You are putting people in the furnace and calling it a sacrament, and one day somebody will drop the second half of that sentence.",
    signed_line="The names were read out over the intake and the fire took them one at a time. The hall smelled of it for two days and nobody complained about that either.",
    hope_on_sign=2.0, discontent_on_sign=-4.0,
    policy={"corpse_capacity": 25.0, "solace": 0.25},
    approval={"faithful": 24.0, "infirm": 8.0, "families": -8.0},
    relieves=["dead_unburied"],
)

law(
    id="faith_keepers", title="The Kindled", branch=FAITH, tier=6,
    section="Faith", sort_order=130, min_day=4,
    requires=["house_of_prayer"],
    prose="The congregation may appoint keepers to hold order at the hour and at the ration line. They carry no weapon. The law is specific about that and silent about everything else they carry.",
    argument_for="They do not need telling twice and they do not need paying.",
    argument_against="You have made a second Watch and you are not the one who commands it.",
    signed_line="They stand at the doors now, at prayer and at the kitchen both, and people have begun deciding what to say before they reach the front of the queue.",
    hope_on_sign=-2.0, discontent_on_sign=-7.0, hope_rate=-0.20,
    policy={"discipline": 0.55, "solace": 0.20},
    approval={"faithful": 28.0, "watch": -20.0, "workers": -10.0},
    flags=["zealots"], provokes=["fear", "disorder"],
)

law(
    id="last_warmth", title="The Last Warmth", branch=FAITH, tier=6,
    section="The Dead", sort_order=131, min_day=5, debate_hours=6.0,
    requires=["rite_of_ash"],
    prose="Any person may declare for the Last Warmth: they give up their place at the stove, walk out past the north marker at dusk, and do not come back. The law makes it voluntary. It also makes it public, and it prints the names.",
    argument_for="My hands do not work any more. I am four bowls a day and a bunk and nothing else, and I would like to be the one who chooses.",
    argument_against="Print a list of who is a burden and you will never need to force anybody. That is the whole trick, and you know it is the whole trick.",
    signed_line="Nine walked out at dusk with the congregation behind them as far as the marker. The oldest was sixty one. Every one of them was already on the list before they volunteered.",
    hope_on_sign=-8.0, discontent_on_sign=-5.0, hope_rate=-0.50,
    policy={"ration": 0.10, "medical_care": 0.10, "solace": 0.15},
    approval={"infirm": -40.0, "faithful": 20.0, "workers": 10.0, "families": -18.0},
    provokes=["fear"], tags=["cruel"],
)

law(
    id="new_faith", title="The New Faith", branch=FAITH, tier=7,
    section="Faith", sort_order=140, min_day=6, debate_hours=8.0,
    requires=["faith_keepers", "last_warmth"],
    prose="The fire is declared the centre of the city in the ordinary legal sense: the hall serves it, the roster serves it, and the wording is chosen so that a future hall cannot say otherwise. The final clause makes the congregation the interpreter of the law. The reading passed over that clause quickly.",
    argument_for="They will die for it. Do you understand what you are being handed?",
    argument_against="Yes. That is exactly the problem.",
    signed_line="The generator has a name now. Nobody voted on it and everybody uses it, and the hall found out what it was from a child.",
    hope_on_sign=6.0, discontent_on_sign=-16.0, hope_rate=0.30,
    policy={"solace": 0.85, "discipline": 0.55, "labour_pool": 0.15},
    approval={"faithful": 40.0, "watch": -30.0, "workers": -12.0, "families": -14.0},
    flags=["new_faith"], provokes=["disorder", "fear"], tags=["unforgivable"],
)


# =====================================================================
#  emit
# =====================================================================

def esc(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def sn_array(name, values):
    if not values:
        return ""
    inner = ", ".join('&"%s"' % v for v in values)
    return "%s = Array[StringName]([%s])\n" % (name, inner)


def f_dict(name, d):
    if not d:
        return ""
    lines = ",\n".join('&"%s": %s' % (k, repr(float(v))) for k, v in sorted(d.items()))
    return "%s = Dictionary[StringName, float]({\n%s\n})\n" % (name, lines)


def emit(law):
    p = law
    out = ['[gd_resource type="Resource" script_class="LawDef" format=3]\n\n']
    out.append('[ext_resource type="Script" path="res://game/sim/society/law_def.gd" id="1_law"]\n\n')
    out.append("[resource]\n")
    out.append('resource_name = "%s"\n' % esc(p["title"]))
    out.append('script = ExtResource("1_law")\n')
    out.append('id = &"%s"\n' % p["id"])
    out.append('title = "%s"\n' % esc(p["title"]))
    out.append('branch = &"%s"\n' % p["branch"])
    out.append("tier = %d\n" % p["tier"])
    out.append('section = "%s"\n' % esc(p.get("section", "")))
    out.append("sort_order = %d\n" % p.get("sort_order", 0))
    out.append('prose = "%s"\n' % esc(p["prose"]))
    out.append('argument_for = "%s"\n' % esc(p["argument_for"]))
    out.append('argument_against = "%s"\n' % esc(p["argument_against"]))
    out.append('signed_line = "%s"\n' % esc(p["signed_line"]))
    out.append(sn_array("requires", p.get("requires", [])))
    out.append(sn_array("requires_any", p.get("requires_any", [])))
    out.append(sn_array("excludes", p.get("excludes", [])))
    if p.get("min_day", 1) != 1:
        out.append("min_day = %d\n" % p["min_day"])
    if p.get("debate_hours", 4.0) != 4.0:
        out.append("debate_hours = %s\n" % repr(float(p["debate_hours"])))
    for key in ("hope_on_sign", "discontent_on_sign", "hope_rate", "discontent_rate"):
        v = float(p.get(key, 0.0))
        if v != 0.0:
            out.append("%s = %s\n" % (key, repr(v)))
    out.append(f_dict("policy", p.get("policy", {})))
    out.append(sn_array("flags", p.get("flags", [])))
    out.append(f_dict("approval", p.get("approval", {})))
    out.append(sn_array("relieves", p.get("relieves", [])))
    out.append(sn_array("provokes", p.get("provokes", [])))
    out.append(sn_array("tags", p.get("tags", [])))
    return "".join(out)


def main():
    os.makedirs(OUT, exist_ok=True)
    ids = set()
    for p in L:
        if p["id"] in ids:
            print("DUPLICATE id %s" % p["id"], file=sys.stderr)
            return 1
        ids.add(p["id"])
    for p in L:
        for ref in list(p.get("requires", [])) + list(p.get("requires_any", [])) + list(p.get("excludes", [])):
            if ref not in ids:
                print("law %s references missing %s" % (p["id"], ref), file=sys.stderr)
                return 1
    # wipe stale files so a renamed law cannot linger in the registry
    for f in os.listdir(OUT):
        if f.endswith(".tres") and f[:-5] not in ids:
            os.remove(os.path.join(OUT, f))
    for p in L:
        with open(os.path.join(OUT, "%s.tres" % p["id"]), "w") as fh:
            fh.write(emit(p))
    print("wrote %d laws to %s" % (len(L), OUT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
