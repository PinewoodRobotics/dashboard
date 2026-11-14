extends TestCase

## Fonts are the bundled OFL Inter and Roboto Mono; no SF Pro file and no
## private-use (SF Symbols) codepoint anywhere in the project; HUD icons are lucide.

const SKIP_DIRS := [".godot", ".scratch", ".screenshots", "node_modules", "build"]
const TEXT_EXT := ["gd", "gdshader", "gdshaderinc", "json", "tscn", "tres", "cfg", "godot", "md", "py", "mjs", "sh", "java", "txt"]


func _walk(dir: String, out: PackedStringArray) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	d.include_hidden = true
	for f in d.get_files():
		out.append(dir.path_join(f))
	for sub in d.get_directories():
		if not SKIP_DIRS.has(sub) and sub != ".git":
			_walk(dir.path_join(sub), out)


func _files() -> PackedStringArray:
	var out := PackedStringArray()
	_walk(ProjectSettings.globalize_path("res://"), out)
	return out


func test_only_bundled_ofl_fonts() -> void:
	var fonts := PackedStringArray()
	for f in _files():
		if ["ttf", "otf", "ttc", "woff", "woff2"].has(f.get_extension().to_lower()):
			fonts.append(f.get_file())
	fonts.sort()
	check_eq(fonts, PackedStringArray(["Inter-300.ttf", "Inter-400.ttf", "Inter-500.ttf", "Inter-600.ttf", "Inter-700.ttf", "RobotoMono-400.ttf", "RobotoMono-500.ttf"]))
	check(FileAccess.file_exists("res://ui/fonts/OFL-Inter.txt") and FileAccess.file_exists("res://ui/fonts/OFL-RobotoMono.txt"), "OFL license texts bundled")
	check_eq((Tokens.mono().base_font as FontFile).get_font_name(), "Roboto Mono")
	check_eq((Tokens.inter().base_font as FontFile).get_font_name(), "Inter")


func test_no_sf_pro_and_no_private_use_glyphs() -> void:
	for f in _files():
		var name := f.get_file().to_lower()
		check(not name.begins_with("sf-") and not name.begins_with("sfpro") and not name.begins_with("sf_pro"), "no SF font file: " + f)
		if not TEXT_EXT.has(f.get_extension().to_lower()):
			continue
		var text := FileAccess.get_file_as_string(f)
		check(not text.contains("SF-Pro" + ".ttf"), "no SF Pro font reference in " + f)
		for i in text.length():
			var c := text.unicode_at(i)
			if (c >= 0xE000 and c <= 0xF8FF) or c >= 0xF0000:
				fail("private-use codepoint U+%X in %s" % [c, f])
				break


func test_hud_icons_are_lucide() -> void:
	var used: Array = [Tokens.LANE_ICON]
	for aim: int in Tokens.AIM_ICONS:
		used.append(Tokens.AIM_ICONS[aim]["icon"])
	check_eq(used.size(), 4)
	var src: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(Icons.SOURCE))
	check_eq(src["source"], "lucide-static")
	for n: String in used:
		check(Icons.has(n), "%s is in lucide.json" % n)
		var img := Icons.image(n, 48, Color.WHITE)
		check(img != null and img.get_width() == 48 and img.get_height() == 48, "%s rasterizes at exactly 48 px" % n)
