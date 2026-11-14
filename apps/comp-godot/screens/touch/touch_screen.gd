class_name TouchScreen
extends Control

## Touchscreen window content at the 1920x515 design size. M2: the robot orbit
## view as the base layer; the dock, rail and tabs arrive in M4.

var orbit: RobotOrbitView
var _status: Label


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color.BLACK
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	orbit = RobotOrbitView.new()
	orbit.name = "Orbit"
	orbit.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(orbit)
	_status = Label.new()
	_status.position = Vector2(24, 16)
	_status.add_theme_font_size_override("font_size", 22)
	_status.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_status)


func _process(_delta: float) -> void:
	var nt := get_node_or_null("/root/NT") as NtService
	if nt != null:
		_status.text = "Touchscreen  NT %s" % ("fixture" if nt.fixture_mode else nt.client.state_name())
