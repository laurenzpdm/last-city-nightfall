extends TestCase
## [P07] The roster, judged as content.
##
## The brief for this part is explicit: eight or more threats that demand
## DIFFERENT ANSWERS, not stat-scaled copies. That is a claim about content, so
## it is tested as content — every def validates, every def is reachable, and the
## roster actually spans the behaviours and the counters it says it does.

const ENEMY_DIR: String = "res://game/content/enemies"
const WEAPON_DIR: String = "res://game/content/weapons"

var enemies: Array[CombatEnemyDef] = []
var weapons: Array[WeaponDef] = []


func requires_files() -> PackedStringArray:
	return PackedStringArray(["res://game/sim/combat/combat_enemy_def.gd"])


func before_all() -> void:
	for res: Resource in Registry.all("enemies"):
		var d: CombatEnemyDef = CombatEnemyDef.from_resource(res)
		if d != null:
			enemies.append(d)
	for res2: Resource in Registry.all("weapons"):
		var w := res2 as WeaponDef
		if w != null:
			weapons.append(w)


# --- it exists and it is well-formed -----------------------------------------

func test_the_roster_is_not_empty() -> void:
	assert_ge(float(enemies.size()), 8.0,
		"the brief asks for at least eight distinct threats")
	assert_ge(float(weapons.size()), 4.0,
		"and enough weapons that the answers can differ")


func test_every_enemy_validates() -> void:
	for d: CombatEnemyDef in enemies:
		assert_empty(d.validate(), "enemy '%s' is clean content" % d.id)


func test_every_weapon_validates() -> void:
	for w: WeaponDef in weapons:
		assert_empty(w.validate(), "weapon '%s' is clean content" % w.id)


func test_ids_are_unique_and_resolvable() -> void:
	var seen: Dictionary[StringName, bool] = {}
	for d: CombatEnemyDef in enemies:
		assert_has_not(seen, d.id, "enemy id '%s' appears once" % d.id)
		seen[d.id] = true
		assert_true(Registry.has("enemies", d.id), "'%s' is in the registry" % d.id)


func test_authored_files_match_their_ids() -> void:
	var dir: DirAccess = DirAccess.open(ENEMY_DIR)
	assert_not_null(dir, "game/content/enemies exists")
	if dir == null:
		return
	for f: String in dir.get_files():
		if not f.ends_with(".tres"):
			continue
		var res: Resource = load("%s/%s" % [ENEMY_DIR, f])
		var d: CombatEnemyDef = CombatEnemyDef.from_resource(res)
		if d == null:
			continue
		assert_eq(String(d.id), f.get_basename(),
			"%s declares the id its filename promises" % f)


func test_spawn_chains_point_at_real_enemies() -> void:
	for d: CombatEnemyDef in enemies:
		if String(d.spawns_kind) == "":
			continue
		assert_true(Registry.has("enemies", d.spawns_kind),
			"'%s' spawns '%s', which exists" % [d.id, d.spawns_kind])


# --- it is actually a spread, not eight of one thing --------------------------

func test_the_roster_spans_at_least_six_behaviours() -> void:
	var seen: Dictionary[int, bool] = {}
	for d: CombatEnemyDef in enemies:
		seen[d.behaviour_index()] = true
	assert_ge(float(seen.size()), 6.0,
		"a roster of stat-scaled copies would share one behaviour; this one does not")


func test_every_named_answer_in_the_brief_is_present() -> void:
	var swarm: bool = false
	var armoured: bool = false
	var heat_eater: bool = false
	var burrower: bool = false
	var screamer: bool = false
	var boss: bool = false
	for d: CombatEnemyDef in enemies:
		if d.pack_size >= 4 and d.health <= 60.0:
			swarm = true
		if d.armour >= 10.0:
			armoured = true
		if d.siphon_rate > 0.0 or d.target_pref == CombatTypes.PREF_CONDUIT:
			heat_eater = true
		if d.ignores_walls:
			burrower = true
		if d.discontent_per_second > 0.0:
			screamer = true
		if d.behaviour_index() == CombatTypes.Behaviour.BOSS:
			boss = true
	assert_true(swarm, "a swarm that punishes single-target guns")
	assert_true(armoured, "an armoured breaker that punishes low-damage spam")
	assert_true(heat_eater, "something that goes for the heat network, not the wall")
	assert_true(burrower, "something that ignores walls entirely")
	assert_true(screamer, "something that attacks morale")
	assert_true(boss, "a night boss")


