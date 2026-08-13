class_name ApproachPlanner
extends RefCounted
## Decides where tonight's attack comes from, by reading the ground and then
## reading the player.
##
## The candidate vectors are not invented: they are [P01]'s approach lanes, old
## highways the map generator cut through the valleys, each with the narrowest
## crossing on it already measured. A defence line pays off exactly where the
## terrain says it should, because the director is looking at the same
## chokepoints the player can see.
##
## On top of that it measures, per lane, what the player has actually built —
## turrets weighted by whether the heat grid is currently powering them, walls
## by the hit points they add — and turns that into a 0..1 defence rating. Then:
##
##   * the MAIN vector is the fastest road to the core. It is where an honest,
##     legible attack comes from, and it is telegraphed first.
##   * the PROBE vector is the player's weakest side, and its share of the night
##     ramps in from night `probe_from_night`. Turtling one road is punished on
##     purpose — but the probe is telegraphed like everything else, and no
##     single vector may ever carry more than `vector_share_cap` of a night.
##
## Nothing in here is hidden from the player: every number it computes reaches
## next_wave_preview(), and the warning ladder names the directions out loud.
##
## Cost: the corridor map is built once per world (a few thousand dictionary
## writes); rescoring is one pass over the building list, which is why it can
## run every few seconds during a night without showing up in the tick budget.

const DEFENCE_REFRESH_TICKS: int = 100

var _profile: ThreatProfile = null
var _grid: SimSystem = null
var _build: SimSystem = null
var _heat: SimSystem = null

var _core: Vector2i = Vector2i.ZERO
var _width: int = 0
var _height: int = 0

## The vectors this world offers, independent of any one night.
var _candidates: Array[ThreatVector] = []
## Corridor cell -> BITMASK of the candidate indices that corridor belongs to.
## A mask rather than one owner because lanes converge near the city: a turret
## between two roads genuinely defends both, and giving it to whichever lane was
## painted first would read a fortified side as an open one.
var _zone: Dictionary[Vector2i, int] = {}
## Candidates whose index fits in the mask. Anything past this is not scored.
const MAX_MASKED_VECTORS: int = 30
## Cached per-kind classification, so rescoring never touches the Registry.
var _kind_cache: Dictionary[StringName, Dictionary] = {}
## Offsets of a disc of radius `lane_corridor_radius`, precomputed once.
var _disc: Array[Vector2i] = []

var _built: bool = false
## Microseconds the last rescore took, and the worst one so far. Profiling only:
## never serialized, never in a metric, only ever in a DEBUG log line.
var last_us: int = 0
var worst_us: int = 0
var scans: int = 0


func bind(profile: ThreatProfile, grid: SimSystem, build: SimSystem, heat: SimSystem) -> void:
	_profile = profile
	_grid = grid
	_build = build
	_heat = heat


func candidates() -> Array[ThreatVector]:
	return _candidates


func is_built() -> bool:
	return _built


## Derives every approach this world offers. Called once, after the grid exists.
func build_vectors() -> void:
	_candidates.clear()
	_zone.clear()
	_built = true
	_read_map()
	_build_disc()

	var lanes: Array = _lanes()
	var idx: int = 0
	for raw: Variant in lanes:
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var v: ThreatVector = _vector_from_lane(raw, idx)
		if v == null:
			continue
		_candidates.append(v)
		idx += 1

	if _candidates.is_empty():
		_synthesise()

	for v: ThreatVector in _candidates:
		_paint_zone(v)

	Log.info("threat", "%d approach vector(s): %s" % [_candidates.size(), _describe()])


## Re-measures what the player has built on every lane.
##
## THIS IS THE ONLY EXPENSIVE THING IN THIS PART, so it is written like it:
## one pass over the building list, one dictionary lookup per building to find
## which corridors it sits in, and per-zone accumulation into flat arrays
## indexed by lane rather than into a dictionary. `has_method` is probed once
## against the first entry instead of once per building — [P11] hands out a
## homogeneous array of BuildingInstance, and 1700 reflection calls a scan is
## the difference between 3 ms and 0.4 ms at stress scale.
func rescore() -> void:
	var t0: int = Time.get_ticks_usec()  # lint:allow profiling only; never serialized
	_rescore()
	last_us = Time.get_ticks_usec() - t0  # lint:allow profiling only
	worst_us = maxi(worst_us, last_us)
	scans += 1


