class_name ResearchDefs
extends RefCounted
## [P10] Shared vocabulary for the tech tree: branches, node states, the effect
## key namespace and the pacing signal names.
##
## Everything here is a NAME OTHER PARTS COMPILE AGAINST. Adding a key is safe;
## renaming one is not. Nothing in this file holds state.

const TAG: String = "research"

# ==========================================================================
#  BRANCHES — the six lanes of the tree, in draw order
# ==========================================================================

const BRANCH_HEAT: StringName = &"heat"
const BRANCH_LOGISTICS: StringName = &"logistics"
const BRANCH_METALLURGY: StringName = &"metallurgy"
const BRANCH_DEFENCE: StringName = &"defence"
const BRANCH_SURVIVAL: StringName = &"survival"
const BRANCH_DESPERATE: StringName = &"desperate"

## Draw order, top lane first. [P18] renders the tree as horizontal bands in
## exactly this order, so a branch never jumps around between builds.
const BRANCH_ORDER: Array[StringName] = [
	BRANCH_HEAT, BRANCH_METALLURGY, BRANCH_LOGISTICS,
	BRANCH_DEFENCE, BRANCH_SURVIVAL, BRANCH_DESPERATE,
]

const BRANCH_TITLES: Dictionary = {
	BRANCH_HEAT: "Heat Engineering",
	BRANCH_METALLURGY: "Metallurgy",
	BRANCH_LOGISTICS: "Logistics",
	BRANCH_DEFENCE: "Defence",
	BRANCH_SURVIVAL: "Survival & Medicine",
	BRANCH_DESPERATE: "Desperate Measures",
}

const BRANCH_SUMMARIES: Dictionary = {
	BRANCH_HEAT: "Keep the heat you make, and move it further than it wants to go.",
	BRANCH_METALLURGY: "Turn ruins into plate, and plate into everything else.",
	BRANCH_LOGISTICS: "Stop carrying things. Start routing them.",
	BRANCH_DEFENCE: "Whatever comes out of the dark, meet it further from the hearth.",
	BRANCH_SURVIVAL: "The city is people. People break in ways steel does not.",
	BRANCH_DESPERATE: "Every one of these works. Every one of them costs you something you cannot buy back.",
}

## Lane accent, for the tree view. Cold blues warm toward the dark branch's red.
const BRANCH_COLORS: Dictionary = {
	BRANCH_HEAT: Color(0.98, 0.66, 0.32),
	BRANCH_METALLURGY: Color(0.74, 0.76, 0.82),
	BRANCH_LOGISTICS: Color(0.46, 0.74, 0.86),
	BRANCH_DEFENCE: Color(0.86, 0.42, 0.38),
	BRANCH_SURVIVAL: Color(0.56, 0.82, 0.60),
	BRANCH_DESPERATE: Color(0.62, 0.26, 0.34),
}


static func branch_title(branch: StringName) -> String:
	return String(BRANCH_TITLES.get(branch, String(branch).capitalize()))


static func branch_index(branch: StringName) -> int:
	var i: int = BRANCH_ORDER.find(branch)
	return i if i >= 0 else BRANCH_ORDER.size()


static func is_branch(branch: StringName) -> bool:
	return BRANCH_ORDER.has(branch)


# ==========================================================================
#  NODE STATE — what the tree view paints
# ==========================================================================

enum State {
	LOCKED,     ## a prerequisite is still missing
	AVAILABLE,  ## every prerequisite is done; the player may start it
	QUEUED,     ## in the queue, not at the head
	ACTIVE,     ## being worked on right now
	PARKED,     ## started, then set aside — progress and materials are kept
	DONE,       ## researched
}

const STATE_NAMES: Array[String] = ["locked", "available", "queued", "active", "parked", "done"]


static func state_name(s: int) -> String:
	return STATE_NAMES[clampi(s, 0, STATE_NAMES.size() - 1)]


# ==========================================================================
#  EFFECT KEYS — the numeric contract with the rest of the simulation
# ==========================================================================
##
## Two shapes, distinguished by suffix, and the suffix IS the contract:
##
##   *_mult   an additive delta around zero. Ask for it with multiplier(key),
##            which returns 1.0 + the sum. Two +0.2 nodes give 1.4, not 1.44 —
##            additive stacking keeps a tech tree from going exponential.
##   *_add    a plain sum in the unit of the thing. Ask with modifier(key).
##
## A system that has not landed yet simply never asks; an absent research system
## means every multiplier is 1.0 and every add is 0.0. Nothing breaks.

# --- heat (P02) ---
const E_HEAT_DEMAND_MULT: StringName = &"heat.demand_mult"           ## consumer draw
const E_HEAT_OUTPUT_MULT: StringName = &"heat.output_mult"           ## generator output
const E_HEAT_LOSS_MULT: StringName = &"heat.loss_mult"               ## per-tile transmission loss
const E_HEAT_THROUGHPUT_MULT: StringName = &"heat.throughput_mult"   ## conduit capacity
const E_HEAT_RADIUS_MULT: StringName = &"heat.radius_mult"           ## radiant warmth radius
const E_HEAT_FUEL_MULT: StringName = &"heat.fuel_mult"               ## fuel burned per unit
const E_HEAT_BUFFER_MULT: StringName = &"heat.buffer_mult"           ## accumulator storage

