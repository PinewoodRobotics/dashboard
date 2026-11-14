class_name DriverView
extends Control

## Driver base behind every overlay (DriverTab.tsx): the robot orbit view with
## live joints and alliance bumpers, and the four camera preset buttons.

var orbit: RobotOrbitView
var buttons: Array[PwButton] = []


func _ready() -> void:
	name = "DriverView"
	mouse_filter = Control.MOUSE_FILTER_PASS
	orbit = RobotOrbitView.new()
	orbit.name = "Orbit"
	orbit.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(orbit)
	for i in 4:
		var b := PwButton.new(str(i + 1), PwButton.Style.DARK, Vector2(40, 40))
		b.name = "Preset%d" % (i + 1)
		b.radius = 20.0
		b.font_size = 18
		b.size = Vector2(40, 40)
		b.pressed.connect(select_preset.bind(i))
		add_child(b)
		buttons.append(b)
	resized.connect(_layout)
	_layout()
	_refresh_buttons()


func _layout() -> void:
	var total := 4 * 40.0 + 3 * 8.0
	for i in buttons.size():
		buttons[i].position = Vector2((size.x - total) * 0.5 + i * 48.0, size.y - 24.0 - 40.0)


func select_preset(i: int) -> void:
	orbit.select_preset(i)
	_refresh_buttons()


func _refresh_buttons() -> void:
	for i in buttons.size():
		var on := i == orbit.cam.preset
		buttons[i].variant = PwButton.Style.LIGHT if on else PwButton.Style.DARK
		buttons[i].queue_redraw()


func set_rendering(on: bool) -> void:
	orbit.set_rendering(on)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color.BLACK)
