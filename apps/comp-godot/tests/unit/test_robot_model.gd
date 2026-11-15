extends TestCase

## Rest transforms from robot3d.md section 2.3 (glTF TRS, quaternion xyzw).
const REST := {
	"Bumper": [[-0.00435, 0.00095, 0.08337], [0, 0, 0, 1]],
	"ClimberControlInner": [[-0.0004, 0.2226, 0.62], [-0.7071, 0, 0, 0.7071]],
	"ClimberControlOuter": [[-0.0004, 0.1522, -0.0099], [-0.7071, 0, 0, 0.7071]],
	"FrameControl": [[-0.0004, -0.3237, -0.0251], [-0.5, 0.5, -0.5, 0.5]],
	"IndexWristRControl": [[-0.2559, -0.2348, 0.1209], [-0.7056, 0, 0, 0.7086]],
	"TurretGearRControl": [[0.2059, 0.0065, 0.2813], [-0.6109, 0.3561, -0.3561, 0.6109]],
	"TurretRControl": [[-0.0004, 0.0065, 0.2584], [-0.6109, -0.3561, 0.3561, 0.6109]],
	"BumperPlane": [[0, 0.00635, -0.0635], [0, 0, 0, 1]],
}
const TOL := 1e-4

var model: Node3D


func before_each() -> void:
	model = (load(ModelsService.PATHS["robot"]) as PackedScene).instantiate()


func after_each() -> void:
	if model != null:
		model.free()


func _manifest() -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string("res://assets/models/models.manifest.json"))


func test_nodes_exist_with_exact_names_and_rest_transforms() -> void:
	for name: String in REST:
		var n := model.find_child(name, true, false) as Node3D
		if not check(n != null, "node %s exists" % name):
			continue
		check_eq(String(n.name), name)
		var want_t := Vector3(REST[name][0][0], REST[name][0][1], REST[name][0][2])
		var q: Array = REST[name][1]
		var want_q := Quaternion(q[0], q[1], q[2], q[3])
		var dt := (n.position - want_t).abs()
		check(maxf(dt.x, maxf(dt.y, dt.z)) <= TOL, "%s translation %s vs %s" % [name, n.position, want_t])
		var got_q := n.quaternion
		if got_q.dot(want_q) < 0.0:
			got_q = -got_q
		var d := got_q - want_q
		check(maxf(maxf(absf(d.x), absf(d.y)), maxf(absf(d.z), absf(d.w))) <= TOL, "%s rotation %s vs %s" % [name, got_q, want_q])


func test_rest_transforms_match_the_manifest_exactly() -> void:
	var rest: Dictionary = _manifest()["robot"]["rest_transforms"]
	check_eq(rest.size(), 8)
	for name: String in rest:
		var n := model.find_child(name, true, false) as Node3D
		if not check(n != null, name):
			continue
		var t: Array = rest[name]["translation"]
		var r: Array = rest[name]["rotation"]
		var s: Array = rest[name]["scale"]
		check(n.position.distance_to(Vector3(t[0], t[1], t[2])) < 1e-6, name + " translation")
		var q := Quaternion(r[0], r[1], r[2], r[3])
		check(minf((n.quaternion - q).length(), (n.quaternion + q).length()) < 1e-6, name + " rotation")
		check(n.scale.distance_to(Vector3(s[0], s[1], s[2])) < 1e-6, name + " scale")


func _triangles(root: Node) -> int:
	var tris := 0
	for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		for i in mi.mesh.get_surface_count():
			tris += mi.mesh.surface_get_array_index_len(i) / 3
	return tris


