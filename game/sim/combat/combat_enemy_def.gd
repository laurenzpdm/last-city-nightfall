class_name CombatEnemyDef
extends Resource
## The definition of one thing that comes out of the dark.
##
## Drop a .tres of this type into `game/content/enemies/` and Registry finds it —
## there is no list to edit. Look one up with
## `Registry.get_item("enemies", &"drift_hound") as CombatEnemyDef`.
##
## [b]It also adopts foreign definitions.[/b] [P08] threat keeps a second, shallower
## enemy schema for composing waves out of the same folder. Rather than fight over
## one class name, [method from_resource] reads any resource in `enemies/` that
## exposes an hp/speed/damage statline and derives the combat-side fields it does
## not state — so whichever part authored a creature, this one can field it.
##
## The design rule this schema exists to enforce: **no stat-scaled copies.** A new
## enemy earns its place by demanding a different answer, and the fields that
## decide that are [member behaviour], [member target_pref], [member resist_*] and
## [member attack_range]. Two defs that differ only in hp and speed are one enemy.
##
## [CombatSystem] reads every def exactly once at world creation and copies the
## hot numbers into packed arrays ([EnemySwarm]), so nothing in the per-tick loop
## ever touches a Resource property.

# ---------------------------------------------------------------- identity ---

## Stable id. Unique across game/content/enemies/, matches the filename.
@export var id: StringName = &""
## Player-facing name, short enough for a threat readout row.
@export var display_name: String = ""
## What it is and, more importantly, what it punishes. The player reads this in
## the bestiary; a critic reads it to check the roster is not eight of one thing.
@export var description: String = ""
## Free-form markers: swarm, armoured, elite, boss, flying, burrowing.
@export var tags: Array[StringName] = []
## Campaign day this thing may first appear on. The director honours it.
@export var min_day: int = 1
## Relative weight in a mixed wave. 0 keeps it out of random waves entirely
## (bosses are placed on purpose, never rolled).
@export var wave_weight: float = 1.0
## Threat points one of these is worth. The director spends a night's budget on
## these, so this is the single number that balances a wave.
@export var threat_value: float = 1.0
## How many arrive together when the director picks this kind.
@export var pack_size: int = 1

# ---------------------------------------------------------------- body -------

@export var health: float = 100.0
## Flat damage reduction on every hit taken. See CombatTypes.resolve_damage.
@export var armour: float = 0.0
## Movement in tiles per second on clean ground. Snow scales it down, a rally
## aura scales it up.
@export var speed: float = 2.0
## Body radius in tiles. Decides splash coverage and how close a turret must be.
@export var body_radius: float = 0.35
## Hit points regenerated per second while standing on ground colder than
## [member regen_below_c]. The city's warmth is a weapon against these.
@export var regen_per_second: float = 0.0
## Ambient-plus-warmth temperature above which regeneration stops.
@export var regen_below_c: float = -20.0

## Incoming damage multipliers, one per CombatTypes.Damage channel.
@export var resist_kinetic: float = 1.0
@export var resist_flame: float = 1.0
@export var resist_blast: float = 1.0
@export var resist_shock: float = 1.0

# ---------------------------------------------------------------- teeth ------

## CombatTypes.Behaviour, by name: advance, breaker, siphon, burrow, fly,
## siege, suicide, support, boss.
@export var behaviour: StringName = &"advance"
## Damage per attack against a structure, before its armour.
@export var damage: float = 10.0
## CombatTypes.Damage channel this thing deals: kinetic, flame, blast, shock.
@export var damage_type: StringName = &"kinetic"
## Seconds between attacks.
@export var attack_interval: float = 1.0
## Tiles from the target's edge at which it can attack. Melee is ~0.6; a siege
## engine sets this beyond the range of the cheap turrets on purpose.
@export var attack_range: float = 0.7
## Splash radius in tiles around each hit. 0 is single-target.
@export var splash_radius: float = 0.0
## Extra damage against structures carrying [member preferred_tag].
@export var preferred_multiplier: float = 1.0
## Tag it hunts: any, wall, conduit, turret, housing, heat_source.
@export var target_pref: StringName = &"any"
## Tiles it will divert to reach a preferred target. 0 means it never diverts.
@export var seek_radius: float = 0.0
## It dies the moment it lands one attack. Sappers and charges.
@export var detonates: bool = false
## Hit points restored per point of damage dealt to a preferred target. A leech
## that is eating your trunk main is also healing off it.
@export var lifesteal: float = 0.0
## Heat units per second stolen out of the magazines of turrets within
## [member aura_radius] while this thing is attacking. Heat denial, not damage.
@export var siphon_rate: float = 0.0
## Discontent added per second while alive inside the city's sight. [P06] society
## takes it if it exists; combat counts it either way.
@export var discontent_per_second: float = 0.0

