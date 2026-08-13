extends Node
## Probe 2: which emission-point texture format works in gl_compatibility?

var _f: int = 0
var _nodes: Array[GPUParticles2D] = []
var _labels: Array[String] = []


func _make(fmt: int, label: String, at: Vector2) -> void:
	var img: Image = Image.create(8, 8, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 1, 1, 1))
	var tex: ImageTexture = ImageTexture.create_from_image(img)
	var pts: Image = Image.create(4, 1, false, fmt)
	pts.set_pixel(0, 0, Color(-120.0, -60.0, 0.0, 1.0))
	pts.set_pixel(1, 0, Color(-40.0, 0.0, 0.0, 1.0))
	pts.set_pixel(2, 0, Color(40.0, 60.0, 0.0, 1.0))
	pts.set_pixel(3, 0, Color(120.0, -30.0, 0.0, 1.0))
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_POINTS
	m.emission_point_count = 4
	m.emission_point_texture = ImageTexture.create_from_image(pts)
	m.gravity = Vector3(0, -30, 0)
	m.color = Color(1, 1, 1, 1)
	m.set_param_min(ParticleProcessMaterial.PARAM_SCALE, 4.0)
	m.set_param_max(ParticleProcessMaterial.PARAM_SCALE, 4.0)
	var q := GPUParticles2D.new()
	q.amount = 120
	q.lifetime = 2.0
	q.preprocess = 1.5
	q.texture = tex
	q.process_material = m
	q.position = at
	q.local_coords = false
	q.emitting = true
	add_child(q)
	_nodes.append(q)
	_labels.append(label)


func _ready() -> void:
	_make(Image.FORMAT_RGBF, "RGBF", Vector2(400, 300))
	_make(Image.FORMAT_RGBAF, "RGBAF", Vector2(960, 300))
	_make(Image.FORMAT_RGBAH, "RGBAH", Vector2(1500, 300))
	# control: box emitter far below
	var img: Image = Image.create(8, 8, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 1, 1, 1))
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	m.emission_sphere_radius = 60.0
	m.gravity = Vector3.ZERO
	m.set_param_min(ParticleProcessMaterial.PARAM_SCALE, 4.0)
	m.set_param_max(ParticleProcessMaterial.PARAM_SCALE, 4.0)
	var q := GPUParticles2D.new()
	q.amount = 120
	q.lifetime = 2.0
	q.preprocess = 1.5
	q.texture = ImageTexture.create_from_image(img)
	q.process_material = m
	q.position = Vector2(960, 800)
	q.local_coords = false
	q.emitting = true
	add_child(q)
	_nodes.append(q)
	_labels.append("SPHERE-control")


func _process(_d: float) -> void:
	_f += 1
	if _f < 40:
		return
	set_process(false)
	await RenderingServer.frame_post_draw
	var im: Image = get_viewport().get_texture().get_image()
	for i: int in _nodes.size():
		var c: Vector2 = _nodes[i].position
		var lit: int = 0
		for y: int in range(maxi(0, int(c.y) - 200), mini(im.get_height(), int(c.y) + 200), 2):
			for x: int in range(maxi(0, int(c.x) - 250), mini(im.get_width(), int(c.x) + 250), 2):
				if im.get_pixel(x, y).r > 0.3:
					lit += 1
		print("PROBE %-16s lit=%d" % [_labels[i], lit])
	get_tree().quit(0)
