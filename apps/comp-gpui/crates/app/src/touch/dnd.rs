//! Rail/dock editor drags (useTouchscreenDnd.ts on dnd-kit; Godot
//! `touch_dnd.gd` and `drag_ghost.gd`). A press on a rail or dock item becomes
//! a tap or, through the drag gate, a drag. The ghost is the source's box
//! moved by the pointer's travel since the press; the item under it is the
//! slot center of every rail and dock item closest to the ghost's center
//! (closestCenter over all sortables, wherever the pointer is). Items of the
//! source's own list make room while it hovers, the lists change on release,
//! and the ghost then glides onto the source's new slot. Positions are design
//! pixels of the touch window.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::Instant;

use dash_core::dnd::{self as rules, DragGate, GateState, Target, Zone};
use dash_core::layout_store;
use gpui_kit::prelude::FluentBuilder;
use gpui_kit::*;

use super::{TabId, TouchScreen, chrome};
use crate::anim::Tween;
use crate::icons::sf_symbol;
use crate::input::{self, Phase, Pointer, TAP_SLOP};
use crate::theme::{ICON, WHITE, alpha, u};

const SORT_S: f32 = 0.2;
const DROP_S: f32 = 0.25;

type Key = (Zone, TabId);

#[derive(Default)]
struct Ghost {
    visible: bool,
    symbol: u32,
    rect: Bounds<f32>,
    from: Point<f32>,
    to: Point<f32>,
    t: Option<Tween>,
}

impl Ghost {
    fn dropping(&self) -> bool {
        self.visible && self.t.is_some_and(|t| t.running())
    }

    fn origin(&self) -> Point<f32> {
        match self.t {
            Some(t) => {
                let k = t.value();
                point(
                    self.from.x + (self.to.x - self.from.x) * k,
                    self.from.y + (self.to.y - self.from.y) * k,
                )
            }
            None => self.rect.origin,
        }
    }
}

#[derive(Default)]
pub struct Dnd {
    gate: DragGate,
    source: Option<Key>,
    /// Rail items outside edit mode: taps only, a moving press is cancelled.
    tap_only: bool,
    source_rect: Bounds<f32>,
    last_target: Option<Target<TabId>>,
    shifts: HashMap<Key, (Tween, Tween)>,
    ghost: Ghost,
    landing: Option<Key>,
    pub layout_path: Option<PathBuf>,
}

impl Dnd {
    pub fn offset(&self, zone: Zone, tab: TabId) -> Point<f32> {
        self.shifts
            .get(&(zone, tab))
            .map(|(x, y)| point(x.value(), y.value()))
            .unwrap_or_default()
    }

    /// The drag source's placeholder (opacity 0.3).
    pub fn faded(&self, zone: Zone, tab: TabId) -> bool {
        self.source == Some((zone, tab)) && self.gate.is_dragging()
    }

    /// Hidden while the ghost glides onto it.
    pub fn landing_hidden(&self, zone: Zone, tab: TabId) -> bool {
        self.landing == Some((zone, tab))
    }

    pub fn is_dragging(&self) -> bool {
        self.source.is_some() && self.gate.is_dragging()
    }

    fn running(&self) -> bool {
        self.ghost.dropping()
            || self
                .shifts
                .values()
                .any(|(x, y)| x.running() || y.running())
            || (self.source.is_some() && !self.tap_only && self.gate.awaiting_hold())
    }
}

fn ms(at: Instant) -> u64 {
    static EPOCH: OnceLock<Instant> = OnceLock::new();
    let epoch = *EPOCH.get_or_init(Instant::now);
    at.saturating_duration_since(epoch).as_millis() as u64
}

fn pt(p: Point<f32>) -> rules::Pt {
    (p.x, p.y)
}

fn center(b: &Bounds<f32>) -> Point<f32> {
    point(
        b.origin.x + b.size.width * 0.5,
        b.origin.y + b.size.height * 0.5,
    )
}

