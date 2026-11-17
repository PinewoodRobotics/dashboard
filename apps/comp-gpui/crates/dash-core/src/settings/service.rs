//! Owner of the app settings file and of the shared connection settings file
//! (apps/comp-godot/services/settings_service.gd). Section writes are
//! normalized, debounced by [`SAVE_DELAY_MS`] and atomic; connection writes go
//! to the shared file at once. The caller drives time: `tick(now_ms)` writes a
//! due save and polls the shared file for edits by the other apps.

use std::fs;
use std::path::PathBuf;

use super::app::{
    AppSettings, ControlsSettings, LayoutSettings, MapSettings, VisualSettings, WindowsSettings,
};
use super::connection::{
    ConnectionSettings, DEFAULT_RECONNECT_TIMEOUT_S, LEGACY_DEFAULT_RECONNECT_TIMEOUT_S,
};
use super::json::{parse, stringify, write_atomically};
use super::shared_store::SharedSettingsStore;

pub const SAVE_DELAY_MS: u64 = 250;
pub const MIGRATION_CONNECT_TIMEOUT: &str = "connect_timeout_2s";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Section {
    Map,
    Visual,
    Layout,
    Controls,
    Windows,
    Connection,
}

#[derive(Debug)]
pub struct SettingsService {
    /// None: nothing is read from or written to disk (offline fixtures).
    pub path: Option<PathBuf>,
    pub data: AppSettings,
    pub connection_store: SharedSettingsStore,
    pub last_error: String,
    save_due_ms: Option<u64>,
}

impl SettingsService {
    /// Loads the app settings file and the shared file.
    pub fn open(path: Option<PathBuf>, connection_store: SharedSettingsStore) -> Self {
        let mut s = Self {
            path,
            data: AppSettings::default(),
            connection_store,
            last_error: String::new(),
            save_due_ms: None,
        };
        s.load_file();
        s.connection_store.reload();
        s
    }

    /// A missing or malformed file loads the defaults.
    pub fn load_file(&mut self) {
        let Some(path) = &self.path else {
            return;
        };
        let text = fs::read_to_string(path).unwrap_or_default();
        self.data = AppSettings::normalize(parse(&text).as_ref());
    }

    pub fn connection(&self) -> &ConnectionSettings {
        &self.connection_store.current
    }

    /// Writes the shared file now (atomic, version + 1). Err holds the reason
    /// the write failed; Ok says whether the settings changed.
    pub fn set_connection(&mut self, conn: &ConnectionSettings) -> Result<bool, String> {
        let before = self.connection_store.current.clone();
        if !self.connection_store.save(conn) {
            return Err(self.connection_store.last_error.clone());
        }
        Ok(self.connection_store.current != before)
    }

    pub fn reset_connection(&mut self) -> Result<bool, String> {
        self.set_connection(&ConnectionSettings::default())
    }

    /// Once per install: a shared file still holding the old 10 s default
    /// (written by every earlier save, from either app) gets the 2 s connect
    /// timeout. A value chosen after this ran is never touched again.
    pub fn migrate_connect_timeout(&mut self) -> bool {
        if self.path.is_none() || self.connection_store.memory_only {
            return false;
        }
        if self.data.has_migration(MIGRATION_CONNECT_TIMEOUT) {
            return false;
        }
        let mut migrated = false;
        if self.connection().reconnect_timeout_s == LEGACY_DEFAULT_RECONNECT_TIMEOUT_S {
            let mut next = self.connection().clone();
            next.reconnect_timeout_s = DEFAULT_RECONNECT_TIMEOUT_S;
            if self.set_connection(&next).is_err() {
                return false;
            }
            migrated = true;
        }
        self.data.add_migration(MIGRATION_CONNECT_TIMEOUT);
        self.save_now();
        migrated
    }

    pub fn set_map(&mut self, v: &MapSettings, now_ms: u64) -> bool {
        let v = v.normalized();
        self.patch(now_ms, |d| replace(&mut d.map, v))
    }

    pub fn set_visual(&mut self, v: &VisualSettings, now_ms: u64) -> bool {
        let v = v.normalized();
        self.patch(now_ms, |d| replace(&mut d.visual, v))
    }

    pub fn set_layout(&mut self, v: &LayoutSettings, now_ms: u64) -> bool {
        let v = v.normalized();
        self.patch(now_ms, |d| replace(&mut d.layout, v))
    }

    pub fn set_controls(&mut self, v: &ControlsSettings, now_ms: u64) -> bool {
        let v = v.normalized();
        self.patch(now_ms, |d| replace(&mut d.controls, v))
    }

    pub fn set_windows(&mut self, v: &WindowsSettings, now_ms: u64) -> bool {
        let v = v.normalized();
        self.patch(now_ms, |d| replace(&mut d.windows, v))
    }

