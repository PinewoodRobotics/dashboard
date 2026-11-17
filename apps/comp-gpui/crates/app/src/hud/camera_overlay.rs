use std::time::Instant;

use gpui_kit::*;

use crate::mock::MockData;
use crate::theme::{
    ACCENT, ERROR, HUD_DESIGN, INTER, ORANGE, WHITE, YELLOW, alpha, hex, u, weight,
};

const FRAME: Bounds<f32> = Bounds {
    origin: Point {
        x: 0.679 * HUD_DESIGN.width,
        y: 0.2037 * HUD_DESIGN.height,
    },
    size: Size {
        width: 576.0,
        height: 432.0,
    },
};
const FRAME_RADIUS: f32 = 0.0083 * HUD_DESIGN.width;
const FRAME_BG: Rgba = hex(0x111111);
const LABEL_LEFT: f32 = 0.012 * FRAME.size.width;
const STATUS_GAP: f32 = 0.0065 * HUD_DESIGN.height;
const STATUS_PX: f32 = 0.025 * HUD_DESIGN.width;
/// Inter's hhea ascender plus descender per em: CSS `line-height: normal`.
const INTER_NORMAL: f32 = (1984.0 + 494.0) / 2048.0;

struct Ruler {
    label: &'static str,
    line_y: f32,
    label_y: f32,
    band_top: f32,
    band_bottom: f32,
    color: Rgba,
    font_px: f32,
}

/// The Figma distance rulers, in pixels of the 576 x 432 frame: bands get
/// thicker and labels larger as the distance shrinks.
const RULERS: [Ruler; 4] = [
    Ruler {
        label: "2.0m",
        line_y: 220.0,
        label_y: 217.0,
        band_top: 210.0,
        band_bottom: 230.0,
        color: ACCENT,
        font_px: 0.0104 * HUD_DESIGN.width,
    },
    Ruler {
        label: "1.5m",
        line_y: 257.0,
        label_y: 251.0,
        band_top: 243.0,
        band_bottom: 267.0,
        color: YELLOW,
        font_px: 0.0125 * HUD_DESIGN.width,
    },
    Ruler {
        label: "1.0m",
        line_y: 310.0,
        label_y: 303.0,
        band_top: 292.0,
        band_bottom: 320.0,
        color: ORANGE,
        font_px: 0.01875 * HUD_DESIGN.width,
    },
    Ruler {
        label: "0.5m",
        line_y: 390.0,
        label_y: 381.0,
        band_top: 368.0,
        band_bottom: 400.0,
        color: ERROR,
        font_px: 0.025 * HUD_DESIGN.width,
    },
];

pub fn status_text(distance_m: f64, ready: bool) -> String {
    if ready {
        "Ready to auto align".into()
    } else {
        format!("{distance_m:.1}m away from target")
    }
}

/// CameraOverlay.tsx: the auto-align camera frame with its distance rulers
/// and the status line under it, shown only while the robot auto-aligns.
/// The camera feed itself is not ported (nor in Godot): the frame stays
/// its #111 fill.
pub fn render(data: &MockData, _now: Instant, _window: &mut Window) -> Option<AnyElement> {
    let a = &data.align;
    if !a.active {
        return None;
    }
    let mut frame = div()
        .relative()
        .w(u(FRAME.size.width))
        .h(u(FRAME.size.height))
        .rounded(u(FRAME_RADIUS))
        .overflow_hidden()
        .bg(FRAME_BG);
    for r in &RULERS {
        let line = INTER_NORMAL * r.font_px;
        frame = frame
            .child(
                div()
                    .absolute()
                    .left_0()
                    .w_full()
                    .top(u(r.band_top))
                    .h(u(r.band_bottom - r.band_top))
                    .bg(alpha(r.color, 0.3)),
            )
            .child(
                div()
                    .absolute()
                    .left_0()
                    .w_full()
                    .top(u(r.line_y))
                    .h(u(2.))
                    .bg(alpha(r.color, 0.9)),
            )
            .child(
                div()
                    .absolute()
                    .left(u(LABEL_LEFT))
                    .top(u(r.label_y - line))
                    .font_family(INTER)
                    .font_weight(weight(400))
                    .text_size(u(r.font_px))
                    .line_height(u(line))
                    .text_color(r.color)
                    .whitespace_nowrap()
                    .child(r.label),
            );
    }
    let status = div()
        .mt(u(STATUS_GAP))
        .font_family(INTER)
        .font_weight(weight(400))
        .text_size(u(STATUS_PX))
        .line_height(u(INTER_NORMAL * STATUS_PX))
        .text_color(if a.ready { ACCENT } else { WHITE })
        .whitespace_nowrap()
        .child(status_text(a.distance_m, a.ready));
    Some(
        div()
            .absolute()
            .left(u(FRAME.origin.x))
            .top(u(FRAME.origin.y))
            .w(u(FRAME.size.width))
            .child(frame)
            .child(status)
            .into_any_element(),
    )
}

#[cfg(test)]
mod tests {
    use super::status_text;

    #[test]
    fn status_reads_ready_or_the_distance() {
        assert_eq!(status_text(1.26, false), "1.3m away from target");
        assert_eq!(status_text(0.0, false), "0.0m away from target");
        assert_eq!(status_text(0.4, true), "Ready to auto align");
    }
}
