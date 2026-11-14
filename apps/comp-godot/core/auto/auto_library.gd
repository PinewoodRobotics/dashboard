class_name AutoLibrary
extends RefCounted

## The exported autos (tools/pathplanner/export_autos.py). An export dropped
## into user://autos wins over the one shipped in res://data/autos when it is
## valid and at least as new, so autos can be refreshed at an event without
## rebuilding the app. Every auto file is checked on load: a broken one falls
## back to the same auto in an older export when there is one, and otherwise
## has no preview and an error to show. Results, failures included, are
## cached, so a broken file is read and logged once.

const FORMAT_VERSION := 1
const BUILTIN_DIR := "res://data/autos"
const USER_DIR := "user://autos"
const META_PATH := "res://data/auto_meta.json"

var dir := ""
var index := {}
var meta := {}
var error := ""
## Older valid exports, newest first, that a broken auto falls back to.
var fallbacks: Array[AutoLibrary] = []
var _cache := {}
var _errors := {}
var _notes := {}


## Picks the newest valid export among dirs (ties go to the earlier dir).
static func load_best(dirs: Array) -> AutoLibrary:
	var valid: Array[AutoLibrary] = []
	var errors := PackedStringArray()
	for d: String in dirs:
		var lib := AutoLibrary.new()
		if not lib.load_dir(d):
			if DirAccess.dir_exists_absolute(d):
				errors.append("%s: %s" % [d, lib.error])
			continue
		var at := 0
		while at < valid.size() and valid[at].exported_at() >= lib.exported_at():
			at += 1
		valid.insert(at, lib)
	if valid.is_empty():
		var none := AutoLibrary.new()
		none.error = "no valid auto export (%s)" % ", ".join(errors)
		none.meta = load_meta(META_PATH)
		return none
	var best: AutoLibrary = valid.pop_front()
	best.fallbacks = valid
	best.meta = load_meta(META_PATH)
	for n in best.names():
		best.get_auto(n)
	return best


func load_dir(path: String) -> bool:
	var idx = _read_json(path.path_join("index.json"))
	if not idx is Dictionary:
		error = "missing or unreadable index.json"
		return false
	if int(idx.get("version", -1)) != FORMAT_VERSION:
		error = "index version %s, expected %d" % [idx.get("version"), FORMAT_VERSION]
		return false
	if not idx.get("autos") is Array:
		error = "index.json has no auto list"
		return false
	for a: Variant in idx["autos"]:
		if not a is Dictionary or not a.get("name") is String or not a.get("file") is String:
			error = "bad auto entry in index.json"
			return false
		if not FileAccess.file_exists(path.path_join(str(a["file"]))):
			error = "missing " + str(a["file"])
			return false
	dir = path
	index = idx
	_cache.clear()
	_errors.clear()
	_notes.clear()
	error = ""
	return true


func is_loaded() -> bool:
	return not index.is_empty()


func exported_at() -> String:
	return str(index.get("exported_at", ""))


func exported_source_hash() -> String:
	return str(index.get("source_hash", ""))


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


## Cached; null for an unknown name or a broken file with no fallback.
func get_auto(auto_name: String) -> AutoPlayback:
	if _cache.has(auto_name):
		return _cache[auto_name]
	var e := entry(auto_name)
	if e.is_empty():
		return null
	var p: Variant = _parse(str(e["file"]))
	if p is String:
		var p_why: String = p
		var why := "%s: %s" % [e["file"], p_why]
		push_warning("auto export %s: %s" % [dir, why])
		p = null
		for fb in fallbacks:
			p = fb.get_auto(auto_name) if fb.entry(auto_name).size() > 0 else null
			if p != null:
				_notes[auto_name] = "%s file is broken (%s). Showing the %s export from %s." % [
					"Built-in" if dir == BUILTIN_DIR else "Event update", p_why,
					"built-in" if fb.dir == BUILTIN_DIR else "older", short_time(fb.exported_at())]
				break
		if p == null:
			_errors[auto_name] = why
	_cache[auto_name] = p
	return p


## Why the auto has no preview although the export lists it; "" when it loads.
func auto_error(auto_name: String) -> String:
	get_auto(auto_name)
	return _errors.get(auto_name, "")


## Set when a broken file was replaced by the same auto from an older export.
func auto_note(auto_name: String) -> String:
	get_auto(auto_name)
	return _notes.get(auto_name, "")


func _parse(file: String) -> Variant:
	var path := dir.path_join(file)
	if not FileAccess.file_exists(path):
		return "missing"
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK:
		return "not valid JSON, line %d" % json.get_error_line()
	var why := AutoPlayback.validate(json.data)
	return why if why != "" else AutoPlayback.from_dict(json.data)


static func short_time(iso: String) -> String:
	return iso.replace("T", " ").trim_suffix("Z").left(16)


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
