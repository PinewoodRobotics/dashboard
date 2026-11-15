class_name OrbitCamera
extends RefCounted

## three.js OrbitControls (r187) as the web tunes it, plus the driver view's
## presets (DriverRobotViewer.tsx). Rotation and pan go into a pool that every
## update() applies DAMPING of and then shrinks by (1 - DAMPING), so a drag
## glides on while updates run; zoom applies at once. Like OrbitControls, update()
## runs once per input event and, where the web's useFrame calls
## controls.update() (the driver view), once per frame scaled to 60 fps.
## RobotViewer.tsx never updates per frame (frame_updates false), so its drags
## stop dead on release and the rest of the pool goes out with the next input
## event. Rotation is 2 pi * rotate_speed per view height of drag on both
## axes; the wheel scales the distance by 0.95^(zoom_speed * |deltaY| / 100),
## a pinch by (spread ratio)^zoom_speed, a pan moves the target in screen space
## by 2 * px * dist * tan(fov / 2) / view height.
## Presets are reached by a 400 ms easeOutCubic tween on the shortest arc, and
## 1000 ms after the last input a 600 ms tween returns to the end of the last
## completed tween (idleTargetRef). While the view is covered (frameloop
## "never") nothing moves, but the wall clock of the tween and the idle wait
## runs on, so both resolve on the first visible frame.
## Tweens run on unclamped poses and the update clamps polar angle and
## distance every frame, as controls.update() does after the web's tween.

const DAMPING := 0.08
const EPS := 1e-6
const PRESET_TWEEN_S := 0.4
const IDLE_DELAY_S := 1.0
const IDLE_RETURN_S := 0.6

const DRIVER := {"rotate_speed": 0.5, "zoom_speed": 0.8, "pan_speed": 1.0, "enable_pan": false,
	"min_polar": 0.1, "max_polar": PI / 2.0 - 0.05, "min_dist": 0.5, "max_dist": 4.0}
const ROBOT_VIEWER := {"rotate_speed": 1.0, "zoom_speed": 1.0, "pan_speed": 1.0, "enable_pan": true,
	"min_polar": 0.0, "max_polar": PI, "min_dist": 0.2, "max_dist": 6.0, "frame_updates": false}

var rotate_speed := 0.5
var zoom_speed := 0.8
var pan_speed := 1.0
var enable_pan := false
var min_polar := 0.1
var max_polar := PI / 2.0 - 0.05
var min_dist := 0.5
var max_dist := 4.0

var presets: Array = []
var preset := 0
var target := Vector3.ZERO
var theta := 0.0
var phi := 1.0
var dist := 2.0
var fov := 50.0
var idle_return := true
var frame_updates := true

var _pool_theta := 0.0
var _pool_phi := 0.0
var _pool_pan := Vector3.ZERO
var _scale := 1.0
var _tween_from := {}
var _tween_to := {}
var _tween_t := 0.0
var _tween_s := 0.0
var _tweening := false
var _idle_s := 0.0
var _user_moved := false
var _interacting := false
var _home := {}


static func load_presets(path: String) -> Array:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		return []
	var out: Array = []
	for s: Dictionary in parsed.get("states", []):
		out.append(pose_to_spherical(s))
	return out


## {target, theta, phi, dist, fov, label} from a {position, target, fov} pose, unclamped.
static func pose_to_spherical(pose: Dictionary) -> Dictionary:
	var p: Array = pose.get("position", [1.38, 0.45, 1.38])
	var t: Array = pose.get("target", [0, 0.25, 0])
	var tgt := Vector3(t[0], t[1], t[2])
	var off := Vector3(p[0], p[1], p[2]) - tgt
	var r := maxf(off.length(), 1e-6)
	return {
		"label": str(pose.get("label", "")),
		"target": tgt,
		"theta": atan2(off.x, off.z),
		"phi": acos(clampf(off.y / r, -1.0, 1.0)),
		"dist": r,
		"fov": float(pose.get("fov", 50.0)),
	}


