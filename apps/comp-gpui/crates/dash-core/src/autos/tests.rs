use std::f64::consts::PI;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use serde_json::{Value, json};

use super::builtin::BUILTIN_EXPORT_FILES;
use super::field::{PP_FIELD_LENGTH_M, PP_FIELD_WIDTH_M, to_world};
use super::*;
use crate::playback::angle::angle_difference;
use crate::playback::{Alliance, AutoClock, AutoMechanisms, AutoPlayback, Channel, ItemKind};

const RED: Alliance = Alliance::Red;
const BLUE: Alliance = Alliance::Blue;

fn data_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../comp-godot/data")
}

struct Scratch(PathBuf);

impl Scratch {
    fn new() -> Self {
        static N: AtomicUsize = AtomicUsize::new(0);
        let dir = std::env::temp_dir().join(format!(
            "dash-core-autos-{}-{}",
            std::process::id(),
            N.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&dir).unwrap();
        Scratch(dir)
    }

    fn join(&self, p: &str) -> PathBuf {
        self.0.join(p)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn copy_export(to: &Path, exported_at: &str) {
    fs::create_dir_all(to).unwrap();
    for (name, text) in BUILTIN_EXPORT_FILES {
        fs::write(to.join(name), text).unwrap();
    }
    edit_json(&to.join("index.json"), |idx| {
        idx["exported_at"] = json!(exported_at)
    });
}

fn edit_json(path: &Path, edit: impl FnOnce(&mut Value)) {
    let mut d: Value = serde_json::from_str(&fs::read_to_string(path).unwrap()).unwrap();
    edit(&mut d);
    fs::write(path, d.to_string()).unwrap();
}

fn edit_auto(dir: &Path, name: &str, edit: impl FnOnce(&mut Value)) {
    edit_json(&dir.join(format!("{name}.json")), edit);
}

fn builtin() -> AutoLibrary {
    AutoLibrary::load_dir(ExportSource::BuiltIn).unwrap()
}

fn auto(lib: &AutoLibrary, name: &str) -> Arc<AutoPlayback> {
    lib.get_auto(name).unwrap_or_else(|| panic!("{name} loads"))
}

fn builtin_json(name: &str) -> Value {
    serde_json::from_str(super::builtin::export_file(&format!("{name}.json")).unwrap()).unwrap()
}

fn near(a: f64, b: f64, eps: f64, what: &str) {
    assert!((a - b).abs() <= eps, "{what}: {a} vs {b}");
}

fn synthetic(n: usize, dt: f64) -> AutoPlayback {
    let mut ch = json!({"x": [], "y": [], "heading": [], "vx": [], "vy": [], "omega": []});
    for i in 0..n {
        let h = if i % 2 == 0 { 3.0 } else { -3.0 };
        for (k, v) in [
            ("x", i as f64),
            ("y", 2.0 * i as f64),
            ("heading", h),
            ("vx", 1.0),
            ("vy", 0.0),
            ("omega", 0.0),
        ] {
            ch[k].as_array_mut().unwrap().push(json!(v));
        }
    }
    let last = (n - 1) as f64;
    AutoPlayback::from_value(&json!({
        "name": "synthetic", "dt": dt, "duration_s": last * dt,
        "start_pose": {"red": [0, 0, 3.0], "blue": [0, 0, 3.0]},
        "end_pose": {"red": [last, 2.0 * last, 0], "blue": [last, 2.0 * last, 0]},
        "samples": {"red": ch.clone(), "blue": ch},
    }))
}

#[test]
fn sample_at_start_mid_and_end() {
    let a = synthetic(5, 0.5);
    assert_eq!(a.sample_count, 5);
    let s0 = a.sample(0.0, RED).unwrap();
    assert_eq!((s0.x, s0.y, s0.heading), (0.0, 0.0, 3.0));
    near(a.sample(1.0, RED).unwrap().x, 2.0, 1e-12, "grid point");
    near(
        a.sample(1.25, RED).unwrap().x,
        2.5,
        1e-12,
        "between grid points",
    );
    near(a.sample(1.25, RED).unwrap().y, 5.0, 1e-12, "y");
    let end = a.sample(2.0, RED).unwrap();
    assert_eq!((end.x, end.y), (4.0, 8.0));
}

#[test]
fn sample_clamps_outside_the_range() {
    let a = synthetic(5, 0.5);
    assert_eq!(a.sample(-3.0, RED), a.sample(0.0, RED));
    assert_eq!(a.sample(99.0, RED), a.sample(2.0, RED));
    assert_eq!(a.sample(f64::INFINITY, BLUE), a.sample(2.0, BLUE));
}

#[test]
fn heading_takes_the_short_arc_across_pi() {
    let a = synthetic(3, 0.5);
    near(
        a.sample(0.25, RED).unwrap().heading.abs(),
        PI,
        1e-9,
        "3.0 -> -3.0 passes through +-PI, not 0",
    );
    let q = a.sample(0.125, RED).unwrap().heading;
    near(
        angle_difference(q, 3.0 + (std::f64::consts::TAU - 6.0) * 0.25),
        0.0,
        1e-9,
        "quarter of the short arc",
    );
}

#[test]
fn sample_is_independent_of_call_order() {
    let lib = builtin();
    let a = auto(&lib, "Ball Shooter Left");
    let mut seed: u64 = 4765;
    let mut times = Vec::new();
    for _ in 0..400 {
        seed = seed
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        times.push(-1.0 + (seed >> 11) as f64 / (1u64 << 53) as f64 * (a.duration_s + 2.0));
    }
    let forward: Vec<_> = times.iter().map(|&t| a.sample(t, BLUE)).collect();
    for (i, &t) in times.iter().enumerate().rev() {
        assert_eq!(
            a.sample(t, BLUE),
            forward[i],
            "sample({t}) depends on call order"
        );
    }
    let fresh = builtin();
    assert_eq!(
        auto(&fresh, "Ball Shooter Left").sample(times[7], BLUE),
        forward[7],
        "fresh instance"
    );
}

#[test]
fn grid_points_return_exported_samples() {
    let lib = builtin();
    let a = auto(&lib, "Climber Right Left");
    for k in [0, 1, 100, 376, 377, a.sample_count - 1] {
        let s = a.sample(k as f64 * a.dt, RED).unwrap();
        near(
            s.x,
            a.channel(Channel::X, RED)[k],
            1e-9,
            &format!("x at {k}"),
        );
        near(
            angle_difference(s.heading, a.channel(Channel::Heading, RED)[k]),
            0.0,
            1e-9,
            &format!("heading at {k}"),
        );
    }
}

#[test]
fn events_at_and_segment_at() {
    let lib = builtin();
    let a = auto(&lib, "Climber Right Left");
    let names = |t: f64| {
        let mut out: Vec<&str> = a.events_at(t).iter().map(|e| e.name.as_str()).collect();
        out.sort();
        out
    };
    assert_eq!(
        names(1.0),
        ["ContinuousAimCommand", "ContinuousShooterCommand"]
    );
    assert!(
        names(0.0).contains(&"IntakeBottomCommand"),
        "intake bottom at 0"
    );
    let top = a
        .events
        .iter()
        .find(|e| e.name == "IntakeTopCommand")
        .unwrap();
    assert!(
        names(top.t0).contains(&"IntakeTopCommand"),
        "intake top while the wrist moves"
    );
    assert!(
        names(top.t0).contains(&"MoveClimberUp"),
        "instant no-op shows at its time"
    );
    assert_eq!(a.segment_at(1.0).unwrap().name, "Climber Right Left");
    assert_eq!(
        a.segment_at(a.duration_s - 0.5).unwrap().name,
        "Climber Right Close"
    );
}

#[test]
fn builtin_export_loads() {
    let tmp = Scratch::new();
    let lib = AutoLibrary::load_best(&[
        ExportSource::Dir(tmp.join("missing")),
        ExportSource::BuiltIn,
    ]);
    assert!(lib.is_loaded(), "{}", lib.error);
    assert_eq!(lib.source(), Some(&ExportSource::BuiltIn));
    assert_eq!(lib.names().len(), 9);
    assert!(
        Arc::ptr_eq(
            &auto(&lib, "Ball Shooter Left"),
            &auto(&lib, "Ball Shooter Left")
        ),
        "cached instance"
    );
    assert!(lib.get_auto("No Such Auto").is_none(), "unknown auto");
    for n in lib.names() {
        assert_eq!(lib.auto_error(n), "", "{n}");
        assert_eq!(lib.auto_note(n), "", "{n}");
    }
}

#[test]
fn newer_user_export_wins() {
    let tmp = Scratch::new();
    let user = tmp.join("user_new");
    copy_export(&user, "2999-01-01T00:00:00Z");
    let lib = AutoLibrary::load_best(&[ExportSource::Dir(user.clone()), ExportSource::BuiltIn]);
    assert_eq!(
        lib.source(),
        Some(&ExportSource::Dir(user)),
        "newer user export is used"
    );
    let older = tmp.join("user_old");
    copy_export(&older, "2000-01-01T00:00:00Z");
    let lib = AutoLibrary::load_best(&[ExportSource::Dir(older), ExportSource::BuiltIn]);
    assert_eq!(
        lib.source(),
        Some(&ExportSource::BuiltIn),
        "older user export is ignored"
    );
    let same = tmp.join("user_same");
    copy_export(&same, builtin().exported_at());
    let lib = AutoLibrary::load_best(&[ExportSource::Dir(same.clone()), ExportSource::BuiltIn]);
    assert_eq!(
        lib.source(),
        Some(&ExportSource::Dir(same)),
        "a tie prefers the user export"
    );
}

#[test]
fn broken_user_export_falls_back() {
    let tmp = Scratch::new();
    let broken = tmp.join("broken");
    copy_export(&broken, "2999-01-01T00:00:00Z");
    fs::remove_file(broken.join("Stay And Shoot.json")).unwrap();
    let lib = AutoLibrary::load_best(&[ExportSource::Dir(broken.clone()), ExportSource::BuiltIn]);
    assert_eq!(lib.source(), Some(&ExportSource::BuiltIn));
    assert_eq!(
        AutoLibrary::load_dir(ExportSource::Dir(broken)).unwrap_err(),
        "missing Stay And Shoot.json"
    );
    let wrong = tmp.join("wrong_version");
    copy_export(&wrong, "2999-01-01T00:00:00Z");
    edit_json(&wrong.join("index.json"), |idx| idx["version"] = json!(99));
    let lib = AutoLibrary::load_best(&[ExportSource::Dir(wrong.clone()), ExportSource::BuiltIn]);
    assert_eq!(lib.source(), Some(&ExportSource::BuiltIn));
    assert_eq!(
        AutoLibrary::load_dir(ExportSource::Dir(wrong)).unwrap_err(),
        "index version 99, expected 1"
    );
    let none = AutoLibrary::load_best(&[ExportSource::Dir(tmp.join("nothing"))]);
    assert!(!none.is_loaded(), "no export");
    assert_eq!(none.error, "no valid auto export ()");
    let empty = tmp.join("empty");
    fs::create_dir_all(&empty).unwrap();
    let none = AutoLibrary::load_best(&[ExportSource::Dir(empty.clone())]);
    assert_eq!(
        none.error,
        format!(
            "no valid auto export ({}: missing or unreadable index.json)",
            empty.display()
        )
    );
    assert_eq!(none.summary_text(None), "No auto export loaded");
}

#[test]
fn broken_auto_falls_back_to_the_older_export_once() {
    let tmp = Scratch::new();
    let user = tmp.join("truncated");
    copy_export(&user, "2999-01-01T00:00:00Z");
    let path = user.join("Ball Shooter Left.json");
    let text = fs::read_to_string(&path).unwrap();
    fs::write(&path, &text[..text.len() / 2]).unwrap();
    edit_auto(&user, "Move Forward And Shoot Left", |d| {
        d["samples"]["blue"]
            .as_object_mut()
            .unwrap()
            .remove("omega");
    });
    let lib = AutoLibrary::load_best(&[ExportSource::Dir(user.clone()), ExportSource::BuiltIn]);
    assert_eq!(
        lib.source(),
        Some(&ExportSource::Dir(user)),
        "the rest of the newer export is still used"
    );
    assert_eq!(lib.fallbacks().len(), 1);
    for n in ["Ball Shooter Left", "Move Forward And Shoot Left"] {
        assert!(
            lib.get_auto(n).is_some_and(|p| p.has_path()),
            "{n} comes from the built-in export"
        );
        assert_eq!(lib.auto_error(n), "", "{n}");
        assert!(
            lib.auto_note(n).starts_with("Event update file is broken"),
            "{}",
            lib.auto_note(n)
        );
        assert!(
            lib.auto_note(n).contains("built-in"),
            "{}",
            lib.auto_note(n)
        );
    }
    assert!(
        lib.auto_note("Ball Shooter Left")
            .contains("not valid JSON"),
        "{}",
        lib.auto_note("Ball Shooter Left")
    );
    assert_eq!(
        lib.auto_note("Move Forward And Shoot Left"),
        "Event update file is broken (missing blue samples: omega). Showing the built-in export from 2026-11-14 12:28."
    );
    assert_eq!(lib.auto_note("Ball Shooter Right"), "");
    let first = auto(&lib, "Ball Shooter Left");
    fs::remove_file(&path).unwrap();
    assert!(
        Arc::ptr_eq(&auto(&lib, "Ball Shooter Left"), &first),
        "the outcome is kept, the file is not read again"
    );
    assert_eq!(
        lib.summary_text(None),
        "9 autos · event update\nexported 2999-01-01 00:00 UTC"
    );
}

#[test]
fn broken_auto_without_fallback_reports_an_error() {
    let tmp = Scratch::new();
    let user = tmp.join("new_only");
    copy_export(&user, "2999-01-01T00:00:00Z");
    edit_auto(&user, "Climber Right Left", |d| {
        d["samples"]["red"]["omega"]
            .as_array_mut()
            .unwrap()
            .truncate(10);
    });
    edit_auto(&user, "Climber Right Middle", |d| {
        d["samples"]["red"]["y"][3] = json!("x")
    });
    let lib = AutoLibrary::load_best(&[ExportSource::Dir(user)]);
    assert!(lib.get_auto("Climber Right Left").is_none(), "no preview");
    assert!(
        lib.auto_error("Climber Right Left")
            .contains("red omega has 10 samples"),
        "{}",
        lib.auto_error("Climber Right Left")
    );
    assert!(
        lib.auto_error("Climber Right Left")
            .starts_with("Climber Right Left.json: ")
    );
    assert!(
        lib.auto_error("Climber Right Middle")
            .contains("non-numeric red y"),
        "{}",
        lib.auto_error("Climber Right Middle")
    );
    assert!(
        lib.get_auto("Stay And Shoot").is_some(),
        "other autos still load"
    );
}

#[test]
fn validate_rejects_what_from_value_cannot_play() {
    let good = builtin_json("Move Forward And Shoot Left");
    assert_eq!(AutoPlayback::validate(&good), "");
    assert_eq!(
        AutoPlayback::validate(&builtin_json("Stay And Shoot")),
        "",
        "no path is fine"
    );
    assert_eq!(AutoPlayback::validate(&json!([])), "not a JSON object");
    type Edit = fn(&mut Value);
    let cases: [(&str, Edit); 7] = [
        ("bad dt", |d| d["dt"] = json!(0)),
        ("bad duration_s", |d| {
            d.as_object_mut().unwrap().remove("duration_s");
        }),
        ("bad event", |d| {
            d["events"][0].as_object_mut().unwrap().remove("t1");
        }),
        ("no blue samples", |d| d["samples"]["blue"] = Value::Null),
        ("missing red samples: heading", |d| {
            d["samples"]["red"]
                .as_object_mut()
                .unwrap()
                .remove("heading");
        }),
        ("bad start_pose", |d| {
            d["start_pose"]["blue"] = json!([1, 2])
        }),
        ("bad warning", |d| d["warnings"] = json!([{"name": "x"}])),
    ];
    for (want, edit) in cases {
        let mut d = good.clone();
        edit(&mut d);
        assert_eq!(AutoPlayback::validate(&d), want);
    }
    assert_eq!(
        AutoPlayback::parse("{").unwrap_err(),
        "not valid JSON, line 1"
    );
}

#[test]
fn meta_covers_every_auto() {
    let lib = AutoLibrary::load_best(&[ExportSource::BuiltIn]);
    for n in lib.names() {
        assert!(lib.meta.contains_key(n), "meta for {n}");
        assert_ne!(lib.description(n), "", "description for {n}");
    }
    assert_eq!(
        lib.display_name("Climber Right Left"),
        "Climber Left to Right"
    );
    assert_eq!(lib.display_name("Unknown"), "Unknown");
}

#[test]
fn builtin_export_hash_matches_its_raw_files() {
    let lib = AutoLibrary::load_best(&[ExportSource::BuiltIn]);
    let raw = data_dir().join("pathplanner");
    assert_eq!(lib.exported_source_hash(), source_hash(&raw));
    let idx = lib.index().unwrap();
    assert_eq!(
        source_hash(&raw.join("paths")),
        idx.paths_hash,
        "paths hash"
    );
    let commands = fs::read(data_dir().join("auto_commands.json")).unwrap();
    assert_eq!(
        sha256_hex(&commands),
        idx.commands_hash,
        "data/auto_commands.json changed without a re-export"
    );
}

fn copy_tree(from: &Path, to: &Path) {
    fs::create_dir_all(to).unwrap();
    for e in fs::read_dir(from).unwrap().flatten() {
        if e.file_type().unwrap().is_dir() {
            copy_tree(&e.path(), &to.join(e.file_name()));
        } else {
            fs::copy(e.path(), to.join(e.file_name())).unwrap();
        }
    }
}

#[test]
fn source_hash_sees_every_raw_change() {
    let tmp = Scratch::new();
    let raw = data_dir().join("pathplanner");
    let copy = tmp.join("pp");
    copy_tree(&raw, &copy);
    let base = source_hash(&copy);
    assert_eq!(base, source_hash(&raw), "a copy hashes the same");
    fs::write(copy.join(".DS_Store"), "x").unwrap();
    assert_eq!(source_hash(&copy), base, "dotfiles are ignored");
    let path_file = copy.join("paths/Move Forward Center.path");
    let text = fs::read_to_string(&path_file).unwrap();
    assert!(text.contains("\"maxVelocity\": 1.0"));
    fs::write(
        &path_file,
        text.replace("\"maxVelocity\": 1.0", "\"maxVelocity\": 1.1"),
    )
    .unwrap();
    let edited = source_hash(&copy);
    assert_ne!(edited, base, "an edited .path changes the hash");
    fs::write(copy.join("autos/New.auto"), "{}").unwrap();
    assert_ne!(
        source_hash(&copy),
        edited,
        "an added .auto changes the hash"
    );
    fs::remove_file(copy.join("autos/New.auto")).unwrap();
    assert_eq!(source_hash(&copy), edited);
    fs::rename(copy.join("settings.json"), copy.join("settings2.json")).unwrap();
    assert_ne!(
        source_hash(&copy),
        edited,
        "a renamed file changes the hash"
    );
}

#[test]
fn nine_autos_and_twelve_paths() {
    let lib = builtin();
    let python_durations = [
        ("Ball Shooter Left", 15.95),
        ("Ball Shooter Right", 15.95),
        ("Climber Left Close", 5.63),
        ("Climber Left", 3.01),
        ("Climber Middle", 1.48),
        ("Climber Right Close", 3.33),
        ("Climber Right Left", 7.53),
        ("Climber Right Middle", 7.14),
        ("Climber Right Right", 7.95),
        ("Move Forward Center", 2.46),
        ("Move Forward Left", 2.94),
        ("Move Forward Right", 2.56),
    ];
    let names = lib.names();
    assert_eq!(names.len(), 9);
    for n in [
        "Ball Shooter Left",
        "Ball Shooter Right",
        "Climber Right Left",
        "Climber Right Middle",
        "Climber Right Right",
        "Move Forward And Shoot Center",
        "Move Forward And Shoot Left",
        "Move Forward And Shoot Right",
        "Stay And Shoot",
    ] {
        assert!(names.contains(&n), "auto {n}");
        assert!(lib.get_auto(n).is_some(), "auto file loads: {n}");
    }
    let idx = lib.index().unwrap();
    assert_eq!(idx.paths.len(), 12);
    for p in &idx.paths {
        let want = python_durations
            .iter()
            .find(|(n, _)| *n == p.name)
            .unwrap_or_else(|| panic!("known path {}", p.name))
            .1;
        near(
            p.python_duration_s.unwrap(),
            want,
            0.02,
            &format!("{} python duration", p.name),
        );
    }
    assert_eq!(idx.dt, 0.02);
    assert_eq!(
        idx.raw["field"]["length_m"].as_f64(),
        Some(PP_FIELD_LENGTH_M)
    );
    assert_eq!(idx.raw["field"]["width_m"].as_f64(), Some(PP_FIELD_WIDTH_M));
}

#[test]
fn samples_grid_endpoints_flip_and_speed() {
    let lib = builtin();
    let idx = lib.index().unwrap();
    for n in lib.names() {
        let a = auto(&lib, n);
        if !a.has_path() {
            continue;
        }
        assert_eq!(
            a.sample_count,
            (a.duration_s / a.dt + 1e-9).floor() as usize + 1,
            "{n} sample count"
        );
        assert_eq!(
            a.sample_count,
            lib.entry(n).unwrap().sample_count,
            "{n} index sample count"
        );
        for side in Alliance::BOTH {
            let (p0, p1) = (a.sample_at(0, side), a.sample_at(a.sample_count - 1, side));
            assert!(
                p0.point().distance_to(a.start_pose(side).unwrap().point()) <= 0.001,
                "{n} {side:?} first sample"
            );
            assert!(
                p1.point().distance_to(a.end_pose(side).unwrap().point()) <= 0.001,
                "{n} {side:?} last sample"
            );
        }
        let sp = idx.path(&a.paths[0]).unwrap().start_pose.unwrap();
        let ep = idx.path(a.paths.last().unwrap()).unwrap().end_pose.unwrap();
        assert!(
            a.sample_at(0, RED).point().distance_to(sp.point()) <= 0.001,
            "{n} starts at the first path's start"
        );
        assert!(
            a.sample_at(a.sample_count - 1, RED)
                .point()
                .distance_to(ep.point())
                <= 0.001,
            "{n} ends at the last path's end"
        );
        let ch = |c, s| a.channel(c, s);
        let mut worst: f64 = 0.0;
        for i in 0..a.sample_count {
            let (rx, ry, rh) = (
                ch(Channel::X, RED)[i],
                ch(Channel::Y, RED)[i],
                ch(Channel::Heading, RED)[i],
            );
            worst = worst.max((ch(Channel::X, BLUE)[i] - (PP_FIELD_LENGTH_M - rx)).abs());
            worst = worst.max((ch(Channel::Y, BLUE)[i] - (PP_FIELD_WIDTH_M - ry)).abs());
            worst = worst.max(angle_difference(ch(Channel::Heading, BLUE)[i], rh + PI).abs());
            worst = worst.max((ch(Channel::Vx, BLUE)[i] + ch(Channel::Vx, RED)[i]).abs());
            worst = worst.max((ch(Channel::Vy, BLUE)[i] + ch(Channel::Vy, RED)[i]).abs());
        }
        assert!(
            worst <= 1e-6,
            "{n} blue is the rotational flip of red (worst {worst})"
        );
        for seg in a.segments.iter().filter(|s| s.is_path()) {
            let vmax = seg.max_velocity_mps.unwrap() * 1.01;
            let lo = (seg.t0 / a.dt - 1e-9).ceil() as usize;
            let hi = (a.sample_count - 1).min((seg.t1 / a.dt + 1e-9).floor() as usize);
            for i in lo..=hi {
                let v = ch(Channel::Vx, RED)[i].hypot(ch(Channel::Vy, RED)[i]);
                assert!(
                    v <= vmax,
                    "{n}: {v:.3} m/s at {:.2} s over {}'s max {vmax}",
                    i as f64 * a.dt,
                    seg.name
                );
            }
        }
    }
}

#[test]
fn climber_right_left_timeline() {
    let lib = builtin();
    let idx = lib.index().unwrap();
    let wrist = AutoCommands::builtin().wrist_command_s();
    let a = auto(&lib, "Climber Right Left");
    let p1 = idx.path("Climber Right Left").unwrap().duration_s;
    let p2 = idx.path("Climber Right Close").unwrap().duration_s;
    let ev = |name: &str| a.events.iter().find(|e| e.name == name).unwrap().clone();
    near(p1, 7.53, 0.02, "first path");
    assert_eq!(a.segments[0].name, "Climber Right Left");
    near(
        a.segments[0].t1,
        p1,
        1e-6,
        "deadline group ends with its path",
    );
    for n in ["ContinuousAimCommand", "ContinuousShooterCommand"] {
        near(ev(n).t1, p1, 1e-6, n);
        assert_eq!(ev(n).end_reason, "deadline");
    }
    let bottom = ev("IntakeBottomCommand");
    near(
        bottom.t1 - bottom.t0,
        wrist,
        1e-6,
        "IntakeBottomCommand ends at the wrist setpoint",
    );
    let top = ev("IntakeTopCommand");
    near(
        top.t0,
        p1,
        1e-6,
        "IntakeTopCommand starts after the deadline group",
    );
    near(
        top.t1 - top.t0,
        wrist,
        1e-6,
        "IntakeTopCommand runs the modeled wrist travel",
    );
    assert_eq!(a.segments[1].kind, "hold");
    assert_eq!(a.segments[2].name, "Climber Right Close");
    near(
        a.segments[2].t0,
        p1 + wrist,
        1e-6,
        "second path starts after the wrist",
    );
    near(
        a.nominal_duration_s,
        p1 + wrist + p2,
        1e-6,
        "nominal duration",
    );
    near(
        a.duration_s,
        ((p1 + wrist + p2) / 0.02 - 1e-9).ceil() * 0.02,
        1e-6,
        "grid duration",
    );
    assert!(a.ends_by_itself, "climber auto ends by itself");
    let down = ev("MoveClimberDown");
    near(
        down.t0,
        p1 + wrist + p2,
        1e-6,
        "MoveClimberDown after the second path",
    );
    assert_eq!(down.kind, "noop");
}

#[test]
fn move_forward_and_shoot_runs_to_auto_end() {
    let lib = builtin();
    let idx = lib.index().unwrap();
    let wrist = AutoCommands::builtin().wrist_command_s();
    for side in ["Center", "Left", "Right"] {
        let a = auto(&lib, &format!("Move Forward And Shoot {side}"));
        let path_end = idx
            .path(&format!("Move Forward {side}"))
            .unwrap()
            .duration_s;
        assert!(!a.ends_by_itself, "{side} never ends by itself");
        let ev = |name: &str| a.events.iter().find(|e| e.name == name).unwrap().clone();
        for n in ["ContinuousAimCommand", "ContinuousShooterCommand"] {
            near(
                ev(n).t0,
                path_end,
                1e-6,
                &format!("{side} {n} starts after the path"),
            );
            assert_eq!(ev(n).t1, 20.0, "{side} {n} active until 20 s");
            assert_eq!(ev(n).end_reason, "auto_end");
        }
        let mid = ev("IntakeMiddleCommand");
        near(mid.t0, path_end, 1e-6, "IntakeMiddleCommand start");
        near(mid.t1 - mid.t0, wrist, 1e-6, "IntakeMiddleCommand length");
        assert!(a.warnings.is_empty(), "{side} has no warnings");
    }
}

#[test]
fn stay_and_shoot_has_no_path() {
    let lib = builtin();
    let a = auto(&lib, "Stay And Shoot");
    assert!(!a.has_path());
    assert!(!lib.entry("Stay And Shoot").unwrap().has_path);
    assert!(a.start_pose(RED).is_none());
    assert!(a.sample(1.0, RED).is_none());
    assert_eq!(a.events.len(), 3);
    for ev in &a.events {
        assert_eq!(
            (ev.t0, ev.t1, ev.end_reason.as_str()),
            (0.0, 20.0, "auto_end"),
            "{}",
            ev.name
        );
    }
}

#[test]
fn ball_shooter_intake_zone() {
    let lib = builtin();
    for side in ["Left", "Right"] {
        let a = auto(&lib, &format!("Ball Shooter {side}"));
        let zones: Vec<_> = a
            .events
            .iter()
            .filter(|e| e.name == "IntakeCommand")
            .collect();
        assert_eq!(zones.len(), 1, "{side} zone count");
        let z = zones[0];
        assert_eq!(z.kind, "zone_marker");
        assert_eq!(z.source, format!("path:Ball Shooter {side}"));
        assert!(0.0 < z.t0 && z.t0 < z.t1 && z.t1 < a.duration_s);
        assert!(
            !z.trigger_bound,
            "the robot binds no EventTrigger for the zone"
        );
        assert!(
            a.warning_codes().contains(&"unbound_marker"),
            "{side} warns that the zone runs nothing"
        );
    }
}

#[test]
fn unregistered_climber_commands_warn_only_on_climber_autos() {
    let lib = builtin();
    let expected: &[(&str, &[&str])] = &[
        ("Climber Right Left", &["MoveClimberDown", "MoveClimberUp"]),
        ("Climber Right Right", &["MoveClimberDown", "MoveClimberUp"]),
        ("Climber Right Middle", &["ClimberL1Command"]),
    ];
    let unregistered = ["MoveClimberUp", "MoveClimberDown", "ClimberL1Command"];
    for n in lib.names() {
        let a = auto(&lib, n);
        let mut names: Vec<&str> = a
            .warnings
            .iter()
            .filter(|w| w.code == "unregistered_command")
            .map(|w| w.name.as_str())
            .collect();
        names.sort();
        let want = expected
            .iter()
            .find(|(k, _)| *k == n)
            .map_or(&[][..], |(_, v)| *v);
        assert_eq!(names, want, "{n} unregistered warnings");
        for ev in &a.events {
            assert_eq!(
                ev.registered,
                !unregistered.contains(&ev.name.as_str()),
                "{n} {} registered flag",
                ev.name
            );
        }
        assert_eq!(
            lib.entry(n)
                .unwrap()
                .warnings
                .iter()
                .any(|w| w == "unregistered_command"),
            !want.is_empty(),
            "{n} index warnings"
        );
    }
}

#[test]
fn events_stay_inside_the_auto() {
    let lib = builtin();
    for n in lib.names() {
        let a = auto(&lib, n);
        for ev in &a.events {
            assert!(
                0.0 <= ev.t0 && ev.t0 <= ev.t1 && ev.t1 <= a.auto_length_s,
                "{n} {} interval",
                ev.name
            );
            if ev.end_reason != "auto_end" {
                assert!(
                    ev.t1 <= a.duration_s + 1e-6,
                    "{n} {} ends inside the timeline",
                    ev.name
                );
            }
        }
        if a.has_path() {
            assert_eq!(a.segments[0].t0, 0.0);
            near(
                a.segments.last().unwrap().t1,
                a.duration_s,
                1e-6,
                &format!("{n} segments cover the timeline"),
            );
        }
    }
}

fn mech(lib: &AutoLibrary, name: &str) -> AutoMechanisms {
    AutoMechanisms::new(auto(lib, name), &AutoCommands::builtin())
}

fn cmd(name: &str, t0: f64, t1: f64) -> Value {
    json!({"name": name, "kind": "command", "t0": t0, "t1": t1, "registered": true})
}

fn synthetic_mech(events: Vec<Value>) -> AutoMechanisms {
    let p = AutoPlayback::from_value(&json!({"name": "synthetic", "dt": 0.02, "duration_s": 0.0,
        "nominal_duration_s": 10.0, "ends_by_itself": true, "events": events}));
    AutoMechanisms::new(Arc::new(p), &AutoCommands::builtin())
}

#[test]
fn timeline_covers_the_auto_period_unless_the_auto_ends() {
    let lib = builtin();
    near(
        auto(&lib, "Ball Shooter Left").timeline_s(),
        20.0,
        1e-9,
        "never-ending commands run to 20 s",
    );
    near(
        auto(&lib, "Stay And Shoot").timeline_s(),
        20.0,
        1e-9,
        "no path",
    );
    near(
        auto(&lib, "Climber Right Left").timeline_s(),
        10.9,
        1e-9,
        "ends by itself",
    );
}

#[test]
fn wrist_moves_at_intake_command_boundaries() {
    let m = synthetic_mech(vec![
        cmd("IntakeBottomCommand", 2.0, 5.0),
        cmd("IntakeTopCommand", 7.0, 7.02),
    ]);
    let stowed = m.wrist_default;
    near(stowed, 0.338, 1e-9, "default command holds MIDDLE");
    near(m.wrist_raw(1.99), stowed, 1e-12, "before the first command");
    near(m.wrist_raw(2.0), stowed, 1e-12, "starts from where it was");
    assert!(
        m.wrist_raw(2.2) < stowed - 0.05,
        "moving down right after the boundary"
    );
    near(
        m.wrist_raw(2.6),
        0.0,
        1e-12,
        "at BOTTOM after the travel time",
    );
    assert!(m.rollers_on(3.0), "IntakeBottomCommand runs the rollers");
    near(
        m.wrist_target_raw(5.0),
        stowed,
        1e-12,
        "default takes over at the end",
    );
    assert!(
        m.wrist_raw(5.2) > 0.05,
        "moving back up after the end boundary"
    );
    assert!(!m.rollers_on(5.2));
    near(m.wrist_raw(6.0), stowed, 1e-12, "stowed again");
}

#[test]
fn stay_and_shoot_lowers_the_wrist_and_runs_everything() {
    let lib = builtin();
    let m = mech(&lib, "Stay And Shoot");
    assert!(!m.playback.has_path());
    near(
        m.wrist_raw(0.0),
        m.wrist_default,
        1e-12,
        "stowed at the start",
    );
    near(
        m.wrist_raw(0.6),
        0.0,
        1e-12,
        "IntakeCommand drops the wrist to BOTTOM",
    );
    let s = m.state_at(10.0, BLUE, true);
    assert!(
        s.aim && s.shooter && s.rollers,
        "aim, shooter and rollers on mid-auto"
    );
    assert_eq!(m.pose_at(0.0, BLUE), m.pose_at(19.0, BLUE), "stationary");
    assert_eq!(
        m.pose_at(5.0, RED),
        AutoMechanisms::NO_PATH_POSE_BLUE.flipped()
    );
    assert_eq!(
        m.items.iter().filter(|it| !it.instant).count(),
        3,
        "its command spans still reach the bar"
    );
}

#[test]
fn unregistered_climber_commands_are_noops() {
    let lib = builtin();
    let m = mech(&lib, "Climber Right Left");
    let noops: Vec<_> = m
        .items
        .iter()
        .filter(|it| it.kind == ItemKind::Noop)
        .collect();
    assert_eq!(
        noops.iter().map(|it| it.name.as_str()).collect::<Vec<_>>(),
        ["MoveClimberUp", "MoveClimberDown"]
    );
    for it in &noops {
        assert!(!it.runs && it.instant, "{} is an instant no-op", it.name);
        assert_eq!(it.note, "no-op on robot");
    }
    for t in [0.0, 7.5, 7.54, 9.0, 10.886, 10.9] {
        assert_eq!(
            m.state_at(t, RED, true).raw.climber,
            AutoMechanisms::CLIMBER_STOWED_RAW,
            "climber still at {t}"
        );
    }
}

#[test]
fn unbound_marker_moves_nothing() {
    let lib = builtin();
    let m = mech(&lib, "Ball Shooter Left");
    let zone: Vec<_> = m
        .items
        .iter()
        .filter(|it| it.name == "IntakeCommand")
        .collect();
    assert_eq!(zone.len(), 1);
    assert!(
        !zone[0].runs,
        "the IntakeCommand zone has no command and no bound trigger"
    );
    assert_eq!(zone[0].note, "marker only, nothing bound on robot");
    near(m.wrist_raw(10.0), m.wrist_default, 1e-12, "wrist stowed");
    assert!(!m.rollers_on(10.0));
}

#[test]
fn turret_points_at_the_alliance_hub_while_aiming() {
    let lib = builtin();
    let mut checked = 0;
    for name in [
        "Ball Shooter Left",
        "Climber Right Left",
        "Move Forward And Shoot Center",
    ] {
        let m = mech(&lib, name);
        for side in Alliance::BOTH {
            let red = side.is_red();
            for i in 0..400 {
                let t = m.duration * i as f64 / 399.0;
                if !m.aim_command_on(t) {
                    continue;
                }
                let s = m.state_at(t, side, true);
                let p = s.pose;
                let world = p.heading + s.turret_rad;
                let front = aim_point::zone(p.point(), red) == aim_point::AimZone::FrontOfHub;
                let aim_at = if front {
                    aim_point::hub(red)
                } else {
                    aim_point::target(p.point(), red)
                };
                let bearing = p.point().angle_to(aim_at);
                let off = angle_difference(world, bearing).to_degrees();
                assert!(
                    off.abs() <= 2.0,
                    "{name} {side:?} t={t:.2} off by {off:.2} deg"
                );
                near(
                    s.raw.turret * std::f64::consts::TAU,
                    s.turret_rad,
                    1e-12,
                    "raw turret is rotations",
                );
                if front {
                    checked += 1;
                }
            }
        }
    }
    assert!(checked > 500, "hub checks: {checked}");
}

#[test]
fn turret_eases_in_and_out_of_an_aim_command_without_gps_assist() {
    let m = synthetic_mech(vec![cmd("ContinuousAimCommand", 2.0, 4.0)]);
    let full = m.aim_angle(3.0, BLUE);
    assert_eq!(m.turret_angle(1.0, BLUE, false), 0.0);
    assert_eq!(m.turret_angle(2.0, BLUE, false), 0.0);
    near(m.turret_angle(3.0, BLUE, false), full, 1e-12, "fully aimed");
    near(
        m.turret_angle(4.0 + AutoMechanisms::AIM_BLEND_S, BLUE, false),
        0.0,
        1e-12,
        "back to center",
    );
    near(
        m.turret_angle(1.0, BLUE, true),
        full,
        1e-12,
        "GPS assist aims from the start",
    );
    let s = m.state_at(3.0, BLUE, false);
    assert_eq!(s.aim_source, crate::playback::AimSource::Command);
    assert_eq!(
        m.state_at(1.0, BLUE, true).aim_source,
        crate::playback::AimSource::Default
    );
    assert_eq!(
        m.state_at(1.0, BLUE, false).aim_source,
        crate::playback::AimSource::None
    );
    assert_eq!(m.items_started(1.0, 2.0).len(), 1);
    assert_eq!(m.items_started(2.0, 3.0).len(), 0);
}

#[test]
fn ribbon_starts_at_the_field_frame_of_the_start_pose() {
    let lib = builtin();
    for name in [
        "Ball Shooter Left",
        "Climber Right Left",
        "Move Forward And Shoot Right",
    ] {
        let p = auto(&lib, name);
        for side in Alliance::BOTH {
            let line = ribbon::centerline(&p, side, ribbon::LIFT);
            let lift = |mut w: WorldPoint| {
                w.y += ribbon::LIFT;
                w
            };
            let sp = p.start_pose(side).unwrap();
            let want = lift(to_world(sp.x, sp.y));
            assert!(
                line.points[0].distance_to(want) < 1e-6,
                "{name} {side:?} first point"
            );
            let ep = p.end_pose(side).unwrap();
            assert!(
                line.points
                    .last()
                    .unwrap()
                    .distance_to(lift(to_world(ep.x, ep.y)))
                    < 1e-3,
                "last point at the end pose"
            );
            assert!(line.times.windows(2).all(|w| w[1] > w[0]), "times increase");
            let strip = ribbon::strip(&line, ribbon::WIDTH).unwrap();
            let (v0, v1) = (strip.vertices[0], strip.vertices[1]);
            let mid = WorldPoint {
                x: (v0.x + v1.x) / 2.0,
                y: (v0.y + v1.y) / 2.0,
                z: (v0.z + v1.z) / 2.0,
            };
            assert!(
                mid.distance_to(want) < 1e-6,
                "strip centered on the first point"
            );
            near(v0.distance_to(v1), ribbon::WIDTH, 1e-9, "strip width");
            assert_eq!(strip.indices.len(), (line.points.len() - 1) * 6);
        }
    }
    let red = ribbon::centerline(&auto(&lib, "Ball Shooter Left"), RED, ribbon::LIFT);
    assert!(
        red.points[0].x < 0.0,
        "red-authored path starts on the red half (world -X)"
    );
}

struct Harness {
    model: AutosModel,
    now_us: i64,
}

impl Harness {
    fn new() -> Self {
        Harness {
            model: AutosModel::new(vec![ExportSource::BuiltIn]),
            now_us: 1_000_000,
        }
    }

    fn advance_us(&mut self, us: i64) {
        self.now_us += us;
    }

    fn advance_s(&mut self, s: f64) {
        self.advance_us((s * 1_000_000.0).round() as i64);
    }

    fn step(&mut self) {
        self.model.step(self.now_us);
    }
}

#[test]
fn service_preview_drives_the_shared_clock() {
    let mut h = Harness::new();
    h.model.clock.tick(0);
    assert_eq!(h.model.library.names().len(), 9);
    h.model.set_preview("Move Forward And Shoot Center");
    near(
        h.model.clock.duration,
        h.model.preview().unwrap().timeline_s(),
        1e-12,
        "duration",
    );
    h.model.clock.play();
    h.step();
    h.advance_s(0.5);
    h.step();
    near(h.model.clock.t, 0.5, 1e-9, "t");
    h.model.set_preview("Stay And Shoot");
    assert_eq!(h.model.clock.duration, 20.0);
    assert_eq!(h.model.clock.t, 0.0);
    assert!(!h.model.clock.playing, "a new preview pauses");
}

#[test]
fn jumping_and_playing_to_t_agree() {
    let mut seed: u64 = 71065;
    let mut rand = move |lo: f64, hi: f64| {
        seed = seed
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        lo + (seed >> 11) as f64 / (1u64 << 53) as f64 * (hi - lo)
    };
    let lib = builtin();
    for name in [
        "Ball Shooter Left",
        "Climber Right Left",
        "Move Forward And Shoot Center",
    ] {
        let d = auto(&lib, name).timeline_s();
        let mut times: Vec<f64> = (0..50).map(|_| rand(0.0, d)).collect();
        times.sort_by(f64::total_cmp);
        let mut player = Harness::new();
        player.model.set_preview(name);
        player.model.clock.play();
        let mut played = Vec::new();
        for target in times {
            while player.model.clock.t < target && player.model.clock.playing {
                let step = rand(0.004, 0.05)
                    .min((target - player.model.clock.t) / player.model.clock.speed);
                player.advance_us(((step * 1_000_000.0).ceil() as i64).max(1));
                player.step();
            }
            played.push((player.model.clock.t, player.model.frame().unwrap().clone()));
        }
        let mut jumper = Harness::new();
        jumper.model.set_preview(name);
        for (t, a) in played.iter().rev() {
            jumper.model.clock.seek(*t);
            jumper.step();
            let b = jumper.model.frame().unwrap();
            assert_eq!(b.state.pose, a.state.pose, "{name} pose at {t:.3}");
            assert_eq!(b.state.raw, a.state.raw, "{name} joints at {t:.3}");
            assert_eq!(
                (b.state.aim, b.state.shooter, b.state.rollers),
                (a.state.aim, a.state.shooter, a.state.rollers)
            );
        }
        let mut distinct: Vec<f64> = played.iter().map(|(t, _)| *t).collect();
        distinct.dedup();
        assert_eq!(distinct.len(), 50, "{name} distinct sample times");
    }
}

#[test]
fn playback_time_scales_with_the_wall_clock() {
    let mut h = Harness::new();
    h.model.set_preview("Climber Right Middle");
    near(h.model.clock.duration, 7.16, 1e-9, "duration");
    for speed in AutoClock::SPEEDS {
        h.model.clock.seek(0.0);
        h.model.clock.set_speed(speed);
        h.model.clock.play();
        h.step();
        h.advance_s(1.5);
        h.step();
        near(
            h.model.clock.t,
            1.5 * speed,
            1e-9,
            &format!("speed {speed}"),
        );
        let mut wall = 0.0;
        while h.model.clock.playing {
            h.advance_s(0.01);
            wall += 0.01;
            h.step();
        }
        near(
            1.5 + wall,
            7.16 / speed,
            0.011,
            &format!("full duration at {speed}x"),
        );
        near(h.model.clock.t, 7.16, 1e-9, "stops at the end");
        near(
            h.model.clock.last_run.unwrap().wall_s,
            1.5 + wall,
            1e-6,
            "run recorded",
        );
    }
    h.model.clock.set_speed(1.0);
    h.model.clock.set_loop(true);
    h.model.clock.seek(7.0);
    h.model.clock.play();
    h.step();
    h.advance_s(0.5);
    h.step();
    assert!(h.model.clock.playing, "loop keeps playing");
    near(h.model.clock.t, 0.34, 1e-6, "wraps");
    h.model.clock.begin_scrub();
    h.model.clock.seek(3.0);
    h.advance_s(1.0);
    h.step();
    near(h.model.clock.t, 3.0, 1e-12, "a scrub holds t");
    h.model.clock.end_scrub();
    h.advance_s(0.25);
    h.step();
    near(h.model.clock.t, 3.25, 1e-9, "and play resumes after it");
}

#[test]
fn hud_state() {
    let pick = HudAuto::pick;
    let owned = |a: &str, m: bool| (a.to_owned(), m);
    assert_eq!(
        pick(true, "Ball Shooter Left", "", false),
        owned("Ball Shooter Left", false)
    );
    assert_eq!(
        pick(true, "Ball Shooter Left", "Stay And Shoot", true),
        owned("Stay And Shoot", true)
    );
    assert_eq!(
        pick(true, "Ball Shooter Left", "Stay And Shoot", false),
        owned("Ball Shooter Left", false)
    );
    assert_eq!(pick(true, "", "", false), owned("", false));
    assert_eq!(
        pick(false, "Ball Shooter Left", "Stay And Shoot", true),
        owned("", false),
        "gone outside pre-match"
    );
}

#[test]
fn hud_start_check_and_alliance_follow_the_inputs() {
    let mut h = Harness::new();
    h.model.inputs.confirmed_auto = "Ball Shooter Left".into();
    h.model.refresh();
    assert_eq!(h.model.hud().auto, "Ball Shooter Left");
    assert!(h.model.hud().start.is_none(), "no live pose, no check");
    assert!(h.model.hud().red, "manual alliance defaults to red");
    let start = h
        .model
        .mechanisms("Ball Shooter Left")
        .unwrap()
        .pose_at(0.0, RED);
    h.model.inputs.robot_pose = Some(LivePose {
        pose: start,
        valid: true,
    });
    h.model.refresh();
    assert_eq!(
        h.model.hud().start.unwrap().level,
        crate::playback::StartPoseLevel::Ok
    );
    h.model.inputs.alliance_red = Some(false);
    h.model.toggle_manual_alliance();
    assert!(
        h.model.manual_red,
        "a known alliance ignores the manual toggle"
    );
    h.model.refresh();
    assert_eq!(
        h.model.hud().start.unwrap().level,
        crate::playback::StartPoseLevel::Off,
        "blue start is elsewhere"
    );
    assert!(
        h.model.start_check("Stay And Shoot").is_none(),
        "no path, no check"
    );
    h.model.set_preview("Stay And Shoot");
    h.model.clock.play();
    h.step();
    assert_eq!(
        (h.model.hud().auto.as_str(), h.model.hud().mirror),
        ("Stay And Shoot", true)
    );
    assert!(
        h.model.hud().start.is_none(),
        "no start check while mirroring"
    );
    assert_eq!(h.model.frame().unwrap().alliance, BLUE);
}

#[test]
fn freshness_uses_the_fixture_age() {
    let mut h = Harness::new();
    let at =
        freshness::parse_unix(h.model.library.exported_at().trim_end_matches('Z')).unwrap() as f64;
    let f = h.model.freshness(None, at + 10.0 * 86400.0).unwrap();
    assert_eq!(
        (f.level, f.text.as_str()),
        (FreshnessLevel::Old, "10 d old")
    );
    h.model.export_age_override_s = Some(3600.0);
    assert_eq!(
        h.model.freshness(None, at + 10.0 * 86400.0).unwrap().text,
        "1 h ago"
    );
    let hash = h.model.library.exported_source_hash().to_owned();
    assert_eq!(
        h.model.freshness(Some(&hash), at).unwrap().level,
        FreshnessLevel::MatchesRobot
    );
    let summary = h
        .model
        .library
        .summary_text(h.model.freshness(None, at).as_ref());
    assert_eq!(
        summary,
        "9 autos · built-in · 1 h ago\nexported 2026-11-14 12:28 UTC"
    );
}

#[test]
fn fixture_sets_preview_alliance_and_meta() {
    let mut h = Harness::new();
    h.model.apply_fixture(
        &json!({"auto": "Ball Shooter Left", "t": 9.0, "playing": true, "alliance": "blue",
        "meta": {"Stay And Shoot": {"name": "Stay", "description": "d"}}}),
    );
    assert_eq!(h.model.preview_name(), "Ball Shooter Left");
    assert_eq!(h.model.clock.t, 9.0);
    assert!(h.model.clock.playing);
    assert!(!h.model.manual_red);
    assert_eq!(h.model.library.display_name("Stay And Shoot"), "Stay");
    assert_eq!(h.model.hud().auto, "Ball Shooter Left");
    assert!(h.model.hud().mirror);
    h.model.reload();
    assert_eq!(
        h.model.preview_name(),
        "Ball Shooter Left",
        "a reload keeps a preview that still loads"
    );
}
