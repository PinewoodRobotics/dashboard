class_name TouchTest
extends CanvasLayer

## Driver-station touch check (Visual > Diagnostics > Touch Test, or
## --touch-test at launch). One layer per window. On the touchscreen it takes
## every touch: a ring sits where Godot thinks each finger is, with its index
## and position, and drags leave a trail, so a finger that is not under its
## ring shows an offset or scaling problem at a glance. On the HUD it only
## counts: any touch that reaches the HUD window means touch input is routed
## to the wrong window, and the two-process launcher is the fix. Every press
## goes to the log. Close (bottom right) or Escape ends the test.

const GROUP := "touch_test"
const RING_R := 46.0
const TRAIL_MAX := 400
const CLOSE := Rect2(-220, -86, 196, 62)
const GREEN := Color("#70cd35")
const ROSE := Color("#f43f5e")

var window_key := "touch"
var touches := {}
var trail: PackedVector2Array = []
var presses := 0
var drags := 0
var canvas: Canvas


class Canvas:
	extends Control
	var test: TouchTest

	func _draw() -> void:
		UiDraw.begin(self)
		var ci := get_canvas_item()
		var font := Tokens.inter(600)
		var hud := test.window_key == "hud"
		if hud:
			if test.presses + test.drags == 0:
				return
			UiDraw.box(ci, Rect2(40, 40, size.x - 80, 120), Color(0.3, 0.02, 0.06), 16.0, 3, TouchTest.ROSE)
			UiDraw.text(self, font, Vector2(72, 112), "Touch reached the HUD window: %d presses, %d drags. Use the two-process launcher." % [test.presses, test.drags], 34, Color.WHITE)
			return
		UiDraw.rect(ci, Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.82))
		for i in range(1, test.trail.size()):
			UiDraw.circle(ci, test.trail[i], 3.0, Color(TouchTest.GREEN, 0.5))
		for idx: int in test.touches:
			var p: Vector2 = test.touches[idx]
			UiDraw.circle(ci, p, TouchTest.RING_R, Color(TouchTest.GREEN, 0.35))
			UiDraw.circle(ci, p, 6.0, Color.WHITE)
			UiDraw.text(self, font, p + Vector2(TouchTest.RING_R + 8, -8), "#%d  %d, %d" % [idx, roundi(p.x), roundi(p.y)], 24, Color.WHITE)
		var lines := [
			"Touch test: rings must sit under your fingertips, also in the corners and while dragging.",
			"Window %d x %d px.  Presses %d, drag events %d, fingers down %d." % [roundi(size.x), roundi(size.y), test.presses, test.drags, test.touches.size()],
		]
		for i in lines.size():
			UiDraw.text(self, font, Vector2(32, 52 + i * 40), lines[i], 28 if i == 0 else 24, Color.WHITE if i == 0 else Tokens.ZINC_300)
		var close := test.close_rect(size)
		UiDraw.box(ci, close, Color(0.1, 0.1, 0.1), 10.0, 2, Color(1, 1, 1, 0.4))
		UiDraw.text(self, font, close.position + Vector2(0, 42), "Close", 28, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER, close.size.x)


static func open_all(tree: SceneTree, windows: Dictionary) -> void:
	for key: String in windows:
		var w: Window = windows[key]
		var existing := false
		for n: Node in tree.get_nodes_in_group(GROUP):
			if (n as TouchTest).get_window() == w:
				existing = true
		if not existing:
			var t := TouchTest.new()
			t.window_key = key
			w.add_child(t)
	print("touch-test: open on %s" % ", ".join(PackedStringArray(windows.keys())))


static func close_all(tree: SceneTree) -> void:
	for n: Node in tree.get_nodes_in_group(GROUP):
		n.queue_free()


func _init() -> void:
	add_to_group(GROUP)
	layer = 90


func _ready() -> void:
	canvas = Canvas.new()
	canvas.test = self
	canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(canvas)


func close_rect(sz: Vector2) -> Rect2:
	return Rect2(sz + CLOSE.position, CLOSE.size)


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		var p := _local(st.position)
		if st.pressed:
			presses += 1
			touches[st.index] = p
			trail.clear()
			print("touch-test: %s window press #%d at %d, %d" % [window_key, st.index, roundi(p.x), roundi(p.y)])
		else:
			touches.erase(st.index)
			if window_key == "touch" and close_rect(canvas.size).has_point(p):
				close_all(get_tree())
	elif event is InputEventScreenDrag:
		var sd := event as InputEventScreenDrag
		drags += 1
		touches[sd.index] = _local(sd.position)
		if sd.index == 0:
			trail.append(touches[sd.index])
			if trail.size() > TRAIL_MAX:
				trail = trail.slice(trail.size() - TRAIL_MAX)
	elif event is InputEventMouseButton and window_key == "touch":
		var mb := event as InputEventMouseButton
		if not mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and close_rect(canvas.size).has_point(_local(mb.position)):
			close_all(get_tree())
	elif event is InputEventKey and event.pressed and (event as InputEventKey).keycode == KEY_ESCAPE:
		close_all(get_tree())
	else:
		return
	canvas.queue_redraw()
	if window_key == "touch":
		get_viewport().set_input_as_handled()


## Event positions are in the window's viewport; the canvas may be scaled by
## the content stretch, so map through its transform.
func _local(p: Vector2) -> Vector2:
	return canvas.get_global_transform_with_canvas().affine_inverse() * p


func report() -> Dictionary:
	return {"window": window_key, "presses": presses, "drags": drags, "down": touches.size()}
