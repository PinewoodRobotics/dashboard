class_name MinimapCamera
extends RefCounted

## HUD minimap camera math (MiniMap3D.tsx): a spherical rig around a target
## that trails the robot. Settings: mode "follow" | "driver", angle 0..1, zoom 0..1.

const FOV_DEG := 50.0
const NEAR := 0.1
const FAR := 100.0
const ZOOM_NEAR := 2.0
const ZOOM_FAR := 11.05
const POLAR_TOP := 0.08
const POLAR_LOW := 1.35
const LERP_POS := 0.15
const LERP_THETA := 0.10
const LERP_SPHERE := 0.1
const TARGET_HEIGHT := 0.3

var phi := 0.0
var dist := 0.0
var theta := 0.0
var target := Vector3.ZERO
var initialized := false


static func target_phi(angle: float) -> float:
	return POLAR_LOW - angle * (POLAR_LOW - POLAR_TOP)


static func target_dist(zoom: float) -> float:
	return ZOOM_FAR + zoom * (ZOOM_NEAR - ZOOM_FAR)


static func desired_target(robot_world: Vector3, zoom: float) -> Vector3:
	return Vector3(robot_world.x, TARGET_HEIGHT, lerpf(0.0, robot_world.z, zoom))


static func desired_theta(mode: String, heading: float, is_red: Variant) -> float:
	if mode == "driver":
		return -PI / 2.0 if is_red == true else PI / 2.0
	return heading + PI / 2.0


## First call snaps to the goal so the view does not swoop in on startup.
func step(dt: float, robot_world: Vector3, heading: float, settings: Dictionary, is_red: Variant) -> void:
	var angle: float = settings.get("angle", 0.3)
	var zoom: float = settings.get("zoom", 0.5)
	var mode: String = settings.get("mode", "follow")
	var goal_target := desired_target(robot_world, zoom)
	var goal_theta := desired_theta(mode, heading, is_red)
	if not initialized:
		phi = target_phi(angle)
		dist = target_dist(zoom)
		target = goal_target
		theta = goal_theta
		initialized = true
		return
	var k_sphere := Smoothing.dt_lerp(LERP_SPHERE, dt)
	phi += (target_phi(angle) - phi) * k_sphere
	dist += (target_dist(zoom) - dist) * k_sphere
	target = target.lerp(goal_target, Smoothing.dt_lerp(LERP_POS, dt))
	theta = Smoothing.lerp_angle(theta, goal_theta, Smoothing.dt_lerp(LERP_THETA, dt))


func position() -> Vector3:
	return target + dist * Vector3(sin(phi) * sin(theta), cos(phi), sin(phi) * cos(theta))
