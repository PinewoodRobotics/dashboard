extends Node

const RING_SLOTS := 4

var _view: CubeView
var _bridge: Object
var _ring: Array[RID] = []
var _source: RID
var _size := Vector2i(1280, 720)
var _producing := false
var _started_us := 0


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if "--probe" in args:
		_run_probe(args)
	elif "--port" in args:
		_start_producer(args)


func _arg_value(args: PackedStringArray, key: String, fallback: String) -> String:
	var index := args.find(key)
	if index >= 0 and index + 1 < args.size():
		return args[index + 1]
	return fallback


func _start_producer(args: PackedStringArray) -> void:
	_bridge = ClassDB.instantiate("HostBridge")
	if _bridge == null or not _bridge.connect_host(int(_arg_value(args, "--port", "0"))):
		push_error("producer: no host connection")
		get_tree().quit(1)
		return
	_bridge.hide_window()
	RenderingServer.render_loop_enabled = false
	Engine.max_fps = int(_arg_value(args, "--fps", "120"))
	_size = Vector2i(int(_arg_value(args, "--width", "1280")), int(_arg_value(args, "--height", "720")))

	_view = CubeView.new(_size)
	add_child(_view)
	_view.render_target_update_mode = SubViewport.UPDATE_ONCE
	RenderingServer.force_draw(false)
	_source = RenderingServer.texture_get_rd_texture(_view.get_texture().get_rid())
	_ring = _bridge.create_ring(_size.x, _size.y, RING_SLOTS)
	if _ring.size() != RING_SLOTS or not _source.is_valid():
		push_error("producer: ring setup failed")
		get_tree().quit(1)
		return
	_started_us = Time.get_ticks_usec()
	_producing = true


func _exit_tree() -> void:
	var rd := RenderingServer.get_rendering_device()
	for rid in _ring:
		rd.free_rid(rid)
	_ring.clear()


func _process(_delta: float) -> void:
	if not _producing:
		return
	if not _bridge.host_connected():
		get_tree().quit()
		return
	_bridge.hide_window()
	var slot: int = _bridge.acquire_slot()
	if slot < 0:
		return
	var tick_start := Time.get_ticks_usec()
	_view.set_time((tick_start - _started_us) / 1000000.0)
	_view.render_target_update_mode = SubViewport.UPDATE_ONCE
	RenderingServer.force_draw(false)
	var submitted_us: int = _bridge.now_us()
	var rd := RenderingServer.get_rendering_device()
	rd.texture_copy(_source, _ring[slot], Vector3.ZERO, Vector3.ZERO, Vector3(_size.x, _size.y, 1), 0, 0, 0, 0)
	# The copy is only recorded here; this second draw submits it. The SubViewport's UPDATE_ONCE
	# was consumed by the first draw, so this one only redraws the hidden 64x64 root.
	RenderingServer.force_draw(false)
	var cpu_ms := (Time.get_ticks_usec() - tick_start) / 1000.0
	_bridge.submit_frame(slot, cpu_ms, submitted_us)


func _run_probe(args: PackedStringArray) -> void:
	RenderingServer.render_loop_enabled = false
	if "--hide" in args:
		ClassDB.instantiate("HostBridge").hide_window()
	_view = CubeView.new(Vector2i(512, 512))
	add_child(_view)
	await get_tree().process_frame

	var rd := RenderingServer.get_rendering_device()
	print("probe rd=%s driver=%s" % [rd != null, RenderingServer.get_current_rendering_driver_name()])

	var frames := int(_arg_value(args, "--frames", "300"))
	var start := Time.get_ticks_usec()
	for i in frames:
		_view.set_time(i / 60.0)
		_view.render_target_update_mode = SubViewport.UPDATE_ONCE
		RenderingServer.force_draw(false)
	var elapsed_ms := (Time.get_ticks_usec() - start) / 1000.0
	print("probe frames=%d total_ms=%.1f per_frame_ms=%.3f" % [frames, elapsed_ms, elapsed_ms / frames])

	var image := _view.get_texture().get_image()
	var lit := 0
	for y in range(0, image.get_height(), 8):
		for x in range(0, image.get_width(), 8):
			if image.get_pixel(x, y).r > 0.3:
				lit += 1
	var out := _arg_value(args, "--out", "user://probe.png")
	image.save_png(out)
	print("probe image=%dx%d orange_samples=%d saved=%s" % [image.get_width(), image.get_height(), lit, out])
	var hold_ms := int(_arg_value(args, "--hold-ms", "0"))
	if hold_ms > 0:
		await get_tree().create_timer(hold_ms / 1000.0).timeout
	get_tree().quit()
