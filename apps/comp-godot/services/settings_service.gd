class_name SettingsService
extends Node

## Owner of user://settings.json and of the shared connection settings file.
## Readers pull the current values every frame (map() is a live dictionary), so
## a change shows up on the next frame in every window; `changed` is for
## listeners that cache. Writes are debounced and atomic.
## --settings=PATH uses another file; offline fixtures read and write one only
## when --settings is given (scripted restart runs). Offline fixtures keep the
## connection settings in memory unless PWRUP_SHARED_SETTINGS_PATH is set, so a
## screenshot run can never rewrite the real shared file.

signal changed(section: String)

const DEFAULT_PATH := "user://settings.json"
const SAVE_DELAY_S := 0.25

var path := DEFAULT_PATH
var persist := true
var data := AppSettings.defaults()
var connection_store: SharedSettingsStore
var _save_due_msec := -1
## --render-scale=X (0.25..1.0) wins over the stored render scale without being saved.
var visual_overrides := {}
## PerfGovernor's caps: render scale and MSAA no higher than these, not saved.
var perf_caps := {}


func _ready() -> void:
	var dev := get_node_or_null("/root/Dev") as DevService
	var offline := false
	if dev != null:
		offline = dev.offline_fixture()
		var rs := CliArgs.get_float(dev.args, "render_scale", 0.0)
		if rs > 0.0:
			visual_overrides["render_scale"] = clampf(rs, 0.25, 1.0)
		if dev.args.has("settings"):
			path = str(dev.args["settings"])
		elif offline:
			persist = false
	if persist:
		load_file()
	if connection_store == null:
		var memory := offline and OS.get_environment(ConnectionSettings.ENV_PATH).strip_edges() == ""
		connection_store = SharedSettingsStore.new("", memory)
		connection_store.reload()
		if dev != null and offline and typeof(dev.fixture.get("connection")) == TYPE_DICTIONARY:
			connection_store.current = ConnectionSettings.from_settings(dev.fixture["connection"])


## {"nt": {host, port, sharedTable, selectedPathTopic}, "reconnectTimeoutSeconds": int}
func connection() -> Dictionary:
	return connection_store.current


## Writes the shared file now (atomic, version + 1). False when the write failed.
func set_connection(conn: Dictionary) -> bool:
	var before := connection_store.current.duplicate(true)
	if not connection_store.save(conn):
		push_warning("settings: " + connection_store.last_error)
		return false
	if connection_store.current != before:
		changed.emit("connection")
	return true


func reset_connection() -> bool:
	return set_connection(ConnectionSettings.defaults())


func controls() -> Dictionary:
	return data["controls"]


func set_controls(patch: Dictionary) -> void:
	_patch("controls", patch, AppSettings.normalize_controls)


func load_file() -> void:
	if not FileAccess.file_exists(path):
		data = AppSettings.defaults()
		return
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK:
		push_warning("settings: %s is not valid JSON, using defaults" % path)
		data = AppSettings.defaults()
		return
	data = AppSettings.normalize(json.data)


func map() -> Dictionary:
	return data["map"]


func set_map(patch: Dictionary) -> void:
	_patch("map", patch, AppSettings.normalize_map)


func visual() -> Dictionary:
	return data["visual"]


func set_visual(patch: Dictionary) -> void:
	_patch("visual", patch, AppSettings.normalize_visual)


func windows() -> Dictionary:
	return data["windows"]


func set_windows(patch: Dictionary) -> void:
	_patch("windows", patch, AppSettings.normalize_windows)


func effective_visual() -> Dictionary:
	if visual_overrides.is_empty() and perf_caps.is_empty():
		return data["visual"]
	var v: Dictionary = data["visual"].duplicate()
	v.merge(visual_overrides, true)
	for k: String in perf_caps:
		v[k] = minf(float(v[k]), float(perf_caps[k])) if k == "render_scale" else mini(int(v[k]), int(perf_caps[k]))
	return v


func set_perf_caps(caps: Dictionary) -> void:
	perf_caps = caps.duplicate()
	changed.emit("visual")


func layout() -> Dictionary:
	return data["layout"]


func set_layout(rail: Array, dock: Array) -> void:
	_patch("layout", {"rail": rail, "dock": dock}, AppSettings.normalize_layout)


func reset(section: String) -> void:
	_patch(section, AppSettings.defaults()[section], func(v: Variant) -> Dictionary: return v)


## Sections are updated in place so readers holding the dictionary see changes.
func _patch(section: String, patch: Dictionary, normalize: Callable) -> void:
	var merged: Dictionary = data[section].duplicate(true)
	merged.merge(patch, true)
	var normalized: Dictionary = normalize.call(merged)
	if normalized == data[section]:
		return
	(data[section] as Dictionary).merge(normalized, true)
	changed.emit(section)
	_schedule_save()


func _schedule_save() -> void:
	if not persist:
		return
	_save_due_msec = Time.get_ticks_msec() + int(SAVE_DELAY_S * 1000.0)


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	if _save_due_msec >= 0 and now >= _save_due_msec:
		save_now()
	if connection_store != null and connection_store.poll(now):
		changed.emit("connection")


func save_now() -> bool:
	_save_due_msec = -1
	if not persist:
		return false
	var dir := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_warning("settings: cannot write %s (%s)" % [tmp, error_string(FileAccess.get_open_error())])
		return false
	f.store_string(JSON.stringify(data, "  ", false))
	f.close()
	var err := DirAccess.rename_absolute(tmp, path)
	if err != OK:
		push_warning("settings: cannot replace %s (%s)" % [path, error_string(err)])
		return false
	return true


func _exit_tree() -> void:
	if _save_due_msec >= 0:
		save_now()
