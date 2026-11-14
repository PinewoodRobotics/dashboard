class_name DebugOverlay
extends CanvasLayer

## F3 overlay: NT client diagnostics and a live table of every cached topic.

const REFRESH_S := 0.2

var nt: NtService
var _header: Label
var _tree: Tree
var _items := {}
var _accum := 0.0


func _init(service: NtService) -> void:
	nt = service
	layer = 100


func _ready() -> void:
	var mono := SystemFont.new()
	mono.font_names = PackedStringArray(["Menlo", "Consolas", "DejaVu Sans Mono", "monospace"])

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.offset_left = 24
	panel.offset_top = 24
	panel.offset_right = -24
	panel.offset_bottom = -24
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0, 0, 0, 0.96)
	bg.border_color = Color("#70cd35")
	bg.set_border_width_all(2)
	bg.set_content_margin_all(16)
	panel.add_theme_stylebox_override("panel", bg)
	add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	panel.add_child(box)

	_header = Label.new()
	_header.add_theme_font_override("font", mono)
	_header.add_theme_font_size_override("font_size", 20)
	_header.add_theme_color_override("font_color", Color.WHITE)
	box.add_child(_header)

	_tree = Tree.new()
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.columns = 5
	_tree.column_titles_visible = true
	_tree.hide_root = true
	_tree.select_mode = Tree.SELECT_ROW
	_tree.add_theme_font_override("font", mono)
	_tree.add_theme_font_size_override("font_size", 16)
	_tree.add_theme_font_override("title_button_font", mono)
	_tree.add_theme_font_size_override("title_button_font_size", 16)
	for i in 5:
		_tree.set_column_title(i, ["Topic", "Type", "Value", "Age ms", "Updates"][i])
		_tree.set_column_title_alignment(i, HORIZONTAL_ALIGNMENT_LEFT)
		_tree.set_column_expand(i, i == 0 or i == 2)
	_tree.set_column_expand_ratio(0, 3)
	_tree.set_column_expand_ratio(2, 2)
	for i in [1, 3, 4]:
		_tree.set_column_custom_minimum_width(i, 120)
	_tree.create_item()
	box.add_child(_tree)
	_refresh()


func _process(delta: float) -> void:
	if not visible:
		return
	_accum += delta
	if _accum >= REFRESH_S:
		_accum = 0.0
		_refresh()


func toggle() -> void:
	visible = not visible
	if visible:
		_refresh()


static func format_value(v: Variant) -> String:
	match typeof(v):
		TYPE_NIL:
			return "-"
		TYPE_FLOAT:
			return "%.4f" % v
		TYPE_PACKED_BYTE_ARRAY:
			return "<%d bytes>" % v.size()
		TYPE_STRING:
			return '"%s"' % v
		TYPE_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_STRING_ARRAY:
			var s := str(v)
			return s if s.length() <= 80 else s.substr(0, 77) + "..."
	return str(v)


func _refresh() -> void:
	if nt == null:
		return
	var d := nt.diagnostics()
	var host_line := "%s  [%s]  protocol %s" % [d["url"], d["state"], d["protocol"] if d["protocol"] != "" else "-"]
	var sync_line := "rtt %s  offset %s us  server time %s us" % [
		"%.2f ms" % (d["rtt_us"] / 1000.0) if d["rtt_us"] >= 0 else "-", d["offset_us"], d["server_time_us"]]
	var count_line := "topics %d  values %.0f/s (%d total)  unknown-id %d  decode err %d  coerce err %d  connects %d  reconnects %d  watchdog %d/%d  deferred %d  last close: %s" % [
		d["cached_topics"], d["values_per_s"], d["values_total"], d["unknown_id_drops"], d["decode_errors"], d["coerce_errors"],
		d["connects"], d["reconnects"], d["connect_watchdog_fires"], d["liveness_fires"], d["deferred_packets"], d["last_close"] if d["last_close"] != "" else "-"]
	_header.text = "NT4  F3 to close\n%s\n%s\n%s" % [host_line, sync_line, count_line]

	var names := Array(nt.topic_names())
	if names.size() != _items.size():
		_rebuild(names)
	var now := Time.get_ticks_usec()
	for name: String in _items:
		var e := nt.entry(name)
		var item: TreeItem = _items[name]
		item.set_text(1, e["type"])
		item.set_text(2, format_value(e["value"]) if e["has_value"] else "-")
		item.set_text(3, str((now - e["local_ts"]) / 1000) if e["has_value"] else "-")
		item.set_text(4, str(e["updates"]))
		var c := Color.WHITE if nt.is_live(name) else Color(1, 1, 1, 0.45)
		for i in 5:
			item.set_custom_color(i, c)


func _rebuild(names: Array) -> void:
	names.sort()
	_tree.clear()
	_items.clear()
	var root := _tree.create_item()
	for name: String in names:
		var item := _tree.create_item(root)
		item.set_text(0, name)
		_items[name] = item
