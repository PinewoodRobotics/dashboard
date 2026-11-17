//! Settings stores (L5): the connection settings file shared with the
//! Electron and Godot dashboards, and this dashboard's own map, visual,
//! layout, controls and window sections.

pub mod app;
pub mod connection;
mod json;
pub mod placement;
pub mod service;
pub mod shared_store;

pub use app::{
    AppSettings, ControlsSettings, LayoutSettings, MapMode, MapSettings, RENDER_SCALES,
    VisualSettings, WindowsSettings, default_app_settings_path, legacy_layout_path,
};
pub use connection::{ConnectionSettings, NtSettings};
pub use service::{Section, SettingsService};
pub use shared_store::SharedSettingsStore;

#[cfg(test)]
pub(crate) mod test_dir {
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicU32, Ordering};

    /// A fresh directory under the system temp dir, removed on drop.
    pub struct TestDir(PathBuf);

    impl TestDir {
        pub fn new(name: &str) -> Self {
            static SEQ: AtomicU32 = AtomicU32::new(0);
            let p = std::env::temp_dir().join(format!(
                "dash-core-{name}-{}-{}",
                std::process::id(),
                SEQ.fetch_add(1, Ordering::Relaxed)
            ));
            let _ = std::fs::remove_dir_all(&p);
            std::fs::create_dir_all(&p).unwrap();
            Self(p)
        }

        pub fn path(&self) -> &Path {
            &self.0
        }

        pub fn file(&self) -> PathBuf {
            self.0.join("connection-settings.json")
        }

        pub fn files(&self) -> Vec<String> {
            let mut v: Vec<String> = std::fs::read_dir(&self.0)
                .unwrap()
                .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
                .collect();
            v.sort();
            v
        }
    }

    impl Drop for TestDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
}
