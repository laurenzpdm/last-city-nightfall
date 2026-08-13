class_name WeaponDef
extends Resource
## What a turret mount actually fires.
##
## Drop a .tres into `game/content/weapons/` and Registry finds it. A building
## picks its default barrel with `BuildingDef.weapon_id`, and the player can
## refit a placed mount by writing `meta.weapon` on the instance — the same
## per-instance meta channel [P11] documents for recipes and storage filters.
## One mount, several answers, chosen after the wall is already up.
##
## THE contract this schema encodes: **a shot costs heat.** [member heat_per_shot]
## comes out of the turret's magazine, and the magazine only charges as fast as
## the heat grid actually serves that building. Defend harder and the city gets
## colder; heat the city badly and the wall stops shooting. That is the whole
## fusion of the three genres in one float.

# ---------------------------------------------------------------- identity ---

@export var id: StringName = &""
@export var display_name: String = ""
## What it is good at and what it is bad at. The refit menu shows this.
@export var description: String = ""
## Free-form markers: anti_swarm, anti_armour, siege, incendiary.
@export var tags: Array[StringName] = []

# ---------------------------------------------------------------- ballistics -

## CombatTypes.Delivery: projectile (travels), hitscan (instant), cone (sustained).
@export var delivery: StringName = &"projectile"
## Damage per shot, or per second for a cone weapon.
@export var damage: float = 20.0
## CombatTypes.Damage channel: kinetic, flame, blast, shock.
@export var damage_type: StringName = &"kinetic"
## Flat enemy armour this weapon ignores.
@export var pierce: float = 0.0
## Shots (or pellets) released per pull of the trigger.
@export var shots_per_burst: int = 1
## Seconds between shots inside a burst.
@export var burst_interval: float = 0.05
## Seconds between bursts.
@export var reload: float = 1.0
## Maximum engagement range in tiles.
@export var range_tiles: float = 10.0
## Minimum range in tiles. A mortar cannot defend its own feet.
@export var min_range_tiles: float = 0.0
## Projectile speed in tiles per second. Ignored for hitscan and cone.
@export var projectile_speed: float = 28.0
## Splash radius in tiles at the point of impact. 0 is single-target.
@export var splash_radius: float = 0.0
## Fraction of full damage at the edge of the splash. Centre always takes 100%.
@export var splash_falloff: float = 0.35
## Half-angle of a cone weapon, in degrees.
@export var cone_degrees: float = 30.0
## Aim error in degrees, applied deterministically per shot from the Rng stream.
## A scatter gun leans on this; a rail lance has none.
@export var spread_degrees: float = 0.0
## Burning damage per second applied on hit, and for how long.
@export var burn_dps: float = 0.0
@export var burn_seconds: float = 0.0

# ---------------------------------------------------------------- handling ---

## Barrel slew in degrees per second. A heavy gun cannot track a swarm.
@export var turn_rate: float = 180.0
## Degrees of aim error the gunner will still fire through.
@export var aim_tolerance: float = 6.0
## Default CombatTypes.Aim policy when the player has not chosen one.
@export var default_aim: StringName = &"first"
## Fraction of the target's velocity the gunner leads by. 1.0 is a perfect
## intercept; below that, fast things are genuinely hard to hit.
@export var lead_factor: float = 1.0

# ---------------------------------------------------------------- supply -----

## Heat units drawn from the mount's magazine per shot, or per second for a cone.
@export var heat_per_shot: float = 2.0
## Item consumed per shot. Empty means the weapon needs no ammunition.
## [P03] logistics / [P04] production feed it; combat degrades to unlimited
## ammunition (and says so in the log) while neither exists.
@export var ammo_item: StringName = &""
@export var ammo_per_shot: int = 1
## Rounds the mount holds locally.
@export var ammo_capacity: int = 40

# ---------------------------------------------------------------- view -------

## Tracer colour [P14] draws the shot with.
@export var tracer_color: Color = Color(1.0, 0.72, 0.36)
## Tracer thickness in pixels.
@export var tracer_width: float = 1.6


func delivery_index() -> int:
	return CombatTypes.enum_of(CombatTypes.DELIVERY_NAMES, delivery, CombatTypes.Delivery.PROJECTILE)


func damage_channel() -> int:
	return CombatTypes.enum_of(CombatTypes.DAMAGE_NAMES, damage_type, CombatTypes.Damage.KINETIC)


func default_aim_index() -> int:
	return CombatTypes.enum_of(CombatTypes.AIM_NAMES, default_aim, CombatTypes.Aim.FIRST)


func has_tag(t: StringName) -> bool:
	return tags.has(t)


## Sustained damage per second at full supply, ignoring travel time and misses.
## The number the refit menu and the balance pass both quote.
func dps() -> float:
	if delivery_index() == CombatTypes.Delivery.CONE:
		return damage
	var cycle: float = maxf(0.05, reload + float(maxi(shots_per_burst - 1, 0)) * burst_interval)
	return damage * float(maxi(shots_per_burst, 1)) / cycle


## Heat units per second at a sustained rate of fire.
func heat_per_second() -> float:
	if delivery_index() == CombatTypes.Delivery.CONE:
		return heat_per_shot
	var cycle: float = maxf(0.05, reload + float(maxi(shots_per_burst - 1, 0)) * burst_interval)
	return heat_per_shot * float(maxi(shots_per_burst, 1)) / cycle


## Content sanity check. Empty means clean.
func validate() -> PackedStringArray:
	var problems: PackedStringArray = PackedStringArray()
	if String(id) == "":
		problems.append("missing id")
	if display_name == "":
		problems.append("missing display_name")
	if description == "":
		problems.append("missing description — say what this weapon answers")
	if damage <= 0.0:
		problems.append("damage must be > 0")
	if reload <= 0.0:
		problems.append("reload must be > 0")
	if range_tiles <= 0.0:
		problems.append("range_tiles must be > 0")
	if min_range_tiles >= range_tiles:
		problems.append("min_range_tiles must be below range_tiles")
	if shots_per_burst < 1:
		problems.append("shots_per_burst must be at least 1")
	if heat_per_shot < 0.0:
		problems.append("heat_per_shot must not be negative")
	if not CombatTypes.DELIVERY_NAMES.has(delivery):
		problems.append("unknown delivery '%s'" % delivery)
	if not CombatTypes.DAMAGE_NAMES.has(damage_type):
		problems.append("unknown damage_type '%s'" % damage_type)
	if not CombatTypes.AIM_NAMES.has(default_aim):
		problems.append("unknown default_aim '%s'" % default_aim)
	if delivery_index() == CombatTypes.Delivery.PROJECTILE and projectile_speed <= 0.0:
		problems.append("a projectile weapon needs projectile_speed > 0")
	if delivery_index() == CombatTypes.Delivery.CONE and cone_degrees <= 0.0:
		problems.append("a cone weapon needs cone_degrees > 0")
	if String(ammo_item) != "" and ammo_per_shot <= 0:
		problems.append("ammo_item set but ammo_per_shot is 0")
	return problems
