class_name CitizenJobBoard
extends RefCounted
## [P05] Who works where, who sleeps where, and which door they use.
##
## The board mirrors [P11]'s buildings into a small, sorted record set that the
## population loop can read without touching the build system, and it owns the
## two matchings that make a city a city:
##
##   * **jobs** — a building declares `workers_required` and `staff_capacity`;
##     the board hires the nearest idle adult and writes the crew size back into
##     `BuildingInstance.workers`, which is the field [P04] and [P07] read. An
##     unstaffed building therefore underperforms without any other part knowing
##     that citizens exist.
##   * **beds** — a building declares `residents`; the board houses people in
##     it, and anyone left over is homeless, which is a death sentence in a
##     blizzard and is meant to be.
##
## Nothing here knows a building by name. Roles come from tags and categories
## on the def, so dropping a new .tres into game/content/buildings/ is enough to
## create a trade, an infirmary or a bunkhouse.

## Doors re-derived per refresh pass. Bounded on purpose — see _revalidate_doors.
const DOOR_FIXES_PER_PASS: int = 8


## One building, as the population cares about it.
class Site extends RefCounted:
	var id: int = 0
	var kind: StringName = &""
	var label: String = ""
	var cell: Vector2i = Vector2i.ZERO
	var size: Vector2i = Vector2i.ONE
	var center: Vector2i = Vector2i.ZERO
	var door: Vector2i = Vector2i.ZERO
	var required: int = 0
	var capacity: int = 0
	var priority: int = 0
	var trade: int = CitizenDefs.Trade.LABOURER
	var hazard: bool = false
	var medical: bool = false
	var food: bool = false
	var comfort: float = 0.0        ## radiated warmth, used to pick a shelter
	var insulation: float = 0.35
	var beds: int = 0
	var operational: bool = false
	var shelter_c: float = 0.0
	var assigned: int = 0
	var present: int = 0
	var taken: int = 0              ## beds occupied

	func staffing() -> float:
		if required <= 0:
			return 1.0
		return clampf(float(present) / float(required), 0.0, 1.0)


var sites: Dictionary[int, Site] = {}
## Every site id, ascending. Rebuilt only when the building set changes, because
## sorting seventeen hundred keys several times a second is a tick all by itself.
var all_ids: PackedInt32Array = PackedInt32Array()
var job_ids: PackedInt32Array = PackedInt32Array()     ## sorted, hiring order
var home_ids: PackedInt32Array = PackedInt32Array()
var care_ids: PackedInt32Array = PackedInt32Array()
var food_ids: PackedInt32Array = PackedInt32Array()
var shelter_cell: Vector2i = Vector2i(-1, -1)
var shelter_building: int = -1

var total_required: int = 0
var total_capacity: int = 0
var total_beds: int = 0
var care_capacity: int = 0
var kitchen_factor: float = 0.0
var version: int = 0                                   ## bumps when the set changes

var _build: SimSystem = null
var _heat: SimSystem = null
var _grid: SimSystem = null
var _has_served: bool = false
var _has_frozen: bool = false
var _has_walkable: bool = false
var _order_dirty: bool = true
var _door_ids: PackedInt32Array = PackedInt32Array()


func bind(build: SimSystem, heat: SimSystem, grid: SimSystem) -> void:
	_build = build
	_heat = heat
	_grid = grid
	_has_served = heat != null and heat.has_method("served_of") and heat.has_method("has_building")
	_has_frozen = heat != null and heat.has_method("is_frozen")
	_has_walkable = grid != null and grid.has_method("is_walkable")


func clear() -> void:
	sites.clear()
	all_ids = PackedInt32Array()
	job_ids = PackedInt32Array()
	home_ids = PackedInt32Array()
	care_ids = PackedInt32Array()
	food_ids = PackedInt32Array()
	shelter_cell = Vector2i(-1, -1)
	shelter_building = -1
	total_required = 0
	total_capacity = 0
	total_beds = 0
	care_capacity = 0
	kitchen_factor = 0.0
	version = 0
	_order_dirty = true


func site_of(building_id: int) -> Site:
	return sites.get(building_id)


## Fraction of the crew a building actually has standing in it, 0..1.
## Buildings that need nobody always report 1.0.
func staffing_of(building_id: int) -> float:
	var s: Site = sites.get(building_id)
	return 1.0 if s == null else s.staffing()


func present_of(building_id: int) -> int:
	var s: Site = sites.get(building_id)
	return 0 if s == null else s.present


