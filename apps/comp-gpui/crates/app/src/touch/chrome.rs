use gpui_kit::prelude::FluentBuilder;
use gpui_kit::*;

use super::{PanelId, TabId, TouchScreen, panels};
use crate::icons::{sf, sf_symbol};
use crate::theme::{
    ACCENT, BLACK, BORDER, DOCK_GAP, DOCK_PAD, DOCK_W, DRAWER_GAP, DRAWER_ICON_COL, DRAWER_PAD,
    DRAWER_W, ICON, RAIL_W, SCRIM, TOUCH_DESIGN, WHITE, alpha, u,
};
use crate::widgets::{Button, ButtonStyle, on_tap, press_state, tappable};

const H: f32 = TOUCH_DESIGN.height;
const BUTTON_W: f32 = 44.0;
const BUTTON_H: f32 = 27.0;
const RAIL_PAD_Y: f32 = 30.0;
const PITCH: f32 = BUTTON_H + 48.0;

/// LeftIcon.tsx, RightIconColumn.tsx. The 48 px span overflows the 27 px
/// button and still takes taps on the web, so the hit box is the span.
fn tab_icon(
    id: impl Into<ElementId>,
    center: Point<f32>,
    symbol: u32,
    active: bool,
    window: &mut Window,
    cx: &mut App,
    f: impl Fn(&mut Window, &mut App) + 'static,
) -> Stateful<Div> {
    let id = id.into();
    let state = press_state(id.clone(), window, cx);
    let el = div()
        .id(id)
        .absolute()
        .left(u(center.x - BUTTON_W * 0.5))
        .top(u(center.y - ICON * 0.5))
        .w(u(BUTTON_W))
        .h(u(ICON))
        .flex()
        .items_center()
        .justify_center()
        .child(sf_symbol(symbol, ICON, if active { ACCENT } else { WHITE }));
    tappable(el, state, false, on_tap(f))
}

fn button_center(x: f32, top: f32) -> Point<f32> {
    point(x + BUTTON_W * 0.5, top + BUTTON_H * 0.5)
}

/// LeftRail.tsx.
pub fn left_rail(
    ts: &TouchScreen,
    window: &mut Window,
    cx: &mut Context<TouchScreen>,
) -> impl IntoElement {
    let x = (RAIL_W - BUTTON_W) * 0.5;
    let entity = cx.entity();
    let mut rail = div()
        .id("left-rail")
        .absolute()
        .top_0()
        .left_0()
        .w(u(RAIL_W))
        .h(u(H))
        .overflow_hidden()
        .occlude();
    let home_symbol = if ts.state.is_driver_base() {
        sf::HOME_FILL
    } else {
        sf::HOME
    };
    let e = entity.clone();
    rail = rail.child(tab_icon(
        "rail-home",
        button_center(x, RAIL_PAD_Y),
        home_symbol,
        ts.state.is_driver_base(),
        window,
        cx,
        move |_, cx| {
            e.update(cx, |this, cx| {
                this.update_state(cx, |s| s.dismiss_overlay())
            })
        },
    ));
    for (i, tab) in ts.state.rail.iter().copied().enumerate() {
        let info = tab.info();
        let active = ts.state.active_tab == Some(tab);
        let e = entity.clone();
        rail = rail.child(tab_icon(
            SharedString::from(format!("rail-{}", tab.key())),
            button_center(x, RAIL_PAD_Y + PITCH * (i + 1) as f32),
            if active {
                info.active_symbol
            } else {
                info.symbol
            },
            active,
            window,
            cx,
            move |_, cx| e.update(cx, |this, cx| this.update_state(cx, |s| s.switch_tab(tab))),
        ));
    }
    let e = entity.clone();
    rail.child(tab_icon(
        "rail-dock",
        button_center(x, H - RAIL_PAD_Y - BUTTON_H),
        sf::DOCK,
        ts.state.dock_open,
        window,
        cx,
        move |_, cx| e.update(cx, |this, cx| this.update_state(cx, |s| s.toggle_dock())),
    ))
}

/// RightPanel.tsx. The content is a fixed 540 px row, so widening reveals
/// it. GPUI has no backdrop blur: only its black/50 tint is drawn.
pub fn right_drawer(
    ts: &TouchScreen,
    window: &mut Window,
    cx: &mut Context<TouchScreen>,
) -> impl IntoElement {
    let rect = ts.drawer_rect();
    let blur = ts.data.read(cx).visual.backdrop_blur;
    let bg = if !ts.state.is_driver_base() {
        BLACK
    } else if blur {
        alpha(BLACK, 0.5)
    } else {
        SCRIM
    };
    let entity = cx.entity();
    let mut row = div().absolute().top_0().left_0().w(u(DRAWER_W)).h(u(H));
    for (i, panel) in PanelId::ALL.iter().copied().enumerate() {
        let info = panel.info();
        let active = ts.state.open_panel == Some(panel);
        let e = entity.clone();
        row = row.child(tab_icon(
            SharedString::from(format!("drawer-{:?}", panel)),
            button_center(DRAWER_PAD, RAIL_PAD_Y + i as f32 * PITCH),
            if active {
                info.active_symbol
            } else {
                info.symbol
            },
            active,
            window,
            cx,
            move |_, cx| {
                e.update(cx, |this, cx| {
                    this.update_state(cx, |s| s.toggle_panel(panel))
                })
            },
        ));
    }
    let body_x = DRAWER_PAD + DRAWER_ICON_COL + DRAWER_GAP;
    let body = div()
        .absolute()
        .left(u(body_x))
        .top(u(DRAWER_PAD))
        .w(u(DRAWER_W - body_x - DRAWER_PAD))
        .h(u(H - 2.0 * DRAWER_PAD))
        .overflow_hidden()
        .when_some(ts.state.display_panel(), |d, panel| {
            d.child(panels::render_panel(ts, panel, cx))
        });
    div()
        .id("right-drawer")
        .absolute()
        .top_0()
        .left(u(rect.origin.x))
        .w(u(rect.size.width))
        .h(u(H))
        .overflow_hidden()
        .occlude()
        .bg(bg)
        .child(
            div()
                .absolute()
                .top_0()
                .left_0()
                .w(u(BORDER))
                .h_full()
                .bg(alpha(ACCENT, ts.drawer_glow.value())),
        )
        .child(row.child(body))
}

