extends TestCase

var dir := ""


func before_each() -> void:
	dir = ProjectSettings.globalize_path("res://.scratch/unit")
	DirAccess.make_dir_recursive_absolute(dir)
	var gd := ProjectSettings.globalize_path("res://.scratch/.gdignore")
	if not FileAccess.file_exists(gd):
		FileAccess.open(gd, FileAccess.WRITE).close()


func test_map_normalization() -> void:
	check_eq(AppSettings.normalize_map(null), {"mode": "follow", "angle": 0.3, "zoom": 0.5})
	check_eq(AppSettings.normalize_map({"mode": "driver", "angle": 2, "zoom": -1}), {"mode": "driver", "angle": 1.0, "zoom": 0.0})
	check_eq(AppSettings.normalize_map({"mode": "orbit", "angle": "x", "zoom": NAN}), {"mode": "follow", "angle": 0.3, "zoom": 0.5})


func test_set_map_signals_and_persists_atomically() -> void:
	var path := dir.path_join("settings_%d.json" % Time.get_ticks_usec())
	var s := SettingsService.new()
	s.path = path
	tree.root.add_child(s)
	var seen: Array = []
	s.changed.connect(func(section: String) -> void: seen.append(section))
	var live := s.map()
	s.set_map({"zoom": 0.8})
	check_eq(seen, ["map"])
	check_eq(live["zoom"], 0.8, "readers holding map() see the change")
	s.set_map({"zoom": 0.8})
	check_eq(seen, ["map"], "no signal without a change")
	check(s.save_now())
	check(not FileAccess.file_exists(path + ".tmp"))
	var s2 := SettingsService.new()
	s2.path = path
	s2.load_file()
	check_eq(s2.map()["zoom"], 0.8)
	s.queue_free()
	s2.free()
	DirAccess.remove_absolute(path)


func test_visual_and_layout_normalization() -> void:
	check_eq(AppSettings.normalize_visual(null), {"render_scale": 1.0, "msaa": 2, "fps_cap": 60, "auto_quality": true})
	check_eq(AppSettings.normalize_visual({"render_scale": 0.5, "msaa": 4, "fps_cap": 30, "auto_quality": false}), {"render_scale": 0.5, "msaa": 4, "fps_cap": 30, "auto_quality": false})
	check_eq(AppSettings.normalize_visual({"render_scale": 0.6, "msaa": 8, "fps_cap": "60", "auto_quality": "no"}), {"render_scale": 1.0, "msaa": 2, "fps_cap": 60, "auto_quality": true}, "only the listed values")
	check_eq(AppSettings.normalize_layout({"rail": ["record", "visual", "visual", "auto"], "dock": ["visual", "record", "auto"]}),
		{"rail": ["visual", "auto"], "dock": ["visual", "auto", "settings", "effects", "howard", "robot3d"]}, "record dropped, dock completed")
	check_eq(AppSettings.normalize_layout({"rail": [], "dock": "junk"}), {"rail": [], "dock": TabDefs.TABS}, "an empty rail is allowed")
	check_eq(AppSettings.normalize_layout("junk"), AppSettings.default_layout())
	check_eq(AppSettings.normalize_layout({"dock": []})["rail"], ["auto", "settings"], "missing rail is the default")


func test_corrupt_file_loads_defaults_and_layout_round_trips() -> void:
	var path := dir.path_join("settings_%d.json" % Time.get_ticks_usec())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("{not json")
	f.close()
	var s := SettingsService.new()
	s.path = path
	s.load_file()
	check_eq(s.data, AppSettings.defaults())
	s.set_layout(["howard", "record"], ["record", "visual"])
	s.set_visual({"render_scale": 0.25})
	check(s.save_now())
	var s2 := SettingsService.new()
	s2.path = path
	s2.load_file()
	check_eq(s2.layout(), {"rail": ["howard"], "dock": ["visual", "auto", "settings", "effects", "howard", "robot3d"]})
	check_eq(s2.visual()["render_scale"], 0.25)
	s.free()
	s2.free()
	DirAccess.remove_absolute(path)
