//! The NT client against apps/comp-godot/tools/sim/fake_robot.py, a real
//! ntcore server. Needs `uv`; run with
//! `cargo test -p dash-core --test fake_robot -- --ignored`.

use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use dash_core::nt::client::State;
use dash_core::nt::topics::{self, SubscriptionGroup};
use dash_core::nt::{Clock, NtService, NtValue, SubOptions};
use dash_core::request_state::{ControlLink, Value};

const AUTO_REQ: &str = "/Shared/PathPlanner/SelectedPath/Request";
const AUTO_STATE: &str = "/Shared/PathPlanner/SelectedPath/State";
const INTAKE_REQ: &str = "/Shared/Intake/Speed/Request";
const INTAKE_STATE: &str = "/Shared/Intake/Speed/State";

struct Robot {
    child: Child,
    pid_file: PathBuf,
    port: u16,
}

fn free_port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

impl Robot {
    fn start(port: u16) -> Robot {
        let script = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../../comp-godot/tools/sim/fake_robot.py");
        let pid_file = std::env::temp_dir().join(format!("dash-core-fake-robot-{port}.pid"));
        let _ = std::fs::remove_file(&pid_file);
        let child = Command::new("uv")
            .arg("run")
            .arg(&script)
            .args(["--port", &port.to_string(), "--pid-file"])
            .arg(&pid_file)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("uv must be on PATH");
        let r = Robot { child, pid_file, port };
        let start = Instant::now();
        while start.elapsed() < Duration::from_secs(60) {
            if r.pid().is_some() && std::net::TcpStream::connect(("127.0.0.1", port)).is_ok() {
                return r;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        panic!("fake robot did not start on {port}");
    }

    fn pid(&self) -> Option<String> {
        std::fs::read_to_string(&self.pid_file).ok().filter(|s| !s.trim().is_empty())
    }

    fn signal(&self, sig: &str) {
        if let Some(pid) = self.pid() {
            let _ = Command::new("kill").args([sig, pid.trim()]).status();
        }
    }
}

impl Drop for Robot {
    fn drop(&mut self) {
        self.signal("-CONT");
        self.signal("-TERM");
        let start = Instant::now();
        while start.elapsed() < Duration::from_secs(5) {
            if let Ok(Some(_)) = self.child.try_wait() {
                return;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        self.signal("-KILL");
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn client(port: u16, extra: Vec<SubscriptionGroup>) -> NtService {
    let nt = dash_core::nt::spawn(Clock::real());
    let mut groups = topics::subscription_groups(AUTO_STATE, INTAKE_STATE);
    groups.extend(extra);
    nt.set_subscriptions(groups);
    nt.configure("127.0.0.1", port, 2.0);
    nt.start();
    nt
}

fn wait_for(nt: &mut NtService, limit: Duration, mut pred: impl FnMut(&NtService) -> bool) -> Option<Duration> {
    let clock = Clock::real();
    let start = Instant::now();
    while start.elapsed() < limit {
        nt.pump(clock.now_us());
        if pred(nt) {
            return Some(start.elapsed());
        }
        std::thread::sleep(Duration::from_millis(2));
    }
    None
}

fn get(nt: &NtService, topic: &str) -> Option<NtValue> {
    nt.get(topic).cloned()
}

#[test]
#[ignore = "needs uv and the fake robot"]
fn connects_decodes_every_type_and_echoes_requests() {
    let robot = Robot::start(free_port());
    let mut nt = client(
        robot.port,
        vec![SubscriptionGroup {
            topics: vec!["/fake/types/".into()],
            options: SubOptions { prefix: true, ..Default::default() },
        }],
    );
    wait_for(&mut nt, Duration::from_secs(5), |nt| nt.is_ready()).expect("READY");
    let expect: Vec<(&str, NtValue)> = vec![
        ("bool", NtValue::Bool(true)),
        ("int", NtValue::Int(1234567890123)),
        ("int_min", NtValue::Int(i64::MIN)),
        ("int_max", NtValue::Int(i64::MAX)),
        ("double", NtValue::Double(std::f64::consts::PI)),
        ("float", NtValue::Double(1.5)),
        ("string", NtValue::String("Höhe 4765".into())),
        ("raw", NtValue::Raw(vec![0, 1, 2, 254, 255])),
        ("bool_array", NtValue::BoolArray(vec![true, false, true])),
        ("double_array", NtValue::DoubleArray(vec![1.5, -2.25, 1e300])),
        ("int_array", NtValue::IntArray(vec![1, -2, 1 << 40])),
        ("float_array", NtValue::DoubleArray(vec![0.5, -0.25])),
        (
            "string_array",
            NtValue::StringArray(vec!["a".into(), "".into(), "Move Forward And Shoot Left".into()]),
        ),
    ];
    wait_for(&mut nt, Duration::from_secs(3), |nt| {
        expect.iter().all(|(k, _)| nt.has_value(&format!("/fake/types/{k}")))
    })
    .expect("every type topic arrives");
    for (k, v) in &expect {
        assert_eq!(get(&nt, &format!("/fake/types/{k}")).as_ref(), Some(v), "/fake/types/{k}");
    }

    for (key, ty) in topics::MATCH_STATE.iter().filter(|(k, _)| *k != "camera_topic") {
        let e = nt.entry(&topics::match_topic(key)).unwrap_or_else(|| panic!("{key} missing"));
        assert_eq!(&*e.type_str, *ty, "{key}");
        assert!(nt.is_live(&topics::match_topic(key)), "{key} live");
    }
    let seq = |nt: &NtService| get(nt, "/matchhud/state/seq").and_then(|v| v.as_i64()).unwrap_or(0);
    let first = seq(&nt);
    wait_for(&mut nt, Duration::from_secs(1), |nt| seq(nt) >= first + 10).expect("seq advances at 50 Hz");
    for t in topics::JOINT_TOPICS.iter().take(2).chain(topics::READOUT_TOPICS.iter()) {
        assert!(nt.is_live(t), "{t} live");
    }
    assert_eq!(
        get(&nt, topics::PP_VALID_AUTOS).and_then(|v| v.as_string_array().map(<[String]>::len)),
        Some(9)
    );

    assert!(nt.publish(AUTO_REQ, Value::String("Stay And Shoot".into())));
    assert!(nt.publish(INTAKE_REQ, Value::Double(0.42)));
    assert!(nt.publish(topics::AIM_TRIM_PUBLISH, Value::Double(1.5)));
    wait_for(&mut nt, Duration::from_secs(2), |nt| {
        get(nt, AUTO_STATE) == Some(NtValue::String("Stay And Shoot".into()))
            && get(nt, topics::PP_SELECTED_AUTO_VALID) == Some(NtValue::Bool(true))
            && get(nt, topics::PP_CURRENT_SELECTED_AUTO) == Some(NtValue::String("Stay And Shoot".into()))
            && get(nt, INTAKE_STATE) == Some(NtValue::Double(0.42))
            && get(nt, topics::AIM_TRIM_READBACK) == Some(NtValue::Double(1.5))
    })
    .expect("robot echoes all three requests");

    let d = nt.diagnostics().clone();
    assert_eq!(d.state, State::Ready);
    assert_eq!(d.protocol, "networktables.first.wpi.edu");
    assert!(d.rtt_us >= 0 && d.rtt_us < 50_000, "rtt {} us", d.rtt_us);
    assert!(d.server_time_us > 0);
    assert_eq!((d.decode_errors, d.coerce_errors, d.unknown_id_drops), (0, 0, 0));
}

#[test]
#[ignore = "needs uv and the fake robot"]
fn reconnects_within_a_second_of_a_restart_and_republishes() {
    let port = free_port();
    let robot = Robot::start(port);
    let mut nt = client(port, vec![]);
    wait_for(&mut nt, Duration::from_secs(5), |nt| nt.is_ready()).expect("READY");
    assert!(nt.publish(INTAKE_REQ, Value::Double(0.7)));
    wait_for(&mut nt, Duration::from_secs(2), |nt| get(nt, INTAKE_STATE) == Some(NtValue::Double(0.7)))
        .expect("first echo");

    drop(robot);
    wait_for(&mut nt, Duration::from_secs(3), |nt| !nt.is_ready()).expect("notices the robot left");
    assert!(!nt.is_live(INTAKE_STATE));
    assert_eq!(get(&nt, INTAKE_STATE), Some(NtValue::Double(0.7)), "stale value kept");
    std::thread::sleep(Duration::from_secs(2));

    let _robot = Robot::start(port);
    let took = wait_for(&mut nt, Duration::from_secs(5), |nt| nt.is_ready()).expect("READY again");
    assert!(took < Duration::from_millis(1200), "READY {took:?} after the server answered");
    wait_for(&mut nt, Duration::from_secs(2), |nt| {
        nt.is_live(INTAKE_STATE) && get(nt, INTAKE_STATE) == Some(NtValue::Double(0.7))
    })
    .expect("desired value republished without caller action");
}

#[test]
#[ignore = "needs uv and the fake robot"]
fn liveness_drops_a_frozen_robot_and_recovers() {
    let robot = Robot::start(free_port());
    let mut nt = client(robot.port, vec![]);
    wait_for(&mut nt, Duration::from_secs(5), |nt| nt.is_ready()).expect("READY");
    robot.signal("-STOP");
    let silent = wait_for(&mut nt, Duration::from_secs(5), |nt| !nt.is_ready()).expect("dropped");
    assert!(
        silent >= Duration::from_millis(1800) && silent <= Duration::from_millis(2600),
        "liveness fired after {silent:?}"
    );
    assert!(nt.diagnostics().liveness_fires >= 1 || nt.diagnostics().last_close.contains("liveness"));
    robot.signal("-CONT");
    wait_for(&mut nt, Duration::from_secs(6), |nt| nt.is_ready()).expect("READY after the robot resumes");
}

#[test]
#[ignore = "needs uv and the fake robot"]
fn refused_connects_retry_at_two_hertz() {
    let port = free_port();
    let mut nt = client(port, vec![]);
    let clock = Clock::real();
    let start = Instant::now();
    let mut max_attempt = 0;
    while start.elapsed() < Duration::from_millis(2000) {
        nt.pump(clock.now_us());
        max_attempt = max_attempt.max(nt.diagnostics().attempt);
        std::thread::sleep(Duration::from_millis(2));
    }
    assert!((5..=7).contains(&max_attempt), "attempts in 2 s: {max_attempt} (0, .1, .35, .85, 1.35, 1.85)");
    assert!(!nt.is_ready());
}