/// Every place a layout is kept between runs: `%APPDATA%`, Application
/// Support or the XDG config directory, under `comp-gpui/layout.json`.
pub fn default_layout_path() -> Option<PathBuf> {
    let env = |k: &str| {
        std::env::var_os(k)
            .filter(|v| !v.is_empty())
            .map(PathBuf::from)
    };
    let base = if cfg!(target_os = "windows") {
        env("APPDATA")?
    } else if cfg!(target_os = "macos") {
        env("HOME")?.join("Library/Application Support")
    } else {
        env("XDG_CONFIG_HOME").or_else(|| env("HOME").map(|h| h.join(".config")))?
    };
    Some(base.join("comp-gpui").join("layout.json"))
}

pub fn load_layout(path: &Path) -> (Vec<TabId>, Vec<TabId>) {
    let l = super::state::layout_tabs().load(path);
    (parse(&l.rail), parse(&l.dock))
}

fn parse(ids: &[String]) -> Vec<TabId> {
    ids.iter().filter_map(|s| TabId::parse(s)).collect()
}

fn keys(ids: &[TabId]) -> Vec<String> {
    ids.iter().map(|t| t.key().to_string()).collect()
}

impl TouchScreen {
    fn list(&self, zone: Zone) -> &[TabId] {
        match zone {
            Zone::Rail => &self.state.rail,
            Zone::Dock => &self.state.dock,
        }
    }

    /// Item boxes in window coordinates, unshifted (rail buttons, dock spans).
    fn slots(&self, zone: Zone, window: &Window) -> Vec<(TabId, Bounds<f32>)> {
        match zone {
            Zone::Rail => self
                .state
                .rail
                .iter()
                .enumerate()
                .map(|(i, t)| (*t, chrome::rail_slot(i)))
                .collect(),
            Zone::Dock => {
                let (items, height) = chrome::dock_layout(&self.state, window);
                let o = chrome::dock_origin(self, height);
                items
                    .into_iter()
                    .map(|(t, b)| {
                        (
                            t,
                            Bounds::new(point(o.x + b.origin.x, o.y + b.origin.y), b.size),
                        )
                    })
                    .collect()
            }
        }
    }

    fn slot_rect(&self, key: Key, window: &Window) -> Option<Bounds<f32>> {
        self.slots(key.0, window)
            .into_iter()
            .find(|(t, _)| *t == key.1)
            .map(|(_, b)| b)
    }

    pub(super) fn dnd_press(&mut self, zone: Zone, tab: TabId, p: &Pointer) {
        self.dnd.source = Some((zone, tab));
        self.dnd.tap_only = !self.state.can_drag();
        self.dnd.gate.begin(pt(p.pos), ms(p.at), p.is_touch());
    }

    pub(super) fn dnd_pointer(&mut self, p: &Pointer, window: &mut Window, cx: &mut Context<Self>) {
        match p.phase {
            Phase::Down => {}
            Phase::Move => self.dnd_move(p, window),
            Phase::Up => self.dnd_release(p, window),
            Phase::Cancel => self.dnd_cancel(),
        }
        cx.notify();
    }

    fn dnd_move(&mut self, p: &Pointer, window: &Window) {
        if self.dnd.source.is_none() {
            return;
        }
        if self.dnd.tap_only {
            if self.dnd.gate.travel(pt(p.pos)) > TAP_SLOP {
                self.dnd.gate.cancel();
            }
            return;
        }
        let was = self.dnd.gate.is_dragging();
        self.dnd.gate.moved(pt(p.pos), ms(p.at));
        if self.dnd.gate.is_dragging() && !was {
            self.start_drag(window);
        }
        if self.dnd.gate.is_dragging() {
            self.track(p.pos, window);
        }
    }

    fn dnd_release(&mut self, p: &Pointer, window: &Window) {
        let Some(key) = self.dnd.source else {
            return;
        };
        let s = self.dnd.gate.end();
        if s == GateState::Dragging {
            self.track(p.pos, window);
        }
        self.dnd.source = None;
        match s {
            GateState::Dragging => {
                let target = self.dnd.last_target.take();
                self.dnd.shifts.clear();
                self.drop_on(key, target.as_ref());
                self.land(key, window);
            }
            GateState::Pending => {
                self.state.switch_tab(key.1);
                self.sync();
            }
            _ => {}
        }
    }

