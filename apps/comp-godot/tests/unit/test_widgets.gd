extends TestCase

## Slider and selector math, and pointer handling through _gui_input with
## mouse events and emulated-touch events.

var nodes: Array[Node] = []


func after_each() -> void:
	for n in nodes:
		if is_instance_valid(n):
			n.queue_free()
	nodes.clear()
	await tree.process_frame


func _add(c: Control, w: float = 408.0) -> Control:
	tree.root.add_child(c)
	c.size = Vector2(w, c.custom_minimum_size.y)
	nodes.append(c)
	return c


static func _btn(pos: Vector2, pressed: bool, touch: bool = false) -> InputEventMouseButton:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = pressed
	e.position = pos
	e.device = InputEvent.DEVICE_ID_EMULATION if touch else 0
	return e


static func _mv(pos: Vector2, touch: bool = false) -> InputEventMouseMotion:
	var e := InputEventMouseMotion.new()
	e.position = pos
	e.device = InputEvent.DEVICE_ID_EMULATION if touch else 0
	return e


func _drag(c: Control, a: Vector2, b: Vector2, touch: bool = false, steps: int = 6) -> void:
	c._gui_input(_btn(a, true, touch))
	for i in range(1, steps + 1):
		c._gui_input(_mv(a.lerp(b, float(i) / steps), touch))
	c._gui_input(_btn(b, false, touch))


func test_pointer_input_flags_touch() -> void:
	check(PointerInput.from_event(_btn(Vector2.ZERO, true, true)).is_touch)
	check(not PointerInput.from_event(_btn(Vector2.ZERO, true, false)).is_touch)
	check_eq(PointerInput.from_event(InputEventScreenTouch.new()).kind, PointerInput.Kind.NONE, "raw touches are left to emulation")


func test_slider_math() -> void:
	check_near(PwSlider.drag_value(0.5, 100, 400, 0, 1, 0.01, [], false), 0.75, 1e-9, "relative drag")
	check_near(PwSlider.drag_value(0.5, 100, 400, 0, 1, 0.01, [], true), 0.25, 1e-9, "reversed inverts the drag")
	check_near(PwSlider.drag_value(0.5, 1000, 400, 0, 1, 0.01, [], false), 1.0, 1e-9, "clamped")
	check_near(PwSlider.quantize(0.333, 0, 1, 0.25, []), 0.25, 1e-9, "step from min")
	check_near(PwSlider.quantize(-3.1, -10, 10, 0.25, []), -3.0, 1e-9)
	check_near(PwSlider.quantize(0.1, 0, 1, 0, [0.25, 0.5, 0.75, 1.0]), 0.25, 1e-9, "snap: lowest reachable is 0.25")
	check_near(PwSlider.quantize(0.6, 0, 1, 0, [0.25, 0.5, 0.75, 1.0]), 0.5, 1e-9)
	check_eq(PwSlider.hint_for(0.45, VisualTab.SCALE_HINTS), "0.5x: moderate quality loss")
	check_eq(PwSlider.hint_for(0.9, MapSettingsPanel.ANGLE_HINTS), "Top down camera view")


func test_slider_tap_changes_nothing_and_drag_is_relative() -> void:
	var s := _add(PwSlider.new().configure({"min_value": 0.0, "max_value": 1.0, "step": 0.01, "value": 0.5})) as PwSlider
	var changes: Array = []
	s.value_changed.connect(func(v: float) -> void: changes.append(v))
	s._gui_input(_btn(Vector2(380, 24), true))
	s._gui_input(_btn(Vector2(380, 24), false))
	check_eq(s.value, 0.5, "a tap near the right end changes nothing")
	check(changes.is_empty())
	_drag(s, Vector2(50, 24), Vector2(150, 24))
	check_near(s.value, 0.75, 1e-9, "100 px of a 400 px track")
	check(not s.dragging)
	_drag(s, Vector2(200, 24), Vector2(200, 80), true)
	check_near(s.value, 0.75, 1e-9, "a vertical drag is left to the swipe")


