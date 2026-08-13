extends SceneTree
## AUTHORING TOOL for [P10]'s tech tree. Not a test — the gate ignores it,
## because a suite entry point is `test_*.gd`, `run_*.gd` or a `.tscn`.
##
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##       --script tests/research/author_research.gd
##
## It writes `game/content/research/*.tres`, one file per node, and those files
## are the shipped content. Edit a beat here, re-run, commit the .tres.
##
## THE RULE THIS FILE EXISTS TO ENFORCE: every node's `description` states the
## MOMENT IN THE CAMPAIGN it is meant to arrive at and the problem the player is
## feeling then, and `answers` names the signal ResearchPacing measures for that
## problem. A node that reads like a stat line is a failed node; the validator in
## ResearchNode rejects a description under 24 characters, and this file is where
## the rest of that discipline lives.

const OUT_DIR: String = "res://game/content/research"

var _written: int = 0
var _failed: int = 0
var _done: bool = false


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	_run()
	quit(1 if _failed > 0 else 0)
	return true


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	_heat()
	_metallurgy()
	_logistics()
	_defence()
	_survival()
	_desperate()
	print("authored %d research nodes into %s (%d failed)" % [_written, OUT_DIR, _failed])


# ==========================================================================
#  HEAT ENGINEERING
# ==========================================================================

