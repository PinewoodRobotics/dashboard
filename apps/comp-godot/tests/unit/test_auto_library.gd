extends TestCase

var root := ""


func before_each() -> void:
	root = ProjectSettings.globalize_path("res://.scratch/unit/autos_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(root)


func _copy_export(to: String, exported_at: String) -> void:
	DirAccess.make_dir_recursive_absolute(to)
	var src := ProjectSettings.globalize_path(AutoLibrary.BUILTIN_DIR)
	for f in DirAccess.get_files_at(src):
		if f.ends_with(".json"):
			DirAccess.copy_absolute(src.path_join(f), to.path_join(f))
	var idx: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(to.path_join("index.json")))
	idx["exported_at"] = exported_at
	var out := FileAccess.open(to.path_join("index.json"), FileAccess.WRITE)
	out.store_string(JSON.stringify(idx))
	out.close()


func test_builtin_export_loads() -> void:
	var lib := AutoLibrary.load_best([root.path_join("missing"), AutoLibrary.BUILTIN_DIR])
	check(lib.is_loaded(), lib.error)
	check_eq(lib.dir, AutoLibrary.BUILTIN_DIR)
	check_eq(lib.names().size(), 9)
	check(lib.get_auto("Ball Shooter Left") == lib.get_auto("Ball Shooter Left"), "cached instance")
	check(lib.get_auto("No Such Auto") == null, "unknown auto")
	for n in lib.names():
		check_eq(lib.auto_error(n), "", n)
		check_eq(lib.auto_note(n), "", n)


func test_newer_user_export_wins() -> void:
	var builtin := AutoLibrary.new()
	builtin.load_dir(AutoLibrary.BUILTIN_DIR)
	var user := root.path_join("user_new")
	_copy_export(user, "2999-01-01T00:00:00Z")
	var lib := AutoLibrary.load_best([user, AutoLibrary.BUILTIN_DIR])
	check_eq(lib.dir, user, "newer user export is used")
	var older := root.path_join("user_old")
	_copy_export(older, "2000-01-01T00:00:00Z")
	check_eq(AutoLibrary.load_best([older, AutoLibrary.BUILTIN_DIR]).dir, AutoLibrary.BUILTIN_DIR, "older user export is ignored")
	var same := root.path_join("user_same")
	_copy_export(same, builtin.exported_at())
	check_eq(AutoLibrary.load_best([same, AutoLibrary.BUILTIN_DIR]).dir, same, "a tie prefers the user export")


