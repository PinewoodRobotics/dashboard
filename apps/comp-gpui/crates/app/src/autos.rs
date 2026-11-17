//! The app's auto stack, one per process like Godot's `/root/Autos` and
//! `Controls.sync`: the auto library and shared preview clock
//! ([`AutosModel`]) and the robot selection handshake
//! ([`AutoSelectionSync`]), driven against the mock robot in [`MockData`]
//! until the NT client replaces [`MockLink`]. The Auto tab, its preview and
//! the Settings tab's export box read it through [`service`]; the HUD can
//! read `model.hud()` the same way.

use std::collections::HashMap;
use std::io::Cursor;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use dash_core::autos::{AutosModel, Freshness, LivePose, Pose};
use dash_core::match_model::Phase;
use dash_core::request_state::{ControlLink, Value};
use dash_core::selection_sync::{
    self as sel, AutoSelectionSync, LOCK_TOPIC, NONE, PP_CURRENT_SELECTED_AUTO, PP_DEPLOY_HASH,
    PP_SELECTED_AUTO_VALID, PP_VALID_AUTOS, SyncEvent,
};
use gpui_kit::*;

use crate::mock::MockData;

const TICK: Duration = Duration::from_millis(20);
/// The preview pauses once the Auto tab has not drawn for this long (Godot
/// pauses it when the panel leaves the tree).
const HIDDEN_AFTER: Duration = Duration::from_millis(250);
/// How long the mock robot takes to echo a Request on State.
const ECHO_DELAY: Duration = Duration::from_millis(250);

/// Electron's `public/path-overview`: per-auto GIFs and the Howard pictures
/// shown when a preview fails. Read from the source tree at runtime.
pub const PATH_OVERVIEW: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../../comp/public/path-overview"
);

fn mock_value(d: &MockData, topic: &str) -> Option<Value> {
    let pp = &d.pathplanner;
    match topic {
        LOCK_TOPIC => Some(Value::Bool(d.matchs.enabled)),
        PP_VALID_AUTOS => pp.valid_autos.clone().map(Value::StringArray),
        PP_SELECTED_AUTO_VALID => pp.selected_auto_valid.map(Value::Bool),
        PP_CURRENT_SELECTED_AUTO => pp.current_selected_auto.clone().map(Value::String),
        PP_DEPLOY_HASH => pp.deploy_hash.clone().map(Value::String),
        t if t == d.auto_selection.link.topics.state => {
            d.auto_selection.link.state.clone().map(Value::String)
        }
        _ => None,
    }
}

/// Read-only [`MockLink`] for rendering.
pub struct MockView<'a>(pub &'a MockData);

impl ControlLink for MockView<'_> {
    fn connected(&self) -> bool {
        self.0.nt_connected
    }

    fn live(&self, topic: &str) -> bool {
        self.connected() && self.value(topic).is_some()
    }

    fn value(&self, topic: &str) -> Option<Value> {
        mock_value(self.0, topic)
    }

    fn publish(&mut self, _topic: &str, _value: Value) -> bool {
        false
    }

    fn forget(&mut self, _topic: &str) {}

    fn release(&mut self, _topic: &str) {}
}

/// `/matchhud/state/*`, PathPlanner and Request/State topics answered from
/// [`MockData`], publishing into it the way the robot would see it.
pub struct MockLink<'a> {
    pub data: &'a mut MockData,
}

impl ControlLink for MockLink<'_> {
    fn connected(&self) -> bool {
        self.data.nt_connected
    }

    fn live(&self, topic: &str) -> bool {
        self.connected() && self.value(topic).is_some()
    }

    fn value(&self, topic: &str) -> Option<Value> {
        mock_value(self.data, topic)
    }

    fn publish(&mut self, topic: &str, value: Value) -> bool {
        let link = &mut self.data.auto_selection.link;
        if topic != link.topics.request {
            return false;
        }
        match value {
            Value::String(s) => {
                link.request = Some(s);
                true
            }
            _ => false,
        }
    }

    fn forget(&mut self, _topic: &str) {}

    fn release(&mut self, topic: &str) {
        if topic == self.data.auto_selection.link.topics.request {
            self.data.auto_selection.link.request = None;
        }
    }
}

/// Godot's touch_auto_* fixtures (data/fixtures), applied over the
/// touch_m6_base robot state.
#[derive(Clone, Debug, Default)]
pub struct Fixture {
    pub name: String,
    pub state: Option<String>,
    pub stored: Option<String>,
    pub enabled: bool,
    pub valid_autos: Option<Vec<String>>,
    pub selected_auto_valid: Option<bool>,
    pub conflict: bool,
    pub view_auto: Option<String>,
    pub export_age_s: Option<f64>,
    pub deploy_hash: Option<String>,
    pub preview_t: Option<f64>,
    pub playing: bool,
    pub expanded: bool,
    /// The mock robot echoes Requests, as a live robot does.
    pub echo: bool,
    pub nt_down: bool,
    /// None: the robot's pose is not live, so there is no start check.
    pub pose: Option<(f64, f64, f64)>,
}

