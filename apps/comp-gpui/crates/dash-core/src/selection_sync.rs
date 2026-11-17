//! Auto selection and its enforcement (L3, AutoSelector.tsx and Godot's
//! `core/controls/auto_selection_sync.gd`). The dashboard's own choice wins:
//! it is persisted, published to `<shared>/<entry>/Request`, and re-published
//! whenever the robot's State disagrees (case-insensitive), at most once per
//! [`THROTTLE_US`]. [`FLICKER_THRESHOLD`] State changes away from the choice
//! within [`FLICKER_WINDOW_US`] raise the conflict popup (another dashboard
//! is fighting). While `/matchhud/state/enabled` is live and true nothing is
//! published. The robot's ValidNames/Autos and SelectedAutoValid add a
//! validity warning, and autos the robot lists but the export lacks are
//! selectable too.

use std::collections::VecDeque;

use crate::request_state::{ControlLink, Policy, RequestState, RequestTopics, Value};

pub const NONE: &str = "NONE";
pub const THROTTLE_US: i64 = 700_000;
pub const FLICKER_WINDOW_US: i64 = 10_000_000;
pub const FLICKER_THRESHOLD: usize = 10;
pub const PENDING_TIMEOUT_US: i64 = 1_500_000;
/// Robot code that never publishes ValidNames/Autos: once its State has been
/// live this long without the list, a stored choice outside the export is
/// dropped, as it was before robot-only autos existed.
pub const ROBOT_LIST_WAIT_US: i64 = 3_000_000;

pub const LOCK_TOPIC: &str = "/matchhud/state/enabled";
pub const PP_CURRENT_SELECTED_AUTO: &str =
    "/AdvantageKit/RealOutputs/PathPlanner/CurrentSelectedAuto";
pub const PP_SELECTED_AUTO_VALID: &str = "/AdvantageKit/RealOutputs/PathPlanner/SelectedAutoValid";
pub const PP_VALID_AUTOS: &str = "/AdvantageKit/RealOutputs/PathPlanner/ValidNames/Autos";
pub const PP_DEPLOY_HASH: &str = "/AdvantageKit/RealOutputs/PathPlanner/DeployHash";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Validity {
    Ok,
    Unknown,
    NotOnRobot,
    LoadFailed,
}

impl Validity {
    pub fn text(self) -> &'static str {
        match self {
            Validity::NotOnRobot => "Not in the robot's auto list",
            Validity::LoadFailed => "Robot failed to load this auto",
            Validity::Ok | Validity::Unknown => "",
        }
    }

    pub fn key(self) -> &'static str {
        match self {
            Validity::Ok => "OK",
            Validity::Unknown => "UNKNOWN",
            Validity::NotOnRobot => "NOT_ON_ROBOT",
            Validity::LoadFailed => "LOAD_FAILED",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SyncEvent {
    Selection(String),
    Conflict(bool),
}

/// The detail pane's Select button for the auto being viewed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SelectButton {
    pub text: &'static str,
    pub enabled: bool,
    pub selected: bool,
}

/// Exact name first, then a trimmed case-insensitive match (pathLibrary.ts).
pub fn find_match<'a, S: AsRef<str>>(candidate: &str, list: &'a [S]) -> Option<&'a str> {
    let c = candidate.trim();
    if c.is_empty() {
        return None;
    }
    if let Some(n) = list.iter().find(|n| n.as_ref() == c) {
        return Some(n.as_ref());
    }
    let lc = c.to_lowercase();
    list.iter()
        .map(AsRef::as_ref)
        .find(|n| n.trim().to_lowercase() == lc)
}

/// What goes on the wire: empty or "none" in any case is [`NONE`].
pub fn wire_name(choice: &str) -> String {
    let t = choice.trim();
    if t.is_empty() || t.eq_ignore_ascii_case(NONE) {
        NONE.to_owned()
    } else {
        t.to_owned()
    }
}

pub fn same_auto(a: &str, b: &str) -> bool {
    wire_name(a).to_lowercase() == wire_name(b).to_lowercase()
}

fn same_auto_owned(a: &String, b: &String) -> bool {
    same_auto(a, b)
}

