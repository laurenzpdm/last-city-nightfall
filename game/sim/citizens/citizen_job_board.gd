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

## How many crews may be re-cut in a single hiring pass. The surplus a building
## took while it was the only building in town is the city's labour reserve, and
## a city that has just finished a smelter should be SEEN to walk people over to
## it across a shift — not to teleport its whole workforce in one tick.
const TRANSFERS_PER_PASS: int = 2


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
	## Somebody stands here: a job, a bed, an infirmary, or the warm square.
	## Walls and pipes are most of a city's building count and nobody visits them,
	## so everything expensive in refresh() is gated on this flag.
	var needs_door: bool = false
	## Standing here stops a walker. Only these change what a path can do.
	var blocks: bool = false
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
## Cells whose walkability changed during the last refresh(). [P05]'s router
## drops exactly the cached paths that crossed them, instead of the whole cache.
var blocked_cells: Array[Vector2i] = []

## How many employed citizens are on the night rotation after the last cut. The
## price of a factory that runs in the dark, in bodies, for [P17] and the log.
var night_crew: int = 0
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
	blocked_cells.clear()
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
		if b == null:
			continue
		var id: int = int(b.get("id"))
		seen[id] = true
		var s: Site = sites.get(id)
		if s == null:
			if not bool(b.call("is_complete")):
				continue
			s = _make_site(b)
			if s == null:
				continue
			sites[id] = s
			changed = true
			if s.blocks:
				_collect_cells(s)
		# A wall's operating state is nobody's business here. Skipping it is what
		# keeps a seventeen-hundred-building city off this system's tick budget.
		if not s.needs_door:
			continue
		s.operational = bool(b.call("is_running"))
		s.shelter_c = _shelter_for(s)

	for i: int in all_ids.size():
		var id: int = all_ids[i]
		if seen.has(id) or not sites.has(id):
			continue
		gone.append(id)
		if sites[id].blocks:
			_collect_cells(sites[id])
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


func _collect_cells(s: Site) -> void:
	for y: int in s.size.y:
		for x: int in s.size.x:
			blocked_cells.append(s.cell + Vector2i(x, y))


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
	s.blocks = bool(def.get("blocks_movement"))
	s.needs_door = _needs_door(s)
	s.door = _find_door(s) if s.needs_door else s.center
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
		if s.needs_door:
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


## The crew a site cannot run WITHOUT — never more than it has room for, because
## a def is allowed to be wrong and a matcher is not.
static func _need_of(site: Site) -> int:
	return mini(site.required, site.capacity)


## Fills up to `limit` vacancies with the nearest idle worker. Hiring is
## deliberately gradual: a city that loses a shift should visibly scramble.
##
## Three passes, and the order between them is the whole point. `capacity` is how
## many people a building has ROOM for; `required` is how many it needs to run at
## all. A single greedy walk that fills each site to capacity in priority order
## hands the front of the queue the entire labour force — the Hearth hired eight
## against a need of four — and every building finished after that starves no
## matter how much slack the city has. So:
##
##   1. every site's `required` crew, priority order, from the idle queue;
##   2. anything still short is covered out of the SURPLUS of the sites that took
##      more than they need, because on a settled map nobody is idle;
##   3. and only then do spare hands deepen crews toward `capacity` — dealt out
##      a layer at a time, because `required` is a crew ROSTER and a shift is
##      what puts people in the room. A building carrying exactly its
##      requirement has that many people in it only while none of them is
##      asleep, eating or walking, so depth is what makes a crew reliable.
func assign_jobs(pool: CitizenPool, jobless: PackedInt32Array, allow_child: bool,
		allow_elder: bool, limit: int) -> int:
	if limit <= 0:
		return 0
	var taken: Dictionary[int, bool] = {}
	var hires: int = 0
	hires += _required_pass(pool, jobless, taken, allow_child, allow_elder, limit - hires)
	hires += _reassign_surplus(pool, limit - hires)
	hires += _deepen_pass(pool, jobless, taken, allow_child, allow_elder, limit - hires)
	return hires


## One walk down the hiring order, filling each site to the crew it cannot run
## without and not one person further.
func _required_pass(pool: CitizenPool, jobless: PackedInt32Array,
		taken: Dictionary[int, bool], allow_child: bool, allow_elder: bool,
		limit: int) -> int:
	if limit <= 0 or jobless.is_empty():
		return 0
	var hires: int = 0
	for i: int in job_ids.size():
		if hires >= limit:
			break
		var site: Site = sites[job_ids[i]]
		if not site.operational:
			continue
		while site.assigned < _need_of(site) and hires < limit:
			var pick: int = _nearest_worker(pool, jobless, taken, site,
				allow_child, allow_elder)
			# The queue rejects candidates on age and health, never on which site
			# is asking, so an empty answer here is an empty answer for every site
			# still to come. Walking the rest of the order would re-scan the whole
			# sample once per vacancy to learn the same thing.
			if pick < 0:
				return hires
			taken[pick] = true
			_place(pool, pick, site)
			hires += 1
	return hires