    pub fn reset(&mut self, section: Section, now_ms: u64) -> bool {
        match section {
            Section::Map => self.set_map(&MapSettings::default(), now_ms),
            Section::Visual => self.set_visual(&VisualSettings::default(), now_ms),
            Section::Layout => self.set_layout(&LayoutSettings::default(), now_ms),
            Section::Controls => self.set_controls(&ControlsSettings::default(), now_ms),
            Section::Windows => self.set_windows(&WindowsSettings::default(), now_ms),
            Section::Connection => self.reset_connection().unwrap_or(false),
        }
    }

    fn patch(&mut self, now_ms: u64, f: impl FnOnce(&mut AppSettings) -> bool) -> bool {
        if !f(&mut self.data) {
            return false;
        }
        if self.path.is_some() {
            self.save_due_ms = Some(now_ms + SAVE_DELAY_MS);
        }
        true
    }

    pub fn save_pending(&self) -> bool {
        self.save_due_ms.is_some()
    }

    /// Writes a due save; true when the shared file changed on disk.
    pub fn tick(&mut self, now_ms: u64) -> bool {
        if self.save_due_ms.is_some_and(|due| now_ms >= due) {
            self.save_now();
        }
        self.connection_store.poll(now_ms)
    }

    /// Writes a pending save now (on quit).
    pub fn flush(&mut self) {
        if self.save_due_ms.is_some() {
            self.save_now();
        }
    }

    pub fn save_now(&mut self) -> bool {
        self.save_due_ms = None;
        let Some(path) = &self.path else {
            return false;
        };
        match write_atomically(path, &stringify(&self.data.to_json())) {
            Ok(()) => {
                self.last_error.clear();
                true
            }
            Err(e) => {
                self.last_error = format!("cannot write {} ({e})", path.display());
                false
            }
        }
    }
}

