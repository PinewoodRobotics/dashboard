class_name ConnectionBanner
extends Control

## Bottom-center status pill (ConnectionLost.tsx): black 85%, 1 px red-500/40
## border, 12 px red dot, 14 px medium red-400 text with wide tracking.

const PAD := Vector2(12, 6)
const DOT := 12.0
const GAP := 8.0
const TEXT_PX := 14
const LINE_H := 20.0
const TRACKING := 0.025 * TEXT_PX

const TEXTS := {
	MatchModel.Banner.DISCONNECTED: "NT Disconnected",
	MatchModel.Banner.NO_DATA: "No Robot Data",
	MatchModel.Banner.STALE: "Robot Data Stale",
}

var kind := MatchModel.Banner.NONE
var _font: Font
var _box := PwBox.new()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = Tokens.inter(500)
	_box.bg_color = Color(0, 0, 0, 0.85)
	_box.border_color = Color(Tokens.ERROR, 0.4)
	_box.set_border_width_all(1)
	_box.set_corner_radius_all(4)
	visible = false


func text() -> String:
	return TEXTS.get(kind, "")


func _text_width(s: String) -> float:
	var w := 0.0
	for ch in s:
		w += _font.get_string_size(ch, HORIZONTAL_ALIGNMENT_LEFT, -1, TEXT_PX).x + TRACKING
	return w - TRACKING


func set_kind(k: MatchModel.Banner) -> void:
	if k == kind:
		return
	kind = k
	visible = k != MatchModel.Banner.NONE
	if visible:
		var w := 1 + PAD.x + DOT + GAP + _text_width(text()) + PAD.x + 1
		var h := 1 + PAD.y + LINE_H + PAD.y + 1
		size = Vector2(ceilf(w), h)
		position = Vector2(roundf((HudLayout.DESIGN.x - size.x) / 2.0), HudLayout.DESIGN.y - HudLayout.BANNER_BOTTOM - h)
	queue_redraw()


func _draw() -> void:
	UiDraw.begin(self)
	if kind == MatchModel.Banner.NONE:
		return
	draw_style_box(_box, Rect2(Vector2.ZERO, size))
	var cy := size.y / 2.0
	UiDraw.circle(get_canvas_item(), Vector2(1 + PAD.x + DOT / 2.0, cy), DOT / 2.0, Tokens.ERROR)
	var x := 1 + PAD.x + DOT + GAP
	var baseline := cy - (_font.get_ascent(TEXT_PX) + _font.get_descent(TEXT_PX)) / 2.0 + _font.get_ascent(TEXT_PX)
	for ch in text():
		UiDraw.text(self, _font, Vector2(x, baseline), ch, TEXT_PX, Tokens.ERROR_TEXT)
		x += _font.get_string_size(ch, HORIZONTAL_ALIGNMENT_LEFT, -1, TEXT_PX).x + TRACKING
