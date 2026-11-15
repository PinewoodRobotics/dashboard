class_name TabIcon
extends Control

## One SF Symbol button of the rail, dock or drawer column (LeftIcon.tsx,
## SortableDockIcon.tsx, RightIconColumn.tsx): the white outline symbol, or the
## green filled one when active, swapped instantly. The control's rect is the
## web element's box (`slot`); the 48 px line-height-1 symbol span centered on
## it overflows a 27 px button and still takes taps. While a sibling is
## dragged, `shift_to` moves and stretches it like a dnd-kit sortable transform
## (200 ms ease, scaled about its center). Rail and dock items report their
## pointer stream to the TouchDnd controller; other buttons emit `tapped`.

signal tapped

const SORT_S := 0.2

var symbol := 0
var active_symbol := 0
## "rail", "dock" or "" (not draggable).
var zone := ""
var tab_id := ""
var active := false:
	set(v):
		if v != active:
			active = v
			queue_redraw()
## The drag source's placeholder (opacity 0.3).
var faded := false:
	set(v):
		if v != faded:
			faded = v
			queue_redraw()
## Hidden while the drop animation flies the ghost onto it.
var landing_hidden := false:
	set(v):
		if v != landing_hidden:
			landing_hidden = v
			queue_redraw()
var dnd: TouchDnd
var slot := Rect2()
var _shift := [UiAnim.new(), UiAnim.new()]
var _stretch := [UiAnim.new(1.0), UiAnim.new(1.0)]
var _down := false
var _start := Vector2.ZERO


func _init(info: Dictionary = {}, item_zone: String = "", id: String = "") -> void:
	symbol = int(info.get("symbol", 0))
	active_symbol = int(info.get("active_symbol", symbol))
	zone = item_zone
	tab_id = id
	if id != "":
		name = "%s_%s" % [item_zone, id]
	mouse_filter = Control.MOUSE_FILTER_STOP


func shown_symbol() -> int:
	return active_symbol if active else symbol


## Width of the shown symbol's span (its advance at 48 px).
func span_width() -> float:
	return Sf.advance(shown_symbol(), Tokens.ICON)


func place(r: Rect2) -> void:
	slot = r
	for a: UiAnim in _shift + _stretch:
		a.jump(a.to)
	_apply()


func slot_center() -> Vector2:
	var parent := get_parent() as CanvasItem
	return parent.get_global_transform() * slot.get_center() if parent != null else slot.get_center()


func slot_rect() -> Rect2:
	return Rect2(slot_center() - slot.size * 0.5, slot.size)


func shift_to(offset: Vector2, stretch: Vector2 = Vector2.ONE, animate: bool = true) -> void:
	var targets := [offset.x, offset.y, stretch.x, stretch.y]
	var anims: Array = _shift + _stretch
	for i in 4:
		var a: UiAnim = anims[i]
		if animate:
			a.retarget(targets[i], SORT_S)
		else:
			a.jump(targets[i])
	_apply()


func shift() -> Vector2:
	return Vector2(_shift[0].to, _shift[1].to)


func step(dt: float) -> void:
	var moving := false
	for a: UiAnim in _shift + _stretch:
		if a.running:
			a.step(dt)
			moving = true
	if moving:
		_apply()


func _apply() -> void:
	size = slot.size
	pivot_offset = size * 0.5
	position = slot.position + Vector2(_shift[0].value, _shift[1].value)
	scale = Vector2(_stretch[0].value, _stretch[1].value)


func _has_point(p: Vector2) -> bool:
	var w := span_width()
	var span := Rect2(size.x * 0.5 - w * 0.5, size.y * 0.5 - Tokens.ICON * 0.5, w, Tokens.ICON)
	return Rect2(Vector2.ZERO, size).has_point(p) or span.has_point(p)


func _gui_input(event: InputEvent) -> void:
	var p := PointerInput.from_event(event)
	if p.kind == PointerInput.Kind.NONE:
		return
	var canvas := get_global_transform() * p.pos
	if dnd != null and zone != "":
		match p.kind:
			PointerInput.Kind.DOWN:
				dnd.press(self, canvas, p.is_touch)
			PointerInput.Kind.MOVE:
				dnd.move(canvas)
			PointerInput.Kind.UP:
				dnd.release(canvas)
		accept_event()
		return
	match p.kind:
		PointerInput.Kind.DOWN:
			_down = true
			_start = p.pos
		PointerInput.Kind.MOVE:
			if _down and p.pos.distance_to(_start) > PwButton.TAP_SLOP_PX:
				_down = false
		PointerInput.Kind.UP:
			if _down and _has_point(p.pos):
				tapped.emit()
			_down = false
	accept_event()


func _draw() -> void:
	UiDraw.begin(self)
	if landing_hidden:
		return
	var col := Tokens.ACCENT if active else Tokens.TEXT
	Sf.draw(self, shown_symbol(), size * 0.5, Tokens.ICON, Color(col, 0.3 if faded else 1.0))
