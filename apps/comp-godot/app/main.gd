extends Node

## Composes the screens from CLI args (after `--`):
##   --screen=both|hud|touch   both: HUD in the root window, touchscreen in a second OS window
##   --nt-host=H --nt-port=P   override the shared connection settings without persisting
##   --fixture=NAME|PATH       offline: inject a fixture's NT values, never open a socket
##                             (with --live: fixture views and probes over live NT)
##   --debug-overlay           show the F3 NetworkTables overlay at start
## Screenshot, perf and probe flags are documented in services/dev_service.gd.

var screen := "both"
var windows := {}
var hud: HudScreen
var touch: TouchScreen
var _overlay: DebugOverlay
var _args := {}


func _ready() -> void:
	_args = CliArgs.parse(OS.get_cmdline_user_args())
	screen = WindowManager.parse_screen(_args)
	var root := get_window()
	WindowManager.setup_root(root, screen)
	_apply_frame_policy()
	_start_nt()

	if screen == "touch":
		touch = TouchScreen.new()
		add_child(touch)
		windows["touch"] = root
	else:
		hud = HudScreen.new()
		add_child(hud)
		windows["hud"] = root
		if screen == "both":
			var w := WindowManager.create_touch_window(root)
			add_child(w)
			touch = TouchScreen.new()
			w.add_child(touch)
			windows["touch"] = w
			var vs := DisplayServer.VSYNC_ENABLED if str(_args.get("vsync", "hud")) == "both" else DisplayServer.VSYNC_DISABLED
			DisplayServer.window_set_vsync_mode(vs, w.get_window_id())

	_overlay = DebugOverlay.new(NT)
	_overlay.visible = _args.has("debug_overlay")
	add_child(_overlay)

	Dev.attach(self)


func _start_nt() -> void:
	if Dev.offline_fixture():
		NT.inject(Dev.fixture_nt())
		return
	var conn := ConnectionSettings.load_shared()
	var nt_conf: Dictionary = conn["nt"]
	var host: String = _args.get("nt_host", nt_conf["host"])
	var port := CliArgs.get_int(_args, "nt_port", nt_conf["port"])
	NT.nt_settings = nt_conf
	NT.configure(host, port, conn["reconnectTimeoutSeconds"])
	NT.subscribe_groups(Topics.subscription_groups(nt_conf))
	NT.start()


## --max-fps=N (0 = uncapped, default 60), --vsync=hud|both|off (default hud).
func _apply_frame_policy() -> void:
	Engine.max_fps = CliArgs.get_int(_args, "max_fps", 60)
	var vsync := str(_args.get("vsync", "hud"))
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED if vsync == "off" else DisplayServer.VSYNC_ENABLED)


func minimap() -> MinimapView:
	return hud.minimap if hud != null else null


func orbit() -> RobotOrbitView:
	return touch.orbit if touch != null else null


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F3:
		_overlay.toggle()
		get_viewport().set_input_as_handled()
