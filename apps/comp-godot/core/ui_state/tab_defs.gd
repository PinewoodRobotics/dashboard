class_name TabDefs
extends RefCounted

## Touchscreen tabs and right panels (apps/comp touchscreen/model/defs.ts).
## The web Record tab is dropped; stored layouts that mention it lose it.

const TABS := ["auto", "settings", "effects", "howard", "robot3d", "visual"]
const DEFAULT_RAIL := ["auto", "settings"]

const TAB_INFO := {
	"auto": {"label": "Auto Select", "icon": "route"},
	"settings": {"label": "Connection Settings", "icon": "settings"},
	"effects": {"label": "Special Effects", "icon": "sparkles"},
	"howard": {"label": "Pictures of Howard", "icon": "image"},
	"robot3d": {"label": "Robot 3D", "icon": "box"},
	"visual": {"label": "Visual Settings", "icon": "eye"},
}

const PANELS := ["showMap", "intakeSpeed"]
const PANEL_INFO := {
	"showMap": {"label": "Map", "icon": "map"},
	"intakeSpeed": {"label": "Intake Speed", "icon": "gauge"},
}

const HOME_ICON := "bot"
const DOCK_ICON := "layout-grid"


static func is_tab(id: Variant) -> bool:
	return typeof(id) == TYPE_STRING and TABS.has(id)


static func is_panel(id: Variant) -> bool:
	return typeof(id) == TYPE_STRING and PANELS.has(id)


## Known ids only, first occurrence kept (layoutStorage.ts sanitize).
static func sanitize_ids(raw: Variant) -> Array:
	var out: Array = []
	if typeof(raw) != TYPE_ARRAY:
		return out
	for id: Variant in raw:
		if is_tab(id) and not out.has(id):
			out.append(id)
	return out


## Sanitized, then every missing tab appended in default order.
static func normalize_dock(raw: Variant) -> Array:
	var out := sanitize_ids(raw)
	for id: String in TABS:
		if not out.has(id):
			out.append(id)
	return out
