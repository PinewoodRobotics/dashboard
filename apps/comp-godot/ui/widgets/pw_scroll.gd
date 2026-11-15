class_name PwScroll
extends Container

## One-axis overflow scroller: the web's overflow-y-scroll / overflow-x-scroll
## (or -auto) with its custom 5 px scrollbar (settings/constants.ts colScroll
## and the horizontal strips). Like a classic Chromium bar the bar's thickness
## sits beside the content, always (always_bar) or only while the content
## overflows; the square ACCENT thumb runs on a track_color track, drags, and a
## press on the track pages toward the pointer.
## Scrolling comes from the OS: the mouse wheel, and trackpad or touch
## scrolling with the OS's own momentum (pan gestures), at Chromium's pixel
## rates (a wheel notch and a track page animate as Chromium's do on Windows
## and Linux, SmoothScroll). An event goes to the innermost scroller that can still move along the
## gesture's main axis, otherwise on to its parents. A mouse drag on the
## content never scrolls, as in a desktop browser.
## Touchscreens that report only touches (Windows, Linux) get Chromium's touch
## scrolling in its place: past the tap slop along the axis the touch drags the
## content, then flings (TouchFling). Touches that start on grab widgets
## (pw_grab: 3D views, keyboard), on horizontal-drag widgets for a horizontal
## scroller (pw_hgrab) or in a widget's touch_action_none() area (the web's
## touch-action: none) stay with that widget.

const DRAG_PX := PwButton.TAP_SLOP_PX
const BAR_W := 5.0
const PAGE_FRACTION := 0.875
const PAGE_REPEAT_DELAY_S := 0.25
const PAGE_REPEAT_S := 0.05

var vertical := true
var always_bar := true
var track_color := Color(0, 0, 0, 0)
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
var fling := TouchFling.new()
var smooth := SmoothScroll.new()
var _touch_pressed := false
var _touch_start := Vector2.ZERO
var _touch_start_scroll := 0.0
var _thumb_drag := false
var _thumb_grab := 0.0
var _page_dir := 0.0
var _page_at := 0.0
var _page_wait := 0.0
var _bar_was := true


func _init(is_vertical: bool = true, bar_always: bool = true, track: Color = Color(0, 0, 0, 0)) -> void:
	vertical = is_vertical
	always_bar = bar_always
	track_color = track
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_PASS
	add_to_group("pw_scroll" if vertical else "pw_hscroll")


func _ready() -> void:
	set_process(false)


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


func bar_visible() -> bool:
	return always_bar or content_length() > view_length() + 0.5


func _bar_thickness() -> float:
	return BAR_W if bar_visible() else 0.0


func _get_minimum_size() -> Vector2:
	var c := content()
	if c == null:
		return Vector2(BAR_W, 0.0) if vertical and always_bar else Vector2(0.0, BAR_W if always_bar else 0.0)
	var m := c.get_combined_minimum_size()
	return Vector2(m.x + _bar_thickness(), 0.0) if vertical else Vector2(0.0, m.y + _bar_thickness())


func _notification(what: int) -> void:
	if what == NOTIFICATION_SORT_CHILDREN:
		scroll_offset = scroll_offset
		var c := content()
		if c == null:
			return
		var len := maxf(content_length(), view_length())
		if vertical:
			fit_child_in_rect(c, Rect2(0.0, -scroll_offset, size.x - _bar_thickness(), len))
		else:
			fit_child_in_rect(c, Rect2(-scroll_offset, 0.0, len, size.y - _bar_thickness()))
		if bar_visible() != _bar_was:
			_bar_was = bar_visible()
			update_minimum_size()
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


## Scrolls by an OS delta (NativeScroll units) when its main axis is ours and
## there is room in that direction, animated for a discrete wheel notch.
## Returns whether it scrolled.
func scroll_by_native(delta: Vector2, notch: bool = false) -> bool:
	var along := delta.y if vertical else delta.x
	var across := delta.x if vertical else delta.y
	if along == 0.0 or absf(along) < absf(across):
		return false
	if notch and SmoothScroll.enabled:
		return _smooth_by(along, -1.0)
	smooth.active = false
	var before := scroll_offset
	scroll_offset += along
	if scroll_offset == before:
		return false
	fling.active = false
	return true


## seconds < 0 times the jump as a wheel notch.
func _smooth_by(px: float, seconds: float) -> bool:
	var base := smooth.target if smooth.active else scroll_offset
	var to := clampf(base + px, 0.0, max_scroll())
	if to == base:
		return smooth.active
	fling.active = false
	smooth.start(scroll_offset, to, SmoothScroll.wheel_seconds(to - scroll_offset) if seconds < 0.0 else seconds)
	set_process(true)
	return true


func _gui_input(event: InputEvent) -> void:
	_scroll_input(event)


## Wheel, pan gesture and scrollbar input; returns whether it took the event.
func _scroll_input(event: InputEvent) -> bool:
	if event is InputEventPanGesture:
		if scroll_by_native(NativeScroll.pan_delta(event as InputEventPanGesture, self)):
			accept_event()
			return true
		return false
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if NativeScroll.is_wheel(mb):
			if mb.pressed and scroll_by_native(NativeScroll.wheel_delta(mb, self), true):
				accept_event()
				return true
			return false
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return false
		if mb.pressed and _on_bar(mb.position):
			_press_bar(mb.position)
			accept_event()
			return true
		if not mb.pressed and (_thumb_drag or _page_dir != 0.0):
			_thumb_drag = false
			dragging = false
			_page_dir = 0.0
			accept_event()
			return true
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _thumb_drag:
			var at := (mm.position.y if vertical else mm.position.x) - _thumb_grab
			var room := maxf(1.0, view_length() - bar_length())
			scroll_offset = at * max_scroll() / room
			accept_event()
			return true
		if _page_dir != 0.0:
			_page_at = mm.position.y if vertical else mm.position.x
			return true
	return false


