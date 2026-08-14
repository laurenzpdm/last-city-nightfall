class_name LcnTutorialRoot
extends CanvasLayer
## [P21] The first twenty minutes. The cold does the teaching.
##
## `game/boot.gd` installs this the moment the file exists (LcnLayers.PENDING)
## and puts it on layer 80, the MODAL slot. It is not a modal. Nothing here ever
## pauses the simulation, dims the world, or puts a wall of text in front of a
## city that is freezing while the player reads it — that is the failure mode
## this part was written against.
##
## WHAT IT ACTUALLY IS: one strip along the bottom of the screen carrying a
## pressure, the smallest action that relieves it, and the meters that move
## while the player performs it. It retires a lesson when the SIMULATION says
## the lesson is over: `networks <= 1`, `rations_made >= 1`,
## `line_fed_burners >= 1`. There is no timer anywhere in this part and
## `LcnTutorialLesson` has no field that could express one.
##
## THE FOUR PILLARS, in the order the game needs them, each taught by something
## that happens rather than something that is said:
##
##   1. HEAT REACHES ONLY WHERE PIPES REACH — the opening settlement stands on
##      three heat networks. Twenty-three seconds in, the two structures that
##      are not on the mains freeze, by themselves, on camera.
##   2. CITIZENS NEED WARMTH AND FOOD — the larder came in on the column and
##      nothing in the city makes another meal. The number falls while you read.
##   3. SOMETHING COMES AT NIGHT — the wave clock is already running when the
##      player arrives, and the one turret they were given is stone cold.
##   4. YOU AUTOMATE BECAUSE YOU CANNOT CLICK FAST ENOUGH — ten porters carry
##      coal by hand all day and the pile has a countdown on it.
##
## SKIPPABLE, RESUMABLE, AND SILENT IN A HARNESS RUN. Skip is a real button on
## the strip, it writes to `user://tutorial.cfg`, and a lesson already taught is
## never taught again. `Harness.active` stands the whole part down before it
## builds anything, so `--visual` scenario runs and every screenshot the art
## parts grade against are unchanged by this file.
##
## INPUT: mouse only, on real Buttons, exactly like [P22]'s event card and for
## the same reason — every key on the keyboard is claimed by somebody in
## `LcnLayers`, F1 included (it is a lens, whatever the PENDING row says), and a
## guide that quietly ate a hotkey would be a worse bug than no guide at all.

const GROUP: StringName = &"lcn_tutorial"
const LAYER: int = 80

const MARGIN: float = 26.0
const PAD: float = 18.0
const MAX_WIDTH: float = 720.0
const MIN_WIDTH: float = 380.0
const REFRESH_SECONDS: float = 0.25

## Colours live here rather than in [P13]'s palette on purpose: this part must
## keep compiling on a launch where another part is mid-edit, and boot loads it
## by path so a compile failure would silently cost the player the whole guide.
## Same reasoning, same numbers as game/narrative/narrative_card.gd.
const PLATE: Color = Color(0.043, 0.055, 0.086, 0.94)
const EDGE: Color = Color(0.62, 0.42, 0.22, 0.85)
const INK: Color = Color(0.94, 0.93, 0.90)
const INK_DIM: Color = Color(0.74, 0.76, 0.80)
const INK_FAINT: Color = Color(0.58, 0.62, 0.70)
const KICKER: Color = Color(0.78, 0.55, 0.30)
const ACTION: Color = Color(0.86, 0.80, 0.62)
const RULE: Color = Color(0.35, 0.30, 0.24, 0.7)
const MARK: Color = Color(0.90, 0.58, 0.28)

## True when this part is running at all. False in a harness run.
var active: bool = false

var course: LcnTutorialCourse = null
var facts: LcnTutorialFacts = null
var memory: LcnTutorialMemory = null

## The two controls the player can actually press. Public so the reachability
## suite can click them at real screen coordinates instead of reaching past the
## interface and calling a private method.
var skip_button: Button = null
var fold_button: Button = null

var collapsed: bool = false

var _root: Control = null
var _panel: PanelContainer = null
var _column: VBoxContainer = null
var _kicker: Label = null
var _headline: Label = null
var _body: Label = null
var _action: Label = null
var _strip: Label = null
var _folded: Label = null
var _marker: Control = null
var _buttons: HBoxContainer = null

