class_name SettingsHeader
extends PanelContainer

## The header bar of the Settings and Visual tabs (SettingsHeader.tsx,
## VisualTab.tsx): 32 px sides, 20 px top and bottom, a 2 px white/10 rule
## below; the 28 px semibold title, an optional status dot and text, and the
## buttons on the right 12 px apart, all centered on the 48 px button row.

var title: PwText
var status_row: HBoxContainer
var status_dot: StatusDot
var status_label: PwText
var buttons: HBoxContainer


class StatusDot:
	extends Control
	var color := Tokens.ERROR:
		set(v):
			color = v
			queue_redraw()

	func _init() -> void:
		custom_minimum_size = Vector2(10, 10)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		size_flags_vertical = Control.SIZE_SHRINK_CENTER

	func _draw() -> void:
		UiDraw.circle(get_canvas_item(), size * 0.5, 5.0, color)


func _init(title_text: String, with_status: bool = false) -> void:
	name = "Header"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := PwBox.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.border_color = Tokens.HAIRLINE
	sb.border_width_bottom = 2
	sb.content_margin_left = 32
	sb.content_margin_right = 32
	sb.content_margin_top = 20
	sb.content_margin_bottom = 20 + 2
	add_theme_stylebox_override("panel", sb)
	var row := UiKit.hbox(24)
	var left := UiKit.hbox(16)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title = PwText.new(title_text, 28, 600, Tokens.TEXT, 28.0)
	title.wrap = PwText.Wrap.NONE
	title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	left.add_child(title)
	if with_status:
		status_row = UiKit.hbox(8)
		status_row.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		status_dot = StatusDot.new()
		status_row.add_child(status_dot)
		status_label = PwText.new("", 14, 600, Tokens.ERROR, 20.0)
		status_label.wrap = PwText.Wrap.NONE
		status_label.name = "Status"
		status_row.add_child(status_label)
		left.add_child(status_row)
	row.add_child(left)
	buttons = UiKit.hbox(12)
	buttons.custom_minimum_size.y = 48
	row.add_child(buttons)
	add_child(row)


func set_status(text: String, ok: bool) -> void:
	var col := Tokens.ACCENT if ok else Tokens.ERROR
	status_dot.color = col
	status_label.color = col
	status_label.text = text


func add_button(b: PwButton) -> PwButton:
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	buttons.add_child(b)
	return b