fn base_valid_autos() -> Vec<String> {
    [
        "Ball Shooter Left",
        "Ball Shooter Right",
        "Climber Right Left",
        "Climber Right Middle",
        "Climber Right Right",
        "Move Forward And Shoot Center",
        "Move Forward And Shoot Left",
        "Move Forward And Shoot Right",
        "Stay And Shoot",
    ]
    .into_iter()
    .map(String::from)
    .collect()
}

impl Fixture {
    pub fn parse(name: &str) -> Option<Self> {
        let mut f = Fixture {
            name: name.to_owned(),
            pose: Some((2.0, 4.03, 0.0)),
            ..Default::default()
        };
        let s = |v: &str| Some(v.to_owned());
        match name {
            "touch_tab_auto" | "touch_auto_selected" => {}
            "touch_auto_locked" => {
                f.enabled = true;
                f.view_auto = s("Ball Shooter Right");
            }
            "touch_auto_conflict" => {
                f.state = s("Climber Right Left");
                f.conflict = true;
            }
            "touch_auto_invalid" => {
                f.valid_autos = Some(vec!["Ball Shooter Right".into(), "Stay And Shoot".into()]);
                f.selected_auto_valid = Some(false);
            }
            "touch_auto_none" => {
                f.state = s(NONE);
                f.stored = s(NONE);
            }
            "touch_auto_robot_only" => {
                let mut v = base_valid_autos();
                v.push("Two Piece Outpost".into());
                f.valid_autos = Some(v);
                f.view_auto = s("Two Piece Outpost");
            }
            "touch_auto_long_names" => {
                f.state = s("Move Forward And Shoot Center");
                f.stored = s("Move Forward And Shoot Center");
                f.view_auto = s("Move Forward And Shoot Center");
            }
            "touch_auto_export_old" => {
                f.view_auto = s("Ball Shooter Left");
                f.export_age_s = Some(432_000.0);
            }
            "touch_auto_paths_differ" => {
                f.view_auto = s("Ball Shooter Left");
                f.deploy_hash = s("deadbeef");
            }
            "touch_auto_start_off" => {
                f.pose = Some((3.1, 4.6, 0.6));
            }
            "touch_auto_playing" => {
                f.preview_t = Some(3.2);
                f.playing = true;
            }
            "touch_auto_scrubbed" => {
                f.view_auto = s("Climber Right Right");
                f.preview_t = Some(6.0);
            }
            "touch_auto_expanded" => {
                f.preview_t = Some(6.0);
                f.expanded = true;
            }
            "touch_auto_disconnected" => {
                f.nt_down = true;
            }
            "touch_auto_live" => {
                f.echo = true;
            }
            _ => return None,
        }
        Some(f)
    }

    fn apply(&self, d: &mut MockData) {
        d.matchs.phase = Phase::PreMatch;
        d.matchs.enabled = self.enabled;
        d.matchs.is_red_alliance = Some(false);
        d.nt_connected = !self.nt_down;
        match self.pose {
            Some((x, y, h)) => {
                d.pose.x_m = x;
                d.pose.y_m = y;
                d.pose.heading_rad = h;
                d.pose.valid = true;
            }
            None => d.pose.valid = false,
        }
        let state = self
            .state
            .clone()
            .unwrap_or_else(|| "Ball Shooter Left".into());
        d.auto_selection.link.state = Some(state.clone());
        d.auto_selection.link.request = None;
        d.auto_selection.stored = self
            .stored
            .clone()
            .unwrap_or_else(|| "Ball Shooter Left".into());
        d.pathplanner.current_selected_auto = Some(state);
        d.pathplanner.valid_autos = Some(self.valid_autos.clone().unwrap_or_else(base_valid_autos));
        d.pathplanner.selected_auto_valid = Some(self.selected_auto_valid.unwrap_or(true));
        d.pathplanner.deploy_hash = self.deploy_hash.clone();
    }
}

/// What a newly opened Auto tab starts on (fixtures).
#[derive(Clone, Debug, Default)]
pub struct TabStart {
    pub view: Option<String>,
    pub expanded: bool,
}

pub struct AutoService {
    pub model: AutosModel,
    pub sync: AutoSelectionSync,
    pub data: Entity<MockData>,
    echo: bool,
    echo_since: Option<(String, Instant)>,
    epoch: Instant,
    tab_seen: Option<Instant>,
    pub tab_start: TabStart,
    previews: HashMap<String, Option<Arc<RenderImage>>>,
}

struct ServiceHandle(Entity<AutoService>);

