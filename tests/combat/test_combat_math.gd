extends TestCase
## [P07] The arithmetic every fight is decided by, tested without a world.
##
## Damage, armour and resistance are pure functions on purpose: the balance of
## the whole tower-defence third rests on them, and a pure function can be pinned
## down by a table instead of by a playthrough.

func requires_files() -> PackedStringArray:
	return PackedStringArray(["res://game/sim/combat/combat_types.gd"])


# --- armour ------------------------------------------------------------------

func test_armour_is_flat_reduction() -> void:
	assert_near(CombatTypes.resolve_damage(30.0, 1.0, 10.0, 0.0), 20.0, 0.001,
		"30 damage into 10 armour lands 20")
	assert_near(CombatTypes.resolve_damage(30.0, 1.0, 0.0, 0.0), 30.0, 0.001,
		"no armour, no reduction")


func test_armour_punishes_small_hits_far_harder_than_big_ones() -> void:
	# The design claim: twenty 5s and one 100 are the same raw damage and very
	# different answers to a breaker.
	var armour: float = 14.0
	var spam: float = CombatTypes.resolve_damage(5.0, 1.0, armour, 0.0) * 20.0
	var slug: float = CombatTypes.resolve_damage(100.0, 1.0, armour, 0.0)
	assert_lt(spam, slug * 0.2, "20x5 delivers less than a fifth of what 1x100 does")
	assert_gt(spam, 0.0, "but spam is never fully absorbed — the floor holds")


func test_the_minimum_fraction_floor() -> void:
	var d: float = CombatTypes.resolve_damage(10.0, 1.0, 400.0, 0.0)
	assert_near(d, 10.0 * CombatTypes.MIN_DAMAGE_FRACTION, 0.0001,
		"absurd armour still takes the floor, never zero")


func test_pierce_eats_armour_before_the_hit_does() -> void:
	assert_near(CombatTypes.resolve_damage(40.0, 1.0, 20.0, 24.0), 40.0, 0.001,
		"pierce above the plating removes it entirely")
	assert_near(CombatTypes.resolve_damage(40.0, 1.0, 20.0, 8.0), 28.0, 0.001,
		"partial pierce removes exactly its share")


func test_resistance_multiplies_before_armour() -> void:
	# Order matters: a resistance applied after armour would make plating and
	# resistance interchangeable, and they are not.
	assert_near(CombatTypes.resolve_damage(20.0, 2.0, 10.0, 0.0), 30.0, 0.001,
		"double weakness then armour")
	assert_near(CombatTypes.resolve_damage(20.0, 0.5, 10.0, 0.0), 1.0, 0.001,
		"half resistance then armour, floored at 10% of the typed hit")


func test_zero_and_negative_raw_damage_are_ignored() -> void:
	assert_near(CombatTypes.resolve_damage(0.0, 1.0, 0.0, 0.0), 0.0, 0.0001)
	assert_near(CombatTypes.resolve_damage(-5.0, 1.0, 0.0, 0.0), 0.0, 0.0001)


# --- helpers -----------------------------------------------------------------

func test_enum_lookup_round_trips() -> void:
	for i: int in range(CombatTypes.DAMAGE_NAMES.size()):
		assert_eq(CombatTypes.enum_of(CombatTypes.DAMAGE_NAMES,
			CombatTypes.DAMAGE_NAMES[i], -1), i, "damage channel %d round trips" % i)
	for j: int in range(CombatTypes.AIM_NAMES.size()):
		assert_eq(CombatTypes.enum_of(CombatTypes.AIM_NAMES,
			CombatTypes.AIM_NAMES[j], -1), j, "aim policy %d round trips" % j)
	assert_eq(CombatTypes.enum_of(CombatTypes.DAMAGE_NAMES, &"nonsense", 3), 3,
		"an unknown name takes the fallback")


func test_hash01_is_stable_and_in_range() -> void:
	var seen: Dictionary[float, bool] = {}
	for i: int in range(64):
		var v: float = CombatTypes.hash01(i, 17)
		assert_between(v, 0.0, 1.0, "hash01 stays in 0..1")
		assert_eq(v, CombatTypes.hash01(i, 17), "hash01 is a pure function")
		seen[v] = true
	assert_gt(float(seen.size()), 40.0, "and it actually spreads")
