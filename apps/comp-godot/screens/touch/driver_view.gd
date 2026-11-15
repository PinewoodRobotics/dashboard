class_name DriverView
extends Control

## Driver base behind every overlay (DriverTab.tsx): the robot orbit view with
## live joints and alliance bumpers, and the four camera preset buttons.

const BTN := 40.0
const GAP := 8.0

var orbit: RobotOrbitView
var bar: PresetBar


class PresetBar:
	extends Control

	var selected := 0:
		set(v):
			selected = v
			for i in buttons.size():
				buttons[i].selected = i == v
	var view: DriverView
	var buttons: Array[PwButton] = []

	func _init() -> void:
		name = "PresetBar"
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		size = Vector2(4 * BTN + 3 * GAP, BTN)
		for i in 4:
			var b := PwButton.new(str(i + 1), PwButton.Style.PILL)
			b.name = "Preset%d" % (i + 1)
			b.position = Vector2(i * (BTN + GAP), 0)
			b.size = Vector2(BTN, BTN)
			b.selected = i == 0
			b.pressed.connect(func() -> void: view.select_preset(i))
			add_child(b)
			buttons.append(b)


func _ready() -> void:
	name = "DriverView"
	mouse_filter = Control.MOUSE_FILTER_PASS
	orbit = RobotOrbitView.new()
	orbit.name = "Orbit"
	orbit.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(orbit)
	bar = PresetBar.new()
	bar.view = self
	add_child(bar)
	resized.connect(_layout)
	_layout()


func _layout() -> void:
	bar.position = Vector2((size.x - bar.size.x) * 0.5, size.y - 24.0 - BTN)


func _process(_delta: float) -> void:
	if bar.selected != orbit.cam.preset:
		bar.selected = orbit.cam.preset


func select_preset(i: int) -> void:
	orbit.select_preset(i)


func set_rendering(on: bool) -> void:
	orbit.set_rendering(on)


func _draw() -> void:
	UiDraw.rect(get_canvas_item(), Rect2(Vector2.ZERO, size), Color.BLACK)
