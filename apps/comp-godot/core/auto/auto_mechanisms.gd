class_name AutoMechanisms
extends RefCounted

## Robot pose and mechanism state of one exported auto as a pure function of t,
## so jumping to t and playing to t agree exactly. Joint values come out in raw
## NT units (what the robot would publish) and go through the same RigSolver as
## live data. Rules, from data/auto_commands.json and the robot code:
## - wrist: the most recently started running intake command holds the intake;
##   with none, the intake's default command holds its location. The wrist
##   eases to each new setpoint at the modeled travel rate.
## - turret: aims at AimPoint's target while ContinuousAimCommand runs, and
##   while the turret's default command aims (GPS assist on, the robot's
##   default), easing in and out over AIM_BLEND_S.
## - shooter and rollers: on while a running command has that effect.
## Events that never run on the robot (unregistered commands, markers nothing
## is bound to) move nothing; the timeline items mark them.

const COMMANDS_PATH := "res://data/auto_commands.json"
const INSTANT_S := 0.021
const AIM_BLEND_S := 0.4
## Pose shown for an auto without a path: the Move Forward And Shoot Center
## start, blue-origin.
const NO_PATH_POSE_BLUE := Vector3(3.3705284, 4.0264605, 2.3561945)
const CLIMBER_STOWED_RAW := 0.0
const WRIST_JOINT := "index_wrist"
const TURRET_JOINT := "turret"
const CLIMBER_JOINT := "climber_inner"

enum Kind { AIM, SHOOTER, INTAKE, NOOP, OTHER }
const KIND_NAMES := ["aim", "shooter", "intake", "noop", "other"]

var playback: AutoPlayback
var duration := 0.0
## Timeline items for the scrub bar, pins and event feed, in export order:
## {name, t0, t1, kind: Kind, runs: bool, instant: bool, note: String}
var items: Array = []
var wrist_default := 0.0
var wrist_rate := INF
var rollers_default := false
## Piecewise-constant intake holder: [{t, target, rollers, from}]; `from` is
## the wrist position when the segment starts.
var _wrist: Array = []
var _aim_cmd: Array = []
var _shooter: Array = []


static func load_config(path: String = COMMANDS_PATH) -> Dictionary:
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return d if d is Dictionary else {}


func _init(p: AutoPlayback, config: Dictionary) -> void:
	playback = p
	duration = p.timeline_s()
	var wrist: Dictionary = config.get("wrist", {})
	var setpoints: Dictionary = wrist.get("setpoints_rot", {})
	var defaults: Dictionary = config.get("intake_default_command", {})
	wrist_default = float(setpoints.get(defaults.get("wrist", ""), 0.0))
	rollers_default = bool(defaults.get("rollers", false))
	if not setpoints.is_empty():
		var span: float = setpoints.values().max() - setpoints.values().min()
		wrist_rate = span / maxf(float(wrist.get("travel_s", 0.5)), 1e-3) if span > 0.0 else INF
	var commands: Dictionary = config.get("commands", {})
	var intake: Array = []
	for e: Dictionary in p.events:
		var cmd_name := str(e.get("name", ""))
		var effect: Dictionary = commands.get(cmd_name, {}).get("effect", {})
		var t0 := clampf(float(e["t0"]), 0.0, duration)
		var t1 := clampf(float(e["t1"]), t0, duration)
		var runs := _runs(e)
		items.append({"name": cmd_name, "t0": t0, "t1": t1, "kind": _kind(e, effect), "runs": runs,
			"instant": float(e["t1"]) - float(e["t0"]) <= INSTANT_S, "note": _note(e, runs)})
		if not runs:
			continue
		if effect.get("aim", false):
			_aim_cmd.append([t0, t1])
		if effect.get("shooter", false):
			_shooter.append([t0, t1])
		if effect.has("wrist"):
			intake.append({"t0": t0, "t1": t1, "target": float(setpoints.get(effect["wrist"], wrist_default)),
				"rollers": bool(effect.get("rollers", false))})
	_aim_cmd = _merge(_aim_cmd)
	_shooter = _merge(_shooter)
	_build_wrist(intake)


static func _runs(e: Dictionary) -> bool:
	var kind := str(e.get("kind", ""))
	if kind == "command":
		return bool(e.get("registered", false))
	if kind == "marker" or kind == "zone_marker":
		return bool(e.get("trigger_bound", false)) and bool(e.get("registered", false))
	return false


static func _kind(e: Dictionary, effect: Dictionary) -> Kind:
	if str(e.get("kind", "")) == "noop" or not bool(e.get("registered", false)):
		return Kind.NOOP
	if effect.get("aim", false):
		return Kind.AIM
	if effect.get("shooter", false):
		return Kind.SHOOTER
	if effect.has("wrist") or effect.has("rollers"):
		return Kind.INTAKE
	return Kind.OTHER


static func _note(e: Dictionary, runs: bool) -> String:
	if runs:
		return ""
	if str(e.get("kind", "")).ends_with("marker"):
		return "marker only, nothing bound on robot"
	return "no-op on robot"


static func _merge(intervals: Array) -> Array:
	intervals.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var out: Array = []
	for iv: Array in intervals:
		if not out.is_empty() and iv[0] <= out.back()[1]:
			out.back()[1] = maxf(out.back()[1], iv[1])
		else:
			out.append([iv[0], iv[1]])
	return out


