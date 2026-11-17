use gpui_kit::*;

use super::{PanelId, TouchScreen};
use crate::icons::sf;
use crate::mock::{MapMode, MapSettings};
use crate::theme::{INTER, WHITE, ZINC_400, touch_weight, u};
use crate::widgets::{
    Axis2, Button, ButtonStyle, Scroll, Selector, SelectorOption, Slider, SliderHint,
};

const TITLE_PX: f32 = 36.0;
// CSS `line-height: normal` for Inter: (ascender + descender) / em.
const INTER_NORMAL: f32 = (1984.0 + 494.0) / 2048.0;

fn title(text: impl Into<SharedString>) -> Div {
    div()
        .font_family(INTER)
        .font_weight(touch_weight(500))
        .text_size(u(TITLE_PX))
        .line_height(u(TITLE_PX * INTER_NORMAL))
        .text_color(WHITE)
        .whitespace_nowrap()
        .child(text.into())
}

fn hints(entries: &[(f32, &str)]) -> Vec<SliderHint> {
    entries
        .iter()
        .map(|(min, l)| SliderHint {
            min: *min,
            label: SharedString::from(l.to_string()),
        })
        .collect()
}

pub fn render_panel(ts: &TouchScreen, panel: PanelId, cx: &mut Context<TouchScreen>) -> AnyElement {
    match panel {
        PanelId::Map => map_panel(ts, cx).into_any_element(),
        PanelId::Intake => coming_soon(panel).into_any_element(),
    }
}

/// RightSideContent.tsx's body for panels without controls yet.
fn coming_soon(panel: PanelId) -> Div {
    div()
        .flex()
        .flex_col()
        .items_start()
        .p(u(10.))
        .size_full()
        .child(title(format!("{} Settings", panel.info().label)))
        .child(
            div()
                .mt(u(16.))
                .text_size(u(14.))
                .line_height(u(20.))
                .text_color(ZINC_400)
                .child("Controls coming soon."),
        )
}

/// MapSettingsPanel.tsx.
fn map_panel(ts: &TouchScreen, cx: &mut Context<TouchScreen>) -> Div {
    let map = ts.data.read(cx).map.clone();
    let data = ts.data.clone();
    let set = move |f: Box<dyn FnOnce(&mut MapSettings)>, cx: &mut App| {
        data.update(cx, |d, cx| {
            f(&mut d.map);
            cx.notify();
        });
    };
    let set = std::rc::Rc::new(set);
    let (s1, s2, s3, s4) = (set.clone(), set.clone(), set.clone(), set);

    let mode = Selector::new(
        "map-mode",
        vec![
            SelectorOption::new(sf::MODE_DRIVER)
                .filled(sf::MODE_DRIVER_FILL)
                .hint("Camera is aligned to the driver station"),
            SelectorOption::new(sf::MODE_FOLLOW)
                .filled(sf::MODE_FOLLOW_FILL)
                .hint("Camera orbits to follow robot rotation"),
        ],
        if map.mode == MapMode::Driver { 0 } else { 1 },
    )
    .label("Mode")
    .on_change(move |i, _, cx| {
        s1(
            Box::new(move |m| {
                m.mode = if i == 0 {
                    MapMode::Driver
                } else {
                    MapMode::Follow
                }
            }),
            cx,
        )
    });

    let angle = Slider::new("map-angle", map.angle)
        .label("Angle")
        .hints(hints(&[
            (0.0, "Camera is close to the ground"),
            (0.1, "Standard third person camera view"),
            (0.5, "Camera view from up high"),
            (0.9, "Top down camera view"),
        ]))
        .on_change(move |v, _, cx| s2(Box::new(move |m| m.angle = v), cx));

    let zoom = Slider::new("map-zoom", map.zoom)
        .label("Zoom")
        .hints(hints(&[
            (
                0.0,
                "Zoomed out to field width (best in driver aligned camera)",
            ),
            (0.2, "Moderate camera distance from robot"),
            (0.6, "Close camera distance to robot"),
        ]))
        .on_change(move |v, _, cx| s3(Box::new(move |m| m.zoom = v), cx));

    let reset = Button::new("map-reset", "Reset", ButtonStyle::OutlineBlock)
        .on_tap(move |_, cx| s4(Box::new(|m| *m = MapSettings::default()), cx));

    div()
        .flex()
        .flex_col()
        .items_start()
        .p(u(16.))
        .size_full()
        .child(title("Map Settings"))
        .child(
            div().mt(u(16.)).w_full().flex_1().min_h_0().child(
                Scroll::new("map-scroll", Axis2::Vertical)
                    .content(div().flex().flex_col().gap(u(20.)).pr(u(10.)))
                    .child(mode)
                    .child(angle)
                    .child(zoom)
                    .child(reset),
            ),
        )
}
