class_name PwRect
extends Control

## ColorRect drawn from the UiDraw atlas, so it batches with the shapes on top.

@export var color := Color.WHITE:
	set(v):
		color = v
		queue_redraw()


func _init(c: Color = Color.WHITE) -> void:
	color = c
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	UiDraw.rect(get_canvas_item(), Rect2(Vector2.ZERO, size), color)
