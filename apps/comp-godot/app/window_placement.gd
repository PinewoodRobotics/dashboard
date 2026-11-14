class_name WindowPlacement
extends RefCounted

## Where each window goes, as a pure function of the screen list (port of the
## Electron tiling in apps/comp/electron/main.cjs, with overrides):
## - an override screen index from the settings or the CLI wins when it exists;
## - otherwise the HUD takes the display that is exactly 1920x1080 and the
##   touchscreen the one that is exactly 1920x515, borderless fullscreen;
## - two windows sharing a single screen both stay windowed (a dev laptop);
## - a screen is never given to two windows: the first claim wins (HUD first).
## Sizes are physical pixels (Godot is DPI aware), so unlike Electron's DIP
## bounds a 125% Windows scale factor does not break the match.

const SIZES := {"hud": Vector2i(1920, 1080), "touch": Vector2i(1920, 515)}
const ORDER := ["hud", "touch"]


## screens: [{"position": Vector2i, "size": Vector2i}], windows: subset of ORDER,
## overrides: {"hud": index, "touch": index} (-1 or missing = automatic).
## Returns {key: {"mode": "fullscreen"|"windowed", "screen": int, "rect": Rect2i, "reason": String}}.
static func plan(screens: Array, windows: Array, overrides: Dictionary = {}) -> Dictionary:
	var keys := ORDER.filter(func(k: String) -> bool: return windows.has(k))
	var out := {}
	var claimed := {}
	for key: String in keys:
		var idx := int(overrides.get(key, -1))
		if idx >= 0 and idx < screens.size() and not claimed.has(idx):
			out[key] = _fullscreen(screens, idx, "override")
			claimed[idx] = true
	for key: String in keys:
		if out.has(key):
			continue
		if screens.size() <= 1 and keys.size() > 1:
			out[key] = _windowed("single screen")
			continue
		var idx := _exact_match(screens, SIZES[key], claimed)
		if idx >= 0:
			out[key] = _fullscreen(screens, idx, "exact size")
			claimed[idx] = true
		else:
			out[key] = _windowed("no %dx%d display" % [SIZES[key].x, SIZES[key].y])
	return out


static func _exact_match(screens: Array, want: Vector2i, claimed: Dictionary) -> int:
	for i in screens.size():
		if not claimed.has(i) and Vector2i(screens[i]["size"]) == want:
			return i
	return -1


static func _fullscreen(screens: Array, idx: int, reason: String) -> Dictionary:
	var s: Dictionary = screens[idx]
	return {"mode": "fullscreen", "screen": idx, "rect": Rect2i(s["position"], s["size"]), "reason": reason}


static func _windowed(reason: String) -> Dictionary:
	return {"mode": "windowed", "screen": -1, "rect": Rect2i(), "reason": reason}


static func current_screens() -> Array:
	var out: Array = []
	for i in DisplayServer.get_screen_count():
		out.append({"position": DisplayServer.screen_get_position(i), "size": DisplayServer.screen_get_size(i)})
	return out


static func is_retile_shortcut(event: InputEvent) -> bool:
	var k := event as InputEventKey
	return k != null and k.pressed and not k.echo and k.shift_pressed \
		and (k.ctrl_pressed or k.meta_pressed) and k.keycode == KEY_F