func assigned_of(building_id: int) -> int:
	var s: Site = sites.get(building_id)
	return 0 if s == null else s.assigned


func door_of(building_id: int) -> Vector2i:
	var s: Site = sites.get(building_id)
	return Vector2i(-1, -1) if s == null else s.door


# =========================================================================
#  refresh
# =========================================================================

## Re-reads [P11]. Adds new buildings, retires vanished ones, and refreshes the
## live facts — whether the place is running, and how warm it is inside, which
## is where [P02]'s per-building `served` becomes a citizen's body temperature.
##
## Returns the ids of buildings that no longer EXIST, so the caller can tear up
## the contracts pointing at them. A building that merely stopped running keeps
## its crew: they walk to the dark workshop, find it dead and go home, which is
## how a heat failure should read — not as a mass layoff and a mass rehire.
func refresh(_tick: int) -> PackedInt32Array:
	var gone := PackedInt32Array()
	if _build == null or not _build.has_method("all_buildings"):
		return gone
	var raw: Variant = _build.call("all_buildings")
	if typeof(raw) != TYPE_ARRAY:
		return gone
	var list: Array = raw
	var seen: Dictionary[int, bool] = {}
	var changed: bool = false
	for entry: Variant in list:
		var b: Object = entry
		if b == null or not b.has_method("is_complete"):
			continue
		var id: int = int(b.get("id"))
		var complete: bool = bool(b.call("is_complete"))
		var s: Site = sites.get(id)
		if s == null:
			if not complete:
				continue
			s = _make_site(b)
			if s == null:
				continue
			sites[id] = s
			changed = true
		seen[id] = true
		s.operational = complete and bool(b.call("is_running"))
		s.shelter_c = _shelter_for(s)

	for i: int in all_ids.size():
		var id: int = all_ids[i]
		if seen.has(id) or not sites.has(id):
			continue
		gone.append(id)
		sites.erase(id)
		changed = true
	if changed:
		_order_dirty = true
		version += 1
	if _order_dirty:
		_rebuild_order()
	_revalidate_doors()
	_refresh_totals()
	return gone


## A door is a fact about the ground, and the ground changes: the pipe run laid
## last minute can seal the only threshold a workshop had. Re-derive any door
## that is no longer standable — but only for buildings somebody walks to, and
## only a few per pass, because re-deriving a hundred at once IS the spike this
## whole file is arranged to avoid. A door nobody could fix this pass gets fixed
## on the next one.
func _revalidate_doors() -> void:
	if not _has_walkable:
		return
	var fixed: int = 0
	for i: int in _door_ids.size():
		if fixed >= DOOR_FIXES_PER_PASS:
			return
		var s: Site = sites.get(_door_ids[i])
		if s == null or bool(_grid.call("is_walkable", s.door)):
			continue
		s.door = _find_door(s)
		fixed += 1


func _make_site(b: Object) -> Site:
	var def: Object = b.get("def")
	if def == null:
		return null
	var s := Site.new()
	s.id = int(b.get("id"))
	s.kind = StringName(String(b.get("kind")))
	s.label = String(def.get("display_name"))
	if s.label == "":
		s.label = String(s.kind)
	s.cell = b.get("cell")
	var rot: int = int(b.get("rot"))
	s.size = def.call("effective_size", rot)
	s.center = s.cell + Vector2i(s.size.x / 2, s.size.y / 2)
	s.required = int(def.get("workers_required"))
	s.capacity = int(def.call("effective_staff_capacity"))
	s.priority = int(def.get("build_priority"))
	s.beds = int(def.get("residents"))
	s.insulation = float(def.get("heat_insulation"))
	s.comfort = float(def.get("heat_radius"))
	var tags: Array = def.get("tags")
	s.trade = CitizenDefs.trade_for(tags, StringName(String(def.get("category"))))
	s.medical = tags.has(CitizenDefs.TAG_MEDICAL)
	s.food = tags.has(CitizenDefs.TAG_FOOD)
	for t: StringName in CitizenDefs.HAZARD_TAGS:
		if tags.has(t):
			s.hazard = true
			break
	s.door = _find_door(s) if _needs_door(s) else s.center
	return s


## True when a citizen ever has to stand at this building: a job, a bed, an
## infirmary, or the warm square the homeless huddle in. Walls and pipes are
## eighty percent of a city's building count and nobody knocks on them.
static func _needs_door(s: Site) -> bool:
	return s.capacity > 0 or s.beds > 0 or s.medical or s.comfort > 0.0


