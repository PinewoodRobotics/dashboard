extends TestCase


static func _aces_fit(x: float) -> float:
	return (x * (x + 0.0245786) - 0.000090537) / (x * (0.983729 * x + 0.432951) + 0.238081)


func test_tone_mapping_is_three_aces_filmic() -> void:
	check_near(CadLighting.EXPOSURE * CadLighting.ACES_BIAS, 1.0 / 0.6, 1e-6, "Godot's 1.8 bias times exposure is three's 1 / 0.6")
	check_near(_aces_fit(CadLighting.WHITE * CadLighting.ACES_BIAS), 1.0, 1e-6, "white normalization is 1")
	var env := CadLighting.environment(CadLighting.MINIMAP)
	check_eq(env.tonemap_mode, Environment.TONE_MAPPER_ACES)
	check_near(env.tonemap_exposure, CadLighting.EXPOSURE, 1e-6)
	check_near(env.tonemap_white, CadLighting.WHITE, 1e-4)


func test_overlay_shader_inverts_the_same_tone_mapping() -> void:
	var src := FileAccess.get_file_as_string("res://scenes3d/auto/overlay_color.gdshaderinc")
	var m := RegEx.create_from_string("OVERLAY_EXPOSURE = ([0-9.]+);").search(src)
	check(m != null and absf(float(m.get_string(1)) - CadLighting.EXPOSURE) < 1e-5, "overlay exposure matches CadLighting.EXPOSURE")


func test_rigs_follow_the_web_viewers() -> void:
	var mm := CadLighting.environment(CadLighting.MINIMAP)
	check_near(mm.ambient_light_sky_contribution, 0.5 / PI, 1e-6, "hemisphere 0.5 from the sky")
	check_near(mm.ambient_light_energy, 0.0, 1e-6, "no flat ambient on the minimap")
	check_eq(mm.reflected_light_source, Environment.REFLECTION_SOURCE_SKY)
	var drv := CadLighting.environment(CadLighting.DRIVER)
	check_near(drv.ambient_light_sky_contribution, 0.0, 1e-6)
	check_near(drv.ambient_light_energy, 0.3 / PI, 1e-6, "ambient 0.3")
	check_near(CadLighting.environment(CadLighting.ROBOT_3D).ambient_light_energy, 0.7 / PI, 1e-6, "ambient 0.7")


func test_install_adds_the_rig_lights() -> void:
	var vp := SubViewport.new()
	tree.root.add_child(vp)
	CadLighting.install(vp, CadLighting.MINIMAP)
	var lights := vp.find_children("*", "DirectionalLight3D", false, false)
	check_eq(lights.size(), 3)
	if lights.size() == 3:
		var key := lights[0] as DirectionalLight3D
		check_near(key.light_energy, 0.6 / PI, 1e-6, "key energy")
		var toward := -key.global_transform.basis.z
		check(toward.is_equal_approx(-Vector3(10, 20, 10).normalized()), "key shines from (10, 20, 10) toward the origin %s" % toward)
		check(not key.shadow_enabled, "no shadows (they cost 9 ms a frame with the full models)")
	check(vp.find_children("*", "WorldEnvironment", false, false).size() == 1, "one WorldEnvironment")
	vp.free()


func test_material_colors_are_not_relinearized() -> void:
	var src := StandardMaterial3D.new()
	src.albedo_color = Color(0.5, 0.5, 0.5)
	var m := CadMaterials.create(src)
	var albedo: Variant = m.get_shader_parameter("albedo")
	check(albedo is Vector4, "albedo goes in as Vector4, which Forward+ does not convert (%s)" % type_string(typeof(albedo)))
	if albedo is Vector4:
		check_near((albedo as Vector4).x, 0.5 ** 2.2, 0.01, "linear base color")