func _heat() -> void:
	var n: ResearchNode = _node(&"draught_sealing", "Draught Sealing", &"heat", 1)
	n.prereqs = []
	n.cost = {&"timber": 30, &"scrap": 40}
	n.work = 140
	n.effects = {&"heat.demand_mult": -0.08}
	n.answers = &"frozen"
	n.answer_weight = 1.9
	n.also_answers = &"heat_deficit"
	n.urgency_line = "Every hut you own is bleeding heat into the dark, and the cheapest answer is rags, tar and boarded windows."
	n.description = "THE BEAT: the first dusk, and again the first morning something froze solid. One hearth, a handful of huts, and the heat number falling faster than the player can feed it. This is the first heat node the tree should offer, because eight percent off every consumer in the city is a bigger number than anything they can build on day one — and because a building that froze last night is the loudest possible argument for it."
	n.flavour = "Tar, rag and board. It is not engineering. It works."
	_save(n)

	n = _node(&"pipe_lagging", "Pipe Lagging", &"heat", 1)
	n.prereqs = [&"draught_sealing"]
	n.cost = {&"timber": 40, &"scrap": 60, &"iron_plate": 20}
	n.work = 220
	n.effects = {&"heat.loss_mult": -0.25}
	n.answers = &"heat_loss"
	n.answer_weight = 1.8
	n.urgency_line = "The far end of your first long run is coming up cold, and wrapping the mains is what stops it."
	n.description = "THE BEAT: the moment the player runs a pipe past about eight tiles and notices the radiator at the end never gets warm. The heat overlay is already telling them why — distance costs heat — and this is the answer that makes the reading actionable. It has to arrive on day one or two, while the base is still small enough that one insulated run visibly fixes a district."
	n.flavour = "Wool, then hide, then wool again. The pipe stops screaming."
	_save(n)

	n = _node(&"thermal_storage", "Thermal Storage", &"heat", 2)
	n.prereqs = [&"pipe_lagging"]
	n.cost = {&"iron_plate": 70, &"copper_coil": 30, &"stone": 80}
	n.work = 380
	n.effects = {&"heat.buffer_mult": 0.25}
	n.answers = &"heat_peak"
	n.answer_weight = 2.0
	n.also_answers = &"storm"
	n.urgency_line = "Your generators cover the day and lose the night; something has to hold the difference."
	n.description = "THE BEAT: the morning after the first night the city ran short. Production was never the problem — the AVERAGE was fine and the peak was not. The pacing engine remembers last night's worst deficit right across the following day, so this offer lands while the player still remembers watching the bar drain, not two days later when they have stopped caring."
	n.flavour = "A tank of hot brine and a great deal of insulation. It gives back what the day did not need."
	_save(n)

	n = _node(&"pressurised_mains", "Pressurised Mains", &"heat", 2)
	n.prereqs = [&"pipe_lagging"]
	n.cost = {&"iron_plate": 90, &"gear": 40, &"copper_coil": 20}
	n.work = 420
	n.effects = {&"heat.throughput_mult": 0.15}
	n.answers = &"heat_bottleneck"
	n.answer_weight = 2.2
	n.urgency_line = "One pipe tile is throttling everything behind it, and the overlay has already named it."
	n.description = "THE BEAT: the first time the heat overlay paints a single tile red and says it is choking eleven buildings. The simulation has computed per-consumer bottleneck attribution since minute one; this node is the reward for finally reading it. Trunk mains carry four times what a pipe does and booster pumps reset the distance loss, which turns 'my base is too far from the hearth' from a wall into a layout problem."
	n.flavour = "Wider bore, higher pressure, and a pump every twenty tiles to argue with the cold."
	_save(n)

	n = _node(&"combustion_tuning", "Combustion Tuning", &"heat", 2)
	n.prereqs = [&"draught_sealing"]
	n.cost = {&"iron_plate": 60, &"gear": 25, &"stone": 40}
	n.work = 340
	n.effects = {&"heat.output_mult": 0.12, &"heat.fuel_mult": -0.10}
	n.answers = &"fuel"
	n.answer_weight = 1.6
	n.also_answers = &"heat_deficit"
	n.urgency_line = "Your burners are eating coal faster than the collectors bring it in."
	n.description = "THE BEAT: day two or three, when the coal curve turns over. The player has enough generators; what they do not have is enough fuel to keep them lit. Twelve percent more heat for ten percent less coal is the difference between a supply line that works and one that needs doubling."
	n.flavour = "Preheat the air, close the damper, and stop throwing half the fire up the flue."
	_save(n)

	n = _node(&"radiant_focusing", "Radiant Focusing", &"heat", 2)
	n.prereqs = [&"draught_sealing"]
	n.cost = {&"copper_coil": 40, &"iron_plate": 50}
	n.work = 320
	n.effects = {&"heat.radius_mult": 0.3}
	n.answers = &"cold"
	n.answer_weight = 1.5
	n.also_answers = &"casualties"
	n.urgency_line = "People are freezing in the streets between buildings you have already heated."
	n.description = "THE BEAT: when the city stops being one block and becomes districts with gaps. Warmth radiates from a radiator in a circle, and the gaps between those circles are where citizens die walking to work. Thirty percent more radius is a quarter of the map warmed without a single new generator."
	n.flavour = "Polished plate behind the coils. The heat stops going where nobody is standing."
	_save(n)

	n = _node(&"heat_recovery", "Heat Recovery", &"heat", 3)
	n.prereqs = [&"thermal_storage", &"combustion_tuning"]
	n.cost = {&"steel_plate": 60, &"copper_coil": 50, &"pipe_segment": 20}
	n.work = 700
	n.effects = {&"heat.loss_mult": -0.20, &"heat.output_mult": 0.08}
	n.answers = &"heat_loss"
	n.answer_weight = 1.4
	n.urgency_line = "A fifth of everything you make is dying between the generator and the house."
	n.description = "THE BEAT: mid campaign, once the base is wide enough that transmission loss is a line item rather than a rounding error. This is the node that rewards a player who has actually read the flow overlay, and it stacks with lagging instead of replacing it — the two together take a thirty-five percent loss down to something survivable."
	n.flavour = "The exhaust goes back into the intake. The stack stops steaming."
	_save(n)

	n = _node(&"geothermal_tapping", "Geothermal Tapping", &"heat", 3)
	n.prereqs = [&"pressurised_mains", &"combustion_tuning"]
	n.cost = {&"steel_plate": 80, &"pipe_segment": 30, &"stone": 120}
	n.work = 820
	n.answers = &"fuel"
	n.answer_weight = 2.4
	n.urgency_line = "The coal is running out and the vents have been steaming since the day you landed."
	n.description = "THE BEAT: the day the coal near the city is visibly thin and the player is deciding whether to push a supply line out into the dark. The vents were on the map from the first minute; this node is the payoff for having noticed them, and it is the first heat source that costs no fuel at all. It should arrive around day four, when fuel logistics has stopped being fun."
	n.flavour = "Drive a column into the vent and take the heat straight out of the ground. No smoke. No hauling."
	_save(n)

	n = _node(&"superheated_mains", "Superheated Mains", &"heat", 4)
	n.prereqs = [&"geothermal_tapping", &"pressurised_mains"]
	n.cost = {&"steel_plate": 140, &"copper_coil": 80, &"pipe_segment": 60}
	n.work = 1250
	n.effects = {&"heat.throughput_mult": 0.45, &"heat.loss_mult": -0.10}
	n.answers = &"heat_bottleneck"
	n.answer_weight = 1.6
	n.urgency_line = "The trunk main you were so proud of is now the tile everything else is waiting behind."
	n.description = "THE BEAT: late campaign, when the city has outgrown its own spine. The player solved this once already with trunk mains; this is the same problem returning at a scale where the answer has to be metallurgical rather than architectural. It also gates the heat lance, so the defence branch ends up caring about pipe pressure."
	n.flavour = "Steam at a pressure the old pipes would have opened like a tin. The new ones do not."
	_save(n)


# ==========================================================================
#  METALLURGY
# ==========================================================================

