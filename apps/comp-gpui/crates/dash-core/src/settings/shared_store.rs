//! The connection settings file shared with the Electron comp app, the admin
//! app and the Godot port (apps/comp/electron/shared-settings.cjs,
//! apps/comp-godot/core/settings/shared_settings_store.gd). Only
//! `settings.networkTables` and `settings.reconnectTimeoutSeconds` are ours:
//! every other key (the Autobahn host and port, hudVisibility, keys from newer
//! builds) is written back as it was read, in its original order. Saves bump
//! `version` and replace the file atomically. `poll` re-reads the file at most
//! every [`POLL_MS`] and reports external edits. With `memory_only` nothing
//! touches the disk (offline fixtures, screenshot runs).

use std::fs;
use std::path::PathBuf;

use serde_json::{Map, Value};

use super::connection::{ConnectionSettings, shared_file_path};
use super::json::{iso_utc_now, num, parse, stringify, write_atomically};

pub const POLL_MS: u64 = 2000;
const DEFAULT_AUTOBAHN_HOST: &str = "10.47.65.7";
const DEFAULT_AUTOBAHN_PORT: u16 = 8080;

fn default_hud_visibility() -> Value {
    serde_json::json!({"showMap": false, "showTimers": true, "showStatus": true, "showCamera": true})
}

#[derive(Debug)]
pub struct SharedSettingsStore {
    pub path: PathBuf,
    pub memory_only: bool,
    pub current: ConnectionSettings,
    pub version: u64,
    pub last_error: String,
    last_text: String,
    next_poll_ms: u64,
}

fn version_of(doc: &Map<String, Value>) -> u64 {
    match num(doc.get("version")) {
        Some(v) if v >= 1.0 => v.floor() as u64,
        _ => 1,
    }
}

impl SharedSettingsStore {
    pub fn new(path: PathBuf, memory_only: bool) -> Self {
        Self {
            path,
            memory_only,
            current: ConnectionSettings::default(),
            version: 0,
            last_error: String::new(),
            last_text: String::new(),
            next_poll_ms: 0,
        }
    }

    /// The default shared file, or memory only when there is no home directory.
    pub fn open_default(memory_only: bool) -> Self {
        match shared_file_path() {
            Some(p) => Self::new(p, memory_only),
            None => Self::new(PathBuf::new(), true),
        }
    }

    /// Re-reads the file; true when the normalized settings changed. A missing
    /// or corrupt file reads as the defaults and is left alone until a save.
    pub fn reload(&mut self) -> bool {
        if self.memory_only {
            return false;
        }
        let text = fs::read_to_string(&self.path).unwrap_or_default();
        if text == self.last_text && !text.is_empty() {
            return false;
        }
        let raw = parse(&text);
        self.last_text = text;
        let (next, version) = match raw.as_ref().and_then(Value::as_object) {
            Some(doc) => (
                ConnectionSettings::from_settings(doc.get("settings")),
                version_of(doc),
            ),
            None => (ConnectionSettings::default(), 0),
        };
        self.version = version;
        if next == self.current {
            return false;
        }
        self.current = next;
        true
    }

    pub fn poll(&mut self, now_ms: u64) -> bool {
        if self.memory_only || now_ms < self.next_poll_ms {
            return false;
        }
        self.next_poll_ms = now_ms + POLL_MS;
        self.reload()
    }