## RobotViewer.tsx: camera at (1.5, 1, 1.5) looking at the origin, fov 50.
static func robot_viewer() -> OrbitCamera:
	var c := OrbitCamera.new()
	c.configure(ROBOT_VIEWER)
	c.idle_return = false
	c._set_from(pose_to_spherical({"position": [1.5, 1.0, 1.5], "target": [0, 0, 0], "fov": 50.0}))
	c.update(0.0)
	return c


func _init(preset_list: Array = []) -> void:
	presets = preset_list
	if not presets.is_empty():
		_set_from(presets[0])
		_home = presets[0]
		update(0.0)


func configure(cfg: Dictionary) -> void:
	for k: String in cfg:
		set(k, cfg[k])


func position() -> Vector3:
	return target + dist * Vector3(sin(phi) * sin(theta), cos(phi), sin(phi) * cos(theta))


func user_moved() -> bool:
	return _user_moved


func is_tweening() -> bool:
	return _tweening


func is_gliding() -> bool:
	return absf(_pool_theta) > 1e-5 or absf(_pool_phi) > 1e-5 or _pool_pan.length() > 1e-5


func select_preset(index: int, animate: bool = true) -> void:
	if index < 0 or index >= presets.size() or (animate and index == preset):
		return
	preset = index
	_user_moved = false
	_idle_s = 0.0
	if animate:
		_start_tween(presets[index], PRESET_TWEEN_S)
	else:
		jump_to(presets[index])


## Places the camera at a {target, theta, phi, dist, fov} pose at once,
## dropping any glide or tween; it counts as not moved by the user.
func jump_to(pose: Dictionary) -> void:
	_tweening = false
	_pool_theta = 0.0
	_pool_phi = 0.0
	_pool_pan = Vector3.ZERO
	_scale = 1.0
	_user_moved = false
	_idle_s = 0.0
	_set_from(pose)
	_home = pose
	update(0.0)


## OrbitControls "start": a pointer went down on the view.
func begin_interaction() -> void:
	_interacting = true
	_cancel_tween()
	_idle_s = 0.0


## OrbitControls "end": the last pointer came up.
func end_interaction() -> void:
	_interacting = false
	_idle_s = 0.0


func is_interacting() -> bool:
	return _interacting


func rotate(dx_px: float, dy_px: float, view_h: float) -> void:
	var h := maxf(view_h, 1.0)
	_pool_theta -= TAU * dx_px * rotate_speed / h
	_pool_phi -= TAU * dy_px * rotate_speed / h
	_moved()
	update(DAMPING)


func pan(dx_px: float, dy_px: float, view_h: float) -> void:
	if not enable_pan:
		return
	_add_pan(dx_px, dy_px, view_h)
	_moved()
	update(DAMPING)


func _add_pan(dx_px: float, dy_px: float, view_h: float) -> void:
	var h := maxf(view_h, 1.0)
	var target_dist := dist * tan(deg_to_rad(fov) * 0.5)
	var basis := view_basis()
	_pool_pan += -basis.x * (2.0 * dx_px * pan_speed * target_dist / h)
	_pool_pan += basis.y * (2.0 * dy_px * pan_speed * target_dist / h)


## A wheel event (WheelEvent.deltaY px, negative zooms in): OrbitControls
## dispatches start and end around it.
func wheel(delta_y_px: float) -> void:
	if delta_y_px == 0.0:
		return
	_cancel_tween()
	var s := pow(0.95, zoom_speed * absf(delta_y_px * 0.01))
	_scale = _scale * s if delta_y_px < 0.0 else _scale / s
	_moved()
	update(DAMPING)


## A trackpad pinch step. Chromium sends it as a ctrl wheel event of
## deltaY = -100 ln(factor), which OrbitControls multiplies by 10.
func magnify(factor: float) -> void:
	if factor > 0.0 and is_finite(factor):
		wheel(-1000.0 * log(factor))


