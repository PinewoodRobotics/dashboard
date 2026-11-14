class_name SharedSettingsStore
extends RefCounted

## The connection settings file shared with the Electron comp app and the
## admin app (electron/shared-settings.cjs). Only `settings.networkTables` and
## `settings.reconnectTimeoutSeconds` are ours: every other key (the Autobahn
## host and port, hudVisibility, keys from newer builds) is written back as it
## was read. Saves bump `version` and replace the file atomically. `poll()`
## re-reads the file at most every POLL_S and reports external edits.
## With `memory_only` nothing touches the disk (offline fixtures).

const POLL_S := 2.0
const DEFAULT_AUTOBAHN := {"host": "10.47.65.7", "port": 8080}
const DEFAULT_HUD_VISIBILITY := {"showMap": false, "showTimers": true, "showStatus": true, "showCamera": true}

var path := ""
var memory_only := false
## {"nt": {...}, "reconnectTimeoutSeconds": int}
var current := ConnectionSettings.defaults()
var version := 0
var last_error := ""
var _last_text := ""
var _next_poll_ms := 0


func _init(p_path: String = "", p_memory_only: bool = false) -> void:
	path = p_path if p_path != "" else ConnectionSettings.shared_file_path()
	memory_only = p_memory_only


## Re-reads the file; true when the normalized settings changed.
func reload() -> bool:
	if memory_only:
		return false
	var text := FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""
	if text == _last_text and text != "":
		return false
	_last_text = text
	var raw: Variant = parse_json(text)
	var next := ConnectionSettings.defaults()
	version = 0
	if typeof(raw) == TYPE_DICTIONARY:
		next = ConnectionSettings.from_settings(raw.get("settings"))
		version = _version_of(raw)
	if next == current:
		return false
	current = next
	return true


## null for empty or malformed text (no engine error: a half-written file from
## another app is expected now and then).
static func parse_json(text: String) -> Variant:
	if text.strip_edges() == "":
		return null
	var json := JSON.new()
	return json.data if json.parse(text) == OK else null


func poll(now_ms: int) -> bool:
	if memory_only or now_ms < _next_poll_ms:
		return false
	_next_poll_ms = now_ms + int(POLL_S * 1000.0)
	return reload()


static func _version_of(raw: Dictionary) -> int:
	var v: Variant = raw.get("version")
	if (typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT) and is_finite(float(v)) and v >= 1:
		return int(floor(float(v)))
	return 1


## Writes `conn` (normalized first) and returns true on success. The rest of
## the file is re-read right before writing so concurrent edits by the other
## apps to keys we do not own survive.
func save(conn: Dictionary) -> bool:
	var normalized := {
		"nt": ConnectionSettings.normalize_nt(conn.get("nt")),
		"reconnectTimeoutSeconds": ConnectionSettings.normalize_reconnect_timeout(conn.get("reconnectTimeoutSeconds")),
	}
	if memory_only:
		current = normalized
		version += 1
		return true
	var raw: Variant = parse_json(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null
	var doc: Dictionary = raw if typeof(raw) == TYPE_DICTIONARY else {}
	var next_version := (_version_of(doc) if not doc.is_empty() else 0) + 1
	var settings: Dictionary = doc.get("settings") if typeof(doc.get("settings")) == TYPE_DICTIONARY else {}
	for k: String in DEFAULT_AUTOBAHN:
		if not settings.has(k):
			settings[k] = DEFAULT_AUTOBAHN[k]
	var nt: Dictionary = settings.get("networkTables") if typeof(settings.get("networkTables")) == TYPE_DICTIONARY else {}
	nt.merge(normalized["nt"], true)
	settings["networkTables"] = nt
	settings["reconnectTimeoutSeconds"] = normalized["reconnectTimeoutSeconds"]
	doc["settings"] = settings
	if typeof(doc.get("hudVisibility")) != TYPE_DICTIONARY:
		doc["hudVisibility"] = DEFAULT_HUD_VISIBILITY.duplicate()
	doc["version"] = next_version
	doc["updatedAtIso"] = Time.get_datetime_string_from_system(true) + ".000Z"
	var text := JSON.stringify(integral_floats_to_int(doc), "  ", false)
	if not write_atomically(path, text):
		return false
	_last_text = text
	current = normalized
	version = next_version
	return true


func write_atomically(target: String, text: String) -> bool:
	var dir := target.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var tmp := "%s.tmp-%d-%d" % [target, OS.get_process_id(), Time.get_ticks_usec()]
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		last_error = "cannot write %s (%s)" % [tmp, error_string(FileAccess.get_open_error())]
		return false
	f.store_string(text)
	f.close()
	var err := DirAccess.rename_absolute(tmp, target)
	if err != OK:
		DirAccess.remove_absolute(tmp)
		last_error = "cannot replace %s (%s)" % [target, error_string(err)]
		return false
	last_error = ""
	return true


## Godot parses every JSON number as a float; write whole numbers back as
## integers so the other apps see `"port": 5810`, not `5810.0`.
static func integral_floats_to_int(v: Variant) -> Variant:
	match typeof(v):
		TYPE_FLOAT:
			var f: float = v
			if is_finite(f) and f == floorf(f) and absf(f) < 9.0e15:
				return int(f)
			return f
		TYPE_DICTIONARY:
			var out := {}
			for k: Variant in v:
				out[k] = integral_floats_to_int(v[k])
			return out
		TYPE_ARRAY:
			var arr: Array = []
			for x: Variant in v:
				arr.append(integral_floats_to_int(x))
			return arr
	return v
