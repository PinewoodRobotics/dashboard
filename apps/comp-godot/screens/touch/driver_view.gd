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
	## The four 40 px round buttons, drawn in one pass (circles, then labels)
	## so they cost two canvas draw calls instead of eight.

	var selected := 0
	var view: DriverView

	func _init() -> void:
		name = "PresetBar"
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		size = Vector2(4 * BTN + 3 * GAP, BTN)
		for i in 4:
			var hit := Control.new()
			hit.name = "Preset%d" % (i + 1)
			hit.position = Vector2(i * (BTN + GAP), 0)
			hit.size = Vector2(BTN, BTN)
			hit.mouse_filter = Control.MOUSE_FILTER_STOP
			hit.gui_input.connect(_on_hit_input.bind(hit, i))
			add_child(hit)

	func _on_hit_input(event: InputEvent, hit: Control, i: int) -> void:
		var p := PointerInput.from_event(event)
		if p.kind == PointerInput.Kind.DOWN:
			hit.set_meta("down", p.pos)
		elif p.kind == PointerInput.Kind.UP and hit.has_meta("down"):
			var start: Vector2 = hit.get_meta("down")
			hit.remove_meta("down")
			if p.pos.distance_to(start) <= PwButton.TAP_SLOP_PX and Rect2(Vector2.ZERO, hit.size).has_point(p.pos):
				view.select_preset(i)
		if p.kind != PointerInput.Kind.NONE:
			hit.accept_event()

	func _draw() -> void:
		for i in 4:
			var c := Vector2(i * (BTN + GAP) + BTN * 0.5, BTN * 0.5)
			draw_circle(c, BTN * 0.5, Color.WHITE if i == selected else Color(1, 1, 1, 0.1))
		var f := Tokens.inter(500)
		for i in 4:
			var t := str(i + 1)
			var w := f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
			var pos := Vector2(i * (BTN + GAP) + (BTN - w) * 0.5, (BTN + f.get_ascent(14) - f.get_descent(14)) * 0.5)
			draw_string(f, pos.round(), t, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color.BLACK if i == selected else Color(1, 1, 1, 0.6))


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
		bar.queue_redraw()


func select_preset(i: int) -> void:
	orbit.select_preset(i)


func set_rendering(on: bool) -> void:
	orbit.set_rendering(on)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color.BLACK)
