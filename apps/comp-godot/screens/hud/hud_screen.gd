class_name HudScreen
extends Control

## Match HUD at the 1920x1080 design size (apps/comp app/hud): header bar with
## the match timer, shift indicator with the aim-mode icon, buffer line, minimap,
## connection banner and lane-alignment toast. Pulls everything from Match each
## frame; nothing here talks to NT.

var match_service: MatchService
var header: PwRect
var timer: SegmentText
var shift: ShiftIndicator
var buffer_line: SegmentText
var minimap: MinimapView
var banner: ConnectionBanner
var toast: LaneToastView
var auto_label: AutoLabel
var start_chip: StartChip
var autos: AutosService
var _toast_count := -1


## Pre-match auto name over the top of the minimap; "Preview" with the
## playback time while the touchscreen preview is mirrored.
class AutoLabel:
	extends PanelContainer
	var icon := PwIcon.new("route", 30, Tokens.ACCENT)
	var kind := UiKit.label("", 26, 600, Tokens.ACCENT)
	var title := UiKit.label("", 30, 600)
	var time := UiKit.label("", 26, 500, Tokens.ZINC_300)

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		var sb := PwBox.new()
		sb.bg_color = Color(0, 0, 0, 0.72)
		sb.set_corner_radius_all(12)
		sb.content_margin_left = 18
		sb.content_margin_right = 20
		sb.content_margin_top = 6
		sb.content_margin_bottom = 6
		add_theme_stylebox_override("panel", sb)
		var row := UiKit.hbox(12)
		row.add_child(icon)
		row.add_child(kind)
		row.add_child(title)
		time.add_theme_font_override("font", Tokens.inter_tabular(500))
		row.add_child(time)
		add_child(row)

	func show_auto(display: String, mirror: bool, t: float, has_preview: bool = true) -> void:
		kind.text = "PREVIEW" if mirror else "AUTO"
		title.text = display
		time.text = "%05.2f s" % t if mirror else ("no preview" if not has_preview else "")
		time.visible = time.text != ""
		reset_size()
		position = Vector2(roundf(HudLayout.MINIMAP.get_center().x - size.x * 0.5), HudLayout.MINIMAP.position.y + 14.0)


class StartChip:
	extends PanelContainer
	const AMBER := Color("#fbbf24")
	var icon := PwIcon.new("crosshair", 24, AMBER)
	var text := UiKit.label("", 24, 600, AMBER)
	var level := -1
	var _sb := PwBox.new()

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		_sb.set_corner_radius_all(10)
		_sb.set_border_width_all(2)
		_sb.content_margin_left = 14
		_sb.content_margin_right = 16
		_sb.content_margin_top = 4
		_sb.content_margin_bottom = 4
		add_theme_stylebox_override("panel", _sb)
		var row := UiKit.hbox(10)
		row.add_child(icon)
		text.add_theme_font_override("font", Tokens.inter_tabular(600))
		row.add_child(text)
		add_child(row)

	func show_check(c: Dictionary, below: Control) -> void:
		level = c["level"]
		var col: Color = StartChip.color_for(level)
		_sb.bg_color = Color(0, 0, 0, 0.72)
		_sb.border_color = Color(col, 0.7)
		icon.color = col
		icon.icon_name = "circle-check" if level == StartPoseCheck.Level.OK else "crosshair"
		text.add_theme_color_override("font_color", col)
		text.text = StartPoseCheck.text(c)
		reset_size()
		position = Vector2(roundf(HudLayout.MINIMAP.get_center().x - size.x * 0.5), below.position.y + below.size.y + 8.0)

	static func color_for(l: int) -> Color:
		match l:
			StartPoseCheck.Level.OK:
				return Tokens.ACCENT
			StartPoseCheck.Level.OFF:
				return AMBER
		return Tokens.ZINC_400


func _ready() -> void:
	if match_service == null:
		match_service = get_node_or_null("/root/Match") as MatchService
	if autos == null:
		autos = get_node_or_null("/root/Autos") as AutosService
	theme = ThemeBuilder.build()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
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

	header = PwRect.new()
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

	auto_label = AutoLabel.new()
	auto_label.name = "AutoLabel"
	auto_label.visible = false
	add_child(auto_label)
	start_chip = StartChip.new()
	start_chip.name = "StartChip"
	start_chip.visible = false
	add_child(start_chip)

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
	_refresh_auto_label()


func _refresh_auto_label() -> void:
	var hud: Dictionary = autos.hud if autos != null else {}
	var name_: String = hud.get("auto", "")
	auto_label.visible = name_ != ""
	if auto_label.visible:
		var mirror: bool = hud.get("mirror", false)
		auto_label.show_auto(autos.library.display_name(name_), mirror, autos.clock.t, autos.library.get_auto(name_) != null)
	var check: Dictionary = hud.get("start", {})
	start_chip.visible = auto_label.visible and not check.is_empty()
	if start_chip.visible:
		start_chip.show_check(check, auto_label)


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
		"auto_label": {"visible": auto_label.visible, "rect": _r(Rect2(auto_label.position, auto_label.size)),
			"text": "%s %s %s" % [auto_label.kind.text, auto_label.title.text, auto_label.time.text] if auto_label.visible else ""},
		"start_chip": {"visible": start_chip.visible, "rect": _r(Rect2(start_chip.position, start_chip.size)),
			"text": start_chip.text.text if start_chip.visible else "", "level": start_chip.level if start_chip.visible else -1},
		"minimap_auto": {"overlay": minimap.auto_overlay.visible, "key": minimap.auto_overlay.key, "mirroring": minimap.mirroring},
	}
	return out


static func _r(r: Rect2) -> Array:
	return [snappedf(r.position.x, 0.01), snappedf(r.position.y, 0.01), snappedf(r.size.x, 0.01), snappedf(r.size.y, 0.01)]
