class_name ThreatUnit
extends RefCounted
## The director's view of one creature: the six numbers it needs to compose a
## night, and nothing else.
##
## **It owns no content.** Creatures live in `game/content/enemies/` and are
## authored by whoever owns them — [P07] combat's [CombatEnemyDef] today, and any
## future schema tomorrow. This class ADAPTS whatever is in that folder: it reads
## the fields it recognises, derives the ones the author did not state, and hands
## the composer a uniform record. Two parts therefore share one roster instead of
## shipping two, and neither has to compile against the other's classes.
##
## Recognised on the economy side, first match wins:
##   cost        threat_value | cost                (derived from the statline)
##   min_wave    min_day | min_wave                 (1)
##   weight      wave_weight | weight               (1.0; 0 means "placed on
##                                                   purpose, never rolled")
##   pack_size   pack_size                          (1)
##   role        role | behaviour | tags            (line)
##   max_share   max_share                          (derived from the role)
##
## And on the statline: health|hp, armour|armor, speed, damage, attack_interval,
## attack_range, flying (or behaviour "fly", or the "flying" tag).

var id: StringName = &""
var display_name: String = ""
var plural_name: String = ""
var description: String = ""

# --- director economy ---
var cost: float = 1.0
var min_wave: int = 1
var weight: float = 1.0
var pack_size: int = 1
var max_share: float = 0.55
var role: StringName = ThreatDefs.ROLE_LINE
var tier: int = 1
var tags: Array[StringName] = []

# --- statline, used by the siege model and by previews ---
var hp: float = 40.0
var armor: float = 0.0
var speed: float = 1.5
var damage: float = 10.0
var attack_interval: float = 1.0
var attack_range: float = 1.0
var flying: bool = false
var heat_seeking: float = 0.5

## CombatTypes.Behaviour -> the director's role vocabulary. A behaviour says
## what a creature DOES on the field; a role says what it is FOR in a night.
const BEHAVIOUR_ROLE: Dictionary = {
	"advance": ThreatDefs.ROLE_LINE,
	"breaker": ThreatDefs.ROLE_BREAKER,
	"burrow": ThreatDefs.ROLE_BREAKER,
	"siphon": ThreatDefs.ROLE_STALKER,
	"fly": ThreatDefs.ROLE_STALKER,
	"siege": ThreatDefs.ROLE_SIEGE,
	"boss": ThreatDefs.ROLE_SIEGE,
	"suicide": ThreatDefs.ROLE_SWARM,
	"support": ThreatDefs.ROLE_LINE,
}


## Builds a unit from any resource sitting in game/content/enemies/. Returns
## null when the resource has no id, which is the only thing that is not
## derivable. `profile` supplies the default shares.
static func from_resource(res: Resource, profile: ThreatProfile) -> ThreatUnit:
	if res == null:
		return null
	var u := ThreatUnit.new()
	u.id = StringName(String(_read(res, ["id"], "")))
	if u.id == &"":
		# Registry indexes a resource without an id by its filename. Doing the
		# same here means a creature can never be registered-but-unfieldable.
		u.id = StringName(res.resource_path.get_file().get_basename())
	if u.id == &"":
		return null
	u.display_name = String(_read(res, ["display_name", "name"], String(u.id)))
	u.plural_name = String(_read(res, ["plural_name"], ""))
	u.description = String(_read(res, ["description"], ""))
	for t: Variant in _read(res, ["tags"], []):
		u.tags.append(StringName(String(t)))

	u.hp = maxf(1.0, float(_read(res, ["health", "hp"], 40.0)))
	u.armor = maxf(0.0, float(_read(res, ["armour", "armor"], 0.0)))
	u.speed = maxf(0.05, float(_read(res, ["speed"], 1.5)))
	u.damage = maxf(0.0, float(_read(res, ["damage"], 10.0)))
	u.attack_interval = maxf(0.05, float(_read(res, ["attack_interval"], 1.0)))
	u.attack_range = maxf(0.1, float(_read(res, ["attack_range"], 1.0)))
	u.heat_seeking = clampf(float(_read(res, ["heat_seeking"], 0.5)), 0.0, 1.0)

	var behaviour: String = String(_read(res, ["behaviour", "behavior"], ""))
	u.flying = bool(_read(res, ["flying"], false)) or behaviour == "fly" or u.tags.has(&"flying")

	u.pack_size = maxi(1, int(_read(res, ["pack_size"], 1)))
	u.min_wave = maxi(1, int(_read(res, ["min_day", "min_wave"], 1)))
	u.weight = maxf(0.0, float(_read(res, ["wave_weight", "weight"], 1.0)))
	# Without an authored cost, price it off what it actually is: durability plus
	# what it does per second. Never zero, so a def can always be composed.
	var derived: float = maxf(0.5, u.hp * 0.006 + (u.damage / u.attack_interval) * 0.10)
	u.cost = maxf(0.01, float(_read(res, ["threat_value", "cost"], derived)))

	u.role = _role_of(res, behaviour, u.tags)
	u.tier = int(_read(res, ["tier"], 0))
	if u.tier <= 0:
		u.tier = _tier_of(u.min_wave, u.tags)
	u.max_share = float(_read(res, ["max_share"], 0.0))
	if u.max_share <= 0.0:
		u.max_share = profile.share_for_role(u.role, u.tags.has(&"boss"))
	u.max_share = clampf(u.max_share, 0.05, 1.0)
	return u


