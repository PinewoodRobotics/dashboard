use gpui_kit::prelude::FluentBuilder;
use gpui_kit::*;

use dash_core::dnd::Zone;

use super::{LayoutState, PanelId, TabId, TouchScreen, dnd, panels};
use crate::icons::{sf, sf_symbol};
use crate::theme::{
    ACCENT, BLACK, BORDER, DOCK_GAP, DOCK_PAD, DOCK_W, DRAWER_GAP, DRAWER_ICON_COL, DRAWER_PAD,
    DRAWER_W, ICON, RAIL_W, SCRIM, TOUCH_DESIGN, WHITE, alpha, u,
};
use crate::widgets::{Button, ButtonStyle, dpx, on_tap, press_state, tappable};

const H: f32 = TOUCH_DESIGN.height;
const BUTTON_W: f32 = 44.0;
const BUTTON_H: f32 = 27.0;
const RAIL_PAD_Y: f32 = 30.0;
const PITCH: f32 = BUTTON_H + 48.0;
const PRESET_COUNT: usize = 4;
const PRESET: f32 = 40.0;
const PRESET_GAP: f32 = 8.0;
const PRESET_BOTTOM: f32 = 24.0;
const BACKDROP_BLUR: f32 = 8.0;
const DOCK_FROST: Rgba = alpha(BLACK, 0.8);
const DRIVER_BG: Rgba = crate::placeholder::VIEW3D_FILL;

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

