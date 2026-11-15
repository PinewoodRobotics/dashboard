class_name SettingsTab
extends Control

## Connection Settings (TouchscreenSettingsPanel.tsx). Drafts are validated
## like useTouchscreenSettingsForm.ts: Save is enabled only when the form is
## valid and differs from the saved settings, Reset writes the schema
## defaults, and every save goes to the shared file. The header status is the
## NetworkTables client's (the web shows Autobahn's), with the current attempt
## while it connects, and Reconnect stays shown in every state: it drops the
## connection and opens a new one at once. After the web's columns (the
## Autobahn one is dropped: the port has no Autobahn) come two Godot-only
## columns: the client's diagnostics and the auto export with Reload Autos.

const VALUE_LABEL := "{v}s — close stuck connections after this many seconds"

var settings: SettingsService
var nt: NtService
var drafts := {}
var form := {}
var header: SettingsHeader
var host: PwTextInput
var port: PwTextInput
var table: PwTextInput
var entry: PwTextInput
var timeout: PwSlider
var save: PwButton
var reset: PwButton
var reconnect: PwButton
var status_label: PwText
var save_error := ""
var preview: InfoBox
var diag: InfoBox
var auto_export: AutoExportBox
var _diag_t := 0.0


func _ready() -> void:
	if settings == null:
		settings = get_node_or_null("/root/Settings") as SettingsService
	if nt == null:
		nt = get_node_or_null("/root/NT") as NtService
	add_child(UiKit.full(PwRect.new(Tokens.PANEL)))
	var root := UiKit.vbox(0)

	header = SettingsHeader.new("Connection Settings", true)
	status_label = header.status_label
	reconnect = header.add_button(PwButton.new("Reconnect", PwButton.Style.OUTLINE))
	reconnect.name = "Reconnect"
	reconnect.pressed.connect(func() -> void:
		if nt != null:
			nt.reconnect()
		_update_status())
	reset = header.add_button(PwButton.new("Reset", PwButton.Style.OUTLINE))
	reset.name = "Reset"
	reset.pressed.connect(_on_reset)
	save = header.add_button(PwButton.new("Save", PwButton.Style.PRIMARY))
	save.name = "Save"
	save.pressed.connect(_on_save)
	root.add_child(header)

	var scroll := UiKit.hscroll()
	scroll.name = "SettingsScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var cols := UiKit.hbox(0)
	scroll.add_child(cols)
	root.add_child(scroll)

	var c1 := UiKit.column("NetworkTables", true)
	host = _field(c1["box"], "Host", "Robot NT Host / IP", "10.47.65.2", false, "host")
	port = _field(c1["box"], "Port", "NT Port", "5810", true, "port")
	table = _field(c1["box"], "SharedTable", "Shared Table", "Shared/PathPlanner", false, "sharedTable")
	entry = _field(c1["box"], "RequestBase", "Request Topic Base", "SelectedPath", false, "selectedPathTopic")
	cols.add_child(c1["panel"])

	var c2 := UiKit.column("Connection", false)
	timeout = PwSlider.new().configure({"label": "Reconnect Timeout", "min_value": float(ConnectionSettings.TIMEOUT_UI_MIN_S),
		"max_value": float(ConnectionSettings.TIMEOUT_UI_MAX_S), "step": 1.0, "decimals": 0, "value_label": VALUE_LABEL,
		"value": float(ConnectionSettings.DEFAULT_RECONNECT_TIMEOUT_S)})
	timeout.name = "Timeout"
	timeout.value_changed.connect(func(v: float) -> void: _set_draft("reconnectTimeoutSeconds", v))
	c2["box"].add_child(timeout)
	cols.add_child(c2["panel"])

	var c3 := UiKit.column("Preview", false)
	preview = InfoBox.new("NT Preview", [["host", "Host"], ["request", "Request topic"], ["state", "State topic"], ["robot_constants", "Robot constants"]])
	preview.name = "NtPreview"
	c3["box"].add_child(preview)
	cols.add_child(c3["panel"])

	var c4 := UiKit.column("Diagnostics", false)
	diag = InfoBox.new("NT Client", [["state", "State"], ["server", "Server"], ["rtt", "Round trip"], ["reconnects", "Reconnects"], ["last_close", "Last close"]])
	diag.name = "Diagnostics"
	c4["box"].add_child(diag)
	cols.add_child(c4["panel"])

	var c5 := UiKit.column("Autos", false)
	auto_export = AutoExportBox.new()
	c5["box"].add_child(auto_export)
	cols.add_child(c5["panel"])

	add_child(UiKit.full(root))
	_load_drafts()
	if settings != null:
		settings.changed.connect(_on_settings_changed)
	_update_status()


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
	for key: String in preview.values:
		preview.set_value(key, str(pv[key]))


func _on_save() -> void:
	if not form.get("save_enabled", false) or settings == null:
		return
	save_error = "" if settings.set_connection(form["next"]) else "Could not write the settings file"
	_load_drafts()
	_update_status()


func _on_reset() -> void:
	if settings == null:
		return
	save_error = "" if settings.reset_connection() else "Could not write the settings file"
	_load_drafts()
	_update_status()


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


## "Connected", or what the client is doing: "Connecting, attempt 3 (0.4 s)".
static func status_text(d: Dictionary) -> String:
	var attempt := int(d.get("attempt", 0))
	match str(d.get("state", "")):
		"READY":
			return "Connected"
		"CONNECTING":
			return "Connecting, attempt %d (%.1f s)" % [attempt, maxf(0.0, float(d.get("attempt_age_s", 0.0)))]
		"SYNCING":
			return "Syncing, attempt %d" % attempt
		"BACKOFF":
			var left := float(d.get("backoff_left_s", 0.0))
			if attempt == 0:
				return "Link lost, retrying in %.1f s" % left
			return "Attempt %d failed, retrying in %.1f s" % [attempt, left]
	return "Disconnected"


func _update_status() -> void:
	var ok := is_connected_nt()
	if nt == null or nt.fixture_mode:
		header.set_status(save_error if save_error != "" else ("Connected" if ok else "Disconnected"), ok and save_error == "")
		diag.set_value("state", "" if nt == null else ("READY" if ok else "IDLE") + " (fixture)")
		return
	var d := nt.diagnostics()
	header.set_status(save_error if save_error != "" else status_text(d), ok and save_error == "")
	diag.set_value("state", str(d.get("state", "")))
	diag.set_value("server", "%s:%d" % [nt.client.host, nt.client.port])
	diag.set_value("rtt", "%.1f ms" % (float(d["rtt_us"]) / 1000.0) if ok and int(d.get("rtt_us", -1)) >= 0 else "--")
	diag.set_value("reconnects", "%d (manual %d)" % [int(d.get("reconnects", 0)), int(d.get("manual_reconnects", 0))])
	var last := str(d.get("last_close", ""))
	diag.set_value("last_close", last if last != "" else "--")


func probe() -> Dictionary:
	var pv := {}
	for key: String in preview.values:
		pv[key] = preview.value(key)
	return {
		"drafts": drafts.duplicate(),
		"save_enabled": not save.disabled,
		"valid": form.get("valid", false),
		"changed": form.get("changed", false),
		"invalid": form.get("invalid_fields", []),
		"preview": pv,
		"status": status_label.text,
		"reconnect_visible": reconnect.visible,
		"error": save_error,
	}
