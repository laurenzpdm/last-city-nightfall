class_name ProdWasteHeat
extends RefCounted
## The heat-recovery loop: the reason a good factory layout is worth building.
##
## A smelter throws off far more heat than it keeps. Every recipe that names
## `waste_heat` banks that much per craft on the machine that ran it. A
## RECUPERATOR standing within its capture radius drains those banks and hands
## the result to [P02] as fuel — it is an ordinary burner whose fuel item is
## `waste_heat`, so heat needs no special case for it and none of this code
## touches the heat solver.
##
## Uncaptured waste DECAYS. That single line is the whole design: heat you do
## not catch goes up the chimney, so packing your smelters around a recuperator
## pays and sprawling does not. Distance is Chebyshev between footprint boxes,
## because a player reads squares, not circles.
##
## Determinism: recuperators are served in id order, and each one drains its
## sources in (distance, id) order. Both lists are rebuilt only when the machine
## set changes, so the per-tick cost is a walk over an already-sorted array.

## Fraction of an uncaptured bank that is lost per second.
const DECAY_PER_SECOND: float = 0.35
## A bank below this is not worth carrying.
const EPS: float = 0.0001
## Hard cap on a machine's bank, in seconds of its own output. Stops a machine
## that nobody ever collects from hoarding an unbounded number.
const BANK_SECONDS: float = 6.0

## Recuperator id -> sorted [source_id, ...] within its capture radius.
var _links: Dictionary[int, PackedInt32Array] = {}
var _dirty: bool = true
var _recuperators: PackedInt32Array = PackedInt32Array()

var recovered_rate: float = 0.0   ## units/s handed to [P02] last tick
var vented_rate: float = 0.0      ## units/s that decayed away last tick


## Call whenever a machine is added or removed. Relinking is O(recuperators x
## sources) and happens on a build event, never on a tick.
func mark_dirty() -> void:
	_dirty = true


## Rebuilds the capture map. `machines` is id -> ProdMachine, ids sorted.
func relink(order: PackedInt32Array, machines: Dictionary[int, ProdMachine]) -> void:
	if not _dirty:
		return
	_dirty = false
	_links.clear()
	_recuperators = PackedInt32Array()
	var sources: PackedInt32Array = PackedInt32Array()
	for id: int in order:
		var m: ProdMachine = machines[id]
		if m.def.is_recuperator():
			_recuperators.append(id)
		elif m.def.is_crafter() or m.def.is_extractor():
			sources.append(id)

	for rid: int in _recuperators:
		var r: ProdMachine = machines[rid]
		var reach: float = r.def.capture_radius
		var scored: Array = []
		for sid: int in sources:
			var s: ProdMachine = machines[sid]
			var d: int = _chebyshev(r, s)
			if float(d) <= reach:
				scored.append([d, sid])
		scored.sort_custom(func(a: Array, b: Array) -> bool:
			if int(a[0]) != int(b[0]):
				return int(a[0]) < int(b[0])
			return int(a[1]) < int(b[1]))
		var arr: PackedInt32Array = PackedInt32Array()
		for entry: Variant in scored:
			arr.append(int((entry as Array)[1]))
		_links[rid] = arr


## Adds recoverable waste to a machine's bank, capped so an uncollected machine
## cannot bank forever.
func bank(m: ProdMachine, amount: float) -> void:
	if amount <= 0.0:
		return
	var cap: float = maxf(1.0, amount * BANK_SECONDS * 20.0)
	m.waste_bank = minf(cap, m.waste_bank + amount)


## Drains banks into recuperators as [P02] fuel, then decays the rest.
## `deliver` is called as deliver.call(recuperator_id, units) and returns how
## many units the burner actually accepted.
func distribute(order: PackedInt32Array, machines: Dictionary[int, ProdMachine],
		dt: float, deliver: Callable) -> void:
	recovered_rate = 0.0
	vented_rate = 0.0
	for id: int in order:
		machines[id].waste_given = 0.0
		machines[id].waste_taken = 0.0

	for rid: int in _recuperators:
		var r: ProdMachine = machines.get(rid)
		if r == null or not r.enabled:
			continue
		var want: float = r.def.waste_capture * dt
		if want <= EPS:
			continue
		var pooled: float = 0.0
		var links: PackedInt32Array = _links.get(rid, PackedInt32Array())
		for sid: int in links:
			if pooled >= want - EPS:
				break
			var s: ProdMachine = machines.get(sid)
			if s == null or s.waste_bank <= EPS:
				continue
			var take: float = minf(s.waste_bank, want - pooled)
			s.waste_bank -= take
			s.waste_given += take / dt
			pooled += take
		if pooled <= EPS:
			continue
		# The burner may be full; hand back whatever it refused so the sources
		# keep it and a later tick can still use it.
		var accepted: float = float(deliver.call(rid, pooled))
		var refused: float = maxf(0.0, pooled - accepted)
		if refused > EPS:
			_return(refused, links, machines, dt)
		r.waste_taken = accepted / dt
		recovered_rate += accepted / dt

	var decay: float = clampf(DECAY_PER_SECOND * dt, 0.0, 1.0)
	for id2: int in order:
		var m: ProdMachine = machines[id2]
		if m.waste_bank <= EPS:
			m.waste_bank = 0.0
			continue
		var lost: float = m.waste_bank * decay
		m.waste_bank -= lost
		vented_rate += lost / dt


func recuperator_count() -> int:
	return _recuperators.size()


## Sorted diagnostic for the state dump: which recuperator watches which machines.
func to_json() -> Dictionary:
	var out: Dictionary = {}
	var keys: Array = _links.keys()
	keys.sort()
	for k: int in keys:
		var arr: Array = []
		for v: int in _links[k]:
			arr.append(v)
		out[str(k)] = arr
	return out


func _return(amount: float, links: PackedInt32Array, machines: Dictionary[int, ProdMachine], dt: float) -> void:
	var left: float = amount
	for sid: int in links:
		if left <= EPS:
			return
		var s: ProdMachine = machines.get(sid)
		if s == null or s.waste_given <= 0.0:
			continue
		var back: float = minf(left, s.waste_given * dt)
		s.waste_bank += back
		s.waste_given -= back / dt
		left -= back


## Tile gap between two footprint boxes, 0 when they touch or overlap.
func _chebyshev(a: ProdMachine, b: ProdMachine) -> int:
	var ar: Rect2i = _box(a)
	var br: Rect2i = _box(b)
	var dx: int = maxi(0, maxi(ar.position.x - br.end.x + 1, br.position.x - ar.end.x + 1))
	var dy: int = maxi(0, maxi(ar.position.y - br.end.y + 1, br.position.y - ar.end.y + 1))
	return maxi(dx, dy)


func _box(m: ProdMachine) -> Rect2i:
	var lo: Vector2i = m.footprint[0]
	var hi: Vector2i = m.footprint[0]
	for c: Vector2i in m.footprint:
		lo.x = mini(lo.x, c.x)
		lo.y = mini(lo.y, c.y)
		hi.x = maxi(hi.x, c.x)
		hi.y = maxi(hi.y, c.y)
	return Rect2i(lo, hi - lo + Vector2i.ONE)
