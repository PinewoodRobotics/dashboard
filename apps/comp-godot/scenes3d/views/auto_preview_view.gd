class_name AutoPreviewView
extends CadView

## Auto tab preview: the field, the ghost robot (the shared robot scene driven
## through RigSolver) at the shared preview frame, and the auto's path overlay.
## "path" frames the path from behind the alliance's driver stations, "field"
## shows the whole field from the side with blue on the right. Drag orbits
## around the framed point, pinch or wheel zooms, two fingers (or right drag)
## pan; a new auto or camera mode, or reset_view(), returns to the framing.

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
const ORBIT_RAD_PER_PX := 0.006
const ZOOM_STEP := 0.9
const MIN_DIST := 1.5
const MAX_DIST := 40.0

var autos: AutosService
var overlay: AutoPathOverlay
var camera_mode := CameraMode.PATH
## Framed view {target, yaw, pitch, dist}; the user view starts from it.
var home := {}
## {} while the framed view is shown.
var user_view := {}
var _framed_key := ""
var _base_key := ""
var _view_dirty := false
var _dragging := false
var _pan_drag := false
var _touches := {}
var _pinch_dist := 0.0
var _pinch_center := Vector2.ZERO


func _init() -> void:
	super()
	with_field = true
	add_to_group("pw_grab")


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
	return not user_view.is_empty()


func reset_view() -> void:
	user_view = {}
	_view_dirty = true


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
	var base := "%s|%s" % [overlay.key, camera_mode]
	var framing := "%s|%s" % [base, size]
	if apply_camera_override():
		_framed_key = ""
		return
	if framing != _framed_key and size.x >= 1.0 and size.y >= 1.0:
		_framed_key = framing
		if base != _base_key:
			_base_key = base
			user_view = {}
		_place_camera(m, side)
		_view_dirty = true
	if _view_dirty and not home.is_empty():
		_view_dirty = false
		_apply_view(user_view if user_moved() else home)


func _apply_view(v: Dictionary) -> void:
	var target: Vector3 = v["target"]
	camera.look_at_from_position(target + spherical(v["yaw"], v["pitch"]) * float(v["dist"]), target, Vector3.UP)


static func spherical(yaw: float, pitch: float) -> Vector3:
	return Vector3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))


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


func _user() -> Dictionary:
	if user_view.is_empty():
		user_view = home.duplicate()
	_view_dirty = true
	return user_view


func orbit(dx_px: float, dy_px: float) -> void:
	if home.is_empty():
		return
	var v := _user()
	v["yaw"] = float(v["yaw"]) - dx_px * ORBIT_RAD_PER_PX
	v["pitch"] = clampf(float(v["pitch"]) + dy_px * ORBIT_RAD_PER_PX, MIN_VIEW_PITCH, MAX_VIEW_PITCH)


## factor < 1 moves closer.
func zoom_by(factor: float) -> void:
	if home.is_empty() or not is_finite(factor) or factor <= 0.0:
		return
	var v := _user()
	v["dist"] = clampf(float(v["dist"]) * factor, MIN_DIST, MAX_DIST)


## Moves the target on the carpet so the scene follows a drag of (dx, dy) px.
func pan(dx_px: float, dy_px: float) -> void:
	if home.is_empty() or size.y < 1.0:
		return
	var v := _user()
	var m_per_px := 2.0 * float(v["dist"]) * tan(deg_to_rad(camera.fov) * 0.5) / size.y
	var yaw := float(v["yaw"])
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	var toward := Vector3(sin(yaw), 0.0, cos(yaw))
	var t: Vector3 = v["target"] - right * dx_px * m_per_px - toward * dy_px * m_per_px
	var lim := Vector3(FieldFrame.HALF_LENGTH_M, 0.0, FieldFrame.HALF_WIDTH_M) + Vector3.ONE * 2.0
	t = t.clamp(-lim, lim)
	t.y = 0.0
	v["target"] = t


func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		if st.pressed:
			_touches[st.index] = st.position
		else:
			_touches.erase(st.index)
		_pinch_dist = _touch_spread()
		_pinch_center = _touch_center()
	elif event is InputEventScreenDrag:
		var sd := event as InputEventScreenDrag
		_touches[sd.index] = sd.position
		if _touches.size() >= 2:
			var spread := _touch_spread()
			var c := _touch_center()
			if _pinch_dist > 0.0 and spread > 0.0:
				zoom_by(_pinch_dist / spread)
				pan(c.x - _pinch_center.x, c.y - _pinch_center.y)
			_pinch_dist = spread
			_pinch_center = c
		accept_event()
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_dragging = mb.pressed
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_RIGHT or mb.button_index == MOUSE_BUTTON_MIDDLE:
			_pan_drag = mb.pressed
			accept_event()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			zoom_by(ZOOM_STEP)
			accept_event()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom_by(1.0 / ZOOM_STEP)
			accept_event()
	elif event is InputEventMagnifyGesture:
		zoom_by(1.0 / maxf((event as InputEventMagnifyGesture).factor, 0.01))
	elif event is InputEventPanGesture:
		var pg := event as InputEventPanGesture
		pan(-pg.delta.x * 8.0, -pg.delta.y * 8.0)
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _touches.size() >= 2:
			return
		if _pan_drag:
			pan(mm.relative.x, mm.relative.y)
		elif _dragging:
			orbit(mm.relative.x, mm.relative.y)


func _touch_spread() -> float:
	if _touches.size() < 2:
		return 0.0
	var pts: Array = _touches.values()
	return (pts[0] as Vector2).distance_to(pts[1])


func _touch_center() -> Vector2:
	if _touches.size() < 2:
		return Vector2.ZERO
	var pts: Array = _touches.values()
	return ((pts[0] as Vector2) + (pts[1] as Vector2)) * 0.5


func camera_report() -> Dictionary:
	var v := user_view if user_moved() else home
	if v.is_empty():
		return {}
	var t: Vector3 = v["target"]
	return {"user": user_moved(), "yaw": v["yaw"], "pitch": v["pitch"], "dist": v["dist"], "target": [t.x, t.y, t.z],
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