func _on_bar(local: Vector2) -> bool:
	if not bar_visible() or max_scroll() <= 0.0:
		return false
	return local.x >= size.x - BAR_W if vertical else local.y >= size.y - BAR_W


func _press_bar(local: Vector2) -> void:
	fling.active = false
	smooth.active = false
	var at := local.y if vertical else local.x
	var thumb_at := thumb_start()
	if at >= thumb_at and at <= thumb_at + bar_length():
		_thumb_drag = true
		dragging = true
		_thumb_grab = at - thumb_at
		return
	_page_at = at
	_page_dir = 1.0 if at > thumb_at else -1.0
	_page_once()
	_page_wait = PAGE_REPEAT_DELAY_S
	set_process(true)


func _page_once() -> void:
	var thumb_at := thumb_start()
	var toward := 1.0 if _page_at > thumb_at + bar_length() else (-1.0 if _page_at < thumb_at else 0.0)
	if toward != _page_dir:
		return
	var page := _page_dir * maxf(1.0, view_length() * PAGE_FRACTION)
	if SmoothScroll.enabled:
		_smooth_by(page, SmoothScroll.page_seconds())
	else:
		scroll_offset += page


func _process(delta: float) -> void:
	if _page_dir != 0.0:
		_page_wait -= delta
		if _page_wait <= 0.0:
			_page_wait += PAGE_REPEAT_S
			_page_once()
	if smooth.active:
		scroll_offset = smooth.step(delta)
	if fling.active:
		var before := scroll_offset
		scroll_offset += fling.step(delta)
		if scroll_offset == before and (scroll_offset <= 0.0 or scroll_offset >= max_scroll()):
			fling.active = false
	if _page_dir == 0.0 and not fling.active and not smooth.active:
		set_process(false)


## Stops a touch scroll that another gesture (a swipe dismissal) has claimed.
func cancel_touch() -> void:
	_touch_pressed = false
	dragging = false
	fling.active = false
	smooth.active = false


func _input(event: InputEvent) -> void:
	var p := PointerInput.from_event(event)
	if not p.is_touch:
		return
	var along_pos := p.pos.y if vertical else p.pos.x
	var t := float(PointerInput.now_ms())
	match p.kind:
		PointerInput.Kind.DOWN:
			fling.active = false
			smooth.active = false
			dragging = false
			var local := get_global_transform().affine_inverse() * p.pos
			_touch_pressed = max_scroll() > 0.0 and not _on_bar(local) and _owns_press(p.pos)
			_touch_start = p.pos
			_touch_start_scroll = scroll_offset
			fling.reset()
		PointerInput.Kind.MOVE:
			if not _touch_pressed:
				return
			var d := p.pos - _touch_start
			var along := d.y if vertical else d.x
			var across := d.x if vertical else d.y
			if not dragging:
				if absf(along) > DRAG_PX and absf(along) >= absf(across):
					dragging = true
					_touch_start = p.pos
					_touch_start_scroll = scroll_offset
				elif d.length() > DRAG_PX:
					_touch_pressed = false
				return
			scroll_offset = _touch_start_scroll - along
			fling.add_sample(along_pos, t)
		PointerInput.Kind.UP:
			if _touch_pressed and dragging:
				fling.add_sample(along_pos, t)
				var window_len := get_viewport_rect().size.y if vertical else get_viewport_rect().size.x
				if fling.start(-fling.release_velocity(t), window_len):
					set_process(true)
			_touch_pressed = false
			dragging = false


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
		if n is PwScroll and (n as PwScroll).vertical == vertical and (n as PwScroll).max_scroll() > 0.0:
			return false
		if n.has_method("touch_action_none") and n.touch_action_none((n as Control).get_global_transform().affine_inverse() * pos):
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


## Thumb length along the track: proportional, as a ::-webkit-scrollbar-thumb
## without a min-height.
func bar_length() -> float:
	var total := content_length()
	var view := view_length()
	return clampf(view * view / total, 1.0, view) if total > 0.0 else view


func thumb_start() -> float:
	var room := view_length() - bar_length()
	return room * scroll_offset / max_scroll() if max_scroll() > 0.0 else 0.0


func _draw() -> void:
	if not bar_visible():
		return
	var view := view_length()
	var track := Rect2(size.x - BAR_W, 0.0, BAR_W, size.y) if vertical else Rect2(0.0, size.y - BAR_W, size.x, BAR_W)
	if track_color.a > 0.0:
		UiDraw.rect(get_canvas_item(), track, track_color)
	if content_length() <= view + 0.5:
		return
	var at := thumb_start()
	var len := bar_length()
	var r := Rect2(size.x - BAR_W, at, BAR_W, len) if vertical else Rect2(at, size.y - BAR_W, len, BAR_W)
	UiDraw.rect(get_canvas_item(), r, Tokens.ACCENT)
