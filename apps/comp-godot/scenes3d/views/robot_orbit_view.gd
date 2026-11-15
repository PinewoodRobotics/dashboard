class_name RobotOrbitView
extends CadView

## Robot-local orbit view driven by OrbitCamera and OrbitInput: the driver
## base (DriverRobotViewer.tsx: presets from camera-poses.json, idle return)
## or, after use_robot_viewer(), the Robot 3D tab (RobotViewer.tsx).

const POSES_PATH := "res://data/rig/camera-poses.json"

var cam := OrbitCamera.new(OrbitCamera.load_presets(POSES_PATH))
var input := OrbitInput.new(cam)


func _init() -> void:
	super()
	light_rig = CadLighting.DRIVER
	add_to_group("pw_grab")


static func load_poses() -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(POSES_PATH))
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


func use_robot_viewer() -> void:
	cam = OrbitCamera.robot_viewer()
	input = OrbitInput.new(cam)


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
	if is_rendering():
		cam.step(delta)
	else:
		cam.step_hidden(delta)
	if not apply_camera_override():
		_place_camera()


func _place_camera() -> void:
	camera.fov = cam.fov
	camera.look_at_from_position(cam.position(), cam.target, Vector3.UP)


func _gui_input(event: InputEvent) -> void:
	if input.handle(event, self):
		accept_event()
