class_name MinimapView
extends CadView

## HUD minimap: field plus the robot at its smoothed NT pose, seen from the
## trailing camera of MinimapCamera.

var settings := {"mode": "follow", "angle": 0.3, "zoom": 0.5}
var cam_model := MinimapCamera.new()
var field: Node3D


func _setup() -> void:
	camera.near = MinimapCamera.NEAR
	camera.far = MinimapCamera.FAR
	camera.fov = MinimapCamera.FOV_DEG
	if models != null:
		models.when_ready("field", _attach_field)


func _attach_field(scene: PackedScene) -> void:
	if field != null or not is_inside_tree():
		return
	field = scene.instantiate() as Node3D
	CadMaterials.apply(field)
	viewport.add_child(field)


func _process(delta: float) -> void:
	super(delta)
	if telemetry == null:
		return
	var p := telemetry.smoothed_pose()
	robot.set_field_pose(p.x, p.y, p.z)
	cam_model.step(delta, telemetry.robot_world(), p.z, settings, telemetry.alliance_red)
	if not apply_camera_override():
		camera.look_at_from_position(cam_model.position(), cam_model.target, Vector3.UP)
