class_name Topics
extends RefCounted

const MATCH_STATE_PREFIX := "/matchhud/state/"

## Every /matchhud/state/* topic the robot publishes (MatchStatusSubsystem.java), with NT types.
const MATCH_STATE := {
	"seq": "int",
	"robot_time_us": "int",
	"connected": "boolean",
	"is_red_alliance": "boolean",
	"enabled": "boolean",
	"autonomous": "boolean",
	"game_specific_message": "string",
	"match_phase": "int",
	"hub_status": "int",
	"header_color": "int",
	"total_time_remaining_s": "double",
	"period_time_remaining_s": "double",
	"shift_time_remaining_s": "double",
	"shift_time_with_buffer_s": "double",
	"buffer_remaining_s": "double",
	"is_shooting": "boolean",
	"show_shift_indicator": "boolean",
	"show_buffer": "boolean",
	"robot_pose_x_m": "double",
	"robot_pose_y_m": "double",
	"robot_heading_rad": "double",
	"robot_pose_valid": "boolean",
	"auto_align_active": "boolean",
	"auto_align_distance_m": "double",
	"auto_align_ready": "boolean",
	"driver_override": "boolean",
	"aim_mode": "int",
	"camera_topic": "string",
}

## Read by the web dashboard but never published by the FIR robot.
const MATCH_STATE_OPTIONAL := ["camera_topic"]

const JOINT_WRIST := "/AdvantageKit/RealOutputs/IntakeSubsystem/WristPosition"
const JOINT_TURRET := "/AdvantageKit/RealOutputs/Turret/PositionRot"
const JOINT_CLIMBER := "/AdvantageKit/RealOutputs/Climber/CurrentHeightMeters"
const JOINT_TOPICS := [JOINT_WRIST, JOINT_TURRET, JOINT_CLIMBER]

const READOUT_TOPICS := {
	"/AdvantageKit/RealOutputs/Turret/DistanceToTarget": "double",
	"/AdvantageKit/RealOutputs/Shooter/RequestedVelocityRPM": "double",
	"/AdvantageKit/RealOutputs/Shooter/VelocityRPM": "double",
	"/AdvantageKit/RealOutputs/Shooter/LeaderVelocityRPM": "double",
	"/AdvantageKit/RealOutputs/Shooter/FollowerVelocityRPM": "double",
	"/AdvantageKit/RealOutputs/Turret/PositionDeg": "double",
	"/AdvantageKit/RealOutputs/Turret/Angle": "double",
	"/AdvantageKit/RealOutputs/Shooter/IsSpunUp": "boolean",
	"/AdvantageKit/RealOutputs/ShooterSubsystem/GPSAssistFeaturesEnabled": "boolean",
	"/AdvantageKit/RealOutputs/MatchStatus/isShooting": "boolean",
}

const LANE_ADJUSTING_VELOCITY := "/AdvantageKit/RealOutputs/SwerveSubsystem/AdjustingVelocity"

const AIM_TRIM_PUBLISH := "/Tuning/Turret/AimTrimDeg"
const AIM_TRIM_READBACK := "/AdvantageKit/NetworkInputs/Tuning/Turret/AimTrimDeg"

const PP_CURRENT_SELECTED_AUTO := "/AdvantageKit/RealOutputs/PathPlanner/CurrentSelectedAuto"
const PP_SELECTED_AUTO_VALID := "/AdvantageKit/RealOutputs/PathPlanner/SelectedAutoValid"
const PP_VALID_AUTOS := "/AdvantageKit/RealOutputs/PathPlanner/ValidNames/Autos"
## Optional: AutoLibrary.source_hash() of the robot's deploy/pathplanner, which
## the robot code publishes only once it adds the README's snippet.
const PP_DEPLOY_HASH := "/AdvantageKit/RealOutputs/PathPlanner/DeployHash"

const INTAKE_SPEED_ENTRY := "Intake/Speed"

const PERIODIC_FAST := 0.02
const PERIODIC_DEFAULT := 0.1


static func match_topic(key: String) -> String:
	return MATCH_STATE_PREFIX + key


static func _trim_slashes(s: String) -> String:
	var t := s.strip_edges()
	while t.begins_with("/"):
		t = t.substr(1)
	while t.ends_with("/"):
		t = t.substr(0, t.length() - 1)
	return t


## Port of ntPathFromTableAndEntry in packages/shared-core/src/settings-schema.ts.
static func nt_path(table: String, entry: String) -> String:
	return "/%s/%s" % [_trim_slashes(table), _trim_slashes(entry)]


static func request_state(table: String, entry: String) -> Dictionary:
	var base := nt_path(table, entry)
	return {"request": base + "/Request", "state": base + "/State"}


static func selected_auto_topics(nt_settings: Dictionary) -> Dictionary:
	return request_state(nt_settings.get("sharedTable", "Shared"), nt_settings.get("selectedPathTopic", "PathPlanner/SelectedPath"))


static func intake_speed_topics(nt_settings: Dictionary) -> Dictionary:
	return request_state(nt_settings.get("sharedTable", "Shared"), INTAKE_SPEED_ENTRY)


## Subscription groups sent in one batch on connect: the match table and the
## joints at 20 ms, everything else at the server default 100 ms.
static func subscription_groups(nt_settings: Dictionary) -> Array:
	var auto_t := selected_auto_topics(nt_settings)
	var intake_t := intake_speed_topics(nt_settings)
	var slow := PackedStringArray(READOUT_TOPICS.keys())
	slow.append_array([
		LANE_ADJUSTING_VELOCITY,
		AIM_TRIM_READBACK,
		auto_t["state"],
		intake_t["state"],
		PP_CURRENT_SELECTED_AUTO,
		PP_SELECTED_AUTO_VALID,
		PP_VALID_AUTOS,
		PP_DEPLOY_HASH,
	])
	return [
		{"topics": PackedStringArray([MATCH_STATE_PREFIX]), "options": {"prefix": true, "periodic": PERIODIC_FAST}},
		{"topics": PackedStringArray(JOINT_TOPICS), "options": {"periodic": PERIODIC_FAST}},
		{"topics": slow, "options": {"periodic": PERIODIC_DEFAULT}},
	]
