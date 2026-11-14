class_name HudLayout
extends RefCounted

## HUD geometry at the 1920x1080 design size, taken from the web HUD's vw/vh
## values (hud.md section 3). The shift block keeps the web line box, which was
## set by the SF Pro icon font (hhea 1950/-494 per 2048 em) at 200 px.

const DESIGN := Vector2(1920, 1080)

const HEADER := Rect2(0, 0, 1920, 180)
const TIMER_BOX_W := 938.0
const TIMER_BOX := Rect2(960 - TIMER_BOX_W / 2, 0, TIMER_BOX_W, 180)

const SHIFT_CENTER := Vector2(960, 335.5)
const ICON_PX := 200
const SF_EM_ASCENT := 1950.0 / 2048.0
const SF_EM_DESCENT := 494.0 / 2048.0
const SHIFT_BASELINE := SHIFT_CENTER.y - (SF_EM_ASCENT + SF_EM_DESCENT) * ICON_PX / 2.0 + SF_EM_ASCENT * ICON_PX
## Width of an SF Pro space at 200 px, the gap between icon and number.
const ICON_GAP := 420.0 / 2048.0 * ICON_PX

const BUFFER_POS := Vector2(975, 224)

const MINIMAP := Rect2(540, 480, 840, 1080 + 19.2 - 480)
const MINIMAP_RADIUS := Vector2(0.3 * 840, 0.3 * (1080 + 19.2 - 480))
const MINIMAP_SHADOW_BLUR := 96.0
const MINIMAP_SHADOW_SPREAD := 67.2

const BANNER_BOTTOM := 24.0
const TOAST_OFFSET := Vector2(24, 24)
