class_name NtHarness
extends RefCounted

static func make_service(tree: SceneTree, port: int, connect_timeout_s: float = 10.0) -> NtService:
	var nt := NtService.new()
	tree.root.add_child(nt)
	nt.configure("127.0.0.1", port, connect_timeout_s)
	return nt


static func dispose(nt: NtService) -> void:
	if nt == null:
		return
	nt.stop()
	nt.queue_free()
