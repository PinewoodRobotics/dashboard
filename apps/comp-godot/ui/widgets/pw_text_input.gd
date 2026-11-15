class_name PwTextInput
extends Control

## CustomTextInput.tsx: label, 72 px field with a 4 px border; focused it is
## green on the focus fill, else red when invalid, else white on the panel
## gray, fading over 100 ms. Godot has no usable on-screen keyboard on
## Windows desktop, so a tap opens the in-app PwKeyboard of this window
## (the numeric keypad for numeric fields). `numeric` strips non-digits.

signal text_changed(text: String)
signal submitted(text: String)

const FIELD_H := 72.0
const LABEL_PX := 12
const LABEL_LINE := 16.0
const LABEL_TRACKING := 2.4
const GAP := 8.0
const TEXT_PX := 24
const INSET := Tokens.BORDER + 20.0
const CARET_BLINK_S := 0.5

var label := ""
var placeholder := ""
var numeric := false
var max_length := 64
var invalid := false:
	set(v):
		invalid = v
		_restyle()
var editing := false:
	set(v):
		editing = v
		_caret_t = 0.0
		_restyle()
var text := ""
var _border := ColorAnim.new(Tokens.TEXT)
var _bg := ColorAnim.new(Tokens.PANEL)
var _caret_t := 0.0

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
	return LABEL_LINE + GAP if label != "" else 0.0


func _restyle() -> void:
	var border := Tokens.ACCENT if editing else (Tokens.ERROR if invalid else Tokens.TEXT)
	var s := Tokens.MOTION_PRESS_S if is_inside_tree() else 0.0
	_border.set_target(border, s)
	_bg.set_target(Tokens.FOCUS_FILL if editing else Tokens.PANEL, s)
	set_process(true)
	queue_redraw()


func _process(delta: float) -> void:
	_border.step(delta)
	_bg.step(delta)
	if editing:
		var was := fmod(_caret_t, CARET_BLINK_S * 2.0) < CARET_BLINK_S
		_caret_t += delta
		if was != (fmod(_caret_t, CARET_BLINK_S * 2.0) < CARET_BLINK_S):
			queue_redraw()
	if _border.running() or _bg.running():
		queue_redraw()
	elif not editing:
		set_process(false)


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


## The label's baseline in its 16 px line (text-xs), placed as CSS centers a
## line box.
static func label_baseline() -> float:
	var f := Tokens.inter(600)
	return roundf((LABEL_LINE + f.get_ascent(LABEL_PX) - f.get_descent(LABEL_PX)) * 0.5)


func _draw() -> void:
	UiDraw.begin(self)
	var ci := get_canvas_item()
	if label != "":
		UiDraw.text_tracked(self, Tokens.inter(600), Vector2(0, label_baseline()), label, LABEL_PX, Tokens.TEXT, LABEL_TRACKING)
	var r := field_rect()
	UiDraw.rect(ci, r, _bg.value())
	UiDraw.frame(ci, r, _border.value(), Tokens.BORDER)
	var f := Tokens.inter(300)
	var base := roundf(r.position.y + (r.size.y + f.get_ascent(TEXT_PX) - f.get_descent(TEXT_PX)) * 0.5)
	var shown := text if text != "" else placeholder
	var col := Tokens.TEXT if text != "" else Tokens.ZINC_600
	UiDraw.text(self, f, Vector2(r.position.x + INSET, base), shown, TEXT_PX, col, HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 2.0 * INSET)
	if editing and fmod(_caret_t, CARET_BLINK_S * 2.0) < CARET_BLINK_S:
		var cx := roundf(r.position.x + INSET + (f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, TEXT_PX).x if text != "" else 0.0))
		var h := f.get_ascent(TEXT_PX) + f.get_descent(TEXT_PX)
		UiDraw.rect(ci, Rect2(cx, base - f.get_ascent(TEXT_PX), 1, h), Tokens.TEXT)