# --- build (P11) ---
const E_BUILD_SPEED_MULT: StringName = &"build.speed_mult"
const E_BUILD_COST_MULT: StringName = &"build.cost_mult"

# --- logistics (P03) ---
const E_LOGI_THROUGHPUT_MULT: StringName = &"logistics.throughput_mult"
const E_LOGI_STORAGE_MULT: StringName = &"logistics.storage_mult"

# --- production / mining (P04) ---
const E_MINE_YIELD_MULT: StringName = &"mining.yield_mult"
const E_CRAFT_SPEED_MULT: StringName = &"craft.speed_mult"
const E_SCRAP_YIELD_MULT: StringName = &"mining.scrap_mult"
const E_FUEL_VALUE_MULT: StringName = &"production.fuel_value_mult"

# --- combat (P07) ---
const E_TURRET_DAMAGE_MULT: StringName = &"combat.turret_damage_mult"
const E_TURRET_RATE_MULT: StringName = &"combat.turret_rate_mult"
const E_TURRET_RANGE_MULT: StringName = &"combat.turret_range_mult"
const E_TURRET_ACCURACY_MULT: StringName = &"combat.turret_accuracy_mult"
const E_TURRET_PIERCE_ADD: StringName = &"combat.turret_pierce_add"
const E_STRUCTURE_HP_MULT: StringName = &"combat.structure_hp_mult"
const E_STRUCTURE_ARMOR_ADD: StringName = &"combat.structure_armor_add"
const E_VISION_MULT: StringName = &"combat.vision_mult"

# --- citizens (P05) ---
const E_EXPOSURE_RESIST: StringName = &"citizens.exposure_resist"
const E_FOOD_MULT: StringName = &"citizens.food_mult"
const E_HEAL_MULT: StringName = &"citizens.heal_mult"
const E_NIGHT_WORK_MULT: StringName = &"citizens.night_work_mult"
const E_WORKFORCE_MULT: StringName = &"citizens.workforce_mult"

# --- society (P06) ---
const E_HOPE_MULT: StringName = &"society.hope_mult"
const E_DISCONTENT_MULT: StringName = &"society.discontent_mult"

# --- research itself ---
const E_RESEARCH_SPEED_MULT: StringName = &"research.speed_mult"

## Every key above, sorted. Used by the content validator to catch a typo in a
## .tres before it becomes an effect that silently does nothing forever.
const EFFECT_KEYS: Array[StringName] = [
	E_BUILD_COST_MULT, E_BUILD_SPEED_MULT,
	E_TURRET_ACCURACY_MULT, E_TURRET_DAMAGE_MULT, E_TURRET_PIERCE_ADD,
	E_TURRET_RANGE_MULT, E_TURRET_RATE_MULT,
	E_STRUCTURE_ARMOR_ADD, E_STRUCTURE_HP_MULT, E_VISION_MULT,
	E_EXPOSURE_RESIST, E_FOOD_MULT, E_HEAL_MULT, E_NIGHT_WORK_MULT, E_WORKFORCE_MULT,
	E_CRAFT_SPEED_MULT,
	E_HEAT_BUFFER_MULT, E_HEAT_DEMAND_MULT, E_HEAT_FUEL_MULT, E_HEAT_LOSS_MULT,
	E_HEAT_OUTPUT_MULT, E_HEAT_RADIUS_MULT, E_HEAT_THROUGHPUT_MULT,
	E_LOGI_STORAGE_MULT, E_LOGI_THROUGHPUT_MULT,
	E_MINE_YIELD_MULT, E_SCRAP_YIELD_MULT,
	E_FUEL_VALUE_MULT,
	E_RESEARCH_SPEED_MULT,
	E_HOPE_MULT, E_DISCONTENT_MULT,
]


## True when the key is one the effect layer knows about.
static func is_effect_key(key: StringName) -> bool:
	return EFFECT_KEYS.has(key)


## True for keys that stack as 1.0 + sum.
static func is_multiplier_key(key: StringName) -> bool:
	return String(key).ends_with("_mult")


# ==========================================================================
#  PACING SIGNALS — the problems the player is actually feeling
# ==========================================================================
##
## A node names ONE signal it is an answer to. The pacing engine measures every
## signal from the live world, 0..1, and the suggestion it makes is whichever
## available node answers the loudest one. This is the whole design of the tree:
## a node is not "next in the list", it is "the answer to the thing that hurt
## you last night".