func _rescore() -> void:
	var n: int = _candidates.size()
	for v: ThreatVector in _candidates:
		v.defence_dps = 0.0
		v.barrier_hp = 0.0
		v.turrets = 0
		v.walls = 0
		v.structures = PackedInt32Array()
	if _build == null or not _build.has_method("all_buildings") or _zone.is_empty():
		for v2: ThreatVector in _candidates:
			v2.defence = 0.0
		return

	var raw: Variant = _build.call("all_buildings")
	if typeof(raw) != TYPE_ARRAY:
		return
	var list: Array = raw
	if list.is_empty():
		return
	var probe: Object = list[0]
	if probe == null or not probe.has_method("is_complete"):
		return
	var has_health: bool = probe.has_method("health_ratio")
	var has_rect: bool = probe.has_method("rect")
	var has_power: bool = _heat != null and _heat.has_method("power_factor")

	var dps: PackedFloat32Array = PackedFloat32Array()
	var barrier: PackedFloat32Array = PackedFloat32Array()
	var turret_n: PackedInt32Array = PackedInt32Array()
	var wall_n: PackedInt32Array = PackedInt32Array()
	var ids_by_zone: Array[PackedInt32Array] = []
	dps.resize(n)
	barrier.resize(n)
	turret_n.resize(n)
	wall_n.resize(n)
	for _i: int in n:
		ids_by_zone.append(PackedInt32Array())

	for entry: Variant in list:
		var b: Object = entry
		if b == null or not bool(b.call("is_complete")):
			continue
		var mask: int = int(_zone.get(b.get("cell"), 0))
		if mask == 0 and has_rect:
			var r: Rect2i = b.call("rect")
			mask = int(_zone.get(r.position + r.size / 2, 0))
		if mask == 0:
			continue
		var info: Dictionary = _kind_info(StringName(String(b.get("kind"))))
		var health: float = clampf(float(b.call("health_ratio")), 0.0, 1.0) if has_health else 1.0
		var id: int = int(b.get("id"))
		var hp: float = float(b.get("hp"))
		var turret: bool = bool(info["turret"])
		var defense: bool = bool(info["defense"])
		# A cold turret is a decoration. This one line is the whole reason the
		# heat grid IS the defence grid.
		var add_dps: float = 0.0
		if turret:
			var power: float = 1.0
			if has_power:
				power = clampf(float(_heat.call("power_factor", id)), 0.0, 1.0)
			add_dps = _profile.turret_dps * health * (0.15 + 0.85 * power)
		elif defense:
			add_dps = _profile.support_dps * health
		# Anything that is not a gun is still a body in the way, and still
		# something they can stop to take apart.
		var add_hp: float = 0.0 if turret else (
			hp * _profile.wall_barrier_scale if defense else hp * 0.25)

		var zone: int = 0
		while mask != 0 and zone < n:
			if (mask & 1) != 0:
				dps[zone] += add_dps
				barrier[zone] += add_hp
				if turret:
					turret_n[zone] += 1
				elif defense:
					wall_n[zone] += 1
				ids_by_zone[zone].append(id)
			mask >>= 1
			zone += 1

	for z: int in n:
		var v3: ThreatVector = _candidates[z]
		v3.defence_dps = dps[z]
		v3.barrier_hp = barrier[z]
		v3.turrets = turret_n[z]
		v3.walls = wall_n[z]
		# [P11] hands out its buildings ascending by id, so the corridor lists
		# come out ascending too and never need sorting.
		v3.structures = ids_by_zone[z]
		var rating: float = v3.defence_dps + v3.barrier_hp * _profile.defence_hp_weight
		v3.defence = rating / (rating + _profile.defence_reference)


