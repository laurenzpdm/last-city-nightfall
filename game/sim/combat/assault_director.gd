class_name AssaultDirector
extends RefCounted
## The stand-in wave director, and only a stand-in.
##
## [P08] owns the real pressure curve. Until it lands, combat would otherwise be
## a system that never runs: the reference scenario would show an empty plain at
## midnight and every screenshot of "the assault" would be a screenshot of snow.
## So this exists, it is small, it says what it is in the log, and it steps aside
## the moment `Sim.get_system(&"threat")` answers — combat asks once, at
## post_setup, and never fights the real director for control.
##
## Two rules keep it from wrecking anybody else's numbers:
##   * it only opens a front once the city has actually built a perimeter (a
##     turret or a wall), because a scenario with no defences is an economy
##     scenario and eating its city would make it useless; and
##   * it spends a **threat budget** rather than a body count, so the roster's
##     `threat_value` is the one knob that balances a night.

## Threat budget of the first night, and what each further day adds.
const BASE_BUDGET: float = 26.0
const BUDGET_PER_DAY: float = 20.0
const BUDGET_GROWTH: float = 1.14
## Bosses come on these days.
const BOSS_EVERY_DAYS: int = 4
## Seconds a wave takes to arrive, so it is a tide and not a teleport.
const RELEASE_SECONDS: float = 45.0
## Hard ceiling on bodies alive at once, whatever the budget says.
const MAX_ALIVE: int = 900
## Seconds of warning before the wave actually starts walking.
const WARNING_SECONDS: float = 12.0

var enabled: bool = false
var wave: int = 0
var active: bool = false

var _budget_left: float = 0.0
var _queue: Array[Dictionary] = []      ## {slot, count, at_tick, lane}
var _queue_head: int = 0
var _was_night: bool = false
var _warned_tick: int = -1
var _wave_started_tick: int = -1
var _last_wave_day: int = -1
var _spawned_this_wave: int = 0
var _threat_this_wave: float = 0.0


## Plans and releases waves. Returns spawn orders for this tick; [CombatSystem]
## performs them, because it owns id minting and the swarm.
func step(tick: int, day: int, is_night: bool, defended: bool,
		swarm: EnemySwarm, alive: int) -> Array[Dictionary]:
	if not enabled:
		return []
	var orders: Array[Dictionary] = []
	var night_began: bool = is_night and not _was_night
	_was_night = is_night

	if night_began and defended and day != _last_wave_day:
		_plan(tick, day, swarm)
		_last_wave_day = day

	if _queue_head < _queue.size():
		while _queue_head < _queue.size() and int(_queue[_queue_head]["at_tick"]) <= tick:
			var order: Dictionary = _queue[_queue_head]
			_queue_head += 1
			if alive + orders.size() >= MAX_ALIVE:
				continue
			orders.append(order)
			_spawned_this_wave += int(order["count"])
		if not active and not orders.is_empty():
			active = true
			_wave_started_tick = tick
			Bus.wave_started.emit(wave, _threat_this_wave)
			Log.info("combat", "wave %d walking: %d bodies, %.0f threat" % [
				wave, _spawned_this_wave, _threat_this_wave])
	elif active and alive == 0:
		active = false
		Bus.wave_cleared.emit(wave)
		Log.info("combat", "wave %d cleared after %.0f s" % [
			wave, float(tick - _wave_started_tick) * SimClock.DT])
	return orders


func idle() -> bool:
	return not active and _queue_head >= _queue.size()


## Seconds until the next planned release, or -1 when nothing is queued.
func seconds_until_release(tick: int) -> float:
	if _queue_head >= _queue.size():
		return -1.0
	return maxf(0.0, float(int(_queue[_queue_head]["at_tick"]) - tick) * SimClock.DT)


func serialize() -> Dictionary:
	var q: Array = []
	for i: int in range(_queue_head, _queue.size()):
		var o: Dictionary = _queue[i]
		q.append({"slot": int(o["slot"]), "count": int(o["count"]),
			"at_tick": int(o["at_tick"]), "lane": int(o["lane"])})
	return {
		"enabled": enabled, "wave": wave, "active": active,
		"budget_left": snappedf(_budget_left, 0.01),
		"was_night": _was_night, "last_wave_day": _last_wave_day,
		"spawned": _spawned_this_wave, "threat": snappedf(_threat_this_wave, 0.01),
		"started_tick": _wave_started_tick, "warned_tick": _warned_tick,
		"queue": q,
	}


