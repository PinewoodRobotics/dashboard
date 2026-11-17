use dash_core::settings::{RENDER_SCALES, VisualSettings, WindowsSettings};
use gpui_kit::*;

use super::settings_tab::{column, header, info_box};
use super::{TabId, TouchScreen, TouchStart};
use crate::mock::MockData;
use crate::settings;
use crate::theme::{PANEL, ZINC_400, u};
use crate::widgets::{
    Axis2, Button, ButtonStyle, Scroll, Selector, SelectorOption, Slider, SliderHint, toggle,
};
use crate::windows;

const SCALE_HINTS: [(f32, &str); 4] = [
    (0.0, "0.25x: for struggling hardware"),
    (0.4, "0.5x: moderate quality loss"),
    (0.62, "0.75: barely noticeable quality loss"),
    (0.87, "1: native resolution, full quality"),
];

const SCREEN_OPTIONS: [(i32, &str, &str); 4] = [
    (-1, "Auto", "Auto: the display with the exact size"),
    (0, "1", "Display 1"),
    (1, "2", "Display 2"),
    (2, "3", "Display 3"),
];

#[derive(Clone, Debug, PartialEq)]
struct Draft {
    visual: VisualSettings,
    windows: WindowsSettings,
}

/// The draft and the saved settings it was loaded from: a section whose saved
/// value changes (Save, Reset, another window) reloads that part of the draft.
struct DraftState {
    draft: Draft,
    base: Draft,
}

fn same(a: &Draft, b: &Draft) -> bool {
    a.windows == b.windows
        && a.visual.backdrop_blur == b.visual.backdrop_blur
        && (a.visual.render_scale - b.visual.render_scale).abs() < 1e-4
}

fn edit<T: 'static>(state: &Entity<DraftState>, f: fn(&mut Draft, T)) -> impl Fn(T, &mut App) + 'static {
    let state = state.clone();
    move |v, cx| {
        state.update(cx, |s, cx| {
            f(&mut s.draft, v);
            cx.notify();
        })
    }
}

fn renderer_name() -> &'static str {
    if cfg!(target_os = "macos") {
        "Metal"
    } else if cfg!(windows) {
        "DirectX 11"
    } else {
        "Vulkan"
    }
}

fn scale_text(s: f32) -> String {
    format!("{s}x")
}

/// Renderer readout (visual_tab.gd's Diagnostics) with what GPUI can report:
/// it draws on demand, so there is no steady frame rate or draw count.
fn renderer_rows(data: &MockData, window: &Window, cx: &App) -> Vec<(&'static str, String)> {
    let adapter = window.gpu_specs().map_or_else(
        || "not reported on this platform".to_owned(),
        |g| {
            let soft = if g.is_software_emulated {
                ", software"
            } else {
                ""
            };
            format!("{} ({}{soft})", g.device_name, g.driver_name)
        },
    );
    let sf = window.scale_factor();
    let vp = window.viewport_size();
    let displays = cx.displays();
    let here = window.display(cx).map(|d| d.id());
    let display = match here.and_then(|id| displays.iter().position(|d| d.id() == id)) {
        Some(i) => format!("{} of {}", i + 1, displays.len()),
        None => format!("unknown of {}", displays.len()),
    };
    let nt = if data.nt_connected {
        match data.nt.rtt_ms {
            Some(r) => format!("{} ({r:.1} ms)", data.nt.state),
            None => data.nt.state.to_owned(),
        }
    } else {
        "DISCONNECTED".to_owned()
    };
    vec![
        ("Driver", format!("{}, GPUI", renderer_name())),
        ("Adapter", adapter),
        (
            "Window",
            format!(
                "{}x{} px at {sf}x",
                (f32::from(vp.width) * sf).round(),
                (f32::from(vp.height) * sf).round()
            ),
        ),
        ("Display", display),
        (
            "Effective quality",
            format!(
                "{} scale, blur {}",
                scale_text(data.visual.render_scale),
                if data.visual.backdrop_blur {
                    "on"
                } else {
                    "off"
                }
            ),
        ),
        ("NetworkTables", nt),
    ]
}

