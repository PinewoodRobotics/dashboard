class_name UiDraw
extends RefCounted

## 2D drawing that batches under the GL Compatibility canvas renderer, which
## issues one draw call per run of rects sharing a texture but one per polygon
## (StyleBoxFlat, draw_circle). Every shape and icon here is a textured rect
## cut from one shared atlas (rounded boxes as nine rects), so neighbouring
## shapes and icons cost one call. Text goes to child canvas items at a z above
## the shapes (text_z, one slot per font, MSDF so sizes share a texture), so a
## layer costs about one call per font instead of one per label. Stacked layers
## (overlays over the driver view, the drawer over both) step z by LAYER_Z.

const ATLAS_PX := 1024
const PAD := 2
const MAX_ICON_PX := 256
const LAYER_Z := 10
const TEXT_Z_FALLBACK := 8
const _MID := 2

static var _image: Image
static var _texture: ImageTexture
static var _cells := {}
static var _shelf := Vector3i.ZERO
static var _dirty := false
static var _full_reported := false
static var _solid_src := Rect2()


class TextItems:
	extends RefCounted
	var items := {}

	func _notification(what: int) -> void:
		if what == NOTIFICATION_PREDELETE:
			for rid: RID in items.values():
				RenderingServer.free_rid(rid)


static func texture() -> ImageTexture:
	if _texture == null:
		_image = Image.create_empty(ATLAS_PX, ATLAS_PX, false, Image.FORMAT_RGBA8)
		_texture = ImageTexture.create_from_image(_image)
		RenderingServer.frame_pre_draw.connect(_flush)
	return _texture


static func atlas_image() -> Image:
	texture()
	return _image


static func _flush() -> void:
	if _dirty:
		_dirty = false
		_texture.update(_image)


static func _alloc(key: String, w: int, h: int) -> Rect2i:
	texture()
	if _shelf.x + w + PAD > ATLAS_PX:
		_shelf = Vector3i(0, _shelf.y + _shelf.z, 0)
	if _shelf.y + h + PAD > ATLAS_PX:
		if not _full_reported:
			_full_reported = true
			push_error("UiDraw: atlas full, %s and later cells reuse the solid cell" % key)
		return Rect2i()
	var r := Rect2i(_shelf.x + PAD, _shelf.y + PAD, w, h)
	_shelf.x += w + PAD
	_shelf.z = maxi(_shelf.z, h + PAD)
	_cells[key] = r
	_dirty = true
	return r


static func _raster(key: String, w: int, h: int, coverage: Callable) -> Rect2i:
	if _cells.has(key):
		return _cells[key]
	var r := _alloc(key, w, h)
	if r.size == Vector2i.ZERO:
		return _solid()
	for y in h:
		for x in w:
			var a: float = coverage.call(Vector2(x + 0.5, y + 0.5))
			if a > 0.0:
				_image.set_pixel(r.position.x + x, r.position.y + y, Color(1, 1, 1, minf(a, 1.0)))
	return r


static func _rounded_sdf(p: Vector2, size: Vector2, radius: float) -> float:
	var q := (p - size * 0.5).abs() - size * 0.5 + Vector2(radius, radius)
	return q.max(Vector2.ZERO).length() + minf(maxf(q.x, q.y), 0.0) - radius


static func _cov(d: float) -> float:
	return clampf(0.5 - d, 0.0, 1.0)


static func _solid() -> Rect2i:
	return _fill_cell(0)


## A rounded square of corner c plus a 2 * _MID px straight middle that nine-slices.
static func _fill_cell(r: int) -> Rect2i:
	var s := 2 * r + 2 * _MID
	return _raster("fill%d" % r, s, s, func(p: Vector2) -> float: return _cov(_rounded_sdf(p, Vector2(s, s), r)))


static func _ring_cell(r: int, w: int) -> Rect2i:
	var c := maxi(r, w)
	var s := 2 * c + 2 * _MID
	var inner_r := maxf(r - w, 0.0)
	return _raster("ring%d_%d" % [r, w], s, s, func(p: Vector2) -> float:
		var outer := _cov(_rounded_sdf(p, Vector2(s, s), r))
		var inner := _cov(_rounded_sdf(p - Vector2(w, w), Vector2(s - 2 * w, s - 2 * w), inner_r))
		return outer - inner)