## Chooses tonight's vectors and their shares. Returns fresh ThreatVector
## instances owned by the plan; the candidates keep their own identity so a
## rescore mid-night can be copied back onto them.
func select(wave: int, set_piece: bool, rng: RandomNumberGenerator) -> Array[ThreatVector]:
	if _candidates.is_empty():
		return []
	rescore()
	var want: int = mini(_profile.vector_count(wave, set_piece), _candidates.size())

	var main: int = _fastest_road()
	var probe: int = -1
	var probe_share: float = _profile.probe_share(wave)
	if want >= 2 and probe_share > 0.0:
		probe = _weakest_side(main)

	var picked: Array[int] = [main]
	if probe >= 0:
		picked.append(probe)
	for extra: int in _rank_rest(picked, rng):
		if picked.size() >= want:
			break
		picked.append(extra)

	# Shares. The main road always carries the larger part of what is left after
	# the probe, so the attack the player was told about is the attack that
	# arrives; the flanks are real, never decisive on their own.
	var shares: Dictionary[int, float] = {}
	if picked.size() == 1:
		shares[picked[0]] = 1.0
	else:
		var flanks: int = picked.size() - (2 if probe >= 0 else 1)
		var rest: float = 1.0 - (probe_share if probe >= 0 else 0.0)
		var main_share: float = rest if flanks <= 0 else rest * 0.62
		shares[main] = main_share
		if probe >= 0:
			shares[probe] = probe_share
		if flanks > 0:
			var each: float = (rest - main_share) / float(flanks)
			for c: int in picked:
				if c != main and c != probe:
					shares[c] = each

	_apply_share_cap(shares)

	var out: Array[ThreatVector] = []
	var order: Array[int] = picked.duplicate()
	order.sort()
	for c2: int in order:
		var src: ThreatVector = _candidates[c2]
		var v: ThreatVector = _copy(src)
		v.index = out.size()
		v.share = float(shares.get(c2, 0.0))
		v.role = ThreatVector.ROLE_MAIN if c2 == main else (
			ThreatVector.ROLE_PROBE if c2 == probe else ThreatVector.ROLE_FLANK)
		out.append(v)
	return out


## Copies fresh defence numbers onto a plan's vectors. Called during a night so
## a turret finished at 22:00 actually defends at 22:01.
func refresh(vectors: Array[ThreatVector]) -> void:
	rescore()
	for v: ThreatVector in vectors:
		var src: ThreatVector = _by_lane(v.lane)
		if src == null:
			continue
		v.defence = src.defence
		v.defence_dps = src.defence_dps
		v.barrier_hp = src.barrier_hp
		v.turrets = src.turrets
		v.walls = src.walls
		v.structures = src.structures


func core_cell() -> Vector2i:
	return _core


func cell_of(idx: int) -> Vector2i:
	if _width <= 0:
		return Vector2i.ZERO
	return Vector2i(idx % _width, idx / _width)


## Distance in cells from the core, used by the siege model and by comfort.
func distance_to_core(cell: Vector2i) -> int:
	return maxi(absi(cell.x - _core.x), absi(cell.y - _core.y))


func to_dict() -> Dictionary:
	var out: Array = []
	for v: ThreatVector in _candidates:
		out.append(v.to_dict())
	return {"core": [_core.x, _core.y], "candidates": out}


# ---------------------------------------------------------------- internals

func _read_map() -> void:
	_core = Vector2i(128, 128)
	_width = 256
	_height = 256
	if _grid == null:
		return
	if _grid.has_method("core_cell"):
		_core = _grid.call("core_cell")
	if _grid.has_method("map_size"):
		var s: Vector2i = _grid.call("map_size")
		if s.x > 0 and s.y > 0:
			_width = s.x
			_height = s.y


func _build_disc() -> void:
	_disc.clear()
	var r: int = _profile.lane_corridor_radius
	for dy: int in range(-r, r + 1):
		for dx: int in range(-r, r + 1):
			if dx * dx + dy * dy <= r * r:
				_disc.append(Vector2i(dx, dy))


func _lanes() -> Array:
	if _grid == null or not _grid.has_method("approach_lanes"):
		return []
	var raw: Variant = _grid.call("approach_lanes")
	return raw if typeof(raw) == TYPE_ARRAY else []