impl Global for ServiceHandle {}

pub fn service(cx: &App) -> Entity<AutoService> {
    cx.global::<ServiceHandle>().0.clone()
}

/// Creates the service and starts its update loop. Call once at startup.
pub fn init(data: Entity<MockData>, fixture: Option<Fixture>, cx: &mut App) {
    let svc = cx.new(|cx| AutoService::new(data, fixture, cx));
    cx.set_global(ServiceHandle(svc.clone()));
    let weak = svc.downgrade();
    cx.spawn(async move |cx| {
        loop {
            cx.background_executor().timer(TICK).await;
            let Some(svc) = weak.upgrade() else { break };
            svc.update(cx, |s, cx| s.tick(cx));
        }
    })
    .detach();
}

fn now_unix() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}

impl AutoService {
    fn new(data: Entity<MockData>, fixture: Option<Fixture>, cx: &mut Context<Self>) -> Self {
        let mut model = AutosModel::with_event_dir(None);
        if let Some(f) = &fixture {
            data.update(cx, |d, _| {
                f.apply(d);
                d.sync_match();
            });
            model.export_age_override_s = Some(f.export_age_s.unwrap_or(3600.0));
        }
        let (topics, stored) = {
            let d = data.read(cx);
            (
                d.connection.selected_path_topics(),
                d.auto_selection.stored.clone(),
            )
        };
        let epoch = Instant::now();
        let mut sync = AutoSelectionSync::new(topics, &stored);
        let names: Vec<String> = model
            .library
            .names()
            .into_iter()
            .map(String::from)
            .collect();
        data.update(cx, |d, _| {
            sync.set_library(&MockLink { data: d }, names, 0);
        });
        if fixture.as_ref().is_some_and(|f| f.conflict) {
            sync.force_conflict();
        }
        sync.take_events();
        let tab_start = TabStart {
            view: fixture.as_ref().and_then(|f| f.view_auto.clone()),
            expanded: fixture.as_ref().is_some_and(|f| f.expanded),
        };
        cx.observe(&data, |_, _, cx| cx.notify()).detach();
        let mut this = Self {
            model,
            sync,
            data,
            echo: fixture.as_ref().is_none_or(|f| f.echo),
            echo_since: None,
            epoch,
            tab_seen: None,
            tab_start,
            previews: HashMap::new(),
        };
        this.tick(cx);
        if let Some(f) = &fixture {
            let view = f
                .view_auto
                .clone()
                .unwrap_or_else(|| this.read_link(cx, |s, link| s.active_name(link)));
            if (f.preview_t.is_some() || f.playing) && this.model.library.get_auto(&view).is_some()
            {
                this.model.set_preview(&view);
                this.model.clock.seek(f.preview_t.unwrap_or(0.0));
                if f.playing {
                    let t = this.model.clock.t;
                    this.model.clock.play();
                    this.model.clock.seek(t);
                }
                this.model.refresh();
            }
        }
        this
    }

    pub fn now_us(&self) -> i64 {
        self.epoch.elapsed().as_micros() as i64
    }

    /// The Auto tab drew this frame; the preview keeps playing while it does.
    pub fn note_tab_drawn(&mut self) {
        self.tab_seen = Some(Instant::now());
    }

    pub fn with_link<R>(
        &mut self,
        cx: &mut Context<Self>,
        f: impl FnOnce(&mut AutoSelectionSync, &mut MockLink, i64) -> R,
    ) -> R {
        let now = self.now_us();
        let sync = &mut self.sync;
        let data = self.data.clone();
        let out = data.update(cx, |d, cx| {
            let r = f(sync, &mut MockLink { data: d }, now);
            cx.notify();
            r
        });
        self.persist_events(cx);
        out
    }

    /// Reads the sync against the current mock robot state.
    pub fn read_link<R>(
        &self,
        cx: &App,
        f: impl FnOnce(&AutoSelectionSync, &dyn ControlLink) -> R,
    ) -> R {
        f(&self.sync, &MockView(self.data.read(cx)))
    }

    fn persist_events(&mut self, cx: &mut Context<Self>) {
        for e in self.sync.take_events() {
            if let SyncEvent::Selection(s) = e {
                self.data.update(cx, |d, _| d.auto_selection.stored = s);
            }
        }
    }

    pub fn reload(&mut self, cx: &mut Context<Self>) {
        self.model.reload();
        let names: Vec<String> = self
            .model
            .library
            .names()
            .into_iter()
            .map(String::from)
            .collect();
        self.with_link(cx, |s, link, now| s.set_library(link, names, now));
        cx.notify();
    }

    /// The loaded export against the robot's deploy hash.
    pub fn freshness(&self, cx: &App) -> Option<Freshness> {
        let d = self.data.read(cx);
        let hash = d
            .nt_connected
            .then(|| d.pathplanner.deploy_hash.clone())
            .flatten();
        self.model.freshness(hash.as_deref(), now_unix())
    }

