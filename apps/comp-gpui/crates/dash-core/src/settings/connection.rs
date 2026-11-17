//! NetworkTables connection settings as stored in the shared JSON file
//! (`settings.networkTables` and `settings.reconnectTimeoutSeconds`),
//! normalized like `normalizeSettings` in packages/shared-core, plus the
//! Connection Settings form rules of useTouchscreenSettingsForm.ts.
//! Ports apps/comp-godot/core/settings/connection_settings.gd.

use std::path::PathBuf;

use serde_json::{Map, Value};

use super::json::{num, obj};
use crate::request_state::RequestTopics;

pub const ENV_PATH: &str = "PWRUP_SHARED_SETTINGS_PATH";
/// `reconnectTimeoutSeconds` is the connect timeout in both dashboards: an
/// attempt that has not connected after this long is dropped and retried.
/// The Electron app keeps its own default (10) and reads values below 2 as 10.
pub const DEFAULT_RECONNECT_TIMEOUT_S: u32 = 2;
pub const LEGACY_DEFAULT_RECONNECT_TIMEOUT_S: u32 = 10;
pub const TIMEOUT_MIN_S: u32 = 1;
pub const TIMEOUT_MAX_S: u32 = 60;
pub const TIMEOUT_UI_MIN_S: u32 = 2;
pub const TIMEOUT_UI_MAX_S: u32 = 30;

pub const DEFAULT_HOST: &str = "10.47.65.2";
pub const DEFAULT_PORT: u16 = 5810;
pub const DEFAULT_SHARED_TABLE: &str = "Shared";
pub const DEFAULT_SELECTED_PATH_TOPIC: &str = "PathPlanner/SelectedPath";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NtSettings {
    pub host: String,
    pub port: u16,
    pub shared_table: String,
    pub selected_path_topic: String,
}

impl Default for NtSettings {
    fn default() -> Self {
        Self {
            host: DEFAULT_HOST.into(),
            port: DEFAULT_PORT,
            shared_table: DEFAULT_SHARED_TABLE.into(),
            selected_path_topic: DEFAULT_SELECTED_PATH_TOPIC.into(),
        }
    }
}

