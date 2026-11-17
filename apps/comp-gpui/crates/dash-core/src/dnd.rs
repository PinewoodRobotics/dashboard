//! Rail/dock editor drags (useTouchscreenDnd.ts on dnd-kit; Godot
//! `dnd_rules.gd` and `drag_gate.gd`). The dock is the master list (order
//! only); the rail is a user subset of it.

pub type Pt = (f32, f32);

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Zone {
    Rail,
    Dock,
}

/// What a drop lands on: an item of a zone, or the zone itself (`over` None).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Target<T> {
    pub zone: Zone,
    pub over: Option<T>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DropResult<T> {
    pub rail: Vec<T>,
    pub dock: Vec<T>,
    pub changed: bool,
}

/// handleDragEnd. `target` None is a drop on nothing.
pub fn apply_drop<T: Clone + PartialEq>(
    rail: &[T],
    dock: &[T],
    src_zone: Zone,
    src: &T,
    target: Option<&Target<T>>,
) -> DropResult<T> {
    let mut r = rail.to_vec();
    let mut d = dock.to_vec();
    if let Some(t) = target {
        let over = t.over.as_ref();
        match (src_zone, t.zone) {
            (Zone::Rail, Zone::Rail) => move_before(&mut r, src, over),
            (Zone::Dock, Zone::Dock) => move_before(&mut d, src, over),
            (Zone::Dock, Zone::Rail) => {
                if !r.contains(src) {
                    match over.and_then(|o| r.iter().position(|x| x == o)) {
                        Some(at) => r.insert(at, src.clone()),
                        None => r.push(src.clone()),
                    }
                }
            }
            (Zone::Rail, Zone::Dock) => r.retain(|x| x != src),
        }
    }
    let changed = r != rail || d != dock;
    DropResult {
        rail: r,
        dock: d,
        changed,
    }
}

/// arrayMove(list, from, index of over); no `over` moves to the end.
fn move_before<T: Clone + PartialEq>(list: &mut Vec<T>, id: &T, over: Option<&T>) {
    let Some(from) = list.iter().position(|x| x == id) else {
        return;
    };
    if over == Some(id) {
        return;
    }
    let to = match over {
        Some(o) => match list.iter().position(|x| x == o) {
            Some(i) => i,
            None => return,
        },
        None => list.len() - 1,
    };
    let item = list.remove(from);
    list.insert(to, item);
}

/// The key whose center is nearest the point (dnd-kit closestCenter).
pub fn closest<K: Clone>(items: &[(K, Pt)], point: Pt) -> Option<K> {
    let mut best = None;
    let mut best_d = f32::INFINITY;
    for (k, c) in items {
        let d = (c.0 - point.0).powi(2) + (c.1 - point.1).powi(2);
        if d < best_d {
            best_d = d;
            best = Some(k.clone());
        }
    }
    best
}