var _accum: float = 0.0
var _signature: String = ""
var _camera: Node = null
var _camera_poll: float = 0.0
var _bound: bool = false
var _begun: bool = false


func _init() -> void:
	# Name and layer in _init, not _ready: boot audits canvas layers over a tree
	# that may contain a node which has not been notified yet, and a node that
	# only names itself once it is ready is a node the table cannot see.
	name = "LcnTutorial"
	layer = LAYER


func _ready() -> void:
	name = "LcnTutorial"
	layer = LAYER
	add_to_group(GROUP)
	# The guide has to stay readable while the player pauses to think, and the
	# player WILL pause: the first lesson is a construction job under a clock.
	process_mode = Node.PROCESS_MODE_ALWAYS

	if Harness.active:
		# A scripted run has no hands and no beginner. Every scenario replay and
		# every screenshot the art parts grade against must be byte-identical
		# with and without this file in the build.
		Log.info("tutorial", "harness run — the guide stands down before it draws anything")
		visible = false
		return

	memory = LcnTutorialMemory.new()
	memory.load_from_disk()
	facts = LcnTutorialFacts.new()
	course = LcnTutorialCourse.new(memory)
	course.load_lessons()
	active = true

	_build()
	Bus.world_ready.connect(_on_world_ready)
	if Sim.alive:
		_on_world_ready()
	Log.info("tutorial", "installed on layer %d — %d lesson(s), %s, reads %s" % [
		LAYER, course.size(),
		"skipped by the player" if memory.skipped else "%d already taught" % memory.taught.size(),
		facts.source_list()])


func _exit_tree() -> void:
	if Bus.world_ready.is_connected(_on_world_ready):
		Bus.world_ready.disconnect(_on_world_ready)


## Binds to the new world but does NOT open a lesson yet: this signal is emitted
## from inside `Sim.create_world()`, before boot has seeded a single building.
## The course begins on the first refresh where the fact table will answer.
func _on_world_ready() -> void:
	facts.bind()
	_bound = true
	_begun = false
	_signature = ""
	_refresh()


func _begin_if_ready() -> void:
	if _begun or not facts.ready_to_answer:
		return
	_begun = true
	course.begin(facts)
	if course.finished():
		Log.info("tutorial", "nothing left to teach: this city already answers every lesson")
	else:
		Log.info("tutorial", "opening on '%s' (%d of %d), reads %s" % [
			String(course.current_id()), course.position(), course.size(),
			facts.source_list()])


# =========================================================================
#  public surface
# =========================================================================

## True when a lesson is on screen right now.
func is_showing() -> bool:
	return active and _begun and not memory.skipped and not course.finished() \
		and _panel != null and _panel.visible


func current_id() -> StringName:
	return course.current_id() if active else &""


## The strip's rectangle in screen coordinates, empty when nothing is drawn.
## The suite uses it to prove the guide does not cover the city.
func panel_rect() -> Rect2:
	if _panel == null or not _panel.visible:
		return Rect2()
	return _panel.get_global_rect()


## Puts the guide away for good and records it. Same path the Skip button takes.
func skip() -> void:
	if not active:
		return
	memory.set_skipped(true)
	Log.info("tutorial", "skipped by the player at '%s'" % String(course.current_id()))
	_refresh()


## Clears the record and starts the course over from the first lesson this city
## has not already answered.
func restart() -> void:
	if not active:
		return
	memory.forget_everything()
	facts.read()
	course.begin(facts)
	_begun = facts.ready_to_answer
	collapsed = false
	_signature = ""
	_refresh()


func set_collapsed(on: bool) -> void:
	collapsed = on
	_signature = ""
	_refresh()


# =========================================================================
#  the strip
# =========================================================================

