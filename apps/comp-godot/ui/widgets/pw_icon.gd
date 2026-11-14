class_name PwIcon
extends Control

## A lucide icon rasterized at its exact pixel size, centered in the control.

@export var icon_name := "":
	set(v):
		icon_name = v
		queue_redraw()
@export var px := 48:
	set(v):
		px = v
		queue_redraw()
@export var color := Color.WHITE:
	set(v):
		color = v
		queue_redraw()


func _init(name_: String = "", size_px: int = 48, tint: Color = Color.WHITE) -> void:
	icon_name = name_
	px = size_px
	color = tint
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(size_px, size_px)


func _draw() -> void:
	if icon_name == "":
		return
	var tex := Icons.texture(icon_name, px, Color(color.r, color.g, color.b, 1.0))
	if tex != null:
		draw_texture(tex, ((size - Vector2(px, px)) * 0.5).round(), Color(1, 1, 1, color.a))