func _metallurgy() -> void:
	var n: ResearchNode = _node(&"scrap_sorting", "Scrap Sorting", &"metallurgy", 1)
	n.cost = {&"timber": 30, &"stone": 30}
	n.work = 130
	n.effects = {&"mining.scrap_mult": 0.30}
	n.answers = &"materials"
	n.answer_weight = 1.6
	n.urgency_line = "The ruins are the only mine you have and you are working them like a rubbish heap."
	n.description = "THE BEAT: the first time the yard runs dry mid-build, usually inside the first ten minutes. It is the cheapest node in the tree and it pays back within the hour. It exists so that a player who is losing always has something to do that is not waiting."
	n.flavour = "Sort before you smelt. Half of what you were burning was already iron."
	_save(n)

	n = _node(&"bloomery_smelting", "Bloomery Smelting", &"metallurgy", 1)
	n.prereqs = [&"scrap_sorting"]
	n.cost = {&"stone": 70, &"scrap": 60}
	n.work = 200
	n.grants = [&"recipe_iron_plate"]
	n.effects = {&"craft.speed_mult": 0.10}
	n.answers = &"materials"
	n.answer_weight = 1.3
	n.urgency_line = "Scrap runs out. Ore does not, and you cannot use ore."
	n.description = "THE BEAT: the point where salvage stops scaling. Every player hits it, because the ruins are finite and the ore field is not. This is the node that turns the map's deposits from scenery into an economy, and the whole metallurgy branch hangs off it."
	n.flavour = "A clay stack, a bellows, and a boy to work it. Iron comes out the bottom."
	_save(n)

	n = _node(&"alloy_steel", "Alloy Steel", &"metallurgy", 2)
	n.prereqs = [&"bloomery_smelting"]
	n.cost = {&"iron_plate": 90, &"coal": 80}
	n.work = 420
	n.grants = [&"recipe_steel_plate"]
	n.answers = &"structure_loss"
	n.answer_weight = 1.5
	n.urgency_line = "Iron came apart on you, and iron is what the whole city is made of."
	n.description = "THE BEAT: after the first night something got through. Steel gates half the mid tree — armour-piercing rounds, cold-rolled plate, precision machining — so the beat here is the night that taught the player iron is not enough, and the branch opens outward from exactly that."
	n.flavour = "Carbon, time, and a furnace that does not cool down between heats."
	_save(n)

	n = _node(&"coke_ovens", "Coke Ovens", &"metallurgy", 2)
	n.prereqs = [&"bloomery_smelting"]
	n.cost = {&"stone": 110, &"iron_plate": 50}
	n.work = 400
	n.effects = {&"production.fuel_value_mult": 0.25}
	n.answers = &"fuel"
	n.answer_weight = 1.7
	n.urgency_line = "Raw coal burns fast, dirty and cold, and you are hauling more of it than anything else."
	n.description = "THE BEAT: when coal is the largest single flow on the map. A quarter more heat per lump is a quarter fewer belts, and that is felt the same hour on a base that has started to look like a coal railway."
	n.flavour = "Bake the coal without air. What is left burns twice as hot and half as fast."
	_save(n)

	n = _node(&"deep_drilling", "Deep Drilling", &"metallurgy", 2)
	n.prereqs = [&"bloomery_smelting"]
	n.cost = {&"iron_plate": 80, &"gear": 40}
	n.work = 440
	n.effects = {&"mining.yield_mult": 0.30}
	n.answers = &"materials"
	n.answer_weight = 1.4
	n.also_answers = &"sprawl"
	n.urgency_line = "The near seam is thinning and the next one is a long way out into the dark."
	n.description = "THE BEAT: the moment before the player pushes extractors past the wall. Thirty percent more from a seam they already defend is the alternative to a mining outpost they cannot protect, and offering it here turns an overextension into a real choice."
	n.flavour = "Longer bit, heavier column, and a drill head that survives the frost line."
	_save(n)

	n = _node(&"precision_machining", "Precision Machining", &"metallurgy", 3)
	n.prereqs = [&"alloy_steel"]
	n.cost = {&"steel_plate": 70, &"gear": 60, &"copper_coil": 40}
	n.work = 720
	n.grants = [&"recipe_precision_gear"]
	n.effects = {&"craft.speed_mult": 0.20}
	n.answers = &"sprawl"
	n.answer_weight = 1.2
	n.urgency_line = "Everything downstream of the workshop is waiting on parts you make one at a time."
	n.description = "THE BEAT: mid campaign, when the workshop is the bottleneck rather than the mine. It is also the prerequisite for prosthetics, which is deliberate — the same lathe that makes a gear makes a hand."
	n.flavour = "Tolerances a tenth of what the old jigs held. Things fit the first time."
	_save(n)

	n = _node(&"cold_rolled_plate", "Cold-Rolled Plate", &"metallurgy", 3)
	n.prereqs = [&"alloy_steel", &"coke_ovens"]
	n.cost = {&"steel_plate": 110, &"coal": 100}
	n.work = 760
	n.effects = {&"combat.structure_hp_mult": 0.25, &"combat.structure_armor_add": 1.5}
	n.answers = &"structure_loss"
	n.answer_weight = 2.0
	n.urgency_line = "The breakers are chewing through your wall faster than the crews can patch it."
	n.description = "THE BEAT: the first night the wall does not hold. Every structure in the city gets tougher, which is why it sits in metallurgy rather than defence: a player who invested in furnaces gets a defensive payoff without ever having built a turret."
	n.flavour = "Rolled cold, so the grain runs the length of the plate. It dents instead of splitting."
	_save(n)


# ==========================================================================
#  LOGISTICS
# ==========================================================================

