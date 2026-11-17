use gpui_kit::*;

use super::{TabId, TouchScreen, settings_tab};
use crate::icons::sf;
use crate::theme::{PANEL, SF, WHITE, ZINC_400, u};
use crate::widgets::{
    Axis2, Button, ButtonStyle, Scroll, Selector, SelectorOption, Slider, SliderHint, TextInput,
    label, toggle,
};

pub fn render_tab(
    ts: &TouchScreen,
    id: TabId,
    key: u64,
    window: &mut Window,
    cx: &mut Context<TouchScreen>,
) -> AnyElement {
    match id {
        TabId::Settings => settings_tab::render(ts, key, window, cx).into_any_element(),
        TabId::Effects => coming_soon("Special effects tab").into_any_element(),
        TabId::Robot3d => crate::placeholder::view3d("Robot 3D view (3D)").into_any_element(),
        TabId::Gallery => gallery(key, window, cx).into_any_element(),
        TabId::Auto | TabId::Howard | TabId::Visual => not_ported(id).into_any_element(),
    }
}

/// PlaceholderScreen.tsx.
fn coming_soon(title: &str) -> Div {
    div()
        .size_full()
        .flex()
        .items_center()
        .justify_center()
        .font_family(SF)
        .text_size(u(48.))
        .line_height(u(72.))
        .text_color(WHITE)
        .child(format!("{title} is coming soon\u{2122}"))
}

fn not_ported(id: TabId) -> Div {
    div()
        .size_full()
        .bg(PANEL)
        .flex()
        .flex_col()
        .items_center()
        .justify_center()
        .gap(u(8.))
        .child(label(id.info().label, 28., 600, WHITE))
        .child(label("Not ported to GPUI yet", 16., 400, ZINC_400))
}

#[derive(Default)]
struct GalleryState {
    speed: f32,
    snap: f32,
    trim: f32,
    mode: usize,
    blur: bool,
    host: String,
    port: String,
    presses: u32,
}

