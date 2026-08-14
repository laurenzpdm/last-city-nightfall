class_name LcnAudioSettings
extends LcnMetaScreen
## [P24] The four sliders the player owns.
##
## [P23] already built the desk: `LcnAudioMixer` creates the bus graph in code
## and polls `Settings.audio` for master / music / ambience / sfx. So this screen
## writes those four numbers and nothing else — it does not touch AudioServer,
## because two things setting the same gain is how a mix ends up depending on
## which one ran last.
##
## `tests/meta/test_settings_reach_the_game.gd` proves the wire is live: it moves
## the slider, ticks the mixer, and reads the bus volume back off AudioServer.

const KEYS: Array[StringName] = [&"master", &"music", &"ambience", &"sfx"]
const LABELS: Dictionary[StringName, String] = {
	&"master": "Everything",
	&"music": "Music",
	&"ambience": "Wind and the city",
	&"sfx": "Machines and guns",
}


func _init() -> void:
	# GDScript does not call a base _init() when the subclass declares one, and
	# without this the list this screen draws is null.
	super()
	screen_id = &"audio"
	title = "SOUND"
	panel_width = 0.44


func refresh() -> void:
	var s: Node = _settings()
	if s == null:
		return
	var rows: Array[Dictionary] = []
	for key: StringName in KEYS:
		var v: float = float(s.call("get_value", "audio", String(key), 0.8))
		rows.append({"kind": LcnMetaList.Kind.SLIDER, "id": key,
			"label": LABELS.get(key, String(key)),
			"min": 0.0, "max": 1.0, "step": 0.05, "value": v,
			"value_text": "off" if v <= 0.0 else "%d%%" % int(round(v * 100.0))})
	rows.append({"kind": LcnMetaList.Kind.NOTE, "id": &"note",
		"label": "A critical alert ducks music and ambience by itself. That is the game talking, and it is applied on top of these, never instead of them."})
	list.set_rows(rows)
	relayout()


func _on_row_changed(id: StringName, value: Variant) -> void:
	var s: Node = _settings()
	if s == null:
		return
	s.call("set_value", "audio", String(id), float(value))
	s.call("save_to_disk")
	refresh()


func _settings() -> Node:
	if not is_inside_tree():
		return null
	return get_tree().root.get_node_or_null(NodePath("Settings"))
