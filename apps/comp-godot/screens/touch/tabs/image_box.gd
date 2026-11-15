class_name ImageBox
extends Control

## A 6 px rounded zinc-950 box that letterboxes its picture (rounded-md
## bg-zinc-950 overflow-hidden around an object-contain image: HowardTab.tsx,
## PathDetailPane.tsx). `outside` is the color around the box, painted over
## the corners to round the picture with the box.

const RADIUS := 6.0

var image: TextureRect
var mask: PwCornerMask


func _init(outside: Color = Tokens.PANEL) -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true
	image = TextureRect.new()
	image.name = "Image"
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(UiKit.full(image))
	mask = PwCornerMask.new(RADIUS, outside)
	add_child(mask)


func _draw() -> void:
	UiDraw.box(get_canvas_item(), Rect2(Vector2.ZERO, size), Tokens.ZINC_950, RADIUS)


## Keeps the corner mask above content added after construction.
func add_content(c: Control) -> void:
	add_child(c)
	move_child(mask, -1)
