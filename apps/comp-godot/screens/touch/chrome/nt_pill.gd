class_name NtPill
extends Control

## "NT Disconnected" pill (ConnectionLost.tsx), shown whenever NetworkTables
## is not connected: black at 85%, 1 px red-500/40 border, 4 px corners,
## 12/6 px padding, a 12 px red-500 dot, 8 px gap, 14/20 px Inter medium
## red-400 text with 0.025em tracking. Its owner places it (the web: bottom
## center of the window, 24 px up, over everything, never taking input).
## The reds are Tailwind 4's palette classes, unlike the #ef4444 the web
## hard-codes elsewhere (Tokens.ERROR).

const PAD := Vector2(12, 6)
const DOT := 12.0
const GAP := 8.0
const TEXT_PX := 14
const LINE_H := 20.0
const TRACKING := 0.025 * TEXT_PX
const TEXT := "NT Disconnected"
const RED_500 := Color("#fb2c36")
const RED_400 := Color("#ff6467")

var nt: NtService
var _font: Font
var _box := PwBox.new()


func _init() -> void:
	name = "NtPill"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = Tokens.text_font(500)
	_box.bg_color = Color(0, 0, 0, 0.85)
	_box.border_color = Color(RED_500, 0.4)
	_box.set_border_width_all(1)
	_box.set_corner_radius_all(4)
	size = Vector2(1 + PAD.x + DOT + GAP + text_width() + PAD.x + 1, 1 + PAD.y + LINE_H + PAD.y + 1)


func _ready() -> void:
	if nt == null:
		nt = get_node_or_null("/root/NT") as NtService
	_update()


func text_width() -> float:
	return _font.get_string_size(TEXT, HORIZONTAL_ALIGNMENT_LEFT, -1, TEXT_PX).x + TRACKING * TEXT.length()


func _process(_delta: float) -> void:
	_update()


func _update() -> void:
	var show := nt != null and not nt.is_ready()
	if show != visible:
		visible = show


func _draw() -> void:
	UiDraw.begin(self)
	draw_style_box(_box, Rect2(Vector2.ZERO, size))
	var cy := size.y * 0.5
	UiDraw.circle(get_canvas_item(), Vector2(1 + PAD.x + DOT * 0.5, cy), DOT * 0.5, RED_500)
	var asc := _font.get_ascent(TEXT_PX)
	var baseline := 1 + PAD.y + (LINE_H - (asc + _font.get_descent(TEXT_PX))) * 0.5 + asc
	UiDraw.text_tracked(self, _font, Vector2(1 + PAD.x + DOT + GAP, baseline), TEXT, TEXT_PX, RED_400, TRACKING)
