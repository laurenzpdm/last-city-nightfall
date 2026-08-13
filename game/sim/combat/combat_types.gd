class_name CombatTypes
extends RefCounted
## Shared vocabulary for [P07] Combat. Pure data + static functions, no state.
##
## The three numbers that decide every fight in this game live here:
##
##   1. **Damage vs armour.** Armour is FLAT reduction, softened by a weapon's
##      pierce and floored at [constant MIN_DAMAGE_FRACTION] of the raw hit. That
##      one line is the whole "spam is punished" design: twenty 5-damage pellets
##      into 14 armour deliver 10 damage in total, one 90-damage shell delivers 79.
##   2. **Resistance by damage type.** Every enemy multiplies incoming damage by a
##      per-type factor, so a defence built out of one weapon has a hole in it.
##   3. **Heat per shot.** A turret fires out of a heat magazine it charges off
##      the city grid. No heat, no shot — see [TurretBattery].
##
## Everything else in this folder is bookkeeping around those three.

# --------------------------------------------------------------- damage ------

## Damage channels. Index order is serialized in save data — append, never reorder.
enum Damage {
	KINETIC,  ## shells, slugs, shrapnel. The bread-and-butter, armour hates it back.
	FLAME,    ## burns over time, hits a cone, costs a lot of heat
	BLAST,    ## area, ignores nothing, expensive and slow
	SHOCK,    ## arc weapons: little raw damage, but it walks straight past plating
}
const DAMAGE_COUNT: int = 4
const DAMAGE_NAMES: Array[StringName] = [&"kinetic", &"flame", &"blast", &"shock"]

## No hit is ever fully absorbed: an unarmoured-looking scratch still lands.
## Without this floor, one over-armoured enemy would make a whole defence
## mathematically useless rather than merely a bad answer.
const MIN_DAMAGE_FRACTION: float = 0.10

## Structural damage a wall soaks before the flow field starts treating it as a
## soft spot. See [AssaultField.weaken].
const BREACH_HEALTH: float = 0.5


## Damage actually delivered by one hit.
## `resist` is the target's multiplier for this damage channel, `armour` its flat
## plating and `pierce` how much of that plating the weapon ignores.
static func resolve_damage(raw: float, resist: float, armour: float, pierce: float) -> float:
	if raw <= 0.0:
		return 0.0
	var typed: float = raw * maxf(resist, 0.0)
	var plate: float = maxf(0.0, armour - maxf(pierce, 0.0))
	return maxf(typed * MIN_DAMAGE_FRACTION, typed - plate)


# --------------------------------------------------------------- enemies -----

## What an enemy is FOR. The behaviour picks the movement rule and the target
## rule; every other difference between two enemies is numbers on [EnemyDef].
enum Behaviour {
	ADVANCE,  ## walk the flow field to the warm centre, break whatever blocks it
	BREAKER,  ## the same, but it hunts the perimeter and picks the weakest panel
	SIPHON,   ## walks past the walls to the heat network and severs it
	BURROW,   ## underground: walls, pipes and turrets simply are not there
	FLY,      ## over the walls, and it knows where the guns are
	SIEGE,    ## stops out of turret range and shells what it can reach
	SUICIDE,  ## one enormous hit on the first structure it touches
	SUPPORT,  ## hangs back, buffs the pack, screams the city's morale apart
	BOSS,     ## the night boss: splash, an aura, and adds when it is hurt
}
const BEHAVIOUR_NAMES: Array[StringName] = [
	&"advance", &"breaker", &"siphon", &"burrow", &"fly",
	&"siege", &"suicide", &"support", &"boss",
]

## Runtime state of one enemy slot. Index order is serialized — append, never
## reorder.
enum EnemyState {
	WALKING,    ## following the field
	ATTACKING,  ## stopped, chewing on a structure
	SPENT,      ## dead, waiting for the end-of-tick compaction
	RETREATING, ## broken off: walking back out of the map, will not fight again
}
const ENEMY_STATE_NAMES: Array[StringName] = [
	&"walking", &"attacking", &"spent", &"retreating",
]


static func enemy_state_name(i: int) -> StringName:
	return ENEMY_STATE_NAMES[i] if i >= 0 and i < ENEMY_STATE_NAMES.size() else &"?"