func test_broken_user_export_falls_back() -> void:
	var broken := root.path_join("broken")
	_copy_export(broken, "2999-01-01T00:00:00Z")
	DirAccess.remove_absolute(broken.path_join("Stay And Shoot.json"))
	var lib := AutoLibrary.load_best([broken, AutoLibrary.BUILTIN_DIR])
	check_eq(lib.dir, AutoLibrary.BUILTIN_DIR)
	var wrong := root.path_join("wrong_version")
	_copy_export(wrong, "2999-01-01T00:00:00Z")
	var idx: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(wrong.path_join("index.json")))
	idx["version"] = 99
	var f := FileAccess.open(wrong.path_join("index.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(idx))
	f.close()
	check_eq(AutoLibrary.load_best([wrong, AutoLibrary.BUILTIN_DIR]).dir, AutoLibrary.BUILTIN_DIR)
	var none := AutoLibrary.load_best([root.path_join("nothing")])
	check(not none.is_loaded(), "no export")
	check(none.error.begins_with("no valid auto export"), none.error)


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _edit_auto(dir: String, auto_name: String, edit: Callable) -> void:
	var path := dir.path_join(auto_name + ".json")
	var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	edit.call(d)
	_write(path, JSON.stringify(d))


func test_broken_auto_falls_back_to_the_older_export_once() -> void:
	var user := root.path_join("truncated")
	_copy_export(user, "2999-01-01T00:00:00Z")
	var path := user.path_join("Ball Shooter Left.json")
	var text := FileAccess.get_file_as_string(path)
	_write(path, text.left(text.length() / 2))
	_edit_auto(user, "Move Forward And Shoot Left", func(d: Dictionary) -> void: d["samples"]["blue"].erase("omega"))
	var lib := AutoLibrary.load_best([user, AutoLibrary.BUILTIN_DIR])
	check_eq(lib.dir, user, "the rest of the newer export is still used")
	check_eq(lib.fallbacks.size(), 1)
	for n in ["Ball Shooter Left", "Move Forward And Shoot Left"]:
		var p := lib.get_auto(n)
		check(p != null and p.has_path(), "%s comes from the built-in export" % n)
		check_eq(lib.auto_error(n), "", n)
		check(lib.auto_note(n).begins_with("Event update file is broken"), lib.auto_note(n))
		check(lib.auto_note(n).contains("built-in"), lib.auto_note(n))
	check(lib.auto_note("Ball Shooter Left").contains("not valid JSON"), lib.auto_note("Ball Shooter Left"))
	check(lib.auto_note("Move Forward And Shoot Left").contains("omega"), lib.auto_note("Move Forward And Shoot Left"))
	check_eq(lib.auto_note("Ball Shooter Right"), "")
	var first := lib.get_auto("Ball Shooter Left")
	DirAccess.remove_absolute(path)
	check(lib.get_auto("Ball Shooter Left") == first, "the outcome is cached, the file is not read again")


func test_broken_auto_without_fallback_reports_an_error() -> void:
	var user := root.path_join("new_only")
	_copy_export(user, "2999-01-01T00:00:00Z")
	_edit_auto(user, "Climber Right Left", func(d: Dictionary) -> void: d["samples"]["red"]["omega"].resize(10))
	_edit_auto(user, "Climber Right Middle", func(d: Dictionary) -> void: d["samples"]["red"]["y"][3] = "x")
	var lib := AutoLibrary.load_best([user])
	check(lib.get_auto("Climber Right Left") == null, "no preview")
	check(lib.auto_error("Climber Right Left").contains("red omega has 10 samples"), lib.auto_error("Climber Right Left"))
	check(lib.auto_error("Climber Right Middle").contains("non-numeric red y"), lib.auto_error("Climber Right Middle"))
	check(lib.get_auto("Stay And Shoot") != null, "other autos still load")


func test_validate_rejects_what_from_dict_cannot_play() -> void:
	var good: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(AutoLibrary.BUILTIN_DIR.path_join("Move Forward And Shoot Left.json")))
	check_eq(AutoPlayback.validate(good), "")
	var stay: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(AutoLibrary.BUILTIN_DIR.path_join("Stay And Shoot.json")))
	check_eq(AutoPlayback.validate(stay), "", "no path is fine")
	check_eq(AutoPlayback.validate([]), "not a JSON object")
	var cases := {
		"bad dt": func(d: Dictionary) -> void: d["dt"] = 0,
		"bad duration_s": func(d: Dictionary) -> void: d.erase("duration_s"),
		"bad event": func(d: Dictionary) -> void: d["events"][0].erase("t1"),
		"no blue samples": func(d: Dictionary) -> void: d["samples"]["blue"] = null,
		"missing red samples: heading": func(d: Dictionary) -> void: d["samples"]["red"].erase("heading"),
		"bad start_pose": func(d: Dictionary) -> void: d["start_pose"]["blue"] = [1, 2],
	}
	for want: String in cases:
		var d := good.duplicate(true)
		cases[want].call(d)
		check_eq(AutoPlayback.validate(d), want)


func test_meta_covers_every_auto() -> void:
	var lib := AutoLibrary.load_best([AutoLibrary.BUILTIN_DIR])
	for n in lib.names():
		check(lib.meta.has(n), "meta for " + n)
		check(lib.description(n) != "", "description for " + n)
	check_eq(lib.display_name("Climber Right Left"), "Climber Left to Right")
	check_eq(lib.display_name("Unknown"), "Unknown")


func test_service_preview_drives_the_shared_clock() -> void:
	var s := AutosService.new()
	s.time_source.freeze(0)
	tree.root.add_child(s)
	check_eq(s.library.names().size(), 9)
	s.set_preview("Move Forward And Shoot Center")
	check_near(s.clock.duration, s.preview().timeline_s(), 1e-12)
	s.clock.play()
	s.step()
	s.time_source.advance_s(0.5)
	s.step()
	check_near(s.clock.t, 0.5, 1e-9)
	s.set_preview("Stay And Shoot")
	check_eq(s.clock.duration, 20.0)
	check_eq(s.clock.t, 0.0)
	check(not s.clock.playing, "a new preview pauses")
	s.queue_free()
	await tree.process_frame