func test_models_keep_every_source_triangle() -> void:
	var m := _manifest()
	check(bool(m["lossless"]), "manifest marks the build lossless")
	check_eq(_triangles(model), int(m["robot"]["source_triangles"]), "robot triangles equal the CAD export's")
	check_eq(int(m["robot"]["triangles"]), int(m["robot"]["source_triangles"]))
	var field: Node3D = (load(ModelsService.PATHS["field"]) as PackedScene).instantiate()
	check_eq(_triangles(field), int(m["field"]["triangles"]))
	check_eq(int(m["field"]["triangles"]) + int(m["field"]["fuel_triangles_dropped"]), int(m["field"]["source_triangles"]),
		"field triangles plus the staged Fuel equal the CAD export's")
	check(field.find_children("GE-26900*", "", true, false).is_empty(), "no Fuel nodes")
	field.free()


func test_import_keeps_full_precision_and_no_lods() -> void:
	for key: String in ModelsService.PATHS:
		var cfg := ConfigFile.new()
		check_eq(cfg.load(ModelsService.PATHS[key] + ".import"), OK, key + ".import")
		check_eq(cfg.get_value("params", "meshes/generate_lods"), false, key + " generates no LODs")
		check_eq(cfg.get_value("params", "meshes/force_disable_compression"), true, key + " vertex compression off")
		var root: Node3D = (load(ModelsService.PATHS[key]) as PackedScene).instantiate()
		for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
			for i in mi.mesh.get_surface_count():
				check(mi.mesh.surface_get_format(i) & Mesh.ARRAY_FLAG_COMPRESS_ATTRIBUTES == 0, "%s %s surface %d uncompressed" % [key, mi.name, i])
		root.free()


func test_surfaces_keep_their_cad_materials() -> void:
	var seen := {}
	for mi: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		for i in mi.mesh.get_surface_count():
			var mat := mi.mesh.surface_get_material(i) as BaseMaterial3D
			if check(mat != null, "%s surface %d has its glTF material" % [mi.name, i]):
				seen[mat.resource_name] = mat
	var grey := seen.get("0.400000_0.400000_0.400000_0.000000_0.000000") as BaseMaterial3D
	if check(grey != null, "a named CAD material survives"):
		var p := CadMaterials.params(grey)
		check(absf((p["albedo"] as Color).r - 0.4) < 1e-3, "shader gets the linear base color back (%s)" % p["albedo"])
		check_eq(p["roughness"], 1.0)
	var glass := seen.get("Material") as BaseMaterial3D
	if check(glass != null, "the polycarbonate material survives"):
		check(CadMaterials.is_blend(glass), "it stays blended")
		check(absf(glass.albedo_color.a - 0.45) < 1e-3, "with its alpha")
		check(absf(glass.roughness - 0.1825) < 1e-3, "and its roughness")
	var field: Node3D = (load(ModelsService.PATHS["field"]) as PackedScene).instantiate()
	var carpet := (field.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D).mesh.surface_get_material(0) as BaseMaterial3D
	check_eq(carpet.metallic, 1.0, "the field export marks its materials metallic")
	var p := CadMaterials.params(carpet, true)
	check_eq([p["metallic"], p["roughness"]], [0.0, 1.0], "the field is shaded matte")
	field.free()


func test_joint_transform_conventions() -> void:
	var rest := Transform3D(Basis(Quaternion(-0.6109, -0.3561, 0.3561, 0.6109).normalized()), Vector3(1, 2, 3))
	var rev := RobotRig.joint_transform(rest, true, Vector3.UP, 0.7)
	check(rev.origin == rest.origin, "revolute keeps the origin")
	check(rev.basis.is_equal_approx(rest.basis * Basis(Vector3.UP, 0.7)), "revolute post-multiplies the local axis")
	var pri := RobotRig.joint_transform(rest, false, Vector3.BACK, -0.31)
	check(pri.basis == rest.basis, "prismatic keeps the basis")
	check(pri.origin.is_equal_approx(rest.origin + Vector3(0, 0, -0.31)), "prismatic offsets in the parent frame")


