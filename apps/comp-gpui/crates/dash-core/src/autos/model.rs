//! Owner of the auto library, the shared preview clock and the preview frame
//! every view draws (touchscreen Auto tab, HUD minimap). Also decides what the
//! HUD shows: the robot-confirmed auto's path in pre-match, and the preview
//! ghost while the preview plays. Port of Godot's `services/autos_service.gd`
//! without the scene tree: the app feeds `inputs` and calls `step` per frame.

use std::collections::HashMap;
use std::sync::Arc;

use serde_json::Value;

use super::commands::AutoCommands;
use super::field::{Pose, to_world};
use super::freshness::{self, Freshness};
use super::library::{AutoLibrary, ExportSource, meta_from_value};
use super::overlay::{self, PathOverlay};
use crate::playback::{
    Alliance, AutoClock, AutoMechanisms, AutoPlayback, MechanismState, StartPoseCheck,
};

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LivePose {
    pub pose: Pose,
    pub valid: bool,
}

/// What the rest of the app knows about the robot, refreshed before `step`.
#[derive(Clone, Debug, PartialEq)]
pub struct PreviewInputs {
    /// The robot's alliance; None while it does not report one.
    pub alliance_red: Option<bool>,
    pub pre_match: bool,
    /// The robot-confirmed auto, already matched to a library name (L3), or "".
    pub confirmed_auto: String,
    /// None while the robot pose is not live.
    pub robot_pose: Option<LivePose>,
}

