class_name MinimapView
extends CadView

## HUD minimap: field plus the robot at its smoothed NT pose, seen from the
## trailing camera of MinimapCamera. Map settings are read from Settings every
## frame; the robot is dimmed while its pose is not current. In pre-match it
## also draws the auto Autos.hud names; while the touchscreen preview plays,
## the robot and camera follow the preview frame instead of NT.

const FRAME_SHADER := preload("res://screens/hud/minimap_frame.gdshader")

var match_service: MatchService
## Used only when there is no Settings service (tests, tools).
var settings := AppSettings.DEFAULT_MAP.duplicate()
var cam_model := MinimapCamera.new()
var autos: AutosService
var auto_overlay: AutoPathOverlay
var mirroring := false


func _init() -> void:
	super()
	with_field = true


func _setup() -> void:
	if match_service == null:
		match_service = get_node_or_null("/root/Match") as MatchService
	camera.near = MinimapCamera.NEAR
	camera.far = MinimapCamera.FAR
	camera.fov = MinimapCamera.FOV_DEG
	if autos == null:
		autos = get_node_or_null("/root/Autos") as AutosService
	auto_overlay = AutoPathOverlay.new()
	auto_overlay.name = "AutoPath"
	viewport.add_child(auto_overlay)
	auto_overlay.clear()


func use_frame(rect_size: Vector2, radius: Vector2, blur: float, spread: float) -> void:
	var m := ShaderMaterial.new()
	m.shader = FRAME_SHADER
	m.set_shader_parameter("rect_size", rect_size)
	m.set_shader_parameter("radius", radius)
	m.set_shader_parameter("blur", blur)
	m.set_shader_parameter("spread", spread)
	material = m


func map_settings() -> Dictionary:
	return settings_service.map() if settings_service != null else settings


func _process(delta: float) -> void:
	super(delta)
	if telemetry == null:
		return
	var f := _update_auto_overlay()
	mirroring = not f.is_empty()
	var p := telemetry.smoothed_pose()
	var alliance: Variant = telemetry.alliance_red
	if mirroring:
		p = f["pose"]
		alliance = f["alliance"] == AutoPlayback.RED
		robot.apply_joints(autos.rig, f["joints"])
		robot.set_alliance(alliance)
	if match_service != null:
		robot.set_dimmed(not mirroring and not match_service.model.pose_trusted())
	robot.set_field_pose(p.x, p.y, p.z)
	cam_model.step(delta, FieldFrame.to_world(p.x, p.y) if mirroring else telemetry.robot_world(), p.z, map_settings(), alliance)
	if not apply_camera_override():
		camera.look_at_from_position(cam_model.position(), cam_model.target, Vector3.UP)


## Shows the auto Autos.hud names; returns the preview frame to mirror, or {}.
func _update_auto_overlay() -> Dictionary:
	var hud: Dictionary = autos.hud if autos != null else {}
	var m := autos.mechanisms(str(hud.get("auto", ""))) if autos != null else null
	if m == null:
		auto_overlay.clear()
		return {}
	var mirror: bool = hud.get("mirror", false) and not autos.frame.is_empty()
	var f: Dictionary = autos.frame if mirror else {}
	auto_overlay.show_auto(m, f["alliance"] if mirror else (AutoPlayback.RED if hud.get("red", true) else AutoPlayback.BLUE))
	auto_overlay.set_progress(f["t"] if mirror else 1e9)
	if mirror:
		var p: Vector3 = f["pose"]
		var target: Vector2 = f["aim_target"]
		auto_overlay.set_aim(FieldFrame.to_world(p.x, p.y), FieldFrame.to_world(target.x, target.y), f["aim"])
	else:
		auto_overlay.set_aim(Vector3.ZERO, Vector3.ZERO, false)
	return f
