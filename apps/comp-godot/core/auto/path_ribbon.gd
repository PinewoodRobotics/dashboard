class_name PathRibbon
extends RefCounted

## Geometry of an auto's path on the field: the sampled centerline in Godot
## world space (FieldFrame) with the playback time of every point, and a flat
## strip mesh whose UV.x carries that time so a shader can split travelled from
## remaining without rebuilding the mesh.

const LIFT := 0.03
const WIDTH := 0.14
const MIN_STEP := 0.01


## {points: PackedVector3Array, times: PackedFloat32Array}; points closer than
## MIN_STEP to the previous one are skipped, the first and last are kept.
static func centerline(p: AutoPlayback, alliance: StringName, lift: float = LIFT) -> Dictionary:
	var points := PackedVector3Array()
	var times := PackedFloat32Array()
	var n := p.sample_count
	for i in n:
		var s := p.sample_at(i, alliance)
		var w := FieldFrame.to_world(s.x, s.y) + Vector3.UP * lift
		if i > 0 and i < n - 1 and w.distance_to(points[points.size() - 1]) < MIN_STEP:
			continue
		if i == n - 1 and points.size() > 1 and w.distance_to(points[points.size() - 1]) < MIN_STEP:
			points[points.size() - 1] = w
			times[times.size() - 1] = i * p.dt
			continue
		points.append(w)
		times.append(i * p.dt)
	return {"points": points, "times": times}


## Triangle strip (as a triangle list) of the given width along the centerline,
## two vertices per point: left then right. UV = (time, 0 left / 1 right).
static func strip_mesh(points: PackedVector3Array, times: PackedFloat32Array, width: float = WIDTH) -> ArrayMesh:
	var n := points.size()
	if n < 2:
		return null
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	verts.resize(n * 2)
	uvs.resize(n * 2)
	normals.resize(n * 2)
	for i in n:
		var a := points[maxi(i - 1, 0)]
		var b := points[mini(i + 1, n - 1)]
		var tangent := Vector3(b.x - a.x, 0.0, b.z - a.z)
		if tangent.length_squared() < 1e-12:
			tangent = Vector3.RIGHT
		var side := tangent.normalized().cross(Vector3.UP) * (width * 0.5)
		verts[i * 2] = points[i] - side
		verts[i * 2 + 1] = points[i] + side
		uvs[i * 2] = Vector2(times[i], 0.0)
		uvs[i * 2 + 1] = Vector2(times[i], 1.0)
		normals[i * 2] = Vector3.UP
		normals[i * 2 + 1] = Vector3.UP
	for i in n - 1:
		var l0 := i * 2
		indices.append_array([l0, l0 + 2, l0 + 1, l0 + 1, l0 + 2, l0 + 3])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
