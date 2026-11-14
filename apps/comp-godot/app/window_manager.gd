class_name WindowManager
extends RefCounted

## One process, up to two OS windows: the root window shows the first screen,
## a non-embedded child Window shows the touchscreen when --screen=both.
## Windows open windowed at two thirds of the design size.

const HUD_DESIGN := Vector2i(1920, 1080)
const TOUCH_DESIGN := Vector2i(1920, 515)
const DEV_SCALE := 2.0 / 3.0

const SCREENS := ["both", "hud", "touch"]


static func parse_screen(args: Dictionary) -> String:
	var s := str(args.get("screen", "both"))
	return s if SCREENS.has(s) else "both"


static func design_size(screen_name: String) -> Vector2i:
	return TOUCH_DESIGN if screen_name == "touch" else HUD_DESIGN


static func configure(window: Window, screen_name: String) -> void:
	var design := design_size(screen_name)
	window.content_scale_size = design
	window.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	window.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP


static func dev_size(screen_name: String) -> Vector2i:
	return Vector2i((Vector2(design_size(screen_name)) * DEV_SCALE).round())


## Root window: resized to the screen it hosts (the project default is the HUD).
static func setup_root(root: Window, screen_name: String) -> void:
	configure(root, screen_name)
	root.title = "PWRUP Comp - %s" % ("Touchscreen" if screen_name == "touch" else "HUD")
	if DisplayServer.get_name() != "headless":
		root.size = dev_size(screen_name)


static func create_touch_window(root: Window) -> Window:
	var w := Window.new()
	w.name = "TouchWindow"
	w.title = "PWRUP Comp - Touchscreen"
	configure(w, "touch")
	w.size = dev_size("touch")
	w.position = root.position + Vector2i(0, root.size.y + 40)
	w.transient = false
	w.wrap_controls = false
	w.close_requested.connect(func() -> void: root.get_tree().quit())
	return w
