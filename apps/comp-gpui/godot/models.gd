class_name Models
extends Node

## Loads the CAD GLBs from absolute paths with GLTFDocument on worker threads.
## Each finished model is a template that views duplicate, so every view shares
## the same Mesh resources and GPU buffers.

signal model_ready(key: String)

const FUEL_PREFIX := "GE-26900"

var templates := {}
var load_ms := {}
var failed := {}
var _jobs := {}


func request(key: String, path: String) -> void:
	if templates.has(key) or _jobs.has(key):
		return
	if path.is_empty() or not FileAccess.file_exists(path):
		push_error("models: %s not found at '%s'" % [key, path])
		failed[key] = true
		return
	var job := {"key": key, "path": path, "t0": Time.get_ticks_msec(), "err": FAILED, "root": null}
	job["task"] = WorkerThreadPool.add_task(_load.bind(job), false, "load " + key)
	_jobs[key] = job
	set_process(true)


func _load(job: Dictionary) -> void:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	job["err"] = doc.append_from_file(job["path"], state)
	if job["err"] == OK:
		job["root"] = doc.generate_scene(state)


func _process(_delta: float) -> void:
	for key: String in _jobs.keys():
		var job: Dictionary = _jobs[key]
		if not WorkerThreadPool.is_task_completed(job["task"]):
			continue
		WorkerThreadPool.wait_for_task_completion(job["task"])
		_jobs.erase(key)
		var root := job["root"] as Node3D
		if job["err"] != OK or root == null:
			push_error("models: %s failed to load (%s)" % [key, error_string(job["err"])])
			failed[key] = true
			continue
		_to_mesh_instances(root)
		if key == "field":
			_drop_fuel(root)
		CadMaterials.apply(root, [], false, key == "field")
		templates[key] = root
		load_ms[key] = Time.get_ticks_msec() - int(job["t0"])
		model_ready.emit(key)
	if _jobs.is_empty():
		set_process(false)


## Loaded, or known never to load.
func settled(key: String) -> bool:
	return templates.has(key) or failed.has(key)


func instance(key: String) -> Node3D:
	var template := templates.get(key) as Node3D
	return template.duplicate() as Node3D if template != null else null


func stats(key: String) -> Dictionary:
	var template := templates.get(key) as Node3D
	if template == null:
		return {}
	var instances := template.find_children("*", "MeshInstance3D", true, false)
	var surfaces := 0
	var triangles := 0
	for mi: MeshInstance3D in instances:
		var mesh := mi.mesh as ArrayMesh
		if mesh == null:
			continue
		for s in mesh.get_surface_count():
			surfaces += 1
			var indices := mesh.surface_get_array_index_len(s)
			triangles += (indices if indices > 0 else mesh.surface_get_array_len(s)) / 3
	return {"mesh_instances": instances.size(), "surfaces": surfaces, "triangles": triangles}


## GLTFDocument can hand back ImporterMeshInstance3D nodes, which do not draw.
static func _to_mesh_instances(root: Node) -> void:
	for imi: ImporterMeshInstance3D in root.find_children("*", "ImporterMeshInstance3D", true, false):
		var mi := MeshInstance3D.new()
		mi.name = imi.name
		mi.transform = imi.transform
		mi.mesh = imi.mesh.get_mesh() if imi.mesh != null else null
		var parent := imi.get_parent()
		parent.add_child(mi)
		parent.move_child(mi, imi.get_index())
		for child in imi.get_children():
			child.reparent(mi, false)
		parent.remove_child(imi)
		imi.free()
		mi.owner = root


## The staged Fuel game pieces, hidden in the web minimap too.
static func _drop_fuel(root: Node) -> void:
	for n in root.find_children(FUEL_PREFIX + "*", "", true, false):
		if is_instance_valid(n):
			n.get_parent().remove_child(n)
			n.free()
