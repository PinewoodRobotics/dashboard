class_name SettingsService
extends Node

## Owner of user://settings.json. Readers pull the current values every frame
## (map() is a live dictionary), so a change shows up on the next frame in every
## window; `changed` is for listeners that cache. Writes are debounced and atomic.
## --settings=PATH uses another file; offline fixtures never read or write one.

signal changed(section: String)

const DEFAULT_PATH := "user://settings.json"
const SAVE_DELAY_S := 0.25

var path := DEFAULT_PATH
var persist := true
var data := AppSettings.defaults()
var _save_due_msec := -1


func _ready() -> void:
	var dev := get_node_or_null("/root/Dev") as DevService
	if dev != null:
		if dev.offline_fixture():
			persist = false
		elif dev.args.has("settings"):
			path = str(dev.args["settings"])
	if persist:
		load_file()
	set_process(false)


func load_file() -> void:
	if not FileAccess.file_exists(path):
		data = AppSettings.defaults()
		return
	data = AppSettings.normalize(JSON.parse_string(FileAccess.get_file_as_string(path)))


func map() -> Dictionary:
	return data["map"]


func set_map(patch: Dictionary) -> void:
	var merged: Dictionary = data["map"].duplicate()
	merged.merge(patch, true)
	var normalized := AppSettings.normalize_map(merged)
	if normalized == data["map"]:
		return
	(data["map"] as Dictionary).merge(normalized, true)
	changed.emit("map")
	_schedule_save()


func _schedule_save() -> void:
	if not persist:
		return
	_save_due_msec = Time.get_ticks_msec() + int(SAVE_DELAY_S * 1000.0)
	set_process(true)


func _process(_delta: float) -> void:
	if _save_due_msec >= 0 and Time.get_ticks_msec() >= _save_due_msec:
		save_now()


func save_now() -> bool:
	_save_due_msec = -1
	set_process(false)
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
