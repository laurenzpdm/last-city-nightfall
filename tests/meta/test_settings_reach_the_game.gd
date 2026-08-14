extends TestCase
## [P24] A setting that does not reach the game is not a setting.
##
## Every check here moves a number in `Settings` and then reads the CONSUMER —
## the audio bus on AudioServer, [P15]'s timing, [P19]'s lens palette, [P17]'s
## style — rather than reading `Settings` back, which would only prove that a
## dictionary can hold a value.
##
## The suite restores every setting it touched, so it cannot leave a machine
## configured differently than it found it.

var _saved: Dictionary = {}


func before_all() -> void:
	for section: String in ["graphics", "accessibility", "audio", "gameplay"]:
		_saved[section] = (Settings.get(section) as Dictionary).duplicate(true)


func after_all() -> void:
	for section: String in _saved:
		var live: Dictionary = Settings.get(section)
		live.clear()
		live.merge(_saved[section] as Dictionary)
	Settings.save_to_disk()


# =================================================================== audio ===

func test_the_music_slider_moves_a_real_audio_bus() -> void:
	var mixer := LcnAudioMixer.new()
	mixer.install()
	var bus: int = AudioServer.get_bus_index(String(LcnAudioDefs.BUS_MUSIC))
	assert_ge(float(bus), 0.0, "[P23] built a Music bus")
	if bus < 0:
		return
	Settings.set_value("audio", "music", 1.0)
	mixer.apply_settings(true)
	var loud: float = AudioServer.get_bus_volume_db(bus)
	Settings.set_value("audio", "music", 0.2)
	mixer.apply_settings(true)
	var quiet: float = AudioServer.get_bus_volume_db(bus)
	assert_lt(quiet, loud - 3.0,
		"turning the music slider down took the Music bus down with it (%.1f dB → %.1f dB)" % [
			loud, quiet])
	Settings.set_value("audio", "music", 0.0)
	mixer.apply_settings(true)
	assert_le(AudioServer.get_bus_volume_db(bus), quiet, "and 0 is quieter still")


func test_every_slider_the_screen_offers_addresses_a_bus_that_exists() -> void:
	var mixer := LcnAudioMixer.new()
	mixer.install()
	for key: StringName in LcnAudioSettings.KEYS:
		assert_true(LcnAudioDefs.SLIDER_BUS.has(String(key)),
			"[P23] has a bus for the '%s' slider this screen draws" % key)


# =========================================================== accessibility ===

func test_reduce_motion_reaches_the_feel_layer() -> void:
	Settings.set_value("accessibility", "reduce_motion", false)
	assert_false(LcnTiming.reduce_motion(), "off by default")
	assert_gt(LcnTiming.shake_scale(), 0.0, "shake exists when motion is allowed")
	Settings.set_value("accessibility", "reduce_motion", true)
	assert_true(LcnTiming.reduce_motion(), "[P15] sees the setting")
	assert_eq(LcnTiming.shake_scale(), 0.0, "every camera impulse is silenced")
	assert_eq(LcnTiming.decorative(0.4), 0.0, "decorative motion collapses to a cut")
	assert_eq(LcnTiming.motion_scale(), 0.0, "and every travel is scaled to nothing")
	assert_false(LcnTiming.hit_stop_enabled(), "hit-stop is off")
	Settings.set_value("accessibility", "reduce_motion", false)


func test_the_screen_shake_slider_is_independent_of_reduce_motion() -> void:
	Settings.set_value("accessibility", "reduce_motion", false)
	Settings.set_value("graphics", "screen_shake", 0.5)
	assert_near(LcnTiming.shake_scale(), 0.5, 0.001, "half shake")
	Settings.set_value("graphics", "screen_shake", 0.0)
	assert_eq(LcnTiming.shake_scale(), 0.0, "no shake, without touching reduce_motion")
	Settings.set_value("graphics", "screen_shake", 1.0)


## The one that matters most in this game: warm-versus-cold is the whole
## language, and it is the axis a red-green deficiency cannot separate.
func test_every_colourblind_token_the_screen_writes_is_understood_downstream() -> void:
	for token: String in LcnAccessSettings.CB_VALUES:
		Settings.set_value("accessibility", "colorblind_mode", token)

		# [P19]'s lenses.
		var vision: int = LcnOverlayPalette.vision_from_setting(token)
		if token == "off":
			assert_eq(vision, LcnOverlayPalette.Vision.NORMAL, "'off' is normal vision")
		else:
			assert_ne(vision, LcnOverlayPalette.Vision.NORMAL,
				"[P19] resolves '%s' to a deficiency rather than ignoring it" % token)
		var palette := LcnOverlayPalette.new(token, false, false)
		assert_eq(palette.vision, vision, "the lens palette configured itself from '%s'" % token)

		# [P17]'s HUD reads the same key out of the same section.
		var hud := LcnHudStyle.new()
		assert_eq(String(hud.colorblind), token, "[P17] picked '%s' up" % token)

		# And our own menus.
		var style := LcnMetaStyle.new()
		assert_eq(String(style.colorblind), token, "[P24] picked '%s' up" % token)
	Settings.set_value("accessibility", "colorblind_mode", "off")


