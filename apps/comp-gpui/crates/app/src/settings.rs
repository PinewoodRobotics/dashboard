//! The settings service as a GPUI global. Screens keep reading the mirrored
//! values from `MockData` (`connection`, `map`, `visual`); writes go through
//! here so they are normalized, persisted and mirrored back in one step.

use std::path::PathBuf;
use std::time::{Duration, Instant};

use dash_core::settings::connection::ENV_PATH;
use dash_core::settings::{
    ConnectionSettings, LayoutSettings, MapSettings, Section, SettingsService,
    SharedSettingsStore, VisualSettings, WindowsSettings, default_app_settings_path,
    legacy_layout_path,
};
use gpui_kit::*;

use crate::mock::MockData;

const TICK: Duration = Duration::from_millis(250);

pub struct Options {
    pub path: Option<PathBuf>,
    pub shared_memory_only: bool,
    /// The old standalone layout file to import once; only the default
    /// settings file imports it.
    pub legacy_layout: Option<PathBuf>,
}

impl Options {
    /// `--settings=PATH` uses another app settings file. Fixture runs persist
    /// nothing unless `--settings` is given, and keep the connection settings
    /// in memory unless PWRUP_SHARED_SETTINGS_PATH is set, so a screenshot run
    /// never rewrites the real files.
    pub fn new(settings_path: Option<PathBuf>, fixture: bool) -> Self {
        let env_shared = std::env::var(ENV_PATH).is_ok_and(|v| !v.trim().is_empty());
        let default = settings_path.is_none() && !fixture;
        Self {
            path: settings_path.or_else(|| default.then(default_app_settings_path).flatten()),
            shared_memory_only: fixture && !env_shared,
            legacy_layout: default.then(legacy_layout_path).flatten(),
        }
    }
}

struct Settings {
    service: SettingsService,
    data: Entity<MockData>,
    epoch: Instant,
}

impl Global for Settings {}

impl Settings {
    fn now_ms(&self) -> u64 {
        self.epoch.elapsed().as_millis() as u64
    }
}

pub fn install(data: &Entity<MockData>, opts: Options, cx: &mut App) {
    let store = SharedSettingsStore::open_default(opts.shared_memory_only);
    let mut service = SettingsService::open(opts.path, store);
    if service.migrate_connect_timeout() {
        eprintln!("comp-gpui: settings: connect timeout 10 s -> 2 s (old default)");
    }
    if let Some(legacy) = &opts.legacy_layout
        && service.migrate_layout_file(legacy)
    {
        eprintln!("comp-gpui: settings: layout imported from {}", legacy.display());
    }
    eprintln!(
        "comp-gpui: settings {} | shared {}",
        service
            .path
            .as_ref()
            .map_or("(memory)".into(), |p| p.display().to_string()),
        if service.connection_store.memory_only {
            "(memory)".into()
        } else {
            service.connection_store.path.display().to_string()
        }
    );
    cx.set_global(Settings {
        service,
        data: data.clone(),
        epoch: Instant::now(),
    });
    mirror(cx, &[Section::Connection, Section::Map, Section::Visual]);

    cx.spawn(async move |cx| {
        loop {
            cx.background_executor().timer(TICK).await;
            cx.update(|cx| {
                let s = cx.global_mut::<Settings>();
                let now = s.now_ms();
                if s.service.tick(now) {
                    mirror(cx, &[Section::Connection]);
                }
            });
        }
    })
    .detach();
    cx.on_app_quit(|cx| {
        cx.global_mut::<Settings>().service.flush();
        async {}
    })
    .detach();
}

fn mirror(cx: &mut App, sections: &[Section]) {
    let s = cx.global::<Settings>();
    let data = s.data.clone();
    let conn = s.service.connection().clone();
    let app = s.service.data.clone();
    data.update(cx, |d, cx| {
        for section in sections {
            match section {
                Section::Connection => {
                    if d.nt_link.is_none() {
                        d.nt.host = conn.nt.host.clone();
                        d.nt.port = conn.nt.port;
                    }
                    let table_moved = d.connection.nt.shared_table != conn.nt.shared_table;
                    d.connection = conn.clone();
                    if table_moved {
                        crate::mock_link::set_shared_table(d, &conn.nt.shared_table);
                    }
                }
                Section::Map => d.map = app.map.clone(),
                Section::Visual => d.visual = app.visual.clone(),
                Section::Layout | Section::Controls | Section::Windows => {}
            }
        }
        cx.notify();
    });
}

fn service(cx: &App) -> &SettingsService {
    &cx.global::<Settings>().service
}

fn update(cx: &mut App, section: Section, f: impl FnOnce(&mut SettingsService, u64) -> bool) {
    let s = cx.global_mut::<Settings>();
    let now = s.now_ms();
    if f(&mut s.service, now) {
        mirror(cx, &[section]);
    }
}

/// Writes the shared file now. Err holds the reason the write failed.
pub fn save_connection(next: &ConnectionSettings, cx: &mut App) -> Result<(), String> {
    let r = cx.global_mut::<Settings>().service.set_connection(next);
    mirror(cx, &[Section::Connection]);
    r.map(|_| ())
}

pub fn reset_connection(cx: &mut App) -> Result<(), String> {
    save_connection(&ConnectionSettings::default(), cx)
}

pub fn set_map(map: &MapSettings, cx: &mut App) {
    update(cx, Section::Map, |s, now| s.set_map(map, now));
}

pub fn set_visual(visual: &VisualSettings, cx: &mut App) {
    update(cx, Section::Visual, |s, now| s.set_visual(visual, now));
}

pub fn reset_visual(cx: &mut App) {
    update(cx, Section::Visual, |s, now| s.reset(Section::Visual, now));
}

pub fn windows(cx: &App) -> WindowsSettings {
    cx.try_global::<Settings>()
        .map(|s| s.service.data.windows)
        .unwrap_or_default()
}

pub fn set_windows(w: &WindowsSettings, cx: &mut App) {
    update(cx, Section::Windows, |s, now| s.set_windows(w, now));
}

/// The rail and dock lists; the touchscreen reads them when it opens, so a
/// re-tiled window keeps them.
pub fn layout(cx: &App) -> LayoutSettings {
    cx.try_global::<Settings>()
        .map(|s| s.service.data.layout.clone())
        .unwrap_or_default()
}

pub fn set_layout(layout: &LayoutSettings, cx: &mut App) {
    update(cx, Section::Layout, |s, now| s.set_layout(layout, now));
}

pub fn last_error(cx: &App) -> String {
    service(cx).last_error.clone()
}
