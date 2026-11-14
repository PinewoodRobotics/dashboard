class_name CadView
extends SubViewportContainer

## A SubViewport with its own 3D world, a camera and the robot model. Subclasses
## place the camera; the robot follows Telemetry every frame.

const ROBOT_SCENE := preload("res://scenes3d/robot/robot_model.tscn")

var viewport: SubViewport
var camera: Camera3D
var robot: RobotModel
var telemetry: TelemetryService
var models: ModelsService
## Dev/fixture camera: {position: Vector3, target: Vector3, up: Vector3}; empty = view's own camera.
var camera_override := {}


func _init() -> void:
	stretch = true
	mouse_filter = Control.MOUSE_FILTER_PASS


func _ready() -> void:
	if telemetry == null:
		telemetry = get_node_or_null("/root/Telemetry") as TelemetryService
	if models == null:
		models = get_node_or_null("/root/Models") as ModelsService
	viewport = SubViewport.new()
	viewport.own_world_3d = true
	viewport.transparent_bg = true
	viewport.msaa_3d = Viewport.MSAA_2X
	viewport.positional_shadow_atlas_size = 0
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	camera = Camera3D.new()
	camera.fov = 50.0
	viewport.add_child(camera)
	robot = ROBOT_SCENE.instantiate() as RobotModel
	viewport.add_child(robot)
	_setup()


## Applies camera_override; returns false when there is none.
func apply_camera_override() -> bool:
	if camera_override.is_empty():
		return false
	camera.look_at_from_position(camera_override["position"], camera_override["target"], camera_override.get("up", Vector3.UP))
	return true


## Window canvas position of a world point (for probes), or null when behind the camera.
func project_to_canvas(world: Vector3) -> Variant:
	if camera.is_position_behind(world):
		return null
	var vp_px := camera.unproject_position(world)
	var scale_xy := size / Vector2(viewport.size)
	return get_global_transform_with_canvas() * (vp_px * scale_xy)


func _setup() -> void:
	pass


func _process(_delta: float) -> void:
	if telemetry == null:
		return
	robot.apply_joints(telemetry.rig, telemetry.joint_values)
	robot.set_alliance(telemetry.alliance_red)


func set_render_scale(s: float) -> void:
	viewport.scaling_3d_scale = s