fn replace<T: PartialEq>(slot: &mut T, v: T) -> bool {
    if *slot == v {
        return false;
    }
    *slot = v;
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::app::MapMode;
    use crate::settings::test_dir::TestDir;
    use serde_json::{Value, json};

    fn service(dir: &TestDir, name: &str) -> SettingsService {
        SettingsService::open(
            Some(dir.path().join(name)),
            SharedSettingsStore::new(dir.file(), false),
        )
    }

    #[test]
    fn set_map_debounces_and_persists_atomically() {
        let dir = TestDir::new("svc-map");
        let mut s = service(&dir, "settings.json");
        let mut m = s.data.map.clone();
        m.zoom = 0.8;
        assert!(s.set_map(&m, 1000));
        assert_eq!(s.data.map.zoom, 0.8);
        assert!(!s.set_map(&m, 1001), "no change, no save");
        assert!(!s.tick(1100) && !dir.path().join("settings.json").exists(), "debounced");
        s.tick(1250);
        assert!(!s.save_pending());
        assert_eq!(dir.files(), vec!["settings.json"], "no temp file left behind");
        let s2 = service(&dir, "settings.json");
        assert_eq!(s2.data.map.zoom, 0.8);
        let raw: Value = serde_json::from_str(&fs::read_to_string(dir.path().join("settings.json")).unwrap()).unwrap();
        assert_eq!(raw["map"], json!({"mode": "follow", "angle": 0.3, "zoom": 0.8}));
    }

    #[test]
    fn writes_are_normalized() {
        let dir = TestDir::new("svc-normalize");
        let mut s = service(&dir, "settings.json");
        assert!(s.set_map(&MapSettings { mode: MapMode::Driver, angle: 3.0, zoom: -2.0 }, 0));
        assert_eq!(s.data.map, MapSettings { mode: MapMode::Driver, angle: 1.0, zoom: 0.0 });
        assert!(s.set_visual(&VisualSettings { backdrop_blur: false, render_scale: 0.6 }, 0));
        assert_eq!(s.data.visual.render_scale, 1.0, "not a listed scale");
        assert!(s.set_windows(&WindowsSettings { hud_screen: 12, touch_screen: -4 }, 0));
        assert_eq!(s.data.windows, WindowsSettings { hud_screen: 7, touch_screen: -1 });
        assert!(s.reset(Section::Visual, 0));
        assert_eq!(s.data.visual, VisualSettings::default());
        assert!(!s.reset(Section::Visual, 0));
    }

    #[test]
    fn corrupt_file_loads_defaults_and_layout_round_trips() {
        let dir = TestDir::new("svc-corrupt");
        let path = dir.path().join("settings.json");
        fs::write(&path, "{not json").unwrap();
        let mut s = service(&dir, "settings.json");
        assert_eq!(s.data, AppSettings::default());
        let layout = LayoutSettings {
            rail: vec!["howard".into(), "record".into()],
            dock: vec!["record".into(), "visual".into()],
        };
        s.set_layout(&layout, 0);
        s.set_visual(&VisualSettings { backdrop_blur: true, render_scale: 0.25 }, 0);
        assert!(s.save_now());
        let s2 = service(&dir, "settings.json");
        assert_eq!(s2.data.layout.rail, ["howard"]);
        assert_eq!(s2.data.layout.dock, ["visual", "auto", "settings", "effects", "howard", "robot3d"]);
        assert_eq!(s2.data.visual.render_scale, 0.25);
    }

    #[test]
    fn no_path_never_touches_disk() {
        let dir = TestDir::new("svc-memory");
        let mut s = SettingsService::open(None, SharedSettingsStore::new(dir.file(), true));
        assert!(s.set_map(&MapSettings { zoom: 0.9, ..MapSettings::default() }, 0));
        s.tick(10_000);
        s.flush();
        assert!(!s.save_now());
        assert!(s.set_connection(&ConnectionSettings::default()).is_ok());
        assert!(!s.migrate_connect_timeout());
        assert!(dir.files().is_empty());
    }

    fn with_shared(dir: &TestDir, timeout: u32, settings_name: &str) -> SettingsService {
        let shared = dir.path().join(format!("shared-{settings_name}"));
        fs::write(
            &shared,
            json!({"version": 3, "settings": {"host": "10.47.65.7", "port": 8080, "reconnectTimeoutSeconds": timeout,
                "networkTables": {"host": "10.47.65.2", "port": 5810}}})
            .to_string(),
        )
        .unwrap();
        SettingsService::open(
            Some(dir.path().join(settings_name)),
            SharedSettingsStore::new(shared, false),
        )
    }

    #[test]
    fn connect_timeout_migrates_old_default_once() {
        let dir = TestDir::new("svc-migrate");
        let mut s = with_shared(&dir, 10, "a.json");
        assert!(s.migrate_connect_timeout(), "old 10 s default migrated");
        assert_eq!(s.connection().reconnect_timeout_s, 2);
        let raw: Value = serde_json::from_str(&fs::read_to_string(&s.connection_store.path).unwrap()).unwrap();
        assert_eq!(raw["settings"]["reconnectTimeoutSeconds"], 2, "written to the shared file");
        assert_eq!(raw["settings"]["host"], "10.47.65.7", "other keys kept");
        let mut chosen = s.connection().clone();
        chosen.reconnect_timeout_s = 10;
        assert!(s.set_connection(&chosen).unwrap());
        let shared = s.connection_store.path.clone();
        let mut s2 = SettingsService::open(
            Some(dir.path().join("a.json")),
            SharedSettingsStore::new(shared, false),
        );
        assert!(!s2.migrate_connect_timeout(), "a 10 chosen after the migration stays");
        assert_eq!(s2.connection().reconnect_timeout_s, 10);
        let mut s3 = with_shared(&dir, 5, "b.json");
        assert!(!s3.migrate_connect_timeout(), "a non-default value is left alone");
        assert_eq!(s3.connection().reconnect_timeout_s, 5);
        assert!(s3.data.has_migration(MIGRATION_CONNECT_TIMEOUT), "recorded either way");
    }

    #[test]
    fn sees_external_edit_and_reset_keeps_foreign_keys() {
        let dir = TestDir::new("svc-external");
        let live = json!({"version": 9, "settings": {"host": "192.168.252.2", "port": 8080, "reconnectTimeoutSeconds": 10,
            "networkTables": {"host": "10.47.65.2", "port": 5810}}});
        fs::write(dir.file(), live.to_string()).unwrap();
        let mut s = service(&dir, "settings.json");
        assert_eq!(s.connection().nt.host, "10.47.65.2");
        assert!(!s.tick(0));
        let mut edited = live.clone();
        edited["settings"]["networkTables"]["host"] = "127.0.0.2".into();
        edited["version"] = 10.into();
        fs::write(dir.file(), edited.to_string()).unwrap();
        assert!(!s.tick(1999));
        assert!(s.tick(2000), "picked up within one poll interval");
        assert_eq!(s.connection().nt.host, "127.0.0.2");
        let mut next = s.connection().clone();
        next.nt.host = "127.0.0.3".into();
        assert_eq!(s.set_connection(&next), Ok(true));
        let raw = || -> Value { serde_json::from_str(&fs::read_to_string(dir.file()).unwrap()).unwrap() };
        assert_eq!(raw()["version"], 11);
        assert_eq!(s.reset_connection(), Ok(true));
        assert_eq!(raw()["settings"]["networkTables"]["host"], "10.47.65.2", "Reset writes the schema defaults");
        assert_eq!(raw()["settings"]["host"], "192.168.252.2", "Reset keeps the Autobahn host");
        assert_eq!(s.reset_connection(), Ok(false), "already the defaults");
    }

    #[test]
    fn failed_connection_write_is_reported() {
        let dir = TestDir::new("svc-fail");
        fs::write(dir.path().join("blocker"), "").unwrap();
        let mut s = SettingsService::open(
            None,
            SharedSettingsStore::new(dir.path().join("blocker").join("c.json"), false),
        );
        let err = s.reset_connection().unwrap_err();
        assert!(err.starts_with("cannot write"), "{err}");
    }
}
