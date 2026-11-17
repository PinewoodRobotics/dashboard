use dash_core::settings::connection::{
    Drafts, Field, Preview, TIMEOUT_UI_MAX_S, TIMEOUT_UI_MIN_S, evaluate_form,
};
use gpui_kit::prelude::FluentBuilder;
use gpui_kit::*;

use super::TouchScreen;
use crate::mock::{ConnectionSettings, MockData};
use crate::settings;
use crate::theme::{
    ACCENT, ERROR, HAIRLINE, MONO, PANEL, WHITE, ZINC_100, ZINC_500, touch_weight, u,
};
use crate::widgets::{Axis2, Button, ButtonStyle, Scroll, Slider, TextInput, label, tracked};

const VALUE_LABEL: &str = "{v}s \u{2014} close stuck connections after this many seconds";
const WRITE_FAILED: &str = "Could not write the settings file";

/// The drafts and the saved settings they were loaded from: when the saved
/// settings change (Save, Reset, an edit by another app) the drafts reload.
struct FormState {
    drafts: Drafts,
    base: ConnectionSettings,
    save_error: String,
}

/// CSS `word-break: break-all`: any character may end a line.
fn break_all(s: &str) -> String {
    let mut out = String::with_capacity(s.len() * 4);
    for (i, c) in s.chars().enumerate() {
        if i > 0 {
            out.push('\u{200B}');
        }
        out.push(c);
    }
    out
}

fn preview_rows(p: Preview) -> Vec<(&'static str, String)> {
    vec![
        ("Host", p.host),
        ("Request topic", p.request),
        ("State topic", p.state),
        ("Robot constants", p.robot_constants),
    ]
}

