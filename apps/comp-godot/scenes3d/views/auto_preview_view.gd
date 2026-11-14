class_name AutoPreviewView
extends CadView

## Auto tab preview: the field, the ghost robot (the shared robot scene driven
## through RigSolver) at the shared preview frame, and the auto's path overlay.
## "path" frames the path from behind the alliance's driver stations, "field"
## shows the whole field from the side with blue on the right.

enum CameraMode { PATH, FIELD }

const PITCH := deg_to_rad(58.0)
const MIN_EXTENT := 4.5
const ROBOT_H := 0.8
const FIT_MARGIN := 0.9

var autos: AutosService
var overlay: AutoPathOverlay
var camera_mode := CameraMode.PATH
var _framed_key := ""


func _init() -> void:
	super()
	with_field = true


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


func _process(_delta: float) -> void:
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
	var framing := "%s|%s|%s" % [overlay.key, camera_mode, size]
	if apply_camera_override():
		_framed_key = ""
	elif framing != _framed_key and size.x >= 1.0 and size.y >= 1.0:
		_framed_key = framing
		_place_camera(m, side)


func _place_camera(m: AutoMechanisms, side: StringName) -> void:
	var aspect := size.x / maxf(size.y, 1.0)
	if camera_mode == CameraMode.FIELD:
		var hx := FieldFrame.HALF_LENGTH_M
		var hz := FieldFrame.HALF_WIDTH_M
		var corners := PackedVector3Array([Vector3(-hx, 0, -hz), Vector3(hx, 0, -hz), Vector3(-hx, 0, hz), Vector3(hx, 0, hz)])
		var side_back := view_back(Vector3.BACK)
		camera.look_at_from_position(side_back * fit_distance(corners, Vector3.ZERO, camera.fov, aspect, side_back), Vector3.ZERO, Vector3.UP)
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
	for c in [Vector3(-1, 0, -1), Vector3(1, 0, -1), Vector3(-1, 0, 1), Vector3(1, 0, 1)]:
		pts.append(center + c * MIN_EXTENT * 0.5)
		for e: Vector3 in ends:
			pts.append(e + c * 0.5)
	var back := view_back(driver_side(side))
	var dist := fit_distance(pts, center, camera.fov, aspect, back)
	camera.look_at_from_position(center + back * dist, center, Vector3.UP)


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

