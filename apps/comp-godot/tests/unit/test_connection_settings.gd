extends TestCase

const LIVE_FILE := {
	"version": 9,
	"updatedAtIso": "2026-07-07T01:39:18.069Z",
	"settings": {
		"host": "192.168.252.2",
		"port": 8080,
		"reconnectTimeoutSeconds": 10,
		"networkTables": {"host": "10.47.65.2", "port": 5810, "sharedTable": "Shared", "selectedPathTopic": "PathPlanner/SelectedPath", "futureNtKey": "keep"},
	},
	"hudVisibility": {"showMap": false, "showTimers": true, "showStatus": true, "showCamera": true},
	"futureTopKey": {"nested": [1, 2.5, "x"]},
}

var dir := ""
var file := ""
var _env_before := ""


func before_each() -> void:
	dir = ProjectSettings.globalize_path("res://.scratch/unit/shared_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)
	file = dir.path_join("connection-settings.json")
	_env_before = OS.get_environment(ConnectionSettings.ENV_PATH)
	OS.set_environment(ConnectionSettings.ENV_PATH, file)


func after_each() -> void:
	OS.set_environment(ConnectionSettings.ENV_PATH, _env_before)
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)


func _write(data: Variant) -> void:
	var f := FileAccess.open(file, FileAccess.WRITE)
	f.store_string(data if data is String else JSON.stringify(data, "  "))
	f.close()


func _read() -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(file))


func test_schema_defaults() -> void:
	check_eq(ConnectionSettings.defaults(), {"nt": {"host": "10.47.65.2", "port": 5810, "sharedTable": "Shared", "selectedPathTopic": "PathPlanner/SelectedPath"}, "reconnectTimeoutSeconds": 10})
	check_eq(ConnectionSettings.shared_file_path(), file, "env override")


func test_normalization_rules() -> void:
	var n := ConnectionSettings.normalize_nt({"host": " 127.0.0.1 ", "port": 5811.4, "sharedTable": "/Shared/", "selectedPathTopic": " /A/B/ "})
	check_eq(n, {"host": "127.0.0.1", "port": 5811, "sharedTable": "Shared", "selectedPathTopic": "A/B"})
	n = ConnectionSettings.normalize_nt({"host": "", "port": 70000, "sharedTable": "//", "selectedPathTopic": "AutonomousSelected"})
	check_eq(n, ConnectionSettings.DEFAULT_NT, "invalid parts fall back; legacy AutonomousSelected entry rewritten")
	n = ConnectionSettings.normalize_nt({"teamNumber": 4765, "robotIpLastOctet": 2, "autonomousSelectedEntry": "Auto/Sel"})
	check_eq(n["host"], "10.47.65.2", "legacy team number")
	check_eq(n["selectedPathTopic"], "Auto/Sel", "legacy entry key")
	n = ConnectionSettings.normalize_nt({"currentPathTopic": "/Tbl/Some/Entry"})
	check_eq([n["sharedTable"], n["selectedPathTopic"]], ["Tbl", "Some/Entry"], "legacy full topic path")
	check_eq(ConnectionSettings.normalize_reconnect_timeout(61), 10)
	check_eq(ConnectionSettings.normalize_reconnect_timeout(30.4), 30)


func test_form_validation_like_the_web() -> void:
	var saved := ConnectionSettings.defaults()
	var d := ConnectionSettings.drafts_from(saved)
	var f := ConnectionSettings.evaluate_form(d, saved)
	check(f["valid"] and not f["changed"] and not f["save_enabled"], "unchanged: Save disabled")
	d["host"] = "  10.47.65.2  "
	check(not ConnectionSettings.evaluate_form(d, saved)["changed"], "trimmed drafts compare equal")
	d["host"] = "127.0.0.1"
	f = ConnectionSettings.evaluate_form(d, saved)
	check(f["save_enabled"], "valid and changed")
	check_eq(f["next"]["nt"]["host"], "127.0.0.1")
	for bad: String in ["", "0", "65536", "abc"]:
		var d2 := d.duplicate()
		d2["port"] = bad
		var f2 := ConnectionSettings.evaluate_form(d2, saved)
		check(not f2["valid"] and not f2["save_enabled"], "port %s rejected" % bad)
		check_eq(f2["invalid_fields"], ["port"])
	for key: String in ["host", "sharedTable", "selectedPathTopic"]:
		var d3 := ConnectionSettings.drafts_from(saved)
		d3[key] = "   "
		check_eq(ConnectionSettings.evaluate_form(d3, saved)["invalid_fields"], [key], key + " must not be blank")
	var d4 := ConnectionSettings.drafts_from(saved)
	d4["reconnectTimeoutSeconds"] = 25.0
	f = ConnectionSettings.evaluate_form(d4, saved)
	check(f["save_enabled"], "timeout change enables Save")
	check_eq(f["next"]["reconnectTimeoutSeconds"], 25)
	var d5 := ConnectionSettings.drafts_from(saved)
	d5["port"] = "65535"
	check(ConnectionSettings.evaluate_form(d5, saved)["save_enabled"])


func test_preview_topics() -> void:
	var p := ConnectionSettings.preview("", "/Shared/", "PathPlanner/SelectedPath")
	check_eq(p, {"host": "(not set)", "request": "/Shared/PathPlanner/SelectedPath/Request", "state": "/Shared/PathPlanner/SelectedPath/State",
		"robot_constants": "Shared/PathPlanner/SelectedPath/Request / Shared/PathPlanner/SelectedPath/State"})


