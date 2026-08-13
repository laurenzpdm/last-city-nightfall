extends Node

func _ready() -> void:
	var cam := GameCamera.new()
	cam.edge_scroll_allowed = false
	cam.name = "GameCamera"
	add_child(cam)
	await get_tree().process_frame
	await get_tree().process_frame
	cam.set_zoom_level(1.0, false)
	cam.focus_on(Vector2.ZERO, true)
	cam._process(1.0/60.0)
	print("vs=", cam._viewport_size(), " rigvs=", cam.rig.viewport_size, " zoom=", cam.rig.zoom, " pos=", cam.rig.position, " bounds=", cam.rig.world_bounds)
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_MIDDLE
	e.position = Vector2(600, 400); e.global_position = e.position; e.pressed = true
	get_viewport().push_input(e)
	print("after press dragging=", cam.rig.is_dragging(), " anchor=", cam.rig._drag_anchor_world, " pos=", cam.rig.position)
	var m := InputEventMouseMotion.new()
	m.position = Vector2(700, 460); m.global_position = m.position; m.relative = Vector2(100, 60)
	get_viewport().push_input(m)
	print("after motion pos=", cam.rig.position, " rigvs=", cam.rig.viewport_size)
	cam._process(1.0/60.0)
	print("after tick pos=", cam.rig.position)
	get_tree().quit(0)
