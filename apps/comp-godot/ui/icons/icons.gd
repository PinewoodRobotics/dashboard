class_name Icons
extends RefCounted

## Lucide icons from ui/icons/lucide.json (tools/icons/build_icons.mjs),
## rasterized at the exact pixel size and color they are drawn at, and cached.
## Up to ATLAS_MAX_PX every icon of one size and color shares an atlas, so
## neighbouring icons batch into one canvas draw call.

const SOURCE := "res://ui/icons/lucide.json"

const ATLAS_MAX_PX := 64
const ATLAS_COLS := 8
const ATLAS_PAD := 2

static var _svgs := {}
static var _cache := {}
static var _atlases := {}


static func _load() -> void:
	if not _svgs.is_empty():
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(SOURCE))
	if typeof(parsed) == TYPE_DICTIONARY and typeof(parsed.get("icons")) == TYPE_DICTIONARY:
		_svgs = parsed["icons"]
	else:
		push_error("icons: cannot read " + SOURCE)


static func has(name: String) -> bool:
	_load()
	return _svgs.has(name)


static func names() -> PackedStringArray:
	_load()
	return PackedStringArray(_svgs.keys())


static func svg(name: String, px: int, color: Color) -> String:
	_load()
	var src: String = _svgs.get(name, "")
	return src.replace('width="24"', 'width="%d"' % px).replace('height="24"', 'height="%d"' % px).replace("currentColor", "#" + color.to_html(false))


static func image(name: String, px: int, color: Color) -> Image:
	if not has(name):
		push_error("icons: unknown lucide icon " + name)
		return null
	var img := Image.new()
	var err := img.load_svg_from_string(svg(name, px, color), 1.0)
	if err != OK:
		push_error("icons: rasterize %s failed (%s)" % [name, error_string(err)])
		return null
	if color.a < 1.0:
		img.convert(Image.FORMAT_RGBA8)
		for y in img.get_height():
			for x in img.get_width():
				var c := img.get_pixel(x, y)
				c.a *= color.a
				img.set_pixel(x, y, c)
	return img


static func texture(name: String, px: int, color: Color) -> Texture2D:
	var key := "%s|%d|%s" % [name, px, color.to_html(true)]
	if px <= ATLAS_MAX_PX and not _cache.has(key) and has(name):
		var atlas := _atlas(px, color)
		var i := names().find(name)
		var cell := px + ATLAS_PAD
		var at := AtlasTexture.new()
		at.atlas = atlas
		at.region = Rect2((i % ATLAS_COLS) * cell, (i / ATLAS_COLS) * cell, px, px)
		_cache[key] = at
	if not _cache.has(key):
		var img := image(name, px, color)
		_cache[key] = ImageTexture.create_from_image(img) if img != null else null
	return _cache[key]


static func _atlas(px: int, color: Color) -> ImageTexture:
	var key := "%d|%s" % [px, color.to_html(true)]
	if not _atlases.has(key):
		var all := names()
		var cell := px + ATLAS_PAD
		var rows := ceili(float(all.size()) / ATLAS_COLS)
		var sheet := Image.create_empty(ATLAS_COLS * cell, rows * cell, false, Image.FORMAT_RGBA8)
		for i in all.size():
			var img := image(all[i], px, color)
			if img == null:
				continue
			img.convert(Image.FORMAT_RGBA8)
			sheet.blit_rect(img, Rect2i(Vector2i.ZERO, img.get_size()), Vector2i((i % ATLAS_COLS) * cell, (i / ATLAS_COLS) * cell))
		_atlases[key] = ImageTexture.create_from_image(sheet)
	return _atlases[key]