/// NetworkTablesPreview.tsx.
pub(super) fn info_box(caption: &str, rows: Vec<(&'static str, String)>) -> Div {
    div()
        .flex()
        .flex_col()
        .gap(u(8.))
        .child(tracked(caption, 12., 600, 0.2, 16., WHITE))
        .child(
            div()
                .flex()
                .flex_col()
                .border(u(2.))
                .border_color(HAIRLINE)
                .children(rows.into_iter().enumerate().map(|(i, (k, v))| {
                    div()
                        .flex()
                        .flex_col()
                        .gap(u(4.))
                        .px(u(20.))
                        .py(u(16.))
                        .when(i > 0, |d| d.border_t(u(2.)).border_color(HAIRLINE))
                        .child(
                            div()
                                .text_size(u(12.))
                                .line_height(u(16.))
                                .text_color(ZINC_500)
                                .child(k),
                        )
                        .child(
                            div()
                                .font_family(MONO)
                                .text_size(u(16.))
                                .line_height(u(24.))
                                .text_color(ZINC_100)
                                .child(break_all(&v)),
                        )
                })),
        )
}

/// SettingsColumn.tsx.
pub(super) fn column(
    id: impl Into<ElementId>,
    title: &str,
    bordered: bool,
    children: Vec<AnyElement>,
) -> Div {
    div()
        .flex_none()
        .w(u(420.))
        .h_full()
        .when(bordered, |d| d.border_r(u(2.)).border_color(HAIRLINE))
        .child(
            Scroll::new(id, Axis2::Vertical)
                .content(div().flex().flex_col().gap(u(28.)).p(u(32.)))
                .child(label(title.to_owned(), 24., 600, WHITE))
                .children(children),
        )
}

/// SettingsHeader.tsx.
pub fn header(title: &str, status: Option<(bool, SharedString)>, buttons: Vec<AnyElement>) -> Div {
    div()
        .flex_none()
        .flex()
        .items_center()
        .justify_between()
        .gap(u(24.))
        .px(u(32.))
        .py(u(20.))
        .border_b(u(2.))
        .border_color(HAIRLINE)
        .child(
            div()
                .flex()
                .items_center()
                .gap(u(16.))
                .child(
                    div()
                        .font_weight(touch_weight(600))
                        .text_size(u(28.))
                        .line_height(u(28.))
                        .text_color(WHITE)
                        .whitespace_nowrap()
                        .child(title.to_owned()),
                )
                .when_some(status, |d, (ok, text)| {
                    let color = if ok { ACCENT } else { ERROR };
                    d.child(
                        div()
                            .flex()
                            .items_center()
                            .gap(u(8.))
                            .child(div().flex_none().size(u(10.)).rounded_full().bg(color))
                            .child(label(text, 14., 600, color).line_height(u(20.))),
                    )
                }),
        )
        .child(
            div()
                .flex()
                .flex_none()
                .items_center()
                .gap(u(12.))
                .h(u(48.))
                .children(buttons),
        )
}

/// Godot's _load_drafts after Save and Reset: the drafts show the saved
/// settings even when the write changed nothing or failed.
fn after_write(
    state: &Entity<FormState>,
    data: &Entity<MockData>,
    r: Result<(), String>,
    cx: &mut App,
) {
    if let Err(e) = &r {
        eprintln!("comp-gpui: settings: {e}");
    }
    let saved = data.read(cx).connection.clone();
    state.update(cx, |s, cx| {
        s.drafts = Drafts::from(&saved);
        s.base = saved;
        s.save_error = if r.is_ok() {
            String::new()
        } else {
            WRITE_FAILED.into()
        };
        cx.notify();
    });
}

/// TouchscreenSettingsPanel.tsx as the Godot port shows it: the Autobahn
/// column is dropped (there is no Autobahn), and Diagnostics and Autos
/// columns follow the web's. Save and Reset write the shared settings file.
pub fn render(
    ts: &TouchScreen,
    key: u64,
    window: &mut Window,
    cx: &mut Context<TouchScreen>,
) -> impl IntoElement {
    let data = ts.data.clone();
    let saved = data.read(cx).connection.clone();
    let state = window.use_keyed_state(("settings-drafts", key), cx, |_, _| FormState {
        drafts: Drafts::from(&saved),
        base: saved.clone(),
        save_error: String::new(),
    });
    state.update(cx, |s, _| {
        if s.base != saved {
            s.drafts = Drafts::from(&saved);
            s.base = saved.clone();
        }
    });
    let d = state.read(cx).drafts.clone();
    let save_error = state.read(cx).save_error.clone();
    let form = evaluate_form(&d, &saved);
    let snapshot: MockData = data.read(cx).clone();
    let connected = snapshot.nt_connected;

    let set = |f: fn(&mut Drafts, String)| {
        let state = state.clone();
        move |v: String, _: &mut Window, cx: &mut App| {
            state.update(cx, |s, cx| {
                f(&mut s.drafts, v);
                cx.notify();
            })
        }
    };
    let field =
        |id: &str, caption: &str, value: &str, placeholder: &str, numeric: bool, invalid: bool| {
            TextInput::new(SharedString::from(format!("{id}-{key}")), value.to_owned())
                .label(caption.to_owned())
                .placeholder(placeholder.to_owned())
                .numeric(numeric)
                .invalid(invalid)
        };

    let mut buttons: Vec<AnyElement> = Vec::new();
    if !connected {
        let data = data.clone();
        buttons.push(
            Button::new(
                ("settings-reconnect", key),
                "Reconnect",
                ButtonStyle::Outline,
            )
            .on_tap(move |_, cx| {
                data.update(cx, |d, cx| {
                    d.request_reconnect();
                    cx.notify();
                })
            })
            .into_any_element(),
        );
    }
    {
        let state = state.clone();
        let data = data.clone();
        buttons.push(
            Button::new(("settings-reset", key), "Reset", ButtonStyle::Outline)
                .on_tap(move |_, cx| {
                    let r = settings::reset_connection(cx);
                    after_write(&state, &data, r, cx);
                })
                .into_any_element(),
        );
    }
    {
        let state = state.clone();
        let data = data.clone();
        let next = form.next.clone();
        let enabled = form.save_enabled;
        buttons.push(
            Button::new(("settings-save", key), "Save", ButtonStyle::Primary)
                .disabled(!enabled)
                .on_tap(move |_, cx| {
                    if enabled {
                        let r = settings::save_connection(&next, cx);
                        after_write(&state, &data, r, cx);
                    }
                })
                .into_any_element(),
        );
    }

    let diagnostics = snapshot.nt.rows();

    let state_timeout = state.clone();
    let columns = div()
        .flex()
        .flex_row()
        .h_full()
        .child(column(
            ("settings-col-nt", key),
            "NetworkTables",
            true,
            vec![
                field(
                    "settings-host",
                    "Robot NT Host / IP",
                    &d.host,
                    "10.47.65.2",
                    false,
                    form.is_invalid(Field::Host),
                )
                .on_change(set(|d, v| d.host = v))
                .into_any_element(),
                field(
                    "settings-port",
                    "NT Port",
                    &d.port,
                    "5810",
                    true,
                    form.is_invalid(Field::Port),
                )
                .on_change(set(|d, v| d.port = v))
                .into_any_element(),
                field(
                    "settings-table",
                    "Shared Table",
                    &d.shared_table,
                    "Shared/PathPlanner",
                    false,
                    form.is_invalid(Field::SharedTable),
                )
                .on_change(set(|d, v| d.shared_table = v))
                .into_any_element(),
                field(
                    "settings-entry",
                    "Request Topic Base",
                    &d.selected_path_topic,
                    "SelectedPath",
                    false,
                    form.is_invalid(Field::SelectedPathTopic),
                )
                .on_change(set(|d, v| d.selected_path_topic = v))
                .into_any_element(),
            ],
        ))
        .child(column(
            ("settings-col-connection", key),
            "Connection",
            false,
            vec![
                Slider::new(("settings-timeout", key), d.reconnect_timeout_s)
                    .label("Reconnect Timeout")
                    .range(TIMEOUT_UI_MIN_S as f32, TIMEOUT_UI_MAX_S as f32)
                    .step(1.0)
                    .decimals(0)
                    .value_label(VALUE_LABEL)
                    .on_change(move |v, _, cx| {
                        state_timeout.update(cx, |s, cx| {
                            s.drafts.reconnect_timeout_s = v;
                            cx.notify();
                        })
                    })
                    .into_any_element(),
            ],
        ))
        .child(column(
            ("settings-col-preview", key),
            "Preview",
            false,
            vec![info_box("NT Preview", preview_rows(form.preview.clone())).into_any_element()],
        ))
        .child(column(
            ("settings-col-diag", key),
            "Diagnostics",
            false,
            vec![info_box("NT Client", diagnostics).into_any_element()],
        ))
        .child(column(
            ("settings-col-autos", key),
            "Autos",
            false,
            vec![super::auto_tab::export_box(key, cx).into_any_element()],
        ));

    let ok = connected && save_error.is_empty();
    let status_text = if !save_error.is_empty() {
        save_error
    } else if connected {
        "Connected".into()
    } else {
        "Disconnected".into()
    };
    div()
        .size_full()
        .flex()
        .flex_col()
        .bg(PANEL)
        .child(header(
            "Connection Settings",
            Some((ok, SharedString::from(status_text))),
            buttons,
        ))
        .child(
            div().flex_1().min_h_0().child(
                Scroll::new(("settings-strip", key), Axis2::Horizontal)
                    .track(PANEL)
                    .content(div().flex().flex_row().h_full())
                    .child(columns),
            ),
        )
}
