class_name DragGate
extends RefCounted

## When a press turns into a drag (useTouchscreenDnd.ts sensors): touch after
## a 200 ms hold that stays within 25 px, mouse after 8 px of travel. A touch
## that travels farther before the hold ends is a scroll or swipe, never a drag.

enum State { IDLE, PENDING, DRAGGING, CANCELLED }

const TOUCH_HOLD_MS := 200
const TOUCH_TOLERANCE_PX := 25.0
const MOUSE_DISTANCE_PX := 8.0

var state := State.IDLE
var is_touch := false
var start_pos := Vector2.ZERO
var start_ms := 0
var max_travel := 0.0


func begin(pos: Vector2, t_ms: int, touch: bool, enabled: bool = true) -> void:
	start_pos = pos
	start_ms = t_ms
	is_touch = touch
	max_travel = 0.0
	state = State.PENDING if enabled else State.CANCELLED


func move(pos: Vector2, t_ms: int) -> State:
	if state != State.PENDING:
		return state
	max_travel = maxf(max_travel, pos.distance_to(start_pos))
	if is_touch:
		if max_travel > TOUCH_TOLERANCE_PX:
			state = State.CANCELLED
		else:
			tick(t_ms)
	elif max_travel >= MOUSE_DISTANCE_PX:
		state = State.DRAGGING
	return state


func tick(t_ms: int) -> State:
	if state == State.PENDING and is_touch and t_ms - start_ms >= TOUCH_HOLD_MS:
		state = State.DRAGGING
	return state


func end() -> State:
	var s := state
	state = State.IDLE
	return s


func is_dragging() -> bool:
	return state == State.DRAGGING
