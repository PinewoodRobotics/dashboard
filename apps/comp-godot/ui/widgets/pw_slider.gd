class_name PwSlider
extends Control

## CustomSlider.tsx: a 48 px bar with a 4 px border and relative drag. The value
## moves by dx / track width * range from the value at drag start, so a plain
## tap changes nothing. A drag claims the pointer once it travels 8 px mostly
## horizontally (it wins over the drawer swipe); a mostly vertical drag is
## left to the overlay's swipe-down. `reversed` fills from the right and
## inverts the drag. Step snaps from min, then snap points to the nearest one.

signal value_changed(value: float)
signal drag_started
signal drag_ended

const INTENT_PX := 8.0
const DOT := 6.0

var label := ""
var value_label := ""
var min_value := 0.0
var max_value := 1.0
var step := 0.0
var snap_points: Array = []
var reversed := false
var decimals := -1
var format_value := Callable()
## [{"min": float, "text": String}]: the entry with the largest min <= value.
var hints: Array = []
var disabled := false:
	set(v):
		disabled = v
		if v:
			_end_drag()
		queue_redraw()
var label_size := 24
var bar_height := 48.0
var value := 0.0
var dragging := false

var _pressed := false
var _start := Vector2.ZERO
var _start_value := 0.0
var _fill := UiAnim.new(0.0)


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_to_group("pw_hgrab")


func _ready() -> void:
	_fill.jump(fraction())
	_update_min_size()


func configure(opts: Dictionary) -> PwSlider:
	for k: String in opts:
		set(k, opts[k])
	value = quantize(value, min_value, max_value, step, snap_points)
	_fill.jump(fraction())
	_update_min_size()
	queue_redraw()
	return self


func _update_min_size() -> void:
	custom_minimum_size.y = _bar_top() + bar_height + (_hint_h() if not hints.is_empty() else 0.0)


func _label_h() -> float:
	return 0.0 if label == "" and value_label == "" else label_size + 12.0


func _hint_h() -> float:
	return 30.0


func _bar_top() -> float:
	return _label_h()


func bar_rect() -> Rect2:
	return Rect2(0, _bar_top(), size.x, bar_height)


func track_width() -> float:
	return maxf(1.0, size.x - 2.0 * Tokens.BORDER)


func fraction() -> float:
	return value_fraction(value, min_value, max_value)


static func value_fraction(v: float, lo: float, hi: float) -> float:
	return clampf((v - lo) / (hi - lo), 0.0, 1.0) if hi > lo else 0.0


static func quantize(v: float, lo: float, hi: float, step_size: float, snaps: Array) -> float:
	var out := clampf(v, lo, hi)
	if step_size > 0.0:
		out = lo + roundf((out - lo) / step_size) * step_size
	if not snaps.is_empty():
		var best: float = snaps[0]
		for s: float in snaps:
			if absf(s - out) < absf(best - out):
				best = s
		out = best
	return clampf(out, lo, hi)


static func drag_value(start_value: float, dx: float, track_w: float, lo: float, hi: float, step_size: float, snaps: Array, is_reversed: bool) -> float:
	var sign := -1.0 if is_reversed else 1.0
	return quantize(start_value + sign * dx / maxf(track_w, 1.0) * (hi - lo), lo, hi, step_size, snaps)


static func hint_for(v: float, ranges: Array) -> String:
	var best := ""
	var best_min := -INF
	for r: Dictionary in ranges:
		var m := float(r.get("min", 0.0))
		if m <= v and m >= best_min:
			best_min = m
			best = str(r.get("text", ""))
	return best


func formatted() -> String:
	if format_value.is_valid():
		return str(format_value.call(value))
	if decimals >= 0:
		return String.num(value, decimals) if decimals > 0 else str(int(roundf(value)))
	return str(value)


func set_value(v: float, emit: bool = false) -> void:
	var q := quantize(v, min_value, max_value, step, snap_points)
	if is_equal_approx(q, value):
		return
	value = q
	if snap_points.is_empty() or not is_inside_tree():
		_fill.jump(fraction())
	else:
		_fill.start(fraction(), Tokens.MOTION_SLIDER_FILL_S, Easing.out_cubic)
	set_process(_fill.running)
	queue_redraw()
	if emit:
		value_changed.emit(value)


func _process(delta: float) -> void:
	_fill.step(delta)
	queue_redraw()
	if not _fill.running:
		set_process(false)


func _gui_input(event: InputEvent) -> void:
	var p := PointerInput.from_event(event)
	if p.kind == PointerInput.Kind.NONE or disabled:
		return
	match p.kind:
		PointerInput.Kind.DOWN:
			_pressed = true
			_start = p.pos
			_start_value = value
			accept_event()
		PointerInput.Kind.MOVE:
			if not _pressed:
				return
			var d := p.pos - _start
			if not dragging:
				if d.length() < INTENT_PX:
					return
				if absf(d.x) <= absf(d.y):
					_pressed = false
					return
				dragging = true
				drag_started.emit()
				queue_redraw()
			set_value(drag_value(_start_value, d.x, track_width(), min_value, max_value, step, snap_points, reversed), true)
			accept_event()
		PointerInput.Kind.UP:
			_end_drag()


func _end_drag() -> void:
	_pressed = false
	if dragging:
		dragging = false
		drag_ended.emit()
		queue_redraw()


func _draw() -> void:
	UiDraw.begin(self)
	var ci := get_canvas_item()
	var a := 0.5 if disabled else 1.0
	var accent := Tokens.ACCENT if dragging else Tokens.TEXT
	if _label_h() > 0.0:
		var f := Tokens.inter(500)
		var base := float(label_size)
		UiDraw.text(self, f, Vector2(0, base), label, label_size, Color(1, 1, 1, a))
		if value_label != "":
			var lw := f.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, label_size).x
			var vs := maxi(12, int(label_size * 0.75))
			UiDraw.text(self, Tokens.inter(400), Vector2(lw + 12.0, base), value_label.replace("{v}", formatted()), vs, Color(1, 1, 1, 0.7 * a), HORIZONTAL_ALIGNMENT_LEFT, size.x - lw - 12.0)
	var bar := bar_rect()
	var bg := Tokens.SELECTED_FILL if dragging else Tokens.PANEL
	UiDraw.rect(ci, bar, Color(bg, a))
	var inner := bar.grow(-Tokens.BORDER)
	var fw := inner.size.x * _fill.value
	var fill_rect := Rect2(inner.end.x - fw, inner.position.y, fw, inner.size.y) if reversed else Rect2(inner.position, Vector2(fw, inner.size.y))
	UiDraw.rect(ci, fill_rect, Color(accent, a))
	for s: float in snap_points:
		var fr := value_fraction(s, min_value, max_value)
		if fr <= 0.0 or fr >= 1.0 or is_equal_approx(s, value):
			continue
		var x := inner.end.x - inner.size.x * fr if reversed else inner.position.x + inner.size.x * fr
		var inside := fill_rect.has_point(Vector2(x, inner.get_center().y))
		UiDraw.circle(ci, Vector2(x, inner.get_center().y), DOT * 0.5, Color(Tokens.PANEL if inside else accent, a))
	UiDraw.frame(ci, bar, Color(accent, a), Tokens.BORDER)
	if not hints.is_empty():
		UiDraw.text(self, Tokens.inter(400), Vector2(0, bar.end.y + 24.0), hint_for(value, hints), 16, Color(Tokens.ZINC_400, a), HORIZONTAL_ALIGNMENT_LEFT, size.x)
