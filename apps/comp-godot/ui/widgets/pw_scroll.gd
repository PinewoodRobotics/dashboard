class_name PwScroll
extends Container

## One-axis scroller that drags with mouse and touch alike, with the web's
## 5 px accent scrollbar. ScrollContainer only drag-scrolls when the OS reports
## a touchscreen and never when the press lands on a button or slider, so this
## watches the stroke in _input instead: once it travels further than a tap
## along the scroll axis, it scrolls. The widgets under the finger drop the
## stroke on their own at that distance (buttons past PwButton.TAP_SLOP_PX,
## sliders and selectors on cross-axis intent). A horizontal scroller leaves
## strokes that start on horizontal-drag widgets (pw_hgrab) to them, and
## neither axis takes strokes from grab widgets (pw_grab: 3D views, keyboard).
## Dragging along the bar's edge moves the bar instead, as a desktop
## scrollbar does. The single child keeps its minimum size along the axis and fills the other.

const DRAG_PX := PwButton.TAP_SLOP_PX
const WHEEL_PX := 60.0
const BAR_W := 5.0
const BAR_HIT_PX := 14.0

var vertical := true
var scroll_offset := 0.0:
	set(v):
		var c := clampf(v, 0.0, max_scroll())
		if c == scroll_offset:
			return
		scroll_offset = c
		queue_sort()
		queue_redraw()
var scroll_vertical: int:
	get:
		return int(scroll_offset) if vertical else 0
	set(v):
		if vertical:
			scroll_offset = v
var scroll_horizontal: int:
	get:
		return 0 if vertical else int(scroll_offset)
	set(v):
		if not vertical:
			scroll_offset = v
var dragging := false
var _pressed := false
var _on_bar := false
var _start := Vector2.ZERO
var _start_scroll := 0.0


func _init(is_vertical: bool = true) -> void:
	vertical = is_vertical
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_PASS
	add_to_group("pw_scroll" if vertical else "pw_hscroll")


func content() -> Control:
	for c in get_children():
		if c is Control:
			return c
	return null


func content_length() -> float:
	var c := content()
	if c == null:
		return 0.0
	var m := c.get_combined_minimum_size()
	return m.y if vertical else m.x


func view_length() -> float:
	return size.y if vertical else size.x


func max_scroll() -> float:
	return maxf(0.0, content_length() - view_length())


func _get_minimum_size() -> Vector2:
	var c := content()
	if c == null:
		return Vector2.ZERO
	var m := c.get_combined_minimum_size()
	return Vector2(m.x, 0.0) if vertical else Vector2(0.0, m.y)


func _notification(what: int) -> void:
	if what == NOTIFICATION_SORT_CHILDREN:
		scroll_offset = scroll_offset
		var c := content()
		if c == null:
			return
		var len := maxf(content_length(), view_length())
		if vertical:
			fit_child_in_rect(c, Rect2(0.0, -scroll_offset, size.x, len))
		else:
			fit_child_in_rect(c, Rect2(-scroll_offset, 0.0, len, size.y))
		queue_redraw()


## Scrolls so the descendant is fully visible.
func reveal(ctl: Control) -> void:
	var r := ctl.get_global_rect()
	var mine := get_global_rect()
	var lo := (r.position.y - mine.position.y) if vertical else (r.position.x - mine.position.x)
	var hi := lo + (r.size.y if vertical else r.size.x)
	if lo < 0.0:
		scroll_offset += lo
	elif hi > view_length():
		scroll_offset += hi - view_length()


func _owns_press(pos: Vector2) -> bool:
	if not is_visible_in_tree() or not get_global_rect().has_point(pos):
		return false
	var hit := pick(get_viewport(), pos)
	if hit == null or hit != self and not is_ancestor_of(hit):
		return false
	var n: Node = hit
	while n != null and n != self:
		if n.is_in_group("pw_grab") or (not vertical and n.is_in_group("pw_hgrab")):
			return false
		n = n.get_parent()
	return true


## The control a press at pos goes to, found the way Viewport does it (higher
## canvas layers first, then later siblings, children before their parent).
## Viewport.gui_get_hovered_control() is not usable: emulated touches never
## set it.
static func pick(vp: Viewport, pos: Vector2) -> Control:
	var layers: Array = vp.find_children("*", "CanvasLayer", true, false)
	layers.sort_custom(func(a: CanvasLayer, b: CanvasLayer) -> bool: return a.layer > b.layer)
	for l: CanvasLayer in layers:
		if l.layer > 0 and l.visible:
			var hit := _pick_children(l, pos)
			if hit != null:
				return hit
	return _pick_children(vp, pos)


static func _pick_children(n: Node, pos: Vector2) -> Control:
	for i in range(n.get_child_count() - 1, -1, -1):
		var child := n.get_child(i)
		var hit: Control = null
		if child is Control:
			hit = _pick_control(child, pos)
		elif not (child is CanvasLayer or child is Window or (child is CanvasItem and not (child as CanvasItem).visible)):
			hit = _pick_children(child, pos)
		if hit != null:
			return hit
	return null


static func _pick_control(c: Control, pos: Vector2) -> Control:
	if not c.visible:
		return null
	var inside := c.get_global_rect().has_point(pos)
	if c.clip_contents and not inside:
		return null
	var hit := _pick_children(c, pos)
	if hit != null:
		return hit
	return c if inside and c.mouse_filter != Control.MOUSE_FILTER_IGNORE else null


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		var mb := event as InputEventMouseButton
		var step := 0.0
		match mb.button_index:
			MOUSE_BUTTON_WHEEL_DOWN, MOUSE_BUTTON_WHEEL_RIGHT:
				step = WHEEL_PX
			MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_LEFT:
				step = -WHEEL_PX
		if step != 0.0:
			if max_scroll() > 0.0 and _owns_press(mb.position):
				scroll_offset += step
				get_viewport().set_input_as_handled()
			return
	var p := PointerInput.from_event(event)
	match p.kind:
		PointerInput.Kind.DOWN:
			_pressed = max_scroll() > 0.0 and _owns_press(p.pos)
			var local := get_global_transform().affine_inverse() * p.pos
			_on_bar = _pressed and (local.x >= size.x - BAR_HIT_PX if vertical else local.y >= size.y - BAR_HIT_PX)
			dragging = false
			_start = p.pos
			_start_scroll = scroll_offset
		PointerInput.Kind.MOVE:
			if not _pressed:
				return
			var d := p.pos - _start
			var along := d.y if vertical else d.x
			var across := d.x if vertical else d.y
			if _on_bar:
				dragging = true
				scroll_offset = _start_scroll + along * max_scroll() / maxf(1.0, view_length() - bar_length())
				return
			if not dragging:
				if absf(along) > DRAG_PX and absf(along) >= absf(across):
					dragging = true
					_start = p.pos
					_start_scroll = scroll_offset
				elif d.length() > DRAG_PX:
					_pressed = false
				return
			scroll_offset = _start_scroll - along
		PointerInput.Kind.UP:
			_pressed = false
			_on_bar = false
			dragging = false


func bar_length() -> float:
	var total := content_length()
	var view := view_length()
	return maxf(24.0, view * view / total) if total > 0.0 else view


func _draw() -> void:
	var total := content_length()
	var view := view_length()
	if total <= view + 0.5:
		return
	var len := bar_length()
	var at := (view - len) * scroll_offset / max_scroll()
	var r := Rect2(size.x - BAR_W, at, BAR_W, len) if vertical else Rect2(at, size.y - BAR_W, len, BAR_W)
	UiDraw.rect(get_canvas_item(), r, Tokens.ACCENT)
