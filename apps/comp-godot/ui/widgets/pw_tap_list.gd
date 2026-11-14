class_name PwTapList
extends Control

## Vertical list of tappable rows that scrolls by dragging with mouse and touch
## alike, with the web's 5 px accent scrollbar. Rows ignore the mouse; the list
## hit-tests them on release, so a drag that scrolls never taps. Not a
## ScrollContainer: on touchscreens that would scroll a second time natively.
## TouchScreen.gesture_context reads `scroll_offset` (group pw_scroll) to keep
## a swipe-down from dismissing the overlay while the list is scrolled.

signal item_tapped(index: int)

const DRAG_PX := 8.0
const WHEEL_PX := 60.0
const BAR_W := 5.0

var items: VBoxContainer
var scroll_offset := 0.0:
	set(v):
		scroll_offset = clampf(v, 0.0, max_scroll())
		if items != null:
			items.position.y = -scroll_offset
		queue_redraw()
var _pressed := false
var _dragging := false
var _start := Vector2.ZERO
var _start_scroll := 0.0


func _init(gap: int = 10) -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_to_group("pw_scroll")
	items = VBoxContainer.new()
	items.add_theme_constant_override("separation", gap)
	items.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(items)
	resized.connect(_fit)
	items.minimum_size_changed.connect(_fit)


func _fit() -> void:
	items.position = Vector2(0, -scroll_offset)
	items.size = Vector2(size.x - BAR_W - 6.0, items.get_combined_minimum_size().y)
	scroll_offset = scroll_offset


func max_scroll() -> float:
	if items == null:
		return 0.0
	return maxf(0.0, items.get_combined_minimum_size().y - size.y)


func add_item(c: Control) -> void:
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	items.add_child(c)
	_fit.call_deferred()


func clear_items() -> void:
	for c in items.get_children():
		items.remove_child(c)
		c.queue_free()


func index_at(global_pos: Vector2) -> int:
	for i in items.get_child_count():
		var c := items.get_child(i) as Control
		if c.visible and c.get_global_rect().has_point(global_pos):
			return i
	return -1


## Scrolls so the item is fully visible.
func reveal(index: int) -> void:
	if index < 0 or index >= items.get_child_count():
		return
	var c := items.get_child(index) as Control
	if c.position.y < scroll_offset:
		scroll_offset = c.position.y
	elif c.position.y + c.size.y > scroll_offset + size.y:
		scroll_offset = c.position.y + c.size.y - size.y


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN or mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			scroll_offset += WHEEL_PX * (1.0 if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN else -1.0)
			accept_event()
			return
	var p := PointerInput.from_event(event)
	match p.kind:
		PointerInput.Kind.DOWN:
			_pressed = true
			_dragging = false
			_start = p.pos
			_start_scroll = scroll_offset
			accept_event()
		PointerInput.Kind.MOVE:
			if not _pressed:
				return
			var d := p.pos - _start
			if not _dragging and absf(d.y) > DRAG_PX and absf(d.y) >= absf(d.x):
				_dragging = true
			if _dragging:
				scroll_offset = _start_scroll - d.y
				accept_event()
			elif d.length() > PwButton.TAP_SLOP_PX:
				_pressed = false
		PointerInput.Kind.UP:
			var tap := _pressed and not _dragging
			_pressed = false
			_dragging = false
			if tap:
				var i := index_at(get_global_transform() * p.pos)
				if i >= 0:
					item_tapped.emit(i)


func _draw() -> void:
	var total := items.get_combined_minimum_size().y if items != null else 0.0
	if total <= size.y + 0.5:
		return
	var h := maxf(24.0, size.y * size.y / total)
	var y := (size.y - h) * scroll_offset / max_scroll()
	UiDraw.rect(get_canvas_item(), Rect2(size.x - BAR_W, y, BAR_W, h), Tokens.ACCENT)
