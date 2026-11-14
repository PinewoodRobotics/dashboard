class_name DragGhost
extends Control

## The dragged tab: a bare white 48 px glyph at 80% opacity on the pointer.

var icon_name := ""


func _init() -> void:
	name = "DragGhost"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size = Vector2(Tokens.ICON, Tokens.ICON)
	visible = false


func show_at(icon: String, canvas_pos: Vector2) -> void:
	icon_name = icon
	visible = true
	move_to(canvas_pos)
	queue_redraw()


func move_to(canvas_pos: Vector2) -> void:
	position = canvas_pos - size * 0.5


func _draw() -> void:
	var tex := Icons.texture(icon_name, Tokens.ICON)
	if tex != null:
		draw_texture(tex, Vector2.ZERO, Color(1, 1, 1, 0.8))
