class_name EnemyDef
extends Resource
## The definition of one thing that comes out of the dark. **This is the schema
## the director composes from and [P07] combat spawns from.**
##
## Drop a .tres of this type into `game/content/enemies/` and Registry finds it —
## there is no list to edit. Look one up with
## `Registry.get_item("enemies", &"husk") as EnemyDef`.
##
## Fields are grouped by the part that consumes them. The director only reads
## the ECONOMY block and `role`; everything below it exists so that combat,
## render and audio never have to invent numbers of their own.
##
## Every field has a sane default, so a def only states what it cares about.

# ------------------------------------------------------------------ identity

## Stable id. Must be unique across game/content/enemies/ and match the filename.
@export var id: StringName = &""
## Player-facing name, singular. "Husk".
@export var display_name: String = ""
## Player-facing name, plural, used in warnings. "husks".
@export var plural_name: String = ""
## One or two sentences. Flavour first, mechanical hint second.
@export var description: String = ""
## Progression tier 1..4. Sorts previews and paces what the player meets when.
@export var tier: int = 1
## Free-form markers: armoured, fast, burrower, pack, cold_blooded, boss.
@export var tags: Array[StringName] = []

# ------------------------------------------------------- director economy ---
# The wave director spends a budget. These five numbers are the whole economy,
# and they are the only ones it reads, which is why balancing a night is a
# content edit rather than a code change.

## Budget points one unit costs the director. The single balance knob.
@export var cost: float = 1.0
## The director will not compose this before wave N. Hard gate, never softened
## by adaptation — a player cannot be surprised by tier 4 on night two.
@export var min_wave: int = 1
## Ceiling on the share of ONE wave's budget that may go to this def. Keeps a
## cheap swarm unit from eating an entire night on a lucky roll. One minimum
## pack is always legal regardless, so a def can never be silently unbuildable.
@export var max_share: float = 0.65
## Units are composed in multiples of this. Swarm things arrive in tens.
@export var pack_size: int = 1
## Relative selection weight inside its role. 0 removes it from composition
## without deleting the content.
@export var weight: float = 1.0
## What this unit is FOR. One of ThreatDefs.ROLES.
@export var role: StringName = &"line"

# --------------------------------------------------------- combat statline --
# [P07] owns what happens on the field. These are the numbers it spawns with;
# the director uses only `threat_rating()` derived from them, and only when it
# has to resolve a night without a combat system present.

## Structural hit points.
@export var hp: float = 40.0
## Flat damage reduction per hit. Armoured things laugh at swarm turrets.
@export var armor: float = 0.0
## Tiles per second on clear ground. Snow and terrain slow it further.
@export var speed: float = 1.2
## Damage per attack against structures.
@export var damage: float = 8.0
## Seconds between attacks.
@export var attack_interval: float = 1.0
## Tiles it can reach from. 1.0 is melee.
@export var attack_range: float = 1.0
## Tiles of sight. Drives when it peels off a lane toward a warmer target.
@export var vision_radius: float = 8.0
## Crosses walls and water. Flyers ignore chokepoints, which is why they are
## gated late and cost a lot.
@export var flying: bool = false
## Units of the pack that share one health pool in the abstract siege model.
## Purely a resolution granularity; combat spawns individuals.
@export var squad_size: int = 1

# --------------------------------------------------------- the heat hunger --
# Why they come at all. Warmth is visible from the plain, so the city that
# survives the cold best is the city that is hunted hardest.

## 0..1. How strongly this thing beelines for the warmest thing it can see
## rather than following the lane to the core. 1.0 walks straight at a generator.
@export var heat_seeking: float = 0.5
## Heat units per second it tears out of a building it is in contact with.
## [P02] loses this from the network; it is not damage, it is theft.
@export var heat_drain: float = 0.0
## Multiplier on its speed while standing in warm ground. They wake up in heat.
@export var warmth_speed_bonus: float = 0.25

# ----------------------------------------------------------- view / audio ---

## Body silhouette key the renderer maps to a sprite set.
@export var silhouette: StringName = &"quadruped"
## Body radius in pixels, for the view and for contact resolution.
@export var body_radius: float = 10.0
## Accent colour on the minimap, the threat overlay and the preview panel.
@export var tint: Color = Color(0.72, 0.29, 0.31)
## Audio cue key played when a group of these is telegraphed.
@export var warn_sound: StringName = &"threat_generic"


## Loose validation. Returns the problems found; an empty array means the def is
## composable. Called once at setup so bad content fails loudly instead of
## quietly skewing every night for the rest of the campaign.
func validate() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if id == &"":
		out.append("id is empty")
	if cost <= 0.0:
		out.append("cost must be > 0 (it is the director's only currency)")
	if pack_size < 1:
		out.append("pack_size must be >= 1")
	if min_wave < 1:
		out.append("min_wave must be >= 1")
	if max_share <= 0.0 or max_share > 1.0:
		out.append("max_share must be in (0, 1]")
	if weight < 0.0:
		out.append("weight must be >= 0")
	if not ThreatDefs.is_role(role):
		out.append("role '%s' is not one of %s" % [role, ThreatDefs.ROLES])
	if hp <= 0.0:
		out.append("hp must be > 0")
	if speed <= 0.0:
		out.append("speed must be > 0")
	if squad_size < 1:
		out.append("squad_size must be >= 1")
	return out


## Damage per second against structures, at full health.
func dps() -> float:
	return damage / maxf(0.05, attack_interval)


## Effective durability against a defence that deals `shot` damage per hit.
## Armour is subtracted per hit, so it is worth far more against many small
## shots than against one big one — the same rule buildings play by.
func effective_hp(shot: float) -> float:
	var taken: float = maxf(1.0, shot - armor)
	return hp * shot / taken


## A single scalar the director can compare units by. Not used for composition
## (that is `cost`, which is authored), only for reporting how heavy a wave is.
func threat_rating() -> float:
	return (hp * (1.0 + armor * 0.08) * 0.02) + dps() * 0.6 + speed * 2.0


func plural() -> String:
	if plural_name != "":
		return plural_name
	return display_name if display_name != "" else String(id)


## JSON-safe summary for previews, saves and the harness dump.
func to_dict() -> Dictionary:
	return {
		"id": String(id),
		"name": display_name,
		"plural": plural(),
		"role": String(role),
		"tier": tier,
		"cost": cost,
		"min_wave": min_wave,
		"pack_size": pack_size,
		"hp": hp,
		"armor": armor,
		"speed": speed,
		"dps": snappedf(dps(), 0.01),
		"flying": flying,
		"heat_seeking": heat_seeking,
		"heat_drain": heat_drain,
	}
