extends TestCase
## A NEW SCREENSHOT TOOL CANNOT BE BORN BLIND.
##
## This project has shipped three tools that photographed something other than
## the thing they were named for, and each of the three was found by a human
## holding two PNGs side by side, months of work later:
##
##   * a sprite suite that read its own cache and certified last week's art;
##   * `tests/render/frame_lab.gd`, whose 24 art-direction frames were 24
##     photographs of [P24]'s title screen — so every luminance, chroma and
##     warmth number this project has ever quoted about its own look was
##     measured off a list of buttons on a dark plate;
##   * `--ui-tour`, which photographed the same title screen eleven more times
##     and reported 11 of 17 screens unreachable, because the menu was also
##     eating every key it pressed.
##
## Fixing the third instance is worth almost nothing. What is worth something is
## that the FOURTH cannot happen quietly, and that is what this suite is: a
## census of every file in the repository that reads the framebuffer, held
## against `tests/gate/screenshot_paths.json`.
##
## THE RULE, and it has exactly three ways to pass:
##
##   1. the file names `LcnShutter` (tools/ui_tour_shutter.gd), which carries
##      both guards — CHROME and DIFF — and cannot be used without them;
##   2. it carries both guards inline and has a `guarded_inline` row naming the
##      functions that hold them, which this suite then asserts still exist;
##   3. it has a `blind` row: named debt, with an owner, what it photographs and
##      what its blindness costs.
##
## A file in none of the three is RED, and the failure message tells the author
## which class to use. That is the whole mechanism. It does not require any
## other part to change anything today, and it does require the next person who
## adds a screenshot to make a decision on purpose.
##
## HOW TO MAKE IT RED: add `get_viewport().get_texture().get_image()` and
## `save_png` to any new .gd under game/, tests/ or tools/ and run this suite.
## Verified by doing exactly that in a scratch tree.

const REGISTRY: String = "res://tests/gate/screenshot_paths.json"
const SHUTTER: String = "res://tools/ui_tour_shutter.gd"
const ROOTS: Array[String] = ["res://game", "res://tests", "res://tools"]

var _registry: Dictionary = {}
## path -> source, for every .gd this suite considers.
var _sources: Dictionary[String, String] = {}
## Every path that reads the framebuffer, sorted.
var _capturing: PackedStringArray = PackedStringArray()


func requires_files() -> PackedStringArray:
	return PackedStringArray([REGISTRY, SHUTTER])


func before_all() -> void:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(REGISTRY))
	_registry = parsed if typeof(parsed) == TYPE_DICTIONARY else {}
	var found: Array[String] = []
	for root: String in ROOTS:
		_scan(root, found)
	found.sort()
	for p: String in found:
		if _captures(_sources[p]):
			_capturing.append(p)


func _scan(dir_path: String, out: Array[String]) -> void:
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return
	for f: String in dir.get_files():
		if not f.ends_with(".gd"):
			continue
		var p: String = "%s/%s" % [dir_path, f]
		_sources[p] = FileAccess.get_file_as_string(p)
		out.append(p)
	for d: String in dir.get_directories():
		_scan("%s/%s" % [dir_path, d], out)


## WHAT COUNTS AS PHOTOGRAPHING THE FRAMEBUFFER, stated once so the census
## cannot be argued with. Reading pixels back out of a viewport is the whole of
## it — baking a sprite atlas into an Image and saving it is not a screenshot
## and has nothing above it to be blind to.
static func _captures(src: String) -> bool:
	var reads: bool = src.contains("get_image()") or src.contains("save_png_to_buffer")
	var from_screen: bool = src.contains("get_viewport") or src.contains("ViewportTexture") \
		or src.contains("get_texture()")
	return reads and from_screen


func _rows(section: String) -> Array:
	return _registry.get(section, []) as Array


func _paths(section: String) -> PackedStringArray:
	var out := PackedStringArray()
	for row: Dictionary in _rows(section):
		out.append(String(row.get("path", "")))
	return out


# --- the census --------------------------------------------------------------

func test_every_screenshot_path_is_guarded_or_named() -> void:
	assert_true(_capturing.size() >= 8,
		("the census found only %d file(s) that read the framebuffer — the detector "
		+ "has stopped matching and this suite is asserting nothing") % _capturing.size())
	var inline: PackedStringArray = _paths("guarded_inline")
	var blind: PackedStringArray = _paths("blind")
	var unregistered: PackedStringArray = PackedStringArray()
	for p: String in _capturing:
		if _sources[p].contains("LcnShutter"):
			continue
		if inline.has(p) or blind.has(p):
			continue
		unregistered.append(p)
	assert_true(unregistered.is_empty(),
		("%s read(s) the framebuffer and carry neither guard: %s.\n"
		+ "    Take the picture through LcnShutter (tools/ui_tour_shutter.gd) — it "
		+ "asserts CHROME (nothing drawn above the subject when the shutter opens) "
		+ "and DIFF (photographs of different things must differ), which are the two "
		+ "checks that would have caught the frame lab and the ui tour. If the tool "
		+ "genuinely cannot use it, add a row to tests/gate/screenshot_paths.json "
		+ "saying who owns it and what its blindness costs.")
		% ["one file" if unregistered.size() == 1 else "%d files" % unregistered.size(),
			", ".join(unregistered)])