func _logistics() -> void:
	var n: ResearchNode = _node(&"hand_carts", "Hand Carts", &"logistics", 1)
	n.cost = {&"timber": 50, &"scrap": 30}
	n.work = 150
	n.effects = {&"build.speed_mult": 0.15, &"logistics.throughput_mult": 0.10}
	n.answers = &"labour"
	n.answer_weight = 1.5
	n.urgency_line = "Half your workforce is walking somewhere, carrying something, and walking back."
	n.description = "THE BEAT: the first construction queue longer than the day. Nothing about this is exciting and that is the point — it is the node a player takes when they work out the bottleneck is not materials but hands, and it makes every build after it faster."
	n.flavour = "Two wheels and a plank. The oldest technology in the city and still the best return."
	_save(n)

	n = _node(&"belt_drives", "Belt Drives", &"logistics", 1)
	n.prereqs = [&"hand_carts"]
	n.cost = {&"timber": 60, &"iron_plate": 40, &"gear": 20}
	n.work = 260
	n.grants = [&"belt", &"recipe_belt"]
	n.answers = &"sprawl"
	n.answer_weight = 1.8
	n.urgency_line = "You are walking ore across your own base, and the base is only getting wider."
	n.description = "THE BEAT: the moment the player builds a second extractor and realises the distance between it and the smelter is now their whole game. This is the automation genre's front door and it must open on day one or two — a Factorio player who cannot lay a belt in the first hour has been told the wrong thing about what this game is."
	n.flavour = "A loop of hide over wooden rollers, turned by the same shaft that turns everything else."
	_save(n)

	n = _node(&"inserter_arms", "Inserter Arms", &"logistics", 2)
	n.prereqs = [&"belt_drives"]
	n.cost = {&"iron_plate": 70, &"gear": 50, &"copper_coil": 25}
	n.work = 380
	n.grants = [&"inserter", &"recipe_inserter"]
	n.answers = &"labour"
	n.answer_weight = 1.6
	n.urgency_line = "The belt runs right past the smelter and a person still has to lift each plate off it."
	n.description = "THE BEAT: immediately after the first belt, when the player discovers that a belt ending at a machine does nothing on its own. This is the second half of one idea and it must never be more than one node away from the first, or the belt reads as broken rather than incomplete."
	n.flavour = "A counterweighted arm on a cam. It does one thing forever and never asks for heat."
	_save(n)

	n = _node(&"underground_belts", "Underground Belts", &"logistics", 2)
	n.prereqs = [&"belt_drives"]
	n.cost = {&"iron_plate": 90, &"stone": 80, &"gear": 30}
	n.work = 420
	n.grants = [&"belt_underground", &"recipe_belt_underground"]
	n.answers = &"tangle"
	n.answer_weight = 2.3
	n.urgency_line = "A belt has to cross a pipe and one of them has to lose."
	n.description = "THE BEAT: the first time the base tangles. The pacing engine measures this directly — conduit tiles per machine — so the offer arrives on the exact day the player's careful grid stops working: not before, when it would be an abstraction, and not after, when they have already torn it up. This is the clearest node in the tree for what the whole design is trying to do."
	n.flavour = "Down, under, and up again. The pipe never knows it was crossed."
	_save(n)

	n = _node(&"splitters_and_balancers", "Splitters & Balancers", &"logistics", 2)
	n.prereqs = [&"underground_belts"]
	n.cost = {&"iron_plate": 80, &"gear": 60, &"copper_coil": 30}
	n.work = 460
	n.grants = [&"splitter", &"recipe_splitter"]
	n.answers = &"tangle"
	n.answer_weight = 1.5
	n.also_answers = &"sprawl"
	n.urgency_line = "One furnace is backed up and the one beside it has been idle since dawn."
	n.description = "THE BEAT: when the player has two machines eating from one line and finds out the first one takes everything. It is the node that turns a belt from a pipe into a network, and it is where a logistics player starts building things they are proud of."
	n.flavour = "Two lanes in, two lanes out, and an argument settled by a lever."
	_save(n)

	n = _node(&"bulk_storage", "Bulk Storage", &"logistics", 2)
	n.prereqs = [&"hand_carts"]
	n.cost = {&"timber": 90, &"stone": 100, &"iron_plate": 40}
	n.work = 400
	n.grants = [&"storage_yard_large"]
	n.effects = {&"logistics.storage_mult": 0.50}
	n.answers = &"materials"
	n.answer_weight = 1.3
	n.urgency_line = "You are producing more than you can keep and the overflow is sitting in the snow."
	n.description = "THE BEAT: the first surplus. A player who has solved production and not storage watches a smelter stall with a full output buffer, which reads as a bug until they understand it. Half again the capacity buys the room to keep building instead of babysitting."
	n.flavour = "Roofed bays, raised floors, and a tally board at the gate."
	_save(n)

	n = _node(&"logistic_scheduling", "Logistic Scheduling", &"logistics", 3)
	n.prereqs = [&"splitters_and_balancers", &"inserter_arms"]
	n.cost = {&"steel_plate": 60, &"copper_coil": 70, &"gear": 80}
	n.work = 780
	n.grants = [&"recipe_logistic_chest"]
	n.effects = {&"logistics.throughput_mult": 0.25, &"build.speed_mult": 0.10}
	n.answers = &"sprawl"
	n.answer_weight = 1.5
	n.urgency_line = "Your base has more lines running through it than you can hold in your head."
	n.description = "THE BEAT: late-mid campaign, when the player stops laying belts by hand and starts thinking in flows. This is where logistics graduates from moving items to declaring intent, and it is the last node before the branch's payoff becomes purely a matter of scale."
	n.flavour = "Requests on one side, offers on the other, and a clerk who never sleeps."
	_save(n)