impl NtSettings {
    pub fn to_json(&self) -> Map<String, Value> {
        let mut m = Map::new();
        m.insert("host".into(), self.host.clone().into());
        m.insert("port".into(), self.port.into());
        m.insert("sharedTable".into(), self.shared_table.clone().into());
        m.insert(
            "selectedPathTopic".into(),
            self.selected_path_topic.clone().into(),
        );
        m
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ConnectionSettings {
    pub nt: NtSettings,
    pub reconnect_timeout_s: u32,
}

impl Default for ConnectionSettings {
    fn default() -> Self {
        Self {
            nt: NtSettings::default(),
            reconnect_timeout_s: DEFAULT_RECONNECT_TIMEOUT_S,
        }
    }
}

impl ConnectionSettings {
    /// The `settings` object of the shared file.
    pub fn from_settings(settings: Option<&Value>) -> Self {
        let Some(s) = obj(settings) else {
            return Self::default();
        };
        Self {
            nt: normalize_nt(s.get("networkTables")),
            reconnect_timeout_s: normalize_reconnect_timeout(s.get("reconnectTimeoutSeconds")),
        }
    }

    pub fn normalized(&self) -> Self {
        Self {
            nt: normalize_nt(Some(&Value::Object(self.nt.to_json()))),
            reconnect_timeout_s: normalize_reconnect_timeout(Some(&self.reconnect_timeout_s.into())),
        }
    }

    pub fn server(&self) -> String {
        format!("{}:{}", self.nt.host, self.nt.port)
    }

    /// The auto selection Request/State pair.
    pub fn selected_path_topics(&self) -> RequestTopics {
        RequestTopics::new(&self.nt.shared_table, &self.nt.selected_path_topic)
    }
}

/// `PWRUP_SHARED_SETTINGS_PATH`, else `~/.pwrup/shared-settings/connection-settings.json`.
pub fn shared_file_path() -> Option<PathBuf> {
    let home_var = if cfg!(windows) { "USERPROFILE" } else { "HOME" };
    shared_file_path_from(
        std::env::var(ENV_PATH).ok().as_deref(),
        std::env::var_os(home_var).map(PathBuf::from),
    )
}

pub fn shared_file_path_from(env: Option<&str>, home: Option<PathBuf>) -> Option<PathBuf> {
    match env.map(str::trim).filter(|e| !e.is_empty()) {
        Some(e) => Some(PathBuf::from(e)),
        None => home.map(|h| {
            h.join(".pwrup")
                .join("shared-settings")
                .join("connection-settings.json")
        }),
    }
}

pub fn normalize_reconnect_timeout(v: Option<&Value>) -> u32 {
    match num(v) {
        Some(f) if f >= f64::from(TIMEOUT_MIN_S) && f <= f64::from(TIMEOUT_MAX_S) => f.round() as u32,
        _ => DEFAULT_RECONNECT_TIMEOUT_S,
    }
}

pub fn trim_slashes(s: &str) -> &str {
    s.trim().trim_matches('/')
}

fn topic_part(v: Option<&Value>, fallback: &str) -> String {
    let t = v.and_then(Value::as_str).map(trim_slashes).unwrap_or("");
    if t.is_empty() { fallback } else { t }.to_owned()
}

fn port(v: Option<&Value>, fallback: u16) -> u16 {
    match num(v) {
        Some(f) if f > 0.0 && f <= 65535.0 => f.round() as u16,
        _ => fallback,
    }
}

pub fn team_to_robot_ip(team: i64, last_octet: i64) -> String {
    let t = team.max(0);
    format!("10.{}.{}.{}", t / 100, t % 100, last_octet.clamp(1, 254))
}

/// Includes the legacy keys the web loader still migrates
/// (`autonomousSelectedEntry`, `currentPathTopic`, `teamNumber` + `robotIpLastOctet`).
pub fn normalize_nt(raw: Option<&Value>) -> NtSettings {
    let mut out = NtSettings::default();
    let Some(raw) = obj(raw) else {
        return out;
    };
    let host = raw
        .get("host")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|h| !h.is_empty());
    if let Some(h) = host {
        out.host = h.to_owned();
    } else if let Some(team) = num(raw.get("teamNumber")).filter(|t| *t > 0.0) {
        let octet = num(raw.get("robotIpLastOctet")).map_or(2, |o| o as i64);
        out.host = team_to_robot_ip(team as i64, octet);
    }
    out.port = port(raw.get("port"), DEFAULT_PORT);
    out.shared_table = topic_part(raw.get("sharedTable"), DEFAULT_SHARED_TABLE);
    let entry_raw = match raw.get("selectedPathTopic") {
        Some(v @ Value::String(_)) => Some(v),
        _ => raw.get("autonomousSelectedEntry"),
    };
    let entry = topic_part(entry_raw, DEFAULT_SELECTED_PATH_TOPIC);
    out.selected_path_topic = if entry == "AutonomousSelected" {
        DEFAULT_SELECTED_PATH_TOPIC.to_owned()
    } else {
        entry
    };
    let legacy = raw
        .get("currentPathTopic")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|l| !l.is_empty());
    if let Some(legacy) = legacy {
        let parts: Vec<&str> = legacy
            .strip_prefix('/')
            .unwrap_or(legacy)
            .split('/')
            .filter(|p| !p.is_empty())
            .collect();
        if parts.len() >= 2 {
            out.shared_table = topic_part(Some(&parts[0].into()), DEFAULT_SHARED_TABLE);
            out.selected_path_topic =
                topic_part(Some(&parts[1..].join("/").into()), DEFAULT_SELECTED_PATH_TOPIC);
        } else {
            out.shared_table = DEFAULT_SHARED_TABLE.into();
            out.selected_path_topic = DEFAULT_SELECTED_PATH_TOPIC.into();
        }
    }
    out
}

/// JavaScript `Number(s)` for the form's text fields: blank is 0, junk is NaN.
pub fn js_number(s: &str) -> f64 {
    let t = s.trim();
    if t.is_empty() {
        return 0.0;
    }
    t.parse::<f64>()
        .ok()
        .filter(|f| f.is_finite())
        .unwrap_or(f64::NAN)
}

/// The form's raw strings plus the slider value.
#[derive(Clone, Debug, PartialEq)]
pub struct Drafts {
    pub host: String,
    pub port: String,
    pub shared_table: String,
    pub selected_path_topic: String,
    pub reconnect_timeout_s: f32,
}

