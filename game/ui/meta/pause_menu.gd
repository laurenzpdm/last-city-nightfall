class_name LcnPauseMenu
extends LcnMetaScreen
## [P24] The pause menu. Opened with Esc when nothing else is open.
##
## It says where the city is — day, souls, the hour — because a player who
## opened this menu has usually been away from the machine and the first thing
## they need is not a list of buttons.
##
## Everything that destroys something asks first: overwriting a save, abandoning
## the run, leaving the game. Everything that does not, does not — "Resume" and
## "Save" are one keypress, and a menu that confirms harmless things trains the
## player to confirm the harmful one without reading it.


func _init() -> void:
	# GDScript does not call a base _init() when the subclass declares one, and
	# without this the list this screen draws is null.
	super()
	screen_id = &"pause"
	title = "PAUSED"
	panel_width = 0.34


func enter(args: Dictionary) -> void:
	super.enter(args)


func refresh() -> void:
	subtitle = _where_we_are()
	var rows: Array[Dictionary] = []
	rows.append({"kind": LcnMetaList.Kind.ACTION, "id": &"resume", "label": "Back to it"})
	rows.append({"kind": LcnMetaList.Kind.ACTION, "id": &"save", "label": "Save the city"})
	rows.append({"kind": LcnMetaList.Kind.ACTION, "id": &"load", "label": "Load a city",
		"enabled": LcnSaveManager.has_any()})
	rows.append({"kind": LcnMetaList.Kind.ACTION, "id": &"settings", "label": "Settings"})
	rows.append({"kind": LcnMetaList.Kind.ACTION, "id": &"title", "label": "Leave for the title"})
	rows.append({"kind": LcnMetaList.Kind.ACTION, "id": &"quit", "label": "Leave the game"})
	list.set_rows(rows)
	relayout()


func _where_we_are() -> String:
	if not Sim.alive:
		return "no city"
	var head: Dictionary = LcnSaveManager.describe_world()
	return "day %d · %s · %d alive" % [
		int(head.get("day", 1)), String(head.get("phase", "")), int(head.get("population", 0))]


func _on_row_activated(id: StringName) -> void:
	match id:
		&"resume":
			request_close.emit()
		&"save":
			request_screen.emit(&"saves", {"mode": "save"})
		&"load":
			request_screen.emit(&"saves", {"mode": "load"})
		&"settings":
			request_screen.emit(&"settings", {})
		&"title":
			request_screen.emit(&"confirm", {
				"title": "Leave for the title",
				"body": "Anything since the last save stays here, which is to say it does not.",
				"confirm": "Leave", "cancel": "Stay", "action": "to_title"})
		&"quit":
			request_screen.emit(&"confirm", {
				"title": "Leave the game",
				"body": "Anything since the last save stays here, which is to say it does not.",
				"confirm": "Leave", "cancel": "Stay", "action": "quit_game"})
