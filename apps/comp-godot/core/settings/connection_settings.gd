class_name ConnectionSettings
extends RefCounted

## NetworkTables connection settings as stored in the shared JSON file
## (`settings.networkTables` and `settings.reconnectTimeoutSeconds`), normalized
## like normalizeSettings in packages/shared-core/src/settings.tsx, plus the
## Connection Settings form rules of useTouchscreenSettingsForm.ts.

const ENV_PATH := "PWRUP_SHARED_SETTINGS_PATH"
const DEFAULT_RECONNECT_TIMEOUT_S := 10
const TIMEOUT_MIN_S := 2
const TIMEOUT_MAX_S := 60
const TIMEOUT_UI_MAX_S := 30

const DEFAULT_NT := {
	"host": "10.47.65.2",
	"port": 5810,
	"sharedTable": "Shared",
	"selectedPathTopic": "PathPlanner/SelectedPath",
}


static func shared_file_path() -> String:
	var env := OS.get_environment(ENV_PATH).strip_edges()
	if env != "":
		return env
	var home := OS.get_environment("USERPROFILE") if OS.get_name() == "Windows" else OS.get_environment("HOME")
	return home.path_join(".pwrup").path_join("shared-settings").path_join("connection-settings.json")


static func defaults() -> Dictionary:
	return {"nt": DEFAULT_NT.duplicate(), "reconnectTimeoutSeconds": DEFAULT_RECONNECT_TIMEOUT_S}


static func _is_num(v: Variant) -> bool:
	return (typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT) and is_finite(float(v))


static func normalize_reconnect_timeout(v: Variant) -> int:
	if _is_num(v) and v >= TIMEOUT_MIN_S and v <= TIMEOUT_MAX_S:
		return int(round(float(v)))
	return DEFAULT_RECONNECT_TIMEOUT_S


static func trim_slashes(s: String) -> String:
	var t := s.strip_edges()
	while t.begins_with("/"):
		t = t.substr(1)
	while t.ends_with("/"):
		t = t.left(t.length() - 1)
	return t


static func _topic_part(v: Variant, fallback: String) -> String:
	var t := trim_slashes(v) if typeof(v) == TYPE_STRING else ""
	return t if t != "" else fallback


static func _port(v: Variant, fallback: int) -> int:
	if _is_num(v) and v > 0 and v <= 65535:
		return int(round(float(v)))
	return fallback


static func team_to_robot_ip(team: int, last_octet: int = 2) -> String:
	var t := maxi(0, team)
	return "10.%d.%d.%d" % [t / 100, t % 100, clampi(last_octet, 1, 254)]


## Includes the legacy keys the web loader still migrates
## (autonomousSelectedEntry, currentPathTopic, teamNumber + robotIpLastOctet).
static func normalize_nt(raw: Variant) -> Dictionary:
	var out := DEFAULT_NT.duplicate()
	if typeof(raw) != TYPE_DICTIONARY:
		return out
	var host_ok := typeof(raw.get("host")) == TYPE_STRING and (raw["host"] as String).strip_edges() != ""
	if host_ok:
		out["host"] = (raw["host"] as String).strip_edges()
	elif _is_num(raw.get("teamNumber")) and raw["teamNumber"] > 0:
		var octet: int = int(raw["robotIpLastOctet"]) if _is_num(raw.get("robotIpLastOctet")) else 2
		out["host"] = team_to_robot_ip(int(raw["teamNumber"]), octet)
	out["port"] = _port(raw.get("port"), DEFAULT_NT["port"])
	out["sharedTable"] = _topic_part(raw.get("sharedTable"), DEFAULT_NT["sharedTable"])
	var entry_raw: Variant = raw.get("selectedPathTopic") if typeof(raw.get("selectedPathTopic")) == TYPE_STRING else raw.get("autonomousSelectedEntry")
	var entry := _topic_part(entry_raw, DEFAULT_NT["selectedPathTopic"])
	if entry == "AutonomousSelected":
		entry = DEFAULT_NT["selectedPathTopic"]
	out["selectedPathTopic"] = entry
	var legacy: Variant = raw.get("currentPathTopic")
	if typeof(legacy) == TYPE_STRING and (legacy as String).strip_edges() != "":
		var parts: PackedStringArray = (legacy as String).strip_edges().trim_prefix("/").split("/", false)
		if parts.size() >= 2:
			out["sharedTable"] = _topic_part(parts[0], DEFAULT_NT["sharedTable"])
			out["selectedPathTopic"] = _topic_part("/".join(parts.slice(1)), DEFAULT_NT["selectedPathTopic"])
		else:
			out["sharedTable"] = DEFAULT_NT["sharedTable"]
			out["selectedPathTopic"] = DEFAULT_NT["selectedPathTopic"]
	return out


