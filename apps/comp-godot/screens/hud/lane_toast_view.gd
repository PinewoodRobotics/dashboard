class_name LaneToastView
extends Control

## Lane-alignment toast, top-left like the web Toaster: #0a0a0a card with a
## #2a2a2a border, text and icon green when ON and red when OFF. Slides in over
## 200 ms and fades out at the end of its 1.8 s life. Larger than the web's
## 13 px Sonner text so it reads from the driver station.

const TEXT_PX := 22
const ICON_PX := 28
const PAD := Vector2(20, 16)
const GAP := 12.0
const MIN_W := 356.0
const SLIDE_S := 0.2
const FADE_S := 0.25

var on := false
var _font: Font
var _box := PwBox.new()
var _icon: Texture2D


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = Tokens.inter(500)
	_box.bg_color = Tokens.TOAST_BG
	_box.border_color = Tokens.TOAST_BORDER
	_box.set_border_width_all(1)
	_box.set_corner_radius_all(8)
	_box.shadow_color = Color(0, 0, 0, 0.35)
	_box.shadow_size = 12
	visible = false


func text() -> String:
	return "Lane Alignment %s" % ("ON" if on else "OFF")


func color() -> Color:
	return Tokens.ACCENT if on else Tokens.ERROR


func show_state(value: bool) -> void:
	on = value
	_icon = Icons.texture(Tokens.LANE_ICON, ICON_PX)
	var tw := _font.get_string_size(text(), HORIZONTAL_ALIGNMENT_LEFT, -1, TEXT_PX).x
	size = Vector2(maxf(MIN_W, ceilf(PAD.x * 2 + ICON_PX + GAP + tw)), PAD.y * 2 + ICON_PX)
	queue_redraw()


## progress: 0..1 of the lifetime, < 0 hidden.
func set_progress(progress: float) -> void:
	visible = progress >= 0.0
	if not visible:
		return
	var life := LaneToast.DURATION_S
	var t := progress * life
	var slide := clampf(t / SLIDE_S, 0.0, 1.0)
	slide = 1.0 - pow(1.0 - slide, 3.0)
	position = Vector2(HudLayout.TOAST_OFFSET.x - (1.0 - slide) * (size.x + HudLayout.TOAST_OFFSET.x), HudLayout.TOAST_OFFSET.y)
	modulate.a = clampf((life - t) / FADE_S, 0.0, 1.0)


func _draw() -> void:
	UiDraw.begin(self)
	draw_style_box(_box, Rect2(Vector2.ZERO, size))
	if _icon != null:
		draw_texture(_icon, Vector2(PAD.x, PAD.y), color())
	var cy := size.y / 2.0
	var baseline := cy - (_font.get_ascent(TEXT_PX) + _font.get_descent(TEXT_PX)) / 2.0 + _font.get_ascent(TEXT_PX)
	UiDraw.text(self, _font, Vector2(PAD.x + ICON_PX + GAP, baseline), text(), TEXT_PX, color())
