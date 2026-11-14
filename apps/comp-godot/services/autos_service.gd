class_name AutosService
extends Node

## Owner of the exported auto library and the shared preview clock.

signal library_changed
signal preview_changed(auto_name: String)

var library := AutoLibrary.new()
var clock := AutoClock.new()
var preview_name := ""


func _ready() -> void:
	reload()


func reload() -> void:
	library = AutoLibrary.load_default()
	if not library.is_loaded():
		push_warning("autos: " + library.error)
	if preview_name != "" and library.get_auto(preview_name) == null:
		set_preview("")
	library_changed.emit()


func preview() -> AutoPlayback:
	return library.get_auto(preview_name) if preview_name != "" else null


func set_preview(auto_name: String) -> void:
	preview_name = auto_name
	var p := preview()
	clock.pause()
	clock.set_duration(p.duration_s if p != null else 0.0)
	clock.seek(0.0)
	preview_changed.emit(auto_name)


func _process(delta: float) -> void:
	clock.advance(delta)
