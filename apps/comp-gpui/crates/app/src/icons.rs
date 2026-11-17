use gpui_kit::*;

use crate::theme::{SF, u};

/// SF Symbols code points, the same ones the web types into `.sf-symbol`
/// spans (touchscreen/model/defs.ts, HubStatusIcon.tsx, MatchHUD.tsx).
pub mod sf {
    pub const AUTO: u32 = 0x1008F1;
    pub const AUTO_FILL: u32 = 0x100B31;
    pub const SETTINGS: u32 = 0x100DD6;
    pub const SETTINGS_FILL: u32 = 0x100DD7;
    pub const EFFECTS: u32 = 0x10114B;
    pub const EFFECTS_FILL: u32 = 0x10114C;
    pub const HOWARD: u32 = 0x1003B8;
    pub const HOWARD_FILL: u32 = 0x10064C;
    pub const ROBOT3D: u32 = 0x100B28;
    pub const ROBOT3D_FILL: u32 = 0x100CF4;
    pub const VISUAL: u32 = 0x1010AE;
    pub const VISUAL_FILL: u32 = 0x1010AF;
    pub const MAP: u32 = 0x10064A;
    pub const MAP_FILL: u32 = 0x10064B;
    pub const INTAKE: u32 = 0x10094E;
    pub const INTAKE_FILL: u32 = 0x10094F;
    pub const HOME: u32 = 0x101FE2;
    pub const HOME_FILL: u32 = 0x101FE3;
    pub const DOCK: u32 = 0x1003DE;
    pub const MODE_DRIVER: u32 = 0x1002D3;
    pub const MODE_DRIVER_FILL: u32 = 0x1002D4;
    pub const MODE_FOLLOW: u32 = 0x1003AC;
    pub const MODE_FOLLOW_FILL: u32 = 0x1003AD;
    pub const TOGGLE_OFF: u32 = 0x100184;
    pub const TOGGLE_ON: u32 = 0x100185;
    pub const AIM_DISABLED: u32 = 0x10004E;
    pub const AIM_GPS: u32 = 0x1003BC;
    pub const AIM_MANUAL: u32 = 0x10037A;
    pub const LANE_ALIGNMENT: u32 = 0x100A15;

    pub fn glyph(code: u32) -> String {
        char::from_u32(code).map(String::from).unwrap_or_default()
    }
}

/// A `.sf-symbol` span: line-height 1, its advance wide.
pub fn sf_symbol(code: u32, size: f32, color: impl Into<Hsla>) -> Div {
    div()
        .flex_none()
        .h(u(size))
        .font_family(SF)
        .font_weight(FontWeight::NORMAL)
        .text_size(u(size))
        .line_height(u(size))
        .text_color(color)
        .whitespace_nowrap()
        .child(sf::glyph(code))
}

pub fn lucide(name: &str, size: f32, color: impl Into<Hsla>) -> Svg {
    svg()
        .path(crate::assets::lucide_path(name))
        .flex_none()
        .size(u(size))
        .text_color(color)
}
