class_name KioskController
extends Node

## Applies WindowPlacement to the open windows: on request (start-up tiling,
## Ctrl/Cmd+Shift+F, the Visual tab), and in kiosk mode also whenever the
## screen list changes, so a display that wakes up late still gets its window.

const GROUP := "kiosk"
const POLL_MS := 2000

var windows := {}
var screen_source: Callable = func() -> Array: return WindowPlacement.current_screens()
var overrides_source: Callable = func() -> Dictionary: return {}
var applier: Callable = func(key: String, w: Window, p: Dictionary) -> void: WindowManager.apply_placement(key, w, p)
var watch_screens := false
var last_plan := {}
var retiles := 0
var _last_screens: Array = []
var _next_poll_ms := 0


func _init() -> void:
	name = "Kiosk"
	add_to_group(GROUP)


func retile() -> Dictionary:
	_last_screens = (screen_source.call() as Array).duplicate(true)
	last_plan = WindowPlacement.plan(_last_screens, windows.keys(), overrides_source.call())
	for key: String in last_plan:
		applier.call(key, windows[key], last_plan[key])
	retiles += 1
	var parts := PackedStringArray()
	for key: String in last_plan:
		var p: Dictionary = last_plan[key]
		parts.append("%s %s%s (%s)" % [key, p["mode"], " on screen %d" % p["screen"] if p["screen"] >= 0 else "", p["reason"]])
	print("windows: %d screen(s): %s" % [_last_screens.size(), ", ".join(parts)])
	return last_plan


func handle_input(event: InputEvent) -> bool:
	if not WindowPlacement.is_retile_shortcut(event):
		return false
	retile()
	return true


func poll(now_ms: int) -> bool:
	if not watch_screens or now_ms < _next_poll_ms:
		return false
	_next_poll_ms = now_ms + POLL_MS
	if screen_source.call() == _last_screens:
		return false
	retile()
	return true


func _process(_delta: float) -> void:
	poll(Time.get_ticks_msec())