# ---------------------------------------------------------------- movement ---

## Walls, buildings and pipes do not block it. Burrowers and flyers.
@export var ignores_walls: bool = false
## Untargetable until it surfaces. A burrower surfaces this many tiles from the
## core; up to then a turret cannot touch it. -1 keeps it visible the whole way.
@export var surfaces_within_tiles: float = -1.0

# ---------------------------------------------------------------- support ----

## CombatTypes.Aura: none, rally, chill.
@export var aura: StringName = &"none"
@export var aura_radius: float = 0.0
## Rally: extra fraction of speed and damage granted. Chill: fraction of a
## turret's charge rate taken away.
@export var aura_power: float = 0.0

# ---------------------------------------------------------------- phases -----

## Enemy id spawned when this one crosses a health gate, or dies.
@export var spawns_kind: StringName = &""
## How many per gate.
@export var spawns_count: int = 0
## Fraction of max health between gates. 0.15 means adds at 85%, 70%, 55%, ...
@export var spawns_every_fraction: float = 0.0
## Also spawn a batch on death.
@export var spawns_on_death: bool = false

# ---------------------------------------------------------------- view -------

## Render archetype the sprite factory understands today: swarm or brute.
## [P13] bakes agents by this name; anything else silently draws as a citizen.
@export var render_arch: StringName = &"swarm"
## Accent colour for the threat readout and the minimap blip.
@export var tint: Color = Color(0.72, 0.30, 0.34)


## Adopts a definition authored against a different schema. Returns null when the
## resource is not an enemy statline at all.
##
## The rule, mirroring what [HeatDef] does for buildings: read what the resource
## states, derive the rest, and never hard-code a creature's name. [P08]'s schema
## spells hit points `hp`, plating `armor`, and gates on `min_wave`/`cost`; it has
## no damage channels, no resistances and no behaviour, so those are derived from
## its `role` and `flying` fields. A creature adopted this way fights correctly —
## it simply has none of the sharper edges an authored combat def can carry.
static func from_resource(res: Resource) -> CombatEnemyDef:
	if res == null or res is CombatEnemyDef:
		return res as CombatEnemyDef
	if not ("hp" in res and "speed" in res and "damage" in res):
		return null
	var d := CombatEnemyDef.new()
	d.id = StringName(String(res.get("id"))) if "id" in res else StringName(res.resource_path.get_file().get_basename())
	d.display_name = String(res.get("display_name")) if "display_name" in res else String(d.id)
	d.description = String(res.get("description")) if "description" in res else "Adopted from a foreign enemy definition."
	if "tags" in res:
		for t: Variant in (res.get("tags") as Array):
			d.tags.append(StringName(String(t)))
	d.health = maxf(1.0, float(res.get("hp")))
	d.armour = float(res.get("armor")) if "armor" in res else 0.0
	d.speed = maxf(0.0, float(res.get("speed")))
	d.damage = float(res.get("damage"))
	d.attack_interval = maxf(0.05, float(res.get("attack_interval"))) if "attack_interval" in res else 1.0
	d.attack_range = float(res.get("attack_range")) if "attack_range" in res else 1.0
	# Their body radius is authored in pixels; ours is in tiles.
	d.body_radius = maxf(0.15, float(res.get("body_radius")) / 32.0) if "body_radius" in res else 0.35
	d.ignores_walls = bool(res.get("flying")) if "flying" in res else false
	d.pack_size = maxi(1, int(res.get("pack_size"))) if "pack_size" in res else 1
	d.min_day = maxi(1, int(res.get("min_wave"))) if "min_wave" in res else 1
	d.wave_weight = float(res.get("weight")) if "weight" in res else 1.0
	d.threat_value = maxf(0.1, float(res.get("cost"))) if "cost" in res else 1.0
	if "tint" in res:
		d.tint = res.get("tint")
	# Role decides the two things a shallow schema cannot state: what it walks up
	# to, and how it is drawn.
	var role: StringName = StringName(String(res.get("role"))) if "role" in res else &"line"
	match role:
		&"breaker":
			d.behaviour = &"breaker"
			d.target_pref = &"wall"
			d.preferred_multiplier = 2.0
			d.seek_radius = 10.0
			d.render_arch = &"brute"
		&"stalker":
			d.behaviour = &"fly" if d.ignores_walls else &"advance"
			d.target_pref = &"turret"
			d.preferred_multiplier = 1.6
			d.seek_radius = 16.0
		&"siege":
			d.behaviour = &"siege"
			d.seek_radius = maxf(d.attack_range + 2.0, 8.0)
			d.render_arch = &"brute"
		_:
			d.behaviour = &"fly" if d.ignores_walls else &"advance"
	if "heat_drain" in res and float(res.get("heat_drain")) > 0.0:
		d.behaviour = &"siphon"
		d.target_pref = &"conduit"
		d.preferred_multiplier = 4.0
		d.seek_radius = maxf(d.seek_radius, 18.0)
		d.siphon_rate = float(res.get("heat_drain"))
		d.aura_radius = 7.0
	return d


