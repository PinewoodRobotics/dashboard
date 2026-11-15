class_name AutoCard
extends PanelContainer

## One row of the auto list (PathCard.tsx): 192 px on #3c3c3c, 10 px padding,
## a 4 px border that is green for the selected auto and white for the one
## being viewed; the 28 px title with the file name below, the description,
## and "Currently Selected" (kept in place, transparent unless selected), 8 px
## apart and clipped to the card.

const HEIGHT := 192.0

var auto_name := ""
var title: PwText
var file: PwText
var desc: PwText
var current: PwText
var _style := PwBox.new()
var _state := ""


func _init(p_name: String, display: String, file_name: String, description: String) -> void:
	auto_name = p_name
	name = "Card_" + p_name.validate_node_name().replace(" ", "_")
	custom_minimum_size = Vector2(0, HEIGHT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true
	_style.bg_color = Tokens.CARD
	_style.set_border_width_all(Tokens.BORDER)
	_style.border_color = Color(0, 0, 0, 0)
	_style.set_content_margin_all(Tokens.BORDER + 10)
	add_theme_stylebox_override("panel", _style)
	var box := UiKit.vbox(8)
	box.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	var head := UiKit.vbox(0)
	title = PwText.new(display, 28, 600, Tokens.TEXT, 28.0)
	title.name = "Title"
	head.add_child(title)
	file = PwText.new(file_name, 14, 400, Tokens.ZINC_500, 20.0)
	file.name = "File"
	var file_box := UiKit.margin(file, 0, 4, 0, 0)
	file_box.visible = file_name != ""
	head.add_child(file_box)
	box.add_child(head)
	desc = PwText.new(description, 18, 400, Tokens.TEXT, 27.0)
	desc.name = "Description"
	box.add_child(desc)
	current = PwText.new("Currently Selected", 18, 700, Color(Tokens.ACCENT, 0.0), 18.0)
	current.name = "Current"
	box.add_child(current)
	add_child(box)


func set_state(active: bool, viewing: bool) -> void:
	var key := "%s|%s" % [active, viewing]
	if key == _state:
		return
	_state = key
	_style.border_color = Tokens.ACCENT if active else (Tokens.TEXT if viewing else Color(0, 0, 0, 0))
	current.color = Color(Tokens.ACCENT, 1.0 if active else 0.0)
	queue_redraw()


func report() -> Dictionary:
	return {"active": current.color.a > 0.5, "border": _style.border_color.to_html(true)}
