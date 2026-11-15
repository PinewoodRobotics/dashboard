class_name TabIcon
extends Control

## One 48 px SF Symbol in the rail, dock or drawer column, centered on the
## cell: the white outline symbol, or the green filled one when active (no
## transition), faded while it is the drag source. Rail and dock items report
## their pointer stream to the TouchDnd controller (tap or hold-drag); other
## cells just emit `tapped`.

signal tapped

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
var faded := false:
	set(v):
		if v != faded:
			faded = v
			queue_redraw()
var dnd: TouchDnd
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


func canvas_center() -> Vector2:
	return get_global_rect().get_center()


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
			if _down and Rect2(Vector2.ZERO, size).has_point(p.pos):
				tapped.emit()
			_down = false
	accept_event()


func _draw() -> void:
	UiDraw.begin(self)
	var col := Tokens.ACCENT if active else Tokens.TEXT
	Sf.draw(self, active_symbol if active else symbol, size * 0.5, Tokens.ICON, Color(col, 0.3 if faded else 1.0))