## `settings` object of the shared file -> {"nt": {...}, "reconnectTimeoutSeconds": int}.
static func from_settings(settings: Variant) -> Dictionary:
	if typeof(settings) != TYPE_DICTIONARY:
		return defaults()
	return {
		"nt": normalize_nt(settings.get("networkTables")),
		"reconnectTimeoutSeconds": normalize_reconnect_timeout(settings.get("reconnectTimeoutSeconds")),
	}


## JavaScript Number(s) for the form's text fields: blank is 0, junk is NaN.
static func js_number(s: String) -> float:
	var t := s.strip_edges()
	if t == "":
		return 0.0
	if t.is_valid_float() or t.is_valid_int():
		return float(t)
	return NAN


## Drafts are the form's raw strings plus the slider value:
## {"host", "port", "sharedTable", "selectedPathTopic": String, "reconnectTimeoutSeconds": float}.
static func drafts_from(conn: Dictionary) -> Dictionary:
	var nt: Dictionary = conn["nt"]
	return {
		"host": str(nt["host"]),
		"port": str(nt["port"]),
		"sharedTable": str(nt["sharedTable"]),
		"selectedPathTopic": str(nt["selectedPathTopic"]),
		"reconnectTimeoutSeconds": float(conn["reconnectTimeoutSeconds"]),
	}


## {"valid", "changed", "save_enabled", "invalid_fields", "next": conn, "preview": {...}}
static func evaluate_form(drafts: Dictionary, saved: Dictionary) -> Dictionary:
	var host := str(drafts.get("host", "")).strip_edges()
	var port := js_number(str(drafts.get("port", "")))
	var table := str(drafts.get("sharedTable", "")).strip_edges()
	var entry := str(drafts.get("selectedPathTopic", "")).strip_edges()
	var timeout := int(round(float(drafts.get("reconnectTimeoutSeconds", DEFAULT_RECONNECT_TIMEOUT_S))))
	var invalid: Array = []
	if host == "":
		invalid.append("host")
	if not (is_finite(port) and port > 0 and port <= 65535):
		invalid.append("port")
	if table == "":
		invalid.append("sharedTable")
	if entry == "":
		invalid.append("selectedPathTopic")
	var s_nt: Dictionary = saved["nt"]
	var changed: bool = host != s_nt["host"] \
		or not is_finite(port) or int(round(port)) != int(s_nt["port"]) \
		or table != s_nt["sharedTable"] \
		or entry != s_nt["selectedPathTopic"] \
		or timeout != int(saved["reconnectTimeoutSeconds"])
	var valid := invalid.is_empty()
	return {
		"valid": valid,
		"changed": changed,
		"save_enabled": valid and changed,
		"invalid_fields": invalid,
		"next": {
			"nt": {"host": host, "port": int(round(port)) if is_finite(port) else 0, "sharedTable": table, "selectedPathTopic": entry},
			"reconnectTimeoutSeconds": timeout,
		},
		"preview": preview(host, table, entry),
	}


## NT Preview table of the settings tab (ntSelectedPathTopics).
static func preview(host: String, table: String, entry: String) -> Dictionary:
	var base := "/%s/%s" % [trim_slashes(table), trim_slashes(entry)]
	var bare := base.trim_prefix("/")
	return {
		"host": host if host.strip_edges() != "" else "(not set)",
		"request": base + "/Request",
		"state": base + "/State",
		"robot_constants": "%s/Request / %s/State" % [bare, bare],
	}
