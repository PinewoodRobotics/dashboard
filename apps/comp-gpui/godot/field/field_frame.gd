class_name FieldFrame
extends RefCounted

## WPILib blue-origin field pose (x along the field, y left, heading CCW) to the
## Godot world of field.glb (Y up, centered, blue alliance wall at +X).
## Uses the official 16.541 x 8.069 m carpet, not the 8.21 m the web minimap used.

const FIELD_LENGTH_M := 16.541
const FIELD_WIDTH_M := 8.069
const HALF_LENGTH_M := FIELD_LENGTH_M / 2.0
const HALF_WIDTH_M := FIELD_WIDTH_M / 2.0

## PathPlannerLib FlippingUtil field size (rotational symmetry).
const PP_FIELD_SIZE := Vector2(16.54, 8.07)


static func to_world(x: float, y: float) -> Vector3:
	return Vector3(HALF_LENGTH_M - x, 0.0, y - HALF_WIDTH_M)


static func from_world(p: Vector3) -> Vector2:
	return Vector2(HALF_LENGTH_M - p.x, p.z + HALF_WIDTH_M)


## Rotation about +Y for the robot wrapper (model forward is +Z).
static func yaw(heading: float) -> float:
	return heading - PI / 2.0


static func robot_transform(x: float, y: float, heading: float) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, yaw(heading)), to_world(x, y))


static func forward(heading: float) -> Vector3:
	return Basis(Vector3.UP, yaw(heading)) * Vector3.BACK


## PathPlanner alliance flip of a blue-origin pose (x, y, heading).
static func flip(pose: Vector3) -> Vector3:
	return Vector3(PP_FIELD_SIZE.x - pose.x, PP_FIELD_SIZE.y - pose.y, wrapf(pose.z + PI, -PI, PI))