func _vector_from_lane(lane: Dictionary, idx: int) -> ThreatVector:
	var path_raw: Variant = lane.get("path", PackedInt32Array())
	var path: PackedInt32Array = path_raw if typeof(path_raw) == TYPE_PACKED_INT32_ARRAY else PackedInt32Array()
	if path.size() < 4:
		return null
	var v := ThreatVector.new()
	v.index = idx
	v.lane = idx
	v.path = path
	v.entry_cell = cell_of(path[path.size() - 1])
	var choke_idx: int = int(lane.get("choke", -1))
	var choke_at: int = path.size() / 2
	if choke_idx >= 0:
		for i: int in path.size():
			if path[i] == choke_idx:
				choke_at = i
				break
	v.choke_cell = cell_of(path[choke_at])
	v.sector = ThreatDefs.compass_sector(v.entry_cell - _core)
	# From just outside the core out to a little past the chokepoint. That whole
	# stretch is "the approach": it is where a wall means something and where a
	# turret can reach the road.
	v.envelope_from = mini(_profile.lane_core_clear, maxi(0, choke_at - 1))
	v.envelope_to = mini(path.size() - 1, choke_at + _profile.lane_envelope_cells)
	v.travel = _travel_of(v.entry_cell, path.size())
	return v


## Cost of walking this road in. The flow field already knows; without it, the
## number of cells on the path is a perfectly good stand-in.
func _travel_of(entry: Vector2i, cells: int) -> int:
	if _grid != null and _grid.has_method("flow_distance"):
		var d: int = int(_grid.call("flow_distance", entry))
		# FlowField.UNREACHABLE is a very large sentinel, not a distance.
		if d > 0 and d < 0x3FFFFFF:
			return d
	return cells * 10


## No lanes (no grid, or a map with no roads): four compass approaches, so the
## director still works and still telegraphs honestly.
func _synthesise() -> void:
	var margin: int = 3
	var reach: int = maxi(8, mini(_width, _height) / 2 - margin)
	var dirs: Array[Vector2i] = [
		Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1),
	]
	for i: int in dirs.size():
		var d: Vector2i = dirs[i]
		var entry: Vector2i = _core + d * reach
		var v := ThreatVector.new()
		v.index = i
		v.lane = i
		v.entry_cell = entry
		v.choke_cell = _core + d * (reach / 2)
		v.sector = ThreatDefs.compass_sector(d)
		var path: PackedInt32Array = PackedInt32Array()
		for step: int in range(0, reach + 1):
			var c: Vector2i = _core + d * step
			path.append(c.y * _width + c.x)
		v.path = path
		v.envelope_from = mini(_profile.lane_core_clear, maxi(0, path.size() / 2 - 1))
		v.envelope_to = mini(path.size() - 1, path.size() / 2 + _profile.lane_envelope_cells)
		v.travel = reach * 10
		_candidates.append(v)


func _paint_zone(v: ThreatVector) -> void:
	if v.index >= MAX_MASKED_VECTORS:
		return
	var bit: int = 1 << v.index
	for i: int in range(v.envelope_from, v.envelope_to + 1):
		var c: Vector2i = cell_of(v.path[i])
		for o: Vector2i in _disc:
			var cell: Vector2i = c + o
			if cell.x < 0 or cell.y < 0 or cell.x >= _width or cell.y >= _height:
				continue
			_zone[cell] = int(_zone.get(cell, 0)) | bit


## Mask of the lanes a building defends, or 0. Checks the anchor cell and the
## footprint centre, which covers everything up to a 4x4 without a full scan.
func _zone_of(b: Object) -> int:
	var cell: Vector2i = b.get("cell")
	var mask: int = int(_zone.get(cell, 0))
	if b.has_method("rect"):
		var r: Rect2i = b.call("rect")
		var mid: Vector2i = r.position + r.size / 2
		if mid != cell:
			mask |= int(_zone.get(mid, 0))
	return mask


