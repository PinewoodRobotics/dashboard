class_name OrbitCamera
extends RefCounted

## Driver-view orbit camera (DriverRobotViewer.tsx): spherical coordinates
## around a target, presets from camera-poses.json reached by a 400 ms
## easeOutCubic tween on the shortest arc, user orbit and zoom within the web
## limits, and an idle return to the selected preset 1000 ms after the last
## input, over 600 ms. Time is passed in, so tests drive it directly.

const MIN_POLAR := 0.1
const MAX_POLAR := PI / 2.0 - 0.05
const MIN_DIST := 0.5
const MAX_DIST := 4.0
const PRESET_TWEEN_S := 0.4
const IDLE_DELAY_S := 1.0
const IDLE_RETURN_S := 0.6
const ROTATE_RAD_PER_PX := 0.006
const ZOOM_STEP := 0.9

var presets: Array = []
var preset := 0
var target := Vector3.ZERO
var theta := 0.0
var phi := 1.0
var dist := 2.0
var fov := 50.0
var idle_return := true

var _tween_from := {}
var _tween_to := {}
var _tween_t := 0.0
var _tween_s := 0.0
var _tweening := false
var _idle_s := 0.0
var _user_moved := false
var _interacting := false


static func load_presets(path: String) -> Array:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		return []
	var out: Array = []
	for s: Dictionary in parsed.get("states", []):
		out.append(pose_to_spherical(s))
	return out


## {target, theta, phi, dist, fov, label} from a {position, target, fov} pose.
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
		"phi": clampf(acos(clampf(off.y / r, -1.0, 1.0)), MIN_POLAR, MAX_POLAR),
		"dist": clampf(r, MIN_DIST, MAX_DIST),
		"fov": float(pose.get("fov", 50.0)),
	}


func _init(preset_list: Array = []) -> void:
	presets = preset_list
	if not presets.is_empty():
		_set_from(presets[0])


func position() -> Vector3:
	return target + dist * Vector3(sin(phi) * sin(theta), cos(phi), sin(phi) * cos(theta))


func is_tweening() -> bool:
	return _tweening


func select_preset(index: int, animate: bool = true) -> void:
	if index < 0 or index >= presets.size():
		return
	preset = index
	_user_moved = false
	_idle_s = 0.0
	if animate:
		_start_tween(presets[index], PRESET_TWEEN_S)
	else:
		_tweening = false
		_set_from(presets[index])


func begin_interaction() -> void:
	_interacting = true
	_tweening = false
	_idle_s = 0.0


func end_interaction() -> void:
	_interacting = false
	_idle_s = 0.0


func orbit(dx_px: float, dy_px: float) -> void:
	_tweening = false
	theta -= dx_px * ROTATE_RAD_PER_PX
	phi = clampf(phi - dy_px * ROTATE_RAD_PER_PX, MIN_POLAR, MAX_POLAR)
	_user_moved = true
	_idle_s = 0.0


## steps > 0 zooms in.
func zoom(steps: float) -> void:
	_tweening = false
	dist = clampf(dist * pow(ZOOM_STEP, steps), MIN_DIST, MAX_DIST)
	_user_moved = true
	_idle_s = 0.0


func step(dt: float) -> void:
	if _tweening:
		_tween_t += dt
		var k := Easing.out_cubic(_tween_t / _tween_s)
		theta = lerpf(_tween_from["theta"], _tween_to["theta"], k)
		phi = lerpf(_tween_from["phi"], _tween_to["phi"], k)
		dist = lerpf(_tween_from["dist"], _tween_to["dist"], k)
		target = (_tween_from["target"] as Vector3).lerp(_tween_to["target"], k)
		fov = lerpf(_tween_from["fov"], _tween_to["fov"], k)
		if _tween_t >= _tween_s:
			_tweening = false
			_set_from(_tween_to)
		return
	if _interacting or not _user_moved or not idle_return:
		return
	_idle_s += dt
	if _idle_s >= IDLE_DELAY_S and preset < presets.size():
		_user_moved = false
		_start_tween(presets[preset], IDLE_RETURN_S)


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
