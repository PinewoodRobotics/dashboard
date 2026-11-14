extends Node

## Composes the screens from CLI args (after `--`):
##   --screen=both|hud|touch   both: HUD in the root window, touchscreen in a second OS window
##   --nt-host=H --nt-port=P   override the shared connection settings without persisting
##   --fixture=NAME|PATH       offline: inject a fixture's NT values, never open a socket
##                             (with --live: fixture views and probes over live NT)
##   --debug-overlay           show the F3 NetworkTables overlay at start
##   --design-size             open windows at the design size instead of two thirds of it
## Screenshot, perf and probe flags are documented in services/dev_service.gd.

var screen := "both"
var windows := {}
var hud: HudScreen
## Untyped and loaded on demand so --screen=hud never compiles the touchscreen.
const TOUCH_SCREEN := "res://screens/touch/touch_screen.gd"
var touch: Control
var _overlay: DebugOverlay
var _args := {}


func _ready() -> void:
	_args = CliArgs.parse(OS.get_cmdline_user_args())
	screen = WindowManager.parse_screen(_args)
	var root := get_window()
	WindowManager.setup_root(root, screen, _args.has("design_size"))
	_apply_frame_policy()
	_start_nt()

	if screen == "touch":
		windows["touch"] = root
	else:
		hud = HudScreen.new()
		add_child(hud)
		windows["hud"] = root
		if screen == "both":
			var w := WindowManager.create_touch_window(root, _args.has("design_size"))
			add_child(w)
			windows["touch"] = w
			var vs := DisplayServer.VSYNC_ENABLED if str(_args.get("vsync", "hud")) == "both" else DisplayServer.VSYNC_DISABLED
			DisplayServer.window_set_vsync_mode(vs, w.get_window_id())

	_overlay = DebugOverlay.new(NT)
	_overlay.visible = _args.has("debug_overlay")
	add_child(_overlay)

	if windows.has("touch"):
		# Compiling the touchscreen scripts costs about 100 ms; the first frame
		# (the HUD in --screen=both) goes out before that.
		await RenderingServer.frame_post_draw
		touch = load(TOUCH_SCREEN).new()
		var host: Node = self if screen == "touch" else windows["touch"]
		host.add_child(touch)

	Dev.attach(self)


func _start_nt() -> void:
	if Dev.offline_fixture():
		NT.inject(Dev.fixture_nt(), Dev.fixture.get("nt_link", "up") != "down")
		return
	_apply_connection()
	Settings.changed.connect(func(section: String) -> void:
		if section == "connection":
			_apply_connection())
	NT.start()


func _apply_connection() -> void:
	NT.apply_connection(Settings.connection(), str(_args.get("nt_host", "")), CliArgs.get_int(_args, "nt_port", 0))


## --max-fps=N (0 = uncapped) overrides the Visual settings frame cap,
## --vsync=hud|both|off (default hud).
func _apply_frame_policy() -> void:
	_apply_fps_cap()
	Settings.changed.connect(func(section: String) -> void:
		if section == "visual":
			_apply_fps_cap())
	var vsync := str(_args.get("vsync", "hud"))
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED if vsync == "off" else DisplayServer.VSYNC_ENABLED)


func _apply_fps_cap() -> void:
	Engine.max_fps = CliArgs.get_int(_args, "max_fps", int(Settings.visual()["fps_cap"]))


func minimap() -> MinimapView:
	return hud.minimap if hud != null else null


func hud_screen() -> HudScreen:
	return hud


func orbit() -> RobotOrbitView:
	return touch.get("orbit") if touch != null else null


func touch_screen() -> Control:
	return touch


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F3:
		_overlay.toggle()
		get_viewport().set_input_as_handled()
