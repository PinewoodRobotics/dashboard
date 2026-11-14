class_name PwBox
extends StyleBox

## StyleBoxFlat's look (fill, inside border, corner radius, shadow) drawn with
## UiDraw so it batches with the other shapes and icons. Same property names as
## StyleBoxFlat for the subset the UI uses.

@export var bg_color := Color(0.6, 0.6, 0.6):
	set(v):
		bg_color = v
		emit_changed()
@export var border_color := Color(0.8, 0.8, 0.8):
	set(v):
		border_color = v
		emit_changed()
@export var border_width_left := 0:
	set(v):
		border_width_left = v
		emit_changed()
@export var border_width_top := 0:
	set(v):
		border_width_top = v
		emit_changed()
@export var border_width_right := 0:
	set(v):
		border_width_right = v
		emit_changed()
@export var border_width_bottom := 0:
	set(v):
		border_width_bottom = v
		emit_changed()
@export var corner_radius := 0:
	set(v):
		corner_radius = v
		emit_changed()
@export var shadow_color := Color(0, 0, 0, 0.6):
	set(v):
		shadow_color = v
		emit_changed()
@export var shadow_size := 0:
	set(v):
		shadow_size = v
		emit_changed()


func set_border_width_all(w: int) -> void:
	border_width_left = w
	border_width_top = w
	border_width_right = w
	border_width_bottom = w


func set_corner_radius_all(r: int) -> void:
	corner_radius = r


func _uniform_border() -> int:
	if border_width_left == border_width_top and border_width_top == border_width_right and border_width_right == border_width_bottom:
		return border_width_left
	return -1


func _draw(ci: RID, rect: Rect2) -> void:
	UiDraw.shadow(ci, rect, corner_radius, shadow_size, shadow_color)
	var w := _uniform_border()
	if w >= 0:
		UiDraw.box(ci, rect, bg_color, corner_radius, w, border_color)
		return
	var inner := Rect2(rect.position + Vector2(border_width_left, border_width_top),
		rect.size - Vector2(border_width_left + border_width_right, border_width_top + border_width_bottom))
	UiDraw.rect(ci, inner, bg_color)
	if border_color.a <= 0.0:
		return
	UiDraw.rect(ci, Rect2(rect.position, Vector2(rect.size.x, border_width_top)), border_color)
	UiDraw.rect(ci, Rect2(rect.position.x, rect.end.y - border_width_bottom, rect.size.x, border_width_bottom), border_color)
	UiDraw.rect(ci, Rect2(rect.position.x, inner.position.y, border_width_left, inner.size.y), border_color)
	UiDraw.rect(ci, Rect2(inner.end.x, inner.position.y, border_width_right, inner.size.y), border_color)
