//! The exported autos (tools/pathplanner/export_autos.py). An event-update
//! export wins over the built-in one when it is valid and at least as new, so
//! autos can be refreshed at an event without rebuilding the app. Every auto
//! file is validated on load: a broken one falls back to the same auto in an
//! older export when there is one, and otherwise has no preview and an error
//! to show. Loading is eager, so a broken file is read once.

use std::borrow::Cow;
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use std::sync::Arc;

use serde_json::Value;

use super::builtin;
use super::field::Pose;
use super::freshness::{Freshness, short_time};
use crate::playback::AutoPlayback;

pub const FORMAT_VERSION: i64 = 1;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ExportSource {
    /// `apps/comp-godot/data/autos`, compiled into the binary.
    BuiltIn,
    /// An event update dropped next to the app, or a test copy.
    Dir(PathBuf),
}

impl ExportSource {
    pub fn is_builtin(&self) -> bool {
        matches!(self, ExportSource::BuiltIn)
    }

    pub fn label(&self) -> String {
        match self {
            ExportSource::BuiltIn => "built-in".into(),
            ExportSource::Dir(p) => p.display().to_string(),
        }
    }

    fn exists(&self) -> bool {
        match self {
            ExportSource::BuiltIn => true,
            ExportSource::Dir(p) => p.is_dir(),
        }
    }

    fn has_file(&self, file: &str) -> bool {
        match self {
            ExportSource::BuiltIn => builtin::export_file(file).is_some(),
            ExportSource::Dir(p) => p.join(file).is_file(),
        }
    }

