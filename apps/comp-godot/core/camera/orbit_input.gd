class_name OrbitInput
extends RefCounted

## OrbitControls' pointer handling for a Control showing an OrbitCamera.
## Mouse: left rotates (ctrl, meta or shift + left pans), middle dollies,
## right pans (ctrl, meta or shift + right rotates); a pan without enable_pan
## does nothing. Wheel, trackpad scroll and trackpad pinch zoom, except while a
## button is held. Touch: one finger rotates, two fingers pinch-zoom and pan by
## their midpoint, and lifting one goes back to rotating with the other.
## Everything moves from the first pixel. Mouse events emulated from touches
## are swallowed, the touch events carry the gesture.

enum State { NONE, ROTATE, DOLLY, PAN, TOUCH_ROTATE, TOUCH_DOLLY_PAN }

var cam: OrbitCamera
var state := State.NONE
var _button := MOUSE_BUTTON_NONE
var _last := Vector2.ZERO
var _touches := {}
var _spread := 0.0
var _mid := Vector2.ZERO


func _init(camera: OrbitCamera) -> void:
	cam = camera


## Returns whether the event belonged to the view.
func handle(event: InputEvent, view: Control) -> bool:
	var h := view.size.y
	if event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		if st.pressed:
			_touches[st.index] = st.position
		else:
			_touches.erase(st.index)
		_touch_start()
		return true
	if event is InputEventScreenDrag:
		var sd := event as InputEventScreenDrag
		if not _touches.has(sd.index):
			return true
		_touch_move(sd.index, sd.position, h)
		return true
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.device == InputEvent.DEVICE_ID_EMULATION:
			return true
		if NativeScroll.is_wheel(mb):
			if mb.pressed and state == State.NONE:
				cam.wheel(NativeScroll.wheel_delta(mb, view).y)
			return true
		if mb.pressed:
			if state == State.NONE:
				_mouse_down(mb)
		elif mb.button_index == _button:
			_button = MOUSE_BUTTON_NONE
			if state != State.NONE:
				state = State.NONE
				cam.end_interaction()
		return true
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if mm.device == InputEvent.DEVICE_ID_EMULATION:
			return true
		var d := mm.position - _last
		_last = mm.position
		match state:
			State.ROTATE:
				cam.rotate(d.x, d.y, h)
			State.DOLLY:
				cam.wheel(d.y)
			State.PAN:
				cam.pan(d.x, d.y, h)
		return state != State.NONE
	if event is InputEventMagnifyGesture:
		if state == State.NONE:
			cam.magnify((event as InputEventMagnifyGesture).factor)
		return true
	if event is InputEventPanGesture:
		if state == State.NONE:
			cam.wheel(NativeScroll.pan_delta(event as InputEventPanGesture, view).y)
		return true
	return false


func _mouse_down(mb: InputEventMouseButton) -> void:
	var modified := mb.ctrl_pressed or mb.meta_pressed or mb.shift_pressed
	var next := State.NONE
	match mb.button_index:
		MOUSE_BUTTON_LEFT:
			next = State.PAN if modified else State.ROTATE
		MOUSE_BUTTON_MIDDLE:
			next = State.DOLLY
		MOUSE_BUTTON_RIGHT:
			next = State.ROTATE if modified else State.PAN
	if next == State.PAN and not cam.enable_pan:
		next = State.NONE
	_button = mb.button_index
	_last = mb.position
	state = next
	if state != State.NONE:
		cam.begin_interaction()


func _touch_start() -> void:
	match _touches.size():
		0:
			state = State.NONE
		1:
			state = State.TOUCH_ROTATE
			_last = _touches.values()[0]
		2:
			state = State.TOUCH_DOLLY_PAN
			var pts: Array = _touches.values()
			_spread = (pts[0] as Vector2).distance_to(pts[1])
			_mid = ((pts[0] as Vector2) + (pts[1] as Vector2)) * 0.5
		_:
			state = State.NONE
	if state != State.NONE:
		cam.begin_interaction()
	elif _touches.is_empty() and cam.is_interacting():
		cam.end_interaction()


func _touch_move(index: int, pos: Vector2, h: float) -> void:
	_touches[index] = pos
	match state:
		State.TOUCH_ROTATE:
			var d := pos - _last
			_last = pos
			cam.rotate(d.x, d.y, h)
		State.TOUCH_DOLLY_PAN:
			var pts: Array = _touches.values()
			var spread := (pts[0] as Vector2).distance_to(pts[1])
			var mid := ((pts[0] as Vector2) + (pts[1] as Vector2)) * 0.5
			if _spread > 0.0 and spread > 0.0:
				cam.pinch(spread / _spread)
			_spread = spread
			if cam.enable_pan:
				cam.pan(mid.x - _mid.x, mid.y - _mid.y, h)
			_mid = mid