    /// Writes `conn` (normalized first). The rest of the file is re-read right
    /// before writing so concurrent edits by the other apps to keys we do not
    /// own survive. A new file gets the Electron key order.
    pub fn save(&mut self, conn: &ConnectionSettings) -> bool {
        let normalized = conn.normalized();
        if self.memory_only {
            self.current = normalized;
            self.version += 1;
            return true;
        }
        let read = fs::read_to_string(&self.path).ok();
        let mut doc = match read.as_deref().and_then(parse) {
            Some(Value::Object(m)) => m,
            _ => Map::new(),
        };
        let next_version = if doc.is_empty() { 0 } else { version_of(&doc) } + 1;
        if doc.is_empty() {
            doc.insert("version".into(), Value::Null);
            doc.insert("updatedAtIso".into(), Value::Null);
        }
        let mut settings = match doc.get("settings") {
            Some(Value::Object(s)) => s.clone(),
            _ => Map::new(),
        };
        let was_new = settings.is_empty();
        settings
            .entry("host")
            .or_insert_with(|| DEFAULT_AUTOBAHN_HOST.into());
        settings
            .entry("port")
            .or_insert_with(|| DEFAULT_AUTOBAHN_PORT.into());
        if was_new {
            settings.insert("reconnectTimeoutSeconds".into(), Value::Null);
        }
        let mut nt = match settings.get("networkTables") {
            Some(Value::Object(m)) => m.clone(),
            _ => Map::new(),
        };
        for (k, v) in normalized.nt.to_json() {
            nt.insert(k, v);
        }
        settings.insert("networkTables".into(), Value::Object(nt));
        settings.insert(
            "reconnectTimeoutSeconds".into(),
            normalized.reconnect_timeout_s.into(),
        );
        doc.insert("settings".into(), Value::Object(settings));
        if !matches!(doc.get("hudVisibility"), Some(Value::Object(_))) {
            doc.insert("hudVisibility".into(), default_hud_visibility());
        }
        doc.insert("version".into(), next_version.into());
        doc.insert("updatedAtIso".into(), iso_utc_now().into());
        let text = stringify(&Value::Object(doc));
        if let Err(e) = write_atomically(&self.path, &text) {
            self.last_error = format!("cannot write {} ({e})", self.path.display());
            return false;
        }
        self.last_error.clear();
        self.last_text = text;
        self.current = normalized;
        self.version = next_version;
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::connection::NtSettings;
    use crate::settings::test_dir::TestDir;
    use serde_json::json;

    fn live_file() -> Value {
        json!({
            "version": 9,
            "updatedAtIso": "2026-07-07T01:39:18.069Z",
            "settings": {
                "host": "192.168.252.2",
                "port": 8080,
                "reconnectTimeoutSeconds": 10,
                "networkTables": {"host": "10.47.65.2", "port": 5810, "sharedTable": "Shared", "selectedPathTopic": "PathPlanner/SelectedPath", "futureNtKey": "keep"},
            },
            "hudVisibility": {"showMap": false, "showTimers": true, "showStatus": true, "showCamera": true},
            "futureTopKey": {"nested": [1, 2.5, "x"]},
        })
    }

    fn write(dir: &TestDir, v: &Value) {
        fs::write(dir.file(), serde_json::to_string_pretty(v).unwrap()).unwrap();
    }

    fn read(dir: &TestDir) -> Value {
        serde_json::from_str(&fs::read_to_string(dir.file()).unwrap()).unwrap()
    }

    fn conn(host: &str, port: u16, timeout: u32) -> ConnectionSettings {
        ConnectionSettings {
            nt: NtSettings {
                host: host.into(),
                port,
                ..NtSettings::default()
            },
            reconnect_timeout_s: timeout,
        }
    }

    #[test]
    fn save_round_trip_preserves_unknown_keys() {
        let dir = TestDir::new("shared-roundtrip");
        write(&dir, &live_file());
        let mut store = SharedSettingsStore::new(dir.file(), false);
        store.reload();
        assert_eq!(store.version, 9);
        assert_eq!(store.current.nt.host, "10.47.65.2");
        let next = conn("127.0.0.1", 5811, 4);
        assert!(store.save(&next));
        let raw = read(&dir);
        assert_eq!(raw["version"], 10, "version + 1");
        assert_eq!(raw["settings"]["host"], "192.168.252.2", "Autobahn host survives");
        assert_eq!(raw["settings"]["port"], 8080, "Autobahn port survives");
        assert_eq!(raw["hudVisibility"], live_file()["hudVisibility"]);
        assert_eq!(raw["futureTopKey"], json!({"nested": [1, 2.5, "x"]}), "unknown top-level key survives");
        assert_eq!(raw["settings"]["networkTables"]["futureNtKey"], "keep", "unknown nested key survives");
        assert_eq!(raw["settings"]["networkTables"]["host"], "127.0.0.1");
        assert_eq!(raw["settings"]["networkTables"]["port"], 5811);
        assert_eq!(raw["settings"]["reconnectTimeoutSeconds"], 4);
        assert!(raw["updatedAtIso"].as_str().unwrap().ends_with('Z'));
        let keys: Vec<&String> = raw.as_object().unwrap().keys().collect();
        assert_eq!(keys, ["version", "updatedAtIso", "settings", "hudVisibility", "futureTopKey"], "key order kept");
        let text = fs::read_to_string(dir.file()).unwrap();
        assert!(text.contains("\"port\": 5811") && !text.contains("5811.0"), "whole numbers stay integers");
        assert_eq!(dir.files(), vec!["connection-settings.json"], "no temp file left behind");
        let mut again = SharedSettingsStore::new(dir.file(), false);
        again.reload();
        assert_eq!(again.current, next);
        assert!(store.save(&next));
        assert_eq!(read(&dir)["version"], 11);
    }

    #[test]
    fn integral_floats_from_other_writers_come_back_as_integers() {
        let dir = TestDir::new("shared-floats");
        fs::write(
            dir.file(),
            r#"{"version": 3.0, "settings": {"host": "h", "port": 8080.0, "networkTables": {"port": 5810.0}}}"#,
        )
        .unwrap();
        let mut store = SharedSettingsStore::new(dir.file(), false);
        store.reload();
        assert!(store.save(&ConnectionSettings::default()));
        let text = fs::read_to_string(dir.file()).unwrap();
        assert!(text.contains("\"port\": 8080,") && text.contains("\"version\": 4,"), "{text}");
    }

    #[test]
    fn save_creates_missing_file_in_electron_layout_and_ignores_corrupt() {
        let dir = TestDir::new("shared-create");
        let mut store = SharedSettingsStore::new(dir.file(), false);
        assert!(!store.reload(), "missing file: defaults, no change");
        assert!(!dir.file().exists(), "reading never writes");
        assert!(store.save(&ConnectionSettings::default()));
        let raw = read(&dir);
        assert_eq!(raw["version"], 1);
        assert_eq!(raw["settings"]["host"], "10.47.65.7", "Electron needs the Autobahn keys");
        assert_eq!(raw["hudVisibility"]["showTimers"], true);
        let text = fs::read_to_string(dir.file()).unwrap();
        let iso = raw["updatedAtIso"].as_str().unwrap();
        let expected = format!(
            r#"{{
  "version": 1,
  "updatedAtIso": "{iso}",
  "settings": {{
    "host": "10.47.65.7",
    "port": 8080,
    "reconnectTimeoutSeconds": 2,
    "networkTables": {{
      "host": "10.47.65.2",
      "port": 5810,
      "sharedTable": "Shared",
      "selectedPathTopic": "PathPlanner/SelectedPath"
    }}
  }},
  "hudVisibility": {{
    "showMap": false,
    "showTimers": true,
    "showStatus": true,
    "showCamera": true
  }}
}}"#
        );
        assert_eq!(text, expected, "byte for byte what JSON.stringify(payload, null, 2) writes");
        assert_eq!(iso.len(), "2026-07-07T01:39:18.069Z".len());

