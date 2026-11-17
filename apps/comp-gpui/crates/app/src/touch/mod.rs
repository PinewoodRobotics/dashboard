mod auto_tab;
mod chrome;
mod dnd;
mod howard_tab;
mod intake_panel;
mod panels;
mod robot3d_tab;
mod settings_tab;
mod state;
mod tabs;
mod visual_tab;

use std::cell::Cell;
use std::rc::Rc;

use gpui_kit::prelude::FluentBuilder;
use gpui_kit::*;

pub use howard_tab::asset as howard_asset;
pub use state::{LayoutState, PanelId, TabId};

use crate::anim::Tween;
use crate::input::{self, Phase, Pointer, SwipeDir, SwipeOutcome, SwipeRecognizer};
use crate::mock::MockData;
use crate::theme::{
    self, BLACK, BORDER, DOCK_PAD, DRAWER_W, ICON, MOTION_DOCK_S, MOTION_OVERLAY_S, RAIL_W,
    TOUCH_DESIGN, u,
};

const H: f32 = TOUCH_DESIGN.height;
const SWIPE_DIM: f32 = DRAWER_W - RAIL_W;

struct Overlay {
    id: TabId,
    key: u64,
    y: Tween,
    exit: bool,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum DockPhase {
    Hidden,
    Open,
    Closing,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum SwipeTarget {
    Overlay,
    Drawer,
}

/// Initial state for screenshots and demos (`--tab`, `--panel`, `--dock`),
/// applied with every transition finished.
#[derive(Clone, Debug, Default)]
pub struct TouchStart {
    pub tab: Option<TabId>,
    pub panel: Option<PanelId>,
    pub dock: bool,
}

/// TouchscreenDashboard.tsx.
pub struct TouchScreen {
    pub data: Entity<MockData>,
    pub state: LayoutState,
    overlays: Vec<Overlay>,
    next_key: u64,
    shown_active: Option<TabId>,
    entry_done: bool,
    overlay_commit: bool,
    drawer_width: Tween,
    drawer_glow: Tween,
    drawer_swipe: Tween,
    drawer_swiping: bool,
    drawer_committing: bool,
    shown_panel_open: bool,
    dock_t: Tween,
    dock_phase: DockPhase,
    swipe: Option<(SwipeTarget, SwipeRecognizer)>,
    pub driver_preset: usize,
    dock_height: Cell<f32>,
    dnd: dnd::Dnd,
}

impl TouchScreen {
    pub fn new(data: Entity<MockData>, start: TouchStart, cx: &mut Context<Self>) -> Self {
        cx.observe(&data, |_, _, cx| cx.notify()).detach();
        let mut this = Self {
            data,
            state: LayoutState::default(),
            overlays: Vec::new(),
            next_key: 0,
            shown_active: None,
            entry_done: false,
            overlay_commit: false,
            drawer_width: Tween::new(RAIL_W),
            drawer_glow: Tween::new(0.0),
            drawer_swipe: Tween::new(0.0),
            drawer_swiping: false,
            drawer_committing: false,
            shown_panel_open: false,
            dock_t: Tween::new(0.0),
            dock_phase: DockPhase::Hidden,
            swipe: None,
            driver_preset: 0,
            dock_height: Cell::new(BORDER + DOCK_PAD * 2.0 + ICON),
            dnd: dnd::Dnd::default(),
        };
        this.state.set_layout(&crate::settings::layout(cx));
        if let Some(tab) = start.tab {
            this.state.switch_tab(tab);
        }
        if let Some(panel) = start.panel {
            this.state.toggle_panel(panel);
        }
        if start.dock {
            this.state.toggle_dock();
        }
        this.sync();
        this.settle();
        this
    }

    pub fn update_state(&mut self, cx: &mut Context<Self>, f: impl FnOnce(&mut LayoutState)) {
        f(&mut self.state);
        self.sync();
        cx.notify();
    }

    fn settle(&mut self) {
        for o in &mut self.overlays {
            let to = o.y.target();
            o.y.jump(to);
        }
        let w = self.drawer_width.target();
        self.drawer_width.jump(w);
        let g = self.drawer_glow.target();
        self.drawer_glow.jump(g);
        let d = self.dock_t.target();
        self.dock_t.jump(d);
        self.step();
    }

    fn new_overlay(&mut self, id: TabId, from: f32, to: f32, exit: bool) {
        let mut y = Tween::new(from);
        y.play(from, to, MOTION_OVERLAY_S);
        self.next_key += 1;
        self.overlays.push(Overlay {
            id,
            key: self.next_key,
            y,
            exit,
        });
    }

    /// useTouchscreenLayoutState's effects: a replaced or dismissed tab slides
    /// out as a fresh instance (the web remounts it as exit-<id>), the new one
    /// slides in on top; the drawer and dock follow their flags.
    fn sync(&mut self) {
        if self.state.active_tab != self.shown_active {
            let skip_exit = self.state.take_skip_exit_anim();
            self.overlays.clear();
            if let Some(prev) = self.shown_active {
                if !skip_exit {
                    self.new_overlay(prev, 0.0, H, true);
                }
            }
            if let Some(active) = self.state.active_tab {
                self.new_overlay(active, H, 0.0, false);
            }
            self.entry_done = false;
            self.overlay_commit = false;
            self.shown_active = self.state.active_tab;
        }

        let skip_panel = self.state.take_skip_panel_anim();
        let open = self.state.open_panel.is_some();
        if open != self.shown_panel_open || skip_panel {
            self.shown_panel_open = open;
            let (w, g) = if open { (DRAWER_W, 1.0) } else { (RAIL_W, 0.0) };
            if skip_panel {
                self.drawer_width.jump(w);
                self.drawer_glow.jump(g);
            } else {
                self.drawer_width.retarget(w, MOTION_OVERLAY_S);
                self.drawer_glow.retarget(g, MOTION_OVERLAY_S);
            }
        }

        if self.state.dock_open && !self.state.dock_closing && self.dock_phase != DockPhase::Open {
            self.dock_phase = DockPhase::Open;
            self.dock_t.play(0.0, 1.0, MOTION_DOCK_S);
        } else if self.state.dock_closing && self.dock_phase == DockPhase::Open {
            self.dock_phase = DockPhase::Closing;
            self.dock_t.play(1.0, 0.0, MOTION_DOCK_S);
        } else if !self.state.dock_open {
            self.dock_phase = DockPhase::Hidden;
        }
        if !self.state.can_drag() && self.dnd.is_dragging() {
            self.dnd_cancel();
        }
    }

    /// Finishes what ended since the last frame; true while anything moves.
    fn step(&mut self) -> bool {
        let mut changed = false;
        if self.drawer_committing && !self.drawer_swipe.running() {
            self.drawer_committing = false;
            self.state.close_panel_immediate();
            self.drawer_swipe.jump(0.0);
            changed = true;
        }
        let active = self.state.active_tab;
        let mut dismiss = false;
        self.overlays.retain(|o| o.y.running() || !o.exit);
        for o in &self.overlays {
            if o.exit || Some(o.id) != active {
                continue;
            }
            if self.overlay_commit && !o.y.running() {
                dismiss = true;
            } else if !o.y.running() && o.y.value() <= 0.0 {
                self.entry_done = true;
            }
        }
        if dismiss {
            self.overlay_commit = false;
            self.state.dismiss_overlay_immediate();
            changed = true;
        }
        if self.dock_phase == DockPhase::Closing && !self.dock_t.running() {
            self.state.finish_dock_close();
            self.dock_phase = DockPhase::Hidden;
            changed = true;
        }
        if changed {
            self.sync();
        }
        self.drawer_width.running()
            || self.drawer_glow.running()
            || self.drawer_swipe.running()
            || self.dock_t.running()
            || self.overlays.iter().any(|o| o.y.running())
    }

    fn drawer_swipe_active(&self) -> bool {
        self.drawer_swiping || self.drawer_committing || self.drawer_swipe.running()
    }

    /// Width the drawer takes from the screen; the app layers' right inset
    /// follows it (a swipe sets it from the translation, as the web's onProgress).
    fn drawer_occupied(&self) -> f32 {
        if self.drawer_swipe_active() {
            DRAWER_W - self.drawer_swipe.value()
        } else {
            self.drawer_width.value()
        }
    }

    fn overlay_rect(&self) -> Bounds<f32> {
        Bounds::new(
            point(RAIL_W, 0.0),
            size(TOUCH_DESIGN.width - RAIL_W - self.drawer_occupied(), H),
        )
    }

    fn drawer_rect(&self) -> Bounds<f32> {
        let w = self.drawer_width.value();
        Bounds::new(
            point(TOUCH_DESIGN.width - w + self.drawer_swipe.value(), 0.0),
            size(w, H),
        )
    }

    fn dock_visible(&self) -> bool {
        self.dock_phase != DockPhase::Hidden
    }

    fn catcher_visible(&self) -> bool {
        self.state.dock_open && !self.state.dock_closing
    }

    /// Touch only, like the web's touch listeners: swipe down on the active
    /// app layer dismisses it, swipe right on the open drawer closes it.
    fn on_pointer(&mut self, p: &Pointer, window: &mut Window, cx: &mut Context<Self>) {
        match p.phase {
            Phase::Down => {
                self.swipe = None;
                if p.is_touch() {
                    self.begin_swipe(p.pos);
                }
            }
            Phase::Move => {
                let Some((target, rec)) = self.swipe.as_mut() else {
                    return;
                };
                let started = rec.update(p.pos, p.at);
                if !rec.is_tracking() {
                    return;
                }
                let target = *target;
                let delta = rec.delta;
                if started {
                    input::cancel_capture(p.pos, window, cx);
                    if target == SwipeTarget::Drawer {
                        self.drawer_swiping = true;
                    }
                }
                match target {
                    SwipeTarget::Overlay => {
                        if let Some(o) = self.active_overlay_mut() {
                            o.y.jump(delta);
                        }
                    }
                    SwipeTarget::Drawer => self.drawer_swipe.jump(delta.clamp(0.0, SWIPE_DIM)),
                }
                cx.notify();
            }
            Phase::Up | Phase::Cancel => {
                let Some((target, mut rec)) = self.swipe.take() else {
                    return;
                };
                let outcome = rec.end();
                if outcome == SwipeOutcome::None {
                    return;
                }
                let commit = outcome == SwipeOutcome::Commit;
                match target {
                    SwipeTarget::Overlay => {
                        self.overlay_commit = commit;
                        if let Some(o) = self.active_overlay_mut() {
                            let from = o.y.value();
                            o.y.play(from, if commit { H } else { 0.0 }, MOTION_OVERLAY_S);
                        }
                    }
                    SwipeTarget::Drawer => {
                        self.drawer_swiping = false;
                        self.drawer_committing = commit;
                        let from = self.drawer_swipe.value();
                        self.drawer_swipe.play(
                            from,
                            if commit { SWIPE_DIM } else { 0.0 },
                            MOTION_OVERLAY_S,
                        );
                    }
                }
                cx.notify();
            }
        }
    }

    fn begin_swipe(&mut self, pos: Point<f32>) {
        if self.dock_visible() && chrome::dock_rect(self).contains(&pos) {
            return;
        }
        if self.drawer_rect().contains(&pos) {
            if self.state.open_panel.is_some() {
                let mut rec = SwipeRecognizer::new(SwipeDir::Right, SWIPE_DIM);
                rec.begin(pos);
                self.swipe = Some((SwipeTarget::Drawer, rec));
            }
            return;
        }
        if pos.x < RAIL_W || self.catcher_visible() {
            return;
        }
        if self.entry_done && self.overlay_rect().contains(&pos) {
            let mut rec = SwipeRecognizer::new(SwipeDir::Down, H);
            rec.begin(pos);
            self.swipe = Some((SwipeTarget::Overlay, rec));
        }
    }

    fn active_overlay_mut(&mut self) -> Option<&mut Overlay> {
        let active = self.state.active_tab;
        self.overlays
            .iter_mut()
            .find(|o| !o.exit && Some(o.id) == active)
    }
}

impl Render for TouchScreen {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        crate::screen::fit(window, TOUCH_DESIGN);
        let moving = self.step();
        if self.dnd_step(window) || moving {
            window.request_animation_frame();
        }

        let overlay = self.overlay_rect();
        let mut layers = div().absolute().top_0().left_0().size_full();
        for o in &self.overlays {
            let content = tabs::render_tab(self, o.id, o.key, window, cx);
            layers = layers.child(
                div()
                    .id(("overlay", o.key))
                    .absolute()
                    .left(u(overlay.origin.x))
                    .top(u(o.y.value()))
                    .w(u(overlay.size.width))
                    .h(u(H))
                    .bg(BLACK)
                    .overflow_hidden()
                    .occlude()
                    .child(content),
            );
        }

        let weak = cx.entity().downgrade();
        let observer: input::Observer = Rc::new(move |p, window, cx| {
            if let Some(this) = weak.upgrade() {
                this.update(cx, |this, cx| this.on_pointer(p, window, cx));
            }
        });

        let root = div()
            .relative()
            .w(u(TOUCH_DESIGN.width))
            .h(u(H))
            .overflow_hidden()
            .bg(BLACK)
            .font_family(theme::INTER)
            .text_size(u(16.))
            .line_height(u(24.))
            .text_color(theme::WHITE)
            .child(chrome::driver_view(self, cx))
            .child(layers)
            .when(self.catcher_visible(), |d| {
                d.child(
                    div()
                        .id("dock-catcher")
                        .absolute()
                        .top_0()
                        .left_0()
                        .size_full()
                        .occlude()
                        .on_click(
                            cx.listener(|this, _, _, cx| this.update_state(cx, |s| s.close_dock())),
                        ),
                )
            })
            .child(chrome::left_rail(self, window, cx))
            .child(chrome::right_drawer(self, window, cx))
            .when(self.dock_visible(), |d| {
                d.child(chrome::dock(self, window, cx))
            })
            .children(dnd::ghost(self))
            .when(!self.data.read(cx).nt_connected, |d| {
                d.child(crate::widgets::status_pill(TOUCH_DESIGN, "NT Disconnected"))
            })
            .child(crate::widgets::keyboard::layer(TOUCH_DESIGN, window, cx))
            .child(crate::touch_test::layer(
                crate::windows::ScreenKind::Touch,
                TOUCH_DESIGN,
                window,
                cx,
            ))
            .child(crate::debug_overlay::layer(&self.data, window, cx));

        div()
            .size_full()
            .bg(BLACK)
            .child(input::install_root(root, observer))
    }
}
