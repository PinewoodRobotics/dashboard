//! Godot-only, in the web's Assets style (VisualTab.tsx): which auto export
//! the Auto tab previews (built-in or event update, export time, whether it
//! matches the robot's paths) as a 14 px paragraph colored by that trust,
//! above an outline Reload Autos button.

use dash_core::autos::FreshnessLevel;
use gpui_kit::*;

use super::kit::{AMBER, ROSE_TEXT};
use crate::autos::service;
use crate::theme::{ACCENT, ZINC_400, u};
use crate::widgets::{Button, ButtonStyle};

pub fn freshness_color(level: Option<FreshnessLevel>) -> Rgba {
    match level {
        Some(FreshnessLevel::MatchesRobot) => ACCENT,
        Some(FreshnessLevel::Differs) => ROSE_TEXT,
        Some(FreshnessLevel::Old) => AMBER,
        _ => ZINC_400,
    }
}

pub fn export_box(key: u64, cx: &mut App) -> impl IntoElement {
    let svc = service(cx);
    let (summary, level) = {
        let s = svc.read(cx);
        let fresh = s.freshness(cx);
        (
            s.model.library.summary_text(fresh.as_ref()),
            fresh.map(|f| f.level),
        )
    };
    div()
        .flex()
        .flex_col()
        .gap(u(8.))
        .child(
            div()
                .text_size(u(14.))
                .line_height(u(20.))
                .text_color(freshness_color(level))
                .child(summary),
        )
        .child(
            Button::new(
                ("settings-reload-autos", key),
                "Reload Autos",
                ButtonStyle::Outline,
            )
            .on_tap(move |_, cx| svc.update(cx, |s, cx| s.reload(cx))),
        )
}
