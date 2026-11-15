class_name PwText
extends Control

## A block of text laid out like a CSS <p>: every line gets a line box of
## `line_height` px with the glyphs centered in it (half-leading above and
## below), so text placed by these boxes lands where the browser puts it.
## line_height 0 is the inherited 1.5 of the page, NORMAL the font's own
## (leading-[normal]). Wraps at word boundaries (or anywhere, break-all),
## optionally clamped, truncated with an ellipsis or letter-spaced. Spans
## ({"text", "font"}) mix weights in one paragraph.

enum Wrap { NONE, WORD, ANYWHERE }

const NORMAL := -1.0

var text := "":
	set(v):
		if v != text:
			text = v
			_reshape()
var color := Color.WHITE:
	set(v):
		if v != color:
			color = v
			queue_redraw()
var px := 16
var weight := 400
var font: Font = null
var line_height := 0.0
var wrap := Wrap.WORD
var align := HORIZONTAL_ALIGNMENT_LEFT
var max_lines := 0
var ellipsis := false
var tracking := 0.0
var spans: Array = []:
	set(v):
		spans = v
		_reshape()

var _para: TextParagraph
var _shaped_w := -2.0
var _lines := 0


func _init(s: String = "", size_px: int = 16, w: int = 400, col: Color = Color.WHITE, lh: float = 0.0) -> void:
	text = s
	px = size_px
	weight = w
	color = col
	line_height = lh
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func configure(opts: Dictionary) -> PwText:
	for k: String in opts:
		set(k, opts[k])
	_reshape()
	return self


func primary_font() -> Font:
	return font if font != null else Tokens.inter(weight)


func line_px() -> float:
	if line_height == NORMAL:
		var f := primary_font()
		return f.get_ascent(px) + f.get_descent(px)
	return line_height if line_height > 0.0 else px * 1.5


## Baseline of the first line below the block's top.
func first_baseline() -> float:
	var f := primary_font()
	return (line_px() - f.get_ascent(px) - f.get_descent(px)) * 0.5 + f.get_ascent(px)


func line_count() -> int:
	_ensure_shaped()
	return _lines


func _wraps() -> bool:
	return wrap != Wrap.NONE and not ellipsis


func _reshape() -> void:
	_shaped_w = -2.0
	update_minimum_size()
	queue_redraw()


func _ensure_shaped() -> void:
	var w := size.x if _wraps() or ellipsis else -1.0
	if _para != null and is_equal_approx(w, _shaped_w):
		return
	_shaped_w = w
	_para = TextParagraph.new()
	var parts: Array = spans if not spans.is_empty() else [{"text": text}]
	for s: Dictionary in parts:
		_para.add_string(str(s.get("text", "")), s.get("font", primary_font()) as Font, px)
	if _wraps():
		_para.width = maxf(w, 1.0)
		_para.break_flags = TextServer.BREAK_MANDATORY | (TextServer.BREAK_GRAPHEME_BOUND if wrap == Wrap.ANYWHERE else TextServer.BREAK_WORD_BOUND | TextServer.BREAK_ADAPTIVE)
	else:
		_para.break_flags = TextServer.BREAK_MANDATORY
		if ellipsis:
			_para.width = maxf(w, 1.0)
			_para.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	if max_lines > 0:
		_para.max_lines_visible = max_lines
		if _wraps():
			_para.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var n := _para.get_line_count()
	_lines = mini(n, max_lines) if max_lines > 0 else n


func _natural_width() -> float:
	var f := primary_font()
	if not spans.is_empty():
		var w := 0.0
		for s: Dictionary in spans:
			w += (s.get("font", f) as Font).get_string_size(str(s.get("text", "")), HORIZONTAL_ALIGNMENT_LEFT, -1, px).x
		return w
	var widest := 0.0
	for line in text.split("\n"):
		widest = maxf(widest, f.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x + tracking * line.length())
	return widest


func _get_minimum_size() -> Vector2:
	if text == "" and spans.is_empty():
		return Vector2.ZERO
	_ensure_shaped()
	var w := 0.0 if _wraps() or ellipsis else ceilf(_natural_width())
	return Vector2(w, maxi(_lines, 1) * line_px())


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and (_wraps() or ellipsis):
		var before := _lines
		_ensure_shaped()
		if _lines != before:
			update_minimum_size()
		queue_redraw()


func _draw() -> void:
	UiDraw.begin(self)
	if (text == "" and spans.is_empty()) or color.a <= 0.0:
		return
	_ensure_shaped()
	var f := primary_font()
	var lh := line_px()
	var base := first_baseline()
	if tracking != 0.0 and spans.is_empty() and not _wraps():
		var lw := _natural_width()
		UiDraw.text_tracked(self, f, Vector2(_align_x(lw), roundf(base)), text, px, color, tracking)
		return
	var ci := UiDraw.text_item(self, f)
	for i in _lines:
		var y := roundf(i * lh + base)
		var lw := _para.get_line_width(i)
		_para.draw_line(ci, Vector2(_align_x(lw), y - _para.get_line_ascent(i)), i, color)


func _align_x(line_w: float) -> float:
	match align:
		HORIZONTAL_ALIGNMENT_CENTER:
			return roundf((size.x - line_w) * 0.5)
		HORIZONTAL_ALIGNMENT_RIGHT:
			return size.x - line_w
	return 0.0


## `s` broken into lines at word boundaries to fit `width` (no wrap if <= 0).
static func wrap_lines(s: String, f: Font, size_px: int, width: float) -> PackedStringArray:
	if s == "" or width <= 0.0:
		return PackedStringArray([s]) if s != "" else PackedStringArray()
	var p := TextParagraph.new()
	p.add_string(s, f, size_px)
	p.width = width
	p.break_flags = TextServer.BREAK_MANDATORY | TextServer.BREAK_WORD_BOUND | TextServer.BREAK_ADAPTIVE
	var out := PackedStringArray()
	for i in p.get_line_count():
		var r := p.get_line_range(i)
		out.append(s.substr(r.x, r.y - r.x).strip_edges())
	return out