    pub(super) fn dnd_cancel(&mut self) {
        self.dnd.source = None;
        self.dnd.gate.end();
        self.dnd.last_target = None;
        self.dnd.shifts.clear();
        self.dnd.ghost.visible = false;
        self.dnd.ghost.t = None;
        self.dnd.landing = None;
    }

    /// The touch hold has no moves to drive it, so frames do.
    pub(super) fn dnd_step(&mut self, window: &Window) -> bool {
        if self.dnd.source.is_some() && !self.dnd.tap_only && self.dnd.gate.awaiting_hold() {
            self.dnd.gate.tick(ms(Instant::now()));
            if self.dnd.gate.is_dragging() {
                self.start_drag(window);
            }
        }
        if self.dnd.ghost.visible && self.dnd.ghost.t.is_some() && !self.dnd.ghost.dropping() {
            self.dnd.ghost.visible = false;
            self.dnd.ghost.t = None;
            self.dnd.landing = None;
        }
        self.dnd
            .shifts
            .retain(|_, (x, y)| x.running() || y.running() || x.value() != 0.0 || y.value() != 0.0);
        self.dnd.running()
    }

    fn start_drag(&mut self, window: &Window) {
        let Some(key) = self.dnd.source else {
            return;
        };
        self.dnd.landing = None;
        self.dnd.source_rect = self
            .slot_rect(key, window)
            .unwrap_or_else(|| Bounds::new(point(0.0, 0.0), size(0.0, 0.0)));
        self.dnd.ghost = Ghost {
            visible: true,
            symbol: key.1.info().symbol,
            rect: self.dnd.source_rect,
            ..Ghost::default()
        };
        self.dnd.last_target = Some(Target {
            zone: key.0,
            over: Some(key.1),
        });
    }

    fn ghost_rect(&self, pos: Point<f32>) -> Bounds<f32> {
        let (sx, sy) = self.dnd.gate.start_pos;
        let r = self.dnd.source_rect;
        Bounds::new(
            point(r.origin.x + pos.x - sx, r.origin.y + pos.y - sy),
            r.size,
        )
    }

    fn track(&mut self, pos: Point<f32>, window: &Window) {
        let Some((zone, tab)) = self.dnd.source else {
            return;
        };
        let r = self.ghost_rect(pos);
        if !self.dnd.ghost.dropping() {
            self.dnd.ghost.rect = r;
        }
        let target = self.target_at(center(&r), window);
        let over = target
            .as_ref()
            .filter(|t| t.zone == zone)
            .and_then(|t| t.over);
        self.dnd.last_target = target;
        self.preview_order(zone, tab, over, window);
    }

    /// The sortable strategies: while `active` is over `over`, each item of
    /// the list moves to the slot it would take in the reordered list.
    fn preview_order(&mut self, zone: Zone, active: TabId, over: Option<TabId>, window: &Window) {
        let slots = self.slots(zone, window);
        let list = self.list(zone);
        let from = list.iter().position(|t| *t == active);
        let to = over.and_then(|o| list.iter().position(|t| *t == o));
        let order = match (from, to) {
            (Some(f), Some(t)) => rules::preview_slots(slots.len(), f, t),
            _ => (0..slots.len()).collect(),
        };
        for (i, (tab, own)) in slots.iter().enumerate() {
            let target = slots[order[i]].1.origin;
            let (dx, dy) = (target.x - own.origin.x, target.y - own.origin.y);
            let e = self
                .dnd
                .shifts
                .entry((zone, *tab))
                .or_insert_with(|| (Tween::new(0.0), Tween::new(0.0)));
            e.0.retarget(dx, SORT_S);
            e.1.retarget(dy, SORT_S);
        }
    }

    /// Rail items while the dock is open (edit mode), dock items while it is
    /// shown.
    fn target_at(&self, at: Point<f32>, window: &Window) -> Option<Target<TabId>> {
        let mut items: Vec<(Key, rules::Pt)> = Vec::new();
        if self.state.can_drag() {
            for (t, b) in self.slots(Zone::Rail, window) {
                items.push(((Zone::Rail, t), pt(center(&b))));
            }
        }
        if self.dock_visible() {
            for (t, b) in self.slots(Zone::Dock, window) {
                items.push(((Zone::Dock, t), pt(center(&b))));
            }
        }
        rules::closest(&items, pt(at)).map(|(zone, t)| Target {
            zone,
            over: Some(t),
        })
    }

