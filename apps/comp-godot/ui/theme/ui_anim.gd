class_name UiAnim
extends RefCounted

## A scalar transition stepped by the owner's _process (deterministic in tests).
##
## With hold_until_drawn set and frame holds enabled (windowed runs), a started
## transition shows its from-value until the frame that shows it has been
## drawn, then advances at most one 60 Hz frame on its first step. Like a
## compositor animation in the browser, whose clock starts at the first painted
## frame, so building and first-drawing a tab or panel never eats the motion.

const FIRST_STEP_S := 1.0 / 60.0
## Steps a held transition waits for a drawn frame before it starts anyway
## (no window drawing, e.g. minimized).
const MAX_HOLD_STEPS := 3

static var frame_holds := false
static var _held: Array[UiAnim] = []

var from := 0.0
var to := 0.0
var duration_s := 0.2
var delay_s := 0.0
var elapsed_s := 0.0
var curve := Easing.css
var value := 0.0
var running := false
var hold_until_drawn := false
var held := false
var _hold_steps := 0
var _first_step := false


func _init(initial: float = 0.0, holds: bool = false) -> void:
	value = initial
	from = initial
	to = initial
	hold_until_drawn = holds


## Turns frame holds on and releases held transitions after every drawn frame.
static func enable_frame_holds() -> void:
	if frame_holds:
		return
	frame_holds = true
	RenderingServer.frame_post_draw.connect(release_held)


static func release_held() -> void:
	for a in _held:
		if a.held:
			a.held = false
			a._first_step = true
	_held.clear()


func start(target: float, duration: float, ease_fn: Callable = Easing.css, delay: float = 0.0) -> void:
	from = value
	to = target
	duration_s = maxf(duration, 0.0)
	delay_s = maxf(delay, 0.0)
	elapsed_s = 0.0
	curve = ease_fn
	running = (duration_s > 0.0 or delay_s > 0.0) and not is_equal_approx(from, to)
	held = false
	_first_step = false
	if not running:
		value = to
	elif hold_until_drawn and frame_holds:
		held = true
		_hold_steps = 0
		_held.append(self)


## A CSS keyframe animation: always plays from `from_value`, wherever it was.
func play(from_value: float, target: float, duration: float, ease_fn: Callable = Easing.css) -> void:
	jump(from_value)
	start(target, duration, ease_fn)


## A CSS transition to `target`: one already heading there keeps going, and
## reversing a running one back to where it started takes only as long as the
## part already played (the CSS reversing shortening factor).
func retarget(target: float, duration: float, ease_fn: Callable = Easing.css, delay: float = 0.0) -> void:
	if is_equal_approx(to, target) and (running or is_equal_approx(value, target)):
		return
	if running and is_equal_approx(from, target) and not is_equal_approx(from, to):
		duration *= clampf((value - from) / (to - from), 0.0, 1.0)
	start(target, duration, ease_fn, delay)


func jump(v: float) -> void:
	value = v
	from = v
	to = v
	running = false
	held = false


## Returns true on the step that finishes the transition.
func step(dt: float) -> bool:
	if not running:
		return false
	if held:
		_hold_steps += 1
		if _hold_steps < MAX_HOLD_STEPS:
			return false
		held = false
		_first_step = true
	if _first_step:
		_first_step = false
		dt = minf(dt, FIRST_STEP_S)
	elapsed_s += dt
	if elapsed_s < delay_s:
		return false
	var k := clampf((elapsed_s - delay_s) / duration_s, 0.0, 1.0) if duration_s > 0.0 else 1.0
	value = lerpf(from, to, curve.call(k))
	if k >= 1.0:
		value = to
		running = false
		return true
	return false
