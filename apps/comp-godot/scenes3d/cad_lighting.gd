class_name CadLighting
extends RefCounted

## The web viewers' light rigs (three.js r187 under React Three Fiber: physical
## light units, ACES Filmic tone mapping at exposure 1, sRGB output) rebuilt
## with Godot lights in each view's own world.
##
## A three.js intensity I becomes light energy I / PI: Godot multiplies
## non-physical light energy by PI before its Lambert term divides by PI, three
## does not. The hemisphere light is the sky's ambient contribution: the sky is
## its sky color above and ground color below, and Godot's ambient from a sky
## is the cosine-weighted average that three's hemisphere light computes.
## Metals reflect the same sky at full strength. three has no environment map,
## so its metals render black and its non-metals reflect nothing; the CAD
## shader keeps the latter (every CAD material so far is a non-metal).
## Environment ACES at EXPOSURE and WHITE is exactly three's
## ACESFilmicToneMapping (its color * exposure / 0.6 before the same fit, and
## no white normalization).

const MINIMAP := {
	"hemisphere": 0.5,
	"sky": Color("#ffffff"),
	"ground": Color("#444444"),
	"lights": [[Vector3(10, 20, 10), 0.6], [Vector3(-6, 8, -6), 0.4], [Vector3(0, 10, -10), 0.2]],
}
## DriverRobotViewer.tsx. Its spot light (intensity 0.5 at 6 m, physical
## falloff) adds under 1% and is left out.
const DRIVER := {
	"ambient": 0.3,
	"lights": [[Vector3(5, 8, 5), 1.0], [Vector3(-3, 4, -2), 0.4]],
}
## RobotViewer.tsx (the Robot 3D tab).
const ROBOT_3D := {
	"ambient": 0.7,
	"lights": [[Vector3(4, 8, 4), 1.2], [Vector3(-4, 2, -4), 0.3]],
}

const SKY_SHADER := preload("res://scenes3d/cad_sky.gdshader")
const ACES_BIAS := 1.8
const EXPOSURE := 1.0 / (0.6 * ACES_BIAS)
## Godot divides its ACES output by the fit at white * 1.8; at this white the
## fit is exactly 1, the value three.js never divides by.
const WHITE := 14.260244

static var _skies := {}


static func install(viewport: SubViewport, rig: Dictionary) -> WorldEnvironment:
	var we := WorldEnvironment.new()
	we.name = "Lighting"
	we.environment = environment(rig)
	viewport.add_child(we)
	for l: Array in rig["lights"]:
		var light := DirectionalLight3D.new()
		light.light_energy = float(l[1]) / PI
		viewport.add_child(light)
		var dir: Vector3 = l[0]
		light.look_at_from_position(dir, Vector3.ZERO, Vector3.FORWARD if absf(dir.normalized().y) > 0.99 else Vector3.UP)
	return we


static func environment(rig: Dictionary) -> Environment:
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.sky = _sky(rig.get("sky", MINIMAP["sky"]), rig.get("ground", MINIMAP["ground"]))
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = float(rig.get("ambient", 0.0)) / PI
	env.ambient_light_sky_contribution = float(rig.get("hemisphere", 0.0)) / PI
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = EXPOSURE
	env.tonemap_white = WHITE
	return env


static func _sky(top: Color, bottom: Color) -> Sky:
	var key := [top, bottom]
	if not _skies.has(key):
		var m := ShaderMaterial.new()
		m.shader = SKY_SHADER
		var t := top.srgb_to_linear()
		var b := bottom.srgb_to_linear()
		m.set_shader_parameter("sky_color", Vector3(t.r, t.g, t.b))
		m.set_shader_parameter("ground_color", Vector3(b.r, b.g, b.b))
		var sky := Sky.new()
		sky.sky_material = m
		sky.radiance_size = Sky.RADIANCE_SIZE_64
		_skies[key] = sky
	return _skies[key]