# ==========================================================================
#  DEFENCE
# ==========================================================================

func _defence() -> void:
	var n: ResearchNode = _node(&"palisade_engineering", "Palisade Engineering", &"defence", 1)
	n.cost = {&"timber": 70, &"stone": 60}
	n.work = 160
	n.grants = [&"wall_reinforced"]
	n.effects = {&"combat.structure_hp_mult": 0.15}
	n.answers = &"wave"
	n.answer_weight = 1.4
	n.urgency_line = "The thing you are calling a wall is a suggestion."
	n.description = "THE BEAT: the afternoon of day one, when the player looks at the dark treeline and at their fence in the same glance. It is cheap, it is fast, and it is the first node in the game that says out loud that something is coming."
	n.flavour = "Sharpened stakes, a rubble core and a firing step. It will not stop everything."
	_save(n)

	n = _node(&"ballistics", "Ballistics", &"defence", 1)
	n.cost = {&"iron_plate": 40, &"timber": 30}
	n.work = 180
	n.effects = {&"combat.turret_damage_mult": 0.18}
	n.answers = &"wave"
	n.answer_weight = 1.6
	n.urgency_line = "Your turret fires, and the thing it hit keeps walking."
	n.description = "THE BEAT: the first night the player watches a turret connect and nothing happens. Raw damage is the least interesting answer in the branch and the correct first one, because at this point the player does not yet know what kind of enemy they are failing against."
	n.flavour = "Heavier shot, tighter bore, and a powder charge somebody finally measured."
	_save(n)

	n = _node(&"watchfires", "Watchfires", &"defence", 1)
	n.prereqs = [&"palisade_engineering"]
	n.cost = {&"timber": 60, &"coal": 50, &"scrap": 40}
	n.work = 220
	n.effects = {&"combat.vision_mult": 0.30, &"combat.turret_accuracy_mult": 0.10}
	n.answers = &"blind"
	n.answer_weight = 1.8
	n.urgency_line = "You cannot see what is killing you until it is already inside the wall."
	n.description = "THE BEAT: the first deep night, or the first blizzard, when visibility collapses and the player realises their turrets are shooting at noises. It ties defence to the climate system directly — in a whiteout this node is worth more than damage is."
	n.flavour = "Pitch, bone and fat burning in an iron basket. Crude, and you can see the plain."
	_save(n)

	n = _node(&"rapid_cycling", "Rapid Cycling", &"defence", 2)
	n.prereqs = [&"ballistics"]
	n.cost = {&"iron_plate": 80, &"gear": 60, &"copper_coil": 30}
	n.work = 420
	n.effects = {&"combat.turret_rate_mult": 0.25, &"heat.demand_mult": 0.05}
	n.answers = &"swarm"
	n.answer_weight = 2.0
	n.urgency_line = "They arrive in a mass and your turret fires once."
	n.description = "THE BEAT: the night the wave stops being a line and becomes a crowd. Note the cost: faster cycling draws more heat, so this node makes the defence grid a heavier customer of the heat grid. That coupling is the entire game in one node."
	n.flavour = "A second feed pawl and a return spring that does not care how cold it is."
	_save(n)

	n = _node(&"armour_piercing", "Armour-Piercing Rounds", &"defence", 2)
	n.prereqs = [&"ballistics", &"alloy_steel"]
	n.cost = {&"steel_plate": 70, &"copper_coil": 40}
	n.work = 480
	n.effects = {&"combat.turret_pierce_add": 4.0, &"combat.turret_damage_mult": 0.05}
	n.answers = &"armoured"
	n.answer_weight = 2.6
	n.urgency_line = "Something came out of the dark with a plate on its front and your rounds bounced off it."
	n.description = "THE BEAT: the night the armoured breaker first appears. This node exists for exactly one moment in the campaign and the pacing engine watches for it — the share of what is coming that is armoured. It requires alloy steel on purpose: the answer to a defence problem lives in the metallurgy branch, so a player who ignored the furnaces is one night behind on the night it matters."
	n.flavour = "A hardened penetrator in a soft jacket. The jacket peels; the core keeps going."
	_save(n)

	n = _node(&"targeting_lattice", "Targeting Lattice", &"defence", 3)
	n.prereqs = [&"rapid_cycling", &"watchfires"]
	n.cost = {&"steel_plate": 60, &"copper_coil": 90, &"gear": 50}
	n.work = 740
	n.effects = {&"combat.turret_accuracy_mult": 0.35, &"combat.turret_range_mult": 0.10}
	n.answers = &"blind"
	n.answer_weight = 2.0
	n.urgency_line = "In a whiteout your turrets are firing at where something used to be."
	n.description = "THE BEAT: the first Great Frost the player fights through rather than hides from. The climate system already tells combat that a blizzard costs accuracy; this is the answer, and its arrival should track the storm calendar rather than a tier number."
	n.flavour = "Ranging wires, a shared clock, and turrets that agree on where the target is."
	_save(n)

	n = _node(&"incendiary_rounds", "Incendiary Rounds", &"defence", 3)
	n.prereqs = [&"rapid_cycling", &"coke_ovens"]
	n.cost = {&"steel_plate": 60, &"coal": 120, &"copper_coil": 40}
	n.work = 700
	n.grants = [&"flame_turret"]
	n.effects = {&"combat.turret_damage_mult": 0.10}
	n.answers = &"swarm"
	n.answer_weight = 2.2
	n.urgency_line = "Killing them one at a time stopped working three nights ago."
	n.description = "THE BEAT: when single-target damage is arithmetically hopeless and the player needs area denial. It hangs off coke ovens rather than off ballistics, because what makes fire work here is fuel chemistry — another deliberate cross-branch dependency."
	n.flavour = "Coke dust and pitch in a thin shell. It does not need to hit hard, only to land."
	_save(n)

	n = _node(&"heat_lance", "Heat Lance", &"defence", 4)
	n.prereqs = [&"armour_piercing", &"superheated_mains"]
	n.cost = {&"steel_plate": 160, &"copper_coil": 110, &"pipe_segment": 70}
	n.work = 1350
	n.grants = [&"heat_lance_turret"]
	n.effects = {&"combat.turret_pierce_add": 6.0}
	n.answers = &"armoured"
	n.answer_weight = 2.0
	n.urgency_line = "Something is walking through your wall as though it were not there."
	n.description = "THE BEAT: the late-campaign monster. The lance burns the city's own heat as ammunition, at a rate that browns out whatever shares its network, so fielding it is a decision about the grid rather than about the wall. It is the point where the three genres finally collapse into one object."
	n.flavour = "A lance of superheated gas at four thousand degrees. It does not pierce armour. It removes it."
	_save(n)