/// The button box of the rail's pinned tab `index`, below the home button.
pub fn rail_slot(index: usize) -> Bounds<f32> {
    Bounds::new(
        point(
            (RAIL_W - BUTTON_W) * 0.5,
            RAIL_PAD_Y + PITCH * (index + 1) as f32,
        ),
        size(BUTTON_W, BUTTON_H),
    )
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
        let slot = rail_slot(i);
        let bx = Bounds::new(
            point(slot.origin.x, slot.origin.y + (BUTTON_H - ICON) * 0.5),
            size(BUTTON_W, ICON),
        );
        let active = ts.state.active_tab == Some(tab);
        rail = rail.child(dnd::sortable_icon(ts, Zone::Rail, tab, bx, active, cx));
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
            d.child(panels::render_panel(ts, panel, window, cx))
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

/// Item spans in dock panel coordinates (border box), and the panel height.
pub fn dock_layout(state: &LayoutState, window: &Window) -> (Vec<(TabId, Bounds<f32>)>, f32) {
    let inner = DOCK_W - 2.0 * (BORDER + DOCK_PAD);
    let origin = point(BORDER + DOCK_PAD, BORDER + DOCK_PAD);
    let mut out = Vec::new();
    let (mut x, mut row) = (0.0f32, 0usize);
    for tab in state.dock.iter().copied() {
        let info = tab.info();
        let symbol = if state.active_tab == Some(tab) {
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
    Bounds::new(dock_origin(ts, height), size(DOCK_W, height))
}

pub fn dock_origin(ts: &TouchScreen, height: f32) -> Point<f32> {
    point(
        (TOUCH_DESIGN.width - DOCK_W) * 0.5,
        H - height * ts.dock_t.value(),
    )
}

/// DockDrawer.tsx.
pub fn dock(
    ts: &TouchScreen,
    window: &mut Window,
    cx: &mut Context<TouchScreen>,
) -> impl IntoElement {
    let (items, height) = dock_layout(&ts.state, window);
    ts.dock_height.set(height);
    let rect = dock_rect(ts);
    let blur = ts.data.read(cx).visual.backdrop_blur;
    let content_origin = point(rect.origin.x + BORDER, rect.origin.y + BORDER);
    let content = size(DOCK_W - 2.0 * BORDER, height - BORDER);
    let mut panel = div()
        .id("dock")
        .absolute()
        .left(u(rect.origin.x))
        .top(u(rect.origin.y))
        .w(u(DOCK_W))
        .h(u(height))
        .overflow_hidden()
        .occlude()
        .border_t(u(BORDER))
        .border_l(u(BORDER))
        .border_r(u(BORDER))
        .border_color(ACCENT)
        .child(dock_backdrop(ts, blur, content_origin, content, window));
    for (tab, b) in items {
        let active = ts.state.active_tab == Some(tab);
        let bx = Bounds::new(point(b.origin.x - BORDER, b.origin.y - BORDER), b.size);
        panel = panel.child(dnd::sortable_icon(ts, Zone::Dock, tab, bx, active, cx));
    }
    panel
}

/// GPUI cannot blur what is behind an element, so the dock fakes the web's
/// `backdrop-blur-[8px] bg-black/50`. Over the driver base the only detail
/// under the dock is the preset row, which it redraws blurred over covers
/// hiding the sharp pills. Tab content is arbitrary, so over a tab layer a
/// denser tint stands in for the detail the blur would wash out.
fn dock_backdrop(
    ts: &TouchScreen,
    blur: bool,
    origin: Point<f32>,
    content: Size<f32>,
    window: &Window,
) -> Div {
    let layer = div()
        .absolute()
        .top_0()
        .left_0()
        .w(u(content.width))
        .h(u(content.height))
        .overflow_hidden();
    if !blur {
        return layer.bg(SCRIM);
    }
    let split = (ts.driver_base_bottom() - origin.y).clamp(0.0, content.height);
    let band = |top: f32, h: f32| {
        div()
            .absolute()
            .left_0()
            .top(u(top))
            .w(u(content.width))
            .h(u(h))
            .overflow_hidden()
    };
    let presets = (0..PRESET_COUNT).flat_map(|i| {
        let slot = preset_slot(i);
        let at = point(slot.origin.x - origin.x, slot.origin.y - origin.y);
        [
            preset_cover(at),
            preset_ghost(at, ts.driver_preset == i, window),
        ]
    });
    layer
        .child(
            band(0.0, split)
                .children(presets)
                .child(div().size_full().bg(alpha(BLACK, 0.5))),
        )
        .child(band(split, content.height - split).bg(DOCK_FROST))
}

fn preset_cover(at: Point<f32>) -> Div {
    div()
        .absolute()
        .left(u(at.x - 1.0))
        .top(u(at.y - 1.0))
        .size(u(PRESET + 2.0))
        .rounded_full()
        .bg(DRIVER_BG)
}

/// The Pill button and its glow seen through the 8 px blur: blurring a
/// gaussian shadow adds the variances.
fn preset_ghost(at: Point<f32>, selected: bool, window: &Window) -> Div {
    let blur = |sigma: f32| dpx(window, sigma.hypot(BACKDROP_BLUR));
    let fill: Hsla = if selected { WHITE } else { alpha(WHITE, 0.1) }.into();
    let mut shadows = vec![BoxShadow::new(px(0.), px(0.), fill).blur_radius(blur(0.0))];
    if selected {
        let glow: Hsla = alpha(WHITE, 0.2).into();
        shadows.push(
            BoxShadow::new(px(0.), dpx(window, 10.), glow)
                .blur_radius(blur(15.0))
                .spread_radius(dpx(window, -3.)),
        );
        shadows.push(
            BoxShadow::new(px(0.), dpx(window, 4.), glow)
                .blur_radius(blur(6.0))
                .spread_radius(dpx(window, -4.)),
        );
    }
    div()
        .absolute()
        .left(u(at.x))
        .top(u(at.y))
        .size(u(PRESET))
        .rounded_full()
        .shadow(shadows)
}

/// DriverTab.tsx: a `bottom-6` row of `h-10 w-10` pills `gap-2` apart,
/// centered in the driver base right of the rail.
pub fn preset_slot(i: usize) -> Bounds<f32> {
    let n = PRESET_COUNT as f32;
    let row = n * PRESET + (n - 1.0) * PRESET_GAP;
    let x = RAIL_W + (TOUCH_DESIGN.width - RAIL_W - row) * 0.5;
    Bounds::new(
        point(
            x + i as f32 * (PRESET + PRESET_GAP),
            H - PRESET_BOTTOM - PRESET,
        ),
        size(PRESET, PRESET),
    )
}

/// DriverTab.tsx.
pub fn driver_view(ts: &TouchScreen, cx: &mut Context<TouchScreen>) -> impl IntoElement {
    let entity = cx.entity();
    let pills = (0..PRESET_COUNT).map(|i| {
        let e = entity.clone();
        let slot = preset_slot(i);
        div()
            .absolute()
            .left(u(slot.origin.x))
            .top(u(slot.origin.y))
            .child(
                Button::new(("preset", i), format!("{}", i + 1), ButtonStyle::Pill)
                    .selected(ts.driver_preset == i)
                    .on_tap(move |_, cx| {
                        e.update(cx, |this, cx| {
                            this.driver_preset = i;
                            cx.notify();
                        })
                    }),
            )
    });
    div()
        .absolute()
        .top_0()
        .left_0()
        .size_full()
        .child(
            div()
                .absolute()
                .top_0()
                .left(u(RAIL_W))
                .w(u(TOUCH_DESIGN.width - RAIL_W))
                .h(u(H))
                .child(crate::placeholder::view3d("Driver view (3D)")),
        )
        .children(pills)
}