## Classification of a building kind, resolved once and then cached. Read
## through Registry rather than through [P11]'s classes, so this part compiles
## and runs whether or not the build system is in the build.
func _kind_info(kind: StringName) -> Dictionary:
	var cached: Dictionary = _kind_cache.get(kind, {})
	if not cached.is_empty():
		return cached
	var info: Dictionary = {"turret": false, "defense": false}
	var res: Resource = Registry.get_item("buildings", kind)
	if res != null:
		var tags: Array = res.get("tags") if "tags" in res else []
		var weapon: String = String(res.get("weapon_id")) if "weapon_id" in res else ""
		var category: String = String(res.get("category")) if "category" in res else ""
		info["turret"] = weapon != "" or tags.has(&"turret")
		info["defense"] = not bool(info["turret"]) and (tags.has(&"wall") or category == "defense")
	_kind_cache[kind] = info
	return info


func _fastest_road() -> int:
	var best: int = 0
	for i: int in _candidates.size():
		if _candidates[i].travel < _candidates[best].travel:
			best = i
	return best


func _weakest_side(exclude: int) -> int:
	var best: int = -1
	for i: int in _candidates.size():
		if i == exclude:
			continue
		if best < 0 or _candidates[i].defence < _candidates[best].defence:
			best = i
	return best


## Everything not already picked, ordered by how attractive it is to attack.
## The small random term stops the third and fourth vectors from being perfectly
## predictable while keeping the first two honest.
func _rank_rest(picked: Array[int], rng: RandomNumberGenerator) -> Array[int]:
	var worst_travel: float = 1.0
	for v: ThreatVector in _candidates:
		worst_travel = maxf(worst_travel, float(v.travel))
	var scored: Array[Dictionary] = []
	for i: int in _candidates.size():
		if picked.has(i):
			continue
		var v2: ThreatVector = _candidates[i]
		var score: float = v2.defence * 0.6 + (float(v2.travel) / worst_travel) * 0.4 + rng.randf() * 0.15
		scored.append({"i": i, "s": score})
	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if absf(float(a["s"]) - float(b["s"])) > 0.000001:
			return float(a["s"]) < float(b["s"])
		return int(a["i"]) < int(b["i"]))
	var out: Array[int] = []
	for e: Dictionary in scored:
		out.append(int(e["i"]))
	return out


## No vector may carry more than the cap once there is more than one, and the
## shares always sum to 1. This is the "never unfair" clause, written down.
func _apply_share_cap(shares: Dictionary[int, float]) -> void:
	if shares.size() <= 1:
		return
	var keys: Array = shares.keys()
	keys.sort()
	var cap: float = maxf(_profile.vector_share_cap, 1.0 / float(shares.size()))
	# Clamp, then spread the overflow into whatever headroom is left, and repeat.
	# Three passes is more than enough for any share set that sums to 1, and it
	# terminates whether or not the caller handed us a sane distribution.
	for _pass: int in 3:
		var overflow: float = 0.0
		var room: float = 0.0
		for k: int in keys:
			var s: float = float(shares[k])
			if s > cap:
				overflow += s - cap
				shares[k] = cap
			else:
				room += cap - s
		if overflow <= 0.000001:
			break
		if room <= 0.000001:
			break
		for k2: int in keys:
			var space: float = maxf(0.0, cap - float(shares[k2]))
			shares[k2] = float(shares[k2]) + overflow * space / room
	var total: float = 0.0
	for k3: int in keys:
		total += float(shares[k3])
	if total > 0.0:
		for k4: int in keys:
			shares[k4] = float(shares[k4]) / total


func _by_lane(lane: int) -> ThreatVector:
	for v: ThreatVector in _candidates:
		if v.lane == lane:
			return v
	return null


func _copy(src: ThreatVector) -> ThreatVector:
	var v := ThreatVector.new()
	v.lane = src.lane
	v.entry_cell = src.entry_cell
	v.choke_cell = src.choke_cell
	v.sector = src.sector
	v.path = src.path
	v.envelope_from = src.envelope_from
	v.envelope_to = src.envelope_to
	v.defence = src.defence
	v.defence_dps = src.defence_dps
	v.barrier_hp = src.barrier_hp
	v.turrets = src.turrets
	v.walls = src.walls
	v.structures = src.structures
	v.travel = src.travel
	return v


func _describe() -> String:
	var parts: PackedStringArray = PackedStringArray()
	for v: ThreatVector in _candidates:
		parts.append("%s@%d" % [v.short_label(), v.travel])
	return ", ".join(parts)