# ==========================================================================
#  SURVIVAL & MEDICINE
# ==========================================================================

func _survival() -> void:
	var n: ResearchNode = _node(&"insulated_clothing", "Insulated Clothing", &"survival", 1)
	n.cost = {&"timber": 40, &"scrap": 50}
	n.work = 170
	n.effects = {&"citizens.exposure_resist": 0.25}
	n.answers = &"cold"
	n.answer_weight = 1.7
	n.also_answers = &"casualties"
	n.urgency_line = "People are freezing on the walk between the house and the job."
	n.description = "THE BEAT: the first citizen death, which in this game is always the cold and almost never the enemy. It is the node that teaches a new player that the temperature on the HUD is a body count, and it is cheap enough to take the same minute they learn it."
	n.flavour = "Layered hide, hood and mitten. Nothing clever. Fewer names on the board."
	_save(n)

	n = _node(&"field_medicine", "Field Medicine", &"survival", 1)
	n.cost = {&"timber": 40, &"scrap": 30, &"stone": 20}
	n.work = 180
	n.grants = [&"medical_post"]
	n.effects = {&"citizens.heal_mult": 0.40}
	n.answers = &"casualties"
	n.answer_weight = 1.6
	n.urgency_line = "The first cough went through a whole hut in one night."
	n.description = "THE BEAT: the first sickness, usually day two. Without it an injured citizen is a dead one, and the player only finds that out by losing somebody. It sits at the very front of the branch so that lesson is survivable."
	n.flavour = "Boiled cloth, splints, and somebody who has read the book twice."
	_save(n)

	n = _node(&"soup_kitchens", "Soup Kitchens", &"survival", 1)
	n.prereqs = [&"insulated_clothing"]
	n.cost = {&"stone": 60, &"iron_plate": 30, &"timber": 40}
	n.work = 240
	n.grants = [&"recipe_hot_ration"]
	n.effects = {&"citizens.food_mult": 0.25, &"society.hope_mult": 0.05}
	n.answers = &"hunger"
	n.answer_weight = 1.7
	n.urgency_line = "Cold rations keep a person alive and do not keep them working."
	n.description = "THE BEAT: the end of the first week, when food stops being a number that only falls slowly and starts deciding how much work gets done. A hot meal is worth more than its calories in this climate, which is why this node touches hope as well as food."
	n.flavour = "One pot, one fire, one queue. The queue is where the city talks to itself."
	_save(n)

	n = _node(&"infirmary", "Infirmary", &"survival", 2)
	n.prereqs = [&"field_medicine"]
	n.cost = {&"iron_plate": 70, &"timber": 80, &"stone": 60}
	n.work = 420
	n.grants = [&"infirmary_building"]
	n.effects = {&"citizens.heal_mult": 0.40, &"society.discontent_mult": -0.05}
	n.answers = &"casualties"
	n.answer_weight = 1.8
	n.urgency_line = "Your medical post is treating people in the corridor."
	n.description = "THE BEAT: after the first bad night — a wave that got through, or a Great Frost that did. The player has a pile of injured and a post built for three. This is the node that turns a disaster into a recovery instead of into a spiral."
	n.flavour = "Beds, heat, and a door that closes. Most of medicine is those three things."
	_save(n)

	n = _node(&"night_shift_rotation", "Night Shift Rotation", &"survival", 2)
	n.prereqs = [&"soup_kitchens"]
	n.cost = {&"timber": 70, &"coal": 60, &"iron_plate": 40}
	n.work = 400
	n.effects = {&"citizens.night_work_mult": 0.35}
	n.answers = &"labour"
	n.answer_weight = 1.9
	n.urgency_line = "Half of your day is dark and nothing gets built in it."
	n.description = "THE BEAT: around day three, when the player first tries to finish a wall before dusk and cannot. It is the honest version of the desperate branch's answer to the same problem: you can pay for the hours with organisation now, or pay for them with people later."
	n.flavour = "Two shifts, staggered, and the second one fed first. Nobody likes it. Everybody sleeps."
	_save(n)

	n = _node(&"prosthetics", "Prosthetics", &"survival", 3)
	n.prereqs = [&"infirmary", &"precision_machining"]
	n.cost = {&"steel_plate": 60, &"gear": 70, &"copper_coil": 40}
	n.work = 760
	n.effects = {&"citizens.workforce_mult": 0.12, &"society.hope_mult": 0.08}
	n.answers = &"labour"
	n.answer_weight = 1.5
	n.also_answers = &"casualties"
	n.urgency_line = "You have a ward full of people who want to work and cannot hold a tool."
	n.description = "THE BEAT: late-mid, once the campaign has actually cost the player limbs. This node gives back a workforce they already lost, which lands very differently from one that hands them a new one — and it needs the lathe from metallurgy, because the tolerance that makes a gear makes a hand."
	n.flavour = "Ash, leather and a machined joint. A man walks out of the ward and back onto the line."
	_save(n)

	n = _node(&"assembly_hall", "Assembly Hall", &"survival", 3)
	n.prereqs = [&"night_shift_rotation", &"insulated_clothing"]
	n.cost = {&"timber": 120, &"stone": 110, &"iron_plate": 60}
	n.work = 720
	n.grants = [&"assembly_hall_building", &"law_public_assembly"]
	n.effects = {&"society.hope_mult": 0.20, &"society.discontent_mult": -0.15}
	n.answers = &"discontent"
	n.answer_weight = 2.0
	n.urgency_line = "The crowd at the hearth has stopped asking politely."
	n.description = "THE BEAT: the first time discontent outruns hope, which is usually straight after a law the city did not like. This is the survival branch's answer to the desperate branch and the two are meant to be read against each other: a hall where people can shout at you, or martial law so that they cannot."
	n.flavour = "A roof, a stove, and room for two hundred. They will use it to complain. That is the point."
	_save(n)


