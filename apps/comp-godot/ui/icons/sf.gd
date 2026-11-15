class_name Sf
extends RefCounted

## SF Symbols, drawn from SF Pro like the web's `.sf-symbol` spans (Sf.tsx,
## globals.css). Code points are the ones in the web source; symbols without a
## filled form repeat the outline one.

const AUTO := 0x1008F1
const AUTO_FILL := 0x100B31
const SETTINGS := 0x100DD6
const SETTINGS_FILL := 0x100DD7
const EFFECTS := 0x10114B
const EFFECTS_FILL := 0x10114C
const HOWARD := 0x1003B8
const HOWARD_FILL := 0x10064C
const ROBOT3D := 0x100B28
const ROBOT3D_FILL := 0x100CF4
const VISUAL := 0x1010AE
const VISUAL_FILL := 0x1010AF
const MAP := 0x10064A
const MAP_FILL := 0x10064B
const INTAKE := 0x10094E
const INTAKE_FILL := 0x10094F
const HOME := 0x101FE2
const HOME_FILL := 0x101FE3
const DOCK := 0x1003DE
const MODE_DRIVER := 0x1002D3
const MODE_DRIVER_FILL := 0x1002D4
const MODE_FOLLOW := 0x1003AC
const MODE_FOLLOW_FILL := 0x1003AD
const TOGGLE_OFF := 0x100184
const TOGGLE_ON := 0x100185

## `.sf-symbol` is an inline-block with line-height 1 (unlayered, so it beats
## the leading-* classes), so a glyph centered in a flex box has its content
## area centered there and, with SF Pro's 1950/-494 of 2048 ascent/descent,
## its baseline this many em below the center.
const BASELINE_EM := (1950.0 - 494.0) / 2048.0 * 0.5


static func font() -> FontVariation:
	return Tokens.sf()


static func advance(symbol: int, px: int) -> float:
	return font().get_char_size(symbol, px).x


## Pen position of `symbol` centered on `center` the way the browser centers
## the span: by its advance, not its ink.
static func origin(symbol: int, center: Vector2, px: int) -> Vector2:
	return Vector2(center.x - advance(symbol, px) * 0.5, roundf(center.y + BASELINE_EM * px))


static func draw(owner: CanvasItem, symbol: int, center: Vector2, px: int, color: Color) -> void:
	if symbol <= 0:
		return
	UiDraw.text(owner, font(), origin(symbol, center, px), char(symbol), px, color)


## Same, into a canvas item of the caller's (clipped layers).
static func draw_into(ci: RID, symbol: int, center: Vector2, px: int, color: Color) -> void:
	if symbol <= 0 or color.a <= 0.0:
		return
	font().draw_char(ci, origin(symbol, center, px), symbol, px, color)
