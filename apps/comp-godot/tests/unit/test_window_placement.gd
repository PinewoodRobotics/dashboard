extends TestCase

const LAPTOP := {"position": Vector2i(0, 0), "size": Vector2i(1366, 768)}
const HUD := {"position": Vector2i(1366, 0), "size": Vector2i(1920, 1080)}
const TOUCH := {"position": Vector2i(1366, 1080), "size": Vector2i(1920, 515)}
const BOTH := ["hud", "touch"]


func _key(keycode: Key, ctrl: bool, meta: bool, shift: bool, pressed: bool = true) -> InputEventKey:
	var k := InputEventKey.new()
	k.keycode = keycode
	k.ctrl_pressed = ctrl
	k.meta_pressed = meta
	k.shift_pressed = shift
	k.pressed = pressed
	return k


func _check_full(p: Dictionary, screen: int, rect: Rect2i, msg: String) -> void:
	check_eq(p["mode"], "fullscreen", msg + " mode")
	check_eq(p["screen"], screen, msg + " screen")
	check_eq(p["rect"], rect, msg + " rect")


func test_exact_sizes_pick_the_displays() -> void:
	var p := WindowPlacement.plan([HUD, TOUCH], BOTH)
	_check_full(p["hud"], 0, Rect2i(1366, 0, 1920, 1080), "hud")
	_check_full(p["touch"], 1, Rect2i(1366, 1080, 1920, 515), "touch")
	check_eq(p["hud"]["reason"], "exact size")


func test_reversed_order_follows_the_sizes() -> void:
	var p := WindowPlacement.plan([TOUCH, HUD], BOTH)
	_check_full(p["hud"], 1, Rect2i(1366, 0, 1920, 1080), "hud")
	_check_full(p["touch"], 0, Rect2i(1366, 1080, 1920, 515), "touch")


func test_driver_station_with_laptop_panel() -> void:
	var p := WindowPlacement.plan([LAPTOP, TOUCH, HUD], BOTH)
	check_eq(p["hud"]["screen"], 2)
	check_eq(p["touch"]["screen"], 1)


func test_single_screen_gives_two_windowed_windows() -> void:
	for s: Dictionary in [LAPTOP, HUD]:
		var p := WindowPlacement.plan([s], BOTH)
		check_eq(p["hud"]["mode"], "windowed", "hud on %s" % s["size"])
		check_eq(p["touch"]["mode"], "windowed", "touch on %s" % s["size"])
		check_eq(p["hud"]["reason"], "single screen")
	var none := WindowPlacement.plan([], BOTH)
	check_eq(none["hud"]["mode"], "windowed", "no screens at all")


func test_one_window_per_process_still_tiles_on_a_single_screen() -> void:
	check_eq(WindowPlacement.plan([HUD], ["hud"])["hud"]["mode"], "fullscreen", "--screen=hud on a 1080p display")
	check_eq(WindowPlacement.plan([LAPTOP], ["hud"])["hud"]["mode"], "windowed", "--screen=hud on a laptop panel")
	var t := WindowPlacement.plan([HUD, TOUCH], ["touch"])
	check_eq(t.keys(), ["touch"])
	check_eq(t["touch"]["screen"], 1)


func test_missing_display_leaves_that_window_windowed() -> void:
	var p := WindowPlacement.plan([LAPTOP, HUD], BOTH)
	check_eq(p["hud"]["screen"], 1)
	check_eq(p["touch"]["mode"], "windowed")
	check_eq(p["touch"]["reason"], "no 1920x515 display")


func test_settings_overrides_win() -> void:
	var p := WindowPlacement.plan([HUD, TOUCH, LAPTOP], BOTH, {"hud": 2, "touch": -1})
	_check_full(p["hud"], 2, Rect2i(0, 0, 1366, 768), "override")
	check_eq(p["hud"]["reason"], "override")
	check_eq(p["touch"]["screen"], 1, "the other window still matches by size")
	var swapped := WindowPlacement.plan([HUD, TOUCH], BOTH, {"hud": 1, "touch": 0})
	check_eq(swapped["hud"]["screen"], 1)
	check_eq(swapped["touch"]["screen"], 0)
	var single := WindowPlacement.plan([LAPTOP], BOTH, {"touch": 0})
	check_eq(single["touch"]["mode"], "fullscreen", "an explicit override is honored on a single screen")
	check_eq(single["hud"]["mode"], "windowed")


