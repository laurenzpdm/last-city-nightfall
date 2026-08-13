extends Node
## User configuration. Owned by [P24] meta. Other parts read, never write.

const PATH: String = "user://settings.cfg"

var graphics: Dictionary = {
	"bloom": true, "grain": true, "snow_density": 1.0,
	"screen_shake": 1.0, "vsync": true, "ui_scale": 1.0,
}
var accessibility: Dictionary = {
	"colorblind_mode": "off", "reduce_motion": false,
	"high_contrast_overlays": false, "font_scale": 1.0, "hold_to_confirm": false,
}
var audio: Dictionary = {"master": 0.9, "music": 0.7, "sfx": 0.9, "ambience": 0.8}
var gameplay: Dictionary = {"edge_scroll": true, "autosave_minutes": 5, "tooltip_delay": 0.35}


func _ready() -> void:
	load_from_disk()


func get_value(section: String, key: String, fallback: Variant = null) -> Variant:
	var d: Dictionary = get(section) if section in self else {}
	return d.get(key, fallback)


func set_value(section: String, key: String, value: Variant) -> void:
	if not (section in self):
		return
	var d: Dictionary = get(section)
	d[key] = value
	if section == "graphics" and key == "ui_scale":
		Bus.ui_scale_changed.emit(float(value))


func load_from_disk() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return
	for section: String in ["graphics", "accessibility", "audio", "gameplay"]:
		if not cfg.has_section(section):
			continue
		var d: Dictionary = get(section)
		for key: String in cfg.get_section_keys(section):
			d[key] = cfg.get_value(section, key)


func save_to_disk() -> void:
	var cfg := ConfigFile.new()
	for section: String in ["graphics", "accessibility", "audio", "gameplay"]:
		var d: Dictionary = get(section)
		for key: String in d:
			cfg.set_value(section, key, d[key])
	cfg.save(PATH)