func test_slider_reversed_and_snap_by_touch() -> void:
	var trim := _add(PwSlider.new().configure({"min_value": -10.0, "max_value": 10.0, "step": 0.25, "reversed": true, "value": 0.0})) as PwSlider
	_drag(trim, Vector2(200, 24), Vector2(140, 24), true)
	check_near(trim.value, 3.0, 1e-9, "dragging left increases a reversed slider")
	var snap := _add(PwSlider.new().configure({"min_value": 0.0, "max_value": 1.0, "snap_points": [0.25, 0.5, 0.75, 1.0], "value": 1.0})) as PwSlider
	_drag(snap, Vector2(300, 24), Vector2(140, 24), true)
	check_near(snap.value, 0.5, 1e-9, "1.0 - 0.4 snaps to 0.5")
	snap.disabled = true
	_drag(snap, Vector2(100, 24), Vector2(400, 24))
	check_near(snap.value, 0.5, 1e-9, "disabled ignores input")


func test_selector_math_and_input() -> void:
	check_eq(PwSelector.cell_at(10, 2), 0)
	check_eq(PwSelector.cell_at(77, 2), 1)
	check_eq(PwSelector.cell_at(500, 2), 1)
	check_eq(PwSelector.nearest_cell(37, 2), 0)
	check_eq(PwSelector.nearest_cell(39, 2), 1)
	check_eq(PwSelector.cells_width(3), 232.0)
	var sel := _add(PwSelector.new().configure("Mode", MapSettingsPanel.MODE_OPTIONS, "follow")) as PwSelector
	var got: Array = []
	sel.selected.connect(func(v: Variant) -> void: got.append(v))
	check_eq(sel.current_value(), "follow")
	sel._gui_input(_btn(Vector2(30, 70), true, true))
	sel._gui_input(_btn(Vector2(30, 70), false, true))
	check_eq(sel.current_value(), "driver", "tap selects the cell under the finger")
	_drag(sel, Vector2(30, 70), Vector2(80, 72))
	check_eq(sel.current_value(), "follow", "drag slides and snaps to the nearest cell")
	check_eq(got, ["driver", "follow"])
	_drag(sel, Vector2(100, 70), Vector2(102, 140), true)
	check_eq(sel.current_value(), "follow", "a vertical drag selects nothing")


func test_text_input_with_keyboard_and_keypad() -> void:
	var host := Control.new()
	tree.root.add_child(host)
	nodes.append(host)
	host.size = Vector2(1920, 515)
	var kb := PwKeyboard.new()
	host.add_child(kb)
	var t := PwTextInput.new("Host", "10.47.65.2")
	host.add_child(t)
	t.size = Vector2(400, 98)
	t._gui_input(_btn(Vector2(50, 60), true, true))
	t._gui_input(_btn(Vector2(50, 60), false, true))
	check(kb.is_open() and kb.target == t and t.editing, "a tap opens this window's keyboard")
	check(not kb.numeric)
	for k in ["1", "0", ".", "4"]:
		kb.press_key(k)
	kb.press_key("SHIFT")
	kb.press_key("a")
	kb.press_key("b")
	check_eq(t.text, "10.4Ab", "shift applies to one key")
	kb.press_key("BKSP")
	check_eq(t.text, "10.4A")
	var submitted: Array = []
	t.submitted.connect(func(s: String) -> void: submitted.append(s))
	kb.press_key("DONE")
	check(not kb.is_open() and not t.editing)
	check_eq(submitted, ["10.4A"])

	var port := PwTextInput.new("Port", "5810", true)
	host.add_child(port)
	port.size = Vector2(400, 98)
	port.open_keyboard()
	check(kb.numeric, "numeric fields get the keypad")
	check(kb.key_button("q") == null and kb.key_button("5") != null)
	kb.press_key("5")
	kb.press_key("8")
	port.insert("1a.0")
	check_eq(port.text, "5810", "numeric filter strips non-digits")
	kb.press_key("CLEAR")
	check_eq(port.text, "")
	kb._gui_input(_btn(Vector2(10, 10), false, true))
	check(not kb.is_open(), "tapping outside the sheet closes it")
	check_eq(PwTextInput.filter("a1-2 3", true), "123")


func test_button_taps_but_not_after_a_drag() -> void:
	var b := _add(PwButton.new("Go"), 120) as PwButton
	b.size = Vector2(120, 48)
	var n := [0]
	b.pressed.connect(func() -> void: n[0] += 1)
	b._gui_input(_btn(Vector2(60, 24), true, true))
	b._gui_input(_btn(Vector2(60, 24), false, true))
	check_eq(n[0], 1)
	_drag(b, Vector2(60, 10), Vector2(60, 40))
	check_eq(n[0], 1, "a 30 px drag inside the button is not a tap")
	b.disabled = true
	b._gui_input(_btn(Vector2(60, 24), true))
	b._gui_input(_btn(Vector2(60, 24), false))
	check_eq(n[0], 1)
