extends TestCase

const AT := "2026-11-14T12:00:00Z"
const HASH := "3e03068c8f377014417fb19d87aa685f6bdf1c078e85db1650972f7c88b9a807"

var now := 0.0


func before_each() -> void:
	now = Time.get_unix_time_from_datetime_string("2026-11-14T12:00:00")


func test_age_without_a_robot_hash() -> void:
	var f := ExportFreshness.check(AT, HASH, null, now + 2.5 * 3600.0)
	check_eq(f["level"], ExportFreshness.Level.FRESH)
	check_eq(f["text"], "2 h ago")
	check_eq(ExportFreshness.check(AT, HASH, null, now + 30.0)["text"], "1 min ago")
	var old := ExportFreshness.check(AT, HASH, "", now + 4 * 86400.0)
	check_eq(old["level"], ExportFreshness.Level.OLD)
	check_eq(old["text"], "4 d old")


func test_unknown_or_future_time_shows_no_age() -> void:
	for at in ["", "garbage", "2999-01-02T03:04:00Z"]:
		var f := ExportFreshness.check(at, HASH, null, now)
		check_eq(f["level"], ExportFreshness.Level.FRESH, at)
		check_eq(f["text"], "", at)


func test_robot_hash_decides_over_age() -> void:
	var same := ExportFreshness.check(AT, HASH, HASH.to_upper(), now + 30 * 86400.0)
	check_eq(same["level"], ExportFreshness.Level.MATCHES_ROBOT)
	check_eq(same["text"], "matches robot")
	var diff := ExportFreshness.check(AT, HASH, "deadbeef", now + 60.0)
	check_eq(diff["level"], ExportFreshness.Level.DIFFERS)
	check_eq(diff["text"], "differs from robot")
	check_eq(ExportFreshness.check(AT, "", "deadbeef", now)["level"], ExportFreshness.Level.DIFFERS, "an export without a hash never matches")


func test_builtin_export_hash_matches_its_raw_files() -> void:
	var lib := AutoLibrary.load_best([AutoLibrary.BUILTIN_DIR])
	check_eq(lib.exported_source_hash(), AutoLibrary.source_hash("res://data/pathplanner"))
