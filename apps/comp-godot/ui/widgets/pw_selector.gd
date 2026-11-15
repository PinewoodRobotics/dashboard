class_name PwSelector
extends Control

## CustomSelector.tsx: 80 px cells overlapping by 4 px (stride 76), each with
## its outline symbol in white. A green window (the selected cell's fill and
## border) slides over them and shows every cell's filled symbol in green
## through it, so a symbol turns green only where the window covers it. A press
## grabs the window at once and it follows the pointer's x from the first
## pixel; release snaps it to the nearest cell after more than 4 px of travel,
## else selects the cell under the release point, and it slides there in
## 200 ms. The hint below is the committed option's, or while pressed the one
## under the window.

signal selected(value: Variant)

const CELL := 80.0
const STRIDE := 76.0
const DRAG_PX := 4.0
const ICON_PX := 36
const LABEL_PX := 24
const HINT_PX := 16
const GAP := 8.0

var label := ""
## [{"value": Variant, "symbol": int, "filled": int, "hint": String}]; a
## Godot-only option may give "text" instead of symbols.
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
var _window := Control.new()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_to_group("pw_hgrab")
	_window.name = "Window"
	_window.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_window.clip_contents = true
	_window.z_index = Tokens.SF_TEXT_Z + 1
	_window.size = Vector2(CELL, CELL)
	_window.draw.connect(_draw_window)
	add_child(_window, false, Node.INTERNAL_MODE_FRONT)


func configure(lbl: String, opts: Array, current: Variant) -> PwSelector:
	label = lbl
	options = opts
	index = maxi(0, index_of(current))
	_hl.jump(index * STRIDE)
	custom_minimum_size = Vector2(cells_width(options.size()), _cells_top() + CELL + (GAP + _line_h(HINT_PX) if _has_hints() else 0.0))
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


static func _line_h(px: int) -> float:
	return px * 1.5


static func _baseline(weight: int, px: int, top: float) -> float:
	var f := Tokens.inter(weight)
	return roundf(top + (_line_h(px) - f.get_ascent(px) - f.get_descent(px)) * 0.5 + f.get_ascent(px))


## The cells are `touch-action: none` in the web: a stroke that starts on them
## never scrolls the panel.
func touch_action_none(local_pos: Vector2) -> bool:
	return Rect2(0, _cells_top(), cells_width(options.size()), CELL).has_point(local_pos)


func highlight_x() -> float:
	return _hl.value


func displayed_index() -> int:
	return nearest_cell(_hl.value, options.size()) if _pressed else index


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
	if i >= 0 and not _pressed and (i != index or (not _hl.running and not is_equal_approx(_hl.value, i * STRIDE))):
		set_index(i, false, animate)


func _cells_top() -> float:
	return _line_h(LABEL_PX) + GAP if label != "" else 0.0


func _has_hints() -> bool:
	for o: Dictionary in options:
		if str(o.get("hint", "")) != "":
			return true
	return false


func _process(delta: float) -> void:
	_hl.step(delta)
	queue_redraw()
	if not _hl.running:
		set_process(false)


func _gui_input(event: InputEvent) -> void:
	var p := PointerInput.from_event(event)
	if p.kind == PointerInput.Kind.NONE or disabled or options.is_empty():
		return
	match p.kind:
		PointerInput.Kind.DOWN:
			if p.pos.y < _cells_top() or p.pos.y > _cells_top() + CELL or p.pos.x > cells_width(options.size()):
				return
			_pressed = true
			dragging = false
			_start = p.pos
			_hl.jump(index * STRIDE)
			set_process(false)
			queue_redraw()
			accept_event()
		PointerInput.Kind.MOVE:
			if not _pressed:
				return
			var dx := p.pos.x - _start.x
			if absf(dx) > DRAG_PX:
				dragging = true
			_hl.jump(clampf(index * STRIDE + dx, 0.0, (options.size() - 1) * STRIDE))
			queue_redraw()
			accept_event()
		PointerInput.Kind.UP:
			if not _pressed:
				return
			_pressed = false
			var target := nearest_cell(_hl.value, options.size()) if dragging else cell_at(p.pos.x, options.size())
			dragging = false
			set_index(target, true)


func _draw() -> void:
	UiDraw.begin(self)
	var ci := get_canvas_item()
	var a := 0.5 if disabled else 1.0
	if label != "":
		UiDraw.text(self, Tokens.inter(500), Vector2(0, _baseline(500, LABEL_PX, 0.0)), label, LABEL_PX, Color(1, 1, 1, a))
	var top := _cells_top()
	for i in options.size():
		var r := Rect2(i * STRIDE, top, CELL, CELL)
		UiDraw.rect(ci, r, Color(Tokens.PANEL, a))
		UiDraw.frame(ci, r, Color(1, 1, 1, a), Tokens.BORDER)
		_draw_option(options[i], r, Color(1, 1, 1, a), false)
	_window.position = Vector2(_hl.value, top)
	_window.queue_redraw()
	var shown := displayed_index()
	if shown < options.size():
		var hint := str(options[shown].get("hint", ""))
		var f := Tokens.inter(400)
		UiDraw.text(self, f, Vector2(0, roundf(top + CELL + GAP + f.get_ascent(HINT_PX))), hint, HINT_PX, Color(1, 1, 1, a), HORIZONTAL_ALIGNMENT_LEFT, maxf(size.x, CELL))


## The green layer: fill, border and every option's filled symbol at its own
## cell, clipped to the window (the web's clip-path inset).
func _draw_window() -> void:
	var a := 0.5 if disabled else 1.0
	var ci := _window.get_canvas_item()
	var r := Rect2(Vector2.ZERO, _window.size)
	UiDraw.rect(ci, r, Color(Tokens.SELECTED_FILL, a))
	UiDraw.frame(ci, r, Color(Tokens.ACCENT, a), Tokens.BORDER)
	for i in options.size():
		_draw_option(options[i], Rect2(Vector2(i * STRIDE, _cells_top()) - _window.position, Vector2(CELL, CELL)), Color(Tokens.ACCENT, a), true)


func _draw_option(opt: Dictionary, r: Rect2, col: Color, in_window: bool) -> void:
	var symbol := int(opt.get("symbol", 0))
	if symbol > 0:
		if in_window:
			Sf.draw_into(_window.get_canvas_item(), int(opt.get("filled", symbol)), r.get_center(), ICON_PX, col)
		else:
			Sf.draw(self, symbol, r.get_center(), ICON_PX, col)
		return
	var text := str(opt.get("text", ""))
	var f := Tokens.inter(600)
	var fs := 24
	var pos := Vector2(r.get_center().x - f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x * 0.5, roundf(r.get_center().y + (f.get_ascent(fs) - f.get_descent(fs)) * 0.5))
	if in_window:
		f.draw_string(_window.get_canvas_item(), pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
	else:
		UiDraw.text(self, f, pos, text, fs, col)
