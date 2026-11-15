class_name HowardError
extends Control

## PathDetailPane.tsx's failed preview: a random picture of Howard letterboxed
## over the box, and centered on it a black/60 caption box (12 px sides, 4 px
## top and bottom, as wide as its longest line allows) with "Failed to load
## preview" (28 px semibold), the picture's unhappy line (18 px) and the small
## print (12 px on 12 px lines, "not" bold italic).

const PAD := Vector2(12, 4)

var image: TextureRect
var heading: PwText
var line: PwText
var small: PwText
var _box: VBoxContainer
var _rng := RandomNumberGenerator.new()
var _entries: Array = []
var _width := 0.0


func _init() -> void:
	name = "HowardError"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	image = TextureRect.new()
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(UiKit.full(image))
	_box = UiKit.vbox(0)
	heading = _centered(PwText.new("Failed to load preview", 28, 600, Tokens.TEXT))
	_box.add_child(heading)
	line = _centered(PwText.new("", 18, 600, Tokens.TEXT, 28.0))
	_box.add_child(line)
	small = _centered(PwText.new("", 12, 600, Tokens.TEXT, 12.0))
	var italic := Tokens.text_font(700).duplicate() as FontVariation
	italic.variation_transform = Transform2D(Vector2(1, 0), Vector2(-0.25, 1), Vector2.ZERO)
	small.spans = [{"text": "The error does "}, {"text": "not", "font": italic},
		{"text": " mean the auto is broken, you can select it and it'll probably still work?"}]
	_box.add_child(UiKit.margin(small, 0, 8, 0, 0))
	add_child(_box)
	resized.connect(_layout)
	_box.minimum_size_changed.connect(_place_box)


static func _centered(t: PwText) -> PwText:
	t.align = HORIZONTAL_ALIGNMENT_CENTER
	return t


## Re-rolls the picture, as the web does for every failed auto.
func roll() -> void:
	if _entries.is_empty():
		_entries = HowardTab.load_entries()
	if _entries.is_empty():
		line.text = "Howard is unhappy now"
		return
	var e: Dictionary = _entries[_rng.randi_range(0, _entries.size() - 1)]
	image.texture = load(str(e.get("image", ""))) as Texture2D
	line.text = str(e.get("text", ""))
	_layout()


func _layout() -> void:
	var widest := 0.0
	for t: PwText in [heading, line, small]:
		var saved := t.wrap
		t.wrap = PwText.Wrap.NONE
		widest = maxf(widest, t.get_combined_minimum_size().x)
		t.wrap = saved
		t.update_minimum_size()
	_width = minf(ceilf(widest), size.x - 2.0 * PAD.x)
	_place_box()


func _place_box() -> void:
	_box.size = Vector2(_width, 0)
	var h := _box.get_combined_minimum_size().y
	_box.size = Vector2(_width, h)
	_box.position = ((size - _box.size) * 0.5).round()
	queue_redraw()


func _draw() -> void:
	var r := Rect2(_box.position - PAD, _box.size + 2.0 * PAD)
	UiDraw.rect(get_canvas_item(), r, Color(0, 0, 0, 0.6))
