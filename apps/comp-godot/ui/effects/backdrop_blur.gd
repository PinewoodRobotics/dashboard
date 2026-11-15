class_name BackdropBlur
extends Control

## CSS `backdrop-filter: blur(<sigma>px)`: replaces this rect with a gaussian
## blur of what was drawn behind it, sigma in design pixels. Draws before its
## owner's own background when given a lower z than the owner.

const SHADER := preload("res://ui/effects/backdrop_blur.gdshader")

var sigma := 4.0
var _passes: Array[ColorRect] = []
var _applied := Vector3.ZERO


func _init(sigma_design_px: float = 4.0) -> void:
	sigma = sigma_design_px
	name = "BackdropBlur"
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _ready() -> void:
	for d: Vector2 in [Vector2(1, 0), Vector2(0, 1)]:
		# Under the Compatibility renderer (4.7.2) a rect-mode copy leaves
		# this area of the back buffer black, so each pass copies the viewport.
		var copy := BackBufferCopy.new()
		copy.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
		add_child(copy)
		var pass_rect := ColorRect.new()
		pass_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var mat := ShaderMaterial.new()
		mat.shader = SHADER
		mat.set_shader_parameter("dir", d)
		pass_rect.material = mat
		add_child(pass_rect)
		_passes.append(pass_rect)
	_sync()


func _process(_delta: float) -> void:
	_sync()


func _sync() -> void:
	if not is_visible_in_tree() or _passes.is_empty():
		return
	var scale_px := (get_viewport().get_final_transform() * get_global_transform_with_canvas()).get_scale().x
	var key := Vector3(size.x, size.y, scale_px)
	if key == _applied:
		return
	_applied = key
	for p in _passes:
		p.position = Vector2.ZERO
		p.size = size
		var mat := p.material as ShaderMaterial
		mat.set_shader_parameter("sigma_px", sigma * scale_px)
		mat.set_shader_parameter("rect_px", size * scale_px)
