extends SceneTree

## Copies the Howard pictures and captions from apps/comp (read only) into the
## Godot project, downscaled to MAX_SIDE px as lossy WebP.
## Usage: godot --headless --path . --script res://tools/assets/copy_howard.gd

const SRC_META := "../comp/public/path-overview/meta/error-images.json"
const SRC_DIR := "../comp/public/path-overview"
const OUT_DIR := "res://assets/images/howard"
const OUT_META := "res://data/howard/howard.json"
const MAX_SIDE := 1200


func _init() -> void:
	var app := ProjectSettings.globalize_path("res://")
	var meta: Variant = JSON.parse_string(FileAccess.get_file_as_string(app.path_join(SRC_META)))
	if typeof(meta) != TYPE_ARRAY:
		printerr("cannot read ", SRC_META)
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_META.get_base_dir()))
	var out: Array = []
	for e: Dictionary in meta:
		var rel := str(e["image"]).trim_prefix("/path-overview/")
		var img := Image.load_from_file(app.path_join(SRC_DIR).path_join(rel))
		if img == null or img.is_empty():
			printerr("cannot load ", rel)
			quit(1)
			return
		var s := float(MAX_SIDE) / maxf(img.get_width(), img.get_height())
		if s < 1.0:
			img.resize(int(img.get_width() * s), int(img.get_height() * s), Image.INTERPOLATE_LANCZOS)
		var dst := OUT_DIR.path_join(rel.get_file())
		img.save_webp(ProjectSettings.globalize_path(dst), true, 0.82)
		out.append({"image": dst, "text": e.get("text", ""), "happy_text": e.get("happy-text", "")})
	var f := FileAccess.open(OUT_META, FileAccess.WRITE)
	f.store_string(JSON.stringify(out, "  ", false) + "\n")
	f.close()
	print("copied %d pictures" % out.size())
	quit(0)
