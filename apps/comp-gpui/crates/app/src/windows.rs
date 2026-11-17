use gpui_kit::*;

use crate::theme::{HUD_DESIGN, TOUCH_DESIGN};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScreenKind {
    Hud,
    Touch,
}

impl ScreenKind {
    pub fn design(self) -> Size<f32> {
        match self {
            ScreenKind::Hud => HUD_DESIGN,
            ScreenKind::Touch => TOUCH_DESIGN,
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            ScreenKind::Hud => "PWRUP Comp - HUD",
            ScreenKind::Touch => "PWRUP Comp - Touchscreen",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum Placement {
    Fullscreen {
        display: DisplayId,
        bounds: Bounds<Pixels>,
    },
    Windowed {
        reason: String,
    },
}

pub struct DisplayInfo {
    pub id: DisplayId,
    pub bounds: Bounds<Pixels>,
}

/// The HUD takes the display that is exactly 1920x1080 and the touchscreen
/// the one that is exactly 1920x515 (app/window_placement.gd). Two windows on
/// a single display both stay windowed, and a display is never given to two
/// windows. Display bounds are logical, so a scaled display matches when its
/// logical size times a common Windows scale factor is the design size.
pub fn plan(displays: &[DisplayInfo], windows: &[ScreenKind]) -> Vec<(ScreenKind, Placement)> {
    let mut claimed: Vec<usize> = Vec::new();
    windows
        .iter()
        .map(|&kind| {
            if displays.len() <= 1 && windows.len() > 1 {
                return (
                    kind,
                    Placement::Windowed {
                        reason: "single screen".into(),
                    },
                );
            }
            let want = kind.design();
            let found = displays
                .iter()
                .enumerate()
                .find(|(i, d)| !claimed.contains(i) && matches_design(d.bounds.size, want));
            match found {
                Some((i, d)) => {
                    claimed.push(i);
                    (
                        kind,
                        Placement::Fullscreen {
                            display: d.id,
                            bounds: d.bounds,
                        },
                    )
                }
                None => (
                    kind,
                    Placement::Windowed {
                        reason: format!("no {}x{} display", want.width, want.height),
                    },
                ),
            }
        })
        .collect()
}

fn matches_design(logical: Size<Pixels>, design: Size<f32>) -> bool {
    [1.0f32, 1.25, 1.5, 1.75, 2.0].iter().any(|k| {
        (f32::from(logical.width) * k - design.width).abs() < 1.0
            && (f32::from(logical.height) * k - design.height).abs() < 1.0
    })
}

pub fn displays(cx: &App) -> Vec<DisplayInfo> {
    cx.displays()
        .iter()
        .map(|d| DisplayInfo {
            id: d.id(),
            bounds: d.bounds(),
        })
        .collect()
}

pub fn options(
    kind: ScreenKind,
    placement: &Placement,
    index: usize,
    borderless: bool,
    cx: &App,
) -> WindowOptions {
    match placement {
        Placement::Fullscreen { display, bounds } => WindowOptions {
            window_bounds: Some(WindowBounds::Fullscreen(*bounds)),
            titlebar: None,
            display_id: Some(*display),
            is_movable: false,
            is_resizable: false,
            app_id: Some("pwrup-comp".into()),
            ..Default::default()
        },
        Placement::Windowed { .. } => {
            let design = kind.design();
            let scale = 2.0 / 3.0;
            let sz = size(
                px((design.width * scale).round()),
                px((design.height * scale).round()),
            );
            let origin = cx
                .primary_display()
                .map(|d| d.bounds().origin)
                .unwrap_or_default();
            let at = point(
                origin.x + px(40.),
                origin.y + px(40. + index as f32 * (f32::from(sz.height) + 40.)),
            );
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds::new(at, sz))),
                titlebar: (!borderless).then(|| TitlebarOptions {
                    title: Some(kind.title().into()),
                    ..Default::default()
                }),
                app_id: Some("pwrup-comp".into()),
                ..Default::default()
            }
        }
    }
}

/// Resizes a dev window to the design size in physical pixels, so its
/// screenshots compare 1:1 with the reference images.
pub fn resize_to_design_pixels(kind: ScreenKind, window: &mut Window) {
    let sf = window.scale_factor().max(0.1);
    let d = kind.design();
    window.resize(size(px(d.width / sf), px(d.height / sf)));
}
