class_name InfoBox
extends VBoxContainer

## NetworkTablesPreview.tsx: a 12 px semibold caption tracked 0.2em over a box
## with a 2 px white/10 border and 2 px dividers; each row is a 12 px zinc-500
## label over a 16 px monospace zinc-100 value that breaks anywhere.

var values := {}
var _rows: VBoxContainer


func _init(caption: String, rows: Array) -> void:
	add_theme_constant_override("separation", 8)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var head := PwText.new(caption, 12, 600, Tokens.TEXT, 16.0)
	head.configure({"wrap": PwText.Wrap.NONE, "tracking": 2.4})
	add_child(head)
	var box := PanelContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := PwBox.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.border_color = Tokens.HAIRLINE
	sb.set_border_width_all(2)
	sb.set_content_margin_all(2)
	box.add_theme_stylebox_override("panel", sb)
	_rows = UiKit.vbox(0)
	for i in rows.size():
		if i > 0:
			_rows.add_child(PwRect.new(Tokens.HAIRLINE))
			(_rows.get_child(-1) as Control).custom_minimum_size.y = 2
		var key := str(rows[i][0])
		var col := UiKit.vbox(4)
		col.add_child(PwText.new(str(rows[i][1]), 12, 400, Tokens.ZINC_500, 16.0))
		var v := PwText.new("", 16, 400, Color("#f4f4f5"), 24.0)
		v.font = Tokens.mono()
		v.wrap = PwText.Wrap.ANYWHERE
		v.name = "Value_" + key
		col.add_child(v)
		values[key] = v
		_rows.add_child(UiKit.margin(col, 20, 16, 20, 16))
	box.add_child(_rows)
	add_child(box)


func set_value(key: String, text: String) -> void:
	(values[key] as PwText).text = text


func value(key: String) -> String:
	return (values[key] as PwText).text