impl Default for PreviewInputs {
    fn default() -> Self {
        Self {
            alliance_red: None,
            pre_match: true,
            confirmed_auto: String::new(),
            robot_pose: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct PreviewFrame {
    pub auto: String,
    pub alliance: Alliance,
    pub state: MechanismState,
}

#[derive(Clone, Debug, PartialEq)]
pub struct HudAuto {
    pub auto: String,
    /// True while the HUD mirrors the touchscreen preview instead of the robot's auto.
    pub mirror: bool,
    pub red: bool,
    pub start: Option<StartPoseCheck>,
}

impl Default for HudAuto {
    fn default() -> Self {
        Self {
            auto: String::new(),
            mirror: false,
            red: true,
            start: None,
        }
    }
}

impl HudAuto {
    /// (auto, mirror) for the HUD.
    pub fn pick(
        pre_match: bool,
        confirmed: &str,
        preview_auto: &str,
        preview_active: bool,
    ) -> (String, bool) {
        if !pre_match {
            (String::new(), false)
        } else if preview_active && !preview_auto.is_empty() {
            (preview_auto.to_owned(), true)
        } else {
            (confirmed.to_owned(), false)
        }
    }
}

/// What the HUD minimap draws for [`HudAuto`]: the auto's path, how much
/// of it is travelled, and while mirroring the preview, the robot pose and
/// aim line to show instead of the live robot. Port of Godot's
/// `MinimapView._update_auto_overlay`.
#[derive(Clone, Debug, PartialEq)]
pub struct HudOverlay {
    pub path: Arc<PathOverlay>,
    /// Path points at or before this playback time are travelled.
    pub progress: f64,
    /// The preview frame's robot while the HUD mirrors the preview.
    pub mirror: Option<PreviewFrame>,
    pub aim: Option<(super::field::WorldPoint, super::field::WorldPoint)>,
}

#[derive(Clone, Debug)]
pub struct AutosModel {
    /// Searched by `reload`, newest valid export wins.
    pub sources: Vec<ExportSource>,
    pub library: AutoLibrary,
    pub clock: AutoClock,
    pub config: AutoCommands,
    /// Alliance used while the robot does not report one.
    pub manual_red: bool,
    /// Fixture runs see the export as this old instead of its real age, so
    /// their screenshots do not change as the export ages.
    pub export_age_override_s: Option<f64>,
    pub inputs: PreviewInputs,
    preview_name: String,
    frame: Option<PreviewFrame>,
    hud: HudAuto,
    hud_overlay: Option<HudOverlay>,
    mechanisms: HashMap<String, Arc<AutoMechanisms>>,
}

impl AutosModel {
    /// The turret's default command is ContinuousAimCommand whenever
    /// TurretSubsystem.isGpsAssistEnabled is true; it starts true and the robot
    /// code never changes it, so the preview turret aims for the whole auto.
    pub const TURRET_DEFAULT_AIMS: bool = true;

    pub fn new(sources: Vec<ExportSource>) -> Self {
        let mut m = AutosModel {
            sources,
            library: AutoLibrary::default(),
            clock: AutoClock::new(),
            config: AutoCommands::builtin(),
            manual_red: true,
            export_age_override_s: None,
            inputs: PreviewInputs::default(),
            preview_name: String::new(),
            frame: None,
            hud: HudAuto::default(),
            hud_overlay: None,
            mechanisms: HashMap::new(),
        };
        m.reload();
        m
    }

    pub fn with_event_dir(dir: Option<std::path::PathBuf>) -> Self {
        let mut sources: Vec<ExportSource> = dir.into_iter().map(ExportSource::Dir).collect();
        sources.push(ExportSource::BuiltIn);
        Self::new(sources)
    }

    pub fn reload(&mut self) {
        self.library = AutoLibrary::load_best(&self.sources);
        self.hud_overlay = None;
        self.mechanisms = self
            .library
            .names()
            .into_iter()
            .filter_map(|n| {
                let p = self.library.get_auto(n)?;
                Some((n.to_owned(), Arc::new(AutoMechanisms::new(p, &self.config))))
            })
            .collect();
        if !self.preview_name.is_empty() && self.library.get_auto(&self.preview_name).is_none() {
            self.set_preview("");
        } else {
            self.refresh();
        }
    }

    pub fn preview_name(&self) -> &str {
        &self.preview_name
    }

    pub fn preview(&self) -> Option<Arc<AutoPlayback>> {
        self.library.get_auto(&self.preview_name)
    }

    pub fn mechanisms(&self, name: &str) -> Option<&Arc<AutoMechanisms>> {
        self.mechanisms.get(name)
    }

    pub fn preview_mechanisms(&self) -> Option<&Arc<AutoMechanisms>> {
        self.mechanisms(&self.preview_name)
    }

    pub fn set_preview(&mut self, name: &str) {
        self.preview_name = name.to_owned();
        let duration = self.preview_mechanisms().map_or(0.0, |m| m.duration);
        self.clock.pause();
        self.clock.end_scrub();
        self.clock.set_duration(duration);
        self.clock.seek(0.0);
        self.refresh();
    }

    pub fn alliance_known(&self) -> bool {
        self.inputs.alliance_red.is_some()
    }

    pub fn alliance_red(&self) -> bool {
        self.inputs.alliance_red.unwrap_or(self.manual_red)
    }

    pub fn alliance(&self) -> Alliance {
        Alliance::from_red(self.alliance_red())
    }

    pub fn toggle_manual_alliance(&mut self) {
        if !self.alliance_known() {
            self.manual_red = !self.manual_red;
            self.refresh();
        }
    }

    pub fn frame(&self) -> Option<&PreviewFrame> {
        self.frame.as_ref()
    }

    pub fn hud(&self) -> &HudAuto {
        &self.hud
    }

    /// None while the HUD shows no auto or the library does not have it.
    pub fn hud_overlay(&self) -> Option<&HudOverlay> {
        self.hud_overlay.as_ref()
    }

    pub fn frame_at(m: &AutoMechanisms, t: f64, alliance: Alliance) -> PreviewFrame {
        PreviewFrame {
            auto: m.playback.name.clone(),
            alliance,
            state: m.state_at(t, alliance, Self::TURRET_DEFAULT_AIMS),
        }
    }

    pub fn step(&mut self, now_us: i64) {
        self.clock.tick(now_us);
        self.refresh();
    }

    /// Recomputes the frame and HUD state without moving the clock, after a
    /// seek, an alliance change or new `inputs`.
    pub fn refresh(&mut self) {
        let alliance = self.alliance();
        self.frame = self
            .preview_mechanisms()
            .map(|m| Self::frame_at(m, self.clock.t, alliance));
        let preview_auto = if self.frame.is_some() {
            self.preview_name.as_str()
        } else {
            ""
        };
        let (auto, mirror) = HudAuto::pick(
            self.inputs.pre_match,
            &self.inputs.confirmed_auto,
            preview_auto,
            self.clock.active(),
        );
        let start = if !auto.is_empty() && !mirror {
            self.start_check(&auto)
        } else {
            None
        };
        self.hud = HudAuto {
            auto,
            mirror,
            red: self.alliance_red(),
            start,
        };
        self.hud_overlay = self.build_hud_overlay();
    }

    fn build_hud_overlay(&self) -> Option<HudOverlay> {
        let m = self.mechanisms(&self.hud.auto)?;
        let mirror = if self.hud.mirror {
            self.frame.clone()
        } else {
            None
        };
        let alliance = mirror
            .as_ref()
            .map_or(Alliance::from_red(self.hud.red), |f| f.alliance);
        let path = match &self.hud_overlay {
            Some(o) if o.path.auto == self.hud.auto && o.path.alliance == alliance => {
                o.path.clone()
            }
            _ => Arc::new(PathOverlay::build(m, alliance)),
        };
        let progress = mirror.as_ref().map_or(path.end_time(), |f| f.state.t);
        let aim = mirror.as_ref().and_then(|f| {
            let p = f.state.pose;
            let target = f.state.aim_target;
            overlay::aim_line(
                to_world(p.x, p.y),
                to_world(target.x, target.y),
                f.state.aim,
            )
        });
        Some(HudOverlay {
            path,
            progress,
            mirror,
            aim,
        })
    }

    /// The loaded export against the robot's deploy hash; None with no export.
    pub fn freshness(&self, robot_hash: Option<&str>, now_unix: f64) -> Option<Freshness> {
        if !self.library.is_loaded() {
            return None;
        }
        let mut now = now_unix;
        if let Some(age) = self.export_age_override_s {
            let at = freshness::age_s(self.library.exported_at(), now);
            if at >= 0.0 {
                now += age - at;
            }
        }
        Some(Freshness::check(
            self.library.exported_at(),
            self.library.exported_source_hash(),
            robot_hash,
            now,
        ))
    }

    /// None without a live pose or a path.
    pub fn start_check(&self, name: &str) -> Option<StartPoseCheck> {
        let live = self.inputs.robot_pose?;
        let m = self.mechanisms(name).filter(|m| m.playback.has_path())?;
        Some(StartPoseCheck::compare(
            live.pose,
            m.pose_at(0.0, self.alliance()),
            live.valid,
        ))
    }

    /// Dev fixture "preview": {"auto", "t", "playing", "speed", "loop",
    /// "alliance": "red"|"blue", "meta": {auto: {"name", "description"}}}.
    pub fn apply_fixture(&mut self, fx: &Value) {
        if let Some(meta) = fx.get("meta").and_then(Value::as_object) {
            self.library.merge_meta(meta_from_value(meta));
        }
        if let Some(name) = fx.get("auto") {
            let name = name
                .as_str()
                .map_or_else(|| name.to_string(), str::to_owned);
            self.set_preview(&name);
        }
        if let Some(a) = fx.get("alliance") {
            self.manual_red = a.as_str() == Some("red");
        }
        if let Some(s) = fx.get("speed").and_then(Value::as_f64) {
            self.clock.set_speed(s);
        }
        if let Some(l) = fx.get("loop").and_then(Value::as_bool) {
            self.clock.set_loop(l);
        }
        if let Some(t) = fx.get("t").and_then(Value::as_f64) {
            self.clock.seek(t);
        }
        if fx.get("playing").and_then(Value::as_bool).unwrap_or(false) {
            let t = self.clock.t;
            self.clock.play();
            self.clock.seek(t);
        }
        self.refresh();
    }
}
