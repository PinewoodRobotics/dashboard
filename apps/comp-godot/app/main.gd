extends Control

## M1 shell: connects NT from the shared connection settings (CLI overrides),
## subscribes the dashboard topic groups and hosts the F3 debug overlay.
## CLI (after `--`): --nt-host=H --nt-port=P --debug-overlay
##                   --screenshot=<png> [--screenshot-delay=S]

var _overlay: DebugOverlay
var _status: Label
var _args := {}


func _ready() -> void:
	_args = CliArgs.parse(OS.get_cmdline_user_args())
	var conn := ConnectionSettings.load_shared()
	var nt_conf: Dictionary = conn["nt"]
	var host: String = _args.get("nt_host", nt_conf["host"])
	var port := CliArgs.get_int(_args, "nt_port", nt_conf["port"])
	NT.nt_settings = nt_conf
	NT.configure(host, port, conn["reconnectTimeoutSeconds"])
	NT.subscribe_groups(Topics.subscription_groups(nt_conf))
	NT.start()

	var bg := ColorRect.new()
	bg.color = Color.BLACK
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	_status = Label.new()
	_status.set_anchors_preset(Control.PRESET_FULL_RECT)
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_status.add_theme_font_size_override("font_size", 28)
	_status.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	add_child(_status)

	_overlay = DebugOverlay.new(NT)
	_overlay.visible = _args.has("debug_overlay")
	add_child(_overlay)

	if _args.has("screenshot"):
		_screenshot(str(_args["screenshot"]), CliArgs.get_float(_args, "screenshot_delay", 1.0))


func _process(_delta: float) -> void:
	_status.text = "PWRUP comp dashboard\nNT %s  %s:%d\nF3: NetworkTables overlay" % [NT.client.state_name(), NT.client.host, NT.client.port]


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F3:
		_overlay.toggle()
		get_viewport().set_input_as_handled()


func _screenshot(path: String, delay_s: float) -> void:
	await get_tree().create_timer(delay_s).timeout
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(path)
	print("screenshot ", path, " ", error_string(err))
	get_tree().quit(0 if err == OK else 1)
