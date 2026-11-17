class_name Smoothing
extends RefCounted

## Frame-rate independent lerp factor: `rate` is the per-frame factor at 60 fps.
static func dt_lerp(rate: float, dt: float) -> float:
	return 1.0 - pow(1.0 - rate, dt * 60.0)


static func lerp_angle(a: float, b: float, t: float) -> float:
	return a + wrapf(b - a, -PI, PI) * t
