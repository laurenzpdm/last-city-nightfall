class_name LcnPostProcess
extends CanvasLayer
## Full-screen colour grade and post stack. [P13]
##
## Sits on its own CanvasLayer above the world so the night CanvasModulate does
## not tint it. A BackBufferCopy immediately below the full-rect guarantees the
## screen texture is populated on the GL Compatibility renderer, which is the
## renderer this project ships with.
##
## Everything is driven from the LcnPalette grade for the current hour, then
## scaled by Settings.graphics so a player on a weak machine (or with motion
## sensitivity) can turn any single effect off without losing the art direction.

const SHADER_PATH: String = "res://game/view/render/post_process.gdshader"

var rect: ColorRect = null
var material: ShaderMaterial = null
var enabled: bool = true

var _copy: BackBufferCopy = null
var _compiled: bool = false
var _heat_bound: bool = false


func setup() -> void:
	layer = 60

	_copy = BackBufferCopy.new()
	_copy.name = "ScreenCopy"
	_copy.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	add_child(_copy)

	var shader: Shader = load(SHADER_PATH)
	if shader == null:
		Log.error("render", "post shader missing at %s — running ungraded" % SHADER_PATH)
		enabled = false
		return
	material = ShaderMaterial.new()
	material.shader = shader

	rect = ColorRect.new()
	rect.name = "PostRect"
	rect.material = material
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.color = Color(0, 0, 0, 1)
	add_child(rect)
	# An unbound sampler in a canvas shader reads as white, which would put a
	# heat shimmer over the entire frame. Bind black until the ground says
	# otherwise.
	var black: Image = Image.create(1, 1, false, Image.FORMAT_RGBA8)
	black.fill(Color(0, 0, 0, 1))
	material.set_shader_parameter("heat_tex", ImageTexture.create_from_image(black))
	material.set_shader_parameter("shimmer_amount", 0.0)
	_compiled = true


## Binds the ground's heat field so the post stack can put a shimmer over hot
## air. Without it `shimmer_amount` stays at zero and the pass is a no-op.
func bind_heat_field(tex: Texture2D, map_px: Vector2) -> void:
	if material == null:
		return
	_heat_bound = tex != null
	material.set_shader_parameter("heat_tex", tex)
	material.set_shader_parameter("map_px", map_px)


## Pushes the hour's grade into the shader. `temperature` shifts the cold
## chromatic split, so a freezing frame literally looks colder than a warm one.
## `view` is the visible world rect, which is how the shimmer knows where the
## hot air is on screen.
func apply(grade: Dictionary, temperature: float, viewport_size: Vector2,
		view: Rect2 = Rect2()) -> void:
	if not _compiled or material == null:
		return
	material.set_shader_parameter("view_origin", view.position)
	material.set_shader_parameter("view_size", view.size)
	# Hot air over snow at -30 C shimmers hard; over a mild afternoon it barely
	# does. Scaling by cold is both true and a free readability cue.
	var shimmer_on: float = 1.0 if bool(Settings.graphics.get("shimmer", true)) else 0.0
	material.set_shader_parameter("shimmer_amount",
		(1.6 if _heat_bound else 0.0) * shimmer_on
		* clampf(inverse_lerp(-5.0, -35.0, temperature), 0.25, 1.0))
	var g: Dictionary = Settings.graphics
	var on: bool = bool(g.get("post_process", true))
	visible = on and enabled
	if not visible:
		return

	var bloom_on: float = 1.0 if bool(g.get("bloom", true)) else 0.0
	var grain_on: float = 1.0 if bool(g.get("grain", true)) else 0.0
	var vignette_on: float = 1.0 if bool(g.get("vignette", true)) else 0.0
	var chroma_on: float = 1.0 if bool(g.get("chromatic", true)) else 0.0
	# Colder than -30C and the frame starts to separate at the edges.
	var cold: float = clampf(inverse_lerp(-15.0, -55.0, temperature), 0.0, 1.0)

	material.set_shader_parameter("grade_lift", _v3(grade["lift"]))
	material.set_shader_parameter("grade_gain", _v3(grade["gain"]))
	material.set_shader_parameter("saturation", float(grade["sat"]))
	material.set_shader_parameter("bloom_strength", float(grade["bloom"]) * bloom_on * 0.85)
	material.set_shader_parameter("bloom_threshold", 0.50)
	material.set_shader_parameter("vignette_strength", 0.52 * vignette_on)
	material.set_shader_parameter("grain_strength", 0.038 * grain_on)
	material.set_shader_parameter("chroma_strength", float(grade["chroma"]) * (0.25 + cold) * chroma_on)
	material.set_shader_parameter("fog_color", _v3(grade["fog"]))
	material.set_shader_parameter("fog_amount", float(grade["fog_amt"]))
	# SimClock time, not wall time: two replays of a scenario grain identically,
	# so a screenshot diff only ever shows a real change.
	material.set_shader_parameter("time_s", SimClock.seconds())
	material.set_shader_parameter("screen_px", viewport_size)


static func _v3(c: Color) -> Vector3:
	return Vector3(c.r, c.g, c.b)