const SIG_NONE: StringName = &""
const SIG_HEAT_DEFICIT: StringName = &"heat_deficit"        ## demand the grid cannot cover
const SIG_HEAT_LOSS: StringName = &"heat_loss"              ## heat lost in the pipes
const SIG_HEAT_BOTTLENECK: StringName = &"heat_bottleneck"  ## one tile throttling many
const SIG_HEAT_PEAK: StringName = &"heat_peak"              ## fine by day, short at night
const SIG_FROZEN: StringName = &"frozen"                    ## buildings actually frozen
const SIG_COLD: StringName = &"cold"                        ## the plain itself is lethal
const SIG_STORM: StringName = &"storm"                      ## a Great Frost is inbound
const SIG_FUEL: StringName = &"fuel"                        ## burners running dry
const SIG_WAVE: StringName = &"wave"                        ## night pressure rising
const SIG_ARMOURED: StringName = &"armoured"                ## shots bouncing off armour
const SIG_SWARM: StringName = &"swarm"                      ## too many, too fast
const SIG_BLIND: StringName = &"blind"                      ## cannot see what is killing you
const SIG_STRUCTURE_LOSS: StringName = &"structure_loss"    ## walls coming apart
const SIG_SPRAWL: StringName = &"sprawl"                    ## the base has outgrown hands
const SIG_TANGLE: StringName = &"tangle"                    ## belts and pipes fighting for tiles
const SIG_MATERIALS: StringName = &"materials"              ## the yard is empty
const SIG_CASUALTIES: StringName = &"casualties"            ## people dying
const SIG_HUNGER: StringName = &"hunger"                    ## food short
const SIG_DISCONTENT: StringName = &"discontent"            ## the crowd at the hearth
const SIG_LABOUR: StringName = &"labour"                    ## not enough hands, not enough hours

const SIGNAL_KEYS: Array[StringName] = [
	SIG_ARMOURED, SIG_BLIND, SIG_CASUALTIES, SIG_COLD, SIG_DISCONTENT,
	SIG_FROZEN, SIG_FUEL, SIG_HEAT_BOTTLENECK, SIG_HEAT_DEFICIT, SIG_HEAT_LOSS,
	SIG_HEAT_PEAK, SIG_HUNGER, SIG_LABOUR, SIG_MATERIALS, SIG_SPRAWL,
	SIG_STORM, SIG_STRUCTURE_LOSS, SIG_SWARM, SIG_TANGLE, SIG_WAVE,
]

## Player-facing phrasing of a measured signal. The pacing engine fills in the
## measurement; this is the half a designer wrote.
const SIGNAL_LINES: Dictionary = {
	SIG_HEAT_DEFICIT: "the grid is short of heat",
	SIG_HEAT_LOSS: "heat is dying in the pipes before it arrives",
	SIG_HEAT_BOTTLENECK: "a single pipe tile is throttling the district behind it",
	SIG_HEAT_PEAK: "the generators cover the day and lose the night",
	SIG_FROZEN: "buildings are freezing solid",
	SIG_COLD: "the plain outside is lethal",
	SIG_STORM: "a Great Frost is coming",
	SIG_FUEL: "the burners are running dry",
	SIG_WAVE: "what comes out of the dark is getting heavier",
	SIG_ARMOURED: "your shots are bouncing off",
	SIG_SWARM: "they arrive faster than the turrets cycle",
	SIG_BLIND: "you cannot see what is killing you",
	SIG_STRUCTURE_LOSS: "the wall is coming apart",
	SIG_SPRAWL: "the base has outgrown what hands can carry",
	SIG_TANGLE: "belts and pipes are fighting over the same tiles",
	SIG_MATERIALS: "the yard is empty",
	SIG_CASUALTIES: "people are dying",
	SIG_HUNGER: "the granary will not last",
	SIG_DISCONTENT: "the crowd at the hearth is not asking politely",
	SIG_LABOUR: "there are not enough hands and not enough hours",
}


static func signal_line(sig: StringName) -> String:
	return String(SIGNAL_LINES.get(sig, "the city needs something it does not have"))


static func is_signal(sig: StringName) -> bool:
	return SIGNAL_KEYS.has(sig)


# ==========================================================================
#  GRANT PREFIXES — what an unlock id means to whoever reads it
# ==========================================================================

const PREFIX_LAW: String = "law_"
const PREFIX_RECIPE: String = "recipe_"


static func is_law(id: StringName) -> bool:
	return String(id).begins_with(PREFIX_LAW)


static func is_recipe(id: StringName) -> bool:
	return String(id).begins_with(PREFIX_RECIPE)


# ==========================================================================
#  ALERT / EVENT KEYS
# ==========================================================================

const KEY_STARTED: StringName = &"research_started"
const KEY_COMPLETED: StringName = &"research_completed"
const KEY_STALLED: StringName = &"research_stalled"
const KEY_SUGGESTED: StringName = &"research_suggested"
const KEY_IDLE: StringName = &"research_idle"

## Bus severity is capped at 1 everywhere in the sim: the harness fails a run on
## severity >= 2, and research is never a run failure.
const MAX_BUS_SEVERITY: int = 1
