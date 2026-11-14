class_name ShiftIndicator
extends Control

## [aim icon][gap][NN][.dd] centered on HudLayout.SHIFT_CENTER, on the web
## baseline. The icon is a 200 px lucide icon centered on the block's center.

var icon_rect: TextureRect
var digits: SegmentText
var _icon_key := ""


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	position = Vector2.ZERO
	size = HudLayout.DESIGN
	icon_rect = TextureRect.new()
	icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon_rect.size = Vector2(HudLayout.ICON_PX, HudLayout.ICON_PX)
	icon_rect.stretch_mode = TextureRect.STRETCH_KEEP
	add_child(icon_rect)
	digits = SegmentText.new()
	digits.align = SegmentText.Align.LEFT
	digits.add_run(Tokens.mono(), Tokens.FONT_TIMER_LARGE, "00").add_run(Tokens.mono(), Tokens.FONT_TIMER_SMALL, ".00")
	add_child(digits)
	_layout()


func _layout() -> void:
	var w := HudLayout.ICON_PX + HudLayout.ICON_GAP + digits.text_width()
	var left := HudLayout.SHIFT_CENTER.x - w / 2.0
	icon_rect.position = Vector2(left, HudLayout.SHIFT_CENTER.y - HudLayout.ICON_PX / 2.0)
	var dx := left + HudLayout.ICON_PX + HudLayout.ICON_GAP
	digits.position = Vector2(dx, 0)
	digits.size = Vector2(digits.text_width(), HudLayout.DESIGN.y)
	digits.baseline = HudLayout.SHIFT_BASELINE


func set_aim(aim: MatchEnums.Aim) -> void:
	var spec: Dictionary = Tokens.AIM_ICONS[aim]
	var key := "%s|%s" % [spec["icon"], spec["color"]]
	if key == _icon_key:
		return
	_icon_key = key
	icon_rect.texture = Icons.texture(spec["icon"], HudLayout.ICON_PX, spec["color"])


func set_seconds(t: float, color: Color) -> void:
	var before := digits.text_width()
	digits.set_texts(TimeFormat.nn_dd(t))
	digits.set_text_color(color)
	if digits.text_width() != before:
		_layout()


func block_rect() -> Rect2:
	var r := Rect2(icon_rect.position, icon_rect.size)
	return r.merge(digits.line_rect())
