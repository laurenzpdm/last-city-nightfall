extends TestCase

func test_stringname_sort() -> void:
	var a: Array[StringName] = [&"zebra_p06", &"alpha_p06", &"middle_p06"]
	a.sort()
	Log.warn("diag", "plain sort: %s" % str(a))
	var b: Array = [StringName("zzz_%d" % 1), StringName("aaa_%d" % 1), StringName("mmm_%d" % 1)]
	b.sort()
	Log.warn("diag", "dynamic sort: %s" % str(b))
	var d: Dictionary[StringName, int] = {}
	d[StringName("q_dyn_p06")] = 1
	d[StringName("a_dyn_p06")] = 2
	d[StringName("m_dyn_p06")] = 3
	var k: Array = d.keys()
	k.sort()
	Log.warn("diag", "dict keys sort: %s" % str(k))