/// The sortable strategies while item `from` is dragged over item `to`:
/// item i takes slot `out[i]`. verticalListSortingStrategy and
/// rectSortingStrategy agree on this (arrayMove(slots, to, from)).
pub fn preview_slots(n: usize, from: usize, to: usize) -> Vec<usize> {
    let mut out: Vec<usize> = (0..n).collect();
    if from < n && to < n {
        let s = out.remove(to);
        out.insert(from, s);
    }
    out
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GateState {
    Idle,
    Pending,
    Dragging,
    Cancelled,
}

/// When a press turns into a drag (useTouchscreenDnd.ts sensors): touch after
/// a 200 ms hold that stays within 25 px, mouse after 8 px of travel. A touch
/// that travels farther before the hold ends is a scroll or swipe, never a
/// drag.
#[derive(Clone, Debug)]
pub struct DragGate {
    pub state: GateState,
    pub is_touch: bool,
    pub start_pos: Pt,
    pub start_ms: u64,
    pub max_travel: f32,
}

impl Default for DragGate {
    fn default() -> Self {
        Self {
            state: GateState::Idle,
            is_touch: false,
            start_pos: (0.0, 0.0),
            start_ms: 0,
            max_travel: 0.0,
        }
    }
}

impl DragGate {
    pub const TOUCH_HOLD_MS: u64 = 200;
    pub const TOUCH_TOLERANCE_PX: f32 = 25.0;
    pub const MOUSE_DISTANCE_PX: f32 = 8.0;

    pub fn begin(&mut self, pos: Pt, t_ms: u64, touch: bool) {
        self.start_pos = pos;
        self.start_ms = t_ms;
        self.is_touch = touch;
        self.max_travel = 0.0;
        self.state = GateState::Pending;
    }

    pub fn travel(&self, pos: Pt) -> f32 {
        ((pos.0 - self.start_pos.0).powi(2) + (pos.1 - self.start_pos.1).powi(2)).sqrt()
    }

    pub fn moved(&mut self, pos: Pt, t_ms: u64) -> GateState {
        if self.state != GateState::Pending {
            return self.state;
        }
        self.max_travel = self.max_travel.max(self.travel(pos));
        if self.is_touch {
            if self.max_travel > Self::TOUCH_TOLERANCE_PX {
                self.state = GateState::Cancelled;
            } else {
                self.tick(t_ms);
            }
        } else if self.max_travel >= Self::MOUSE_DISTANCE_PX {
            self.state = GateState::Dragging;
        }
        self.state
    }

    pub fn tick(&mut self, t_ms: u64) -> GateState {
        if self.state == GateState::Pending
            && self.is_touch
            && t_ms.saturating_sub(self.start_ms) >= Self::TOUCH_HOLD_MS
        {
            self.state = GateState::Dragging;
        }
        self.state
    }

    pub fn cancel(&mut self) {
        if self.state == GateState::Pending {
            self.state = GateState::Cancelled;
        }
    }

    pub fn end(&mut self) -> GateState {
        std::mem::replace(&mut self.state, GateState::Idle)
    }

    pub fn is_dragging(&self) -> bool {
        self.state == GateState::Dragging
    }

    /// Pending on a touch: the hold timer needs frames even without moves.
    pub fn awaiting_hold(&self) -> bool {
        self.state == GateState::Pending && self.is_touch
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const RAIL: [&str; 3] = ["auto", "settings", "visual"];
    const DOCK: [&str; 6] = ["auto", "settings", "effects", "howard", "robot3d", "visual"];

    fn drop(
        src: Zone,
        id: &'static str,
        zone: Option<Zone>,
        over: &'static str,
    ) -> DropResult<&'static str> {
        let target = zone.map(|zone| Target {
            zone,
            over: (!over.is_empty()).then_some(over),
        });
        apply_drop(&RAIL, &DOCK, src, &id, target.as_ref())
    }

    #[test]
    fn rail_reorder() {
        let r = drop(Zone::Rail, "visual", Some(Zone::Rail), "auto");
        assert_eq!(r.rail, ["visual", "auto", "settings"]);
        assert_eq!(r.dock, DOCK);
        assert_eq!(
            drop(Zone::Rail, "auto", Some(Zone::Rail), "visual").rail,
            ["settings", "visual", "auto"]
        );
        assert_eq!(
            drop(Zone::Rail, "auto", Some(Zone::Rail), "").rail,
            ["settings", "visual", "auto"],
            "over the zone moves to the end"
        );
    }

    #[test]
    fn dock_reorder() {
        let r = drop(Zone::Dock, "howard", Some(Zone::Dock), "auto");
        assert_eq!(
            r.dock,
            ["howard", "auto", "settings", "effects", "robot3d", "visual"]
        );
        assert_eq!(r.rail, RAIL);
    }

    #[test]
    fn dock_to_rail_inserts_at_target_without_duplicates() {
        assert_eq!(
            drop(Zone::Dock, "howard", Some(Zone::Rail), "settings").rail,
            ["auto", "howard", "settings", "visual"]
        );
        assert_eq!(
            drop(Zone::Dock, "howard", Some(Zone::Rail), "").rail,
            ["auto", "settings", "visual", "howard"],
            "over the zone appends"
        );
        let dup = drop(Zone::Dock, "visual", Some(Zone::Rail), "auto");
        assert_eq!(dup.rail, RAIL, "already in the rail: no duplicate");
        assert!(!dup.changed);
        assert_eq!(
            drop(Zone::Dock, "howard", Some(Zone::Rail), "settings").dock,
            DOCK,
            "dock order unchanged"
        );
        let empty = apply_drop(
            &[],
            &DOCK,
            Zone::Dock,
            &"effects",
            Some(&Target {
                zone: Zone::Rail,
                over: None,
            }),
        );
        assert_eq!(empty.rail, ["effects"], "empty rail");
    }

    #[test]
    fn rail_to_dock_removes() {
        let r = drop(Zone::Rail, "settings", Some(Zone::Dock), "howard");
        assert_eq!(r.rail, ["auto", "visual"]);
        assert_eq!(r.dock, DOCK);
        assert_eq!(
            drop(Zone::Rail, "settings", Some(Zone::Dock), "settings").rail,
            ["auto", "visual"],
            "even over its own dock item"
        );
    }

    #[test]
    fn drop_on_nothing_is_a_no_op() {
        let r = drop(Zone::Dock, "howard", None, "");
        assert!(!r.changed);
        assert_eq!(r.rail, RAIL);
        assert!(!drop(Zone::Rail, "auto", None, "").changed);
        assert!(
            !drop(Zone::Rail, "auto", Some(Zone::Rail), "auto").changed,
            "onto itself"
        );
    }

    #[test]
    fn targets_from_positions() {
        assert_eq!(closest::<&str>(&[], (40.0, 100.0)), None);
        let items = [
            ("auto", (0.0, 0.0)),
            ("settings", (100.0, 0.0)),
            ("visual", (200.0, 0.0)),
        ];
        assert_eq!(closest(&items, (130.0, 30.0)), Some("settings"));
    }

    #[test]
    fn sortable_previews() {
        assert_eq!(
            preview_slots(3, 0, 2),
            [2, 0, 1],
            "rail auto over visual: siblings move up"
        );
        assert_eq!(
            preview_slots(6, 0, 2),
            [2, 0, 1, 3, 4, 5],
            "dock auto over effects: settings takes auto's slot, howard stays"
        );
        assert_eq!(preview_slots(3, 2, 0), [1, 2, 0]);
        assert_eq!(preview_slots(3, 1, 1), [0, 1, 2]);
    }

    #[test]
    fn touch_drag_starts_after_hold_within_tolerance() {
        let mut g = DragGate::default();
        g.begin((100.0, 100.0), 1000, true);
        assert_eq!(
            g.moved((110.0, 110.0), 1100),
            GateState::Pending,
            "14 px early: still pending"
        );
        assert!(g.awaiting_hold());
        assert_eq!(g.tick(1199), GateState::Pending, "199 ms");
        assert_eq!(g.tick(1200), GateState::Dragging, "200 ms hold");
        g.begin((100.0, 100.0), 1000, true);
        assert_eq!(
            g.moved((126.0, 100.0), 1050),
            GateState::Cancelled,
            "26 px before the hold ends is not a drag"
        );
        assert_eq!(g.tick(1300), GateState::Cancelled);
        g.begin((100.0, 100.0), 1000, true);
        assert_eq!(
            g.moved((125.0, 100.0), 1250),
            GateState::Dragging,
            "25 px is within tolerance"
        );
    }

    #[test]
    fn mouse_drag_starts_after_8px() {
        let mut g = DragGate::default();
        g.begin((100.0, 100.0), 0, false);
        assert_eq!(
            g.moved((107.0, 100.0), 5000),
            GateState::Pending,
            "time alone never starts a mouse drag"
        );
        assert!(!g.awaiting_hold());
        assert_eq!(g.tick(5000), GateState::Pending);
        assert_eq!(g.moved((108.0, 100.0), 5001), GateState::Dragging);
        assert_eq!(g.end(), GateState::Dragging);
        assert_eq!(g.state, GateState::Idle);
    }
}
