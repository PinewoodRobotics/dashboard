class_name PwTextInput
extends Control

## CustomTextInput.tsx: label, 72 px field with a 4 px border (green with the
## focus fill while editing). Godot has no usable on-screen keyboard on
## Windows desktop, so a tap opens the in-app PwKeyboard of this window
## (the numeric keypad for numeric fields). `numeric` strips non-digits.

signal text_changed(text: String)
signal submitted(text: String)

const FIELD_H := 72.0

var label := ""
var placeholder := ""
var numeric := false
var max_length := 64
var invalid := false:
	set(v):
		invalid = v
		queue_redraw()
var editing := false:
	set(v):
		editing = v
		queue_redraw()
var text := ""

var _pressed := false
var _start := Vector2.ZERO


func _init(lbl: String = "", hint: String = "", is_numeric: bool = false) -> void:
	label = lbl
	placeholder = hint
	numeric = is_numeric
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(240, _field_top() + FIELD_H)


static func filter(s: String, digits_only: bool) -> String:
	if not digits_only:
		return s.replace("\n", "").replace("\t", "")
	var out := ""
	for ch in s:
		if ch >= "0" and ch <= "9":
			out += ch
	return out


func set_text(s: String, emit: bool = false) -> void:
	var t := filter(s, numeric).left(max_length)
	if t == text:
		return
	text = t
	queue_redraw()
	if emit:
		text_changed.emit(text)


func insert(s: String) -> void:
	set_text(text + s, true)


func backspace() -> void:
	if text != "":
		set_text(text.left(text.length() - 1), true)


func clear() -> void:
	set_text("", true)


func submit() -> void:
	submitted.emit(text)


func _field_top() -> float:
	return 26.0 if label != "" else 0.0


func field_rect() -> Rect2:
	return Rect2(0, _field_top(), size.x, FIELD_H)


func _gui_input(event: InputEvent) -> void:
	var p := PointerInput.from_event(event)
	match p.kind:
		PointerInput.Kind.DOWN:
			_pressed = true
			_start = p.pos
			accept_event()
		PointerInput.Kind.MOVE:
			if _pressed and p.pos.distance_to(_start) > PwButton.TAP_SLOP_PX:
				_pressed = false
		PointerInput.Kind.UP:
			if _pressed and Rect2(Vector2.ZERO, size).has_point(p.pos):
				open_keyboard()
			_pressed = false


func open_keyboard() -> void:
	var kb := PwKeyboard.for_window(self)
	if kb != null:
		kb.open_for(self)
	else:
		editing = true


func _draw() -> void:
	if label != "":
		draw_string(Tokens.label_font(), Vector2(0, 14), label.to_upper(), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Tokens.TEXT)
	var r := field_rect()
	var border := Tokens.ERROR if invalid else (Tokens.ACCENT if editing else Tokens.TEXT)
	draw_rect(r, Tokens.FOCUS_FILL if editing else Color.BLACK)
	draw_rect(r.grow(-Tokens.BORDER * 0.5), border, false, Tokens.BORDER)
	var f := Tokens.inter(300)
	var fs := 24
	var base := r.position.y + (r.size.y + f.get_ascent(fs) - f.get_descent(fs)) * 0.5
	var shown := text if text != "" else placeholder
	var col := Tokens.TEXT if text != "" else Tokens.ZINC_500
	draw_string(f, Vector2(r.position.x + 20.0, base), shown, HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 40.0, fs, col)
	if editing:
		var cx := r.position.x + 20.0 + (f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x if text != "" else 0.0) + 2.0
		draw_rect(Rect2(cx, r.get_center().y - 16, 2, 32), Tokens.ACCENT)
