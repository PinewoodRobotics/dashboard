extends TestCase

## PwScroll and PwTapList: OS scrolling (wheel, pan gestures) at Chromium's
## rates, no mouse drag scrolling, the reserved 5 px bar, touch drag with
## Chromium's fling where the OS sends only touches.

var nodes: Array[Node] = []


func after_each() -> void:
	for n in nodes:
		if is_instance_valid(n):
			n.queue_free()
	nodes.clear()
	await tree.process_frame


func _scroller(vertical: bool = true, length: float = 2000.0) -> PwScroll:
	var sc := PwScroll.new(vertical)
	var tall := Control.new()
	tall.custom_minimum_size = Vector2(100, length) if vertical else Vector2(length, 100)
	sc.add_child(tall)
	tree.root.add_child(sc)
	sc.position = Vector2.ZERO
	sc.size = Vector2(420, 400)
	nodes.append(sc)
	return sc


static func _btn(pos: Vector2, pressed: bool, touch: bool = false, button := MOUSE_BUTTON_LEFT) -> InputEventMouseButton:
	var e := InputEventMouseButton.new()
	e.button_index = button
	e.pressed = pressed
	e.position = pos
	e.global_position = pos
	e.device = InputEvent.DEVICE_ID_EMULATION if touch else 0
	return e


static func _mv(pos: Vector2, touch: bool = false) -> InputEventMouseMotion:
	var e := InputEventMouseMotion.new()
	e.position = pos
	e.global_position = pos
	e.device = InputEvent.DEVICE_ID_EMULATION if touch else 0
	return e


static func _pan(delta_px: Vector2) -> InputEventPanGesture:
	var e := InputEventPanGesture.new()
	e.delta = delta_px * NativeScroll.MAC_PAN_SCALE
	return e


func test_native_units_match_chromium() -> void:
	var wheel := _btn(Vector2.ZERO, true, false, MOUSE_BUTTON_WHEEL_DOWN)
	wheel.factor = NativeScroll.MAC_LINE_FACTOR if OS.get_name() == "macOS" else 1.0
	var expect := NativeScroll.MAC_LINE_PX if OS.get_name() == "macOS" else NativeScroll.NOTCH_PX
	check_eq(NativeScroll.wheel_delta(wheel, null), Vector2(0, expect), "one line or notch")
	wheel.shift_pressed = true
	check_eq(NativeScroll.wheel_delta(wheel, null), Vector2(expect, 0), "shift turns the wheel sideways")
	check_eq(NativeScroll.pan_delta(_pan(Vector2(0, 37)), null), Vector2(0, 37), "pan gestures are OS pixels")


func test_wheel_and_pan_scroll_and_hand_on_at_the_end() -> void:
	var sc := _scroller()
	await tree.process_frame
	var k := NativeScroll.dip_to_design(sc)
	check(sc._scroll_input(_pan(Vector2(0, 120) / k)), "pan gesture scrolls")
	check_near(sc.scroll_offset, 120.0, 1e-3, "1:1 with the OS delta, no easing")
	check(not sc._scroll_input(_pan(Vector2(80, 10) / k)), "a sideways gesture is the parent's")
	check(sc._scroll_input(_pan(Vector2(0, -500) / k)))
	check_eq(sc.scroll_offset, 0.0)
	check(not sc._scroll_input(_pan(Vector2(0, -10) / k)), "at the top the gesture goes on to the parent")
	var wheel := _btn(Vector2(10, 10), true, false, MOUSE_BUTTON_WHEEL_DOWN)
	wheel.factor = 1.0
	check(sc._scroll_input(wheel))
	check_near(sc.scroll_offset, minf(NativeScroll.wheel_delta(wheel, sc).y, sc.max_scroll()), 1e-3)
	var h := _scroller(false)
	await tree.process_frame
	check(not h._scroll_input(_pan(Vector2(0, 50))), "a vertical gesture passes a horizontal strip")
	check(h._scroll_input(_pan(Vector2(50, 0))))


func test_mouse_drag_never_scrolls() -> void:
	var sc := _scroller()
	await tree.process_frame
	sc._input(_btn(Vector2(100, 300), true))
	for y in [280, 200, 100]:
		sc._input(_mv(Vector2(100, y)))
	sc._input(_btn(Vector2(100, 100), false))
	check_eq(sc.scroll_offset, 0.0)


