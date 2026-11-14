class_name PwButton
extends Control

## Touch button with tap semantics: it fires on release inside the button
## when the pointer moved less than TAP_SLOP_PX, so a swipe that starts on a
## button never presses it.

signal pressed

enum Style { DARK, PRIMARY, OUTLINE, ACCENT, LIGHT, GHOST }

const TAP_SLOP_PX := 16.0

var text := "":
	set(v):
		text = v
		queue_redraw()
var variant := Style.DARK:
	set(v):
		variant = v
		queue_redraw()
var font_size := 24:
	set(v):
		font_size = v
		queue_redraw()
var icon_name := ""
var disabled := false:
	set(v):
		disabled = v
		if v:
			_down = false
		queue_redraw()
var radius := 8.0
var _down := false
var _start := Vector2.ZERO


func _init(label: String = "", kind: Style = Style.DARK, min_size: Vector2 = Vector2(0, 48)) -> void:
	text = label
	variant = kind
	custom_minimum_size = min_size
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE


func is_down() -> bool:
	return _down


func _gui_input(event: InputEvent) -> void:
	var p := PointerInput.from_event(event)
	if p.kind == PointerInput.Kind.NONE or disabled:
		return
	match p.kind:
		PointerInput.Kind.DOWN:
			_down = true
			_start = p.pos
			accept_event()
		PointerInput.Kind.MOVE:
			if _down and p.pos.distance_to(_start) > TAP_SLOP_PX:
				_down = false
		PointerInput.Kind.UP:
			var fire := _down and Rect2(Vector2.ZERO, size).has_point(p.pos)
			_down = false
			if fire:
				pressed.emit()
	queue_redraw()


func _colors() -> Dictionary:
	match variant:
		Style.PRIMARY:
			return {"bg": Tokens.ACCENT.darkened(0.15) if _down else Tokens.ACCENT, "border": Color(0, 0, 0, 0), "text": Color.BLACK}
		Style.OUTLINE:
			return {"bg": Color(1, 1, 1, 0.08) if _down else Color(0, 0, 0, 0), "border": Tokens.OUTLINE, "text": Tokens.ZINC_400}
		Style.ACCENT:
			return {"bg": Tokens.SELECTED_FILL, "border": Tokens.ACCENT, "text": Tokens.ACCENT}
		Style.GHOST:
			return {"bg": Color(1, 1, 1, 0.2 if _down else 0.1), "border": Color(0, 0, 0, 0), "text": Color(1, 1, 1, 0.6)}
		Style.LIGHT:
			return {"bg": Tokens.ZINC_300 if _down else Color.WHITE, "border": Color(0, 0, 0, 0), "text": Color.BLACK}
	return {"bg": Tokens.ZINC_800 if _down else Color.BLACK, "border": Color(0, 0, 0, 0), "text": Tokens.TEXT}


func _draw() -> void:
	UiDraw.begin(self)
	var c := _colors()
	var a := 0.5 if disabled else 1.0
	var bg: Color = c["bg"]
	var border: Color = c["border"]
	bg.a *= a
	border.a *= a
	UiDraw.box(get_canvas_item(), Rect2(Vector2.ZERO, size), bg, radius, 2 if variant == Style.OUTLINE else (Tokens.BORDER if variant == Style.ACCENT else 0), border)
	var font := Tokens.inter(500)
	var col: Color = c["text"]
	col.a *= a
	var icon_w := 0.0
	if icon_name != "":
		icon_w = font_size + 10.0
	var tw := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var x := (size.x - tw - icon_w) * 0.5
	if icon_name != "":
		var tex := Icons.texture(icon_name, font_size)
		if tex != null:
			draw_texture(tex, Vector2(x, (size.y - font_size) * 0.5).round(), col)
	var baseline := (size.y + font.get_ascent(font_size) - font.get_descent(font_size)) * 0.5
	UiDraw.text(self, font, Vector2(x + icon_w, baseline).round(), text, font_size, col)
