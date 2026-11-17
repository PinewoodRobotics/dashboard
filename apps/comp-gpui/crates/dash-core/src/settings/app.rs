//! The dashboard's own settings file in the per-OS user data dir, normalized
//! like settings-schema.ts (map defaults follow / 0.3 / 0.5) and
//! layoutStorage.ts (unknown tab ids dropped, dock completed in default
//! order), plus the robot controls the web kept in localStorage and the
//! window placement overrides. Ports apps/comp-godot/core/settings/app_settings.gd.
//! Unknown top-level keys (newer builds, `migrations`) survive a round trip.

use std::path::PathBuf;

use serde_json::{Map, Value};

use super::json::{f32_value, num, obj};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MapMode {
    Driver,
    Follow,
}

impl MapMode {
    pub fn as_str(self) -> &'static str {
        match self {
            MapMode::Driver => "driver",
            MapMode::Follow => "follow",
        }
    }

    fn parse(s: &str) -> Option<Self> {
        match s {
            "driver" => Some(MapMode::Driver),
            "follow" => Some(MapMode::Follow),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct MapSettings {
    pub mode: MapMode,
    pub angle: f32,
    pub zoom: f32,
}

impl Default for MapSettings {
    fn default() -> Self {
        Self {
            mode: MapMode::Follow,
            angle: 0.3,
            zoom: 0.5,
        }
    }
}

fn unit(v: Option<&Value>, default: f32) -> f32 {
    num(v).map_or(default, |f| f.clamp(0.0, 1.0) as f32)
}

impl MapSettings {
    pub fn normalize(raw: Option<&Value>) -> Self {
        let d = Self::default();
        let Some(raw) = obj(raw) else {
            return d;
        };
        Self {
            mode: raw
                .get("mode")
                .and_then(Value::as_str)
                .and_then(MapMode::parse)
                .unwrap_or(d.mode),
            angle: unit(raw.get("angle"), d.angle),
            zoom: unit(raw.get("zoom"), d.zoom),
        }
    }

    pub fn normalized(&self) -> Self {
        Self::normalize(Some(&self.to_json()))
    }

    pub fn to_json(&self) -> Value {
        let mut m = Map::new();
        m.insert("mode".into(), self.mode.as_str().into());
        m.insert("angle".into(), f32_value(self.angle));
        m.insert("zoom".into(), f32_value(self.zoom));
        Value::Object(m)
    }
}

pub const RENDER_SCALES: [f32; 4] = [0.25, 0.5, 0.75, 1.0];

/// The web's visualSettings less the Log Depth toggle; Godot's MSAA, frame cap
/// and automatic quality have no GPUI counterpart.
#[derive(Clone, Debug, PartialEq)]
pub struct VisualSettings {
    pub backdrop_blur: bool,
    pub render_scale: f32,
}

impl Default for VisualSettings {
    fn default() -> Self {
        Self {
            backdrop_blur: true,
            render_scale: 1.0,
        }
    }
}

/// One of the allowed render scales, else the default.
pub fn normalize_render_scale(v: Option<&Value>) -> f32 {
    num(v)
        .and_then(|f| {
            RENDER_SCALES
                .iter()
                .copied()
                .find(|s| (f64::from(*s) - f).abs() < 1e-5)
        })
        .unwrap_or(VisualSettings::default().render_scale)
}

impl VisualSettings {
    pub fn normalize(raw: Option<&Value>) -> Self {
        let d = Self::default();
        let Some(raw) = obj(raw) else {
            return d;
        };
        Self {
            backdrop_blur: raw
                .get("backdrop_blur")
                .and_then(Value::as_bool)
                .unwrap_or(d.backdrop_blur),
            render_scale: normalize_render_scale(raw.get("render_scale")),
        }
    }

    pub fn normalized(&self) -> Self {
        Self::normalize(Some(&self.to_json()))
    }

    pub fn to_json(&self) -> Value {
        let mut m = Map::new();
        m.insert("render_scale".into(), f32_value(self.render_scale));
        m.insert("backdrop_blur".into(), self.backdrop_blur.into());
        Value::Object(m)
    }
}

/// -1 = automatic (the display with the exact size), else a display index.
pub const AUTO_SCREEN: i32 = -1;
pub const MAX_SCREEN_INDEX: i32 = 7;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct WindowsSettings {
    pub hud_screen: i32,
    pub touch_screen: i32,
}

impl Default for WindowsSettings {
    fn default() -> Self {
        Self {
            hud_screen: AUTO_SCREEN,
            touch_screen: AUTO_SCREEN,
        }
    }
}

fn screen_index(v: Option<&Value>, default: i32) -> i32 {
    match num(v) {
        Some(f) if f == f.floor() => f.clamp(-1.0, f64::from(MAX_SCREEN_INDEX)) as i32,
        _ => default,
    }
}

impl WindowsSettings {
    pub fn normalize(raw: Option<&Value>) -> Self {
        let d = Self::default();
        let Some(raw) = obj(raw) else {
            return d;
        };
        Self {
            hud_screen: screen_index(raw.get("hud_screen"), d.hud_screen),
            touch_screen: screen_index(raw.get("touch_screen"), d.touch_screen),
        }
    }

    pub fn normalized(&self) -> Self {
        Self::normalize(Some(&self.to_json()))
    }

    pub fn to_json(&self) -> Value {
        let mut m = Map::new();
        m.insert("hud_screen".into(), self.hud_screen.into());
        m.insert("touch_screen".into(), self.touch_screen.into());
        Value::Object(m)
    }
}

/// apps/comp-godot/core/ui_state/tab_defs.gd: the web Record tab is dropped,
/// so stored layouts that mention it lose it.
pub const TABS: [&str; 6] = ["auto", "settings", "effects", "howard", "robot3d", "visual"];
pub const DEFAULT_RAIL: [&str; 2] = ["auto", "settings"];

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LayoutSettings {
    pub rail: Vec<String>,
    pub dock: Vec<String>,
}

impl Default for LayoutSettings {
    fn default() -> Self {
        Self {
            rail: DEFAULT_RAIL.iter().map(|s| s.to_string()).collect(),
            dock: TABS.iter().map(|s| s.to_string()).collect(),
        }
    }
}

/// Known ids only, first occurrence kept.
fn sanitize_ids(raw: Option<&Value>) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for id in raw.and_then(Value::as_array).into_iter().flatten() {
        if let Some(id) = id.as_str().filter(|id| TABS.contains(id))
            && !out.iter().any(|o| o == id)
        {
            out.push(id.to_owned());
        }
    }
    out
}

impl LayoutSettings {
    pub fn normalize(raw: Option<&Value>) -> Self {
        let Some(raw) = obj(raw) else {
            return Self::default();
        };
        let rail = if raw.contains_key("rail") {
            sanitize_ids(raw.get("rail"))
        } else {
            Self::default().rail
        };
        let mut dock = sanitize_ids(raw.get("dock"));
        for id in TABS {
            if !dock.iter().any(|d| d == id) {
                dock.push(id.to_owned());
            }
        }
        Self { rail, dock }
    }

    pub fn normalized(&self) -> Self {
        Self::normalize(Some(&self.to_json()))
    }

    pub fn to_json(&self) -> Value {
        let mut m = Map::new();
        m.insert("rail".into(), self.rail.clone().into());
        m.insert("dock".into(), self.dock.clone().into());
        Value::Object(m)
    }
}

/// `selected_auto`: "" = nothing chosen, "NONE" = No Auto, else an auto name.
/// `intake_speed`: None = use the robot's compiled constant, else 0..1.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ControlsSettings {
    pub selected_auto: String,
    pub intake_speed: Option<f64>,
}