    fn drop_on(&mut self, (zone, tab): Key, target: Option<&Target<TabId>>) {
        let res = rules::apply_drop(&self.state.rail, &self.state.dock, zone, &tab, target);
        if res.changed {
            self.set_lists(res.rail, res.dock);
        }
    }

    pub(super) fn set_lists(&mut self, rail: Vec<TabId>, dock: Vec<TabId>) {
        if !self.state.set_lists(&rail, &dock) {
            return;
        }
        if let Some(path) = &self.dnd.layout_path {
            let layout = layout_store::Layout {
                rail: keys(&self.state.rail),
                dock: keys(&self.state.dock),
            };
            if let Err(e) = layout_store::save(path, &layout) {
                eprintln!("comp-gpui: cannot save {}: {e}", path.display());
            }
        }
    }

    fn land(&mut self, key: Key, window: &Window) {
        let Some(home) = self.slot_rect(key, window) else {
            self.dnd.ghost.visible = false;
            return;
        };
        self.dnd.landing = Some(key);
        let from = self.dnd.ghost.rect.origin;
        let mut t = Tween::new(0.0);
        t.play(0.0, 1.0, DROP_S);
        self.dnd.ghost.from = from;
        self.dnd.ghost.to = home.origin;
        self.dnd.ghost.t = Some(t);
    }
}

/// A rail or dock item: its symbol centered in `bx` (parent coordinates),
/// moved by its sortable shift, faded while it is the drag source.
pub(super) fn sortable_icon(
    ts: &TouchScreen,
    zone: Zone,
    tab: TabId,
    bx: Bounds<f32>,
    active: bool,
    cx: &mut Context<TouchScreen>,
) -> Stateful<Div> {
    let info = tab.info();
    let shift = ts.dnd.offset(zone, tab);
    let color = if active { crate::theme::ACCENT } else { WHITE };
    let color = if ts.dnd.faded(zone, tab) {
        alpha(color, 0.3)
    } else {
        color
    };
    let symbol = if active {
        info.active_symbol
    } else {
        info.symbol
    };
    let prefix = match zone {
        Zone::Rail => "rail",
        Zone::Dock => "dock",
    };
    let entity = cx.entity();
    div()
        .id(SharedString::from(format!("{prefix}-{}", tab.key())))
        .absolute()
        .left(u(bx.origin.x + shift.x))
        .top(u(bx.origin.y + shift.y))
        .w(u(bx.size.width))
        .h(u(bx.size.height))
        .flex()
        .items_center()
        .when(zone == Zone::Rail, |d| d.justify_center())
        .when(!ts.dnd.landing_hidden(zone, tab), |d| {
            d.child(sf_symbol(symbol, ICON, color))
        })
        .on_mouse_down(MouseButton::Left, move |e, window, cx| {
            let p = input::pointer(Phase::Down, e.position, window);
            entity.update(cx, |this, _| this.dnd_press(zone, tab, &p));
            let e = entity.clone();
            input::capture(window, move |p, window, cx| {
                e.update(cx, |this, cx| this.dnd_pointer(p, window, cx))
            });
        })
}

/// TouchscreenDragGhost.tsx: the bare white outline symbol at 80% opacity,
/// centered in a box the size of the dragged element.
pub(super) fn ghost(ts: &TouchScreen) -> Option<Div> {
    let g = &ts.dnd.ghost;
    if !g.visible {
        return None;
    }
    let o = g.origin();
    Some(
        div()
            .absolute()
            .left(u(o.x))
            .top(u(o.y))
            .w(u(g.rect.size.width))
            .h(u(g.rect.size.height))
            .flex()
            .items_center()
            .justify_center()
            .child(sf_symbol(g.symbol, ICON, alpha(WHITE, 0.8))),
    )
}