#[derive(Clone, Debug)]
pub struct AutoSelectionSync {
    request: RequestState<String>,
    /// Library names.
    pub names: Vec<String>,
    /// Last ValidNames/Autos the robot published, kept across disconnects.
    pub robot_names: Vec<String>,
    /// "" = nothing chosen (mirror the robot), [`NONE`] = No Auto, else an auto name.
    pub selected: String,
    pub conflict: bool,
    was_connected: bool,
    last_sync_us: i64,
    prev_robot: String,
    mismatch_us: VecDeque<i64>,
    known_since_us: Option<i64>,
    events: Vec<SyncEvent>,
}

impl AutoSelectionSync {
    pub fn new(topics: RequestTopics, stored: &str) -> Self {
        Self {
            request: RequestState::new(
                topics,
                Policy {
                    forget_on_disconnect: false,
                    pending_timeout_us: Some(PENDING_TIMEOUT_US),
                },
                same_auto_owned,
            ),
            names: Vec::new(),
            robot_names: Vec::new(),
            selected: stored.trim().to_owned(),
            conflict: false,
            was_connected: false,
            last_sync_us: -THROTTLE_US,
            prev_robot: NONE.to_owned(),
            mismatch_us: VecDeque::new(),
            known_since_us: None,
            events: Vec::new(),
        }
    }

    pub fn topics(&self) -> &RequestTopics {
        &self.request.topics
    }

    /// Name whose user-initiated publish the robot has not confirmed yet, or "".
    pub fn pending(&self) -> &str {
        self.request.pending().map_or("", |p| p.value.as_str())
    }

    pub fn publishes(&self) -> u32 {
        self.request.publishes
    }

    pub fn last_wire(&self) -> &str {
        match &self.request.last_published {
            Some(Value::String(s)) => s,
            _ => "",
        }
    }

    pub fn publish_error(&self) -> Option<&str> {
        self.request.publish_error.as_deref()
    }

    /// Selection and conflict changes since the last call.
    pub fn take_events(&mut self) -> Vec<SyncEvent> {
        std::mem::take(&mut self.events)
    }

    pub fn set_topics(&mut self, link: &mut dyn ControlLink, topics: RequestTopics, now_us: i64) {
        if self.request.set_topics(link, topics) {
            self.was_connected = false;
            self.last_sync_us = now_us - THROTTLE_US;
        }
    }

    /// A stored choice that matches neither the library nor the robot's list
    /// is cleared; until the robot's list (or its absence) is known it waits,
    /// unpublished.
    pub fn set_library(&mut self, link: &dyn ControlLink, names: Vec<String>, now_us: i64) {
        self.names = names;
        self.resolve_selected(link, now_us);
    }

    fn resolve_selected(&mut self, link: &dyn ControlLink, now_us: i64) {
        self.refresh_robot_names(link);
        if self.names.is_empty() || self.selected.is_empty() || self.selected == NONE {
            return;
        }
        let m = find_match(&self.selected, &self.names)
            .or_else(|| find_match(&self.selected, &self.robot_names))
            .map(str::to_owned);
        match m {
            None if self.robot_list_settled(link, now_us) => self.set_selected(String::new()),
            Some(m) if m != self.selected => self.set_selected(m),
            _ => {}
        }
    }

    fn robot_list_settled(&self, link: &dyn ControlLink, now_us: i64) -> bool {
        self.robot_list_live(link)
            || self
                .known_since_us
                .is_some_and(|k| now_us - k >= ROBOT_LIST_WAIT_US)
    }

    pub fn awaiting_robot_list(&self) -> bool {
        if self.selected.is_empty() || self.selected == NONE {
            return false;
        }
        find_match(&self.selected, &self.names).is_none()
            && find_match(&self.selected, &self.robot_names).is_none()
    }

    pub fn robot_list_live(&self, link: &dyn ControlLink) -> bool {
        link.connected() && link.live(PP_VALID_AUTOS)
    }

    pub fn robot_list(&self, link: &dyn ControlLink) -> Vec<String> {
        if !self.robot_list_live(link) {
            return Vec::new();
        }
        match link.value(PP_VALID_AUTOS) {
            Some(Value::StringArray(v)) => v,
            _ => Vec::new(),
        }
    }

    fn refresh_robot_names(&mut self, link: &dyn ControlLink) {
        if self.robot_list_live(link) {
            self.robot_names = self.robot_list(link);
        }
    }