## The tile a worker stands on. Buildings block movement, so "at the workshop"
## means at its door — which is also why a shift change reads as a crowd
## gathering at a threshold rather than sprites vanishing into a roof.
func _find_door(s: Site) -> Vector2i:
	var best := Vector2i(-1, -1)
	var best_score: int = 0x7FFFFFFF
	for y: int in range(s.cell.y - 1, s.cell.y + s.size.y + 1):
		for x: int in range(s.cell.x - 1, s.cell.x + s.size.x + 1):
			var inside_x: bool = x >= s.cell.x and x < s.cell.x + s.size.x
			var inside_y: bool = y >= s.cell.y and y < s.cell.y + s.size.y
			if inside_x and inside_y:
				continue
			if not inside_x and not inside_y:
				continue          # corners are not doors
			var c := Vector2i(x, y)
			if _has_walkable and not bool(_grid.call("is_walkable", c)):
				continue
			# Nearest to the centre wins; the (y, x) term only breaks ties, so
			# two identical worlds always pick the same threshold.
			var d: int = absi(c.x - s.center.x) + absi(c.y - s.center.y)
			var score: int = d * 100000 + (y & 0xFF) * 256 + (x & 0xFF)
			if score < best_score:
				best_score = score
				best = c
	if best.x >= 0:
		return best
	# Walled in on every side. Widen the search once rather than handing back a
	# cell inside the footprint, which no path can ever reach.
	for r: int in range(2, 5):
		for y2: int in range(s.cell.y - r, s.cell.y + s.size.y + r):
			for x2: int in range(s.cell.x - r, s.cell.x + s.size.x + r):
				var c2 := Vector2i(x2, y2)
				if not bool(_grid.call("is_walkable", c2)):
					continue
				var d2: int = absi(c2.x - s.center.x) + absi(c2.y - s.center.y)
				var score2: int = d2 * 100000 + (y2 & 0xFF) * 256 + (x2 & 0xFF)
				if score2 < best_score:
					best_score = score2
					best = c2
		if best.x >= 0:
			return best
	return s.center


## Degrees of warmth a roof is worth here. A frozen or starved building is
## barely better than standing in the road — that is the whole death spiral in
## one expression.
func _shelter_for(s: Site) -> float:
	var base: float = CitizenDefs.SHELTER_C * (0.6 + 0.4 * clampf(s.insulation, 0.0, 1.0))
	if not s.operational:
		return base * CitizenDefs.SHELTER_MIN_FACTOR
	var factor: float = 0.75
	if _has_served and bool(_heat.call("has_building", s.id)):
		if _has_frozen and bool(_heat.call("is_frozen", s.id)):
			factor = CitizenDefs.SHELTER_MIN_FACTOR
		else:
			var served: float = float(_heat.call("served_of", s.id))
			factor = CitizenDefs.SHELTER_MIN_FACTOR \
				+ (1.0 - CitizenDefs.SHELTER_MIN_FACTOR) * clampf(served, 0.0, 1.0)
	return base * factor


func _rebuild_order() -> void:
	_order_dirty = false
	var keys: Array = sites.keys()
	keys.sort()
	all_ids = PackedInt32Array(keys)
	var jobs: Array[int] = []
	var homes: Array[int] = []
	var care: Array[int] = []
	var food: Array[int] = []
	var doors: Array[int] = []
	for id: int in keys:
		var s: Site = sites[id]
		if s.capacity > 0:
			jobs.append(id)
		if s.beds > 0:
			homes.append(id)
		if s.medical:
			care.append(id)
		if s.food:
			food.append(id)
		if _needs_door(s):
			doors.append(id)
	_door_ids = PackedInt32Array(doors)
	# Heat and food outrank decoration when crews are short: build_priority is
	# already [P11]'s statement of what the city cannot do without.
	jobs.sort_custom(func(a: int, b: int) -> bool:
		var sa: Site = sites[a]
		var sb: Site = sites[b]
		if sa.priority != sb.priority:
			return sa.priority > sb.priority
		return a < b)
	job_ids = PackedInt32Array(jobs)
	home_ids = PackedInt32Array(homes)
	care_ids = PackedInt32Array(care)
	food_ids = PackedInt32Array(food)


