use gpui_kit::prelude::FluentBuilder;
use gpui_kit::*;

use super::TouchScreen;
use crate::mock::{ConnectionSettings, MockData};
use crate::theme::{
    ACCENT, ERROR, HAIRLINE, MONO, PANEL, WHITE, ZINC_100, ZINC_400, ZINC_500, touch_weight, u,
};
use crate::widgets::{Axis2, Button, ButtonStyle, Scroll, Slider, TextInput, label, tracked};

const TIMEOUT_MIN_S: f32 = 2.0;
const TIMEOUT_MAX_S: f32 = 30.0;
const VALUE_LABEL: &str = "{v}s \u{2014} close stuck connections after this many seconds";

#[derive(Clone, Debug, PartialEq)]
struct Drafts {
    host: String,
    port: String,
    table: String,
    entry: String,
    timeout: f32,
}

impl Drafts {
    fn from(c: &ConnectionSettings) -> Self {
        Self {
            host: c.nt_host.clone(),
            port: c.nt_port.clone(),
            table: c.shared_table.clone(),
            entry: c.request_topic_base.clone(),
            timeout: c.reconnect_timeout_s,
        }
    }
}

struct Form {
    invalid_host: bool,
    invalid_port: bool,
    invalid_table: bool,
    invalid_entry: bool,
    save_enabled: bool,
    next: ConnectionSettings,
}

