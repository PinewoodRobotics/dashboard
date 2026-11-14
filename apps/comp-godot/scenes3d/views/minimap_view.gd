class_name MinimapView
extends CadView

## HUD minimap: field plus the robot at its smoothed NT pose, seen from the
## trailing camera of MinimapCamera. Map settings are read from Settings every
## frame; the robot is dimmed while its pose is not current.

const FRAME_SHADER := preload("res://screens/hud/minimap_frame.gdshader")

var match_service: MatchService
## Used only when there is no Settings service (tests, tools).
var settings := AppSettings.DEFAULT_MAP.duplicate()
var cam_model := MinimapCamera.new()
var field: Node3D
var _field_generation := 0


func _setup() -> void:
	if match_service == null:
		match_service = get_node_or_null("/root/Match") as MatchService
	camera.near = MinimapCamera.NEAR
	camera.far = MinimapCamera.FAR
	camera.fov = MinimapCamera.FOV_DEG
	if models != null:
		models.when_ready("field", _attach_field)
		models.model_ready.connect(_on_model_ready)


func use_frame(rect_size: Vector2, radius: Vector2, blur: float, spread: float) -> void:
	var m := ShaderMaterial.new()
	m.shader = FRAME_SHADER
	m.set_shader_parameter("rect_size", rect_size)
	m.set_shader_parameter("radius", radius)
	m.set_shader_parameter("blur", blur)
	m.set_shader_parameter("spread", spread)
	material = m


func _on_model_ready(key: String) -> void:
	if key == "field" and field != null and int(models.generation.get(key, 0)) != _field_generation:
		field.free()
		field = null
		_attach_field(models.scenes[key])


func _attach_field(scene: PackedScene) -> void:
	if field != null or not is_inside_tree():
		return
	if models != null:
		_field_generation = int(models.generation.get("field", 0))
	field = scene.instantiate() as Node3D
	CadMaterials.apply(field)
	viewport.add_child(field)


func map_settings() -> Dictionary:
	return settings_service.map() if settings_service != null else settings


func _process(delta: float) -> void:
	super(delta)
	if telemetry == null:
		return
	if match_service != null:
		robot.set_dimmed(not match_service.model.pose_trusted())
	var p := telemetry.smoothed_pose()
	robot.set_field_pose(p.x, p.y, p.z)
	cam_model.step(delta, telemetry.robot_world(), p.z, map_settings(), telemetry.alliance_red)
	if not apply_camera_override():
		camera.look_at_from_position(cam_model.position(), cam_model.target, Vector3.UP)
