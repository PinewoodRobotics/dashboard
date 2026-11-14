class_name AimPoint
extends RefCounted

## Port of the robot's AimPoint.java (FIR 2026Rebuilt util/AimPoint.java). The
## turret target depends on the zone the robot stands in. Zones and targets are
## blue-perspective fractions of the field; on red the robot mirrors X across
## the field center (not the PathPlanner rotation). Outside every zone the
## nearest zone center wins.

const LENGTH := FieldFrame.FIELD_LENGTH_M
const WIDTH := FieldFrame.FIELD_WIDTH_M

const FRONT_OF_HUB := "FRONT_OF_HUB"
const ZONES := [
	{"name": FRONT_OF_HUB, "min": Vector2(0.0, 0.0), "max": Vector2(0.25, 1.0), "target": Vector2(0.28, 0.5)},
	{"name": "LEFT_CENTER", "min": Vector2(0.25, 0.0), "max": Vector2(0.5, 0.45), "target": Vector2(0.2, 0.25)},
	{"name": "MIDDLE_CENTER", "min": Vector2(0.25, 0.45), "max": Vector2(0.5, 0.55), "target": Vector2(0.5, 0.75)},
	{"name": "RIGHT_CENTER", "min": Vector2(0.25, 0.55), "max": Vector2(0.5, 1.0), "target": Vector2(0.2, 0.75)},
]


static func _field(f: Vector2) -> Vector2:
	return Vector2(LENGTH * f.x, WIDTH * f.y)


static func _mirror(p: Vector2, red: bool) -> Vector2:
	return Vector2(LENGTH - p.x, p.y) if red else p


static func zone(pos: Vector2, red: bool) -> Dictionary:
	var blue := _mirror(pos, red)
	for z: Dictionary in ZONES:
		var lo := _field(z["min"])
		var hi := _field(z["max"])
		if blue.x >= lo.x and blue.x < hi.x and blue.y >= lo.y and blue.y < hi.y:
			return z
	var best: Dictionary = ZONES[0]
	var best_d := INF
	for z: Dictionary in ZONES:
		var d := blue.distance_to((_field(z["min"]) + _field(z["max"])) * 0.5)
		if d < best_d:
			best_d = d
			best = z
	return best


## Field point (blue-origin meters) the turret aims at from pos.
static func target(pos: Vector2, red: bool) -> Vector2:
	return _mirror(_field(zone(pos, red)["target"]), red)


static func hub(red: bool) -> Vector2:
	return _mirror(_field(ZONES[0]["target"]), red)


## Turret angle relative to the robot's heading (CCW, radians) that points at
## target from pose (x, y, heading), as ContinuousAimCommand computes it
## without lead compensation.
static func turret_angle(pose: Vector3, aim_at: Vector2) -> float:
	var d := aim_at - Vector2(pose.x, pose.y)
	return wrapf(atan2(d.y, d.x) - pose.z, -PI, PI)