/// Every widget of the kit on one strip (the Godot port's widget gallery).
fn gallery(key: u64, window: &mut Window, cx: &mut Context<TouchScreen>) -> impl IntoElement {
    let state = window.use_keyed_state(("gallery", key), cx, |_, _| GalleryState {
        speed: 0.6,
        snap: 0.5,
        trim: 0.0,
        mode: 1,
        blur: true,
        host: "10.47.65.2".into(),
        port: "5810".into(),
        presses: 0,
    });
    let s = state.read(cx);
    let set = |f: fn(&mut GalleryState, f32)| {
        let st = state.clone();
        move |v: f32, _: &mut Window, cx: &mut App| {
            st.update(cx, |s, cx| {
                f(s, v);
                cx.notify();
            })
        }
    };
    let st = state.clone();
    let st2 = state.clone();
    let st3 = state.clone();
    let st4 = state.clone();
    let st5 = state.clone();
    let st6 = state.clone();

    let col = |id: &str, title: &str, children: Vec<AnyElement>| {
        div()
            .flex_none()
            .w(u(420.))
            .h_full()
            .border_r(u(2.))
            .border_color(crate::theme::HAIRLINE)
            .child(
                Scroll::new(SharedString::from(id.to_owned()), Axis2::Vertical)
                    .content(div().flex().flex_col().gap(u(28.)).p(u(32.)))
                    .child(label(title.to_owned(), 24., 600, WHITE))
                    .children(children),
            )
    };

    let sliders = col(
        "gallery-sliders",
        "Sliders",
        vec![
            Slider::new(("g-speed", key), s.speed)
                .label("Intake Speed")
                .decimals(2)
                .value_label("{v} of full speed")
                .on_change(set(|s, v| s.speed = v))
                .into_any_element(),
            Slider::new(("g-snap", key), s.snap)
                .label("Render Scale")
                .snap_points(vec![0.25, 0.5, 0.75, 1.0])
                .hints(vec![
                    SliderHint {
                        min: 0.0,
                        label: "0.25x: for struggling hardware".into(),
                    },
                    SliderHint {
                        min: 0.4,
                        label: "0.5x: moderate quality loss".into(),
                    },
                    SliderHint {
                        min: 0.62,
                        label: "0.75: barely noticeable quality loss".into(),
                    },
                    SliderHint {
                        min: 0.87,
                        label: "1: native resolution, full quality".into(),
                    },
                ])
                .on_change(set(|s, v| s.snap = v))
                .into_any_element(),
            Slider::new(("g-trim", key), s.trim)
                .range(-5.0, 5.0)
                .step(0.5)
                .decimals(1)
                .label("Aim Trim")
                .value_label("{v} deg")
                .reversed(true)
                .on_change(set(|s, v| s.trim = v))
                .into_any_element(),
            Slider::new(("g-disabled", key), 0.3)
                .label("Disabled")
                .disabled(true)
                .into_any_element(),
        ],
    );

    let selectors = col(
        "gallery-selectors",
        "Selectors",
        vec![
            Selector::new(
                ("g-mode", key),
                vec![
                    SelectorOption::new(sf::MODE_DRIVER)
                        .filled(sf::MODE_DRIVER_FILL)
                        .hint("Driver aligned"),
                    SelectorOption::new(sf::MODE_FOLLOW)
                        .filled(sf::MODE_FOLLOW_FILL)
                        .hint("Follow robot"),
                    SelectorOption::new(sf::MAP)
                        .filled(sf::MAP_FILL)
                        .hint("Field map"),
                ],
                s.mode,
            )
            .label("Mode")
            .on_change(move |i, _, cx| {
                st.update(cx, |s, cx| {
                    s.mode = i;
                    cx.notify();
                })
            })
            .into_any_element(),
            toggle(
                ("g-blur", key),
                s.blur,
                "Solid panels (better GPU performance)",
                "Frosted glass blur effect",
            )
            .label("Backdrop Blur")
            .on_change(move |i, _, cx| {
                st2.update(cx, |s, cx| {
                    s.blur = i == 1;
                    cx.notify();
                })
            })
            .into_any_element(),
        ],
    );

    let inputs = col(
        "gallery-inputs",
        "Text Inputs",
        vec![
            TextInput::new(("g-host", key), s.host.clone())
                .label("Robot NT Host / IP")
                .placeholder("10.47.65.2")
                .on_change(move |v, _, cx| {
                    st3.update(cx, |s, cx| {
                        s.host = v;
                        cx.notify();
                    })
                })
                .into_any_element(),
            TextInput::new(("g-port", key), s.port.clone())
                .label("NT Port")
                .placeholder("5810")
                .numeric(true)
                .invalid(s.port.is_empty())
                .on_change(move |v, _, cx| {
                    st4.update(cx, |s, cx| {
                        s.port = v;
                        cx.notify();
                    })
                })
                .into_any_element(),
        ],
    );

    let presses = s.presses;
    let buttons = col(
        "gallery-buttons",
        "Buttons",
        vec![
            div()
                .flex()
                .gap(u(12.))
                .child(
                    Button::new(("g-outline", key), "Reset", ButtonStyle::Outline).on_tap(
                        move |_, cx| {
                            st5.update(cx, |s, cx| {
                                s.presses += 1;
                                cx.notify();
                            })
                        },
                    ),
                )
                .child(
                    Button::new(("g-primary", key), "Save", ButtonStyle::Primary).on_tap(
                        move |_, cx| {
                            st6.update(cx, |s, cx| {
                                s.presses += 1;
                                cx.notify();
                            })
                        },
                    ),
                )
                .child(
                    Button::new(("g-primary-off", key), "Save", ButtonStyle::Primary)
                        .disabled(true),
                )
                .into_any_element(),
            Button::new(("g-block", key), "Reset", ButtonStyle::OutlineBlock).into_any_element(),
            div()
                .flex()
                .gap(u(8.))
                .children((0..4).map(|i| {
                    Button::new(
                        ("g-pill", i as usize),
                        format!("{}", i + 1),
                        ButtonStyle::Pill,
                    )
                    .selected(i == 0)
                }))
                .into_any_element(),
            label(format!("Taps: {presses}"), 16., 400, ZINC_400).into_any_element(),
            div()
                .flex()
                .flex_col()
                .gap(u(8.))
                .children((1..=12).map(|i| label(format!("Scroll row {i}"), 18., 400, WHITE)))
                .into_any_element(),
        ],
    );

    div().size_full().bg(PANEL).child(
        Scroll::new(("gallery-strip", key), Axis2::Horizontal)
            .track(PANEL)
            .content(div().flex().flex_row().h_full())
            .child(sliders)
            .child(selectors)
            .child(inputs)
            .child(buttons),
    )
}