static func _shadow_cell(r: int, blur: int) -> Rect2i:
	var c := r + blur
	var s := 2 * c + 2 * _MID
	return _raster("shadow%d_%d" % [r, blur], s, s, func(p: Vector2) -> float:
		var d := _rounded_sdf(p - Vector2(blur, blur), Vector2(s - 2 * blur, s - 2 * blur), r)
		var t := clampf(1.0 - d / blur, 0.0, 1.0) if d > 0.0 else 1.0
		return t * t)


static func _diamond_cell(half: int, stroke: float) -> Rect2i:
	var s := 2 * half + 2
	return _raster("diamond%d_%s" % [half, stroke], s, s, func(p: Vector2) -> float:
		var q := (p - Vector2(s, s) * 0.5).abs()
		var d := (q.x + q.y - half) * 0.70710678
		return _cov(d) - (_cov(d + stroke) if stroke > 0.0 else 0.0))


static func _rid() -> RID:
	return texture().get_rid()


static func _blit(ci: RID, dst: Rect2, src: Rect2, color: Color) -> void:
	if dst.size.x <= 0.0 or dst.size.y <= 0.0:
		return
	RenderingServer.canvas_item_add_texture_rect_region(ci, dst, _rid(), src, color)


static func _nine(ci: RID, rect: Rect2, cell: Rect2i, c: int, color: Color, center: bool) -> void:
	var o := Vector2(cell.position)
	var s := float(cell.size.x)
	var m := float(c + _MID - 1)
	var x0 := rect.position.x
	var y0 := rect.position.y
	var x1 := rect.end.x
	var y1 := rect.end.y
	var mw := rect.size.x - 2 * c
	var mh := rect.size.y - 2 * c
	if c > 0:
		_blit(ci, Rect2(x0, y0, c, c), Rect2(o, Vector2(c, c)), color)
		_blit(ci, Rect2(x1 - c, y0, c, c), Rect2(o + Vector2(s - c, 0), Vector2(c, c)), color)
		_blit(ci, Rect2(x0, y1 - c, c, c), Rect2(o + Vector2(0, s - c), Vector2(c, c)), color)
		_blit(ci, Rect2(x1 - c, y1 - c, c, c), Rect2(o + Vector2(s - c, s - c), Vector2(c, c)), color)
		_blit(ci, Rect2(x0 + c, y0, mw, c), Rect2(o + Vector2(m, 0), Vector2(2, c)), color)
		_blit(ci, Rect2(x0 + c, y1 - c, mw, c), Rect2(o + Vector2(m, s - c), Vector2(2, c)), color)
		_blit(ci, Rect2(x0, y0 + c, c, mh), Rect2(o + Vector2(0, m), Vector2(c, 2)), color)
		_blit(ci, Rect2(x1 - c, y0 + c, c, mh), Rect2(o + Vector2(s - c, m), Vector2(c, 2)), color)
	if center:
		_blit(ci, Rect2(x0 + c, y0 + c, mw, mh), Rect2(o + Vector2(m, m), Vector2(2, 2)), color)


static func _fit_radius(rect: Rect2, radius: float) -> int:
	return clampi(roundi(radius), 0, floori(minf(rect.size.x, rect.size.y) * 0.5))


static func rect(ci: RID, r: Rect2, color: Color) -> void:
	if color.a <= 0.0:
		return
	if _solid_src.size == Vector2.ZERO:
		_solid_src = Rect2(Vector2(_solid().position) + Vector2(_MID - 1, _MID - 1), Vector2(2, 2))
	_blit(ci, r, _solid_src, color)


## Inside frame of `width` px along the edges of r (draw_rect unfilled, drawn inward).
static func frame(ci: RID, r: Rect2, color: Color, width: float) -> void:
	rect(ci, Rect2(r.position, Vector2(r.size.x, width)), color)
	rect(ci, Rect2(r.position.x, r.end.y - width, r.size.x, width), color)
	rect(ci, Rect2(r.position.x, r.position.y + width, width, r.size.y - 2 * width), color)
	rect(ci, Rect2(r.end.x - width, r.position.y + width, width, r.size.y - 2 * width), color)