# ==========================================================================
#  DESPERATE MEASURES
# ==========================================================================

func _desperate() -> void:
	var n: ResearchNode = _node(&"emergency_shift", "Emergency Shift", &"desperate", 1)
	n.prereqs = [&"insulated_clothing"]
	n.cost = {&"coal": 60, &"timber": 40}
	n.work = 260
	n.grants = [&"law_extended_shift"]
	n.effects = {&"citizens.night_work_mult": 0.20, &"society.discontent_mult": 0.10}
	n.answers = &"labour"
	n.answer_weight = 1.8
	n.urgency_line = "You are three hours short and the storm is four hours out."
	n.description = "THE BEAT: the first Great Frost warning, when the player counts the work left against the clock and comes up short. This is the door into the dark branch and it is deliberately the reasonable one — an extra shift is not a crime. Everything below it is easier to sign because this one was signed first."
	n.flavour = "Fourteen hours. Signed at dusk, felt at dawn."
	_save(n)

	n = _node(&"sawdust_rations", "Sawdust Rations", &"desperate", 2)
	n.prereqs = [&"emergency_shift", &"soup_kitchens"]
	n.cost = {&"timber": 80, &"scrap": 50}
	n.work = 380
	n.grants = [&"law_sawdust_rations"]
	n.effects = {&"citizens.food_mult": 0.45, &"society.hope_mult": -0.12}
	n.answers = &"hunger"
	n.answer_weight = 2.2
	n.urgency_line = "The granary will not reach the thaw and you both know it."
	n.description = "THE BEAT: the food crisis of the middle campaign. It works — nearly half again the rations — and every single person can taste what is in it. The tree offers this exactly when the arithmetic of starvation has become unavoidable, because that is the only time a player takes it."
	n.flavour = "Sawdust, bark meal, and enough salt to hide it. It fills. It does not feed."
	_save(n)

	n = _node(&"child_apprenticeships", "Child Apprenticeships", &"desperate", 2)
	n.prereqs = [&"emergency_shift"]
	n.cost = {&"timber": 60, &"iron_plate": 40}
	n.work = 400
	n.grants = [&"law_child_labour"]
	n.effects = {&"citizens.workforce_mult": 0.18, &"society.hope_mult": -0.18}
	n.answers = &"labour"
	n.answer_weight = 1.9
	n.urgency_line = "There are two hundred pairs of hands in this city that you have decided are not hands."
	n.description = "THE BEAT: the second labour crisis, after the honest answers have all been spent. It should arrive as arithmetic and not as temptation — at the exact moment the player has run out of adults and has not run out of work."
	n.flavour = "They are quick, they are small, and they fit in the crawlways. That is the argument."
	_save(n)

	n = _node(&"bleed_the_grid", "Bleed the Grid", &"desperate", 3)
	n.prereqs = [&"thermal_storage", &"emergency_shift"]
	n.cost = {&"iron_plate": 80, &"copper_coil": 50, &"gear": 40}
	n.work = 640
	n.grants = [&"law_district_shutdown"]
	n.effects = {&"heat.buffer_mult": 0.15}
	n.answers = &"heat_deficit"
	n.answer_weight = 2.3
	n.urgency_line = "You can hold four districts through the night, and you have five."
	n.description = "THE BEAT: the night the grid cannot cover the city and somebody has to go cold. The heat solver already sheds load by priority tier; this law lets the player choose that tier by district and take a whole quarter offline deliberately. It is the difference between a brownout that happened to them and a sacrifice they made."
	n.flavour = "Close the valve at the district head. Whatever is behind it is dark by morning."
	_save(n)

	n = _node(&"martial_law", "Martial Law", &"desperate", 3)
	n.prereqs = [&"child_apprenticeships"]
	n.cost = {&"iron_plate": 90, &"steel_plate": 40}
	n.work = 620
	n.grants = [&"law_martial_law", &"guard_post"]
	n.effects = {&"society.discontent_mult": -0.35, &"society.hope_mult": -0.15}
	n.answers = &"discontent"
	n.answer_weight = 2.4
	n.urgency_line = "The crowd at the hearth is not asking any more."
	n.description = "THE BEAT: after the laws above have been signed and the city has noticed. It suppresses discontent rather than answering it, which is precisely the trap: it buys nights, and the bill compounds. The tree places it opposite the assembly hall so the player has to decide which kind of city they are running."
	n.flavour = "Guard posts, a curfew, and the word 'order' used a great deal."
	_save(n)

	n = _node(&"corpse_furnaces", "Corpse Furnaces", &"desperate", 3)
	n.prereqs = [&"sawdust_rations", &"combustion_tuning"]
	n.cost = {&"steel_plate": 70, &"stone": 90}
	n.work = 700
	n.grants = [&"law_corpse_furnaces"]
	n.effects = {&"production.fuel_value_mult": 0.20, &"society.hope_mult": -0.25}
	n.answers = &"fuel"
	n.answer_weight = 2.0
	n.priority_bias = -0.6
	n.urgency_line = "The dead are stacked at the gate because the ground is too hard to dig."
	n.description = "THE BEAT: the darkest arithmetic in the game, and it is only reachable by a player who has already been hungry and already been short of fuel. It arrives with the bodies. The pacing engine carries a negative bias on it, so an honest fuel answer is always offered first when one exists — the city has to run out of those before it runs out of scruples."
	n.flavour = "They are already cold. The furnace does not know the difference."
	_save(n)

	n = _node(&"the_last_furnace", "The Last Furnace", &"desperate", 4)
	n.prereqs = [&"corpse_furnaces", &"martial_law", &"superheated_mains"]
	n.cost = {&"steel_plate": 200, &"copper_coil": 120, &"pipe_segment": 80}
	n.work = 1500
	n.grants = [&"law_the_last_furnace"]
	n.effects = {&"heat.output_mult": 0.45, &"society.hope_mult": -0.30, &"society.discontent_mult": 0.20}
	n.answers = &"heat_deficit"
	n.answer_weight = 2.0
	n.priority_bias = -0.8
	n.urgency_line = "There is one more furnace and it runs on the city."
	n.description = "THE BEAT: the end of the dark branch, reachable only by a player who took every step of it. Everything that is not the hearth becomes fuel: outbuildings, stores, whole districts. It ends the campaign one way or the other, and it exists so that 'we survived' is not automatically the same sentence as 'we were right'."
	n.flavour = "The hearth burns hotter than it ever has. There is nothing left around it to warm."
	_save(n)


# ==========================================================================
#  PLUMBING
# ==========================================================================

func _node(id: StringName, title: String, branch: StringName, tier: int) -> ResearchNode:
	var n := ResearchNode.new()
	n.id = id
	n.title = title
	n.branch = branch
	n.tier = tier
	n.resource_name = title
	# Written into the .tres rather than inferred at runtime, so the rule is
	# visible in the content: a law is signed by the player or not at all.
	n.player_decision = ResearchDefs.CONSENT_BRANCHES.has(branch)
	return n


func _save(n: ResearchNode) -> void:
	var issues: PackedStringArray = n.validate()
	if issues.size() > 0:
		printerr("INVALID '%s': %s" % [String(n.id), ", ".join(issues)])
		_failed += 1
		return
	var path: String = "%s/%s.tres" % [OUT_DIR, String(n.id)]
	var err: int = ResourceSaver.save(n, path)
	if err != OK:
		printerr("failed to save %s (error %d)" % [path, err])
		_failed += 1
		return
	_written += 1
