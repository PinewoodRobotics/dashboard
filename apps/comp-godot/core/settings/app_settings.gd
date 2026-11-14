class_name AppSettings
extends RefCounted

## Godot-only settings in user://settings.json, normalized like
## settings-schema.ts (mapSettings defaults follow / 0.3 / 0.5) and
## layoutStorage.ts (unknown tab ids dropped, dock completed in default order),
## plus the robot controls the web kept in localStorage (selected auto, intake
## speed override).

const MAP_MODES := ["follow", "driver"]
const DEFAULT_MAP := {"mode": "follow", "angle": 0.3, "zoom": 0.5}

const RENDER_SCALES := [0.25, 0.5, 0.75, 1.0]
const MSAA_LEVELS := [0, 2, 4]
const FPS_CAPS := [30, 60]
const DEFAULT_VISUAL := {"render_scale": 1.0, "msaa": 2, "fps_cap": 60}

## selected_auto: "" = nothing chosen, "NONE" = No Auto, else an auto name.
## intake_speed: null = use the robot's compiled constant, else 0..1.
const DEFAULT_CONTROLS := {"selected_auto": "", "intake_speed": null}

## Screen index per window, -1 = automatic (exact display size). See WindowPlacement.
const DEFAULT_WINDOWS := {"hud_screen": -1, "touch_screen": -1}
const MAX_SCREEN_INDEX := 7


static func _unit(v: Variant, default: float) -> float:
	if _is_num(v):
		return clampf(float(v), 0.0, 1.0)
	return default


static func _is_num(v: Variant) -> bool:
	return (typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT) and is_finite(float(v))


static func normalize_map(raw: Variant) -> Dictionary:
	var out := DEFAULT_MAP.duplicate()
	if typeof(raw) != TYPE_DICTIONARY:
		return out
	if MAP_MODES.has(raw.get("mode")):
		out["mode"] = raw["mode"]
	out["angle"] = _unit(raw.get("angle"), DEFAULT_MAP["angle"])
	out["zoom"] = _unit(raw.get("zoom"), DEFAULT_MAP["zoom"])
	return out


static func _one_of(v: Variant, allowed: Array, default: Variant) -> Variant:
	if not _is_num(v):
		return default
	for a: Variant in allowed:
		if is_equal_approx(float(a), float(v)):
			return a
	return default


static func normalize_visual(raw: Variant) -> Dictionary:
	var out := DEFAULT_VISUAL.duplicate()
	if typeof(raw) != TYPE_DICTIONARY:
		return out
	out["render_scale"] = _one_of(raw.get("render_scale"), RENDER_SCALES, DEFAULT_VISUAL["render_scale"])
	out["msaa"] = _one_of(raw.get("msaa"), MSAA_LEVELS, DEFAULT_VISUAL["msaa"])
	out["fps_cap"] = _one_of(raw.get("fps_cap"), FPS_CAPS, DEFAULT_VISUAL["fps_cap"])
	return out


static func normalize_controls(raw: Variant) -> Dictionary:
	var out := DEFAULT_CONTROLS.duplicate()
	if typeof(raw) != TYPE_DICTIONARY:
		return out
	if typeof(raw.get("selected_auto")) == TYPE_STRING:
		out["selected_auto"] = (raw["selected_auto"] as String).strip_edges()
	if _is_num(raw.get("intake_speed")):
		out["intake_speed"] = IntakeSpeed.round_speed(float(raw["intake_speed"]))
	return out


static func normalize_windows(raw: Variant) -> Dictionary:
	var out := DEFAULT_WINDOWS.duplicate()
	if typeof(raw) != TYPE_DICTIONARY:
		return out
	for key: String in out:
		var v: Variant = raw.get(key)
		if _is_num(v) and float(v) == floorf(float(v)):
			out[key] = clampi(int(v), -1, MAX_SCREEN_INDEX)
	return out


static func normalize_layout(raw: Variant) -> Dictionary:
	if typeof(raw) != TYPE_DICTIONARY:
		return default_layout()
	return {
		"rail": TabDefs.sanitize_ids(raw.get("rail")) if raw.has("rail") else TabDefs.DEFAULT_RAIL.duplicate(),
		"dock": TabDefs.normalize_dock(raw.get("dock")),
	}


static func default_layout() -> Dictionary:
	return {"rail": TabDefs.DEFAULT_RAIL.duplicate(), "dock": TabDefs.TABS.duplicate()}


static func defaults() -> Dictionary:
	return {"map": DEFAULT_MAP.duplicate(), "visual": DEFAULT_VISUAL.duplicate(), "layout": default_layout(), "controls": DEFAULT_CONTROLS.duplicate(),
		"windows": DEFAULT_WINDOWS.duplicate()}


## Unknown sections are kept so newer builds' settings survive a round trip.
static func normalize(raw: Variant) -> Dictionary:
	var out := defaults()
	if typeof(raw) != TYPE_DICTIONARY:
		return out
	for key: String in raw:
		if not out.has(key):
			out[key] = raw[key]
	out["map"] = normalize_map(raw.get("map"))
	out["visual"] = normalize_visual(raw.get("visual"))
	out["layout"] = normalize_layout(raw.get("layout"))
	out["controls"] = normalize_controls(raw.get("controls"))
	out["windows"] = normalize_windows(raw.get("windows"))
	return out
