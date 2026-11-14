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
