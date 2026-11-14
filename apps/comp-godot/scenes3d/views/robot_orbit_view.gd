class_name RobotOrbitView
extends CadView

## Robot-local orbit view (driver view base). Starts at a camera-poses.json
## preset; mouse or touch drag orbits, wheel zooms, within the web limits.

const POSES_PATH := "res://data/rig/camera-poses.json"
const MIN_POLAR := 0.1
const MAX_POLAR := PI / 2.0 - 0.05
const MIN_DIST := 0.5
const MAX_DIST := 4.0
const ROTATE_SPEED := 0.006

var preset := 0
var target := Vector3.ZERO
var theta := 0.0
var phi := 1.0
var dist := 2.0
var _dragging := false


func _setup() -> void:
	camera.near = 0.01
	camera.far = 50.0
	apply_preset(preset)


static func load_poses() -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(POSES_PATH))
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


func apply_preset(index: int) -> void:
	var poses := load_poses()
	var states: Array = poses.get("states", [])
	var pose: Dictionary = states[index] if index >= 0 and index < states.size() else poses.get("initial", {})
	var p: Array = pose.get("position", [1.38, 0.45, 1.38])
	var t: Array = pose.get("target", [0, 0.25, 0])
	target = Vector3(t[0], t[1], t[2])
	var offset := Vector3(p[0], p[1], p[2]) - target
	dist = clampf(offset.length(), MIN_DIST, MAX_DIST)
	phi = clampf(acos(clampf(offset.y / offset.length(), -1.0, 1.0)), MIN_POLAR, MAX_POLAR)
	theta = atan2(offset.x, offset.z)
	camera.fov = float(pose.get("fov", 50.0))
	preset = index
	_place_camera()


func _process(delta: float) -> void:
	super(delta)
	apply_camera_override()


func _place_camera() -> void:
	var pos := target + dist * Vector3(sin(phi) * sin(theta), cos(phi), sin(phi) * cos(theta))
	camera.look_at_from_position(pos, target, Vector3.UP)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_dragging = mb.pressed
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			dist = clampf(dist * 0.9, MIN_DIST, MAX_DIST)
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			dist = clampf(dist / 0.9, MIN_DIST, MAX_DIST)
		_place_camera()
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		theta -= mm.relative.x * ROTATE_SPEED
		phi = clampf(phi - mm.relative.y * ROTATE_SPEED, MIN_POLAR, MAX_POLAR)
		_place_camera()