func _build() -> void:
	_root = Control.new()
	_root.name = "Root"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	# The guide never eats a click meant for the city. Only the two Buttons do.
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_marker = Control.new()
	_marker.name = "Marker"
	_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_marker.set_anchors_preset(Control.PRESET_FULL_RECT)
	_marker.draw.connect(_draw_marker)
	_root.add_child(_marker)

	_panel = PanelContainer.new()
	_panel.name = "Guide"
	_panel.add_theme_stylebox_override("panel", _plate())
	_panel.mouse_filter = Control.MOUSE_FILTER_PASS
	_root.add_child(_panel)

	var pad := MarginContainer.new()
	for side: String in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, int(PAD))
	_panel.add_child(pad)

	_column = VBoxContainer.new()
	_column.add_theme_constant_override("separation", 7)
	pad.add_child(_column)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	_column.add_child(head)
	_kicker = _label("", 12, KICKER)
	_kicker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_kicker)
	_buttons = HBoxContainer.new()
	_buttons.add_theme_constant_override("separation", 6)
	head.add_child(_buttons)
	fold_button = _button("Hide", _on_fold_pressed)
	_buttons.add_child(fold_button)
	skip_button = _button("Skip the guide", _on_skip_pressed)
	_buttons.add_child(skip_button)

	_headline = _label("", 21, INK)
	_column.add_child(_headline)
	_body = _label("", 14, INK_DIM)
	_column.add_child(_body)
	_action = _label("", 14, ACTION)
	_column.add_child(_action)
	_column.add_child(_rule())
	_strip = _label("", 12, INK_FAINT)
	_column.add_child(_strip)

	_folded = _label("", 12, INK_FAINT)
	_folded.name = "Folded"
	_folded.visible = false
	_column.add_child(_folded)


func _process(delta: float) -> void:
	if not active:
		return
	_camera_poll -= delta
	if _camera == null and _camera_poll <= 0.0:
		_camera_poll = 0.5
		_camera = _find_camera(get_tree().root, 0)
	_accum += delta
	if _accum < REFRESH_SECONDS:
		return
	_accum = 0.0
	_refresh()


func _refresh() -> void:
	if not active or _panel == null:
		return
	if not Sim.alive or not _bound:
		_panel.visible = false
		_marker.visible = false
		return
	if memory.skipped:
		_panel.visible = false
		_marker.visible = false
		return
	# READ FIRST, ASK AFTER. `course.finished()` is true before `begin()` has
	# ever run, because the queue starts at -1 — so testing it here cost the
	# whole part a run: the guide returned before it ever read the simulation,
	# never opened a lesson, and every check in tests/tutorial that depends on a
	# live fact went red with a zero.
	facts.read()
	_begin_if_ready()
	if not _begun or course.finished():
		_panel.visible = false
		_marker.visible = false
		return
	if course.advance(facts):
		_signature = ""
		if course.finished():
			Log.info("tutorial", "the course is over — every lesson answered by the city")
			_panel.visible = false
			_marker.visible = false
			return
	_panel.visible = true
	var lesson: LcnTutorialLesson = course.current_lesson()
	if lesson == null:
		_panel.visible = false
		return
	# The strip is rebuilt only when the lesson or the shown text changes. The
	# live numbers move several times a second and rebuilding Buttons underneath
	# a player's cursor is how a click on Skip gets eaten.
	var sig: String = "%s|%d|%s" % [String(lesson.id), 1 if collapsed else 0, _strip_text(lesson)]
	if sig != _signature:
		_signature = sig
		_paint(lesson)
	_layout()
	_marker.visible = not collapsed
	_marker.queue_redraw()


func _paint(lesson: LcnTutorialLesson) -> void:
	_kicker.text = "%s   %d of %d" % [
		lesson.kicker.to_upper() if lesson.kicker != "" else "THE GUIDE",
		course.position(), course.size()]
	var showing: bool = not collapsed
	_headline.visible = showing
	_body.visible = showing
	_action.visible = showing
	_strip.visible = showing and _strip_text(lesson) != ""
	_folded.visible = not showing
	fold_button.text = "Hide" if showing else "Show"
	skip_button.visible = showing
	if not showing:
		_folded.text = lesson.headline
		return
	_headline.text = lesson.headline
	_body.text = facts.fill(lesson.body)
	_action.text = facts.fill(lesson.action) if not lesson.final_card else ""
	_action.visible = _action.text != ""
	_strip.text = _strip_text(lesson)
	skip_button.text = "Close" if lesson.final_card else "Skip the guide"


## "networks 3   frozen 2   outside -27 C" — the meters that move while the
## player works, so the lesson is provably about the city and not about itself.
func _strip_text(lesson: LcnTutorialLesson) -> String:
	if collapsed:
		return ""
	var out: PackedStringArray = PackedStringArray()
	for key: StringName in lesson.watch:
		out.append("%s %s" % [facts.label_of(key), facts.value_text(key, facts.fact(key))])
	return "     ".join(out)


