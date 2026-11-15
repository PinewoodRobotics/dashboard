class_name TouchFling
extends RefCounted

## Chromium's touchscreen fling on Windows and Linux (ExperimentalFlingAnimation,
## ui/events/gestures/physics_based_fling_curve.cc) along one axis: the
## release velocity comes from a quadratic least-squares fit over the last
## 100 ms of the drag (VelocityTracker LSQ2), the fling travels v^2 / 2a at
## 2.7559e-5 in/ms^2 on a 96 dpi screen (capped at 3 viewports) over
## min(2 s, v / 2300) seconds along a cubic bezier whose start slope matches v.

const HORIZON_MS := 100.0
const STOPPED_MS := 80.0
const MIN_VELOCITY := 30.0
const MAX_VELOCITY := 17000.0
const DECEL_PX_PER_S2 := 2.7559e-5 * 96.0 * 1e6
const PIXEL_DECELERATION := 2300.0
const MAX_DURATION_S := 2.0
const BOUNDS_MULTIPLIER := 3.0
const P1 := Vector2(0.2, 1.0)
const P2 := Vector2(0.55, 1.0)

var _samples: Array = []
var distance := 0.0
var duration_s := 0.0
var _p1 := P1
var _t := 0.0
var _done_offset := 0.0
var active := false


func reset() -> void:
	_samples.clear()
	active = false


## pos: finger position along the axis in px, t_ms: event time.
func add_sample(pos: float, t_ms: float) -> void:
	_samples.append(Vector2(t_ms, pos))
	while _samples.size() > 2 and t_ms - (_samples[0] as Vector2).x > HORIZON_MS:
		_samples.pop_front()


## Finger velocity in px/s at release time t_ms.
func release_velocity(t_ms: float) -> float:
	if _samples.size() < 2:
		return 0.0
	var last: Vector2 = _samples[_samples.size() - 1]
	if t_ms - last.x > STOPPED_MS:
		return 0.0
	var pts: Array = _samples.filter(func(s: Vector2) -> bool: return last.x - s.x <= HORIZON_MS)
	if pts.size() < 2:
		return 0.0
	return clampf(_lsq_slope(pts, last.x) * 1000.0, -MAX_VELOCITY, MAX_VELOCITY)


static func _lsq_slope(pts: Array, t0: float) -> float:
	var n := float(pts.size())
	if pts.size() == 2:
		var a: Vector2 = pts[0]
		var b: Vector2 = pts[1]
		return (b.y - a.y) / (b.x - a.x) if b.x != a.x else 0.0
	var s1 := 0.0
	var s2 := 0.0
	var s3 := 0.0
	var s4 := 0.0
	var y0 := 0.0
	var y1 := 0.0
	var y2 := 0.0
	for p: Vector2 in pts:
		var x := p.x - t0
		s1 += x
		s2 += x * x
		s3 += x * x * x
		s4 += x * x * x * x
		y0 += p.y
		y1 += p.y * x
		y2 += p.y * x * x
	var m := Basis(Vector3(n, s1, s2), Vector3(s1, s2, s3), Vector3(s2, s3, s4))
	if absf(m.determinant()) < 1e-9:
		var a: Vector2 = pts[0]
		var b: Vector2 = pts[pts.size() - 1]
		return (b.y - a.y) / (b.x - a.x) if b.x != a.x else 0.0
	return (m.inverse() * Vector3(y0, y1, y2)).y


## Starts a fling of the content at velocity px/s (content direction), bounded
## by 3 lengths of the window along the axis. Returns false below Chromium's
## minimum fling velocity.
func start(velocity: float, window_len: float) -> bool:
	active = false
	if absf(velocity) < MIN_VELOCITY:
		return false
	var dist := velocity * velocity / (2.0 * DECEL_PX_PER_S2)
	dist = minf(dist, floorf(window_len * BOUNDS_MULTIPLIER))
	if dist <= 0.0:
		return false
	distance = signf(velocity) * dist
	duration_s = minf(MAX_DURATION_S, absf(velocity) / PIXEL_DECELERATION)
	var slope := absf(velocity * duration_s / distance)
	_p1 = P1
	if slope * _p1.x < 1.0:
		_p1.y = _p1.x * slope
	else:
		_p1.x = _p1.y / slope
	_t = 0.0
	_done_offset = 0.0
	active = true
	return true


## Advances by dt seconds; returns the offset to add since the last step.
func step(dt: float) -> float:
	if not active:
		return 0.0
	_t += dt
	var x := _t / duration_s if duration_s > 0.0 else 1.0
	var offset := distance
	if x < 1.0:
		offset = distance * Easing.cubic_bezier(_p1.x, _p1.y, P2.x, P2.y, x)
	else:
		active = false
	var d := offset - _done_offset
	_done_offset = offset
	return d
