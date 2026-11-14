class_name TelemetryService
extends Node

## Robot pose, alliance and joint values from NT, resolved once per frame for
## every 3D view in every window.

const POSE_X := "/matchhud/state/robot_pose_x_m"
const POSE_Y := "/matchhud/state/robot_pose_y_m"
const POSE_HEADING := "/matchhud/state/robot_heading_rad"
const POSE_VALID := "/matchhud/state/robot_pose_valid"
const IS_RED := "/matchhud/state/is_red_alliance"

## Field center, as the web minimap starts.
const DEFAULT_POSE := Vector3(FieldFrame.HALF_LENGTH_M, FieldFrame.HALF_WIDTH_M, 0.0)

var nt: NtService
var rig := RigSolver.load_default()
var smoother := PoseSmoother.new()

## (x, y, heading) as last received, kept while disconnected (shown stale).
var pose_raw := DEFAULT_POSE
var has_pose := false
var pose_valid := false
## null while the topic is not live.
var alliance_red: Variant = null
## Joint key -> value used when the topic is not live (debug sliders).
var manual_joints := {}
var joint_targets := {}
var joint_values := {}


func _init() -> void:
	process_priority = -900


func _ready() -> void:
	if nt == null:
		nt = get_node_or_null("/root/NT") as NtService


func _process(delta: float) -> void:
	step(delta)


func step(dt: float) -> void:
	if nt == null:
		return
	if nt.has_value(POSE_X) and nt.has_value(POSE_Y) and nt.has_value(POSE_HEADING):
		pose_raw = Vector3(float(nt.value(POSE_X)), float(nt.value(POSE_Y)), float(nt.value(POSE_HEADING)))
		has_pose = true
	pose_valid = nt.value(POSE_VALID, false) == true
	alliance_red = bool(nt.value(IS_RED)) if nt.is_live(IS_RED) else null
	smoother.step(pose_raw.x, pose_raw.y, pose_raw.z, dt)

	var live := {}
	for j in rig.joints:
		if j.nt_topic != "" and nt.is_live(j.nt_topic):
			var v: Variant = nt.value(j.nt_topic)
			if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
				live[j.key] = float(v)
	joint_targets = rig.compute_joint_values(live, manual_joints)
	joint_values = rig.step(joint_targets, dt)


func pose_live() -> bool:
	return nt != null and nt.is_live(POSE_X) and nt.is_live(POSE_Y) and nt.is_live(POSE_HEADING)


func smoothed_pose() -> Vector3:
	return Vector3(smoother.x, smoother.y, smoother.heading)


func robot_world() -> Vector3:
	return FieldFrame.to_world(smoother.x, smoother.y)