## What the player is told there were several of.
func plural() -> String:
	if plural_name != "":
		return plural_name
	if display_name == "":
		return String(id)
	if display_name.begins_with("The ") or display_name.ends_with("s"):
		return display_name
	return display_name.to_lower() + "s"


## Damage per second against structures, at full strength.
func dps() -> float:
	return damage / maxf(0.05, attack_interval)


## One scalar for reporting how heavy a unit is. Never used for composition —
## that is `cost`, which the content author owns.
func threat_rating() -> float:
	return hp * (1.0 + armor * 0.08) * 0.02 + dps() * 0.6 + speed * 2.0


## Problems that make this unit uncomposable. Empty means it is fine.
func validate() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if id == &"":
		out.append("id is empty")
	if cost <= 0.0:
		out.append("cost/threat_value must be > 0")
	if pack_size < 1:
		out.append("pack_size must be >= 1")
	if not ThreatDefs.is_role(role):
		out.append("role '%s' is not one of %s" % [role, ThreatDefs.ROLES])
	return out


func to_dict() -> Dictionary:
	return {
		"id": String(id),
		"name": display_name,
		"plural": plural(),
		"role": String(role),
		"tier": tier,
		"cost": snappedf(cost, 0.01),
		"min_wave": min_wave,
		"pack_size": pack_size,
		"weight": snappedf(weight, 0.01),
		"max_share": snappedf(max_share, 0.01),
		"hp": snappedf(hp, 0.1),
		"armor": snappedf(armor, 0.1),
		"speed": snappedf(speed, 0.01),
		"dps": snappedf(dps(), 0.01),
		"flying": flying,
	}


# ---------------------------------------------------------------- internals

## A stated role wins; then the "swarm" tag, because a swarm creature is a swarm
## creature whatever it does when it arrives; then the behaviour table.
static func _role_of(res: Resource, behaviour: String, tags: Array[StringName]) -> StringName:
	var stated: String = String(_read(res, ["role"], ""))
	if ThreatDefs.is_role(StringName(stated)):
		return StringName(stated)
	if tags.has(&"swarm"):
		return ThreatDefs.ROLE_SWARM
	if tags.has(&"boss"):
		return ThreatDefs.ROLE_SIEGE
	if BEHAVIOUR_ROLE.has(behaviour):
		return BEHAVIOUR_ROLE[behaviour]
	return ThreatDefs.ROLE_LINE


static func _tier_of(min_wave: int, tags: Array[StringName]) -> int:
	if tags.has(&"boss"):
		return 4
	if min_wave >= 9:
		return 4
	if min_wave >= 4:
		return 3
	if min_wave >= 2:
		return 2
	return 1


## Reads the first property a resource actually exposes. `in` rather than a
## cast, so this never needs to know the class it is reading.
static func _read(res: Resource, names: Array, fallback: Variant) -> Variant:
	for n: String in names:
		if n in res:
			var v: Variant = res.get(n)
			if v != null:
				return v
	return fallback