func _build_wrist(intake: Array) -> void:
	var cuts: Array[float] = [0.0]
	for e: Dictionary in intake:
		cuts.append(e["t0"])
		cuts.append(e["t1"])
	cuts.sort()
	for c in cuts:
		var holder := {}
		for e: Dictionary in intake:
			if e["t0"] <= c and c < e["t1"] and (holder.is_empty() or e["t0"] >= holder["t0"]):
				holder = e
		var target: float = holder.get("target", wrist_default)
		var rollers: bool = holder.get("rollers", rollers_default)
		if not _wrist.is_empty() and _wrist.back()["target"] == target and _wrist.back()["rollers"] == rollers:
			continue
		if not _wrist.is_empty() and _wrist.back()["t"] == c:
			_wrist.pop_back()
		var from := wrist_default if _wrist.is_empty() else _ease_wrist(_wrist.back(), c)
		_wrist.append({"t": c, "target": target, "rollers": rollers, "from": from})


func _ease_wrist(seg: Dictionary, t: float) -> float:
	var from: float = seg["from"]
	var target: float = seg["target"]
	var travel := absf(target - from) / wrist_rate
	if travel <= 0.0:
		return target
	return lerpf(from, target, smoothstep(0.0, 1.0, (t - float(seg["t"])) / travel))


func _wrist_segment(t: float) -> Dictionary:
	var seg: Dictionary = _wrist[0]
	for s: Dictionary in _wrist:
		if s["t"] > t:
			break
		seg = s
	return seg


static func _inside(intervals: Array, t: float, end: float) -> bool:
	for iv: Array in intervals:
		if t >= iv[0] and (t < iv[1] or (iv[1] >= end and t <= end)):
			return true
	return false


func wrist_raw(t: float) -> float:
	return _ease_wrist(_wrist_segment(t), t)


func wrist_target_raw(t: float) -> float:
	return _wrist_segment(t)["target"]


func rollers_on(t: float) -> bool:
	return _wrist_segment(t)["rollers"]


func shooter_on(t: float) -> bool:
	return _inside(_shooter, t, duration)


func aim_command_on(t: float) -> bool:
	return _inside(_aim_cmd, t, duration)


func _aim_intervals(gps_assist: bool) -> Array:
	return [[0.0, duration]] if gps_assist else _aim_cmd


func no_path_pose(alliance: StringName) -> Vector3:
	return FieldFrame.flip(NO_PATH_POSE_BLUE) if alliance == AutoPlayback.RED else NO_PATH_POSE_BLUE


## (x, y, heading) blue-origin at t for the alliance's samples.
func pose_at(t: float, alliance: StringName) -> Vector3:
	return playback.sample_pose(t, alliance) if playback.has_path() else no_path_pose(alliance)


func aim_target(t: float, alliance: StringName) -> Vector2:
	var p := pose_at(t, alliance)
	return AimPoint.target(Vector2(p.x, p.y), alliance == AutoPlayback.RED)


func aim_angle(t: float, alliance: StringName) -> float:
	return AimPoint.turret_angle(pose_at(t, alliance), aim_target(t, alliance))


## Turret angle relative to the chassis (CCW radians) at t.
func turret_angle(t: float, alliance: StringName, gps_assist: bool) -> float:
	var last_end := -1.0
	for iv: Array in _aim_intervals(gps_assist):
		if t >= iv[0] and (t < iv[1] or (iv[1] >= duration and t <= duration)):
			var th := aim_angle(t, alliance)
			if iv[0] <= 0.0:
				return th
			return lerp_angle(0.0, th, smoothstep(0.0, AIM_BLEND_S, t - iv[0]))
		if iv[1] <= t:
			last_end = iv[1]
	if last_end < 0.0:
		return 0.0
	return lerp_angle(aim_angle(last_end, alliance), 0.0, smoothstep(0.0, AIM_BLEND_S, t - last_end))


## Everything the preview draws at t. raw: joint key -> raw NT value, ready
## for RigSolver.compute_joint_values.
func state_at(t: float, alliance: StringName, gps_assist: bool = true) -> Dictionary:
	t = clampf(t, 0.0, duration)
	var turret := turret_angle(t, alliance, gps_assist)
	var aiming := _inside(_aim_intervals(gps_assist), t, duration)
	return {
		"t": t,
		"pose": pose_at(t, alliance),
		"raw": {WRIST_JOINT: wrist_raw(t), TURRET_JOINT: turret / TAU, CLIMBER_JOINT: CLIMBER_STOWED_RAW},
		"turret_rad": turret,
		"wrist_target_raw": wrist_target_raw(t),
		"aim": aiming,
		"aim_source": ("command" if aim_command_on(t) else "default") if aiming else "",
		"aim_target": aim_target(t, alliance),
		"shooter": shooter_on(t),
		"rollers": rollers_on(t),
	}


## Items whose start lies in (t_from, t_to], for the event feed.
func items_started(t_from: float, t_to: float) -> Array:
	return items.filter(func(it: Dictionary) -> bool: return it["t0"] > t_from and it["t0"] <= t_to)