func test_a_deficiency_actually_changes_the_colours_meaning_is_carried_in() -> void:
	Settings.set_value("accessibility", "colorblind_mode", "off")
	var plain := LcnMetaStyle.new()
	var good_normal: Color = plain.status(&"good")
	for token: String in ["protan", "deutan", "mono"]:
		Settings.set_value("accessibility", "colorblind_mode", token)
		var style := LcnMetaStyle.new()
		assert_ne(style.status(&"good").to_html(), good_normal.to_html(),
			"'%s' moves the good reading off green" % token)
	Settings.set_value("accessibility", "colorblind_mode", "tritan")
	var tritan := LcnMetaStyle.new()
	assert_ne(tritan.status(&"warn").to_html(), plain.status(&"warn").to_html(),
		"tritan moves the caution amber, which is the hue it cannot hold")
	Settings.set_value("accessibility", "colorblind_mode", "off")


func test_text_scaling_grows_the_rows_rather_than_clipping_them() -> void:
	Settings.set_value("accessibility", "font_scale", 1.0)
	var small := LcnMetaStyle.new()
	var small_row: float = small.row_height()
	var small_type: int = small.fs(LcnMetaStyle.FS_ROW)
	Settings.set_value("accessibility", "font_scale", 1.6)
	var large := LcnMetaStyle.new()
	assert_gt(large.fs(LcnMetaStyle.FS_ROW), small_type, "the type is bigger")
	assert_gt(large.row_height(), small_row * 1.4,
		"and the row grew with it (%d → %d px)" % [int(small_row), int(large.row_height())])
	# [P17]'s HUD scales its type from the same key, so one slider moves both.
	var hud := LcnHudStyle.new()
	assert_near(hud.font_scale, 1.6, 0.001, "[P17] reads the same font scale")
	Settings.set_value("accessibility", "font_scale", 1.0)


func test_the_font_scale_is_clamped_so_a_bad_config_cannot_erase_the_interface() -> void:
	Settings.set_value("accessibility", "font_scale", 99.0)
	assert_le(LcnMetaStyle.new().font_scale, 2.0, "an absurd scale is clamped")
	Settings.set_value("accessibility", "font_scale", -4.0)
	assert_ge(LcnMetaStyle.new().font_scale, 0.7, "a negative scale is clamped")
	Settings.set_value("accessibility", "font_scale", 1.0)


# ================================================================= display ===

func test_a_resolution_survives_the_round_trip_through_the_config_file() -> void:
	for res: Vector2i in LcnDisplaySettings.RESOLUTIONS:
		var text: String = LcnDisplaySettings.resolution_text(res)
		assert_eq(LcnDisplaySettings.parse_resolution(text), res,
			"%s parses back to itself" % text)
	assert_eq(LcnDisplaySettings.parse_resolution("garbage"), Vector2i.ZERO,
		"nonsense parses to nothing rather than to a 0×0 window")
	assert_eq(LcnDisplaySettings.parse_resolution("1280x720"), Vector2i(1280, 720),
		"a plain x is accepted too, since that is what a hand-edited config has")


func test_display_settings_persist_to_the_file_a_restart_reads() -> void:
	Settings.set_value("graphics", "window_mode", LcnDisplaySettings.MODE_BORDERLESS)
	Settings.set_value("graphics", "max_fps", 144)
	Settings.save_to_disk()
	var cfg := ConfigFile.new()
	assert_eq(cfg.load(Settings.PATH), OK, "the settings file was written")
	assert_eq(String(cfg.get_value("graphics", "window_mode", "")),
		LcnDisplaySettings.MODE_BORDERLESS, "the window mode is in it")
	assert_eq(int(cfg.get_value("graphics", "max_fps", 0)), 144, "so is the frame cap")


func test_applying_display_settings_headless_touches_nothing_and_says_nothing() -> void:
	# The gate runs headless. A settings screen that pokes DisplayServer there
	# is how a nicety becomes 23 blocking engine errors — it has happened in this
	# build once already (commit 49e6b7e).
	assert_no_errors(func() -> void:
		LcnDisplaySettings.apply_all()
		LcnDisplaySettings.apply_all(),
		"apply_all() is silent with no display server")


# ================================================================ keybinds ===

func test_the_reservation_table_and_the_action_map_do_not_disagree() -> void:
	Keybinds.install()
	# Every reserved key is claimed by the router, so the only actions allowed to
	# hold one are the three speed actions it dispatches.
	for code: int in LcnLayers.RESERVED_TIME + LcnLayers.RESERVED_LENS:
		var holders: PackedStringArray = PackedStringArray()
		for action: StringName in Keybinds.actions():
			for e: InputEvent in Keybinds.events_for(action):
				var k := e as InputEventKey
				if k == null:
					continue
				var bound: int = int(k.physical_keycode if k.physical_keycode != 0 else k.keycode)
				if bound == code:
					holders.append(String(action))
		var expected: PackedStringArray = PackedStringArray()
		if LcnLayers.RESERVED_TIME.has(code):
			expected.append("speed_%d" % (LcnLayers.RESERVED_TIME.find(code) + 1))
		assert_eq(holders, expected,
			"%s is held by exactly %s" % [OS.get_keycode_string(code), str(expected)])
