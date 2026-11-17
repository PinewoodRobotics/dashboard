class_name RobotContent
extends ViewContent

## The driver base robot view (DriverRobotViewer.tsx): the robot under
## OrbitCamera presets with OrbitControls damping and idle return, driven by
## host pointers through OrbitInput.

const POSES_PATH := "res://data/camera-poses.json"

var cam := OrbitCamera.new(OrbitCamera.load_presets(POSES_PATH))
var input := OrbitInput.new(cam)
var _proxy := Control.new()
var _robot: Node3D


func _init(idle_return: bool) -> void:
	cam.idle_return = idle_return


func _ready() -> void:
	CadLighting.install(self, CadLighting.DRIVER)
	camera = Camera3D.new()
	camera.near = 0.01
	camera.far = 50.0
	add_child(camera)
	_place_camera()
	on_model_ready("robot")


func on_model_ready(key: String) -> void:
	if key != "robot" or _robot != null or models == null:
		return
	var model := models.instance("robot")
	if model == null:
		return
	_robot = ViewContent.cad_up()
	_robot.add_child(model)
	add_child(_robot)


func is_ready() -> bool:
	return models == null or models.settled("robot")


func step(dt: float, visible: bool) -> void:
	if visible:
		cam.step(dt)
	else:
		cam.step_hidden(dt)
	_place_camera()


func handle_pointer(p: Dictionary, logical_size: Vector2) -> void:
	_proxy.size = logical_size
	var event := PointerEvents.to_input_event(p)
	if event != null:
		input.handle(event, _proxy)
		_place_camera()


func _place_camera() -> void:
	camera.fov = cam.fov
	camera.look_at_from_position(cam.position(), cam.target, Vector3.UP)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and is_instance_valid(_proxy):
		_proxy.free()
