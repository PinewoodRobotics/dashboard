class_name HowardTab
extends Control

## HowardTab.tsx: a random picture of Howard; "More Howard" always picks a
## different one.

const DATA := "res://data/howard/howard.json"

var entries: Array = []
var index := -1
var rng := RandomNumberGenerator.new()
var image: TextureRect
var caption: Label
var more: PwButton


static func load_entries() -> Array:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(DATA))
	return parsed if typeof(parsed) == TYPE_ARRAY else []


static func pick_other(current: int, count: int, gen: RandomNumberGenerator) -> int:
	if count <= 1:
		return 0
	var i := gen.randi_range(0, count - 2)
	return i + 1 if i >= current and current >= 0 else i


func _ready() -> void:
	entries = load_entries()
	var bg := ColorRect.new()
	bg.color = Tokens.PANEL
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(UiKit.full(bg))
	var row := UiKit.hbox(16)
	var left := UiKit.vbox(16)
	left.custom_minimum_size.x = 520
	left.add_child(UiKit.label("Pictures of Howard", 34, 600))
	caption = UiKit.wrapped("", 22, Tokens.ZINC_300)
	caption.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(caption)
	more = PwButton.new("More Howard", PwButton.Style.DARK, Vector2(0, 72))
	more.name = "More"
	more.font_size = 34
	more.pressed.connect(next_picture)
	left.add_child(more)
	row.add_child(left)
	var frame := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Tokens.ZINC_950
	sb.set_corner_radius_all(12)
	sb.set_content_margin_all(8)
	frame.add_theme_stylebox_override("panel", sb)
	frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	image = TextureRect.new()
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	frame.add_child(image)
	row.add_child(frame)
	add_child(UiKit.full(UiKit.margin(row, 16, 16, 16, 16)))
	show_index(pick_other(-1, entries.size(), rng))


func next_picture() -> void:
	show_index(pick_other(index, entries.size(), rng))


func show_index(i: int) -> void:
	if entries.is_empty():
		caption.text = "No pictures found"
		return
	index = clampi(i, 0, entries.size() - 1)
	var e: Dictionary = entries[index]
	caption.text = str(e.get("happy_text", ""))
	image.texture = load(str(e.get("image", ""))) as Texture2D