        fs::write(dir.file(), "{not json").unwrap();
        let mut s2 = SharedSettingsStore::new(dir.file(), false);
        s2.current = conn("x", 1, 5);
        assert!(s2.reload(), "corrupt file reads as defaults");
        assert_eq!(s2.current, ConnectionSettings::default());
        assert_eq!(fs::read_to_string(dir.file()).unwrap(), "{not json", "corrupt file left alone until a save");
    }

    #[test]
    fn poll_picks_up_external_edits() {
        let dir = TestDir::new("shared-poll");
        write(&dir, &live_file());
        let mut store = SharedSettingsStore::new(dir.file(), false);
        store.reload();
        assert!(!store.poll(0));
        let mut edited = live_file();
        edited["settings"]["networkTables"]["host"] = "10.0.0.9".into();
        write(&dir, &edited);
        assert!(!store.poll(1000), "polls every 2 s");
        assert!(store.poll(2000));
        assert_eq!(store.current.nt.host, "10.0.0.9");
        assert!(!store.poll(4000), "no change, no report");
    }

    #[test]
    fn memory_only_never_touches_disk() {
        let dir = TestDir::new("shared-memory");
        let mut store = SharedSettingsStore::new(dir.file(), true);
        assert!(store.save(&conn("1.2.3.4", 5810, 3)));
        assert_eq!(store.current.nt.host, "1.2.3.4");
        assert_eq!(store.version, 1);
        assert!(!dir.file().exists());
        assert!(!store.reload() && !store.poll(10_000));
    }

    #[test]
    fn save_normalizes_what_it_writes() {
        let dir = TestDir::new("shared-normalize");
        let mut store = SharedSettingsStore::new(dir.file(), false);
        let mut c = conn(" 10.0.0.5 ", 5810, 99);
        c.nt.shared_table = "/Tbl/".into();
        assert!(store.save(&c));
        let raw = read(&dir);
        assert_eq!(raw["settings"]["networkTables"]["host"], "10.0.0.5");
        assert_eq!(raw["settings"]["networkTables"]["sharedTable"], "Tbl");
        assert_eq!(raw["settings"]["reconnectTimeoutSeconds"], 2, "out of range: default");
    }

    #[test]
    fn unwritable_path_reports_an_error() {
        let dir = TestDir::new("shared-unwritable");
        fs::write(dir.path().join("blocker"), "").unwrap();
        let mut store = SharedSettingsStore::new(dir.path().join("blocker").join("c.json"), false);
        assert!(!store.save(&ConnectionSettings::default()));
        assert!(store.last_error.starts_with("cannot write"), "{}", store.last_error);
        assert_eq!(store.current, ConnectionSettings::default());
    }
}
