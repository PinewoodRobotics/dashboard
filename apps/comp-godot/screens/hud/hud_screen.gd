class_name HudScreen
extends Control

## Match HUD at the 1920x1080 design size (apps/comp app/hud): header bar with
## the match timer, shift indicator with the aim-mode icon, buffer line, minimap,
## connection banner and lane-alignment toast. Pulls everything from Match each
## frame; nothing here talks to NT.

var match_service: MatchService
var header: ColorRect
var timer: SegmentText
var shift: ShiftIndicator
var buffer_line: SegmentText
var minimap: MinimapView
var banner: ConnectionBanner
var toast: LaneToastView
var _toast_count := -1


func _ready() -> void:
	if match_service == null:
		match_service = get_node_or_null("/root/Match") as MatchService
	theme = ThemeBuilder.build()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Tokens.BG
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	minimap = MinimapView.new()
	minimap.name = "Minimap"
	minimap.position = HudLayout.MINIMAP.position
	minimap.size = HudLayout.MINIMAP.size
	add_child(minimap)
	minimap.use_frame(HudLayout.MINIMAP.size, HudLayout.MINIMAP_RADIUS, HudLayout.MINIMAP_SHADOW_BLUR, HudLayout.MINIMAP_SHADOW_SPREAD)

	shift = ShiftIndicator.new()
	shift.name = "ShiftIndicator"
	shift.visible = false
	add_child(shift)

	buffer_line = SegmentText.new()
	buffer_line.name = "BufferLine"
	buffer_line.align = SegmentText.Align.LEFT
	buffer_line.add_run(Tokens.mono(), Tokens.FONT_TIMER_SMALL, "00").add_run(Tokens.mono(), Tokens.FONT_TIMER_SMALL, ".00").add_run(Tokens.inter(), Tokens.FONT_TIMER_SMALL, " with buffer")
	buffer_line.position = Vector2(HudLayout.BUFFER_POS.x, 0)
	buffer_line.size = Vector2(HudLayout.DESIGN.x - HudLayout.BUFFER_POS.x, HudLayout.DESIGN.y)
	buffer_line.baseline = HudLayout.BUFFER_POS.y + buffer_line.ascent()
	buffer_line.visible = false
	add_child(buffer_line)

	header = ColorRect.new()
	header.name = "Header"
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.position = HudLayout.HEADER.position
	header.size = HudLayout.HEADER.size
	header.visible = false
	add_child(header)

	timer = SegmentText.new()
	timer.name = "MainTimer"
	timer.add_run(Tokens.mono(), Tokens.FONT_TIMER_LARGE, "00:00").add_run(Tokens.mono(), Tokens.FONT_TIMER_SMALL, ".00")
	timer.position = HudLayout.TIMER_BOX.position
	timer.size = HudLayout.TIMER_BOX.size
	add_child(timer)
	timer.center_baseline()

	toast = LaneToastView.new()
	toast.name = "LaneToast"
	add_child(toast)

	banner = ConnectionBanner.new()
	banner.name = "Banner"
	add_child(banner)

	refresh()


func _process(_delta: float) -> void:
	refresh()


func refresh() -> void:
	if match_service == null:
		return
	var m := match_service.model
	var now := match_service.now_us()
	header.visible = Tokens.HEADER_COLORS.has(m.header)
	if header.visible:
		header.color = Tokens.HEADER_COLORS[m.header]

	var text_color := Tokens.TEXT if m.link_ok() else Tokens.TEXT_DIM
	timer.set_texts(TimeFormat.mm_ss_cc(m.total_display(now)))
	timer.set_text_color(text_color)

	shift.visible = m.show_shift_indicator
	var buffer: Variant = null
	if shift.visible:
		var sd := m.shift_display(now)
		shift.set_aim(m.aim)
		shift.set_seconds(sd["main"], text_color)
		buffer = sd["buffer"]
	buffer_line.visible = buffer != null
	if buffer != null:
		var parts := TimeFormat.nn_dd(buffer)
		buffer_line.set_texts(PackedStringArray([parts[0], parts[1], " with buffer"]))
		buffer_line.set_text_color(text_color)

	banner.set_kind(m.banner())

	if m.toast.fire_count != _toast_count:
		_toast_count = m.toast.fire_count
		if m.toast.fire_count > 0:
			toast.show_state(m.toast.visible_on)
	toast.set_progress(m.toast.progress(now))


func displayed_total() -> String:
	return "".join(timer.texts)


func layout_report() -> Dictionary:
	var out := {
		"header": {"visible": header.visible, "rect": _r(Rect2(header.position, header.size)), "color": header.color.to_html(false)},
		"timer": {"line": _r(timer.line_rect()), "box": _r(Rect2(timer.position, timer.size)), "sizes": Array(timer.sizes), "text": displayed_total(), "color": timer.color.to_html(true)},
		"shift": {"visible": shift.visible, "block": _r(shift.block_rect()), "icon": _r(Rect2(shift.icon_rect.position, shift.icon_rect.size)), "digits": _r(shift.digits.line_rect()), "sizes": Array(shift.digits.sizes), "text": "".join(shift.digits.texts), "baseline": shift.digits.baseline},
		"buffer": {"visible": buffer_line.visible, "line": _r(buffer_line.line_rect()), "text": "".join(buffer_line.texts)},
		"minimap": {"rect": _r(Rect2(minimap.position, minimap.size))},
		"banner": {"visible": banner.visible, "rect": _r(Rect2(banner.position, banner.size)), "text": banner.text()},
		"toast": {"visible": toast.visible, "rect": _r(Rect2(toast.position, toast.size)), "text": toast.text() if toast.visible else ""},
	}
	return out


static func _r(r: Rect2) -> Array:
	return [snappedf(r.position.x, 0.01), snappedf(r.position.y, 0.01), snappedf(r.size.x, 0.01), snappedf(r.size.y, 0.01)]