fn screen_selector(
    id: (&'static str, u64),
    caption: &str,
    value: i32,
    on_change: impl Fn(i32, &mut App) + 'static,
) -> Selector {
    let index = SCREEN_OPTIONS
        .iter()
        .position(|(v, _, _)| *v == value)
        .unwrap_or(0);
    Selector::new(
        id,
        SCREEN_OPTIONS
            .iter()
            .map(|(_, text, hint)| SelectorOption::text(*text).hint(*hint))
            .collect(),
        index,
    )
    .label(caption.to_owned())
    .on_change(move |i, _, cx| on_change(SCREEN_OPTIONS[i].0, cx))
}

/// VisualTab.tsx as the Godot port shows it, keeping the columns that mean
/// something in GPUI: Rendering (Backdrop Blur, Render Scale; Log Depth is
/// dropped), Displays (which display each window takes, Re-tile) and the
/// renderer Diagnostics. Edits go to a draft; Save (enabled while the draft
/// differs) persists it, Reset restores the rendering defaults at once.
pub fn render(
    ts: &TouchScreen,
    key: u64,
    window: &mut Window,
    cx: &mut Context<TouchScreen>,
) -> impl IntoElement {
    let data = ts.data.read(cx).clone();
    let saved = Draft {
        visual: data.visual.clone(),
        windows: settings::windows(cx),
    };
    let state = window.use_keyed_state(("visual-draft", key), cx, |_, _| DraftState {
        draft: saved.clone(),
        base: saved.clone(),
    });
    state.update(cx, |s, _| {
        if s.base.visual != saved.visual {
            s.draft.visual = saved.visual.clone();
        }
        if s.base.windows != saved.windows {
            s.draft.windows = saved.windows;
        }
        s.base = saved.clone();
    });
    let draft = state.read(cx).draft.clone();
    let has_changes = !same(&draft, &saved);

    let reset = {
        let state = state.clone();
        Button::new(("visual-reset", key), "Reset", ButtonStyle::Outline)
            .on_tap(move |_, cx| {
                settings::reset_visual(cx);
                state.update(cx, |s, cx| {
                    s.draft.visual = VisualSettings::default();
                    cx.notify();
                });
            })
            .into_any_element()
    };
    let save = {
        let draft = draft.clone();
        let saved = saved.clone();
        Button::new(("visual-save", key), "Save", ButtonStyle::Primary)
            .disabled(!has_changes)
            .on_tap(move |_, cx| {
                if same(&draft, &saved) {
                    return;
                }
                settings::set_visual(&draft.visual, cx);
                if draft.windows != saved.windows {
                    settings::set_windows(&draft.windows, cx);
                }
            })
            .into_any_element()
    };

    let blur_edit = edit(&state, |d, i: usize| d.visual.backdrop_blur = i == 1);
    let scale_edit = edit(&state, |d, v: f32| d.visual.render_scale = v);
    let hud_edit = edit(&state, |d, v: i32| d.windows.hud_screen = v);
    let touch_edit = edit(&state, |d, v: i32| d.windows.touch_screen = v);

    let rendering = vec![
        toggle(
            ("visual-blur", key),
            draft.visual.backdrop_blur,
            "Solid panels (better GPU performance)",
            "Frosted glass blur effect",
        )
        .label("Backdrop Blur")
        .on_change(move |i, _, cx| blur_edit(i, cx))
        .into_any_element(),
        Slider::new(("visual-scale", key), draft.visual.render_scale)
            .label("Render Scale")
            .snap_points(RENDER_SCALES.to_vec())
            .hints(
                SCALE_HINTS
                    .iter()
                    .map(|(min, l)| SliderHint {
                        min: *min,
                        label: SharedString::from(*l),
                    })
                    .collect(),
            )
            .on_change(move |v, _, cx| scale_edit(v, cx))
            .into_any_element(),
    ];

    let displays = vec![
        screen_selector(
            ("visual-hud-screen", key),
            "HUD Display",
            draft.windows.hud_screen,
            hud_edit,
        )
        .into_any_element(),
        screen_selector(
            ("visual-touch-screen", key),
            "Touchscreen Display",
            draft.windows.touch_screen,
            touch_edit,
        )
        .into_any_element(),
        div()
            .flex()
            .flex_col()
            .gap(u(8.))
            .child(
                div()
                    .text_size(u(14.))
                    .line_height(u(20.))
                    .text_color(ZINC_400)
                    .child(windows::tiling_text(cx)),
            )
            .child(
                Button::new(
                    ("visual-retile", key),
                    "Re-tile Windows",
                    ButtonStyle::Outline,
                )
                .on_tap(|_, cx| {
                    windows::retile(
                        TouchStart {
                            tab: Some(TabId::Visual),
                            ..Default::default()
                        },
                        cx,
                    )
                }),
            )
            .into_any_element(),
    ];

    let diagnostics = vec![
        Button::new(("visual-touch-test", key), "Touch Test", ButtonStyle::Outline)
            .on_tap(|_, cx| crate::touch_test::open_all(cx))
            .into_any_element(),
        info_box("Renderer", renderer_rows(&data, window, cx)).into_any_element(),
    ];

    let columns = div()
        .flex()
        .flex_row()
        .h_full()
        .child(column(("visual-col-rendering", key), "Rendering", false, rendering))
        .child(column(("visual-col-displays", key), "Displays", false, displays))
        .child(column(
            ("visual-col-diag", key),
            "Diagnostics",
            false,
            diagnostics,
        ));

    div()
        .size_full()
        .flex()
        .flex_col()
        .bg(PANEL)
        .child(header("Visual Settings", None, vec![reset, save]))
        .child(
            div().flex_1().min_h_0().child(
                Scroll::new(("visual-strip", key), Axis2::Horizontal)
                    .track(PANEL)
                    .content(div().flex().flex_row().h_full())
                    .child(columns),
            ),
        )
}
