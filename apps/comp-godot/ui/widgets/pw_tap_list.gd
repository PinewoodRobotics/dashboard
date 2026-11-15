class_name PwTapList
extends PwScroll

## Vertical list of tappable rows in a PwScroll (PathListPane.tsx: padding and
## gap inside the scroller, bar at its right edge). Rows ignore the mouse; a
## press released on a row within the tap slop fires item_tapped, so a touch
## that scrolls never taps.

signal item_tapped(index: int)

var items: VBoxContainer
var _pressed := false
var _start := Vector2.ZERO


func _init(gap: int = 10, pad: int = 0) -> void:
	super(true)
	mouse_filter = Control.MOUSE_FILTER_STOP
	items = VBoxContainer.new()
	items.add_theme_constant_override("separation", gap)
	items.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var m := MarginContainer.new()
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		m.add_theme_constant_override(side, pad)
	m.add_child(items)
	add_child(m)


func add_item(c: Control) -> void:
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	items.add_child(c)


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
func reveal_index(index: int) -> void:
	if index >= 0 and index < items.get_child_count():
		reveal(items.get_child(index) as Control)


func _gui_input(event: InputEvent) -> void:
	if _scroll_input(event):
		return
	var p := PointerInput.from_event(event)
	match p.kind:
		PointerInput.Kind.DOWN:
			_pressed = not _on_bar(p.pos)
			_start = p.pos
			if _pressed:
				accept_event()
		PointerInput.Kind.MOVE:
			if _pressed and (dragging or p.pos.distance_to(_start) > PwButton.TAP_SLOP_PX):
				_pressed = false
		PointerInput.Kind.UP:
			var tap := _pressed and not dragging
			_pressed = false
			if tap:
				var i := index_at(get_global_transform() * p.pos)
				if i >= 0:
					item_tapped.emit(i)