func test_a_screen_is_never_given_twice() -> void:
	var p := WindowPlacement.plan([HUD, TOUCH], BOTH, {"hud": 1, "touch": 1})
	check_eq(p["hud"]["screen"], 1, "first claim wins")
	check_eq(p["touch"]["mode"], "windowed", "touch's 1920x515 display is taken")
	var two_hd := {"position": Vector2i(1920, 0), "size": Vector2i(1920, 1080)}
	var q := WindowPlacement.plan([HUD, two_hd, TOUCH], BOTH, {"touch": 0})
	check_eq(q["touch"]["screen"], 0)
	check_eq(q["hud"]["screen"], 1, "HUD takes the next exact match")


func test_out_of_range_override_falls_back_to_auto() -> void:
	var p := WindowPlacement.plan([HUD, TOUCH], BOTH, {"hud": 5, "touch": -1})
	check_eq(p["hud"]["screen"], 0)
	check_eq(p["hud"]["reason"], "exact size")


func test_shortcut_matches_ctrl_or_cmd_with_shift_f() -> void:
	check(WindowPlacement.is_retile_shortcut(_key(KEY_F, true, false, true)), "Ctrl+Shift+F")
	check(WindowPlacement.is_retile_shortcut(_key(KEY_F, false, true, true)), "Cmd+Shift+F")
	check(not WindowPlacement.is_retile_shortcut(_key(KEY_F, true, false, false)), "Ctrl+F")
	check(not WindowPlacement.is_retile_shortcut(_key(KEY_F, false, false, true)), "Shift+F")
	check(not WindowPlacement.is_retile_shortcut(_key(KEY_G, true, false, true)), "Ctrl+Shift+G")
	check(not WindowPlacement.is_retile_shortcut(_key(KEY_F, true, false, true, false)), "key release")
	var echo := _key(KEY_F, true, false, true)
	echo.echo = true
	check(not WindowPlacement.is_retile_shortcut(echo), "key repeat")


func _kiosk(screens: Array, applied: Array, overrides: Dictionary = {}) -> KioskController:
	var k := KioskController.new()
	k.windows = {"hud": null, "touch": null}
	k.screen_source = func() -> Array: return screens
	k.overrides_source = func() -> Dictionary: return overrides
	k.applier = func(key: String, _w: Window, p: Dictionary) -> void: applied.append([key, p["mode"], p["screen"]])
	return k


func test_shortcut_retiles_the_windows() -> void:
	var screens: Array = [LAPTOP]
	var applied: Array = []
	var k := _kiosk(screens, applied)
	k.retile()
	check_eq(applied, [["hud", "windowed", -1], ["touch", "windowed", -1]], "start-up on the laptop alone")
	applied.clear()
	screens.append_array([TOUCH, HUD])
	check(not k.handle_input(_key(KEY_F, true, false, false)), "Ctrl+F is ignored")
	check_eq(applied, [])
	check(k.handle_input(_key(KEY_F, true, false, true)), "Ctrl+Shift+F handled")
	check_eq(applied, [["hud", "fullscreen", 2], ["touch", "fullscreen", 1]], "displays plugged in, then re-tiled")
	check_eq(k.retiles, 2)
	k.free()


func test_kiosk_retiles_when_the_screen_list_changes() -> void:
	var screens: Array = [LAPTOP, HUD]
	var applied: Array = []
	var k := _kiosk(screens, applied)
	k.retile()
	applied.clear()
	check(not k.poll(0), "not watching outside kiosk mode")
	k.watch_screens = true
	check(not k.poll(1), "unchanged screens")
	check(not k.poll(500), "throttled")
	screens.append(TOUCH)
	check(not k.poll(1000), "still throttled")
	check(k.poll(2001), "a new display triggers a re-tile")
	check_eq(applied, [["hud", "fullscreen", 1], ["touch", "fullscreen", 2]])
	k.free()


func test_settings_windows_section_normalizes() -> void:
	check_eq(AppSettings.normalize_windows(null), {"hud_screen": -1, "touch_screen": -1})
	check_eq(AppSettings.normalize_windows({"hud_screen": 1, "touch_screen": 0}), {"hud_screen": 1, "touch_screen": 0})
	check_eq(AppSettings.normalize_windows({"hud_screen": 1.5, "touch_screen": "2"}), {"hud_screen": -1, "touch_screen": -1})
	check_eq(AppSettings.normalize_windows({"hud_screen": 99, "touch_screen": -9}), {"hud_screen": 7, "touch_screen": -1})
	check_eq(AppSettings.defaults()["windows"], {"hud_screen": -1, "touch_screen": -1})
