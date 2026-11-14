class_name CadView
extends SubViewportContainer

## A SubViewport with its own 3D world, a camera and the robot model. Subclasses
## place the camera; the robot follows Telemetry every frame. Render scale and
## MSAA follow the Visual settings live. A view that is covered sets its
## viewport to UPDATE_DISABLED (it keeps showing its last frame).

const ROBOT_SCENE := preload("res://scenes3d/robot/robot_model.tscn")
const GROUP := "cad_views"
const MSAA := {0: Viewport.MSAA_DISABLED, 2: Viewport.MSAA_2X, 4: Viewport.MSAA_4X}

var viewport: SubViewport
var camera: Camera3D
var robot: RobotModel
var telemetry: TelemetryService
var models: ModelsService
var settings_service: SettingsService
## Dev/fixture camera: {position: Vector3, target: Vector3, up: Vector3}; empty = view's own camera.
var camera_override := {}


func _init() -> void:
	stretch = true
	mouse_filter = Control.MOUSE_FILTER_PASS
	add_to_group(GROUP)


func _ready() -> void:
	if telemetry == null:
		telemetry = get_node_or_null("/root/Telemetry") as TelemetryService
	if models == null:
		models = get_node_or_null("/root/Models") as ModelsService
	if settings_service == null:
		settings_service = get_node_or_null("/root/Settings") as SettingsService
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
	if settings_service != null:
		apply_visual(settings_service.visual())
		settings_service.changed.connect(_on_settings_changed)
	_setup()


func _on_settings_changed(section: String) -> void:
	if section == "visual":
		apply_visual(settings_service.visual())


func apply_visual(v: Dictionary) -> void:
	viewport.scaling_3d_scale = float(v.get("render_scale", 1.0))
	viewport.msaa_3d = MSAA.get(int(v.get("msaa", 2)), Viewport.MSAA_2X)


func set_rendering(on: bool) -> void:
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED


func is_rendering() -> bool:
	return viewport != null and viewport.render_target_update_mode != SubViewport.UPDATE_DISABLED and is_visible_in_tree()


static func rendering_views(tree: SceneTree) -> Array:
	return tree.get_nodes_in_group(GROUP).filter(func(v: CadView) -> bool: return v.is_rendering())


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