## Multiplier for one CombatTypes.Damage channel.
func resist_of(channel: int) -> float:
	match channel:
		CombatTypes.Damage.KINETIC: return resist_kinetic
		CombatTypes.Damage.FLAME: return resist_flame
		CombatTypes.Damage.BLAST: return resist_blast
		CombatTypes.Damage.SHOCK: return resist_shock
	return 1.0


func behaviour_index() -> int:
	return CombatTypes.enum_of(CombatTypes.BEHAVIOUR_NAMES, behaviour, CombatTypes.Behaviour.ADVANCE)


func damage_channel() -> int:
	return CombatTypes.enum_of(CombatTypes.DAMAGE_NAMES, damage_type, CombatTypes.Damage.KINETIC)


func aura_index() -> int:
	return CombatTypes.enum_of(CombatTypes.AURA_NAMES, aura, CombatTypes.Aura.NONE)


func has_tag(t: StringName) -> bool:
	return tags.has(t)


## Content sanity check. Returns human-readable problems; empty means clean.
## [CombatSystem] runs it over every def at world creation, so a bad .tres shows
## up in the log at second zero instead of as a mystery at minute forty.
func validate() -> PackedStringArray:
	var problems: PackedStringArray = PackedStringArray()
	if String(id) == "":
		problems.append("missing id")
	if display_name == "":
		problems.append("missing display_name")
	if description == "":
		problems.append("missing description — say what this enemy punishes")
	if health <= 0.0:
		problems.append("health must be > 0")
	if speed < 0.0:
		problems.append("speed must not be negative")
	if attack_interval <= 0.0:
		problems.append("attack_interval must be > 0")
	if armour < 0.0:
		problems.append("armour must not be negative")
	if pack_size < 1:
		problems.append("pack_size must be at least 1")
	if threat_value <= 0.0:
		problems.append("threat_value must be > 0 — the director budgets in these")
	if not CombatTypes.BEHAVIOUR_NAMES.has(behaviour):
		problems.append("unknown behaviour '%s'" % behaviour)
	if not CombatTypes.DAMAGE_NAMES.has(damage_type):
		problems.append("unknown damage_type '%s'" % damage_type)
	if not CombatTypes.AURA_NAMES.has(aura):
		problems.append("unknown aura '%s'" % aura)
	if aura_index() != CombatTypes.Aura.NONE and aura_radius <= 0.0:
		problems.append("aura '%s' with no radius" % aura)
	if String(spawns_kind) != "" and spawns_count <= 0:
		problems.append("spawns_kind set but spawns_count is 0")
	for r: float in [resist_kinetic, resist_flame, resist_blast, resist_shock]:
		if r < 0.0:
			problems.append("resistances must not be negative")
			break
	return problems
