class_name MinimapContent
extends ViewContent

## HUD minimap: the field and the robot seen from MinimapCamera's trailing
## camera. Without NT the robot drives a slow loop around the field so the view
## keeps changing like it does in a match.

const SETTINGS := {"mode": "follow", "angle": 0.3, "zoom": 0.5}

var cam_model := MinimapCamera.new()
var _pose_wrapper := Node3D.new()
var _robot: Node3D
var _field: Node3D
var _t := 0.0


func _ready() -> void:
	CadLighting.install(self, CadLighting.MINIMAP)
	camera = Camera3D.new()
	camera.near = MinimapCamera.NEAR
	camera.far = MinimapCamera.FAR
	camera.fov = MinimapCamera.FOV_DEG
	add_child(camera)
	_pose_wrapper.name = "PoseWrapper"
	add_child(_pose_wrapper)
	on_model_ready("robot")
	on_model_ready("field")
	step(0.0, true)


func on_model_ready(key: String) -> void:
	if models == null:
		return
	if key == "robot" and _robot == null:
		var model := models.instance("robot")
		if model != null:
			_robot = ViewContent.cad_up()
			_robot.add_child(model)
			_pose_wrapper.add_child(_robot)
	elif key == "field" and _field == null:
		_field = models.instance("field")
		if _field != null:
			add_child(_field)


func step(dt: float, visible: bool) -> void:
	_t += dt
	var a := _t * 0.25
	var pose := Vector3(8.27 + 4.0 * cos(a), 4.03 + 2.2 * sin(a), a + PI / 2.0)
	_pose_wrapper.transform = FieldFrame.robot_transform(pose.x, pose.y, pose.z)
	if not visible:
		return
	cam_model.step(dt, FieldFrame.to_world(pose.x, pose.y), pose.z, SETTINGS, false)
	camera.look_at_from_position(cam_model.position(), cam_model.target, Vector3.UP)