    pub fn robot_only_names(&self) -> Vec<String> {
        let mut out: Vec<String> = Vec::new();
        for n in &self.robot_names {
            let t = n.trim();
            if !t.is_empty()
                && !t.eq_ignore_ascii_case(NONE)
                && find_match(t, &self.names).is_none()
                && find_match(t, &out).is_none()
            {
                out.push(t.to_owned());
            }
        }
        out
    }

    pub fn all_names(&self) -> Vec<String> {
        let mut all = self.names.clone();
        all.extend(self.robot_only_names());
        all
    }

    /// Whether the choice may be published: No Auto, a library auto, or one
    /// the robot lists.
    pub fn enforceable(&self) -> bool {
        if self.selected.is_empty() {
            return false;
        }
        self.selected == NONE
            || find_match(&self.selected, &self.names).is_some()
            || find_match(&self.selected, &self.robot_names).is_some()
    }

    pub fn locked(&self, link: &dyn ControlLink) -> bool {
        link.live(LOCK_TOPIC) && link.value(LOCK_TOPIC) == Some(Value::Bool(true))
    }

    pub fn robot_known(&self, link: &dyn ControlLink) -> bool {
        link.connected() && link.live(&self.request.topics.state)
    }

    /// The robot's State, trimmed; empty or "none" in any case is [`NONE`].
    pub fn robot_auto(&self, link: &dyn ControlLink) -> String {
        if !self.robot_known(link) {
            return NONE.to_owned();
        }
        match link.value(&self.request.topics.state) {
            Some(Value::String(s)) => wire_name(&s),
            _ => NONE.to_owned(),
        }
    }

    /// What the list highlights: the local choice, else the robot's auto
    /// when it names a known auto.
    pub fn active_name(&self, link: &dyn ControlLink) -> String {
        if self.selected == NONE {
            return NONE.to_owned();
        }
        let all = self.all_names();
        if let Some(local) = find_match(&self.selected, &all) {
            return local.to_owned();
        }
        if self.robot_known(link) {
            let r = self.robot_auto(link);
            if r == NONE {
                return String::new();
            }
            return find_match(&r, &all).unwrap_or("").to_owned();
        }
        String::new()
    }

    pub fn robot_confirms_selection(&self, link: &dyn ControlLink) -> bool {
        !self.selected.is_empty()
            && self.robot_known(link)
            && same_auto(&self.robot_auto(link), &self.selected)
    }

    pub fn select(&mut self, link: &mut dyn ControlLink, choice: &str, now_us: i64) -> bool {
        if self.locked(link) {
            return false;
        }
        let s = if choice == NONE || choice.trim().is_empty() {
            NONE.to_owned()
        } else {
            choice.to_owned()
        };
        self.set_selected(s);
        let wire = wire_name(&self.selected);
        self.request.send(link, now_us, wire);
        self.last_sync_us = now_us;
        true
    }

    pub fn resync(&mut self, link: &mut dyn ControlLink, now_us: i64) -> bool {
        self.set_conflict(false);
        if self.locked(link) || !self.enforceable() {
            return false;
        }
        self.publish(link);
        self.last_sync_us = now_us;
        true
    }

    pub fn dismiss_conflict(&mut self) {
        self.set_conflict(false);
    }

    /// Fixtures only: shows the conflict popup without the flicker that
    /// raises it.
    pub fn force_conflict(&mut self) {
        self.set_conflict(true);
    }

    fn set_selected(&mut self, s: String) {
        if s == self.selected {
            return;
        }
        self.selected = s.clone();
        self.mismatch_us.clear();
        self.events.push(SyncEvent::Selection(s));
    }

    fn set_conflict(&mut self, v: bool) {
        if v == self.conflict {
            return;
        }
        self.conflict = v;
        self.events.push(SyncEvent::Conflict(v));
    }

    fn publish(&mut self, link: &mut dyn ControlLink) {
        let wire = wire_name(&self.selected);
        self.request.publish(link, &wire);
    }

