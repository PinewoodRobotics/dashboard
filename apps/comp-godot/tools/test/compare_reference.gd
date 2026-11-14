extends SceneTree

## Renders the processed robot next to an unsimplified reference GLB (from
## `node tools/assets/build_models.mjs --reference DIR`) from the 4
## camera-poses.json presets and from minimap distance, both with the CAD
## shader. Writes side-by-side PNGs plus silhouette IoU and color difference.
## Windowed run:
##   godot --path apps/comp-godot --script res://../comp-godot/tools/test/compare_reference.gd \
##     -- --reference=/abs/robot-reference.glb --out=/abs/prefix

const VIEW := Vector2i(800, 600)
const MINIMAP_VIEW := Vector2i(280, 200)

var _out := ""
var _ref_path := ""
var _results := {}


func _init() -> void:
	var args := CliArgs.parse(OS.get_cmdline_user_args())
	_ref_path = str(args.get("reference", ""))
	_out = str(args.get("out", "compare"))
	_run.call_deferred()


func _run() -> void:
	var processed: Node3D = (load("res://assets/models/robot.glb") as PackedScene).instantiate()
	CadMaterials.apply(processed)
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var t0 := Time.get_ticks_msec()
	var err := doc.append_from_file(_ref_path, state)
	if err != OK:
		printerr("cannot read reference: ", _ref_path)
		quit(1)
		return
	var reference: Node3D = doc.generate_scene(state)
	print("reference loaded in %d ms" % (Time.get_ticks_msec() - t0))
	_tint_reference(reference)

	var poses := RobotOrbitView.load_poses()
	var shots: Array = []
	var states: Array = poses.get("states", [])
	for i in states.size():
		var s: Dictionary = states[i]
		shots.append({"name": "preset%d_%s" % [i, str(s.get("label", i)).to_lower()], "position": _v(s["position"]), "target": _v(s["target"]), "size": VIEW})
	var far_dir := Vector3(1.0, 0.75, 1.0).normalized()
	shots.append({"name": "minimap_distance", "position": far_dir * 6.5 + Vector3(0, 0.25, 0), "target": Vector3(0, 0.25, 0), "size": MINIMAP_VIEW})

	root.size = Vector2i(VIEW.x * 2, VIEW.y)
	var views: Array[SubViewport] = []
	var cams: Array[Camera3D] = []
	for model: Node3D in [processed, reference]:
		var vp := SubViewport.new()
		vp.own_world_3d = true
		vp.msaa_3d = Viewport.MSAA_2X
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		root.add_child(vp)
		var cad_up := Node3D.new()
		cad_up.rotation.x = -PI / 2.0
		vp.add_child(cad_up)
		cad_up.add_child(model)
		var cam := Camera3D.new()
		cam.fov = 50.0
		cam.near = 0.01
		vp.add_child(cam)
		views.append(vp)
		cams.append(cam)

	for shot: Dictionary in shots:
		var imgs: Array[Image] = []
		var masks: Array[Image] = []
		for mode in ["shaded", "silhouette"]:
			_set_silhouette(processed, mode == "silhouette")
			_set_silhouette(reference, mode == "silhouette")
			for k in 2:
				views[k].size = shot["size"]
				cams[k].look_at_from_position(shot["position"], shot["target"], Vector3.UP)
			for f in 4:
				await process_frame
			await RenderingServer.frame_post_draw
			for k in 2:
				var img := views[k].get_texture().get_image()
				img.convert(Image.FORMAT_RGB8)
				(imgs if mode == "shaded" else masks).append(img)
		var iou := _iou(masks[0], masks[1])
		var diff := _mean_diff(imgs[0], imgs[1])
		_results[shot["name"]] = {"silhouette_iou": iou, "mean_abs_diff": diff}
		print("%s: silhouette IoU %.4f, mean color diff %.4f" % [shot["name"], iou, diff])
		var sx: Vector2i = shot["size"]
		var side := Image.create(sx.x * 2 + 8, sx.y, false, Image.FORMAT_RGB8)
		side.fill(Color(0.25, 0.25, 0.25))
		side.blit_rect(imgs[0], Rect2i(Vector2i.ZERO, sx), Vector2i.ZERO)
		side.blit_rect(imgs[1], Rect2i(Vector2i.ZERO, sx), Vector2i(sx.x + 8, 0))
		side.save_png("%s_%s.png" % [_out, shot["name"]])
	var f := FileAccess.open(_out + "_results.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(_results, "  "))
	f.close()
	quit(0)


func _v(a: Array) -> Vector3:
	return Vector3(a[0], a[1], a[2])


var _tints := {}


func _tint_reference(n: Node) -> void:
	for mi: MeshInstance3D in n.find_children("*", "MeshInstance3D", true, false):
		for i in mi.mesh.get_surface_count():
			var src := mi.mesh.surface_get_material(i)
			var c := (src as BaseMaterial3D).albedo_color if src is BaseMaterial3D else Color(0.8, 0.8, 0.8)
			var key := c.to_html()
			if not _tints.has(key):
				var m := CadMaterials.tintable()
				m.set_shader_parameter("use_tint", 1.0)
				m.set_shader_parameter("tint", c)
				_tints[key] = m
			mi.set_surface_override_material(i, _tints[key])


var _saved := {}
var _white: StandardMaterial3D


func _set_silhouette(n: Node, on: bool) -> void:
	if _white == null:
		_white = StandardMaterial3D.new()
		_white.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_white.cull_mode = BaseMaterial3D.CULL_DISABLED
		_white.albedo_color = Color.WHITE
	for mi: MeshInstance3D in n.find_children("*", "MeshInstance3D", true, false):
		mi.material_overlay = null
		mi.material_override = _white if on else null


static func _iou(a: Image, b: Image) -> float:
	var inter := 0
	var uni := 0
	for y in a.get_height():
		for x in a.get_width():
			var pa := a.get_pixel(x, y).r > 0.5
			var pb := b.get_pixel(x, y).r > 0.5
			if pa and pb:
				inter += 1
			if pa or pb:
				uni += 1
	return float(inter) / maxf(1.0, uni)


static func _mean_diff(a: Image, b: Image) -> float:
	var total := 0.0
	var n := 0
	for y in a.get_height():
		for x in a.get_width():
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			total += (absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)) / 3.0
			n += 1
	return total / maxf(1.0, n)
