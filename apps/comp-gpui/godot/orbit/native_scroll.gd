class_name NativeScroll
extends RefCounted

## OS scroll input as the WheelEvent deltaX/deltaY Chromium hands the web app,
## in design px: positive scrolls toward the end (content moves up or left).
## Godot macOS reports a line wheel as factor = lines * 0.3 and a trackpad or
## touch scroll (momentum included) as a pan gesture of -points * 0.03
## (platform/macos/godot_content_view.mm, scrollWheel); Chromium scrolls 40 px
## per Cocoa line and 100 px per Windows/Linux notch.

const NOTCH_PX := 100.0
const MAC_LINE_PX := 40.0
const MAC_LINE_FACTOR := 0.3
const MAC_PAN_SCALE := 0.03


static func wheel_delta(mb: InputEventMouseButton, ctl: Control) -> Vector2:
	var factor := mb.factor if mb.factor > 0.0 else 1.0
	var px := factor * (MAC_LINE_PX / MAC_LINE_FACTOR if OS.get_name() == "macOS" else NOTCH_PX)
	var d := Vector2.ZERO
	match mb.button_index:
		MOUSE_BUTTON_WHEEL_DOWN:
			d = Vector2(0.0, px)
		MOUSE_BUTTON_WHEEL_UP:
			d = Vector2(0.0, -px)
		MOUSE_BUTTON_WHEEL_RIGHT:
			d = Vector2(px, 0.0)
		MOUSE_BUTTON_WHEEL_LEFT:
			d = Vector2(-px, 0.0)
	if mb.shift_pressed and d.x == 0.0:
		d = Vector2(d.y, 0.0)
	return d * dip_to_design(ctl)


static func pan_delta(pg: InputEventPanGesture, ctl: Control) -> Vector2:
	return pg.delta / MAC_PAN_SCALE * dip_to_design(ctl)


static func is_wheel(mb: InputEventMouseButton) -> bool:
	return mb.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN, MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT]


## Design px per OS point (Chromium DIP) for the window ctl is in.
static func dip_to_design(ctl: Control) -> float:
	if ctl == null or not ctl.is_inside_tree():
		return 1.0
	var w := ctl.get_window()
	if w == null:
		return 1.0
	var px_per_dip := DisplayServer.screen_get_scale(w.current_screen) if OS.get_name() == "macOS" else 1.0
	var stretch := w.content_scale_factor
	var cs := Vector2(w.content_scale_size)
	if cs.x > 0.0 and cs.y > 0.0 and w.size.x > 0 and w.size.y > 0:
		stretch *= minf(float(w.size.x) / cs.x, float(w.size.y) / cs.y)
	return px_per_dip / maxf(stretch, 1e-3)
