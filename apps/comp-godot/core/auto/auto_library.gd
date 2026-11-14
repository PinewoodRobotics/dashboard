class_name AutoLibrary
extends RefCounted

## The exported autos (tools/pathplanner/export_autos.py). An export dropped
## into user://autos wins over the one shipped in res://data/autos when it is
## valid and at least as new, so autos can be refreshed at an event without
## rebuilding the app.

const FORMAT_VERSION := 1
const BUILTIN_DIR := "res://data/autos"
const USER_DIR := "user://autos"
const META_PATH := "res://data/auto_meta.json"

var dir := ""
var index := {}
var meta := {}
var error := ""
var _cache := {}


## Picks the newest valid export among dirs (ties go to the earlier dir).
static func load_best(dirs: Array) -> AutoLibrary:
	var best: AutoLibrary = null
	var errors := PackedStringArray()
	for d: String in dirs:
		var lib := AutoLibrary.new()
		if not lib.load_dir(d):
			if DirAccess.dir_exists_absolute(d):
				errors.append("%s: %s" % [d, lib.error])
			continue
		if best == null or lib.exported_at() > best.exported_at():
			best = lib
	if best == null:
		best = AutoLibrary.new()
		best.error = "no valid auto export (%s)" % ", ".join(errors)
	best.meta = load_meta(META_PATH)
	return best


func load_dir(path: String) -> bool:
	var idx = _read_json(path.path_join("index.json"))
	if not idx is Dictionary:
		error = "missing or unreadable index.json"
		return false
	if int(idx.get("version", -1)) != FORMAT_VERSION:
		error = "index version %s, expected %d" % [idx.get("version"), FORMAT_VERSION]
		return false
	for a: Dictionary in idx.get("autos", []):
		if not FileAccess.file_exists(path.path_join(str(a["file"]))):
			error = "missing " + str(a["file"])
			return false
	dir = path
	index = idx
	_cache.clear()
	error = ""
	return true


func is_loaded() -> bool:
	return not index.is_empty()


func exported_at() -> String:
	return str(index.get("exported_at", ""))


func names() -> PackedStringArray:
	var out := PackedStringArray()
	for a: Dictionary in index.get("autos", []):
		out.append(str(a["name"]))
	return out


func entry(auto_name: String) -> Dictionary:
	for a: Dictionary in index.get("autos", []):
		if a["name"] == auto_name:
			return a
	return {}


## Parsed lazily and cached; null for an unknown name or a broken file.
func get_auto(auto_name: String) -> AutoPlayback:
	if _cache.has(auto_name):
		return _cache[auto_name]
	var e := entry(auto_name)
	if e.is_empty():
		return null
	var d = _read_json(dir.path_join(str(e["file"])))
	if not d is Dictionary:
		push_error("auto export unreadable: " + str(e["file"]))
		return null
	var p := AutoPlayback.from_dict(d)
	_cache[auto_name] = p
	return p


func display_name(auto_name: String) -> String:
	var m: Dictionary = meta.get(auto_name, {})
	return str(m.get("name", auto_name))


func description(auto_name: String) -> String:
	return str(meta.get(auto_name, {}).get("description", ""))


static func load_meta(path: String) -> Dictionary:
	var d = _read_json(path)
	if not d is Dictionary:
		return {}
	var out := {}
	for k: String in d.get("autos", {}):
		var m = d["autos"][k]
		if m is Dictionary:
			out[k] = m
	return out


static func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(path))


## Digest of a raw PathPlanner directory, identical to source_hash() in
## tools/pathplanner/export_autos.py: sha256 over "relpath\nsha256(file)\n" for
## every file whose path has no dot-prefixed part, sorted by relpath.
static func source_hash(root: String) -> String:
	var rels := PackedStringArray()
	_collect(root, "", rels)
	rels.sort()
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for rel in rels:
		ctx.update(("%s\n%s\n" % [rel, FileAccess.get_sha256(root.path_join(rel))]).to_utf8_buffer())
	return ctx.finish().hex_encode()


static func _collect(root: String, rel: String, out: PackedStringArray) -> void:
	var d := DirAccess.open(root.path_join(rel))
	if d == null:
		return
	d.include_hidden = true
	for f in d.get_files():
		if not f.begins_with("."):
			out.append(rel.path_join(f) if rel != "" else f)
	for sub in d.get_directories():
		if not sub.begins_with("."):
			_collect(root, rel.path_join(sub) if rel != "" else sub, out)