    pub fn update(&mut self, link: &mut dyn ControlLink, now_us: i64) {
        let connected = link.connected();
        let just_connected = connected && !self.was_connected;
        self.was_connected = connected;
        let is_locked = self.locked(link);
        let known = self.robot_known(link);
        if !known {
            self.known_since_us = None;
        } else if self.known_since_us.is_none() {
            self.known_since_us = Some(now_us);
        }
        let robot = self.robot_auto(link);
        self.resolve_selected(link, now_us);
        let enforce = self.enforceable();

        if !connected || !enforce || is_locked {
            self.mismatch_us.clear();
            self.prev_robot = robot.clone();
        } else if known {
            if robot != self.prev_robot && !same_auto(&robot, &self.selected) {
                while self
                    .mismatch_us
                    .front()
                    .is_some_and(|&t| now_us - t > FLICKER_WINDOW_US)
                {
                    self.mismatch_us.pop_front();
                }
                self.mismatch_us.push_back(now_us);
                if self.mismatch_us.len() >= FLICKER_THRESHOLD {
                    self.set_conflict(true);
                    self.mismatch_us.clear();
                }
            }
            self.prev_robot = robot.clone();
        }

        if connected && enforce && !is_locked {
            let aligned = known && same_auto(&robot, &self.selected);
            if (just_connected || !aligned) && now_us - self.last_sync_us >= THROTTLE_US {
                self.publish(link);
                self.last_sync_us = now_us;
            }
        }

        self.request.update(link, now_us);
    }

    /// Whether the robot can run `auto_name`: NotOnRobot when its live
    /// ValidNames/Autos list lacks it, LoadFailed when it is the robot's
    /// current auto and SelectedAutoValid is false, Unknown without live
    /// robot data.
    pub fn validity(&self, link: &dyn ControlLink, auto_name: &str) -> Validity {
        if auto_name.is_empty() || auto_name == NONE || !link.connected() {
            return if auto_name == NONE {
                Validity::Ok
            } else {
                Validity::Unknown
            };
        }
        let listed = link.live(PP_VALID_AUTOS);
        if listed {
            if let Some(Value::StringArray(list)) = link.value(PP_VALID_AUTOS) {
                if find_match(auto_name, &list).is_none() {
                    return Validity::NotOnRobot;
                }
            }
        }
        if self.robot_known(link)
            && same_auto(&self.robot_auto(link), auto_name)
            && link.live(PP_SELECTED_AUTO_VALID)
        {
            return if link.value(PP_SELECTED_AUTO_VALID) == Some(Value::Bool(false)) {
                Validity::LoadFailed
            } else {
                Validity::Ok
            };
        }
        if listed {
            Validity::Ok
        } else {
            Validity::Unknown
        }
    }

