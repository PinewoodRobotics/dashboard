class_name SmoothScroll
extends RefCounted

## Chromium's animated scroll for wheel notches and scrollbar track pages on
## Windows and Linux (cc/animation/scroll_offset_animation_curve.cc, ease-in-out
## curve). A wheel jump takes 12 frames at 60 Hz up to 120 px, shrinking to 6
## frames at 480 px (kInverseDelta); a page takes 9 frames (kConstant). Another
## step before the end retargets from the current offset and keeps the current
## velocity through the curve's first control point
## (EaseInOutWithInitialVelocity). macOS Chromium does not animate either.

const FRAME_S := 1.0 / 60.0
const RAMP_START_PX := 120.0
const RAMP_END_PX := 480.0
const MIN_FRAMES := 6.0
const MAX_FRAMES := 12.0
const CONSTANT_FRAMES := 9.0
const X1 := 0.42
const X2 := 0.58

static var enabled := OS.get_name() != "macOS"

var active := false
var target := 0.0
var _from := 0.0
var _t := 0.0
var _s := 0.0
var _y1 := 0.0


static func wheel_seconds(delta_px: float) -> float:
	var slope := (MIN_FRAMES - MAX_FRAMES) / (RAMP_END_PX - RAMP_START_PX)
	return clampf(MAX_FRAMES + (absf(delta_px) - RAMP_START_PX) * slope, MIN_FRAMES, MAX_FRAMES) * FRAME_S


static func page_seconds() -> float:
	return CONSTANT_FRAMES * FRAME_S


func start(from: float, to: float, seconds: float) -> void:
	var v := velocity() if active else 0.0
	var d := to - from
	_from = from
	target = to
	_t = 0.0
	_s = seconds
	_y1 = clampf(v * seconds / d, -1000.0, 1000.0) * X1 if d != 0.0 else 0.0
	active = d != 0.0 and seconds > 0.0


func value() -> float:
	if not active:
		return target
	return _from + (target - _from) * Easing.cubic_bezier(X1, _y1, X2, 1.0, _t / _s)


## Offset px per second at the current time.
func velocity() -> float:
	if not active:
		return 0.0
	var h := 1e-3
	var u := minf(_t / _s, 1.0 - h)
	var e0 := Easing.cubic_bezier(X1, _y1, X2, 1.0, u)
	var e1 := Easing.cubic_bezier(X1, _y1, X2, 1.0, u + h)
	return (e1 - e0) / h * (target - _from) / _s


func step(dt: float) -> float:
	_t += dt
	if _t >= _s:
		active = false
	return value()
