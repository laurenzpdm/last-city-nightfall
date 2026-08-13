extends SceneTree
var _done: bool = false
func _process(_d: float) -> bool:
	if _done: return true
	_done = true
	load("res://tests/logistics/_mapdump_body.gd").new().call("run")
	quit(0)
	return true
