class_name PwCornerMask
extends Control

## Rounds the corners of whatever its parent box holds by painting the
## background color outside the rounding, drawn above the content.

var radius := 6.0
var color := Tokens.PANEL


func _init(r: float = 6.0, bg: Color = Tokens.PANEL) -> void:
	radius = r
	color = bg
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 1
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _draw() -> void:
	UiDraw.corner_mask(get_canvas_item(), Rect2(Vector2.ZERO, size), radius, color)
