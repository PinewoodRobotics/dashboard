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


func test_builtin_export_loads_lazily() -> void:
	var lib := AutoLibrary.load_best([root.path_join("missing"), AutoLibrary.BUILTIN_DIR])
	check(lib.is_loaded(), lib.error)
	check_eq(lib.dir, AutoLibrary.BUILTIN_DIR)
	check_eq(lib.names().size(), 9)
	check(lib.get_auto("Ball Shooter Left") == lib.get_auto("Ball Shooter Left"), "cached instance")
	check(lib.get_auto("No Such Auto") == null, "unknown auto")


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