    fn tick(&mut self, cx: &mut Context<Self>) {
        let now = self.now_us();
        let (topics, pre_match, alliance, pose) = {
            let d = self.data.read(cx);
            let topics = d.connection.selected_path_topics();
            let live = d.nt_connected;
            let pose = live.then(|| LivePose {
                pose: Pose::new(d.pose.x_m, d.pose.y_m, d.pose.heading_rad),
                valid: d.pose.valid,
            });
            (
                topics,
                d.matchs.phase == Phase::PreMatch,
                if live { d.matchs.is_red_alliance } else { None },
                pose,
            )
        };
        let echo = self.echo;
        let echo_since = &mut self.echo_since;
        let sync = &mut self.sync;
        let data = self.data.clone();
        let shown = |s: &AutoSelectionSync| {
            (
                s.pending().to_owned(),
                s.conflict,
                s.selected.clone(),
                s.robot_names.clone(),
            )
        };
        let shown_before = shown(sync);
        let mut changed = false;
        data.update(cx, |d, cx| {
            if d.auto_selection.link.topics != topics {
                d.auto_selection.link.topics = topics.clone();
            }
            let before = (
                d.auto_selection.link.clone(),
                d.pathplanner.current_selected_auto.clone(),
            );
            let mut link = MockLink { data: d };
            sync.set_topics(&mut link, topics, now);
            sync.update(&mut link, now);
            if echo && d.nt_connected {
                let req = d.auto_selection.link.request.clone();
                let differs = req.is_some() && req != d.auto_selection.link.state;
                match (differs, req, echo_since.as_ref()) {
                    (true, Some(r), Some((pending, at)))
                        if *pending == r && at.elapsed() >= ECHO_DELAY =>
                    {
                        d.auto_selection.link.state = Some(r.clone());
                        d.pathplanner.current_selected_auto = Some(r);
                        *echo_since = None;
                    }
                    (true, Some(r), Some((pending, _))) if *pending == r => {}
                    (true, Some(r), _) => *echo_since = Some((r, Instant::now())),
                    _ => *echo_since = None,
                }
            }
            let after = (
                d.auto_selection.link.clone(),
                d.pathplanner.current_selected_auto.clone(),
            );
            if before != after {
                changed = true;
                cx.notify();
            }
        });
        changed |= shown(&self.sync) != shown_before;
        self.persist_events(cx);

        let confirmed = self.read_link(cx, |s, link| {
            if !s.robot_known(link) {
                return String::new();
            }
            let r = s.robot_auto(link);
            if r == NONE {
                return String::new();
            }
            sel::find_match(&r, &s.names)
                .map(str::to_owned)
                .or_else(|| sel::find_match(&r, &s.robot_only_names()).map(str::to_owned))
                .unwrap_or_default()
        });
        let inputs = &mut self.model.inputs;
        let new_inputs = dash_core::autos::PreviewInputs {
            alliance_red: alliance,
            pre_match,
            confirmed_auto: confirmed,
            robot_pose: pose,
        };
        if *inputs != new_inputs {
            *inputs = new_inputs;
            self.model.refresh();
            changed = true;
        }

        let hidden = self.tab_seen.is_none_or(|t| t.elapsed() > HIDDEN_AFTER);
        if hidden && self.model.clock.active() {
            self.model.clock.pause();
            self.model.clock.end_scrub();
            self.model.refresh();
            changed = true;
        }
        if self.model.clock.playing {
            self.model.step(now);
            changed = true;
        }
        if changed {
            cx.notify();
        }
    }

    /// The first frame of the web's path-overview GIF for `auto`, which
    /// stands where the realtime 3D preview will go. Only the first frame is
    /// decoded: the whole GIF runs to hundreds of MB of frames.
    pub fn preview_image(&mut self, auto: &str) -> Option<Arc<RenderImage>> {
        if let Some(img) = self.previews.get(auto) {
            return img.clone();
        }
        let img =
            decode_first_frame(&PathBuf::from(PATH_OVERVIEW).join(format!("animated/{auto}.gif")));
        self.previews.insert(auto.to_owned(), img.clone());
        img
    }
}

fn decode_first_frame(path: &PathBuf) -> Option<Arc<RenderImage>> {
    use image::AnimationDecoder;
    let bytes = std::fs::read(path).ok()?;
    let decoder = image::codecs::gif::GifDecoder::new(Cursor::new(bytes)).ok()?;
    let frame = decoder.into_frames().next()?.ok()?;
    let mut buf = frame.into_buffer();
    for px in buf.chunks_exact_mut(4) {
        px.swap(0, 2);
    }
    Some(Arc::new(RenderImage::new(vec![image::Frame::new(buf)])))
}