func _refresh_totals() -> void:
	total_required = 0
	total_capacity = 0
	total_beds = 0
	care_capacity = 0
	var kitchens: int = 0
	var kitchen_staffed: float = 0.0
	var best_comfort: float = -1.0
	var best_id: int = -1
	for i: int in job_ids.size():
		var s: Site = sites[job_ids[i]]
		if not s.operational:
			continue
		total_required += s.required
		total_capacity += s.capacity
	for i: int in home_ids.size():
		var s2: Site = sites[home_ids[i]]
		if s2.operational:
			total_beds += s2.beds
	for i: int in care_ids.size():
		var s3: Site = sites[care_ids[i]]
		if s3.operational:
			care_capacity += maxi(s3.capacity, 2) * 2
	# Until a building carries the medical tag, the sick are nursed in their own
	# bunks. Worse than an infirmary and rationed by how many beds exist, but a
	# city with housing is never a city with no care at all.
	care_capacity += total_beds / 4
	for i: int in food_ids.size():
		var s4: Site = sites[food_ids[i]]
		if not s4.operational or s4.required <= 0:
			continue
		kitchens += 1
		kitchen_staffed += s4.staffing()
	kitchen_factor = 0.0 if kitchens == 0 else clampf(kitchen_staffed / float(kitchens), 0.0, 1.0)
	# The warmest running building is where the homeless huddle. Picking it by
	# radiated warmth (never by dictionary order) keeps the choice replayable.
	for i: int in _door_ids.size():
		var s5: Site = sites[_door_ids[i]]
		if not s5.operational or s5.comfort <= 0.0:
			continue
		if s5.comfort > best_comfort:
			best_comfort = s5.comfort
			best_id = s5.id
	shelter_building = best_id
	shelter_cell = sites[best_id].door if best_id >= 0 else Vector2i(-1, -1)


# =========================================================================
#  matching
# =========================================================================

## Counts who is actually standing in each building. Cheap enough to run several
## times a second, which is what keeps `staffing_of` honest during a shift
## change instead of reporting the roster.
func recount_presence(pool: CitizenPool) -> void:
	for i: int in job_ids.size():
		sites[job_ids[i]].present = 0
	var n: int = pool.alive.size()
	for i: int in n:
		var s: int = pool.alive[i]
		if pool.state[s] != CitizenDefs.State.WORKING:
			continue
		var b: int = pool.job[s]
		if b < 0:
			continue
		var site: Site = sites.get(b)
		if site != null:
			site.present += 1


## Writes the crew size back into [P11]'s instances, which is where [P04]
## production and [P07] combat read it from.
func publish_workers() -> void:
	if _build == null or not _build.has_method("get_building"):
		return
	for i: int in job_ids.size():
		var site: Site = sites[job_ids[i]]
		var b: Object = _build.call("get_building", site.id)
		if b != null:
			b.set("workers", site.present)


## Fills up to `limit` vacancies with the nearest idle worker. Hiring is
## deliberately gradual: a city that loses a shift should visibly scramble.
func assign_jobs(pool: CitizenPool, jobless: PackedInt32Array, allow_child: bool,
		allow_elder: bool, limit: int) -> int:
	if jobless.is_empty():
		return 0
	var taken: Dictionary[int, bool] = {}
	var hires: int = 0
	for i: int in job_ids.size():
		if hires >= limit:
			break
		var site: Site = sites[job_ids[i]]
		if not site.operational or site.assigned >= site.capacity:
			continue
		while site.assigned < site.capacity and hires < limit:
			var pick: int = _nearest_worker(pool, jobless, taken, site,
				allow_child, allow_elder)
			if pick < 0:
				break
			taken[pick] = true
			pool.job[pick] = site.id
			pool.trade[pick] = site.trade
			pool.hazard[pick] = 1 if site.hazard else 0
			site.assigned += 1
			hires += 1
	return hires


func _nearest_worker(pool: CitizenPool, jobless: PackedInt32Array,
		taken: Dictionary[int, bool], site: Site,
		allow_child: bool, allow_elder: bool) -> int:
	var best: int = -1
	var best_d: int = 0x7FFFFFFF
	for i: int in jobless.size():
		var s: int = jobless[i]
		if taken.has(s) or pool.job[s] >= 0:
			continue
		var bracket: int = CitizenDefs.age_bracket(pool.age[s])
		if bracket == CitizenDefs.Age.CHILD and not (allow_child
				and pool.age[s] >= CitizenDefs.CHILD_LABOUR_MIN_AGE):
			continue
		if bracket == CitizenDefs.Age.ELDER and not allow_elder:
			continue
		if pool.illness[s] >= CitizenDefs.SICK_ONSET or pool.injury[s] >= CitizenDefs.INJURY_CLEAR:
			continue
		# Distance from where they sleep, not where they stand: a job you can
		# walk to from your bed is a job you keep.
		var from: Vector2i = pool.cell_of(s)
		var h: int = pool.home[s]
		if h >= 0:
			var hs: Site = sites.get(h)
			if hs != null:
				from = hs.door
		var d: int = absi(from.x - site.door.x) + absi(from.y - site.door.y)
		if d < best_d:
			best_d = d
			best = s
	return best


