class_name AutoCard
extends PanelContainer

## One row of the auto list (PathCard.tsx): 192 px, 4 px border that is green
## for the selected auto, white for the one being viewed. Adds the robot's
## validity warning, which the web card did not have.

const HEIGHT := 192.0
const AMBER := Color("#fbbf24")

var auto_name := ""
var title: Label
var file: Label
var desc: Label
var warning_row: HBoxContainer
var warning: Label
var current: Label
var _style := StyleBoxFlat.new()
var _state := ""


func _init(p_name: String, display: String, file_name: String, description: String) -> void:
	auto_name = p_name
	name = "Card_" + p_name.validate_node_name().replace(" ", "_")
	custom_minimum_size = Vector2(0, HEIGHT)
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_style.bg_color = Tokens.CARD
	_style.set_border_width_all(Tokens.BORDER)
	_style.border_color = Color(0, 0, 0, 0)
	_style.set_content_margin_all(14)
	add_theme_stylebox_override("panel", _style)
	var box := UiKit.vbox(2)
	title = UiKit.label(display, 28, 600)
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	box.add_child(title)
	file = UiKit.label(file_name, 14, 400, Tokens.ZINC_500)
	file.visible = file_name != ""
	box.add_child(file)
	desc = UiKit.wrapped(description, 18, Tokens.ZINC_300)
	desc.max_lines_visible = 2
	desc.visible = description != ""
	box.add_child(desc)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(spacer)
	warning_row = UiKit.hbox(6)
	warning_row.add_child(PwIcon.new("triangle-alert", 18, AMBER))
	warning = UiKit.label("", 16, 500, AMBER)
	warning.name = "Warning"
	warning_row.add_child(warning)
	warning_row.visible = false
	box.add_child(warning_row)
	current = UiKit.label("Currently Selected", 18, 700, Color(Tokens.ACCENT, 0.0))
	current.name = "Current"
	box.add_child(current)
	add_child(box)


func set_state(active: bool, viewing: bool, warning_text: String) -> void:
	var key := "%s|%s|%s" % [active, viewing, warning_text]
	if key == _state:
		return
	_state = key
	_style.border_color = Tokens.ACCENT if active else (Tokens.TEXT if viewing else Color(0, 0, 0, 0))
	current.add_theme_color_override("font_color", Color(Tokens.ACCENT, 1.0 if active else 0.0))
	warning.text = warning_text
	warning_row.visible = warning_text != ""
	queue_redraw()


func report() -> Dictionary:
	return {"active": current.get_theme_color("font_color").a > 0.5, "border": _style.border_color.to_html(true), "warning": warning.text}