    pub fn button_for(&self, link: &dyn ControlLink, view: &str) -> SelectButton {
        let active = !view.is_empty() && self.active_name(link) == view;
        let pending = self.pending();
        let locked = self.locked(link);
        let text = if !pending.is_empty() && pending == view {
            "Selecting..."
        } else if locked {
            "Locked During Match"
        } else if active {
            "Selected"
        } else {
            "Select"
        };
        SelectButton {
            text,
            enabled: !view.is_empty() && pending.is_empty() && !locked,
            selected: active,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::request_state::FakeLink;

    const REQ: &str = "/Shared/PathPlanner/SelectedPath/Request";
    const STATE: &str = "/Shared/PathPlanner/SelectedPath/State";
    const NAMES: [&str; 3] = ["Ball Shooter Left", "Ball Shooter Right", "Stay And Shoot"];

    struct World {
        link: FakeLink,
        now: i64,
    }

    impl World {
        fn new() -> Self {
            Self {
                link: FakeLink::default(),
                now: 1_000_000_000,
            }
        }

        fn names() -> Vec<String> {
            NAMES.iter().map(|s| s.to_string()).collect()
        }

        fn sync(&mut self, stored: &str) -> AutoSelectionSync {
            let mut s = AutoSelectionSync::new(topics(), stored);
            s.set_library(&self.link, Self::names(), self.now);
            s
        }

        fn update(&mut self, s: &mut AutoSelectionSync) {
            s.update(&mut self.link, self.now);
        }

        fn tick(&mut self, s: &mut AutoSelectionSync, seconds: f64) {
            self.tick_step(s, seconds, 0.02);
        }

        fn tick_step(&mut self, s: &mut AutoSelectionSync, seconds: f64, step_s: f64) {
            let n = (seconds / step_s).round() as i64;
            for _ in 0..n {
                self.now += (step_s * 1e6).round() as i64;
                s.update(&mut self.link, self.now);
            }
        }

        fn state(&mut self, v: &str) {
            self.link.set(STATE, Value::String(v.into()));
        }

        fn robot_list(&mut self, v: &[&str]) {
            self.link.set(
                PP_VALID_AUTOS,
                Value::StringArray(v.iter().map(|s| s.to_string()).collect()),
            );
        }

        fn last(&self) -> Option<String> {
            self.link.last(REQ).and_then(|v| v.as_str().map(str::to_owned))
        }

        fn count(&self) -> usize {
            self.link.count(REQ)
        }

        fn flip(&mut self, s: &mut AutoSelectionSync, times: usize, gap_s: f64) {
            for i in 0..times {
                self.state("Ball Shooter Left");
                self.tick_step(s, gap_s * 0.5, gap_s * 0.5);
                self.state(if i % 2 == 0 {
                    "Stay And Shoot"
                } else {
                    "Ball Shooter Right"
                });
                self.tick_step(s, gap_s * 0.5, gap_s * 0.5);
            }
        }
    }

    fn topics() -> RequestTopics {
        RequestTopics {
            request: REQ.into(),
            state: STATE.into(),
        }
    }

    fn btn(text: &'static str, enabled: bool, selected: bool) -> SelectButton {
        SelectButton {
            text,
            enabled,
            selected,
        }
    }

    fn selections(s: &mut AutoSelectionSync) -> Vec<String> {
        s.take_events()
            .into_iter()
            .filter_map(|e| match e {
                SyncEvent::Selection(v) => Some(v),
                SyncEvent::Conflict(_) => None,
            })
            .collect()
    }

    fn conflicts(s: &mut AutoSelectionSync) -> Vec<bool> {
        s.take_events()
            .into_iter()
            .filter_map(|e| match e {
                SyncEvent::Conflict(v) => Some(v),
                SyncEvent::Selection(_) => None,
            })
            .collect()
    }

    #[test]
    fn publishes_stored_selection_on_connect() {
        let mut w = World::new();
        let mut s = w.sync("Ball Shooter Left");
        w.update(&mut s);
        assert_eq!(w.count(), 0, "nothing while disconnected");
        w.link.up = true;
        w.update(&mut s);
        assert_eq!(w.count(), 1, "published on connect");
        assert_eq!(w.last().as_deref(), Some("Ball Shooter Left"));
        w.state("Ball Shooter Left");
        w.tick(&mut s, 3.0);
        assert_eq!(w.count(), 1, "no republish once State agrees");
        w.link.up = false;
        w.update(&mut s);
        w.link.up = true;
        w.update(&mut s);
        assert_eq!(w.count(), 2, "published again on reconnect");
    }

    #[test]
    fn nothing_chosen_publishes_nothing_and_mirrors_robot() {
        let mut w = World::new();
        let mut s = w.sync("");
        w.link.up = true;
        w.state("ball shooter right");
        w.tick(&mut s, 2.0);
        assert!(w.link.published.is_empty());
        assert_eq!(
            s.active_name(&w.link),
            "Ball Shooter Right",
            "mirrors the robot's auto when nothing is chosen"
        );
    }

    #[test]
    fn republish_when_state_differs_at_most_every_700ms() {
        let mut w = World::new();
        let mut s = w.sync("Ball Shooter Left");
        w.link.up = true;
        w.state("Ball Shooter Left");
        w.update(&mut s);
        let base = w.count();
        w.state("Stay And Shoot");
        w.tick(&mut s, 0.68);
        assert_eq!(w.count() - base, 0, "throttled inside 700 ms of the connect publish");
        w.tick(&mut s, 0.04);
        assert_eq!(w.count() - base, 1, "republished once 700 ms passed");
        w.tick(&mut s, 0.66);
        assert_eq!(w.count() - base, 1, "no second publish inside 700 ms");
        w.tick(&mut s, 0.06);
        assert_eq!(w.count() - base, 2);
        w.tick(&mut s, 7.0);
        assert!(w.count() - base <= 2 + 10, "at most one per 700 ms over 7 s");
        assert_eq!(w.last().as_deref(), Some("Ball Shooter Left"));
    }

    #[test]
    fn case_insensitive_match_counts_as_aligned() {
        let mut w = World::new();
        let mut s = w.sync("Ball Shooter Left");
        w.link.up = true;
        w.update(&mut s);
        w.state("  BALL shooter left ");
        let n = w.count();
        w.tick(&mut s, 3.0);
        assert_eq!(w.count(), n);
        assert!(s.robot_confirms_selection(&w.link));
    }

    #[test]
    fn no_auto_publishes_none_and_accepts_empty_state() {
        let mut w = World::new();
        let mut s = w.sync("");
        w.link.up = true;
        w.update(&mut s);
        assert!(s.select(&mut w.link, NONE, w.now));
        assert_eq!(w.last().as_deref(), Some("NONE"));
        assert_eq!(s.selected, "NONE");
        w.state("");
        let n = w.count();
        w.tick(&mut s, 2.0);
        assert_eq!(w.count(), n, "empty State is NONE");
        w.state("Stay And Shoot");
        w.tick(&mut s, 0.6);
        assert_eq!(w.count(), n + 1, "republished when the robot runs something");
        assert_eq!(s.active_name(&w.link), "NONE");
    }

    #[test]
    fn select_publishes_immediately_and_persists() {
        let mut w = World::new();
        let mut s = w.sync("");
        s.take_events();
        w.link.up = true;
        w.update(&mut s);
        assert!(s.select(&mut w.link, "Stay And Shoot", w.now));
        assert_eq!(w.last().as_deref(), Some("Stay And Shoot"));
        assert_eq!(selections(&mut s), vec!["Stay And Shoot".to_owned()]);
        let b = s.button_for(&w.link, "Stay And Shoot");
        assert_eq!(b.text, "Selecting...");
        assert!(!b.enabled);
        assert!(
            !s.button_for(&w.link, "Ball Shooter Left").enabled,
            "every Select waits for the pending one"
        );
        w.state("Stay And Shoot");
        w.update(&mut s);
        assert_eq!(s.pending(), "");
        assert_eq!(
            s.button_for(&w.link, "Stay And Shoot"),
            btn("Selected", true, true)
        );
        assert_eq!(
            s.button_for(&w.link, "Ball Shooter Left"),
            btn("Select", true, false)
        );
    }

    #[test]
    fn pending_times_out() {
        let mut w = World::new();
        let mut s = w.sync("");
        w.link.up = true;
        s.select(&mut w.link, "Stay And Shoot", w.now);
        w.tick(&mut s, 1.4);
        assert_eq!(s.pending(), "Stay And Shoot");
        w.tick(&mut s, 0.2);
        assert_eq!(s.pending(), "");
    }

    #[test]
    fn lock_while_enabled_and_live() {
        let mut w = World::new();
        let mut s = w.sync("Ball Shooter Left");
        w.link.up = true;
        w.state("Stay And Shoot");
        w.link.set(LOCK_TOPIC, Value::Bool(true));
        let n = w.count();
        w.tick(&mut s, 3.0);
        assert_eq!(w.count(), n, "no enforcement while locked");
        assert!(s.locked(&w.link));
        assert!(!s.select(&mut w.link, "Ball Shooter Right", w.now), "select refused");
        assert_eq!(s.selected, "Ball Shooter Left");
        assert!(!s.resync(&mut w.link, w.now), "resync refused");
        assert_eq!(
            s.button_for(&w.link, "Ball Shooter Left"),
            btn("Locked During Match", false, true)
        );
        assert_eq!(w.count(), n);
        for i in 0..12 {
            w.state(if i % 2 == 0 {
                "Ball Shooter Right"
            } else {
                "Stay And Shoot"
            });
            w.tick(&mut s, 0.1);
        }
        assert!(!s.conflict, "no conflict counting while locked");
        w.link.set(LOCK_TOPIC, Value::Bool(false));
        w.tick(&mut s, 0.1);
        assert_eq!(w.count(), n + 1, "enforcement resumes after the match");
    }

    #[test]
    fn enabled_without_live_value_does_not_lock() {
        let mut w = World::new();
        let s = w.sync("Ball Shooter Left");
        w.link.up = false;
        w.link.set(LOCK_TOPIC, Value::Bool(true));
        assert!(!s.locked(&w.link), "stale enabled (not live) does not lock");
        w.link.up = true;
        assert!(s.locked(&w.link));
    }

    #[test]
    fn conflict_after_ten_mismatching_changes_in_ten_seconds() {
        let mut w = World::new();
        let mut s = w.sync("Ball Shooter Left");
        w.link.up = true;
        w.state("Ball Shooter Left");
        w.update(&mut s);
        s.take_events();
        w.flip(&mut s, 9, 0.8);
        assert!(!s.conflict, "9 mismatches do not trigger");
        w.flip(&mut s, 1, 0.8);
        assert!(s.conflict, "10th mismatch within 10 s triggers the popup");
        assert_eq!(conflicts(&mut s), vec![true]);
        s.dismiss_conflict();
        assert!(!s.conflict);
        w.flip(&mut s, 9, 0.8);
        assert!(!s.conflict, "counter restarted after the popup");
        w.flip(&mut s, 1, 0.8);
        assert!(s.conflict);
        let n = w.count();
        w.now += 1_000_000;
        assert!(s.resync(&mut w.link, w.now), "resync");
        assert!(!s.conflict, "resync hides the popup");
        assert_eq!(w.count(), n + 1, "resync republishes the selection");
        assert_eq!(w.last().as_deref(), Some("Ball Shooter Left"));
    }

    #[test]
    fn slow_flips_never_conflict() {
        let mut w = World::new();
        let mut s = w.sync("Ball Shooter Left");
        w.link.up = true;
        w.flip(&mut s, 20, 1.2);
        assert!(!s.conflict, "one mismatch per 1.2 s stays under 10 per 10 s");
    }

    #[test]
    fn library_clears_unknown_and_fixes_case() {
        let mut w = World::new();
        let mut s = w.sync("Gone Auto");
        assert_eq!(s.selected, "Gone Auto", "kept until the robot's list can confirm it");
        assert!(!s.enforceable(), "an unconfirmed choice is never published");
        w.link.up = true;
        w.state("Stay And Shoot");
        w.tick(&mut s, 1.0);
        assert_eq!(w.count(), 0, "nothing published while the robot's list is missing");
        w.robot_list(&NAMES);
        w.update(&mut s);
        assert_eq!(s.selected, "");
        assert_eq!(selections(&mut s), vec![String::new()]);
        assert_eq!(w.count(), 0);
        let s2 = w.sync("stay and shoot");
        assert_eq!(s2.selected, "Stay And Shoot");
        let s3 = w.sync("NONE");
        assert_eq!(s3.selected, "NONE", "No Auto survives a library change");
    }

    #[test]
    fn stored_choice_is_dropped_when_the_robot_never_lists_autos() {
        let mut w = World::new();
        let mut s = w.sync("Gone Auto");
        assert!(s.awaiting_robot_list());
        w.link.up = true;
        w.tick(&mut s, 5.0);
        assert_eq!(
            s.selected, "Gone Auto",
            "a connection without the robot's State proves nothing"
        );
        w.state("Stay And Shoot");
        w.tick(&mut s, 2.0);
        assert_eq!(s.selected, "Gone Auto", "the list may still be on its way");
        w.tick(&mut s, 1.5);
        assert_eq!(s.selected, "", "robot code without ValidNames/Autos");
        assert!(!s.awaiting_robot_list());
        assert_eq!(w.count(), 0);
    }

    #[test]
    fn a_previously_listed_choice_is_kept_without_the_list() {
        let mut w = World::new();
        w.link.up = true;
        w.state("NONE");
        w.robot_list(&["New Auto"]);
        let mut s = w.sync("New Auto");
        w.update(&mut s);
        assert!(!s.awaiting_robot_list());
        w.link.values.remove(PP_VALID_AUTOS);
        w.tick(&mut s, 5.0);
        assert_eq!(s.selected, "New Auto");
    }

    #[test]
    fn validity_from_robot_lists() {
        let mut w = World::new();
        let s = w.sync("Ball Shooter Left");
        assert_eq!(
            s.validity(&w.link, "Ball Shooter Left"),
            Validity::Unknown,
            "unknown while disconnected"
        );
        w.link.up = true;
        w.robot_list(&["Ball Shooter Right"]);
        assert_eq!(s.validity(&w.link, "Ball Shooter Left"), Validity::NotOnRobot);
        assert_eq!(s.validity(&w.link, "ball shooter right"), Validity::Ok);
        w.robot_list(&["Ball Shooter Left", "Ball Shooter Right"]);
        w.state("Ball Shooter Left");
        w.link.set(PP_SELECTED_AUTO_VALID, Value::Bool(false));
        assert_eq!(s.validity(&w.link, "Ball Shooter Left"), Validity::LoadFailed);
        assert_eq!(
            s.validity(&w.link, "Ball Shooter Right"),
            Validity::Ok,
            "SelectedAutoValid only speaks for the robot's current auto"
        );
        w.link.set(PP_SELECTED_AUTO_VALID, Value::Bool(true));
        assert_eq!(s.validity(&w.link, "Ball Shooter Left"), Validity::Ok);
        assert_eq!(s.validity(&w.link, "NONE"), Validity::Ok);
        assert_eq!(Validity::LoadFailed.text(), "Robot failed to load this auto");
    }

    #[test]
    fn topic_change_releases_old_publisher() {
        let mut w = World::new();
        let mut s = w.sync("Ball Shooter Left");
        w.link.up = true;
        w.update(&mut s);
        let next = RequestTopics {
            request: "/T/X/Request".into(),
            state: "/T/X/State".into(),
        };
        s.set_topics(&mut w.link, next, w.now);
        assert_eq!(w.link.released, vec![REQ.to_owned()]);
        w.update(&mut s);
        assert_eq!(
            w.link.last("/T/X/Request").and_then(Value::as_str),
            Some("Ball Shooter Left"),
            "published on the new topic"
        );
    }

    #[test]
    fn robot_only_autos_are_selectable_and_enforced() {
        let mut w = World::new();
        let mut s = w.sync("");
        w.link.up = true;
        w.state("Stay And Shoot");
        w.robot_list(&["Ball Shooter Left", "New Auto", "ball shooter right", "none", " "]);
        w.update(&mut s);
        assert_eq!(
            s.robot_only_names(),
            vec!["New Auto".to_owned()],
            "library names match case-insensitively; blanks and none are skipped"
        );
        let mut all = World::names();
        all.push("New Auto".into());
        assert_eq!(s.all_names(), all);
        assert_eq!(s.validity(&w.link, "New Auto"), Validity::Ok);
        assert!(s.select(&mut w.link, "New Auto", w.now));
        assert_eq!(w.last().as_deref(), Some("New Auto"));
        assert_eq!(s.active_name(&w.link), "New Auto");
        assert_eq!(s.button_for(&w.link, "New Auto").text, "Selecting...");
        w.state("New Auto");
        w.tick(&mut s, 0.1);
        assert_eq!(s.button_for(&w.link, "New Auto"), btn("Selected", true, true));
        w.state("Stay And Shoot");
        let before = w.count();
        w.tick(&mut s, 1.0);
        assert!(
            w.count() > before,
            "a robot-only choice is enforced like a library one"
        );
        assert_eq!(w.last().as_deref(), Some("New Auto"));
    }

    #[test]
    fn robot_only_choice_survives_a_restart_without_the_robot() {
        let mut w = World::new();
        let mut s = w.sync("New Auto");
        assert_eq!(s.selected, "New Auto");
        assert_eq!(
            s.active_name(&w.link),
            "",
            "not highlighted before the robot lists it"
        );
        w.link.up = true;
        w.state("NONE");
        w.robot_list(&["new auto", "Stay And Shoot"]);
        w.update(&mut s);
        assert_eq!(s.selected, "new auto", "takes the robot's spelling");
        assert_eq!(
            w.last().as_deref(),
            Some("new auto"),
            "published on connect once confirmed"
        );
        w.link.up = false;
        w.update(&mut s);
        assert_eq!(
            s.robot_only_names(),
            vec!["new auto".to_owned()],
            "the last list is kept while disconnected"
        );
        assert_eq!(s.active_name(&w.link), "new auto");
    }

    #[test]
    fn robot_auto_outside_the_export_is_highlighted() {
        let mut w = World::new();
        let mut s = w.sync("");
        w.link.up = true;
        w.state("New Auto");
        w.robot_list(&["New Auto"]);
        w.update(&mut s);
        assert_eq!(s.active_name(&w.link), "New Auto");
    }

    #[test]
    fn wire_names_and_matching() {
        assert_eq!(wire_name("  "), "NONE");
        assert_eq!(wire_name(" none "), "NONE");
        assert_eq!(wire_name(" A "), "A");
        assert!(same_auto("", "NONE"));
        assert!(same_auto(" ball SHOOTER left", "Ball Shooter Left"));
        let list = ["Ball Shooter Left", "ball shooter left"];
        assert_eq!(find_match("ball shooter left", &list), Some("ball shooter left"));
        assert_eq!(find_match("BALL SHOOTER LEFT ", &list), Some("Ball Shooter Left"));
        assert_eq!(find_match(" ", &list), None);
    }
}
