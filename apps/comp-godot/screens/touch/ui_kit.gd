class_name UiKit
extends RefCounted


static func label(text: String, size: int, weight: int = 400, color: Color = Tokens.TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", Tokens.inter(weight))
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


static func wrapped(text: String, size: int, color: Color = Tokens.ZINC_400, weight: int = 400) -> Label:
	var l := label(text, size, weight, color)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


static func vbox(gap: int) -> VBoxContainer:
	var b := VBoxContainer.new()
	b.add_theme_constant_override("separation", gap)
	b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return b


static func hbox(gap: int) -> HBoxContainer:
	var b := HBoxContainer.new()
	b.add_theme_constant_override("separation", gap)
	b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return b


static func margin(child: Control, l: int, t: int, r: int, b: int) -> MarginContainer:
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", l)
	m.add_theme_constant_override("margin_top", t)
	m.add_theme_constant_override("margin_right", r)
	m.add_theme_constant_override("margin_bottom", b)
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	m.add_child(child)
	return m


static func vscroll() -> PwScroll:
	return PwScroll.new(true)


static func hscroll() -> PwScroll:
	return PwScroll.new(false)


static func full(c: Control) -> Control:
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return c


## A 420 px settings column (SettingsColumn.tsx): 32 px padding, 24 px title, 28 px gap.
static func column(title: String, border_right: bool = true, pad: int = 32, gap: int = 28) -> Dictionary:
	var panel := PanelContainer.new()
	var sb := PwBox.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.border_color = Tokens.HAIRLINE
	sb.border_width_right = 2 if border_right else 0
	sb.set_content_margin_all(pad)
	panel.add_theme_stylebox_override("panel", sb)
	panel.custom_minimum_size.x = 420
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var box := vbox(gap)
	box.add_child(label(title, 24, 600))
	panel.add_child(box)
	return {"panel": panel, "box": box}
