class_name SettingsTab
extends Control

## Connection Settings (TouchscreenSettingsPanel.tsx without the Autobahn
## column). Drafts are validated like useTouchscreenSettingsForm.ts: Save is
## enabled only when the form is valid and differs from the saved settings,
## Reset writes the schema defaults, and every save goes to the shared file.
## The header shows the NetworkTables state and Reconnect restarts the client.

const TIMEOUT_HINTS := [{"min": 0.0, "text": "Closes a stuck connection after this long"}]
const COLUMN_W := {"Robot": 380, "Topics": 420, "Connection": 380, "NT Preview": 572}

var settings: SettingsService
var nt: NtService
var drafts := {}
var form := {}
var host: PwTextInput
var port: PwTextInput
var table: PwTextInput
var entry: PwTextInput
var timeout: PwSlider
var save: PwButton
var reset: PwButton
var reconnect: PwButton
var status_dot: PwRect
var status_label: Label
var save_error: Label
var preview_values := {}
var diag: Label
var _diag_t := 0.0


func _ready() -> void:
	if settings == null:
		settings = get_node_or_null("/root/Settings") as SettingsService
	if nt == null:
		nt = get_node_or_null("/root/NT") as NtService
	var root := UiKit.vbox(0)

	var header := UiKit.hbox(16)
	var title := UiKit.label("Connection Settings", 28, 600)
	header.add_child(title)
	status_dot = PwRect.new()
	status_dot.custom_minimum_size = Vector2(14, 14)
	status_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	status_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(status_dot)
	status_label = UiKit.label("", 20, 500)
	status_label.name = "Status"
	status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(status_label)
	save_error = UiKit.label("", 16, 400, Tokens.ERROR_TEXT)
	header.add_child(save_error)
	reconnect = PwButton.new("Reconnect", PwButton.Style.DARK, Vector2(170, 48))
	reconnect.name = "Reconnect"
	reconnect.icon_name = "refresh-cw"
	reconnect.pressed.connect(func() -> void:
		if nt != null:
			nt.reconnect())
	header.add_child(reconnect)
	reset = PwButton.new("Reset", PwButton.Style.OUTLINE, Vector2(130, 48))
	reset.name = "Reset"
	reset.pressed.connect(_on_reset)
	header.add_child(reset)
	save = PwButton.new("Save", PwButton.Style.PRIMARY, Vector2(130, 48))
	save.name = "Save"
	save.pressed.connect(_on_save)
	header.add_child(save)
	root.add_child(UiKit.margin(header, 32, 16, 32, 0))

	var scroll := UiKit.hscroll()
	scroll.name = "SettingsScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var cols := UiKit.hbox(0)
	scroll.add_child(cols)
	root.add_child(scroll)

	var c1 := UiKit.column("Robot", true, 24, 20)
	host = _field(c1["box"], "Host", "Robot NT Host / IP", ConnectionSettings.DEFAULT_NT["host"], false, "host")
	port = _field(c1["box"], "Port", "NT Port", str(ConnectionSettings.DEFAULT_NT["port"]), true, "port")
	_add_column(cols, c1)

	var c2 := UiKit.column("Topics", true, 24, 20)
	table = _field(c2["box"], "SharedTable", "Shared Table", ConnectionSettings.DEFAULT_NT["sharedTable"], false, "sharedTable")
	entry = _field(c2["box"], "RequestBase", "Request Topic Base", ConnectionSettings.DEFAULT_NT["selectedPathTopic"], false, "selectedPathTopic")
	_add_column(cols, c2)

	var c3 := UiKit.column("Connection", true, 24, 20)
	timeout = PwSlider.new().configure({"label": "Reconnect Timeout", "min_value": float(ConnectionSettings.TIMEOUT_MIN_S),
		"max_value": float(ConnectionSettings.TIMEOUT_UI_MAX_S), "step": 1.0, "decimals": 0, "value_label": "{v}s",
		"hints": TIMEOUT_HINTS, "value": float(ConnectionSettings.DEFAULT_RECONNECT_TIMEOUT_S)})
	timeout.name = "Timeout"
	timeout.value_changed.connect(func(v: float) -> void: _set_draft("reconnectTimeoutSeconds", v))
	c3["box"].add_child(timeout)
	diag = UiKit.label("", 15, 400, Tokens.ZINC_400)
	diag.name = "Diagnostics"
	diag.add_theme_font_override("font", Tokens.mono())
	diag.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	c3["box"].add_child(diag)
	_add_column(cols, c3)

	var c4 := UiKit.column("NT Preview", false, 24, 14)
	for key: String in ["host", "request", "state", "robot_constants"]:
		var caption := {"host": "Host", "request": "Request topic", "state": "State topic", "robot_constants": "Robot constants"}[key] as String
		var row := UiKit.vbox(2)
		row.add_child(UiKit.label(caption.to_upper(), 12, 600, Tokens.ZINC_400))
		var v := UiKit.label("", 16, 400, Tokens.TEXT)
		v.name = "Preview_" + key
		v.add_theme_font_override("font", Tokens.mono())
		v.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		row.add_child(v)
		preview_values[key] = v
		c4["box"].add_child(row)
	_add_column(cols, c4)

	add_child(UiKit.full(root))
	_load_drafts()
	if settings != null:
		settings.changed.connect(_on_settings_changed)
	_update_status()


