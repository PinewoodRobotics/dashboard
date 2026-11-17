class_name HostView
extends RefCounted

## One host view: a SubViewport with its content, the shared-surface ring it is
## copied into, and its own frame clock. A view renders only while the host
## has it active and its next frame is due, so views run at independent rates.

const RING_SLOTS := 4
## A tick this close to the deadline still renders, so Godot's own tick jitter
## does not drop a view running at the engine's rate to half of it.
const SLACK_US := 2000

var id: int
var viewport: SubViewport
var content: ViewContent
var fps := 60
var active := true
var scale := 1.0
var ring: Array[RID] = []
var ring_size := Vector2i.ZERO
var pending_slot := -1
var input_stamp := 0
var _next_due_us := 0
var _source := RID()


func _init(view_id: int, view_content: ViewContent) -> void:
	id = view_id
	content = view_content
	viewport = SubViewport.new()
	viewport.name = "View%d" % view_id
	viewport.own_world_3d = true
	viewport.transparent_bg = false
	viewport.msaa_3d = Viewport.MSAA_2X
	viewport.positional_shadow_atlas_size = 0
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	viewport.add_child(content)


func logical_size() -> Vector2:
	return Vector2(ring_size) / maxf(scale, 0.01)


## Points the viewport and a fresh ring generation at size; the previous ring's
## textures are freed once the RenderingDevice is done with them.
func resize(bridge: Object, size: Vector2i, device_scale: float) -> void:
	scale = device_scale
	size = size.clamp(Vector2i(16, 16), Vector2i(8192, 8192))
	if size == ring_size and not ring.is_empty():
		return
	viewport.size = size
	var old := ring
	ring = bridge.create_ring(id, size.x, size.y, RING_SLOTS)
	ring_size = size if ring.size() == RING_SLOTS else Vector2i.ZERO
	_free(old)
	_source = RID()


func close(bridge: Object) -> void:
	bridge.release_ring(id)
	_free(ring)
	ring.clear()
	viewport.queue_free()


func wants_frame(now_us: int) -> bool:
	return active and ring_size != Vector2i.ZERO and now_us + SLACK_US >= _next_due_us and content.is_ready()


func begin_frame(slot: int, now_us: int) -> void:
	pending_slot = slot
	var period := 1000000 / maxi(fps, 1)
	_next_due_us = now_us + period if now_us - _next_due_us > period else _next_due_us + period
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


## Records this view's copy into its slot; it is submitted by the tick's second draw.
func copy_to_slot(rd: RenderingDevice) -> bool:
	_source = RenderingServer.texture_get_rd_texture(viewport.get_texture().get_rid())
	if not _source.is_valid() or viewport.size != ring_size:
		return false
	rd.texture_copy(_source, ring[pending_slot], Vector3.ZERO, Vector3.ZERO, Vector3(ring_size.x, ring_size.y, 1), 0, 0, 0, 0)
	return true


func handle_pointer(p: Dictionary) -> void:
	content.handle_pointer(p, logical_size())
	input_stamp = maxi(input_stamp, int(p.get("stamp", 0)))


func _free(rids: Array[RID]) -> void:
	var rd := RenderingServer.get_rendering_device()
	for rid in rids:
		if rid.is_valid():
			rd.free_rid(rid)
