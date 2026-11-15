class_name PwRange
extends Control

## Chromium's own <input type="range"> in the light scheme with an
## accent-color (Robot3DTab.tsx joint sliders): a 16 px box with 2 px margins,
## an 8 px round track with a 1 px border, the part before the thumb in the
## accent color, a 16 px accent thumb. A press moves the thumb to the pointer
## and dragging follows it; values snap to step from min. Disabled shows the
## browser's gray at 40% opacity.

signal value_changed(value: float)

const BOX_H := 16.0
const MARGIN := 2.0
const TRACK_H := 8.0
const THUMB := 16.0
const TRACK_BG := Color("#efefef")
const TRACK_BORDER := Color("#767676")
const DISABLED_FILL := Color("#cbcbcb")
const DISABLED_BORDER := Color("#c5c5c5")
const DISABLED_TRACK := Color("#fafafa")

var min_value := 0.0
var max_value := 1.0
var step := 0.01
var value := 0.0
var accent := Color("#60a5fa")
var disabled := false:
	set(v):
		if v != disabled:
			disabled = v
			_dragging = false
			queue_redraw()
var _dragging := false


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(0, BOX_H + 2.0 * MARGIN)
	add_to_group("pw_hgrab")


func touch_action_none(_local_pos: Vector2) -> bool:
	return true


func set_value(v: float, emit: bool = false) -> void:
	var q := PwSlider.quantize(v, min_value, max_value, step, [])
	if is_equal_approx(q, value):
		return
	value = q
	queue_redraw()
	if emit:
		value_changed.emit(value)


func _box() -> Rect2:
	return Rect2(MARGIN, (size.y - BOX_H) * 0.5, size.x - 2.0 * MARGIN, BOX_H)


func _value_at(x: float) -> float:
	var b := _box()
	var travel := maxf(1.0, b.size.x - THUMB)
	return min_value + clampf((x - b.position.x - THUMB * 0.5) / travel, 0.0, 1.0) * (max_value - min_value)


func _gui_input(event: InputEvent) -> void:
	var p := PointerInput.from_event(event)
	if p.kind == PointerInput.Kind.NONE or disabled:
		return
	match p.kind:
		PointerInput.Kind.DOWN:
			_dragging = true
			set_value(_value_at(p.pos.x), true)
			accept_event()
		PointerInput.Kind.MOVE:
			if _dragging:
				set_value(_value_at(p.pos.x), true)
				accept_event()
		PointerInput.Kind.UP:
			_dragging = false


func _draw() -> void:
	var ci := get_canvas_item()
	var a := 0.4 if disabled else 1.0
	var b := _box()
	var t := PwSlider.value_fraction(value, min_value, max_value)
	var cx := b.position.x + THUMB * 0.5 + t * maxf(0.0, b.size.x - THUMB)
	var track := Rect2(b.position.x, b.get_center().y - TRACK_H * 0.5, b.size.x, TRACK_H)
	var fill := DISABLED_FILL if disabled else accent
	UiDraw.box(ci, track, Color(DISABLED_TRACK if disabled else TRACK_BG, a), TRACK_H * 0.5, 1, Color(DISABLED_BORDER if disabled else TRACK_BORDER, a))
	var filled := Rect2(track.position, Vector2(maxf(cx - track.position.x, TRACK_H), TRACK_H))
	UiDraw.box(ci, filled, Color(fill, a), TRACK_H * 0.5)
	UiDraw.circle(ci, Vector2(cx, b.get_center().y), THUMB * 0.5, Color(fill, a))