## A two-finger touch step: spread_ratio = new spread / previous spread.
func pinch(spread_ratio: float) -> void:
	if spread_ratio <= 0.0 or not is_finite(spread_ratio):
		return
	_scale /= pow(spread_ratio, zoom_speed)
	_moved()
	update(DAMPING)


## A two-finger touch move: the pinch and the midpoint pan share one update,
## as in OrbitControls' handleTouchMoveDollyPan.
func pinch_pan(spread_ratio: float, dx_px: float, dy_px: float, view_h: float) -> void:
	if spread_ratio > 0.0 and is_finite(spread_ratio):
		_scale /= pow(spread_ratio, zoom_speed)
	if enable_pan:
		_add_pan(dx_px, dy_px, view_h)
	_moved()
	update(DAMPING)


## Camera axes (right, up, back) for the current pose, as Object3D.lookAt builds them.
func view_basis() -> Basis:
	var back := Vector3(sin(phi) * sin(theta), cos(phi), sin(phi) * cos(theta))
	var right := Vector3.UP.cross(back)
	if right.length_squared() < 1e-12:
		right = Vector3(cos(theta), 0.0, -sin(theta))
	right = right.normalized()
	return Basis(right, back.cross(right).normalized(), back)


## OrbitControls.update() with damping factor k: applies k of the pooled
## rotation and pan, the pending zoom, the limits, then shrinks the pool.
func update(k: float) -> void:
	theta += _pool_theta * k
	phi += _pool_phi * k
	phi = clampf(phi, min_polar, max_polar)
	phi = clampf(phi, EPS, PI - EPS)
	target += _pool_pan * k
	dist = clampf(dist * _scale, min_dist, max_dist)
	_pool_theta *= 1.0 - k
	_pool_phi *= 1.0 - k
	_pool_pan *= 1.0 - k
	_scale = 1.0


func step(dt: float) -> void:
	if not frame_updates:
		return
	var k := 1.0 - pow(1.0 - DAMPING, dt * 60.0)
	if _tweening:
		_tween_t += dt
		var e := Easing.out_cubic(_tween_t / _tween_s)
		theta = lerpf(_tween_from["theta"], _tween_to["theta"], e)
		phi = lerpf(_tween_from["phi"], _tween_to["phi"], e)
		dist = lerpf(_tween_from["dist"], _tween_to["dist"], e)
		target = (_tween_from["target"] as Vector3).lerp(_tween_to["target"], e)
		fov = lerpf(_tween_from["fov"], _tween_to["fov"], e)
		if _tween_t >= _tween_s:
			_tweening = false
			_set_from(_tween_to)
			_home = _tween_to
			_idle_s = 0.0
		update(k)
		return
	if not _interacting and _user_moved and idle_return and not _home.is_empty():
		_idle_s += dt
		if _idle_s > IDLE_DELAY_S:
			_user_moved = false
			_start_tween(_home, IDLE_RETURN_S)
	update(k)


## A frame while the view is covered: the camera holds still, the clocks run.
func step_hidden(dt: float) -> void:
	if not frame_updates:
		return
	if _tweening:
		_tween_t += dt
	elif not _interacting and _user_moved and idle_return:
		_idle_s += dt


## A tween stopped part way leaves the camera off the preset.
func _cancel_tween() -> void:
	if _tweening:
		_tweening = false
		_user_moved = true
	_idle_s = 0.0


func _moved() -> void:
	_user_moved = true
	_idle_s = 0.0


func _start_tween(to: Dictionary, seconds: float) -> void:
	_tween_from = {"theta": theta, "phi": phi, "dist": dist, "target": target, "fov": fov}
	var dest := to.duplicate()
	dest["theta"] = theta + wrapf(float(to["theta"]) - theta, -PI, PI)
	_tween_to = dest
	_tween_t = 0.0
	_tween_s = seconds
	_tweening = true


func _set_from(s: Dictionary) -> void:
	target = s["target"]
	theta = s["theta"]
	phi = s["phi"]
	dist = s["dist"]
	fov = s["fov"]