func deserialize(data: Dictionary, swarm: EnemySwarm) -> void:
	enabled = bool(data.get("enabled", false))
	wave = int(data.get("wave", 0))
	active = bool(data.get("active", false))
	_budget_left = float(data.get("budget_left", 0.0))
	_was_night = bool(data.get("was_night", false))
	_last_wave_day = int(data.get("last_wave_day", -1))
	_spawned_this_wave = int(data.get("spawned", 0))
	_threat_this_wave = float(data.get("threat", 0.0))
	_wave_started_tick = int(data.get("started_tick", -1))
	_warned_tick = int(data.get("warned_tick", -1))
	_queue.clear()
	_queue_head = 0
	for entry: Variant in data.get("queue", []):
		var d: Dictionary = entry
		var slot: int = int(d.get("slot", -1))
		if slot < 0 or slot >= swarm.def_count:
			continue
		_queue.append({"slot": slot, "count": int(d.get("count", 1)),
			"at_tick": int(d.get("at_tick", 0)), "lane": int(d.get("lane", 0))})


# ---------------------------------------------------------------- internals --

func _plan(tick: int, day: int, swarm: EnemySwarm) -> void:
	var pool: Array[Dictionary] = swarm.rollable(day)
	if pool.is_empty():
		return
	wave += 1
	_queue.clear()
	_queue_head = 0
	_spawned_this_wave = 0
	_threat_this_wave = 0.0
	_budget_left = (BASE_BUDGET + BUDGET_PER_DAY * float(day - 1)) * pow(BUDGET_GROWTH, float(day - 1))

	var rng: RandomNumberGenerator = Rng.stream("combat_waves")
	var total_weight: float = 0.0
	for p: Dictionary in pool:
		total_weight += float(p["weight"])
	var warn_ticks: int = int(WARNING_SECONDS / SimClock.DT)
	var release_ticks: int = int(RELEASE_SECONDS / SimClock.DT)
	var guard: int = 0
	while _budget_left > 0.0 and guard < 400:
		guard += 1
		var roll: float = rng.randf() * total_weight
		var picked: Dictionary = pool[pool.size() - 1]
		for p2: Dictionary in pool:
			roll -= float(p2["weight"])
			if roll <= 0.0:
				picked = p2
				break
		var pack: int = int(picked["pack"])
		var cost: float = float(picked["threat"]) * float(pack)
		if cost > _budget_left and _threat_this_wave > 0.0:
			break
		_budget_left -= cost
		_threat_this_wave += cost
		var at: int = tick + warn_ticks + int(rng.randf() * float(release_ticks))
		_queue.append({"slot": int(picked["slot"]), "count": pack,
			"at_tick": at, "lane": int(rng.randi() & 0x3FFF)})

	# A boss is placed, never rolled: it arrives late in the night, alone, and
	# only on the nights the campaign says it should.
	if day % BOSS_EVERY_DAYS == 0:
		var boss: int = _boss_slot(swarm, day)
		if boss >= 0:
			_queue.append({"slot": boss, "count": 1,
				"at_tick": tick + warn_ticks + release_ticks / 2, "lane": int(rng.randi() & 0x3FFF)})
			_threat_this_wave += swarm.threat_of_slot(boss)

	_queue.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["at_tick"]) != int(b["at_tick"]):
			return int(a["at_tick"]) < int(b["at_tick"])
		return int(a["slot"]) < int(b["slot"]))
	_warned_tick = tick
	Bus.wave_incoming.emit(wave, WARNING_SECONDS)
	Bus.alert_raised.emit(1, &"wave_incoming",
		"Something is moving on the ice. Wave %d, %.0f threat." % [wave, _threat_this_wave],
		Vector2.ZERO)


## Heaviest thing in the roster that this day allows and that is not part of the
## random pool. Bosses are authored with wave_weight 0 exactly so they only ever
## appear here.
func _boss_slot(swarm: EnemySwarm, day: int) -> int:
	var best: int = -1
	var best_threat: float = 0.0
	for i: int in range(swarm.def_count):
		if swarm.d_weight[i] > 0.0 or swarm.d_min_day[i] > day:
			continue
		if swarm.d_behaviour[i] != CombatTypes.Behaviour.BOSS:
			continue
		if best < 0 or swarm.d_threat[i] > best_threat:
			best = i
			best_threat = swarm.d_threat[i]
	return best