## Rounded box like StyleBoxFlat: border inside the rect, fill inside the border.
static func box(ci: RID, r: Rect2, fill: Color, radius: float = 0.0, border: int = 0, border_color: Color = Color(0, 0, 0, 0)) -> void:
	var c := _fit_radius(r, radius)
	var w := border if border_color.a > 0.0 else 0
	if fill.a > 0.0:
		var inner := r.grow(-w)
		var ic := _fit_radius(inner, c - w)
		if ic == 0:
			rect(ci, inner, fill)
		else:
			_nine(ci, inner, _fill_cell(ic), ic, fill, true)
	if w > 0:
		if c == 0:
			frame(ci, r, border_color, w)
		else:
			_nine(ci, r, _ring_cell(c, w), maxi(c, w), border_color, false)


static func shadow(ci: RID, r: Rect2, radius: float, blur: int, color: Color) -> void:
	if blur <= 0 or color.a <= 0.0:
		return
	var c := _fit_radius(r, radius)
	_nine(ci, r.grow(blur), _shadow_cell(c, blur), c + blur, color, true)


static func circle(ci: RID, center: Vector2, radius: float, color: Color) -> void:
	var r := roundi(radius)
	if r <= 0 or color.a <= 0.0:
		return
	var cell := _fill_cell(r)
	_nine(ci, Rect2(center - Vector2(r, r), Vector2(2 * r, 2 * r)), cell, r, color, false)


## Square diamond of half-diagonal `half` px; stroke > 0 draws only the outline.
static func diamond(ci: RID, center: Vector2, half: int, color: Color, stroke: float = 0.0) -> void:
	var cell := _diamond_cell(half, stroke)
	_blit(ci, Rect2(center - Vector2(cell.size) * 0.5, Vector2(cell.size)), Rect2(cell), color)


## A white lucide icon cut from the atlas, to be drawn with a modulate color.
static func icon_texture(icon_name: String, px: int) -> Texture2D:
	var key := "icon:%s@%d" % [icon_name, px]
	if not _cells.has(key):
		if px > MAX_ICON_PX:
			return null
		var img := Icons.image(icon_name, px, Color.WHITE)
		if img == null:
			return null
		img.convert(Image.FORMAT_RGBA8)
		var r := _alloc(key, img.get_width(), img.get_height())
		if r.size == Vector2i.ZERO:
			return null
		_image.blit_rect(img, Rect2i(Vector2i.ZERO, img.get_size()), r.position)
	var at := AtlasTexture.new()
	at.atlas = texture()
	at.region = Rect2(_cells[key])
	return at


static func text_z(font: Font) -> int:
	return int(font.get_meta(&"text_z", TEXT_Z_FALLBACK)) if font != null else TEXT_Z_FALLBACK


## The child canvas item of `owner` that holds its text in `font`; cleared by begin().
static func text_item(owner: CanvasItem, font: Font) -> RID:
	var holder: TextItems = owner.get_meta(&"_ui_text") if owner.has_meta(&"_ui_text") else null
	if holder == null:
		holder = TextItems.new()
		owner.set_meta(&"_ui_text", holder)
	var z := text_z(font)
	if not holder.items.has(z):
		var rid := RenderingServer.canvas_item_create()
		RenderingServer.canvas_item_set_parent(rid, owner.get_canvas_item())
		RenderingServer.canvas_item_set_z_as_relative_to_parent(rid, true)
		RenderingServer.canvas_item_set_z_index(rid, z)
		holder.items[z] = rid
	return holder.items[z]


## Call first in a _draw() that uses text(): clears the text drawn last time.
static func begin(owner: CanvasItem) -> void:
	if owner.has_meta(&"_ui_text"):
		for rid: RID in (owner.get_meta(&"_ui_text") as TextItems).items.values():
			RenderingServer.canvas_item_clear(rid)


static func text(owner: CanvasItem, font: Font, pos: Vector2, s: String, px: int, color: Color,
		align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT, width: float = -1.0) -> void:
	if s == "" or color.a <= 0.0:
		return
	font.draw_string(text_item(owner, font), pos, s, align, width, px, color)


## Labels draw their text in their own canvas item, so they take their font's z.
static func layer_label(l: Label) -> void:
	if is_instance_valid(l) and l.is_inside_tree():
		l.z_index = text_z(l.get_theme_font(&"font"))
