class_name ColorAnim
extends RefCounted

## A color under a CSS transition: set() retargets it like a style change,
## step() advances it from the owner's _process. Interpolates premultiplied,
## as browsers do, so fading from transparent does not pass through gray.

var from := Color.TRANSPARENT
var to := Color.TRANSPARENT
var _t := UiAnim.new(1.0)


func _init(initial: Color = Color.TRANSPARENT) -> void:
	jump(initial)


func value() -> Color:
	return mix(from, to, _t.value)


func running() -> bool:
	return _t.running


func target() -> Color:
	return to if _t.to >= 0.5 else from


func jump(c: Color) -> void:
	from = c
	to = c
	_t.jump(1.0)


func set_target(c: Color, duration: float, curve: Callable = Easing.css, delay: float = 0.0) -> void:
	if c.is_equal_approx(target()):
		return
	if duration <= 0.0 and delay <= 0.0:
		jump(c)
		return
	if _t.running and (c.is_equal_approx(from) or c.is_equal_approx(to)):
		_t.retarget(0.0 if c.is_equal_approx(from) else 1.0, duration, curve, delay)
		return
	from = value()
	to = c
	_t.jump(0.0)
	_t.start(1.0, duration, curve, delay)


func step(dt: float) -> bool:
	return _t.step(dt)


static func mix(a: Color, b: Color, t: float) -> Color:
	if t <= 0.0:
		return a
	if t >= 1.0:
		return b
	var alpha := lerpf(a.a, b.a, t)
	if alpha <= 0.0:
		return Color(b, 0.0)
	var r := lerpf(a.r * a.a, b.r * b.a, t) / alpha
	var g := lerpf(a.g * a.a, b.g * b.a, t) / alpha
	var bl := lerpf(a.b * a.a, b.b * b.a, t) / alpha
	return Color(r, g, bl, alpha)