func test_save_round_trip_preserves_unknown_keys() -> void:
	_write(LIVE_FILE)
	var store := SharedSettingsStore.new()
	check_eq(store.path, file)
	store.reload()
	check_eq(store.version, 9)
	check_eq(store.current["nt"]["host"], "10.47.65.2")
	var next := {"nt": {"host": "127.0.0.1", "port": 5811, "sharedTable": "Shared", "selectedPathTopic": "PathPlanner/SelectedPath"}, "reconnectTimeoutSeconds": 4}
	check(store.save(next))
	var raw := _read()
	check_eq(raw["version"], 10.0, "version + 1")
	check_eq(raw["settings"]["host"], "192.168.252.2", "Autobahn host survives")
	check_eq(raw["settings"]["port"], 8080.0, "Autobahn port survives")
	check_eq(raw["hudVisibility"], LIVE_FILE["hudVisibility"], "hudVisibility survives")
	check_eq(raw["futureTopKey"], {"nested": [1.0, 2.5, "x"]}, "unknown top-level key survives")
	check_eq(raw["settings"]["networkTables"]["futureNtKey"], "keep", "unknown nested key survives")
	check_eq(raw["settings"]["networkTables"]["host"], "127.0.0.1")
	check_eq(raw["settings"]["networkTables"]["port"], 5811.0)
	check_eq(raw["settings"]["reconnectTimeoutSeconds"], 4.0)
	check(str(raw["updatedAtIso"]).ends_with("Z"))
	var text := FileAccess.get_file_as_string(file)
	check(text.contains("\"port\": 5811") and not text.contains("5811.0"), "whole numbers stay integers for the other apps")
	check_eq(DirAccess.get_files_at(dir), PackedStringArray(["connection-settings.json"]), "no temp file left behind")
	var again := SharedSettingsStore.new()
	again.reload()
	check_eq(again.current, next)
	check(store.save(next))
	check_eq(_read()["version"], 11.0)


func test_save_creates_missing_file_and_ignores_corrupt() -> void:
	var store := SharedSettingsStore.new()
	check(not store.reload(), "missing file: defaults, no change")
	check(not FileAccess.file_exists(file), "reading never writes")
	check(store.save(ConnectionSettings.defaults()))
	var raw := _read()
	check_eq(raw["version"], 1.0)
	check_eq(raw["settings"]["host"], "10.47.65.7", "Electron needs the Autobahn keys")
	check_eq(raw["hudVisibility"]["showTimers"], true)
	_write("{not json")
	var s2 := SharedSettingsStore.new()
	s2.current = {"nt": {"host": "x", "port": 1, "sharedTable": "a", "selectedPathTopic": "b"}, "reconnectTimeoutSeconds": 5}
	check(s2.reload(), "corrupt file reads as defaults")
	check_eq(s2.current, ConnectionSettings.defaults())
	check_eq(FileAccess.get_file_as_string(file), "{not json", "corrupt file left alone until a save")


func test_poll_picks_up_external_edits() -> void:
	_write(LIVE_FILE)
	var store := SharedSettingsStore.new()
	store.reload()
	check(not store.poll(0))
	var edited: Dictionary = LIVE_FILE.duplicate(true)
	edited["settings"]["networkTables"]["host"] = "10.0.0.9"
	_write(edited)
	check(not store.poll(1000), "polls every 2 s")
	check(store.poll(2000))
	check_eq(store.current["nt"]["host"], "10.0.0.9")
	check(not store.poll(4000), "no change, no report")


func test_memory_only_never_touches_disk() -> void:
	var store := SharedSettingsStore.new("", true)
	check(store.save({"nt": {"host": "1.2.3.4"}, "reconnectTimeoutSeconds": 3}))
	check_eq(store.current["nt"]["host"], "1.2.3.4")
	check(not FileAccess.file_exists(file))


func test_settings_service_sees_external_edit_within_3s() -> void:
	_write(LIVE_FILE)
	var s := SettingsService.new()
	s.persist = false
	tree.root.add_child(s)
	check_eq(s.connection()["nt"]["host"], "10.47.65.2")
	var seen: Array = []
	s.changed.connect(func(section: String) -> void: seen.append(section))
	var edited: Dictionary = LIVE_FILE.duplicate(true)
	edited["settings"]["networkTables"]["host"] = "127.0.0.2"
	edited["version"] = 10
	_write(edited)
	var el := await wait_until(func() -> bool: return seen.has("connection"), 3.5)
	note("external edit seen after %.2f s" % el)
	check(el >= 0.0 and el <= 3.0, "picked up within 3 s (%.2f)" % el)
	check_eq(s.connection()["nt"]["host"], "127.0.0.2")
	check(s.set_connection({"nt": {"host": "127.0.0.3", "port": 5810, "sharedTable": "Shared", "selectedPathTopic": "PathPlanner/SelectedPath"}, "reconnectTimeoutSeconds": 10}))
	check_eq(_read()["version"], 11.0)
	check(s.reset_connection())
	check_eq(_read()["settings"]["networkTables"]["host"], "10.47.65.2", "Reset writes the schema defaults")
	check_eq(_read()["settings"]["host"], "192.168.252.2", "Reset keeps the Autobahn host")
	s.queue_free()