func test_rig_applies_solver_values_to_the_imported_nodes() -> void:
	var solver := RigSolver.load_default()
	var rig := RobotRig.new(model)
	var values := solver.compute_joint_values({"turret": 0.25, "index_wrist": 0.3, "climber_inner": 0.0})
	rig.apply(solver, values)
	var turret: Node3D = rig.nodes["TurretRControl"]
	var gear: Node3D = rig.nodes["TurretGearRControl"]
	var wrist: Node3D = rig.nodes["IndexWristRControl"]
	var inner: Node3D = rig.nodes["ClimberControlInner"]
	var outer: Node3D = rig.nodes["ClimberControlOuter"]
	check(turret.transform.origin == rig.rest["TurretRControl"].origin, "turret origin unchanged")
	check(turret.transform.basis.is_equal_approx(rig.rest["TurretRControl"].basis * Basis(Vector3.UP, -PI / 2.0)), "turret basis")
	check(gear.transform.basis.is_equal_approx(rig.rest["TurretGearRControl"].basis * Basis(Vector3.UP, PI / 2.0)), "gear opposite")
	check(wrist.transform.basis.is_equal_approx(rig.rest["IndexWristRControl"].basis * Basis(Vector3.RIGHT, values["index_wrist"])), "wrist basis")
	check(inner.transform.basis.is_equal_approx(rig.rest["ClimberControlInner"].basis), "climber basis unchanged")
	check(inner.transform.origin.is_equal_approx(rig.rest["ClimberControlInner"].origin + Vector3(0, 0, -0.31)), "inner offset")
	check(outer.transform.origin.is_equal_approx(rig.rest["ClimberControlOuter"].origin + Vector3(0, 0, 0.31)), "outer mirrored")
	rig.apply(solver, solver.compute_joint_values({}))
	check(turret.transform.is_equal_approx(rig.rest["TurretRControl"]), "default returns to rest")


func test_bumper_recolor_uses_a_private_material() -> void:
	var rig := RobotRig.new(model)
	check(rig.bumper != null, "bumper node found")
	var other: Node3D = (load(ModelsService.PATHS["robot"]) as PackedScene).instantiate()
	var rig2 := RobotRig.new(other)
	rig.set_alliance(true)
	rig2.set_alliance(false)
	check(rig.bumper.mesh == rig2.bumper.mesh, "mesh stays shared")
	check(rig.bumper_material != rig2.bumper_material, "materials are per instance")
	check_eq(rig.bumper_material.get_shader_parameter("tint"), RobotRig.RED)
	check_eq(rig2.bumper_material.get_shader_parameter("tint"), RobotRig.BLUE)
	rig.set_alliance(null)
	check_eq(rig.bumper_material.get_shader_parameter("use_tint"), 0.0, "unknown alliance shows the model color")
	other.free()


func test_manifest_is_current() -> void:
	var m := _manifest()
	for key: String in ModelsService.PATHS:
		var entry: Dictionary = m[key]
		var out_path := "res://" + str(entry["output"])
		check_eq(FileAccess.get_sha256(out_path), entry["output_sha256"], key + " GLB matches the manifest: run tools/assets/build_models.mjs")
		var src := ProjectSettings.globalize_path("res://").path_join("..").path_join("..").path_join(str(entry["source"]))
		if not FileAccess.file_exists(src):
			note("source %s not present; staleness check skipped" % src)
			continue
		check_eq(FileAccess.get_sha256(src), entry["source_sha256"], "%s source changed since the models were built: run tools/assets/build_models.mjs" % key)


func test_glbs_declare_no_extensions() -> void:
	for key: String in ModelsService.PATHS:
		var f := FileAccess.open(ModelsService.PATHS[key], FileAccess.READ)
		f.seek(12)
		var json_len := f.get_32()
		f.seek(20)
		var header: Dictionary = JSON.parse_string(f.get_buffer(json_len).get_string_from_utf8())
		check(not header.has("extensionsRequired"), key + " extensionsRequired")
		check(not header.has("extensionsUsed"), key + " extensionsUsed")
		check(not header.has("animations"), key + " animations dropped")

