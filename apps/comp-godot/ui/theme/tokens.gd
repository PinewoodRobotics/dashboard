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
const ZINC_400 := Color("#a1a1aa")
const ZINC_500 := Color("#71717a")
const ZINC_700 := Color("#3f3f46")
const ZINC_800 := Color("#27272a")
const ZINC_900 := Color("#18181b")

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

const INTER_PATH := "res://ui/fonts/Inter-Variable.ttf"
const MONO_PATH := "res://ui/fonts/RobotoMono-Variable.ttf"

static var _fonts := {}


static func _font(path: String, weight: int) -> FontVariation:
	var key := "%s@%d" % [path, weight]
	if not _fonts.has(key):
		var fv := FontVariation.new()
		fv.base_font = load(path) as FontFile
		fv.variation_opentype = {TextServerManager.get_primary_interface().name_to_tag("wght"): weight}
		_fonts[key] = fv
	return _fonts[key]


static func inter(weight: int = 400) -> FontVariation:
	return _font(INTER_PATH, weight)


static func mono(weight: int = 400) -> FontVariation:
	return _font(MONO_PATH, weight)