/// intake_speed.gd `round_speed`.
pub fn round_speed(v: f64) -> f64 {
    (v.clamp(0.0, 1.0) * 100.0).round() / 100.0
}

impl ControlsSettings {
    pub fn normalize(raw: Option<&Value>) -> Self {
        let Some(raw) = obj(raw) else {
            return Self::default();
        };
        Self {
            selected_auto: raw
                .get("selected_auto")
                .and_then(Value::as_str)
                .map(|s| s.trim().to_owned())
                .unwrap_or_default(),
            intake_speed: num(raw.get("intake_speed")).map(round_speed),
        }
    }

    pub fn normalized(&self) -> Self {
        Self::normalize(Some(&self.to_json()))
    }

    pub fn to_json(&self) -> Value {
        let mut m = Map::new();
        m.insert("selected_auto".into(), self.selected_auto.clone().into());
        m.insert(
            "intake_speed".into(),
            self.intake_speed.map_or(Value::Null, Value::from),
        );
        Value::Object(m)
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct AppSettings {
    pub map: MapSettings,
    pub visual: VisualSettings,
    pub layout: LayoutSettings,
    pub controls: ControlsSettings,
    pub windows: WindowsSettings,
    /// Every other top-level key, in file order (`migrations` among them).
    pub extra: Map<String, Value>,
}

const SECTIONS: [&str; 5] = ["map", "visual", "layout", "controls", "windows"];
const MIGRATIONS: &str = "migrations";

impl AppSettings {
    pub fn normalize(raw: Option<&Value>) -> Self {
        let Some(raw) = obj(raw) else {
            return Self::default();
        };
        Self {
            map: MapSettings::normalize(raw.get("map")),
            visual: VisualSettings::normalize(raw.get("visual")),
            layout: LayoutSettings::normalize(raw.get("layout")),
            controls: ControlsSettings::normalize(raw.get("controls")),
            windows: WindowsSettings::normalize(raw.get("windows")),
            extra: raw
                .iter()
                .filter(|(k, _)| !SECTIONS.contains(&k.as_str()))
                .map(|(k, v)| (k.clone(), v.clone()))
                .collect(),
        }
    }

    pub fn to_json(&self) -> Value {
        let mut m = Map::new();
        m.insert("map".into(), self.map.to_json());
        m.insert("visual".into(), self.visual.to_json());
        m.insert("layout".into(), self.layout.to_json());
        m.insert("controls".into(), self.controls.to_json());
        m.insert("windows".into(), self.windows.to_json());
        for (k, v) in &self.extra {
            m.insert(k.clone(), v.clone());
        }
        Value::Object(m)
    }

    pub fn has_migration(&self, name: &str) -> bool {
        self.extra
            .get(MIGRATIONS)
            .and_then(Value::as_array)
            .is_some_and(|a| a.iter().any(|m| m.as_str() == Some(name)))
    }

    pub fn add_migration(&mut self, name: &str) {
        let mut done = match self.extra.get(MIGRATIONS) {
            Some(Value::Array(a)) => a.clone(),
            _ => Vec::new(),
        };
        done.push(name.into());
        self.extra.insert(MIGRATIONS.into(), Value::Array(done));
    }
}

const APP_DIR: [&str; 2] = ["PWRUP", "CompGpui"];
pub const FILE_NAME: &str = "settings.json";

/// The per-OS user data dir (as Godot's custom user dir `PWRUP/CompDashboard`,
/// in a sibling folder so the two ports never fight over one file):
/// `%APPDATA%` on Windows, `~/Library/Application Support` on macOS,
/// `$XDG_DATA_HOME` or `~/.local/share` elsewhere.
pub fn default_app_settings_path() -> Option<PathBuf> {
    let os = if cfg!(windows) {
        "windows"
    } else if cfg!(target_os = "macos") {
        "macos"
    } else {
        "linux"
    };
    app_settings_path_for(os, |k| std::env::var_os(k).map(PathBuf::from))
}

pub fn app_settings_path_for(os: &str, env: impl Fn(&str) -> Option<PathBuf>) -> Option<PathBuf> {
    let nonempty = |k: &str| env(k).filter(|p| !p.as_os_str().is_empty());
    let base = match os {
        "windows" => nonempty("APPDATA"),
        "macos" => nonempty("HOME").map(|h| h.join("Library").join("Application Support")),
        _ => nonempty("XDG_DATA_HOME").or_else(|| nonempty("HOME").map(|h| h.join(".local").join("share"))),
    }?;
    Some(base.join(APP_DIR[0]).join(APP_DIR[1]).join(FILE_NAME))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn n<T>(f: fn(Option<&Value>) -> T, v: Value) -> T {
        f(Some(&v))
    }

    #[test]
    fn map_normalization() {
        assert_eq!(MapSettings::normalize(None), MapSettings::default());
        assert_eq!(
            n(MapSettings::normalize, json!({"mode": "driver", "angle": 2, "zoom": -1})),
            MapSettings { mode: MapMode::Driver, angle: 1.0, zoom: 0.0 }
        );
        assert_eq!(
            n(MapSettings::normalize, json!({"mode": "orbit", "angle": "x", "zoom": null})),
            MapSettings::default()
        );
        assert_eq!(MapSettings::default().to_json(), json!({"mode": "follow", "angle": 0.3, "zoom": 0.5}));
    }

    #[test]
    fn visual_normalization() {
        assert_eq!(VisualSettings::normalize(None), VisualSettings { backdrop_blur: true, render_scale: 1.0 });
        assert_eq!(
            n(VisualSettings::normalize, json!({"render_scale": 0.5, "msaa": 4, "backdrop_blur": false})),
            VisualSettings { backdrop_blur: false, render_scale: 0.5 }
        );
        assert_eq!(
            n(VisualSettings::normalize, json!({"render_scale": 0.6, "backdrop_blur": "no"})),
            VisualSettings::default(),
            "only the listed values"
        );
        assert_eq!(n(normalize_render_scale, json!(0.25)), 0.25);
        assert_eq!(n(normalize_render_scale, json!("0.25")), 1.0);
    }

    #[test]
    fn layout_normalization() {
        let l = n(LayoutSettings::normalize, json!({"rail": ["record", "visual", "visual", "auto"], "dock": ["visual", "record", "auto"]}));
        assert_eq!(l.rail, ["visual", "auto"]);
        assert_eq!(l.dock, ["visual", "auto", "settings", "effects", "howard", "robot3d"], "record dropped, dock completed");
        let l = n(LayoutSettings::normalize, json!({"rail": [], "dock": "junk"}));
        assert!(l.rail.is_empty(), "an empty rail is allowed");
        assert_eq!(l.dock, TABS);
        assert_eq!(n(LayoutSettings::normalize, json!("junk")), LayoutSettings::default());
        assert_eq!(n(LayoutSettings::normalize, json!({"dock": []})).rail, ["auto", "settings"], "missing rail is the default");
    }

    #[test]
    fn controls_normalization() {
        assert_eq!(ControlsSettings::normalize(None), ControlsSettings::default());
        let c = n(ControlsSettings::normalize, json!({"selected_auto": "  Left 3  ", "intake_speed": 0.456}));
        assert_eq!(c.selected_auto, "Left 3");
        assert_eq!(c.intake_speed, Some(0.46));
        assert_eq!(n(ControlsSettings::normalize, json!({"intake_speed": 3})).intake_speed, Some(1.0));
        assert_eq!(n(ControlsSettings::normalize, json!({"intake_speed": null})).intake_speed, None);
        assert_eq!(ControlsSettings::default().to_json(), json!({"selected_auto": "", "intake_speed": null}));
    }

    #[test]
    fn windows_section_normalizes() {
        assert_eq!(WindowsSettings::normalize(None), WindowsSettings { hud_screen: -1, touch_screen: -1 });
        assert_eq!(n(WindowsSettings::normalize, json!({"hud_screen": 1, "touch_screen": 0})), WindowsSettings { hud_screen: 1, touch_screen: 0 });
        assert_eq!(n(WindowsSettings::normalize, json!({"hud_screen": 1.5, "touch_screen": "2"})), WindowsSettings::default());
        assert_eq!(n(WindowsSettings::normalize, json!({"hud_screen": 99, "touch_screen": -9})), WindowsSettings { hud_screen: 7, touch_screen: -1 });
        assert_eq!(n(WindowsSettings::normalize, json!({"hud_screen": 2.0})).hud_screen, 2);
    }

    #[test]
    fn unknown_sections_survive_and_order_is_stable() {
        let raw = json!({"zzz": {"a": 1}, "map": {"mode": "driver"}, "migrations": ["m1"]});
        let s = AppSettings::normalize(Some(&raw));
        assert!(s.has_migration("m1") && !s.has_migration("m2"));
        let out = s.to_json();
        let keys: Vec<&String> = out.as_object().unwrap().keys().collect();
        assert_eq!(keys, ["map", "visual", "layout", "controls", "windows", "zzz", "migrations"]);
        assert_eq!(out["zzz"], json!({"a": 1}));
        assert_eq!(AppSettings::normalize(Some(&out)), s, "round trip");
        assert_eq!(AppSettings::normalize(Some(&json!([1]))), AppSettings::default());
    }

    #[test]
    fn user_data_dir_per_os() {
        let env = |k: &str| match k {
            "APPDATA" => Some(PathBuf::from("C:/Users/d/AppData/Roaming")),
            "HOME" => Some(PathBuf::from("/home/d")),
            _ => None,
        };
        assert_eq!(app_settings_path_for("windows", env), Some(PathBuf::from("C:/Users/d/AppData/Roaming/PWRUP/CompGpui/settings.json")));
        assert_eq!(app_settings_path_for("macos", env), Some(PathBuf::from("/home/d/Library/Application Support/PWRUP/CompGpui/settings.json")));
        assert_eq!(app_settings_path_for("linux", env), Some(PathBuf::from("/home/d/.local/share/PWRUP/CompGpui/settings.json")));
        assert_eq!(app_settings_path_for("windows", |_| None), None);
    }
}