## Beds for the homeless, nearest first. Returns how many moved in.
func assign_homes(pool: CitizenPool, homeless: PackedInt32Array, limit: int) -> int:
	if homeless.is_empty():
		return 0
	var moved: int = 0
	for i: int in homeless.size():
		if moved >= limit:
			break
		var s: int = homeless[i]
		if pool.home[s] >= 0:
			continue
		var best: int = -1
		var best_d: int = 0x7FFFFFFF
		var from: Vector2i = pool.cell_of(s)
		var j: int = pool.job[s]
		if j >= 0:
			var js: Site = sites.get(j)
			if js != null:
				from = js.door
		for k: int in home_ids.size():
			var hs: Site = sites[home_ids[k]]
			if not hs.operational or hs.taken >= hs.beds:
				continue
			var d: int = absi(from.x - hs.door.x) + absi(from.y - hs.door.y)
			if d < best_d:
				best_d = d
				best = home_ids[k]
		if best < 0:
			break
		sites[best].taken += 1
		pool.home[s] = best
		moved += 1
	return moved


## Drops every assignment pointing at a building that is gone or stopped.
func release(pool: CitizenPool, building_ids: PackedInt32Array) -> void:
	if building_ids.is_empty():
		return
	var gone: Dictionary[int, bool] = {}
	for i: int in building_ids.size():
		gone[building_ids[i]] = true
	var n: int = pool.alive.size()
	for i: int in n:
		var s: int = pool.alive[i]
		if pool.job[s] >= 0 and gone.has(pool.job[s]):
			pool.job[s] = -1
			pool.hazard[s] = 0
		if pool.home[s] >= 0 and gone.has(pool.home[s]):
			pool.home[s] = -1
	_recount_assignments(pool)


## Rebuilds assigned/taken from the citizens themselves. The counters are a
## cache of the truth, and after any bulk change the truth wins.
func _recount_assignments(pool: CitizenPool) -> void:
	for i: int in job_ids.size():
		sites[job_ids[i]].assigned = 0
	for j: int in home_ids.size():
		sites[home_ids[j]].taken = 0
	var n: int = pool.alive.size()
	for i: int in n:
		var s: int = pool.alive[i]
		var j: int = pool.job[s]
		if j >= 0:
			var js: Site = sites.get(j)
			if js == null:
				pool.job[s] = -1
			else:
				js.assigned += 1
		var h: int = pool.home[s]
		if h >= 0:
			var hs: Site = sites.get(h)
			if hs == null:
				pool.home[s] = -1
			else:
				hs.taken += 1


func recount(pool: CitizenPool) -> void:
	_recount_assignments(pool)


## Frees the slots one citizen held. Called the moment they die.
func vacate(pool: CitizenPool, slot: int) -> void:
	var j: int = pool.job[slot]
	if j >= 0:
		var js: Site = sites.get(j)
		if js != null:
			js.assigned = maxi(0, js.assigned - 1)
	var h: int = pool.home[slot]
	if h >= 0:
		var hs: Site = sites.get(h)
		if hs != null:
			hs.taken = maxi(0, hs.taken - 1)


## The nearest running infirmary door, or (-1, -1) when the city has none.
func nearest_care(from: Vector2i) -> int:
	var best: int = -1
	var best_d: int = 0x7FFFFFFF
	for i: int in care_ids.size():
		var s: Site = sites[care_ids[i]]
		if not s.operational:
			continue
		var d: int = absi(from.x - s.door.x) + absi(from.y - s.door.y)
		if d < best_d:
			best_d = d
			best = care_ids[i]
	return best


func spare_beds() -> int:
	var free: int = 0
	for i: int in home_ids.size():
		var s: Site = sites[home_ids[i]]
		if s.operational:
			free += maxi(0, s.beds - s.taken)
	return free
