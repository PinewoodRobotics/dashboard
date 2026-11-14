class_name PointerInput
extends RefCounted

## One pointer model for mouse and touch. Widgets read the (emulated) mouse
## events only: a touch arrives as a mouse event from DEVICE_ID_EMULATION
## (input_devices/pointing/emulate_mouse_from_touch), which sets is_touch, so
## hold-to-drag and swipe thresholds follow the touch rules. Raw screen touch
## events are ignored to avoid handling a touch twice.

enum Kind { NONE, DOWN, MOVE, UP }

var kind := Kind.NONE
var pos := Vector2.ZERO
var is_touch := false
var button := MOUSE_BUTTON_NONE


static func from_event(e: InputEvent) -> PointerInput:
	var p := PointerInput.new()
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return p
		p.kind = Kind.DOWN if mb.pressed else Kind.UP
		p.pos = mb.position
		p.button = mb.button_index
		p.is_touch = mb.device == InputEvent.DEVICE_ID_EMULATION
	elif e is InputEventMouseMotion:
		var mm := e as InputEventMouseMotion
		p.kind = Kind.MOVE
		p.pos = mm.position
		p.is_touch = mm.device == InputEvent.DEVICE_ID_EMULATION
	return p


static func now_ms() -> int:
	return Time.get_ticks_msec()