func _layout() -> void:
	var size: Vector2 = Vector2(get_viewport().get_visible_rect().size)
	if size.x <= 0.0:
		return
	var width: float = clampf(size.x * 0.44, MIN_WIDTH, MAX_WIDTH)
	width = minf(width, size.x - MARGIN * 2.0)
	_panel.custom_minimum_size = Vector2(width, 0.0)
	_panel.size = Vector2(width, _panel.get_combined_minimum_size().y)
	for l: Label in [_headline, _body, _action, _strip, _folded]:
		l.custom_minimum_size = Vector2(width - PAD * 2.0, 0.0)
	# Bottom centre. [P17] owns the four corners — stocks bottom left, selection
	# bottom right, clock top centre — and [P22]'s card sits at 0.22 of the
	# height. This is the one band of screen nobody else has claimed, and it is
	# where a player's eye already is when they are placing a building.
	_panel.position = Vector2(
		roundf((size.x - width) * 0.5),
		roundf(size.y - _panel.size.y - MARGIN))
	_marker.size = size


# =========================================================================
#  the marker
# =========================================================================

## A ring around the thing the lesson is about. Drawn in SCREEN space from a
## projected world position — this canvas must never set follow_viewport_enabled
## on layer 80, because `LcnLayers.violations()` correctly treats a world-space
## canvas above the HUD as the bug that painted FROZEN badges across the clock.
func _draw_marker() -> void:
	if collapsed or not is_showing():
		return
	var lesson: LcnTutorialLesson = course.current_lesson()
	if lesson == null or String(lesson.focus) == "":
		return
	if not facts.focus_cells.has(lesson.focus):
		return
	if _camera == null or not _camera.has_method(&"world_to_screen"):
		return
	var cell: Vector2i = facts.focus_cells[lesson.focus]
	var world: Vector2 = Vector2(cell) * 32.0 + Vector2(16.0, 16.0)
	var at: Vector2 = _camera.call(&"world_to_screen", world)
	var view: Rect2 = Rect2(Vector2.ZERO, _marker.size)
	if not view.grow(-8.0).has_point(at):
		return
	# Deliberately quiet: a hairline ring and four ticks. A beginner's screen is
	# already carrying a HUD, a lens legend and an event card.
	var r: float = 26.0
	_marker.draw_arc(at, r, 0.0, TAU, 40, Color(MARK.r, MARK.g, MARK.b, 0.75), 1.5)
	_marker.draw_arc(at, r + 5.0, 0.0, TAU, 40, Color(MARK.r, MARK.g, MARK.b, 0.18), 1.0)
	for dir: Vector2 in [Vector2.UP, Vector2.DOWN, Vector2.LEFT, Vector2.RIGHT]:
		_marker.draw_line(at + dir * (r - 6.0), at + dir * (r + 6.0),
			Color(MARK.r, MARK.g, MARK.b, 0.85), 1.5)


func _find_camera(node: Node, depth: int) -> Node:
	if depth > 6:
		return null
	if node.has_method(&"world_to_screen") and node is Node2D:
		return node
	for child: Node in node.get_children():
		var found: Node = _find_camera(child, depth + 1)
		if found != null:
			return found
	return null


# =========================================================================
#  buttons
# =========================================================================

func _on_skip_pressed() -> void:
	var lesson: LcnTutorialLesson = course.current_lesson()
	if lesson != null and lesson.final_card:
		course.dismiss_current(facts)
		_signature = ""
		_refresh()
		return
	skip()


func _on_fold_pressed() -> void:
	set_collapsed(not collapsed)


# =========================================================================
#  small builders
# =========================================================================

func _label(text: String, size: int, colour: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", colour)
	return l


func _button(text: String, handler: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", 12)
	b.pressed.connect(handler)
	return b


func _rule() -> Control:
	var r := ColorRect.new()
	r.color = RULE
	r.custom_minimum_size = Vector2(0.0, 1.0)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


func _plate() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = PLATE
	sb.border_color = EDGE
	sb.set_border_width_all(1)
	sb.border_width_left = 3
	sb.set_corner_radius_all(2)
	return sb
