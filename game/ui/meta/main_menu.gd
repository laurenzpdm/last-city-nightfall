class_name LcnMainMenu
extends LcnMetaScreen
## [P24] The first thing anybody sees.
##
## It carries the tone or it is a list of buttons in front of a game about a
## dying city. Three decisions:
##
##   * the title is set in the cold ramp with one warm ember behind it, because
##     that is the whole game in one image: a cold plain, one fire;
##   * the line under it is small writing from Caldera Nine, in [P22]'s register
##     — a concrete fact about a real place, never a tagline. "Survive the
##     endless night" would fit any frozen city in any game, which is the test
##     [P22] applies to its own lines and the one applied here;
##   * "Continue" is first and tells you what you are continuing — day, souls
##     and when you left it. A main menu that makes you open a browser to find
##     out which save is newest has failed at its only real job.

## Deliberately not chosen with Rng: this is the menu, and nothing here may
## touch a simulation stream. Picked from the wall clock, which the sim never
## reads.
const LINES: Array[String] = [
	"The Hearth has not gone out in nine years. Nobody says this out loud.",
	"Kettle Row keeps a lamp lit at both ends so the watch can count them.",
	"There is a ledger in the Survey Hall with a column nobody wanted to rule.",
	"The rim road is passable until it isn't, and nobody agrees on when that is.",
	"Whatever comes in off the plain at night comes for the warmth first.",
	"The second boiler has a warm side, and the whole city knows which side it is.",
]

var _line: String = ""
var _continue_slot: String = ""


func _init() -> void:
	# GDScript does not call a base _init() when the subclass declares one, and
	# without this the list this screen draws is null.
	super()
	screen_id = &"main"
	# The name of the game is drawn above the plate by draw_extra(), so the plate
	# itself carries no title and reserves no band for one.
	title = ""
	subtitle = ""
	opaque = true
	panel_width = 0.34
	# The name of the game is drawn ABOVE the plate, so the plate reserves no
	# room for a title it does not draw.
	head_lines = 0.9
	footer = "↑↓ move   Enter select"
	_line = LINES[int(Time.get_unix_time_from_system()) % LINES.size()]


func refresh() -> void:
	var recent: Dictionary = LcnSaveManager.most_recent()
	_continue_slot = String(recent.get("slot", ""))
	var rows: Array[Dictionary] = []
	if _continue_slot != "":
		rows.append({
			"kind": LcnMetaList.Kind.ACTION, "id": &"continue", "label": "Continue",
			"hint": "%s  ·  %s" % [
				String(recent.get("name", _continue_slot)),
				LcnSaveManager.describe_slot(recent)],
		})
	rows.append({"kind": LcnMetaList.Kind.ACTION, "id": &"new", "label": "A new city",
		"hint": "Caldera Nine, the morning of the first day"})
	rows.append({"kind": LcnMetaList.Kind.ACTION, "id": &"load", "label": "Load a city",
		"enabled": LcnSaveManager.has_any()})
	rows.append({"kind": LcnMetaList.Kind.ACTION, "id": &"settings", "label": "Settings"})
	rows.append({"kind": LcnMetaList.Kind.ACTION, "id": &"quit", "label": "Leave"})
	list.set_rows(rows)
	relayout()


func _on_row_activated(id: StringName) -> void:
	match id:
		&"continue":
			request_screen.emit(&"__continue", {"slot": _continue_slot})
		&"new":
			request_screen.emit(&"__new_game", {})
		&"load":
			request_screen.emit(&"saves", {"mode": "load"})
		&"settings":
			request_screen.emit(&"settings", {})
		&"quit":
			request_screen.emit(&"confirm", {
				"title": "Leave Caldera Nine",
				"body": "The city keeps no record of who was here.",
				"confirm": "Leave", "cancel": "Stay", "action": "quit_game"})


## The title block, drawn above the panel rather than in it. The panel holds the
## choices; the name of the game is not a choice.
func draw_extra(panel: Rect2) -> void:
	var cx: float = size.x * 0.5
	var base: float = panel.position.y - float(style.fs(LcnMetaStyle.FS_TITLE)) * 1.1
	# One ember behind the word, the only warm thing on the screen.
	var glow: float = 0.30 + 0.06 * style.pulse(0.7)
	var r: float = float(style.fs(LcnMetaStyle.FS_TITLE)) * 2.6
	draw_circle(Vector2(cx, base - float(style.fs(LcnMetaStyle.FS_TITLE)) * 0.55), r,
		Color(LcnMetaStyle.P.EMBER.r, LcnMetaStyle.P.EMBER.g, LcnMetaStyle.P.EMBER.b, glow * 0.14))
	draw_circle(Vector2(cx, base - float(style.fs(LcnMetaStyle.FS_TITLE)) * 0.55), r * 0.45,
		Color(LcnMetaStyle.P.WARM_EDGE.r, LcnMetaStyle.P.WARM_EDGE.g, LcnMetaStyle.P.WARM_EDGE.b, glow * 0.20))
	style.text_centre(self, cx, base - float(style.fs(LcnMetaStyle.FS_TITLE)) * 1.05,
		"LAST CITY", LcnMetaStyle.FS_TITLE, LcnMetaStyle.P.SNOW_LIT)
	style.text_centre(self, cx, base, "NIGHTFALL", LcnMetaStyle.FS_TITLE, LcnMetaStyle.P.WARM_EDGE)
	style.text_centre(self, cx, base + float(style.fs(LcnMetaStyle.FS_BODY)) * 2.2,
		_line, LcnMetaStyle.FS_BODY, style.ink_dim())
	# Version, bottom right, small. A build a critic is looking at should say
	# which build it is.
	style.text_right(self, size.x - 24.0, size.y - 18.0,
		"%s  ·  %s" % [
			String(ProjectSettings.get_setting("application/config/version", "0.0.0")),
			LcnSteamSeam.platform_line()],
		LcnMetaStyle.FS_SMALL, style.ink_faint())
