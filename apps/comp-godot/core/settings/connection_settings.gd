class_name ConnectionSettings
extends RefCounted

const ENV_PATH := "PWRUP_SHARED_SETTINGS_PATH"
const DEFAULT_RECONNECT_TIMEOUT_S := 10

const DEFAULT_NT := {
	"host": "10.47.65.2",
	"port": 5810,
	"sharedTable": "Shared",
	"selectedPathTopic": "PathPlanner/SelectedPath",
}


static func shared_file_path() -> String:
	var env := OS.get_environment(ENV_PATH)
	if env != "":
		return env
	var home := OS.get_environment("USERPROFILE") if OS.get_name() == "Windows" else OS.get_environment("HOME")
	return home.path_join(".pwrup").path_join("shared-settings").path_join("connection-settings.json")


## Same rule as normalizeReconnectTimeoutSeconds in settings-schema.ts.
static func normalize_reconnect_timeout(v: Variant) -> int:
	if (typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT) and is_finite(float(v)) and v >= 2 and v <= 60:
		return int(round(float(v)))
	return DEFAULT_RECONNECT_TIMEOUT_S


static func normalize_nt(raw: Variant) -> Dictionary:
	var out := DEFAULT_NT.duplicate()
	if typeof(raw) != TYPE_DICTIONARY:
		return out
	if typeof(raw.get("host")) == TYPE_STRING and raw["host"].strip_edges() != "":
		out["host"] = raw["host"].strip_edges()
	var p: Variant = raw.get("port")
	if (typeof(p) == TYPE_FLOAT or typeof(p) == TYPE_INT) and p >= 1 and p <= 65535:
		out["port"] = int(p)
	for key: String in ["sharedTable", "selectedPathTopic"]:
		if typeof(raw.get(key)) == TYPE_STRING and raw[key].strip_edges() != "":
			out[key] = raw[key].strip_edges()
	return out


## Returns {"nt": {...}, "reconnectTimeoutSeconds": int, "source": path or ""}.
static func load_shared() -> Dictionary:
	var path := shared_file_path()
	var result := {"nt": DEFAULT_NT.duplicate(), "reconnectTimeoutSeconds": DEFAULT_RECONNECT_TIMEOUT_S, "source": ""}
	if not FileAccess.file_exists(path):
		return result
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(data) != TYPE_DICTIONARY:
		return result
	var settings: Variant = data.get("settings", {})
	if typeof(settings) != TYPE_DICTIONARY:
		return result
	result["nt"] = normalize_nt(settings.get("networkTables"))
	result["reconnectTimeoutSeconds"] = normalize_reconnect_timeout(settings.get("reconnectTimeoutSeconds"))
	result["source"] = path
	return result
