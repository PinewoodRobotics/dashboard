class_name HowardTab
extends Control

## HowardTab.tsx: a third-width column (16 px padding) with the title and the
## picture's caption at the top and "More Howard" at the bottom, the picture
## letterboxed in a rounded box filling the rest. "More Howard" always picks a
## different picture.

const DATA := "res://data/howard/howard.json"
const PAD := 16

var entries: Array = []
var index := -1
var rng := RandomNumberGenerator.new()
var image: TextureRect
var caption: PwText
var more: PwButton
var _left: Control
var _right: Control
var _loading: PwText


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
	add_child(UiKit.full(PwRect.new(Tokens.PANEL)))
	var col := UiKit.vbox(0)
	var top := UiKit.vbox(10)
	top.add_child(PwText.new("Pictures of Howard", 34, 600, Tokens.TEXT, 34.0))
	caption = PwText.new("", 22, 400, Tokens.ZINC_300, 26.4)
	caption.name = "Caption"
	top.add_child(caption)
	col.add_child(top)
	var push := Control.new()
	push.mouse_filter = Control.MOUSE_FILTER_IGNORE
	push.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(push)
	more = PwButton.new("More Howard", PwButton.Style.DARK)
	more.name = "More"
	more.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	more.pressed.connect(next_picture)
	col.add_child(more)
	_left = UiKit.margin(col, PAD, PAD, PAD, PAD)
	add_child(_left)
	var box := ImageBox.new()
	box.name = "Frame"
	image = box.image
	_right = UiKit.margin(box, PAD, PAD, PAD, PAD)
	add_child(_right)
	_loading = PwText.new("Loading...", 34, 400, Tokens.ZINC_500)
	_loading.wrap = PwText.Wrap.NONE
	_loading.align = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_loading)
	resized.connect(_layout)
	_layout()
	show_index(pick_other(-1, entries.size(), rng))


func _layout() -> void:
	var left_w := size.x / 3.0
	_left.position = Vector2.ZERO
	_left.size = Vector2(left_w, size.y)
	_right.position = Vector2(left_w, 0)
	_right.size = Vector2(size.x - left_w, size.y)
	var lh := _loading.get_combined_minimum_size().y
	_loading.position = Vector2(0, (size.y - lh) * 0.5)
	_loading.size = Vector2(size.x, lh)


func next_picture() -> void:
	show_index(pick_other(index, entries.size(), rng))


func show_index(i: int) -> void:
	var empty := entries.is_empty()
	_left.visible = not empty
	_right.visible = not empty
	_loading.visible = empty
	if empty:
		return
	index = clampi(i, 0, entries.size() - 1)
	var e: Dictionary = entries[index]
	caption.text = str(e.get("happy_text", ""))
	image.texture = load(str(e.get("image", ""))) as Texture2D