func _add_column(cols: Control, c: Dictionary) -> void:
	var panel: Control = c["panel"]
	var title: Label = (c["box"] as Control).get_child(0)
	panel.custom_minimum_size.x = COLUMN_W.get(title.text, 420)
	cols.add_child(panel)


func _field(parent: Control, node_name: String, caption: String, hint: String, numeric: bool, key: String) -> PwTextInput:
	var t := PwTextInput.new(caption, hint, numeric)
	t.name = node_name
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	t.text_changed.connect(func(s: String) -> void: _set_draft(key, s))
	parent.add_child(t)
	return t


func saved() -> Dictionary:
	return settings.connection() if settings != null else ConnectionSettings.defaults()


func _load_drafts() -> void:
	drafts = ConnectionSettings.drafts_from(saved())
	host.set_text(drafts["host"])
	port.set_text(drafts["port"])
	table.set_text(drafts["sharedTable"])
	entry.set_text(drafts["selectedPathTopic"])
	timeout.set_value(drafts["reconnectTimeoutSeconds"])
	_evaluate()


func _set_draft(key: String, v: Variant) -> void:
	drafts[key] = v
	_evaluate()


func _evaluate() -> void:
	form = ConnectionSettings.evaluate_form(drafts, saved())
	save.disabled = not form["save_enabled"]
	var bad: Array = form["invalid_fields"]
	host.invalid = bad.has("host")
	port.invalid = bad.has("port")
	table.invalid = bad.has("sharedTable")
	entry.invalid = bad.has("selectedPathTopic")
	var pv: Dictionary = form["preview"]
	for key: String in preview_values:
		(preview_values[key] as Label).text = str(pv[key])


func _on_save() -> void:
	if not form.get("save_enabled", false) or settings == null:
		return
	save_error.text = "" if settings.set_connection(form["next"]) else "Could not write the settings file"
	_load_drafts()


func _on_reset() -> void:
	if settings == null:
		return
	save_error.text = "" if settings.reset_connection() else "Could not write the settings file"
	_load_drafts()


func _on_settings_changed(section: String) -> void:
	if section == "connection":
		_load_drafts()


func _process(delta: float) -> void:
	_diag_t += delta
	if _diag_t >= 0.25:
		_diag_t = 0.0
		_update_status()


func is_connected_nt() -> bool:
	return nt != null and nt.is_ready()


func _update_status() -> void:
	var ok := is_connected_nt()
	status_dot.color = Tokens.ACCENT if ok else Tokens.ERROR
	status_label.text = "Connected" if ok else "Disconnected"
	status_label.add_theme_color_override("font_color", Tokens.ACCENT if ok else Tokens.ERROR_TEXT)
	reconnect.visible = not ok
	if nt == null:
		diag.text = ""
		return
	if nt.fixture_mode:
		diag.text = "State      %s (fixture)" % ("READY" if ok else "IDLE")
		return
	var d := nt.diagnostics()
	var lines := PackedStringArray([
		"State      %s" % d.get("state", ""),
		"Server     %s:%d" % [nt.client.host, nt.client.port],
		"RTT        %s" % ("%.1f ms" % (float(d["rtt_us"]) / 1000.0) if ok and int(d.get("rtt_us", -1)) >= 0 else "--"),
		"Reconnects %d" % int(d.get("reconnects", 0)),
	])
	var last := str(d.get("last_close", ""))
	if last != "" and not ok:
		lines.append("Last close %s" % last.left(40))
	diag.text = "\n".join(lines)


func probe() -> Dictionary:
	return {
		"drafts": drafts.duplicate(),
		"save_enabled": not save.disabled,
		"valid": form.get("valid", false),
		"changed": form.get("changed", false),
		"invalid": form.get("invalid_fields", []),
		"preview": form.get("preview", {}),
		"status": status_label.text,
		"reconnect_visible": reconnect.visible,
		"error": save_error.text,
	}
