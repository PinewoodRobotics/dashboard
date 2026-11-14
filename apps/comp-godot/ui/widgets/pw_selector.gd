class_name PwSelector
extends Control

## CustomSelector.tsx: 80 px cells overlapping by 4 px (stride 76) with a
## green highlight that slides to the selection in 200 ms. Tap selects the
## cell under the pointer; a horizontal drag (more than 4 px) slides the
## highlight with the pointer and snaps to the nearest cell on release. The
## hint of the option under the highlight shows below and follows the drag.

signal selected(value: Variant)

const CELL := 80.0
const STRIDE := 76.0
const DRAG_PX := 4.0
const ICON_PX := 36
const INTENT_PX := 8.0

var label := ""
## [{"value": Variant, "icon": String, "text": String, "hint": String}]
var options: Array = []
var index := 0
var disabled := false:
	set(v):
		disabled = v
		queue_redraw()
var dragging := false

var _hl := UiAnim.new(0.0)
var _pressed := false
var _start := Vector2.ZERO
var _start_hl := 0.0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_to_group("pw_hgrab")


func configure(lbl: String, opts: Array, current: Variant) -> PwSelector:
	label = lbl
	options = opts
	index = maxi(0, index_of(current))
	_hl.jump(index * STRIDE)
	custom_minimum_size = Vector2(cells_width(options.size()), _cells_top() + CELL + 30.0)
	queue_redraw()
	return self


func index_of(v: Variant) -> int:
	for i in options.size():
		if options[i].get("value") == v:
			return i
	return -1


func current_value() -> Variant:
	return options[index].get("value") if index < options.size() else null


static func cells_width(n: int) -> float:
	return CELL + STRIDE * maxf(0, n - 1)


static func cell_at(x: float, n: int) -> int:
	return clampi(int(floor(x / STRIDE)), 0, maxi(0, n - 1))


static func nearest_cell(highlight_x: float, n: int) -> int:
	return clampi(int(roundf(highlight_x / STRIDE)), 0, maxi(0, n - 1))


func highlight_x() -> float:
	return _hl.value


func displayed_index() -> int:
	return nearest_cell(_hl.value, options.size())


func set_index(i: int, emit: bool = false, animate: bool = true) -> void:
	i = clampi(i, 0, options.size() - 1)
	var changed := i != index
	index = i
	if animate and is_inside_tree():
		_hl.start(i * STRIDE, Tokens.MOTION_OVERLAY_S)
		set_process(true)
	else:
		_hl.jump(i * STRIDE)
	queue_redraw()
	if emit and changed:
		selected.emit(current_value())


func select_value(v: Variant, animate: bool = true) -> void:
	var i := index_of(v)
	if i >= 0:
		set_index(i, false, animate)


func _cells_top() -> float:
	return 36.0 if label != "" else 0.0


func _process(delta: float) -> void:
	_hl.step(delta)
	queue_redraw()
	if not _hl.running:
		set_process(false)


func _gui_input(event: InputEvent) -> void:
	var p := PointerInput.from_event(event)
	if p.kind == PointerInput.Kind.NONE or disabled or options.is_empty():
		return
	var local_x := p.pos.x
	match p.kind:
		PointerInput.Kind.DOWN:
			_pressed = true
			dragging = false
			_start = p.pos
			_start_hl = _hl.value
			accept_event()
		PointerInput.Kind.MOVE:
			if not _pressed:
				return
			var d := p.pos - _start
			if not dragging:
				if absf(d.x) > DRAG_PX and absf(d.x) >= absf(d.y):
					dragging = true
				elif d.length() >= INTENT_PX:
					_pressed = false
					return
				else:
					return
			_hl.jump(clampf(_start_hl + d.x, 0.0, (options.size() - 1) * STRIDE))
			queue_redraw()
			accept_event()
		PointerInput.Kind.UP:
			if not _pressed:
				return
			_pressed = false
			if dragging:
				dragging = false
				set_index(nearest_cell(_hl.value, options.size()), true)
			elif local_x >= 0.0 and local_x <= cells_width(options.size()) and p.pos.y >= _cells_top():
				set_index(cell_at(local_x, options.size()), true)


func _draw() -> void:
	UiDraw.begin(self)
	var ci := get_canvas_item()
	var a := 0.5 if disabled else 1.0
	if label != "":
		UiDraw.text(self, Tokens.inter(500), Vector2(0, 24), label, 24, Color(1, 1, 1, a))
	var top := _cells_top()
	for i in options.size():
		var r := Rect2(i * STRIDE, top, CELL, CELL)
		UiDraw.rect(ci, r, Color(Tokens.PANEL, a))
		UiDraw.frame(ci, r, Color(1, 1, 1, a), Tokens.BORDER)
		_draw_option(options[i], r, Color(1, 1, 1, a))
	var hl := Rect2(_hl.value, top, CELL, CELL)
	UiDraw.rect(ci, hl, Color(Tokens.SELECTED_FILL, a))
	UiDraw.frame(ci, hl, Color(Tokens.ACCENT, a), Tokens.BORDER)
	var shown := displayed_index()
	if shown < options.size():
		_draw_option(options[shown], hl, Color(Tokens.ACCENT, a))
		var hint := str(options[shown].get("hint", ""))
		if hint != "":
			UiDraw.text(self, Tokens.inter(400), Vector2(0, top + CELL + 24.0), hint, 16, Color(Tokens.ZINC_400, a), HORIZONTAL_ALIGNMENT_LEFT, maxf(size.x, 400.0))


func _draw_option(opt: Dictionary, r: Rect2, col: Color) -> void:
	var icon := str(opt.get("icon", ""))
	if icon != "":
		var tex := Icons.texture(icon, ICON_PX)
		if tex != null:
			draw_texture(tex, (r.get_center() - Vector2(ICON_PX, ICON_PX) * 0.5).round(), col)
		return
	var text := str(opt.get("text", ""))
	var f := Tokens.inter(600)
	var fs := 24
	var w := f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	UiDraw.text(self, f, Vector2(r.get_center().x - w * 0.5, r.get_center().y + (f.get_ascent(fs) - f.get_descent(fs)) * 0.5).round(), text, fs, col)