## What an enemy walks past and what it walks up to.
const PREF_ANY: StringName = &"any"
const PREF_WALL: StringName = &"wall"
const PREF_CONDUIT: StringName = &"conduit"
const PREF_TURRET: StringName = &"turret"
const PREF_HOUSING: StringName = &"housing"
const PREF_HEAT_SOURCE: StringName = &"heat_source"

## Support auras. Few enough to enumerate, cheap enough to apply every tick.
enum Aura {
	NONE,
	RALLY,  ## nearby enemies move and hit harder
	CHILL,  ## nearby turret magazines charge slower — heat denial, not damage
}
const AURA_NAMES: Array[StringName] = [&"none", &"rally", &"chill"]


# --------------------------------------------------------------- turrets -----

## Target selection policy, stored per turret in `BuildingInstance.meta.aim`.
enum Aim {
	FIRST,     ## closest to the city core along the path — the classic TD default
	CLOSEST,   ## nearest to the turret
	STRONGEST, ## most remaining hit points
	WEAKEST,   ## least remaining hit points; finish the wounded
	ARMOURED,  ## heaviest plating first — for the guns that can actually hurt it
}
const AIM_NAMES: Array[StringName] = [&"first", &"closest", &"strongest", &"weakest", &"armoured"]

## Why a turret is not shooting right now. This is the combat half of the
## legibility contract: every silent gun can name its own reason, the same way
## [HeatSystem] can name the tile that browned a building out.
enum Idle {
	FIRING,       ## it is doing its job
	NO_TARGET,    ## nothing hostile inside its range
	TURNING,      ## has a target, still swinging onto it
	RELOADING,    ## between shots
	NO_HEAT,      ## magazine empty — the city took the warmth back
	NO_AMMO,      ## the belt never arrived
	OFFLINE,      ## unpowered, frozen, switched off or still under construction
	NO_WEAPON,    ## a turret mount with no weapon fitted
}
const IDLE_NAMES: Array[StringName] = [
	&"firing", &"no_target", &"turning", &"reloading",
	&"no_heat", &"no_ammo", &"offline", &"no_weapon",
]

## How a weapon delivers its damage.
enum Delivery {
	PROJECTILE,  ## travels, can be dodged by something fast enough
	HITSCAN,     ## instant, always connects, expensive
	CONE,        ## a sustained cone: flamethrowers, everything in front burns
}
const DELIVERY_NAMES: Array[StringName] = [&"projectile", &"hitscan", &"cone"]


# --------------------------------------------------------------- geometry ----

const TILE: float = 32.0


static func tiles_to_px(t: float) -> float:
	return t * TILE


static func px_to_tiles(p: float) -> float:
	return p / TILE


## Index of `name` in `table`, or `fallback`. Content is authored as readable
## StringNames; the simulation runs on ints.
static func enum_of(table: Array[StringName], name: StringName, fallback: int = 0) -> int:
	var i: int = table.find(name)
	return i if i >= 0 else fallback


static func damage_name(i: int) -> StringName:
	return DAMAGE_NAMES[i] if i >= 0 and i < DAMAGE_NAMES.size() else &"?"


static func behaviour_name(i: int) -> StringName:
	return BEHAVIOUR_NAMES[i] if i >= 0 and i < BEHAVIOUR_NAMES.size() else &"?"


static func aim_name(i: int) -> StringName:
	return AIM_NAMES[i] if i >= 0 and i < AIM_NAMES.size() else &"?"


static func idle_name(i: int) -> StringName:
	return IDLE_NAMES[i] if i >= 0 and i < IDLE_NAMES.size() else &"?"


static func aura_name(i: int) -> StringName:
	return AURA_NAMES[i] if i >= 0 and i < AURA_NAMES.size() else &"?"


static func delivery_name(i: int) -> StringName:
	return DELIVERY_NAMES[i] if i >= 0 and i < DELIVERY_NAMES.size() else &"?"


## Deterministic 0..1 value from two ints. Used for per-enemy lane offsets and
## spawn scatter that must not consume an Rng draw (an Rng draw taken inside a
## per-enemy loop makes the sequence depend on iteration order, which is exactly
## the kind of thing that survives testing and dies in a replay).
static func hash01(a: int, b: int) -> float:
	var h: int = (a * 73856093) ^ (b * 19349663)
	h = (h ^ (h >> 13)) * 1274126177
	return float((h >> 8) & 0xFFFF) / 65535.0
