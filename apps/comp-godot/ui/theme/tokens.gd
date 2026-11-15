class_name Tokens
extends RefCounted

## Single source of colors, type, spacing and motion for both screens.

const ACCENT := Color("#70cd35")
const YELLOW := Color("#ffd900")
const PURPLE := Color("#a600ff")
const ORANGE := Color("#ff9d00")
const BLUE := Color("#3b82f6")
const ERROR := Color("#ef4444")
const ERROR_TEXT := Color("#f87171")
const PANEL := Color("#272727")
const CARD := Color("#3c3c3c")
const SELECTED_FILL := Color("#192515")
const FOCUS_FILL := Color("#1a2410")
const TOAST_BG := Color("#0a0a0a")
const TOAST_BORDER := Color("#2a2a2a")
const BG := Color.BLACK
const TEXT := Color.WHITE
const TEXT_DIM := Color(1, 1, 1, 0.45)
const ZINC_300 := Color("#d4d4d8")
const ZINC_400 := Color("#9f9fa9")
const ZINC_500 := Color("#71717b")
const ZINC_600 := Color("#52525c")
const ZINC_700 := Color("#3f3f46")
const ZINC_800 := Color("#27272a")
const ZINC_900 := Color("#18181b")
const ZINC_950 := Color("#09090b")
const SCRIM := Color(0, 0, 0, 0.9)
const HAIRLINE := Color(1, 1, 1, 0.1)
const OUTLINE := Color(1, 1, 1, 0.2)

const HEADER_COLORS := {
	MatchEnums.Header.GREEN: ACCENT,
	MatchEnums.Header.YELLOW: YELLOW,
	MatchEnums.Header.PURPLE: PURPLE,
}

const AIM_ICONS := {
	MatchEnums.Aim.SHOOTER_DISABLED: {"icon": "circle-minus", "color": CARD},
	MatchEnums.Aim.GPS_AUTO: {"icon": "scan-eye", "color": BLUE},
	MatchEnums.Aim.MANUAL_AIMING: {"icon": "circle-gauge", "color": ORANGE},
}
const LANE_ICON := "gamepad-2"

const FONT_TEXT_SM := 14
const FONT_TEXT_BASE := 16
const FONT_TEXT_LG := 18
const FONT_TIMER_LARGE := 128
const FONT_TIMER_SMALL := 64

const RAIL_W := 84
const DRAWER_W := 540
const DOCK_W := 860
const ICON := 48
const BORDER := 4

const MOTION_OVERLAY_S := 0.2
const MOTION_DOCK_S := 0.1
const MOTION_SLIDER_FILL_S := 0.15
const MOTION_PRESS_S := 0.1
const MOTION_TAILWIND_S := 0.15

const TOUCH_DESIGN := Vector2(1920, 515)
const DRAWER_PAD := 20
const DRAWER_ICON_COL := 44
const DRAWER_GAP := 30
const DOCK_PAD := 10
const DOCK_GAP := 12

const INTER_WEIGHTS := [300, 400, 500, 600, 700]
const MONO_WEIGHTS := [400, 500]
const SF_TEXT_Z := 1 + 5 + 2

static var _fonts := {}


## Static weights (tools/fonts/build_fonts.sh), imported as MSDF so every size
## of a weight shares one glyph texture. text_z gives each texture its own z
## slot, so UiDraw batches all text of one font in a layer together.
static func _font(family: String, weights: Array, weight: int, z_base: int) -> FontVariation:
	var w: int = weights[0]
	for candidate: int in weights:
		if absi(candidate - weight) < absi(w - weight):
			w = candidate
	var key := "%s@%d" % [family, w]
	if not _fonts.has(key):
		var fv := FontVariation.new()
		fv.base_font = load("res://ui/fonts/%s-%d.ttf" % [family, w]) as FontFile
		fv.set_meta(&"text_z", z_base + weights.find(w))
		_fonts[key] = fv
	return _fonts[key]


static func inter(weight: int = 400) -> FontVariation:
	return _font("Inter", INTER_WEIGHTS, weight, 1)


static func mono(weight: int = 400) -> FontVariation:
	return _font("RobotoMono", MONO_WEIGHTS, weight, 1 + INTER_WEIGHTS.size())


## Inter with tabular figures, for numbers that tick without shifting.
static func inter_tabular(weight: int = 400) -> FontVariation:
	var key := "tnum@%d" % weight
	if not _fonts.has(key):
		var fv := inter(weight).duplicate() as FontVariation
		fv.opentype_features = {TextServerManager.get_primary_interface().name_to_tag("tnum"): 1}
		_fonts[key] = fv
	return _fonts[key]


## SF Pro (tools/fonts/build_sf_symbols.sh) for SF Symbols and the few SF Pro
## texts of the web dashboard. Imported as plain per-size glyphs, not MSDF:
## msdfgen leaves stray marks beside SF Pro's letters.
static func sf() -> FontVariation:
	if not _fonts.has("sf"):
		var fv := FontVariation.new()
		fv.base_font = load("res://ui/fonts/SF-Pro-400.ttf") as FontFile
		fv.set_meta(&"text_z", SF_TEXT_Z)
		_fonts["sf"] = fv
	return _fonts["sf"]
