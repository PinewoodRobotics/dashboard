class_name ModelsService
extends Node

## Loads the CAD scenes on a worker thread so the UI and NT are live before the
## models appear. Every view instances the same PackedScene, so Mesh resources
## and their GPU buffers are shared across viewports and windows.

signal model_ready(key: String)

const PATHS := {
	"robot": "res://assets/models/robot.glb",
	"field": "res://assets/models/field.glb",
}

var scenes := {}
var ready_msec := {}
var _pending := {}
var _waiters := {}


func _ready() -> void:
	for key: String in PATHS:
		request(key)


func request(key: String) -> void:
	if scenes.has(key) or _pending.has(key):
		return
	var err := ResourceLoader.load_threaded_request(PATHS[key], "PackedScene")
	if err != OK:
		push_error("model load request failed: %s (%s)" % [key, error_string(err)])
		return
	_pending[key] = true
	set_process(true)


func _process(_delta: float) -> void:
	for key: String in _pending.keys():
		var path: String = PATHS[key]
		var status := ResourceLoader.load_threaded_get_status(path)
		if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			continue
		_pending.erase(key)
		if status != ResourceLoader.THREAD_LOAD_LOADED:
			push_error("model failed to load: " + path)
			continue
		_finish(key, ResourceLoader.load_threaded_get(path))
	if _pending.is_empty():
		set_process(false)


## Blocking load, for tests and tools.
func load_now(key: String) -> PackedScene:
	if not scenes.has(key):
		if _pending.has(key):
			_pending.erase(key)
			_finish(key, ResourceLoader.load_threaded_get(PATHS[key]))
		else:
			_finish(key, load(PATHS[key]))
	return scenes[key]


func is_ready(key: String) -> bool:
	return scenes.has(key)


func all_ready() -> bool:
	for key: String in PATHS:
		if not scenes.has(key):
			return false
	return true


## Calls cb(scene: PackedScene) now if loaded, otherwise once it is.
func when_ready(key: String, cb: Callable) -> void:
	if scenes.has(key):
		cb.call(scenes[key])
		return
	if not _waiters.has(key):
		_waiters[key] = []
	_waiters[key].append(cb)
	request(key)


func _finish(key: String, scene: PackedScene) -> void:
	scenes[key] = scene
	ready_msec[key] = Time.get_ticks_msec()
	var waiting: Array = _waiters.get(key, [])
	_waiters.erase(key)
	for cb: Callable in waiting:
		if cb.is_valid():
			cb.call(scene)
	model_ready.emit(key)