## Spare hands, spread before deep. Walking the order once and filling each site
## to `capacity` is the same mistake as the loop this file replaced, one level
## down: the Hearth would take every spare pair of hands for its fifth through
## eighth body while the kitchen ran on the bare two that let it call itself
## staffed. So the surplus is dealt out in layers — everybody gets a second body
## before anybody gets a third — and priority only decides who gets each layer
## first.
func _deepen_pass(pool: CitizenPool, jobless: PackedInt32Array,
		taken: Dictionary[int, bool], allow_child: bool, allow_elder: bool,
		limit: int) -> int:
	if limit <= 0 or jobless.is_empty():
		return 0
	var deepest: int = 0
	for i: int in job_ids.size():
		var s: Site = sites[job_ids[i]]
		if s.operational:
			deepest = maxi(deepest, s.capacity - _need_of(s))
	var hires: int = 0
	for depth: int in range(1, deepest + 1):
		if hires >= limit:
			break
		for i: int in job_ids.size():
			if hires >= limit:
				break
			var site: Site = sites[job_ids[i]]
			if not site.operational:
				continue
			if site.assigned >= mini(_need_of(site) + depth, site.capacity):
				continue
			var pick: int = _nearest_worker(pool, jobless, taken, site,
				allow_child, allow_elder)
			if pick < 0:
				return hires
			taken[pick] = true
			_place(pool, pick, site)
			hires += 1
	return hires


## Cuts the day and night rotations. **A shift belongs to a BUILDING, not to a
## hire counter — and no building in this city closes at sunset.**
##
## Two rules died here, in this order.
##
## The first dealt every third hire to the night and never looked at where that
## person worked, so the rotation was a property of hire ORDER and was never
## re-cut: every building was permanently missing a third of its crew by day and
## two thirds by night, and `citizens.staffed` never rose above 0.64 at any hour.
##
## The second — the one this replaces — put a crew entirely on the rotation its
## building was "for" and only bought a second rotation with surplus bodies. In a
## city that is short of hands nothing ever HAS surplus, so in practice every
## workshop was day-only and every gun was night-only. Measured over 24000 ticks:
## `production.active_machines` 3.01 morning, 2.44 afternoon, then 0.34 / 0.44 /
## 0.35 through the dark, all eight machines ending `unstaffed`, every belt line
## at throughput 0.0. It also cost the DAY: the hearth's four stokers were all on
## nights, so the city's main fire read `no crew` every morning.
##
## The rule now, in one sentence: **a crew works both rotations, weighted toward
## the hours its building is for.** Primary is filled first; `skeleton_crew` says
## how many hands are peeled off for the other rotation; surplus past `required`
## still buys a full second crew, because depth should always beat policy. A
## workshop of four is three by day and one after dark. A gun of one stays on the
## wall at night, because one body cannot be in two places.
##
## The cost is deliberate and lands on the day: half a crew at the bench is half
## the output, so daylight is no longer free and hiring past `required` is how
## you buy it back. CitizenDefs.NIGHT_TRADES carries the rest of the reasoning.
##
## Re-cut from scratch on every pass rather than remembered, so somebody walked
## onto a new crew by `_reassign_surplus` takes that crew's hours with them
## instead of carrying their first employer's rota around for life.
##
## Deterministic twice over: `pool.alive` and `job_ids` are both sorted, and the
## one dictionary here is only ever read through `job_ids`, never iterated.
func cut_shifts(pool: CitizenPool, law: StringName = CitizenDefs.LAW_STANDARD) -> void:
	# One walk of the population buckets every crew. Asking each site who works
	# there instead is O(sites x population), which is the shape this whole file
	# is arranged to avoid.
	var crews: Dictionary[int, PackedInt32Array] = {}
	var n: int = pool.alive.size()
	for i: int in n:
		var s: int = pool.alive[i]
		var j: int = pool.job[s]
		if j < 0:
			pool.shift[s] = CitizenDefs.Shift.OFF
			continue
		# Days by default, so a crew whose site vanished between the last refresh
		# and this pass is never left holding a rotation nobody will re-cut.
		pool.shift[s] = CitizenDefs.Shift.DAY
		var crew: PackedInt32Array = crews.get(j, PackedInt32Array())
		crew.append(s)
		crews[j] = crew

	night_crew = 0
	for i: int in job_ids.size():
		var id: int = job_ids[i]
		if not crews.has(id):
			continue
		var crew2: PackedInt32Array = crews[id]
		var site: Site = sites[id]
		var need: int = _need_of(site)
		var primary: int = CitizenDefs.Shift.NIGHT \
			if CitizenDefs.is_night_trade(site.trade) else CitizenDefs.Shift.DAY
		var other: int = CitizenDefs.Shift.DAY \
			if primary == CitizenDefs.Shift.NIGHT else CitizenDefs.Shift.NIGHT
		# Two claims on the other rotation, and the bigger one wins.
		#
		#   policy  — the shift law's skeleton share of this crew, so a building
		#             with exactly its requirement still has somebody in it at
		#             the far end of the clock;
		#   depth   — every hand past `required`, because a spare body adds
		#             nothing to a rotation that is already at its requirement.
		#
		# The cliff version of the depth rule — cover both ONLY with a full
		# second crew — was measured over 24000 ticks and took
		# `production.active_machines` at night to 0.00, because almost nothing
		# in a city short of hands ever reaches twice its requirement. That is
		# why policy exists underneath it and why it is not conditional on
		# anything: the dark is the game.
		var policy: int = CitizenDefs.skeleton_crew(law, crew2.size())
		var depth: int = clampi(crew2.size() - need, 0, need) if need > 0 else 0
		var to_other: int = clampi(maxi(policy, depth), 0, maxi(0, crew2.size() - 1))
		# A curfew beats depth as well as policy. Without this the law is a lie
		# in exactly the city that can afford to sign it: a crew twice its
		# requirement would cover both rotations anyway, so the buildings that
		# would actually keep working through a curfew are the well-staffed ones.
		if not CitizenDefs.splits_the_clock(law):
			to_other = 0
		var keep: int = crew2.size() - to_other
		for k: int in crew2.size():
			var shift: int = primary if k < keep else other
			pool.shift[crew2[k]] = shift
			if shift == CitizenDefs.Shift.NIGHT:
				night_crew += 1


