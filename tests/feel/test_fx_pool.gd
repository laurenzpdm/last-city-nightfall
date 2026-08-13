extends TestCase
## LcnFxPool — fixed-size, allocation-free effect storage. [P15]
##
## The contract this suite defends is the frame budget: the pool NEVER grows, so
## a thousand simultaneous deaths cost exactly what ten do, and no effect can
## outlive the cap and turn up as a mystery millisecond an hour later.


func test_the_pool_never_grows() -> void:
	var pool := LcnFxPool.new(16)
	assert_eq(pool.capacity, 16)
	for i: int in 200:
		pool.spawn(LcnFxPool.Kind.DUST, Vector2(float(i), 0.0), Vector2.ZERO, 1.0, 4.0, Color.WHITE)
	assert_eq(pool.capacity, 16, "two hundred spawns into a sixteen-row pool is still sixteen rows")
	assert_le(pool.count(), 16, "and at most sixteen are alive")
	assert_eq(pool.spawned, 200, "every spawn was accounted for")
	assert_gt(pool.dropped, 0, "and the overflow was recorded, not hidden")


func test_a_full_pool_overwrites_its_oldest_row() -> void:
	var pool := LcnFxPool.new(4)
	for i: int in 4:
		pool.spawn(LcnFxPool.Kind.DUST, Vector2(float(i), 0.0), Vector2.ZERO, 9.0, 1.0, Color.WHITE)
	assert_eq(pool.count(), 4, "full")
	pool.spawn(LcnFxPool.Kind.RING, Vector2(99.0, 0.0), Vector2.ZERO, 9.0, 1.0, Color.WHITE)
	assert_eq(pool.count(), 4, "still full — the newcomer took a seat, it did not add one")
	var found: bool = false
	for i: int in pool.capacity:
		if pool.alive_at(i) and pool.kind_at(i) == int(LcnFxPool.Kind.RING):
			found = true
	assert_true(found, "and the newest effect is the one that survived")


func test_life_is_clamped_to_the_vocabulary() -> void:
	var pool := LcnFxPool.new(4)
	var i: int = pool.spawn(LcnFxPool.Kind.EMBER, Vector2.ZERO, Vector2.ZERO,
		9999.0, 1.0, Color.WHITE)
	assert_le(pool.field(i, LcnFxPool.F_LIFE), LcnTiming.MAX_EFFECT_LIFE,
		"nobody gets to leak a ten-second particle")
	var j: int = pool.spawn(LcnFxPool.Kind.EMBER, Vector2.ZERO, Vector2.ZERO,
		-5.0, 1.0, Color.WHITE)
	assert_gt(pool.field(j, LcnFxPool.F_LIFE), 0.0, "and a zero life is not a divide by zero")


func test_prune_retires_exactly_what_expired() -> void:
	var pool := LcnFxPool.new(8)
	var born: float = LcnTiming.world_now()
	pool.spawn(LcnFxPool.Kind.DUST, Vector2.ZERO, Vector2.ZERO, 0.2, 1.0, Color.WHITE)
	pool.spawn(LcnFxPool.Kind.DUST, Vector2.ZERO, Vector2.ZERO, 2.0, 1.0, Color.WHITE)
	assert_eq(pool.count(), 2)
	pool.prune(born + 0.1)
	assert_eq(pool.count(), 2, "nothing has expired yet")
	pool.prune(born + 0.5)
	assert_eq(pool.count(), 1, "the short one is gone")
	pool.prune(born + 3.0)
	assert_eq(pool.count(), 0, "and then the long one")


func test_age_runs_from_zero_to_one_and_clamps() -> void:
	var pool := LcnFxPool.new(4)
	var born: float = LcnTiming.world_now()
	var i: int = pool.spawn(LcnFxPool.Kind.RING, Vector2.ZERO, Vector2.ZERO, 1.0, 1.0, Color.WHITE)
	assert_near(pool.age01(i, born), 0.0, 1.0e-4)
	assert_near(pool.age01(i, born + 0.5), 0.5, 0.01)
	assert_near(pool.age01(i, born + 1.0), 1.0, 1.0e-4)
	assert_near(pool.age01(i, born + 50.0), 1.0, 1.0e-4, "a stalled frame cannot overshoot")


func test_every_field_survives_the_round_trip() -> void:
	var pool := LcnFxPool.new(4)
	var col := Color(0.2, 0.4, 0.6, 0.8)
	var i: int = pool.spawn(LcnFxPool.Kind.SHARD, Vector2(12.0, -30.0), Vector2(3.0, 4.0),
		0.7, 5.5, col, 0.25, 0.75, 17.0)
	assert_eq(pool.kind_at(i), int(LcnFxPool.Kind.SHARD))
	assert_eq(pool.position_at(i), Vector2(12.0, -30.0))
	assert_eq(pool.velocity_at(i), Vector2(3.0, 4.0))
	assert_near(pool.field(i, LcnFxPool.F_SIZE), 5.5, 1.0e-4)
	assert_near(pool.field(i, LcnFxPool.F_P0), 0.25, 1.0e-4)
	assert_near(pool.field(i, LcnFxPool.F_P1), 0.75, 1.0e-4)
	var back: Color = pool.color_at(i)
	assert_near(back.r, col.r, 1.0e-3)
	assert_near(back.a, col.a, 1.0e-3)


## Two hundred puffs must not look like one puff drawn two hundred times, and
## the variation may not come from a random number generator — this is view code
## but it runs during a replayable run and a critic diffs the screenshots.
func test_wobble_varies_by_seed_and_never_uses_randomness() -> void:
	var pool := LcnFxPool.new(8)
	var a: int = pool.spawn(LcnFxPool.Kind.EMBER, Vector2.ZERO, Vector2.ZERO, 1.0, 1.0,
		Color.WHITE, 0.0, 0.0, 3.0)
	var b: int = pool.spawn(LcnFxPool.Kind.EMBER, Vector2.ZERO, Vector2.ZERO, 1.0, 1.0,
		Color.WHITE, 0.0, 0.0, 91.0)
	assert_ne(snappedf(pool.wobble(a, 1), 0.0001), snappedf(pool.wobble(b, 1), 0.0001),
		"different seeds wobble differently")
	assert_eq(pool.wobble(a, 1), pool.wobble(a, 1), "and the same row always wobbles the same")
	assert_between(pool.wobble(a, 2), -1.0, 1.0, "in range")
	assert_between(pool.wobble(b, 7), -1.0, 1.0, "in range")


func test_clear_empties_without_reallocating() -> void:
	var pool := LcnFxPool.new(8)
	for _i: int in 8:
		pool.spawn(LcnFxPool.Kind.DUST, Vector2.ZERO, Vector2.ZERO, 1.0, 1.0, Color.WHITE)
	pool.clear()
	assert_eq(pool.count(), 0)
	assert_eq(pool.capacity, 8)
	for i: int in 8:
		assert_false(pool.alive_at(i), "row %d is free again" % i)


func test_a_tiny_pool_is_still_a_pool() -> void:
	# The floor exists so a caller cannot ask for a two-row pool and get a
	# division by zero in _claim().
	var pool := LcnFxPool.new(1)
	assert_ge(pool.capacity, 8)
	pool.spawn(LcnFxPool.Kind.DUST, Vector2.ZERO, Vector2.ZERO, 1.0, 1.0, Color.WHITE)
	assert_eq(pool.count(), 1)
