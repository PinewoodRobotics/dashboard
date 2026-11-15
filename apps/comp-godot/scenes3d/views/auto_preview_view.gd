class_name AutoPreviewView
extends CadView

## Auto tab preview: the field, the ghost robot (the shared robot scene driven
## through RigSolver) at the shared preview frame, and the auto's path overlay.
## "path" frames the path from behind the alliance's driver stations, "field"
## shows the whole field from the side with blue on the right. The camera is
## an OrbitCamera with the driver view's tuning plus pan (the web shows a GIF
## here); its limits keep it over the carpet and the target on the field. A
## new auto or camera mode, or reset_view(), returns to the framing.

enum CameraMode { PATH, FIELD }

const PITCH := deg_to_rad(58.0)
const MIN_EXTENT := 4.5
## Past this aspect the framing is height bound, so the minimum box gets
## shallower (never below MIN_DEPTH_FRACTION) to keep the robot large.
const WIDE_ASPECT := 3.0
const MIN_DEPTH_FRACTION := 0.4
const ROBOT_LENGTH_M := 0.9
const ROBOT_H := 0.8
const FIT_MARGIN := 0.9
const MIN_VIEW_PITCH := deg_to_rad(8.0)
const MAX_VIEW_PITCH := deg_to_rad(89.0)
const MIN_DIST := 1.5
const MAX_DIST := 40.0
const ORBIT := {"rotate_speed": 0.5, "zoom_speed": 0.8, "pan_speed": 1.0, "enable_pan": true,
	"min_polar": PI / 2.0 - MAX_VIEW_PITCH, "max_polar": PI / 2.0 - MIN_VIEW_PITCH, "min_dist": MIN_DIST, "max_dist": MAX_DIST}

var autos: AutosService
var overlay: AutoPathOverlay
var camera_mode := CameraMode.PATH
## Framed view {target, yaw, pitch, dist}; the user view starts from it.
var home := {}
var cam := OrbitCamera.new()
var input := OrbitInput.new(cam)
var _framed_key := ""
var _base_key := ""


func _init() -> void:
	super()
	with_field = true
	cam.configure(ORBIT)
	cam.idle_return = false
	add_to_group("pw_grab")
	add_to_group("pw_swipe_veto")


func _setup() -> void:
	if autos == null:
		autos = get_node_or_null("/root/Autos") as AutosService
	camera.near = 0.1
	camera.far = 100.0
	overlay = AutoPathOverlay.new()
	overlay.name = "AutoPath"
	viewport.add_child(overlay)
	overlay.visible = false


func set_camera_mode(mode: CameraMode) -> void:
	camera_mode = mode
	_framed_key = ""


func user_moved() -> bool:
	return cam.user_moved()


func reset_view() -> void:
	if not home.is_empty():
		cam.jump_to(_orbit_pose(home))


func _process(delta: float) -> void:
	cam.step(delta)
	_clamp_target()
	if autos == null:
		return
	show_frame(autos.frame, autos.preview_mechanisms())


func show_frame(f: Dictionary, m: AutoMechanisms) -> void:
	if f.is_empty() or m == null:
		overlay.clear()
		return
	var side: StringName = f["alliance"]
	overlay.show_auto(m, side)
	overlay.set_progress(f["t"])
	var p: Vector3 = f["pose"]
	robot.set_field_pose(p.x, p.y, p.z)
	robot.apply_joints(autos.rig, f["joints"])
	robot.set_alliance(side == AutoPlayback.RED)
	var target: Vector2 = f["aim_target"]
	overlay.set_aim(FieldFrame.to_world(p.x, p.y), FieldFrame.to_world(target.x, target.y), f["aim"])
	var base := "%s|%s" % [overlay.key, camera_mode]
	var framing := "%s|%s" % [base, size]
	if apply_camera_override():
		_framed_key = ""
		return
	if framing != _framed_key and size.x >= 1.0 and size.y >= 1.0:
		_framed_key = framing
		var reframe := base != _base_key or not user_moved()
		_base_key = base
		_place_camera(m, side)
		if reframe:
			cam.jump_to(_orbit_pose(home))
	if not home.is_empty():
		camera.look_at_from_position(cam.position(), cam.target, Vector3.UP)


func _orbit_pose(v: Dictionary) -> Dictionary:
	return {"target": v["target"], "theta": v["yaw"], "phi": PI / 2.0 - float(v["pitch"]), "dist": v["dist"], "fov": camera.fov}