impl Drafts {
    pub fn from(c: &ConnectionSettings) -> Self {
        Self {
            host: c.nt.host.clone(),
            port: c.nt.port.to_string(),
            shared_table: c.nt.shared_table.clone(),
            selected_path_topic: c.nt.selected_path_topic.clone(),
            reconnect_timeout_s: c.reconnect_timeout_s as f32,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Field {
    Host,
    Port,
    SharedTable,
    SelectedPathTopic,
}

/// The NT Preview rows (ntSelectedPathTopics).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Preview {
    pub host: String,
    pub request: String,
    pub state: String,
    pub robot_constants: String,
}

pub fn preview(host: &str, table: &str, entry: &str) -> Preview {
    let base = format!("/{}/{}", trim_slashes(table), trim_slashes(entry));
    let bare = base.trim_start_matches('/');
    Preview {
        host: if host.trim().is_empty() {
            "(not set)".into()
        } else {
            host.to_owned()
        },
        request: format!("{base}/Request"),
        state: format!("{base}/State"),
        robot_constants: format!("{bare}/Request / {bare}/State"),
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Form {
    pub valid: bool,
    pub changed: bool,
    pub save_enabled: bool,
    pub invalid: Vec<Field>,
    pub next: ConnectionSettings,
    pub preview: Preview,
}

impl Form {
    pub fn is_invalid(&self, f: Field) -> bool {
        self.invalid.contains(&f)
    }
}

/// Save is enabled only when the form is valid and differs from the saved
/// settings; the drafts are trimmed before both checks.
pub fn evaluate_form(d: &Drafts, saved: &ConnectionSettings) -> Form {
    let host = d.host.trim().to_owned();
    let port = js_number(&d.port);
    let table = d.shared_table.trim().to_owned();
    let entry = d.selected_path_topic.trim().to_owned();
    let timeout = d.reconnect_timeout_s.round().max(0.0) as u32;
    let mut invalid = Vec::new();
    if host.is_empty() {
        invalid.push(Field::Host);
    }
    if !(port.is_finite() && port > 0.0 && port <= 65535.0) {
        invalid.push(Field::Port);
    }
    if table.is_empty() {
        invalid.push(Field::SharedTable);
    }
    if entry.is_empty() {
        invalid.push(Field::SelectedPathTopic);
    }
    let changed = host != saved.nt.host
        || !port.is_finite()
        || port.round() != f64::from(saved.nt.port)
        || table != saved.nt.shared_table
        || entry != saved.nt.selected_path_topic
        || timeout != saved.reconnect_timeout_s;
    let valid = invalid.is_empty();
    let preview = preview(&host, &table, &entry);
    Form {
        valid,
        changed,
        save_enabled: valid && changed,
        invalid,
        next: ConnectionSettings {
            nt: NtSettings {
                host,
                port: if port.is_finite() { port.round() as u16 } else { 0 },
                shared_table: table,
                selected_path_topic: entry,
            },
            reconnect_timeout_s: timeout,
        },
        preview,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn nt(v: Value) -> NtSettings {
        normalize_nt(Some(&v))
    }

    #[test]
    fn schema_defaults() {
        let d = ConnectionSettings::default();
        assert_eq!(d.nt.host, "10.47.65.2");
        assert_eq!(d.nt.port, 5810);
        assert_eq!(d.nt.shared_table, "Shared");
        assert_eq!(d.nt.selected_path_topic, "PathPlanner/SelectedPath");
        assert_eq!(d.reconnect_timeout_s, 2);
        assert_eq!(
            d.selected_path_topics(),
            RequestTopics {
                request: "/Shared/PathPlanner/SelectedPath/Request".into(),
                state: "/Shared/PathPlanner/SelectedPath/State".into(),
            }
        );
    }

    #[test]
    fn shared_file_path_env_override() {
        assert_eq!(
            shared_file_path_from(Some(" /tmp/x.json "), Some("/home/a".into())),
            Some(PathBuf::from("/tmp/x.json"))
        );
        assert_eq!(
            shared_file_path_from(Some("  "), Some("/home/a".into())),
            Some(PathBuf::from(
                "/home/a/.pwrup/shared-settings/connection-settings.json"
            ))
        );
        assert_eq!(shared_file_path_from(None, None), None);
    }

    #[test]
    fn normalization_rules() {
        let n = nt(json!({"host": " 127.0.0.1 ", "port": 5811.4, "sharedTable": "/Shared/", "selectedPathTopic": " /A/B/ "}));
        assert_eq!(
            n,
            NtSettings {
                host: "127.0.0.1".into(),
                port: 5811,
                shared_table: "Shared".into(),
                selected_path_topic: "A/B".into()
            }
        );
        let n = nt(json!({"host": "", "port": 70000, "sharedTable": "//", "selectedPathTopic": "AutonomousSelected"}));
        assert_eq!(n, NtSettings::default(), "invalid parts fall back; legacy AutonomousSelected entry rewritten");
        let n = nt(json!({"teamNumber": 4765, "robotIpLastOctet": 2, "autonomousSelectedEntry": "Auto/Sel"}));
        assert_eq!(n.host, "10.47.65.2", "legacy team number");
        assert_eq!(n.selected_path_topic, "Auto/Sel", "legacy entry key");
        let n = nt(json!({"currentPathTopic": "/Tbl/Some/Entry"}));
        assert_eq!((n.shared_table.as_str(), n.selected_path_topic.as_str()), ("Tbl", "Some/Entry"));
        let n = nt(json!({"currentPathTopic": "/Only", "sharedTable": "X"}));
        assert_eq!(n.shared_table, "Shared", "a one-part legacy topic resets both parts");
        assert_eq!(nt(json!("junk")), NtSettings::default());
        let t = |v: Value| normalize_reconnect_timeout(Some(&v));
        assert_eq!(t(json!(61)), 2);
        assert_eq!(t(json!(30.4)), 30);
        assert_eq!(t(json!(1)), 1);
        assert_eq!(t(json!(60)), 60);
        assert_eq!(t(json!(0.4)), 2);
        assert_eq!(t(json!("5")), 2);
        assert_eq!(normalize_reconnect_timeout(None), 2);
        assert_eq!(team_to_robot_ip(254, 300), "10.2.54.254");
    }

    #[test]
    fn from_settings_reads_the_shared_file_section() {
        let s = json!({"host": "10.47.65.7", "port": 8080, "reconnectTimeoutSeconds": 10,
            "networkTables": {"host": "10.0.0.2", "port": 5811}});
        let c = ConnectionSettings::from_settings(Some(&s));
        assert_eq!(c.nt.host, "10.0.0.2");
        assert_eq!(c.nt.port, 5811);
        assert_eq!(c.reconnect_timeout_s, 10);
        assert_eq!(ConnectionSettings::from_settings(None), ConnectionSettings::default());
    }

    #[test]
    fn form_validation_like_the_web() {
        let saved = ConnectionSettings::default();
        let mut d = Drafts::from(&saved);
        let f = evaluate_form(&d, &saved);
        assert!(f.valid && !f.changed && !f.save_enabled, "unchanged: Save disabled");
        d.host = "  10.47.65.2  ".into();
        assert!(!evaluate_form(&d, &saved).changed, "trimmed drafts compare equal");
        d.host = "127.0.0.1".into();
        let f = evaluate_form(&d, &saved);
        assert!(f.save_enabled, "valid and changed");
        assert_eq!(f.next.nt.host, "127.0.0.1");
        for bad in ["", "0", "65536", "abc"] {
            let mut d2 = d.clone();
            d2.port = bad.into();
            let f2 = evaluate_form(&d2, &saved);
            assert!(!f2.valid && !f2.save_enabled, "port {bad} rejected");
            assert_eq!(f2.invalid, vec![Field::Port]);
        }
        let blanks: [(fn(&mut Drafts), Field); 3] = [
            (|d| d.host = "   ".into(), Field::Host),
            (|d| d.shared_table = "   ".into(), Field::SharedTable),
            (|d| d.selected_path_topic = "   ".into(), Field::SelectedPathTopic),
        ];
        for (blank, field) in blanks {
            let mut d3 = Drafts::from(&saved);
            blank(&mut d3);
            assert_eq!(evaluate_form(&d3, &saved).invalid, vec![field], "{field:?} must not be blank");
        }
        let mut d4 = Drafts::from(&saved);
        d4.reconnect_timeout_s = 25.0;
        let f = evaluate_form(&d4, &saved);
        assert!(f.save_enabled, "timeout change enables Save");
        assert_eq!(f.next.reconnect_timeout_s, 25);
        let mut d5 = Drafts::from(&saved);
        d5.port = "65535".into();
        assert!(evaluate_form(&d5, &saved).save_enabled);
        assert_eq!(evaluate_form(&d5, &saved).next.nt.port, 65535);
    }

    #[test]
    fn js_number_like_javascript() {
        assert_eq!(js_number(""), 0.0);
        assert_eq!(js_number(" 12 "), 12.0);
        assert_eq!(js_number("1e3"), 1000.0);
        assert!(js_number("abc").is_nan());
        assert!(js_number("inf").is_nan());
    }

    #[test]
    fn preview_topics() {
        let p = preview("", "/Shared/", "PathPlanner/SelectedPath");
        assert_eq!(
            p,
            Preview {
                host: "(not set)".into(),
                request: "/Shared/PathPlanner/SelectedPath/Request".into(),
                state: "/Shared/PathPlanner/SelectedPath/State".into(),
                robot_constants:
                    "Shared/PathPlanner/SelectedPath/Request / Shared/PathPlanner/SelectedPath/State"
                        .into(),
            }
        );
    }
}
