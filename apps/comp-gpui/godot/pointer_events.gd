class_name PointerEvents
extends RefCounted

## Host Pointer messages (protocol::Pointer as parsed JSON) as the InputEvents
## OrbitInput.handle expects. Wheel deltas arrive as Chromium WheelEvent px and
## go in as the pan gesture NativeScroll.pan_delta turns back into those px
## (the proxy Control is outside the tree, so its DIP scale is 1).

const BUTTONS := {1: MOUSE_BUTTON_LEFT, 2: MOUSE_BUTTON_RIGHT, 3: MOUSE_BUTTON_MIDDLE}
const SHIFT := 1
const CTRL := 2
const ALT := 4
const META := 8


static func to_input_event(p: Dictionary) -> InputEvent:
	var pos := Vector2(float(p.get("x", 0.0)), float(p.get("y", 0.0)))
	var phase := str(p.get("phase", ""))
	if str(p.get("kind", "Mouse")) == "Touch":
		return _touch(p, phase, pos)
	match phase:
		"Down", "Up":
			var mb := InputEventMouseButton.new()
			mb.button_index = BUTTONS.get(int(p.get("button", 0)), MOUSE_BUTTON_NONE)
			mb.pressed = phase == "Down"
			mb.position = pos
			_mods(mb, int(p.get("mods", 0)))
			return mb
		"Move":
			var mm := InputEventMouseMotion.new()
			mm.position = pos
			_mods(mm, int(p.get("mods", 0)))
			return mm
		"Wheel":
			var pg := InputEventPanGesture.new()
			pg.position = pos
			pg.delta = Vector2(float(p.get("wheel_x", 0.0)), float(p.get("wheel_y", 0.0))) * NativeScroll.MAC_PAN_SCALE
			return pg
		"Pinch":
			var mg := InputEventMagnifyGesture.new()
			mg.position = pos
			mg.factor = float(p.get("magnify", 1.0))
			return mg
	return null


static func _touch(p: Dictionary, phase: String, pos: Vector2) -> InputEvent:
	var index := int(p.get("id", 0))
	if phase == "Move":
		var sd := InputEventScreenDrag.new()
		sd.index = index
		sd.position = pos
		return sd
	var st := InputEventScreenTouch.new()
	st.index = index
	st.position = pos
	st.pressed = phase == "Down"
	st.canceled = phase == "Cancel"
	return st


static func _mods(e: InputEventWithModifiers, mods: int) -> void:
	e.shift_pressed = mods & SHIFT != 0
	e.ctrl_pressed = mods & CTRL != 0
	e.alt_pressed = mods & ALT != 0
	e.meta_pressed = mods & META != 0