func _clamp_target() -> void:
	var lim := Vector3(FieldFrame.HALF_LENGTH_M, 0.0, FieldFrame.HALF_WIDTH_M) + Vector3.ONE * 2.0
	var t := cam.target.clamp(-lim, lim)
	t.y = 0.0
	cam.target = t


static func view_of(target: Vector3, back: Vector3, dist: float) -> Dictionary:
	return {"target": target, "yaw": atan2(back.x, back.z), "pitch": asin(clampf(back.y, -1.0, 1.0)), "dist": dist}


func _place_camera(m: AutoMechanisms, side: StringName) -> void:
	var aspect := size.x / maxf(size.y, 1.0)
	if camera_mode == CameraMode.FIELD:
		var hx := FieldFrame.HALF_LENGTH_M
		var hz := FieldFrame.HALF_WIDTH_M
		var corners := PackedVector3Array([Vector3(-hx, 0, -hz), Vector3(hx, 0, -hz), Vector3(-hx, 0, hz), Vector3(hx, 0, hz)])
		var side_back := view_back(Vector3.BACK)
		home = view_of(Vector3.ZERO, side_back, fit_distance(corners, Vector3.ZERO, camera.fov, aspect, side_back))
		return
	var pts := PackedVector3Array()
	if m.playback.has_path():
		var line: PackedVector3Array = PathRibbon.centerline(m.playback, side)["points"]
		for i in range(0, line.size(), 4):
			pts.append(line[i])
		pts.append(line[line.size() - 1])
	else:
		var p := m.pose_at(0.0, side)
		pts.append(FieldFrame.to_world(p.x, p.y))
	var lo := pts[0]
	var hi := pts[0]
	for v in pts:
		lo = lo.min(v)
		hi = hi.max(v)
	var center := (lo + hi) * 0.5
	center.y = 0.0
	var ends := [pts[0], pts[pts.size() - 1]]
	var fwd := driver_side(side)
	var across := Vector3.UP.cross(fwd)
	var depth := MIN_EXTENT * clampf(WIDE_ASPECT / aspect, MIN_DEPTH_FRACTION, 1.0)
	for c in [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]:
		pts.append(center + across * c.x * MIN_EXTENT * 0.5 + fwd * c.y * depth * 0.5)
		for e: Vector3 in ends:
			pts.append(e + Vector3(c.x, 0, c.y) * 0.5)
	var back := view_back(fwd)
	home = view_of(center, back, fit_distance(pts, center, camera.fov, aspect, back))


func _gui_input(event: InputEvent) -> void:
	if input.handle(event, self):
		accept_event()


func camera_report() -> Dictionary:
	if home.is_empty():
		return {}
	var t := cam.target
	return {"user": user_moved(), "yaw": cam.theta, "pitch": PI / 2.0 - cam.phi, "dist": cam.dist, "target": [t.x, t.y, t.z],
		"home_dist": home["dist"], "robot_px": robot_px()}


## On-screen length of the robot's frame, in view pixels.
func robot_px() -> float:
	if robot == null or not camera.is_inside_tree():
		return 0.0
	var o := robot.global_transform.origin
	var side := camera.global_transform.basis.x * ROBOT_LENGTH_M
	var px := camera.unproject_position(o).distance_to(camera.unproject_position(o + side))
	return px * size.x / maxf(float(viewport.size.x), 1.0)


## Horizontal direction from the field center to the alliance's driver
## stations (the blue wall is at world +X).
static func driver_side(side: StringName) -> Vector3:
	return Vector3.LEFT if side == AutoPlayback.RED else Vector3.RIGHT


## Unit vector from the framed center toward a camera on the given horizontal
## side, PITCH above the carpet.
static func view_back(horizontal: Vector3) -> Vector3:
	return horizontal * cos(PITCH) + Vector3.UP * sin(PITCH)


## Smallest camera distance from center along back at which every point (and
## a ROBOT_H tall box over it) projects inside FIT_MARGIN of the view.
static func fit_distance(points: PackedVector3Array, center: Vector3, fov_v_deg: float, aspect: float, back: Vector3) -> float:
	var right := Vector3.UP.cross(back).normalized()
	var up := back.cross(right)
	var tan_v := tan(deg_to_rad(fov_v_deg) * 0.5) * FIT_MARGIN
	var tan_h := tan_v * aspect
	var dist := 0.0
	for p in points:
		for h in [0.0, ROBOT_H]:
			var v: Vector3 = p + Vector3.UP * h - center
			var along := v.dot(back)
			dist = maxf(dist, along + absf(v.dot(right)) / tan_h)
			dist = maxf(dist, along + absf(v.dot(up)) / tan_v)
	return dist

