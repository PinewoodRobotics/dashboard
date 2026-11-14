class_name AutoPathOverlay
extends Node3D

## One auto drawn on the field: path ribbon (travelled part highlighted by the
## shader from the playback time), start and end markers, a pin per timeline
## event at the pose where it starts, and the turret's aim line. Meshes are
## cached per auto and alliance and shared by every view.

const RIBBON_SHADER := preload("res://scenes3d/auto/auto_path.gdshader")
const MARKER_SHADER := preload("res://scenes3d/auto/auto_marker.gdshader")
const KIND_COLORS := {
	AutoMechanisms.Kind.AIM: Color("#3b82f6"),
	AutoMechanisms.Kind.SHOOTER: Color("#ff9d00"),
	AutoMechanisms.Kind.INTAKE: Color("#70cd35"),
	AutoMechanisms.Kind.NOOP: Color("#71717a"),
	AutoMechanisms.Kind.OTHER: Color("#a600ff"),
}
const START_COLOR := Color("#70cd35")
const END_COLOR := Color("#ffffff")
const AIM_COLOR := Color(0.231, 0.51, 0.965, 0.85)
const PIN_HEIGHT := 1.0
const PIN_ALPHA := 0.6

static var _mesh_cache := {}

var ribbon: MeshInstance3D
var markers: MeshInstance3D
var aim_line: MeshInstance3D
var ribbon_material: ShaderMaterial
var key := ""
var _aim_mesh := ImmediateMesh.new()


static func kind_color(it: Dictionary) -> Color:
	return KIND_COLORS[AutoMechanisms.Kind.NOOP] if not it["runs"] else KIND_COLORS.get(it["kind"], Color.WHITE)


func _init() -> void:
	ribbon_material = ShaderMaterial.new()
	ribbon_material.shader = RIBBON_SHADER
	ribbon = _instance("Ribbon", ribbon_material)
	var marker_material := ShaderMaterial.new()
	marker_material.shader = MARKER_SHADER
	markers = _instance("Markers", marker_material)
	aim_line = _instance("AimLine", marker_material)
	aim_line.mesh = _aim_mesh


func _instance(n: String, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = n
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi


func show_auto(mech: AutoMechanisms, alliance: StringName) -> void:
	var k := "%s|%s" % [mech.playback.name, alliance]
	if k == key:
		return
	key = k
	if not _mesh_cache.has(k):
		var line := PathRibbon.centerline(mech.playback, alliance)
		_mesh_cache[k] = {
			"ribbon": PathRibbon.strip_mesh(line["points"], line["times"]),
			"markers": build_markers(mech, alliance),
		}
	ribbon.mesh = _mesh_cache[k]["ribbon"]
	markers.mesh = _mesh_cache[k]["markers"]
	visible = true


func clear() -> void:
	if key == "" and not visible:
		return
	key = ""
	ribbon.mesh = null
	markers.mesh = null
	set_aim(Vector3.ZERO, Vector3.ZERO, false)
	visible = false


func set_progress(t: float) -> void:
	ribbon_material.set_shader_parameter("progress", t)


func set_aim(from: Vector3, to: Vector3, on: bool) -> void:
	_aim_mesh.clear_surfaces()
	var d := Vector3(to.x - from.x, 0.0, to.z - from.z)
	if not on or d.length() < 0.05:
		return
	var side := d.normalized().cross(Vector3.UP) * 0.035
	var a := Vector3(from.x, 0.05, from.z)
	var b := Vector3(to.x, 0.05, to.z)
	_aim_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	_aim_mesh.surface_set_color(AIM_COLOR)
	for v in [a - side, b - side, a + side, a + side, b - side, b + side]:
		_aim_mesh.surface_add_vertex(v)
	_ring_immediate(_aim_mesh, b, 0.16, 0.24)
	_aim_mesh.surface_end()


static func _ring_immediate(m: ImmediateMesh, c: Vector3, r0: float, r1: float) -> void:
	var seg := 24
	for i in seg:
		var a0 := TAU * i / seg
		var a1 := TAU * (i + 1) / seg
		var p0 := Vector3(cos(a0), 0, sin(a0))
		var p1 := Vector3(cos(a1), 0, sin(a1))
		for v in [c + p0 * r0, c + p0 * r1, c + p1 * r1, c + p0 * r0, c + p1 * r1, c + p1 * r0]:
			m.surface_add_vertex(v)


static func build_markers(mech: AutoMechanisms, alliance: StringName) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var start := mech.pose_at(0.0, alliance)
	var end := mech.pose_at(mech.duration, alliance)
	var s_world := FieldFrame.to_world(start.x, start.y) + Vector3.UP * 0.04
	_ring(st, s_world, 0.34, 0.46, START_COLOR)
	_arrow(st, s_world, FieldFrame.forward(start.z), START_COLOR)
	if mech.playback.has_path():
		var e_world := FieldFrame.to_world(end.x, end.y) + Vector3.UP * 0.045
		_ring(st, e_world, 0.0, 0.3, Color(END_COLOR, 0.35))
		_ring(st, e_world, 0.3, 0.4, END_COLOR)
	var placed := {}
	for it: Dictionary in mech.items:
		var p := mech.pose_at(it["t0"], alliance)
		var base := FieldFrame.to_world(p.x, p.y)
		var slot := "%.2f|%.2f" % [base.x, base.z]
		var stack: int = placed.get(slot, 0)
		placed[slot] = stack + 1
		_pin(st, base + Vector3(0.1 * stack, 0, 0), Color(kind_color(it), PIN_ALPHA))
	return st.commit()


static func _ring(st: SurfaceTool, c: Vector3, r0: float, r1: float, col: Color) -> void:
	var seg := 40
	for i in seg:
		var a0 := TAU * i / seg
		var a1 := TAU * (i + 1) / seg
		var p0 := Vector3(cos(a0), 0, sin(a0))
		var p1 := Vector3(cos(a1), 0, sin(a1))
		_tri(st, c + p0 * r0, c + p0 * r1, c + p1 * r1, col)
		_tri(st, c + p0 * r0, c + p1 * r1, c + p1 * r0, col)


static func _arrow(st: SurfaceTool, c: Vector3, fwd: Vector3, col: Color) -> void:
	var side := fwd.cross(Vector3.UP)
	var tip := c + fwd * 0.85
	var back := c + fwd * 0.52
	_tri(st, tip, back + side * 0.17, back - side * 0.17, col)


static func _pin(st: SurfaceTool, base: Vector3, col: Color) -> void:
	var w := 0.018
	var top := base + Vector3.UP * PIN_HEIGHT
	for s: Vector3 in [Vector3(w, 0, 0), Vector3(0, 0, w)]:
		_tri(st, base - s, base + s, top + s, col)
		_tri(st, base - s, top + s, top - s, col)
	var h := 0.075
	var head := top + Vector3.UP * h
	var ring := [Vector3(h, 0, 0), Vector3(0, 0, h), Vector3(-h, 0, 0), Vector3(0, 0, -h)]
	for i in 4:
		var a: Vector3 = head + ring[i]
		var b: Vector3 = head + ring[(i + 1) % 4]
		_tri(st, head + Vector3.UP * h, a, b, col)
		_tri(st, head - Vector3.UP * h, a, b, col)


static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, col: Color) -> void:
	for v in [a, b, c]:
		st.set_color(col)
		st.add_vertex(v)
