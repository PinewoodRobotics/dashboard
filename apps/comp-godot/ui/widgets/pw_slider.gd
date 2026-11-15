class_name PwSlider
extends Control

## CustomSlider.tsx: label, optional value line, a 48 px track with a 4 px
## border, optional hint. A press on the track turns it green (100 ms fade)
## and the value then moves by dx / track width * range from the value at the
## press, from the first pixel, so a tap changes nothing. `reversed` fills from
## the right and inverts the drag. Step snaps from min, then snap points to the
## nearest one; with snap points the fill width eases over 150 ms.

signal value_changed(value: float)
signal drag_started
signal drag_ended

const DOT := 6.0
const GAP := 8.0
const VALUE_PX := 18
const HINT_PX := 16

var label := ""
## Shown between label and track; "{v}" is replaced by the formatted value.
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
## True while pressed (the web's isDragging).
var dragging := false

var _start := Vector2.ZERO
var _start_value := 0.0
var _fill := UiAnim.new(0.0)
var _track_bg := ColorAnim.new(Tokens.PANEL)
var _border := ColorAnim.new(Tokens.TEXT)
var _fill_col := ColorAnim.new(Tokens.TEXT)
var _dots: Array[Dictionary] = []


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_to_group("pw_hgrab")


func _ready() -> void:
	_fill.jump(fraction())
	_sync_dots(false)
	_update_min_size()


func configure(opts: Dictionary) -> PwSlider:
	for k: String in opts:
		set(k, opts[k])
	value = quantize(value, min_value, max_value, step, snap_points)
	_fill.jump(fraction())
	_sync_dots(false)
	_update_min_size()
	queue_redraw()
	return self


## Every text line of CustomSlider has the page's 1.5 line height
## (leading-normal on the label and value, inherited by the hint).
static func _line_h(_weight: int, px: int) -> float:
	return px * 1.5


## Baseline of `px` text in its line box starting at `top` (glyphs centered).
static func _baseline(weight: int, px: int, top: float) -> float:
	var f := Tokens.inter(weight)
	return roundf(top + (_line_h(weight, px) - f.get_ascent(px) - f.get_descent(px)) * 0.5 + f.get_ascent(px))


func _update_min_size() -> void:
	var hint_n := _hint_lines().size()
	var h := _bar_top() + bar_height + (GAP + hint_n * _line_h(400, HINT_PX) if hint_n > 0 else 0.0)
	if not is_equal_approx(custom_minimum_size.y, h):
		custom_minimum_size.y = h


func _value_lines() -> PackedStringArray:
	if value_label == "":
		return PackedStringArray()
	return PwText.wrap_lines(_interpolate(value_label), Tokens.inter(500), VALUE_PX, size.x)


func _hint_lines() -> PackedStringArray:
	if hints.is_empty():
		return PackedStringArray()
	return PwText.wrap_lines(_interpolate(hint_for(value, hints)), Tokens.inter(400), HINT_PX, size.x)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_update_min_size()


func _value_top() -> float:
	return _line_h(500, label_size) + GAP if label != "" else 0.0


func _bar_top() -> float:
	var n := _value_lines().size()
	return _value_top() + (n * _line_h(500, VALUE_PX) + GAP if n > 0 else 0.0)


func bar_rect() -> Rect2:
	return Rect2(0, _bar_top(), size.x, bar_height)


## The track is `touch-action: none` in the web: a stroke that starts on it
## never scrolls the panel.
func touch_action_none(local_pos: Vector2) -> bool:
	return bar_rect().has_point(local_pos)


## The web divides by the track's border-box width (getBoundingClientRect).
func track_width() -> float:
	return maxf(1.0, size.x)


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
	return out


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
		return ("%." + str(decimals) + "f") % value
	return str(value)


func _interpolate(s: String) -> String:
	return s.replace("{v}", formatted())


func set_value(v: float, emit: bool = false) -> void:
	var q := quantize(v, min_value, max_value, step, snap_points)
	if is_equal_approx(q, value):
		return
	value = q
	if snap_points.is_empty() or not is_inside_tree():
		_fill.jump(fraction())
	else:
		_fill.retarget(fraction(), Tokens.MOTION_SLIDER_FILL_S, Easing.css_ease_out)
	_sync_dots(true)
	_update_min_size()
	_kick()
	if emit:
		value_changed.emit(value)


func _dot_epsilon() -> float:
	return (max_value - min_value) * 0.005


func _dot_target(s: float) -> Dictionary:
	var t := fraction()
	var pt := value_fraction(s, min_value, max_value)
	var in_fill := pt > 1.0 - t if reversed else pt < t
	var col: Color
	if in_fill:
		col = Tokens.SELECTED_FILL if dragging else Tokens.PANEL
	else:
		col = Tokens.ACCENT if dragging else Tokens.TEXT
	return {"color": col, "alpha": 0.0 if absf(s - value) < _dot_epsilon() else 1.0}