func _place(pool: CitizenPool, slot: int, site: Site) -> void:
	pool.job[slot] = site.id
	pool.trade[slot] = site.trade
	pool.hazard[slot] = 1 if site.hazard else 0
	site.assigned += 1


## Moves people off crews that are deeper than they need to be and onto the
## required slots nobody is standing in. Without this the two passes above only
## help a city that still has idle hands; the one in the reference run had none,
## because the first four buildings had hired everybody.
##
## Bounded per pass on purpose, and the whole re-cut is skipped in the ordinary
## case where nothing is short.
func _reassign_surplus(pool: CitizenPool, limit: int) -> int:
	var budget: int = mini(limit, TRANSFERS_PER_PASS)
	if budget <= 0:
		return 0
	var moved: int = 0
	for i: int in job_ids.size():
		if moved >= budget:
			break
		var site: Site = sites[job_ids[i]]
		if not site.operational or site.assigned >= _need_of(site):
			continue
		while site.assigned < _need_of(site) and moved < budget:
			# A donor is a donor regardless of who is asking, so once the city has
			# no surplus left it has none for anybody.
			if not _poach_one(pool, site):
				return moved
			moved += 1
	return moved


## Takes one worker off the least important overstaffed crew in the city and
## puts them on `site`. Returns false when no building anywhere is carrying more
## people than it needs — at which point the city is simply short of hands, and
## the understaffed badge is telling the truth.
func _poach_one(pool: CitizenPool, site: Site) -> bool:
	# Reverse hiring order: lowest build_priority first, and among equals the
	# highest id — the crew a city can most afford to thin is the last thing it
	# decided it wanted.
	for i: int in range(job_ids.size() - 1, -1, -1):
		var donor: Site = sites[job_ids[i]]
		if donor.id == site.id or donor.assigned <= _need_of(donor):
			continue
		var pick: int = _pick_from_crew(pool, donor, site)
		if pick < 0:
			continue
		donor.assigned = maxi(0, donor.assigned - 1)
		_place(pool, pick, site)
		return true
	return false


## Whoever on the donor's roster stands closest to the door that needs them.
## `pool.alive` is sorted, so equal distances always resolve to the same person
## and a replay re-cuts the same crews.
func _pick_from_crew(pool: CitizenPool, donor: Site, site: Site) -> int:
	var best: int = -1
	var best_d: int = 0x7FFFFFFF
	var n: int = pool.alive.size()
	for i: int in n:
		var s: int = pool.alive[i]
		if pool.job[s] != donor.id:
			continue
		# Reassigning someone who is in bed with fever fills the roster and not
		# the building, which is the exact lie this whole change exists to stop.
		if pool.illness[s] >= CitizenDefs.SICK_ONSET or pool.injury[s] >= CitizenDefs.INJURY_CLEAR:
			continue
		var from: Vector2i = pool.cell_of(s)
		var d: int = absi(from.x - site.door.x) + absi(from.y - site.door.y)
		if d < best_d:
			best_d = d
			best = s
	return best


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
