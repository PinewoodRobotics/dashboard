class_name AutoStatusRow
extends Control

## PathListPane.tsx's loading, empty and error rows: 180 px of #3c3c3c with
## one centered 18 px line ("Failed to load. Tap to retry." in rose-400).

const HEIGHT := 180.0

var text: PwText


func _init(message: String, color: Color) -> void:
	name = "StatusRow"
	custom_minimum_size = Vector2(0, HEIGHT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	text = PwText.new(message, 18, 400, color)
	text.align = HORIZONTAL_ALIGNMENT_CENTER
	add_child(text)
	resized.connect(_place)


func _place() -> void:
	var h := text.fit_width(size.x - 20)
	text.position = Vector2(10, (size.y - h) * 0.5)


func _draw() -> void:
	UiDraw.rect(get_canvas_item(), Rect2(Vector2.ZERO, size), Tokens.CARD)
