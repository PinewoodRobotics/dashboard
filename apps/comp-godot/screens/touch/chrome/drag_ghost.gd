class_name DragGhost
extends Control

## The dragged tab: its bare white outline symbol, 48 px, at 80% opacity on
## the pointer (TouchscreenDragGhost.tsx).

var symbol := 0


func _init() -> void:
	name = "DragGhost"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size = Vector2(Tokens.ICON, Tokens.ICON)
	visible = false


func show_at(sym: int, canvas_pos: Vector2) -> void:
	symbol = sym
	visible = true
	move_to(canvas_pos)
	queue_redraw()


func move_to(canvas_pos: Vector2) -> void:
	position = canvas_pos - size * 0.5


func _draw() -> void:
	UiDraw.begin(self)
	Sf.draw(self, symbol, size * 0.5, Tokens.ICON, Color(1, 1, 1, 0.8))