fn sf_advance(window: &Window, code: u32, size_px: f32) -> f32 {
    let text = sf::glyph(code);
    let run = TextRun {
        len: text.len(),
        font: font(crate::theme::SF),
        color: Hsla::white(),
        background_color: None,
        underline: None,
        strikethrough: None,
    };
    let line = window
        .text_system()
        .layout_line(&text, px(size_px), &[run], None);
    f32::from(line.width)
}

fn dock_layout(ts: &TouchScreen, window: &Window) -> (Vec<(TabId, Bounds<f32>)>, f32) {
    let inner = DOCK_W - 2.0 * (BORDER + DOCK_PAD);
    let origin = point(BORDER + DOCK_PAD, BORDER + DOCK_PAD);
    let mut out = Vec::new();
    let (mut x, mut row) = (0.0f32, 0usize);
    for tab in ts.state.dock.iter().copied() {
        let info = tab.info();
        let symbol = if ts.state.active_tab == Some(tab) {
            info.active_symbol
        } else {
            info.symbol
        };
        let w = sf_advance(window, symbol, ICON);
        if x > 0.0 && x + w > inner {
            x = 0.0;
            row += 1;
        }
        out.push((
            tab,
            Bounds::new(
                point(origin.x + x, origin.y + row as f32 * (ICON + DOCK_GAP)),
                size(w, ICON),
            ),
        ));
        x += w + DOCK_GAP;
    }
    let rows = row as f32 + 1.0;
    let height = BORDER + DOCK_PAD * 2.0 + rows * ICON + (rows - 1.0) * DOCK_GAP;
    (out, height)
}

pub fn dock_rect(ts: &TouchScreen) -> Bounds<f32> {
    let height = ts.dock_height.get();
    Bounds::new(
        point(
            (TOUCH_DESIGN.width - DOCK_W) * 0.5,
            H - height * ts.dock_t.value(),
        ),
        size(DOCK_W, height),
    )
}

/// DockDrawer.tsx.
pub fn dock(
    ts: &TouchScreen,
    window: &mut Window,
    cx: &mut Context<TouchScreen>,
) -> impl IntoElement {
    let (items, height) = dock_layout(ts, window);
    ts.dock_height.set(height);
    let rect = dock_rect(ts);
    let blur = ts.data.read(cx).visual.backdrop_blur;
    let entity = cx.entity();
    let mut panel = div()
        .id("dock")
        .absolute()
        .left(u(rect.origin.x))
        .top(u(rect.origin.y))
        .w(u(DOCK_W))
        .h(u(height))
        .overflow_hidden()
        .occlude()
        .bg(if blur { alpha(BLACK, 0.5) } else { SCRIM })
        .border_t(u(BORDER))
        .border_l(u(BORDER))
        .border_r(u(BORDER))
        .border_color(ACCENT);
    for (tab, b) in items {
        let info = tab.info();
        let active = ts.state.active_tab == Some(tab);
        let e = entity.clone();
        let id = SharedString::from(format!("dock-{}", tab.key()));
        let state = press_state(id.clone(), window, cx);
        let item = div()
            .id(id)
            .absolute()
            .left(u(b.origin.x - BORDER))
            .top(u(b.origin.y - BORDER))
            .w(u(b.size.width))
            .h(u(ICON))
            .flex()
            .items_center()
            .child(sf_symbol(
                if active {
                    info.active_symbol
                } else {
                    info.symbol
                },
                ICON,
                if active { ACCENT } else { WHITE },
            ));
        panel = panel.child(tappable(
            item,
            state,
            false,
            on_tap(move |_, cx| {
                e.update(cx, |this, cx| this.update_state(cx, |s| s.switch_tab(tab)))
            }),
        ));
    }
    panel
}

/// DriverTab.tsx.
pub fn driver_view(ts: &TouchScreen, cx: &mut Context<TouchScreen>) -> impl IntoElement {
    let entity = cx.entity();
    let pills = (0..4usize).map(|i| {
        let e = entity.clone();
        Button::new(("preset", i), format!("{}", i + 1), ButtonStyle::Pill)
            .selected(ts.driver_preset == i)
            .on_tap(move |_, cx| {
                e.update(cx, |this, cx| {
                    this.driver_preset = i;
                    cx.notify();
                })
            })
    });
    div()
        .absolute()
        .top_0()
        .left(u(RAIL_W))
        .w(u(TOUCH_DESIGN.width - RAIL_W))
        .h(u(H))
        .child(crate::placeholder::view3d("Driver view (3D)"))
        .child(
            div()
                .absolute()
                .left_0()
                .right_0()
                .bottom(u(24.))
                .flex()
                .justify_center()
                .gap(u(8.))
                .children(pills),
        )
}