func _sync_dots(animate: bool) -> void:
	if _dots.size() != snap_points.size():
		_dots.clear()
		for s: float in snap_points:
			_dots.append({"color": ColorAnim.new(), "alpha": UiAnim.new(1.0)})
		animate = false
	for i in snap_points.size():
		var want := _dot_target(snap_points[i])
		var d := _dots[i]
		if animate and is_inside_tree():
			(d["color"] as ColorAnim).set_target(want["color"], Tokens.MOTION_PRESS_S)
			(d["alpha"] as UiAnim).retarget(want["alpha"], 0.05, Easing.css, 0.05)
		else:
			(d["color"] as ColorAnim).jump(want["color"])
			(d["alpha"] as UiAnim).jump(want["alpha"])


func _set_pressed(on: bool) -> void:
	dragging = on
	var accent := Tokens.ACCENT if on else Tokens.TEXT
	_track_bg.set_target(Tokens.SELECTED_FILL if on else Tokens.PANEL, Tokens.MOTION_PRESS_S, Easing.tailwind)
	_border.set_target(accent, Tokens.MOTION_PRESS_S, Easing.tailwind)
	_fill_col.set_target(accent, Tokens.MOTION_PRESS_S)
	_sync_dots(true)
	_kick()


func _kick() -> void:
	set_process(true)
	queue_redraw()


func _process(delta: float) -> void:
	var busy := _fill.running
	_fill.step(delta)
	for c: ColorAnim in [_track_bg, _border, _fill_col]:
		busy = c.running() or busy
		c.step(delta)
	for d: Dictionary in _dots:
		busy = (d["color"] as ColorAnim).running() or (d["alpha"] as UiAnim).running or busy
		(d["color"] as ColorAnim).step(delta)
		(d["alpha"] as UiAnim).step(delta)
	queue_redraw()
	if not busy:
		set_process(false)


func _gui_input(event: InputEvent) -> void:
	var p := PointerInput.from_event(event)
	if p.kind == PointerInput.Kind.NONE or disabled:
		return
	match p.kind:
		PointerInput.Kind.DOWN:
			if not bar_rect().has_point(p.pos):
				return
			_start = p.pos
			_start_value = value
			_set_pressed(true)
			drag_started.emit()
			accept_event()
		PointerInput.Kind.MOVE:
			if not dragging:
				return
			set_value(drag_value(_start_value, p.pos.x - _start.x, track_width(), min_value, max_value, step, snap_points, reversed), true)
			accept_event()
		PointerInput.Kind.UP:
			_end_drag()


func _end_drag() -> void:
	if dragging:
		_set_pressed(false)
		drag_ended.emit()


func _draw() -> void:
	UiDraw.begin(self)
	var ci := get_canvas_item()
	var a := 0.5 if disabled else 1.0
	if label != "":
		UiDraw.text(self, Tokens.inter(500), Vector2(0, _baseline(500, label_size, 0.0)), label, label_size, Color(1, 1, 1, a), HORIZONTAL_ALIGNMENT_LEFT, size.x)
	var lines := _value_lines()
	for i in lines.size():
		UiDraw.text(self, Tokens.inter(500), Vector2(0, _baseline(500, VALUE_PX, _value_top() + i * _line_h(500, VALUE_PX))), lines[i], VALUE_PX, Color(1, 1, 1, 0.7 * a))
	var bar := bar_rect()
	var inner := bar.grow(-Tokens.BORDER)
	var fw := inner.size.x * _fill.value
	var fill_rect := Rect2(inner.end.x - fw, inner.position.y, fw, inner.size.y) if reversed else Rect2(inner.position, Vector2(fw, inner.size.y))
	var rest_rect := Rect2(inner.position, Vector2(inner.size.x - fw, inner.size.y)) if reversed else Rect2(inner.position.x + fw, inner.position.y, inner.size.x - fw, inner.size.y)
	# Track, fill and border tile without overlapping, so the per-shape 50% of a
	# disabled slider composites like the web's opacity-50 on the whole group.
	UiDraw.rect(ci, rest_rect, _faded(_track_bg.value(), a))
	UiDraw.rect(ci, fill_rect, _faded(_fill_col.value(), a))
	var eps := _dot_epsilon()
	for i in snap_points.size():
		var s: float = snap_points[i]
		if absf(s - min_value) < eps or absf(s - max_value) < eps:
			continue
		var d := _dots[i]
		var x := inner.position.x + inner.size.x * value_fraction(s, min_value, max_value)
		var col := _faded((d["color"] as ColorAnim).value(), a * (d["alpha"] as UiAnim).value)
		UiDraw.circle(ci, Vector2(x, inner.get_center().y), DOT * 0.5, col)
	UiDraw.frame(ci, bar, _faded(_border.value(), a), Tokens.BORDER)
	var hint := _hint_lines()
	for i in hint.size():
		UiDraw.text(self, Tokens.inter(400), Vector2(0, _baseline(400, HINT_PX, bar.end.y + GAP + i * _line_h(400, HINT_PX))), hint[i], HINT_PX, Color(1, 1, 1, a))


static func _faded(c: Color, a: float) -> Color:
	return Color(c, c.a * a)