/// useTouchscreenSettingsForm.ts: Save is enabled only when the form is valid
/// and differs from the saved settings.
fn evaluate(d: &Drafts, saved: &ConnectionSettings) -> Form {
    let host = d.host.trim().to_owned();
    let port = d
        .port
        .trim()
        .parse::<u32>()
        .ok()
        .filter(|p| (1..=65535).contains(p));
    let table = d.table.trim().to_owned();
    let entry = d.entry.trim().to_owned();
    let timeout = d.timeout.round();
    let next = ConnectionSettings {
        nt_host: host.clone(),
        nt_port: port.map(|p| p.to_string()).unwrap_or_default(),
        shared_table: table.clone(),
        request_topic_base: entry.clone(),
        reconnect_timeout_s: timeout,
    };
    let invalid_host = host.is_empty();
    let invalid_port = port.is_none();
    let invalid_table = table.is_empty();
    let invalid_entry = entry.is_empty();
    let valid = !(invalid_host || invalid_port || invalid_table || invalid_entry);
    Form {
        invalid_host,
        invalid_port,
        invalid_table,
        invalid_entry,
        save_enabled: valid && next != *saved,
        next,
    }
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

fn trim_slashes(s: &str) -> &str {
    s.trim_matches('/')
}

/// The NT Preview rows (ntSelectedPathTopics).
fn preview(d: &Drafts) -> Vec<(&'static str, String)> {
    let base = format!(
        "/{}/{}",
        trim_slashes(d.table.trim()),
        trim_slashes(d.entry.trim())
    );
    let bare = base.trim_start_matches('/');
    vec![
        (
            "Host",
            if d.host.trim().is_empty() {
                "(not set)".to_owned()
            } else {
                d.host.trim().to_owned()
            },
        ),
        ("Request topic", format!("{base}/Request")),
        ("State topic", format!("{base}/State")),
        ("Robot constants", format!("{bare}/Request / {bare}/State")),
    ]
}

/// NetworkTablesPreview.tsx.
fn info_box(caption: &str, rows: Vec<(&'static str, String)>) -> Div {
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
fn column(id: impl Into<ElementId>, title: &str, bordered: bool, children: Vec<AnyElement>) -> Div {
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

/// TouchscreenSettingsPanel.tsx as the Godot port shows it: the Autobahn
/// column is dropped (there is no Autobahn), and Diagnostics and Autos
/// columns follow the web's.
pub fn render(
    ts: &TouchScreen,
    key: u64,
    window: &mut Window,
    cx: &mut Context<TouchScreen>,
) -> impl IntoElement {
    let data = ts.data.clone();
    let saved = data.read(cx).connection.clone();
    let drafts = window.use_keyed_state(("settings-drafts", key), cx, |_, _| Drafts::from(&saved));
    let d = drafts.read(cx).clone();
    let form = evaluate(&d, &saved);
    let snapshot: MockData = data.read(cx).clone();
    let connected = snapshot.nt_connected;

    let set = |f: fn(&mut Drafts, String)| {
        let drafts = drafts.clone();
        move |v: String, _: &mut Window, cx: &mut App| {
            drafts.update(cx, |d, cx| {
                f(d, v);
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
                    d.nt.reconnects += 1;
                    cx.notify();
                })
            })
            .into_any_element(),
        );
    }
    {
        let data = data.clone();
        let drafts = drafts.clone();
        buttons.push(
            Button::new(("settings-reset", key), "Reset", ButtonStyle::Outline)
                .on_tap(move |_, cx| {
                    let defaults = ConnectionSettings::default();
                    drafts.update(cx, |d, cx| {
                        *d = Drafts::from(&defaults);
                        cx.notify();
                    });
                    data.update(cx, |d, cx| {
                        d.connection = defaults;
                        cx.notify();
                    });
                })
                .into_any_element(),
        );
    }
    {
        let data = data.clone();
        let drafts = drafts.clone();
        let next = form.next.clone();
        buttons.push(
            Button::new(("settings-save", key), "Save", ButtonStyle::Primary)
                .disabled(!form.save_enabled)
                .on_tap(move |_, cx| {
                    let next = next.clone();
                    drafts.update(cx, |d, cx| {
                        *d = Drafts::from(&next);
                        cx.notify();
                    });
                    data.update(cx, |d, cx| {
                        d.connection = next;
                        cx.notify();
                    });
                })
                .into_any_element(),
        );
    }

    let nt = &snapshot.nt;
    let diagnostics = vec![
        ("State", nt.state.to_owned()),
        (
            "Attempt",
            if connected {
                "Connected".to_owned()
            } else {
                "Connecting, attempt 1 (0.4 s)".to_owned()
            },
        ),
        ("Server", nt.server.clone()),
        (
            "Round trip",
            nt.rtt_ms
                .filter(|_| connected)
                .map(|r| format!("{r:.1} ms"))
                .unwrap_or_else(|| "--".into()),
        ),
        ("Reconnects", format!("{} (manual 0)", nt.reconnects)),
        ("Last close", "--".to_owned()),
    ];

    let drafts_timeout = drafts.clone();
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
                    form.invalid_host,
                )
                .on_change(set(|d, v| d.host = v))
                .into_any_element(),
                field(
                    "settings-port",
                    "NT Port",
                    &d.port,
                    "5810",
                    true,
                    form.invalid_port,
                )
                .on_change(set(|d, v| d.port = v))
                .into_any_element(),
                field(
                    "settings-table",
                    "Shared Table",
                    &d.table,
                    "Shared/PathPlanner",
                    false,
                    form.invalid_table,
                )
                .on_change(set(|d, v| d.table = v))
                .into_any_element(),
                field(
                    "settings-entry",
                    "Request Topic Base",
                    &d.entry,
                    "SelectedPath",
                    false,
                    form.invalid_entry,
                )
                .on_change(set(|d, v| d.entry = v))
                .into_any_element(),
            ],
        ))
        .child(column(
            ("settings-col-connection", key),
            "Connection",
            false,
            vec![
                Slider::new(("settings-timeout", key), d.timeout)
                    .label("Reconnect Timeout")
                    .range(TIMEOUT_MIN_S, TIMEOUT_MAX_S)
                    .step(1.0)
                    .decimals(0)
                    .value_label(VALUE_LABEL)
                    .on_change(move |v, _, cx| {
                        drafts_timeout.update(cx, |d, cx| {
                            d.timeout = v;
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
            vec![info_box("NT Preview", preview(&d)).into_any_element()],
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
            vec![
                div()
                    .flex()
                    .flex_col()
                    .gap(u(8.))
                    .child(
                        div()
                            .text_size(u(14.))
                            .line_height(u(20.))
                            .text_color(ZINC_400)
                            .child(format!(
                                "{} autos \u{b7} built-in\nexported 2026-11-14 18:02 UTC",
                                snapshot.autos.len()
                            )),
                    )
                    .child(Button::new(
                        ("settings-reload-autos", key),
                        "Reload Autos",
                        ButtonStyle::Outline,
                    ))
                    .into_any_element(),
            ],
        ));

    let status = (
        connected,
        SharedString::from(if connected {
            "Connected"
        } else {
            "Disconnected"
        }),
    );
    div()
        .size_full()
        .flex()
        .flex_col()
        .bg(PANEL)
        .child(header("Connection Settings", Some(status), buttons))
        .child(
            div().flex_1().min_h_0().child(
                Scroll::new(("settings-strip", key), Axis2::Horizontal)
                    .track(PANEL)
                    .content(div().flex().flex_row().h_full())
                    .child(columns),
            ),
        )
}
