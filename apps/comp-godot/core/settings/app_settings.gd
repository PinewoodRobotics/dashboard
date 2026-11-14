class_name AppSettings
extends RefCounted

## Godot-only settings in user://settings.json, normalized like
## settings-schema.ts (mapSettings defaults follow / 0.3 / 0.5).

const MAP_MODES := ["follow", "driver"]
const DEFAULT_MAP := {"mode": "follow", "angle": 0.3, "zoom": 0.5}


static func _unit(v: Variant, default: float) -> float:
	if (typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT) and is_finite(float(v)):
		return clampf(float(v), 0.0, 1.0)
	return default


static func normalize_map(raw: Variant) -> Dictionary:
	var out := DEFAULT_MAP.duplicate()
	if typeof(raw) != TYPE_DICTIONARY:
		return out
	if MAP_MODES.has(raw.get("mode")):
		out["mode"] = raw["mode"]
	out["angle"] = _unit(raw.get("angle"), DEFAULT_MAP["angle"])
	out["zoom"] = _unit(raw.get("zoom"), DEFAULT_MAP["zoom"])
	return out


static func defaults() -> Dictionary:
	return {"map": DEFAULT_MAP.duplicate()}


## Unknown sections are kept so newer builds' settings survive a round trip.
static func normalize(raw: Variant) -> Dictionary:
	var out := defaults()
	if typeof(raw) != TYPE_DICTIONARY:
		return out
	for key: String in raw:
		if not out.has(key):
			out[key] = raw[key]
	out["map"] = normalize_map(raw.get("map"))
	return out
