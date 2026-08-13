extends TestCase

const HOUR: int = 400

func _city() -> SocietyReading:
	var r := SocietyReading.new()
	r.day = 1
	r.day_ticks = 9600
	r.outdoor_c = -18.0
	r.homes_total = 5
	r.housing_capacity = 60.0
	r.home_temp_avg = -6.0
	r.coldest_home_c = -6.0
	r.homes_cold = 4
	r.warm_share = 0.2
	r.hearths_lit = 2
	r.kitchens = 3
	r.kitchens_running = 1.0
	r.granaries = 1
	r.food_capacity_per_day = 26.0
	r.food_reserve_days = 0.8
	return r

func _trace(world_seed: int) -> PackedStringArray:
	Rng.reset(world_seed)
	var out := PackedStringArray()
	var s := SocietySystem.new()
	s.setup()
	s.post_setup()
	s.inject_reading(_city())
	var seen: int = 0
	for t: int in range(1, HOUR * 14):
		if t == HOUR:
			s.handle_command({"op": "sign", "law": "care_house"})
		if t == HOUR * 10:
			s.handle_command({"op": "sign", "law": "double_bunks"})
		s.step(t)
		if s.council.demands.size() > seen:
			seen = s.council.demands.size()
			var d: SocietyDemand = s.council.demands[seen - 1]
			out.append("t=%d %s %s %s dl=%d" % [t, d.faction, d.grievance, d.kind, d.deadline_tick])
		if t % (HOUR * 2) == 0:
			out.append("t=%d hope=%.4f disc=%.4f pop=%.4f sick=%.4f gr=%d rngstate=%d" % [
				t, s.hope(), s.discontent(), s.populace.population, s.populace.sick,
				s.council.active_grievance_count(), Rng.stream("society").state])
	return out

func _cmp(tag: String, a: PackedStringArray, b: PackedStringArray) -> void:
	for i: int in maxi(a.size(), b.size()):
		var la: String = a[i] if i < a.size() else "<none>"
		var lb: String = b[i] if i < b.size() else "<none>"
		if la != lb:
			Log.error("diag", "%s DIVERGENCE line %d:\n  A: %s\n  B: %s" % [tag, i, la, lb])
			return
	Log.warn("diag", "%s: no divergence in %d lines" % [tag, a.size()])


func test_diag_sequence() -> void:
	var r1: PackedStringArray = _trace(7)
	var r99: PackedStringArray = _trace(99)
	var r2: PackedStringArray = _trace(7)
	var r3: PackedStringArray = _trace(7)
	_cmp("first-vs-third", r1, r2)
	_cmp("third-vs-fourth", r2, r3)


func test_diag() -> void:
	var a: PackedStringArray = _trace(7)
	var b: PackedStringArray = _trace(7)
	for i: int in maxi(a.size(), b.size()):
		var la: String = a[i] if i < a.size() else "<none>"
		var lb: String = b[i] if i < b.size() else "<none>"
		if la != lb:
			Log.error("diag", "FIRST DIVERGENCE line %d:\n  A: %s\n  B: %s" % [i, la, lb])
			return
	Log.warn("diag", "no divergence in %d lines" % a.size())
