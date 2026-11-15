class_name DragGhost
extends Control

## The dnd-kit DragOverlay (TouchscreenDragGhost.tsx): the dragged tab's bare
## white outline symbol at 80% opacity, centered in a box the size of the
## dragged element that keeps the grab offset from the pointer. On drop it
## glides onto the source element's final slot (250 ms ease); with no slot
## left (the item left the rail) it vanishes at once.

signal landed

const DROP_S := 0.25

var symbol := 0
var _t := UiAnim.new(0.0)
var _from := Vector2.ZERO
var _to := Vector2.ZERO


func _init() -> void:
	name = "DragGhost"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false


func show_rect(sym: int, r: Rect2) -> void:
	symbol = sym
	_t.jump(0.0)
	size = r.size
	position = r.position
	visible = true
	queue_redraw()


func move_to(top_left: Vector2) -> void:
	if not dropping():
		position = top_left


func drop_to(top_left: Vector2) -> void:
	_from = position
	_to = top_left
	_t.play(0.0, 1.0, DROP_S)
	if not _t.running:
		_land()


func dropping() -> bool:
	return visible and _t.running


func hide_now() -> void:
	_t.jump(0.0)
	visible = false


func step(dt: float) -> void:
	if not _t.running:
		return
	var done := _t.step(dt)
	position = _from.lerp(_to, _t.value)
	if done:
		_land()


func _land() -> void:
	visible = false
	landed.emit()


func _draw() -> void:
	UiDraw.begin(self)
	Sf.draw(self, symbol, size * 0.5, Tokens.ICON, Color(1, 1, 1, 0.8))
