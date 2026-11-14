class_name SegmentText
extends Control

## Inline runs of different fonts and sizes sharing one baseline, like CSS
## spans with line-height normal: the line box is as tall as the largest
## run's ascent + descent. Drawn directly; redraws only when the text changes.

enum Align { LEFT, CENTER }

var fonts: Array[Font] = []
var sizes: PackedInt32Array = []
var texts: PackedStringArray = []
var color := Color.WHITE
var align := Align.CENTER
var baseline := 0.0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func add_run(font: Font, px: int, text: String = "") -> SegmentText:
	fonts.append(font)
	sizes.append(px)
	texts.append(text)
	return self


func set_texts(values: PackedStringArray) -> void:
	if values != texts:
		texts = values
		queue_redraw()


func set_text_color(c: Color) -> void:
	if c != color:
		color = c
		queue_redraw()


func ascent() -> float:
	var a := 0.0
	for i in fonts.size():
		a = maxf(a, fonts[i].get_ascent(sizes[i]))
	return a


func descent() -> float:
	var d := 0.0
	for i in fonts.size():
		d = maxf(d, fonts[i].get_descent(sizes[i]))
	return d


func line_height() -> float:
	return ascent() + descent()


func run_width(i: int) -> float:
	return fonts[i].get_string_size(texts[i], HORIZONTAL_ALIGNMENT_LEFT, -1, sizes[i]).x


func text_width() -> float:
	var w := 0.0
	for i in fonts.size():
		w += run_width(i)
	return w


func start_x() -> float:
	return (size.x - text_width()) * 0.5 if align == Align.CENTER else 0.0


func center_baseline() -> void:
	baseline = (size.y - line_height()) * 0.5 + ascent()
	queue_redraw()


func _draw() -> void:
	UiDraw.begin(self)
	var x := start_x()
	for i in fonts.size():
		UiDraw.text(self, fonts[i], Vector2(x, baseline), texts[i], sizes[i], color)
		x += run_width(i)


func line_rect() -> Rect2:
	var top := baseline - ascent()
	return Rect2(global_position + Vector2(start_x(), top), Vector2(text_width(), line_height()))
