class_name TabIcon
extends Control

## One 48 px glyph cell in the rail, dock or drawer column: white, accent when
## active, faded while it is the drag source. Rail and dock items report their
## pointer stream to the TouchDnd controller (tap or hold-drag); other cells
## just emit `tapped`.

signal tapped

var icon_name := ""
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


func _init(icon: String = "", item_zone: String = "", id: String = "") -> void:
	icon_name = icon
	zone = item_zone
	tab_id = id
	name = ("%s_%s" % [item_zone, id]) if id != "" else icon
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
	var col := Tokens.ACCENT if active else Tokens.TEXT
	var tex := Icons.texture(icon_name, Tokens.ICON, col)
	if tex != null:
		draw_texture(tex, ((size - Vector2(Tokens.ICON, Tokens.ICON)) * 0.5).round(), Color(1, 1, 1, 0.3 if faded else 1.0))
