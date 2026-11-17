extends Node

var _view: CubeView


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if "--probe" in args:
		_run_probe(args)


func _arg_value(args: PackedStringArray, key: String, fallback: String) -> String:
	var index := args.find(key)
	if index >= 0 and index + 1 < args.size():
		return args[index + 1]
	return fallback


func _run_probe(args: PackedStringArray) -> void:
	RenderingServer.render_loop_enabled = false
	_view = CubeView.new(Vector2i(512, 512))
	add_child(_view)
	await get_tree().process_frame

	var rd := RenderingServer.get_rendering_device()
	print("probe rd=%s driver=%s" % [rd != null, RenderingServer.get_current_rendering_driver_name()])
	print("probe window_visible=%s" % get_window().visible)

	var frames := 300
	var start := Time.get_ticks_usec()
	for i in frames:
		_view.step(1.0 / 60.0)
		_view.render_target_update_mode = SubViewport.UPDATE_ONCE
		RenderingServer.force_draw(false)
	var elapsed_ms := (Time.get_ticks_usec() - start) / 1000.0
	print("probe frames=%d total_ms=%.1f per_frame_ms=%.3f" % [frames, elapsed_ms, elapsed_ms / frames])

	var image := _view.get_texture().get_image()
	var lit := 0
	for y in range(0, image.get_height(), 8):
		for x in range(0, image.get_width(), 8):
			var c := image.get_pixel(x, y)
			if c.r > 0.3:
				lit += 1
	var out := _arg_value(args, "--out", "user://probe.png")
	image.save_png(out)
	print("probe image=%dx%d format=%d orange_samples=%d saved=%s" % [image.get_width(), image.get_height(), image.get_format(), lit, out])
	var hold_ms := int(_arg_value(args, "--hold-ms", "0"))
	if hold_ms > 0:
		await get_tree().create_timer(hold_ms / 1000.0).timeout
	get_tree().quit()
