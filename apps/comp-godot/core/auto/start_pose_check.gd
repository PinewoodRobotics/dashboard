class_name StartPoseCheck
extends RefCounted

## Pre-match placement check: the live robot pose against the selected auto's
## first pose, both (x, y, heading) in blue-origin field meters and radians.

const OK_M := 0.15
const OK_DEG := 8.0

enum Level { OK, OFF, INVALID }


static func compare(robot: Vector3, start: Vector3, pose_valid: bool = true) -> Dictionary:
	var dist := Vector2(robot.x, robot.y).distance_to(Vector2(start.x, start.y))
	var deg := absf(rad_to_deg(angle_difference(robot.z, start.z)))
	var level := Level.INVALID
	if pose_valid:
		level = Level.OK if dist <= OK_M and deg <= OK_DEG else Level.OFF
	return {"dist_m": dist, "heading_deg": deg, "level": level}


static func text(c: Dictionary) -> String:
	if c.is_empty():
		return ""
	match c["level"]:
		Level.OK:
			return "On start pose (%.2f m / %.0f°)" % [c["dist_m"], c["heading_deg"]]
		Level.OFF:
			return "Start pose off by %s / %.0f°" % [distance_text(c["dist_m"]), c["heading_deg"]]
	return "Start pose unknown: robot pose not valid"


static func distance_text(m: float) -> String:
	return "%.2f m" % m if m < 10.0 else "%.1f m" % m
