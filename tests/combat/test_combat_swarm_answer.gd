extends TestCase
## [P07] THE SWARM MUST SURVIVE ITS FIRST ROUND.
##
## `game/content/enemies/drift_hound.tres` says, in its own description, that it
## "exists to punish a wall defended by one big gun" and that "single-target
## damage is the wrong answer". The shipped numbers said the opposite, and the
## reference run measured it exactly:
##
##   artifacts/J3_pre/metrics.csv, first_night 24000 ticks, night two —
##   ticks 14040..14160 turned 9 shots into 10 kills, and 15220..15340 did the
##   same again. TWENTY bodies for eighteen rounds, across the two windows; the
##   20-tick sample grid cannot resolve them finer than that, and it does not
##   need to. The general-purpose barrel put a drift hound down with one round
##   because 26 base damage times the 1.18 ballistics rung is 30.68 against 30
##   points of health, and 30.68 > 30. Ballistics is not the ceiling: with
##   incendiary_rounds (0.10) and armour_piercing (0.05) as well the tree reaches
##   1.33x, or 34.58 — which is why `max_damage_mult` below is READ OFF THE
##   REGISTRY rather than written down here, and why 42 health clears the real
##   ceiling and not just the one rung this paragraph names.
##   (Independently: `final.systems.combat.turrets[0]` in
##   artifacts/J3_pre/state.json carries damage 92.04 over shots 3 — 30.68
##   each.)
##
##   Cited against J3_pre, not J3_base: the two hold byte-identical metrics.csv,
##   but J3_base was probed after the content changed and had its gate.json
##   removed for it, so J3_pre is the baseline with nothing taken out of it.
##
## Whichever way a later hand moves the numbers, this is the RULE the content
## was written to express, so it is asserted as a rule rather than as a constant:
## the barrel a first wall actually has must not delete the basic swarm unit in
## one round at ANY damage multiplier research can reach.
##
## It is deliberately one-sided. It does not say a hound must survive three
## rounds — a swarm that soaks is not a swarm — only that it must survive one.

const ENEMY_DIR: String = "res://game/content/enemies"

## The barrel a wall gets by default, and it hits one thing at a time. A cone, a
## scatter or the anti-armour lance is ALLOWED to one-shot a hound — a scatter
## doing it is the answer the content is trying to teach, and the lance doing it
## costs nine units of heat a shot and a 1.6 s reload to kill one body of six.
const GENERAL_BARRELS: Array[StringName] = [&"burner_cannon"]

var enemies: Array[CombatEnemyDef] = []
var weapons: Dictionary[StringName, WeaponDef] = {}
## 1.0 plus every combat.turret_damage_mult a player can research.
var max_damage_mult: float = 1.0


func requires_files() -> PackedStringArray:
	return PackedStringArray([
		"res://game/sim/combat/combat_enemy_def.gd",
		"res://game/sim/combat/weapon_def.gd",
	])


func before_all() -> void:
	for res: Resource in Registry.all("enemies"):
		var d: CombatEnemyDef = CombatEnemyDef.from_resource(res)
		if d != null:
			enemies.append(d)
	for res2: Resource in Registry.all("weapons"):
		var w := res2 as WeaponDef
		if w != null:
			weapons[w.id] = w
	for res3: Resource in Registry.all("research"):
		if not ("effects" in res3):
			continue
		var fx: Dictionary = res3.get("effects")
		max_damage_mult += maxf(0.0, float(fx.get(ResearchDefs.E_TURRET_DAMAGE_MULT, 0.0)))


## One round of `w` into `d`, through resistance and plate, at the best damage
## multiplier the tech tree offers.
func _one_round(w: WeaponDef, d: CombatEnemyDef) -> float:
	return CombatTypes.resolve_damage(
		w.damage * max_damage_mult, d.resist_of(w.damage_channel()), d.armour, w.pierce)


func test_the_research_tree_still_has_a_damage_rung() -> void:
	# If this ever reads 1.0 the test below has stopped meaning anything, and it
	# should say so out loud rather than pass by accident.
	assert_gt(max_damage_mult, 1.0,
		"no combat.turret_damage_mult in game/content/research — the ceiling this test "
		+ "checks against would be the base statline")


func test_a_general_barrel_never_one_shots_a_swarm_unit() -> void:
	var checked: int = 0
	for d: CombatEnemyDef in enemies:
		if not d.has_tag(&"swarm"):
			continue
		for id: StringName in GENERAL_BARRELS:
			var w: WeaponDef = weapons.get(id)
			if w == null:
				continue
			checked += 1
			var round_damage: float = _one_round(w, d)
			assert_lt(round_damage, d.health,
				("'%s' puts '%s' down in ONE round (%.2f damage vs %.1f health at the "
				+ "%.2fx damage rung). A swarm the wall deletes one body per round is "
				+ "not a swarm — it is a queue, and the night it makes is a queue too.")
					% [w.id, d.id, round_damage, d.health, max_damage_mult])
	assert_gt(float(checked), 0.0, "no swarm-tagged enemy met a general barrel")


func test_two_rounds_are_still_enough() -> void:
	# The other side of the same rule. A hound is not a wall: whatever a later
	# hand does to its health, the default barrel must still finish it inside a
	# single reload cycle's worth of rounds, at the BASE statline with no
	# research at all. Otherwise the opening night is unwinnable by design.
	var w: WeaponDef = weapons.get(&"burner_cannon")
	assert_not_null(w, "the default barrel exists")
	for d: CombatEnemyDef in enemies:
		# Only the swarm the OPENING night is made of. A day-four swarm is
		# allowed to need a better answer than the barrel that shipped with the
		# mount; that is what the research tree is for.
		if not d.has_tag(&"swarm") or d.min_day > 1:
			continue
		var base_round: float = CombatTypes.resolve_damage(
			w.damage, d.resist_of(w.damage_channel()), d.armour, w.pierce)
		assert_ge(base_round * 2.0, d.health,
			("'%s' needs more than two un-researched burner rounds (%.2f x2 vs %.1f). "
			+ "That is a brawler wearing a swarm's tag.") % [d.id, base_round, d.health])


func test_the_swarms_price_tracks_what_it_costs_to_kill() -> void:
	# `threat_value` is what one body costs a night's budget. When a body's
	# durability moves and its price does not, the wave director silently buys a
	# heavier night than the curve authored. Held loosely — this is a sanity
	# rail against a free 40% of pressure, not a balance formula.
	for d: CombatEnemyDef in enemies:
		if not d.has_tag(&"swarm"):
			continue
		var per_hp: float = d.threat_value / maxf(1.0, d.health)
		assert_between(per_hp, 0.015, 0.075,
			("'%s' is priced at %.3f budget per point of health. A swarm unit that is "
			+ "cheap relative to what it soaks makes every night heavier than the curve "
			+ "says, and one that is dear makes the night empty.") % [d.id, per_hp])
