extends Node

## Producer for the GPUI host: views opened by the host render into shared
## surfaces with the render loop off. One tick draws every due view with
## force_draw, records each view's copy into its ring slot, and submits the
## copies with a second force_draw; the bridge sends Frame once Godot's queue
## has drained past them.

const CLEAR_COLOR := Color("#0b0d12")
const IDLE_FPS := 30

var _bridge: Object
var _views := {}
var _models: Models
var _idle_return := true


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
	RenderingServer.set_default_clear_color(CLEAR_COLOR)
	Engine.max_fps = IDLE_FPS
	_idle_return = not ("--no-idle-return" in args)

	_models = Models.new()
	_models.name = "Models"
	add_child(_models)
	_models.model_ready.connect(_on_model_ready)
	_models.request("robot", _arg_value(args, "--robot", ""))
	_models.request("field", _arg_value(args, "--field", ""))


func _on_model_ready(key: String) -> void:
	var s := _models.stats(key)
	_bridge.send_status("%s loaded in %d ms: %d mesh instances, %d surfaces, %d triangles" % [
		key, _models.load_ms[key], s.get("mesh_instances", 0), s.get("surfaces", 0), s.get("triangles", 0)])
	for v: HostView in _views.values():
		v.content.on_model_ready(key)


func _exit_tree() -> void:
	if _bridge == null:
		return
	for v: HostView in _views.values():
		v.close(_bridge)
	_views.clear()


func _process(delta: float) -> void:
	if _bridge == null:
		return
	if not _bridge.host_connected():
		get_tree().quit()
		return
	for line: String in _bridge.poll_messages():
		var message: Variant = JSON.parse_string(line)
		if message is Dictionary:
			_handle(message)
	_bridge.hide_window()

	var now := Time.get_ticks_usec()
	var due: Array[HostView] = []
	for v: HostView in _views.values():
		v.content.step(delta, v.active)
		if v.wants_frame(now):
			var slot: int = _bridge.acquire_slot(v.id)
			if slot >= 0:
				v.begin_frame(slot, now)
				due.append(v)
	if due.is_empty():
		return

	var tick_start := Time.get_ticks_usec()
	RenderingServer.force_draw(false)
	var submitted_us: int = _bridge.now_us()
	var rd := RenderingServer.get_rendering_device()
	var copied: Array[HostView] = []
	for v in due:
		if v.copy_to_slot(rd):
			copied.append(v)
	# The copies are only recorded here; this draw submits them. Every due
	# viewport's UPDATE_ONCE was consumed by the first draw.
	RenderingServer.force_draw(false)
	var cpu_ms := (Time.get_ticks_usec() - tick_start) / 1000.0
	for v in copied:
		_bridge.submit_frame(v.id, v.pending_slot, cpu_ms, submitted_us, v.input_stamp)


func _handle(m: Dictionary) -> void:
	var view_id := int(m.get("view", -1))
	var view := _views.get(view_id) as HostView
	match str(m.get("type", "")):
		"OpenView":
			if view == null:
				view = HostView.new(view_id, _content(str(m.get("scene", "Cube"))))
				_views[view_id] = view
				add_child(view.viewport)
			view.fps = int(m.get("fps", 60))
			view.active = bool(m.get("active", true))
			view.resize(_bridge, Vector2i(int(m["width"]), int(m["height"])), float(m.get("scale", 1.0)))
			_update_max_fps()
		"Resize":
			if view != null:
				view.resize(_bridge, Vector2i(int(m["width"]), int(m["height"])), float(m.get("scale", 1.0)))
		"SetActive":
			if view != null:
				view.active = bool(m.get("active", true))
				_update_max_fps()
		"CloseView":
			if view != null:
				view.close(_bridge)
				_views.erase(view_id)
				_update_max_fps()
		"Pointer":
			if view != null:
				view.handle_pointer(m)


func _content(scene: String) -> ViewContent:
	var content: ViewContent
	match scene:
		"Robot":
			content = RobotContent.new(_idle_return)
		"Minimap":
			content = MinimapContent.new()
		_:
			content = CubeContent.new()
	content.models = _models
	return content


func _update_max_fps() -> void:
	var fps := IDLE_FPS
	for v: HostView in _views.values():
		if v.active:
			fps = maxi(fps, v.fps)
	Engine.max_fps = fps


func _run_probe(args: PackedStringArray) -> void:
	RenderingServer.render_loop_enabled = false
	if "--hide" in args:
		ClassDB.instantiate("HostBridge").hide_window()
	var content := CubeContent.new()
	var view := HostView.new(0, content)
	view.viewport.size = Vector2i(512, 512)
	add_child(view.viewport)
	await get_tree().process_frame

	var rd := RenderingServer.get_rendering_device()
	print("probe rd=%s driver=%s" % [rd != null, RenderingServer.get_current_rendering_driver_name()])

	var frames := int(_arg_value(args, "--frames", "300"))
	var start := Time.get_ticks_usec()
	for i in frames:
		content.set_time(i / 60.0)
		view.viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		RenderingServer.force_draw(false)
	var elapsed_ms := (Time.get_ticks_usec() - start) / 1000.0
	print("probe frames=%d total_ms=%.1f per_frame_ms=%.3f" % [frames, elapsed_ms, elapsed_ms / frames])

	var image := view.viewport.get_texture().get_image()
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
