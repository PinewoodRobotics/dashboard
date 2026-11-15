extends TestCase

## Fonts are the bundled OFL Inter and Roboto Mono plus the SF Pro cut of
## tools/fonts/build_sf_symbols.sh (never the 26 MB variable file); SF Symbols
## are written as code point constants, so no private-use character sits in a
## source file; HUD icons are lucide.

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
	check_eq(fonts, PackedStringArray(["Inter-300.ttf", "Inter-400.ttf", "Inter-500.ttf", "Inter-600.ttf", "Inter-700.ttf", "RobotoMono-400.ttf", "RobotoMono-500.ttf", "SF-Pro-400.ttf"]))
	check(FileAccess.file_exists("res://ui/fonts/OFL-Inter.txt") and FileAccess.file_exists("res://ui/fonts/OFL-RobotoMono.txt"), "OFL license texts bundled")
	check_eq((Tokens.mono().base_font as FontFile).get_font_name(), "Roboto Mono")
	check_eq((Tokens.inter().base_font as FontFile).get_font_name(), "Inter")


func test_sf_pro_is_the_symbol_cut_and_no_private_use_glyphs() -> void:
	var sf := FileAccess.get_file_as_bytes("res://ui/fonts/SF-Pro-400.ttf")
	check(sf.size() > 0 and sf.size() < 512 * 1024, "SF Pro is the subset, not the variable font (%d bytes)" % sf.size())
	var font := Tokens.sf().base_font as FontFile
	check_eq(font.get_font_name(), "SF Pro")
	for info: Dictionary in TabDefs.TAB_INFO.values() + TabDefs.PANEL_INFO.values() + [TabDefs.HOME_INFO, TabDefs.DOCK_INFO]:
		for key: String in ["symbol", "active_symbol"]:
			check(font.has_char(int(info[key])), "SF Pro has U+%X" % int(info[key]))
	for sym: int in [Sf.MODE_DRIVER, Sf.MODE_DRIVER_FILL, Sf.MODE_FOLLOW, Sf.MODE_FOLLOW_FILL, Sf.TOGGLE_OFF, Sf.TOGGLE_ON, 0x2122]:
		check(font.has_char(sym), "SF Pro has U+%X" % sym)
	for f in _files():
		if not TEXT_EXT.has(f.get_extension().to_lower()):
			continue
		var text := FileAccess.get_file_as_string(f)
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