    fn read(&self, file: &str) -> Option<Cow<'static, str>> {
        match self {
            ExportSource::BuiltIn => builtin::export_file(file).map(Cow::Borrowed),
            ExportSource::Dir(p) => fs::read_to_string(p.join(file)).ok().map(Cow::Owned),
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct IndexAuto {
    pub name: String,
    pub file: String,
    pub folder: String,
    pub duration_s: f64,
    pub sample_count: usize,
    pub has_path: bool,
    pub paths: Vec<String>,
    pub ends_by_itself: bool,
    pub warnings: Vec<String>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct IndexPath {
    pub name: String,
    pub duration_s: f64,
    pub python_duration_s: Option<f64>,
    pub max_velocity_mps: Option<f64>,
    pub start_pose: Option<Pose>,
    pub end_pose: Option<Pose>,
    pub used_by: Vec<String>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct ExportIndex {
    pub version: i64,
    pub exported_at: String,
    pub source_hash: String,
    pub paths_hash: String,
    pub commands_hash: String,
    pub dt: f64,
    pub auto_length_s: f64,
    pub autos: Vec<IndexAuto>,
    pub paths: Vec<IndexPath>,
    /// The whole index.json, for the fields not modeled above (parity, field, ...).
    pub raw: Value,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct AutoMeta {
    pub name: Option<String>,
    pub description: Option<String>,
}

pub type MetaMap = HashMap<String, AutoMeta>;

#[derive(Clone, Debug, Default)]
struct Outcome {
    playback: Option<Arc<AutoPlayback>>,
    why: String,
    error: String,
    note: String,
}

#[derive(Clone, Debug, Default)]
pub struct AutoLibrary {
    source: Option<ExportSource>,
    index: Option<ExportIndex>,
    pub meta: MetaMap,
    pub error: String,
    fallbacks: Vec<AutoLibrary>,
    outcomes: HashMap<String, Outcome>,
}

fn s(v: Option<&Value>) -> String {
    match v {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Null) | None => String::new(),
        Some(other) => other.to_string(),
    }
}

fn f(v: Option<&Value>) -> Option<f64> {
    v.and_then(Value::as_f64)
}

fn strings(v: Option<&Value>) -> Vec<String> {
    v.and_then(Value::as_array)
        .map(|a| a.iter().map(|x| s(Some(x))).collect())
        .unwrap_or_default()
}

fn pose(v: Option<&Value>) -> Option<Pose> {
    let a = v?.as_array()?;
    Some(Pose::new(
        a.first()?.as_f64()?,
        a.get(1)?.as_f64()?,
        a.get(2)?.as_f64()?,
    ))
}

impl ExportIndex {
    fn from_value(raw: Value) -> ExportIndex {
        let autos = raw["autos"]
            .as_array()
            .map(|a| {
                a.iter()
                    .map(|e| IndexAuto {
                        name: s(e.get("name")),
                        file: s(e.get("file")),
                        folder: s(e.get("folder")),
                        duration_s: f(e.get("duration_s")).unwrap_or(0.0),
                        sample_count: e.get("sample_count").and_then(Value::as_u64).unwrap_or(0)
                            as usize,
                        has_path: e.get("has_path").and_then(Value::as_bool).unwrap_or(false),
                        paths: strings(e.get("paths")),
                        ends_by_itself: e
                            .get("ends_by_itself")
                            .and_then(Value::as_bool)
                            .unwrap_or(false),
                        warnings: strings(e.get("warnings")),
                    })
                    .collect()
            })
            .unwrap_or_default();
        let paths = raw["paths"]
            .as_array()
            .map(|a| {
                a.iter()
                    .map(|p| IndexPath {
                        name: s(p.get("name")),
                        duration_s: f(p.get("duration_s")).unwrap_or(0.0),
                        python_duration_s: f(p.get("python_duration_s")),
                        max_velocity_mps: f(p.get("max_velocity_mps")),
                        start_pose: pose(p.get("start_pose")),
                        end_pose: pose(p.get("end_pose")),
                        used_by: strings(p.get("used_by")),
                    })
                    .collect()
            })
            .unwrap_or_default();
        ExportIndex {
            version: f(raw.get("version")).map_or(-1, |v| v as i64),
            exported_at: s(raw.get("exported_at")),
            source_hash: s(raw.get("source_hash")),
            paths_hash: s(raw.get("paths_hash")),
            commands_hash: s(raw.get("commands_hash")),
            dt: f(raw.get("dt")).unwrap_or(0.02),
            auto_length_s: f(raw.get("auto_length_s")).unwrap_or(20.0),
            autos,
            paths,
            raw,
        }
    }

    pub fn path(&self, name: &str) -> Option<&IndexPath> {
        self.paths.iter().find(|p| p.name == name)
    }
}

impl AutoLibrary {
    /// The newest valid export among `sources`; a tie goes to the earlier one.
    pub fn load_best(sources: &[ExportSource]) -> AutoLibrary {
        let mut valid: Vec<AutoLibrary> = Vec::new();
        let mut errors = Vec::new();
        for src in sources {
            match AutoLibrary::load_dir(src.clone()) {
                Ok(lib) => {
                    let at = valid
                        .iter()
                        .take_while(|v| v.exported_at() >= lib.exported_at())
                        .count();
                    valid.insert(at, lib);
                }
                Err(e) if src.exists() => errors.push(format!("{}: {e}", src.label())),
                Err(_) => {}
            }
        }
        if valid.is_empty() {
            return AutoLibrary {
                error: format!("no valid auto export ({})", errors.join(", ")),
                meta: builtin_meta(),
                ..Default::default()
            };
        }
        let mut best = valid.remove(0);
        best.fallbacks = valid;
        best.meta = builtin_meta();
        best.resolve_fallbacks();
        best
    }

    pub fn load_dir(source: ExportSource) -> Result<AutoLibrary, String> {
        let idx: Value = source
            .read("index.json")
            .and_then(|t| serde_json::from_str(&t).ok())
            .filter(Value::is_object)
            .ok_or("missing or unreadable index.json")?;
        let version = idx.get("version").cloned().unwrap_or(Value::Null);
        if version.as_f64() != Some(FORMAT_VERSION as f64) {
            return Err(format!(
                "index version {version}, expected {FORMAT_VERSION}"
            ));
        }
        let entries = idx
            .get("autos")
            .and_then(Value::as_array)
            .ok_or("index.json has no auto list")?;
        for a in entries {
            let (Some(_), Some(file)) = (
                a.get("name").and_then(Value::as_str),
                a.get("file").and_then(Value::as_str),
            ) else {
                return Err("bad auto entry in index.json".into());
            };
            if !source.has_file(file) {
                return Err(format!("missing {file}"));
            }
        }
        let index = ExportIndex::from_value(idx);
        let mut outcomes = HashMap::new();
        for e in &index.autos {
            let parsed = match source.read(&e.file) {
                None => Err("missing".to_owned()),
                Some(text) => AutoPlayback::parse(&text).map(Arc::new),
            };
            let outcome = match parsed {
                Ok(p) => Outcome {
                    playback: Some(p),
                    ..Default::default()
                },
                Err(why) => Outcome {
                    error: format!("{}: {why}", e.file),
                    why,
                    ..Default::default()
                },
            };
            outcomes.entry(e.name.clone()).or_insert(outcome);
        }
        Ok(AutoLibrary {
            source: Some(source),
            index: Some(index),
            outcomes,
            ..Default::default()
        })
    }

    fn resolve_fallbacks(&mut self) {
        let here = if self.source.as_ref().is_some_and(ExportSource::is_builtin) {
            "Built-in"
        } else {
            "Event update"
        };
        for (name, outcome) in self.outcomes.iter_mut() {
            if outcome.playback.is_some() {
                continue;
            }
            for fb in &self.fallbacks {
                let Some(p) = fb.entry(name).and_then(|_| fb.get_auto(name)) else {
                    continue;
                };
                let there = if fb.source().is_some_and(ExportSource::is_builtin) {
                    "built-in"
                } else {
                    "older"
                };
                outcome.note = format!(
                    "{here} file is broken ({}). Showing the {there} export from {}.",
                    outcome.why,
                    short_time(fb.exported_at())
                );
                outcome.error.clear();
                outcome.playback = Some(p);
                break;
            }
        }
    }

    pub fn is_loaded(&self) -> bool {
        self.index.is_some()
    }

    pub fn source(&self) -> Option<&ExportSource> {
        self.source.as_ref()
    }

    pub fn index(&self) -> Option<&ExportIndex> {
        self.index.as_ref()
    }

    pub fn fallbacks(&self) -> &[AutoLibrary] {
        &self.fallbacks
    }

    pub fn exported_at(&self) -> &str {
        self.index.as_ref().map_or("", |i| &i.exported_at)
    }

    pub fn exported_source_hash(&self) -> &str {
        self.index.as_ref().map_or("", |i| &i.source_hash)
    }

    pub fn names(&self) -> Vec<&str> {
        self.index.as_ref().map_or_else(Vec::new, |i| {
            i.autos.iter().map(|a| a.name.as_str()).collect()
        })
    }

    pub fn entry(&self, name: &str) -> Option<&IndexAuto> {
        self.index.as_ref()?.autos.iter().find(|a| a.name == name)
    }

    /// None for an unknown name or a broken file with no fallback.
    pub fn get_auto(&self, name: &str) -> Option<Arc<AutoPlayback>> {
        self.outcomes.get(name)?.playback.clone()
    }

    /// Why a listed auto has no preview; "" when it loads.
    pub fn auto_error(&self, name: &str) -> &str {
        self.outcomes.get(name).map_or("", |o| &o.error)
    }

    /// Set when a broken file was replaced by the same auto from an older export.
    pub fn auto_note(&self, name: &str) -> &str {
        self.outcomes.get(name).map_or("", |o| &o.note)
    }

    pub fn display_name<'a>(&'a self, name: &'a str) -> &'a str {
        self.meta
            .get(name)
            .and_then(|m| m.name.as_deref())
            .unwrap_or(name)
    }

    pub fn description(&self, name: &str) -> &str {
        self.meta
            .get(name)
            .and_then(|m| m.description.as_deref())
            .unwrap_or("")
    }

    pub fn merge_meta(&mut self, meta: MetaMap) {
        self.meta.extend(meta);
    }

    /// The Auto export box / Settings Autos paragraph.
    pub fn summary_text(&self, fresh: Option<&Freshness>) -> String {
        if !self.is_loaded() {
            return "No auto export loaded".into();
        }
        let origin = if self.source.as_ref().is_some_and(ExportSource::is_builtin) {
            "built-in"
        } else {
            "event update"
        };
        let extra = fresh.map_or("", |f| f.text.as_str());
        let extra = if extra.is_empty() {
            String::new()
        } else {
            format!(" · {extra}")
        };
        format!(
            "{} autos · {origin}{extra}\nexported {} UTC",
            self.names().len(),
            short_time(self.exported_at())
        )
    }
}

pub fn parse_meta(text: &str) -> MetaMap {
    let Ok(Value::Object(d)) = serde_json::from_str::<Value>(text) else {
        return MetaMap::new();
    };
    let Some(autos) = d.get("autos").and_then(Value::as_object) else {
        return MetaMap::new();
    };
    meta_from_value(autos)
}

pub fn meta_from_value(autos: &serde_json::Map<String, Value>) -> MetaMap {
    autos
        .iter()
        .filter_map(|(k, m)| {
            let m = m.as_object()?;
            let text = |key: &str| m.get(key).map(|v| s(Some(v)));
            Some((
                k.clone(),
                AutoMeta {
                    name: text("name"),
                    description: text("description"),
                },
            ))
        })
        .collect()
}

pub fn builtin_meta() -> MetaMap {
    parse_meta(builtin::BUILTIN_META)
}
