extends SceneTree

## Headless test runner. Usage:
##   godot --headless --path . --script res://tests/run_tests.gd -- --dir=unit [--filter=substr]
## Discovers test_*.gd files in res://tests/<dir>, runs every test_* method
## (coroutines are awaited) and exits non-zero on any failure.

var _filter := ""
var _dirs: PackedStringArray = []


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--dir="):
			_dirs.append(a.substr(6))
		elif a.begins_with("--filter="):
			_filter = a.substr(9)
	if _dirs.is_empty():
		_dirs.append("unit")
	_run.call_deferred()


func _list(dir_path: String) -> PackedStringArray:
	var out := PackedStringArray()
	var d := DirAccess.open(dir_path)
	if d == null:
		push_error("test dir not found: " + dir_path)
		return out
	for f in d.get_files():
		if f.begins_with("test_") and f.ends_with(".gd"):
			out.append(dir_path.path_join(f))
	out.sort()
	return out


func _run() -> void:
	var total := 0
	var failed := 0
	var failed_names: PackedStringArray = []
	var t_start := Time.get_ticks_msec()
	for dir_name in _dirs:
		for path in _list("res://tests".path_join(dir_name)):
			var script: GDScript = load(path)
			if script == null or not script.can_instantiate():
				print("LOAD ERROR ", path)
				failed += 1
				failed_names.append(path)
				continue
			var methods: PackedStringArray = []
			for m in script.get_script_method_list():
				var n: String = m["name"]
				if n.begins_with("test_") and not methods.has(n):
					methods.append(n)
			print("== ", path.get_file())
			for n in methods:
				var full := "%s::%s" % [path.get_file().get_basename(), n]
				if _filter != "" and not full.contains(_filter):
					continue
				var tc: TestCase = script.new()
				tc.tree = self
				total += 1
				var t0 := Time.get_ticks_msec()
				await tc.before_each()
				await tc.call(n)
				await tc.after_each()
				var ms := Time.get_ticks_msec() - t0
				if tc.failures.is_empty():
					print("  ok   %s (%d ms)" % [n, ms])
				else:
					failed += 1
					failed_names.append(full)
					print("  FAIL %s (%d ms)" % [n, ms])
					for f in tc.failures:
						print("       - ", f)
	print("\n%d tests, %d failed, %.1f s" % [total, failed, (Time.get_ticks_msec() - t_start) / 1000.0])
	for n in failed_names:
		print("FAILED ", n)
	quit(1 if failed > 0 or total == 0 else 0)
