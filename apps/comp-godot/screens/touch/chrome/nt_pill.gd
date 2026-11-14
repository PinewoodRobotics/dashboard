class_name NtPill
extends PanelContainer

## "NT Disconnected" pill (ConnectionLost.tsx), shown whenever NetworkTables
## is not connected; last values stay on screen. The web put it bottom center,
## where it would cover the driver view's camera presets and the auto tab's
## Select button, so it sits in the bottom-right corner of the overlay area.

const MARGIN := 16.0

var nt: NtService
var right_edge := Tokens.TOUCH_DESIGN.x - Tokens.RAIL_W


func _ready() -> void:
	if nt == null:
		nt = get_node_or_null("/root/NT") as NtService
	name = "NtPill"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := PwBox.new()
	sb.bg_color = Color(0, 0, 0, 0.85)
	sb.border_color = Color(Tokens.ERROR, 0.4)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	add_theme_stylebox_override("panel", sb)
	var row := UiKit.hbox(8)
	var dot := Control.new()
	dot.custom_minimum_size = Vector2(12, 12)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dot.draw.connect(func() -> void: UiDraw.circle(dot.get_canvas_item(), Vector2(6, 6), 6, Tokens.ERROR))
	row.add_child(dot)
	row.add_child(UiKit.label("NT Disconnected", 14, 500, Tokens.ERROR_TEXT))
	add_child(row)
	_update()


func _process(_delta: float) -> void:
	_update()


func _update() -> void:
	var show := nt != null and not nt.is_ready()
	if show != visible:
		visible = show
	if visible:
		var s := get_combined_minimum_size()
		size = s
		position = Vector2(right_edge - MARGIN - s.x, Tokens.TOUCH_DESIGN.y - MARGIN - s.y)