func test_bar_is_reserved_and_the_thumb_drags() -> void:
	var sc := _scroller()
	await tree.process_frame
	check_eq(sc.content().size.x, 415.0, "the 5 px bar sits beside the content")
	check_near(sc.bar_length(), 400.0 * 400.0 / 2000.0, 1e-6, "proportional thumb")
	sc._gui_input(_btn(Vector2(418, 10), true))
	check(sc.dragging)
	sc._gui_input(_mv(Vector2(418, 10 + 160)))
	check_near(sc.scroll_offset, 160.0 * 1600.0 / 320.0, 1e-3, "the thumb follows the pointer")
	sc._gui_input(_btn(Vector2(418, 170), false))
	check(not sc.dragging)
	sc._gui_input(_btn(Vector2(418, 390), true))
	check_near(sc.scroll_offset, 800.0 + 400.0 * PwScroll.PAGE_FRACTION, 1e-3, "a press on the track pages")
	sc._gui_input(_btn(Vector2(418, 390), false))
	var auto := PwScroll.new(false, false)
	var short := Control.new()
	short.custom_minimum_size = Vector2(100, 50)
	auto.add_child(short)
	tree.root.add_child(auto)
	nodes.append(auto)
	auto.size = Vector2(420, 300)
	await tree.process_frame
	check(not auto.bar_visible(), "overflow auto: no bar until the content overflows")
	check_eq(short.size.y, 300.0)


func test_touch_drags_and_flings() -> void:
	var sc := _scroller()
	await tree.process_frame
	sc._input(_btn(Vector2(100, 300), true, true))
	sc._input(_mv(Vector2(100, 290), true))
	check(not sc.dragging, "inside the tap slop")
	for y in [280, 260, 240, 220, 200]:
		sc._input(_mv(Vector2(100, y), true))
	check(sc.dragging)
	check_near(sc.scroll_offset, 80.0, 1e-6, "follows the finger once past the slop")
	sc._input(_btn(Vector2(100, 200), false, true))
	check(not sc.dragging)
	sc._input(_btn(Vector2(100, 300), true))
	sc._input(_mv(Vector2(100, 100)))
	check_near(sc.scroll_offset, 80.0, 1e-6, "the mouse never drags")
	sc._input(_btn(Vector2(100, 100), false))


func test_fling_curve_is_chromium_s() -> void:
	var f := TouchFling.new()
	check(not f.start(20.0, 515.0), "below 30 px/s")
	check(f.start(2000.0, 515.0))
	check_near(f.distance, 2000.0 * 2000.0 / (2.0 * TouchFling.DECEL_PX_PER_S2), 1e-3, "v^2 / 2a")
	check_near(f.duration_s, 2000.0 / 2300.0, 1e-6)
	var total := 0.0
	for i in 120:
		total += f.step(1.0 / 60.0)
	check_near(total, f.distance, 1e-3)
	check(not f.active)
	f.start(9000.0, 515.0)
	check_eq(f.distance, floorf(515.0 * 3.0), "capped at three window lengths")
	var v := TouchFling.new()
	for i in 6:
		v.add_sample(100.0 - 10.0 * i, 1000.0 + 16.0 * i)
	check_near(v.release_velocity(1080.0), -625.0, 1e-3, "least squares over the last 100 ms")
	check_eq(v.release_velocity(1200.0), 0.0, "stopped for 80 ms: no fling")


func test_tap_list_taps_rows_but_not_after_a_drag() -> void:
	var list := PwTapList.new(10, 10)
	tree.root.add_child(list)
	nodes.append(list)
	list.size = Vector2(300, 200)
	for i in 6:
		var row := Control.new()
		row.custom_minimum_size = Vector2(0, 80)
		list.add_item(row)
	var taps: Array = []
	list.item_tapped.connect(func(i: int) -> void: taps.append(i))
	await tree.process_frame
	check_eq((list.items.get_child(0) as Control).get_global_rect().position, Vector2(10, 10), "padding inside the scroller")
	check_eq((list.items.get_child(0) as Control).size.x, 300.0 - 20.0 - 5.0, "minus the padding and the bar")
	list._gui_input(_btn(Vector2(50, 150), true))
	list._gui_input(_btn(Vector2(52, 152), false))
	check_eq(taps, [1])
	list._gui_input(_btn(Vector2(50, 150), true))
	list._gui_input(_mv(Vector2(50, 100)))
	list._gui_input(_btn(Vector2(50, 100), false))
	check_eq(taps, [1], "a mouse drag neither taps nor scrolls")
	check_eq(list.scroll_offset, 0.0)
	list.reveal_index(5)
	check_eq(list.scroll_offset, 10.0 + 5.0 * 90.0 + 80.0 - 200.0, "reveal brings the last row into view")
