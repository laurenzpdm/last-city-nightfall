class_name LcnUiStore
extends RefCounted
## [P18] "Every panel remembers state" — this is where it remembers it.
##
## Deliberately NOT in Settings: `game/core/settings.gd` belongs to [P24] and
## every part is told to read it and never write it. Panel geometry, pinned
## buildings and the last thing typed into a search box are this part's own
## business, so they live in this part's own file.
##
## Writes are debounced through `mark_dirty()` + `flush()`: dragging a panel
## around must not hit the disk sixty times a second.

const PATH: String = "user://lcn_build_menu.cfg"
const SECTION_PANELS: String = "panels"
const SECTION_PALETTE: String = "palette"
const SECTION_BROWSER: String = "browser"
const SECTION_BLUEPRINTS: String = "blueprints"

## panel id -> open?
var open: Dictionary[StringName, bool] = {}
## panel id -> position (size is layout-driven; only the corner is a preference)
var placement: Dictionary[StringName, Vector2] = {}
## LcnBuildCatalog.to_dict()
var palette: Dictionary = {}
var last_tab: StringName = LcnBuildCatalog.TAB_ALL
var last_query: String = ""
var browser_item: StringName = &""
var browser_history: Array[String] = []
var tech_focus: StringName = &""
var law_chapter: StringName = &""
## blueprint id -> player-typed name
var blueprint_names: Dictionary[String, String] = {}

var _dirty: bool = false


func mark_dirty() -> void:
	_dirty = true


func is_dirty() -> bool:
	return _dirty


func is_open(panel: StringName) -> bool:
	return bool(open.get(panel, false))


func set_open(panel: StringName, value: bool) -> void:
	if bool(open.get(panel, false)) == value:
		return
	open[panel] = value
	_dirty = true


func remember_placement(panel: StringName, pos: Vector2) -> void:
	var prev: Vector2 = placement.get(panel, Vector2(-99999.0, -99999.0))
	if prev.distance_to(pos) < 1.0:
		return
	placement[panel] = pos
	_dirty = true


func rename_blueprint(id: StringName, title: String) -> void:
	var key: String = String(id)
	if title.strip_edges() == "":
		blueprint_names.erase(key)
	else:
		blueprint_names[key] = title.strip_edges()
	_dirty = true


func blueprint_overrides() -> Dictionary:
	var out: Dictionary = {}
	var keys: Array = blueprint_names.keys()
	keys.sort()
	for k: Variant in keys:
		out[String(k)] = String(blueprint_names[k])
	return out


# ------------------------------------------------------------------- disk ----

func load_from_disk() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return
	open.clear()
	placement.clear()
	if cfg.has_section(SECTION_PANELS):
		for key: String in cfg.get_section_keys(SECTION_PANELS):
			if key.ends_with("_at"):
				var v: Variant = cfg.get_value(SECTION_PANELS, key, Vector2.ZERO)
				if typeof(v) == TYPE_VECTOR2:
					placement[StringName(key.substr(0, key.length() - 3))] = v
			else:
				open[StringName(key)] = bool(cfg.get_value(SECTION_PANELS, key, false))
	var pal: Variant = cfg.get_value(SECTION_PALETTE, "state", {})
	if typeof(pal) == TYPE_DICTIONARY:
		palette = pal
	last_tab = StringName(String(cfg.get_value(SECTION_PALETTE, "tab", String(LcnBuildCatalog.TAB_ALL))))
	last_query = String(cfg.get_value(SECTION_PALETTE, "query", ""))
	browser_item = StringName(String(cfg.get_value(SECTION_BROWSER, "item", "")))
	browser_history.clear()
	var hist: Variant = cfg.get_value(SECTION_BROWSER, "history", [])
	if typeof(hist) == TYPE_ARRAY:
		for h: Variant in (hist as Array):
			browser_history.append(String(h))
	tech_focus = StringName(String(cfg.get_value(SECTION_BROWSER, "tech", "")))
	law_chapter = StringName(String(cfg.get_value(SECTION_BROWSER, "law", "")))
	blueprint_names.clear()
	var names: Variant = cfg.get_value(SECTION_BLUEPRINTS, "names", {})
	if typeof(names) == TYPE_DICTIONARY:
		var keys: Array = (names as Dictionary).keys()
		keys.sort()
		for k: Variant in keys:
			blueprint_names[String(k)] = String((names as Dictionary)[k])
	_dirty = false


## Writes only when something changed. Returns true when it actually saved.
func flush() -> bool:
	if not _dirty:
		return false
	var cfg := ConfigFile.new()
	var panel_keys: Array = open.keys()
	panel_keys.sort()
	for k: Variant in panel_keys:
		cfg.set_value(SECTION_PANELS, String(k), bool(open[k]))
	var place_keys: Array = placement.keys()
	place_keys.sort()
	for k2: Variant in place_keys:
		cfg.set_value(SECTION_PANELS, "%s_at" % String(k2), placement[k2])
	cfg.set_value(SECTION_PALETTE, "state", palette)
	cfg.set_value(SECTION_PALETTE, "tab", String(last_tab))
	cfg.set_value(SECTION_PALETTE, "query", last_query)
	cfg.set_value(SECTION_BROWSER, "item", String(browser_item))
	cfg.set_value(SECTION_BROWSER, "history", browser_history)
	cfg.set_value(SECTION_BROWSER, "tech", String(tech_focus))
	cfg.set_value(SECTION_BROWSER, "law", String(law_chapter))
	cfg.set_value(SECTION_BLUEPRINTS, "names", blueprint_overrides())
	var err: int = cfg.save(PATH)
	_dirty = false
	return err == OK


## Throws the file away. Tests use it so one run cannot inherit another's state.
static func wipe() -> void:
	if FileAccess.file_exists(PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
