//! The persisted rail and dock lists (layoutStorage.ts; Godot's `layout`
//! settings section, `{"rail": [...], "dock": [...]}`). Unknown ids are
//! dropped, duplicates keep their first occurrence, and the dock is completed
//! in default order, so a stored layout from an older build (with the web's
//! Record tab, say) still loads.

use std::io;
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Layout {
    pub rail: Vec<String>,
    pub dock: Vec<String>,
}

pub struct Tabs<'a> {
    pub all: &'a [&'a str],
    pub default_rail: &'a [&'a str],
}

impl Tabs<'_> {
    pub fn default_layout(&self) -> Layout {
        Layout {
            rail: owned(self.default_rail),
            dock: owned(self.all),
        }
    }

    pub fn sanitize<T: AsRef<str>>(&self, raw: &[T]) -> Vec<String> {
        let mut out: Vec<String> = Vec::new();
        for id in raw.iter().map(AsRef::as_ref) {
            if self.all.contains(&id) && !out.iter().any(|o| o == id) {
                out.push(id.to_string());
            }
        }
        out
    }

    pub fn normalize_dock<T: AsRef<str>>(&self, raw: &[T]) -> Vec<String> {
        let mut out = self.sanitize(raw);
        for id in self.all {
            if !out.iter().any(|o| o == id) {
                out.push(id.to_string());
            }
        }
        out
    }

    pub fn normalize(&self, raw: &Value) -> Layout {
        let Some(obj) = raw.as_object() else {
            return self.default_layout();
        };
        Layout {
            rail: match obj.get("rail") {
                Some(v) => self.sanitize(&strings(v)),
                None => owned(self.default_rail),
            },
            dock: self.normalize_dock(&obj.get("dock").map(strings).unwrap_or_default()),
        }
    }

    /// A missing or corrupt file is the default layout.
    pub fn load(&self, path: &Path) -> Layout {
        let raw = std::fs::read_to_string(path)
            .ok()
            .and_then(|s| serde_json::from_str::<Value>(&s).ok())
            .unwrap_or(Value::Null);
        self.normalize(&raw)
    }
}

/// Written through a temporary file and a rename, so a crash mid-write never
/// leaves a truncated layout behind.
pub fn save(path: &Path, layout: &Layout) -> io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let text = serde_json::to_string_pretty(&json!({"rail": layout.rail, "dock": layout.dock}))?;
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(".tmp");
    let tmp = PathBuf::from(tmp);
    std::fs::write(&tmp, text)?;
    std::fs::rename(&tmp, path)
}

fn strings(v: &Value) -> Vec<String> {
    v.as_array()
        .map(|a| {
            a.iter()
                .filter_map(|x| x.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default()
}

fn owned(ids: &[&str]) -> Vec<String> {
    ids.iter().map(|s| s.to_string()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const TABS: Tabs = Tabs {
        all: &["auto", "settings", "effects", "howard", "robot3d", "visual"],
        default_rail: &["auto", "settings"],
    };

    fn ids(v: &[&str]) -> Vec<String> {
        owned(v)
    }

    #[test]
    fn normalization() {
        assert_eq!(
            TABS.normalize(&json!({"rail": ["record", "visual", "visual", "auto"], "dock": ["visual", "record", "auto"]})),
            Layout {
                rail: ids(&["visual", "auto"]),
                dock: ids(&["visual", "auto", "settings", "effects", "howard", "robot3d"]),
            },
            "record dropped, dock completed"
        );
        assert_eq!(
            TABS.normalize(&json!({"rail": [], "dock": "junk"})),
            Layout {
                rail: vec![],
                dock: ids(TABS.all)
            },
            "an empty rail is allowed"
        );
        assert_eq!(TABS.normalize(&json!("junk")), TABS.default_layout());
        assert_eq!(
            TABS.normalize(&json!({"dock": []})).rail,
            ids(&["auto", "settings"]),
            "missing rail is the default"
        );
    }

    #[test]
    fn set_lists_sanitizes() {
        let raw = json!({"rail": ["visual", "record", "visual", 3], "dock": ["howard", "record"]});
        let l = TABS.normalize(&raw);
        assert_eq!(l.rail, ids(&["visual"]));
        assert_eq!(
            l.dock,
            ids(&["howard", "auto", "settings", "effects", "robot3d", "visual"])
        );
    }

    #[test]
    fn corrupt_file_loads_defaults_and_layout_round_trips() {
        let dir = std::env::temp_dir().join(format!("dash-core-layout-{}", std::process::id()));
        let path = dir.join("layout.json");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(&path, "{not json").unwrap();
        assert_eq!(TABS.load(&path), TABS.default_layout());
        assert_eq!(TABS.load(&dir.join("missing.json")), TABS.default_layout());
        let stored = Layout {
            rail: ids(&["howard", "record"]),
            dock: ids(&["record", "visual"]),
        };
        save(&path, &stored).unwrap();
        assert_eq!(
            TABS.load(&path),
            Layout {
                rail: ids(&["howard"]),
                dock: ids(&["visual", "auto", "settings", "effects", "howard", "robot3d"]),
            }
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