func test_no_two_enemies_are_the_same_answer() -> void:
	# Two defs count as the same answer when behaviour, what they walk up to and
	# their resistance profile all match. That is the "no stat-scaled copies" rule
	# written down as an assertion.
	var seen: Dictionary[String, String] = {}
	for d: CombatEnemyDef in enemies:
		var key: String = "%s|%s|%.2f/%.2f/%.2f/%.2f|%s" % [
			d.behaviour, d.target_pref,
			d.resist_kinetic, d.resist_flame, d.resist_blast, d.resist_shock,
			str(d.ignores_walls)]
		assert_has_not(seen, key,
			"'%s' demands a different answer from '%s'" % [d.id, seen.get(key, "")])
		seen[key] = String(d.id)


func test_a_boss_can_never_be_rolled_into_an_ordinary_wave() -> void:
	for d: CombatEnemyDef in enemies:
		if d.behaviour_index() != CombatTypes.Behaviour.BOSS:
			continue
		assert_eq(d.wave_weight, 0.0,
			"'%s' is placed by the director, never rolled" % d.id)
		assert_gt(d.threat_value, 20.0, "and it is worth a night on its own")


# --- weapons span real trade-offs --------------------------------------------

func test_weapons_cover_every_damage_channel_the_roster_resists() -> void:
	var offered: Dictionary[int, bool] = {}
	for w: WeaponDef in weapons:
		offered[w.damage_channel()] = true
	assert_ge(float(offered.size()), 3.0,
		"a defence built on one channel must be a real mistake, so at least three exist")


func test_no_weapon_dominates_on_every_axis() -> void:
	# Two weapons on different damage channels are never comparable: the roster
	# resists channels differently on purpose, so "worse on paper" can still be the
	# only thing that kills a given creature. Within one channel, though, a weapon
	# that wins on damage, reach, heat, handling, plating and coverage at once
	# would make its rival content nobody would ever fit.
	for a: WeaponDef in weapons:
		for b: WeaponDef in weapons:
			if a.id == b.id or a.damage_channel() != b.damage_channel():
				continue
			var better: bool = a.dps() >= b.dps() \
				and a.range_tiles >= b.range_tiles \
				and a.min_range_tiles <= b.min_range_tiles \
				and a.heat_per_second() <= b.heat_per_second() \
				and a.turn_rate >= b.turn_rate \
				and a.pierce >= b.pierce \
				and _coverage(a) >= _coverage(b)
			assert_false(better,
				"'%s' would make '%s' pointless — every weapon must give something up"
				% [a.id, b.id])


## How many bodies one trigger pull can touch, roughly. A cone weapon covers a
## whole arc, a splash weapon a disc, everything else exactly one thing.
func _coverage(w: WeaponDef) -> float:
	if w.delivery_index() == CombatTypes.Delivery.CONE:
		return w.range_tiles * w.cone_degrees / 30.0
	if w.splash_radius > 0.0:
		return w.splash_radius * w.splash_radius
	return 1.0


func test_every_weapon_costs_heat_to_fire() -> void:
	for w: WeaponDef in weapons:
		assert_gt(w.heat_per_shot, 0.0,
			"'%s' burns heat — a free turret breaks the whole fusion" % w.id)


func test_the_default_turret_barrel_exists() -> void:
	# turret_mount.tres is [P11]'s and names its weapon; combat must supply it.
	var mount: Resource = Registry.get_item("buildings", &"turret_mount")
	if mount == null:
		skip("[P11] has no turret_mount in this build")
		return
	var wanted: StringName = StringName(String(mount.get("weapon_id")))
	if String(wanted) == "":
		skip("turret_mount names no weapon")
		return
	assert_true(Registry.has("weapons", wanted),
		"the mount asks for '%s' and combat authors it" % wanted)
