class_name SwipeRecognizer
extends RefCounted

## Dismiss swipes (useSwipeGesture.ts). Once either axis has moved 8 px the
## gesture is decided once: it tracks only if the main axis dominates and moves in the
## swipe direction, otherwise it is rejected for the rest of the touch. While
## tracking, delta follows the main axis clamped to [0, dimension]. Release
## commits at 35% of the dimension or 0.5 px/ms over the last 5 tracked moves.
##
## A slider or selector under the press stops some moves from reaching the
## swipe, as their touchmove stopPropagation does on the web. A selector
## (CustomSelector.tsx) lets only its first decided move through, and only if
## it is vertical, so a swipe down started on it moves one step and snaps
## back. A slider (CustomSlider.tsx) stops every move once one has gone more
## sideways than vertical.

enum Dir { DOWN, RIGHT }
enum State { IDLE, PENDING, TRACKING, REJECTED }
enum Outcome { NONE, COMMIT, SNAP_BACK }
enum Widget { NONE, SLIDER, SELECTOR }

const INTENT_PX := 8.0
const COMMIT_FRACTION := 0.35
const COMMIT_VELOCITY := 0.5
const VELOCITY_SAMPLES := 5

var dir := Dir.DOWN
var dimension := 515.0
var state := State.IDLE
var delta := 0.0
var _start := Vector2.ZERO
var _samples: Array = []
var _widget := Widget.NONE
var _widget_decided := false
var _widget_horizontal := false


func _init(direction: Dir = Dir.DOWN, dim: float = 515.0) -> void:
	dir = direction
	dimension = dim


## ctx: {"scroll_not_at_top": bool, "widget": Widget, "vetoed": bool}
func begin(pos: Vector2, t_ms: float, ctx: Dictionary = {}) -> void:
	_start = pos
	delta = 0.0
	_samples = []
	_widget = ctx.get("widget", Widget.NONE)
	_widget_decided = false
	_widget_horizontal = false
	state = State.REJECTED if blocks(dir, ctx) else State.PENDING


static func blocks(direction: Dir, ctx: Dictionary) -> bool:
	if ctx.get("vetoed", false):
		return true
	return direction == Dir.DOWN and ctx.get("scroll_not_at_top", false)


func _widget_stops(d: Vector2) -> bool:
	match _widget:
		Widget.SELECTOR:
			if _widget_decided:
				return true
			if absf(d.x) < INTENT_PX and absf(d.y) < INTENT_PX:
				return false
			_widget_decided = true
			return absf(d.x) > absf(d.y)
		Widget.SLIDER:
			if not _widget_horizontal and (absf(d.x) >= INTENT_PX or absf(d.y) >= INTENT_PX):
				_widget_horizontal = absf(d.x) > absf(d.y)
			return _widget_horizontal
	return false


func move(pos: Vector2, t_ms: float) -> State:
	if state == State.IDLE or state == State.REJECTED:
		return state
	var d := pos - _start
	if _widget_stops(d):
		return state
	var main := d.y if dir == Dir.DOWN else d.x
	var cross := d.x if dir == Dir.DOWN else d.y
	if state == State.PENDING:
		if absf(d.x) < INTENT_PX and absf(d.y) < INTENT_PX:
			return state
		if absf(cross) > absf(main) or main < 0.0:
			state = State.REJECTED
			return state
		state = State.TRACKING
	delta = clampf(main, 0.0, dimension)
	_samples.append([t_ms, delta])
	if _samples.size() > VELOCITY_SAMPLES:
		_samples.pop_front()
	return state


## px/ms over the retained samples.
func velocity() -> float:
	if _samples.size() < 2:
		return 0.0
	var a: Array = _samples[0]
	var b: Array = _samples[_samples.size() - 1]
	var dt := float(b[0]) - float(a[0])
	return (float(b[1]) - float(a[1])) / dt if dt > 0.0 else 0.0


func end() -> Outcome:
	var was := state
	state = State.IDLE
	if was != State.TRACKING:
		return Outcome.NONE
	if delta >= dimension * COMMIT_FRACTION or velocity() >= COMMIT_VELOCITY:
		return Outcome.COMMIT
	return Outcome.SNAP_BACK


func cancel() -> void:
	state = State.IDLE


func is_tracking() -> bool:
	return state == State.TRACKING
