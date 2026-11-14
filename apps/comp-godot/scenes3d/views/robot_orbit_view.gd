class_name RobotOrbitView
extends CadView

## Robot-local orbit view (driver base and Robot 3D tab) driven by
## OrbitCamera: presets from camera-poses.json, drag to orbit, wheel, trackpad
## or two-finger pinch to zoom, idle return to the selected preset.

const POSES_PATH := "res://data/rig/camera-poses.json"

var cam := OrbitCamera.new(OrbitCamera.load_presets(POSES_PATH))
var _dragging := false
var _touches := {}
var _pinch_dist := 0.0


func _init() -> void:
	super()
	add_to_group("pw_grab")


static func load_poses() -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(POSES_PATH))
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


func _setup() -> void:
	camera.near = 0.01
	camera.far = 50.0
	_place_camera()


func apply_preset(index: int) -> void:
	cam.select_preset(index, false)
	_place_camera()


func select_preset(index: int) -> void:
	cam.select_preset(index, true)


func _process(delta: float) -> void:
	super(delta)
	cam.step(delta)
	if not apply_camera_override():
		_place_camera()


func _place_camera() -> void:
	camera.fov = cam.fov
	camera.look_at_from_position(cam.position(), cam.target, Vector3.UP)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		if st.pressed:
			_touches[st.index] = st.position
		else:
			_touches.erase(st.index)
		_pinch_dist = _touch_spread()
	elif event is InputEventScreenDrag:
		var sd := event as InputEventScreenDrag
		_touches[sd.index] = sd.position
		if _touches.size() >= 2:
			var spread := _touch_spread()
			if _pinch_dist > 0.0 and spread > 0.0:
				cam.zoom(log(spread / _pinch_dist) / -log(OrbitCamera.ZOOM_STEP))
			_pinch_dist = spread
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_dragging = mb.pressed
			if mb.pressed:
				cam.begin_interaction()
			else:
				cam.end_interaction()
			accept_event()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			cam.zoom(1.0)
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			cam.zoom(-1.0)
	elif event is InputEventMagnifyGesture:
		cam.zoom(log((event as InputEventMagnifyGesture).factor) / -log(OrbitCamera.ZOOM_STEP))
	elif event is InputEventMouseMotion and _dragging and _touches.size() < 2:
		var mm := event as InputEventMouseMotion
		cam.orbit(mm.relative.x, mm.relative.y)


func _touch_spread() -> float:
	if _touches.size() < 2:
		return 0.0
	var pts: Array = _touches.values()
	return (pts[0] as Vector2).distance_to(pts[1])
