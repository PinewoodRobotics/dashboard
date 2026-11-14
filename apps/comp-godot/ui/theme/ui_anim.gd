class_name UiAnim
extends RefCounted

## A scalar transition stepped by the owner's _process (deterministic in tests).

var from := 0.0
var to := 0.0
var duration_s := 0.2
var elapsed_s := 0.0
var curve := Easing.css
var value := 0.0
var running := false


func _init(initial: float = 0.0) -> void:
	value = initial
	from = initial
	to = initial


func start(target: float, duration: float, ease_fn: Callable = Easing.css) -> void:
	from = value
	to = target
	duration_s = maxf(duration, 0.0)
	elapsed_s = 0.0
	curve = ease_fn
	running = duration_s > 0.0 and not is_equal_approx(from, to)
	if not running:
		value = to


func jump(v: float) -> void:
	value = v
	from = v
	to = v
	running = false


## Returns true on the step that finishes the transition.
func step(dt: float) -> bool:
	if not running:
		return false
	elapsed_s += dt
	var k := clampf(elapsed_s / duration_s, 0.0, 1.0)
	value = lerpf(from, to, curve.call(k))
	if k >= 1.0:
		value = to
		running = false
		return true
	return false