## A registry row that names a file which no longer photographs anything is a
## row that will outlive its reason and be copied by the next author. Both
## sections have to keep matching the repository.
func test_the_registry_has_not_rotted() -> void:
	for section: String in ["guarded_inline", "blind"]:
		for row: Dictionary in _rows(section):
			var p: String = String(row.get("path", ""))
			assert_true(_sources.has(p),
				"%s lists %s, which is not a .gd under game/, tests/ or tools/ any more — delete the row"
					% [section, p])
			if not _sources.has(p):
				continue
			assert_true(_capturing.has(p),
				"%s lists %s, which no longer reads the framebuffer — delete the row"
					% [section, p])
			assert_true(String(row.get("owner", "")) != "",
				"%s row for %s has no owner, so nobody can be asked to fix it" % [section, p])
	for row2: Dictionary in _rows("blind"):
		var p2: String = String(row2.get("path", ""))
		if not _sources.has(p2):
			continue
		assert_false(_sources[p2].contains("LcnShutter"),
			("%s is on the blind list and now uses LcnShutter — delete its row, or the "
			+ "debt list stops meaning anything") % p2)
		assert_true(String(row2.get("cost", "")) != "",
			"the blind row for %s does not say what its blindness costs" % p2)


## The debt is allowed to shrink and not to grow. `max_blind` is the number this
## wave measured; a later wave that lowers it is doing the right thing and a
## later wave that raises it has to say so in a diff somebody reads.
func test_the_blind_list_does_not_grow() -> void:
	var cap: int = int(_registry.get("max_blind", 0))
	assert_true(cap <= 10,
		("max_blind is %d; it was 10 when the census was taken and this number only "
		+ "goes down. Raising it is how an allowlist becomes a place to hide.") % cap)
	assert_true(_rows("blind").size() <= cap,
		"%d file(s) on the blind list, cap %d" % [_rows("blind").size(), cap])


# --- the guards themselves ---------------------------------------------------

## The shared implementation cannot be hollowed out while everything keeps
## pointing at it. These are the two guards by name.
func test_the_shutter_still_carries_both_guards() -> void:
	var src: String = _sources.get(SHUTTER, "")
	assert_true(src != "", "there is no shutter at %s" % SHUTTER)
	for needle: String in ["func strip(", "func note(", "func failures(",
			"func diff_failures(", "func fingerprint(", "func draws("]:
		assert_true(src.contains(needle),
			"LcnShutter has lost `%s` — the guard every other rig delegates to" % needle)


## A rig that holds the guards inline holds them at the named functions, and
## those functions are asserted to still be there. [P13]'s frame lab is the only
## one, and it is the file the guards were invented in.
func test_inline_guards_are_still_where_the_registry_says() -> void:
	assert_false(_rows("guarded_inline").is_empty(),
		"no rig claims to carry the guards inline — the frame lab's row has gone missing")
	for row: Dictionary in _rows("guarded_inline"):
		var p: String = String(row.get("path", ""))
		var src: String = _sources.get(p, "")
		if src == "":
			continue
		var chrome: String = String(row.get("chrome", ""))
		var diff: String = String(row.get("diff", ""))
		assert_true(chrome != "" and src.contains(chrome),
			"%s is registered as carrying the CHROME guard at `%s`, and it does not any more"
				% [p, chrome])
		assert_true(diff != "" and src.contains(diff),
			"%s is registered as carrying the DIFF guard at `%s`, and it does not any more"
				% [p, diff])
		# ...and the chrome guard has to be measured against the layer table
		# rather than against a number somebody typed, or it drifts the moment
		# the stack is re-allocated.
		assert_true(src.contains("LcnLayers."),
			"%s strips chrome without consulting LcnLayers — a hardcoded ceiling is a comment"
				% p)


## The two rigs this wave owns go through the shared class, and that is asserted
## here rather than assumed: they are the worked examples the failure message
## above points people at.
func test_the_harness_and_the_tour_use_the_shutter() -> void:
	for p: String in ["res://game/core/harness.gd", "res://tools/ui_tour.gd"]:
		assert_true(_sources.has(p), "%s is missing" % p)
		if not _sources.has(p):
			continue
		assert_true(_sources[p].contains("LcnShutter"),
			"%s photographs the build without going through LcnShutter" % p)
