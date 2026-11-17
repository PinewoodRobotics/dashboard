use super::*;

const MS: i64 = 1000;
const S: i64 = 1_000_000;

fn int(i: i64) -> Value {
    Value::Int(i)
}

fn dbl(d: f64) -> Value {
    Value::Double(d)
}

fn b(v: bool) -> Value {
    Value::Bool(v)
}

fn near(a: f64, want: f64, tol: f64, what: &str) {
    assert!((a - want).abs() <= tol, "{what}: {a} vs {want}");
}

fn ready_model() -> MatchModel {
    let mut m = MatchModel::new();
    m.set_nt_ready(true, 0);
    m
}

#[test]
fn has_data_and_connected() {
    let mut m = MatchModel::new();
    assert!(!m.has_data() && !m.connected());
    assert_eq!(m.banner(), Banner::Disconnected);
    m.set_nt_ready(true, 0);
    assert!(!m.connected(), "socket up, no robot data");
    assert_eq!(m.banner(), Banner::NoData);
    m.ingest("seq", &int(0), 0);
    assert!(!m.has_data(), "seq 0 is not data");
    m.ingest("seq", &int(1), 0);
    assert!(m.has_data() && m.connected());
    m.step(0);
    assert_eq!(m.banner(), Banner::None);
    m.set_nt_ready(false, 10);
    assert!(!m.connected());
    assert_eq!(m.banner(), Banner::Disconnected);
    m.set_nt_ready(true, 20);
    assert!(
        !m.has_data(),
        "values from the previous connection do not count"
    );
    m.ingest("connected", &b(true), 30);
    assert!(
        m.has_data() && m.connected(),
        "the DS-attached flag alone counts"
    );
    m.ingest("connected", &b(false), 40);
    assert!(!m.has_data());
}

#[test]
fn ingest_maps_enums_and_flags() {
    let mut m = ready_model();
    m.ingest("match_phase", &int(4), 0);
    m.ingest("hub_status", &int(3), 0);
    m.ingest("header_color", &int(2), 0);
    m.ingest("aim_mode", &int(2), 0);
    m.ingest("show_shift_indicator", &b(true), 0);
    m.ingest("show_buffer", &b(true), 0);
    assert_eq!(m.phase, Phase::Shift2);
    assert_eq!(m.hub, Hub::Warning);
    assert_eq!(m.header, Header::Yellow);
    assert_eq!(m.aim, Aim::ManualAiming);
    assert!(m.show_shift_indicator && m.show_buffer);
    m.ingest("match_phase", &int(99), 0);
    m.ingest("aim_mode", &int(-4), 0);
    assert_eq!(m.phase, Phase::PreMatch, "unknown phase -> pre_match");
    assert_eq!(m.aim, Aim::ShooterDisabled);
}

#[test]
fn shift_selection_both_hub_periods_use_period_time() {
    for p in [Phase::Autonomous, Phase::Transition, Phase::Endgame] {
        let d = MatchModel::select_shift(p, Hub::Both, 7.5, 3.0, 6.0, 0.0, false);
        assert_eq!(d.main, 7.5, "{p:?} uses period time");
        assert_eq!(d.buffer, None);
    }
    assert_eq!(
        MatchModel::select_shift(Phase::Autonomous, Hub::Both, -1.0, 0.0, 0.0, 0.0, false).main,
        0.0,
        "clamped at 0"
    );
}

#[test]
fn shift_selection_shifts() {
    let sel = MatchModel::select_shift;
    assert_eq!(
        sel(Phase::Shift1, Hub::Active, 99.0, 15.4, 18.4, 0.0, false).main,
        15.4,
        "active: shift time"
    );
    assert_eq!(
        sel(Phase::Shift2, Hub::Inactive, 99.0, 12.0, 12.0, 0.0, false).main,
        12.0,
        "inactive: shift time"
    );
    let warn = sel(Phase::Shift2, Hub::Warning, 99.0, 23.7, 23.7, 1.7, true);
    assert_eq!(warn.main, 0.0, "warning forces 0");
    assert_eq!(
        warn.buffer,
        Some(1.7),
        "warning buffer line counts buffer_remaining"
    );
    assert_eq!(
        sel(Phase::Shift1, Hub::Active, 99.0, 15.4, 18.4, 0.0, true).buffer,
        Some(18.4),
        "show_buffer outside warning uses shift_time_with_buffer"
    );
    assert_eq!(
        sel(Phase::Shift2, Hub::Warning, 99.0, 23.7, 23.7, 1.7, false).buffer,
        None,
        "buffer line only with show_buffer"
    );
    assert_eq!(
        sel(Phase::Shift2, Hub::Warning, 99.0, 23.7, 23.7, -0.5, true).buffer,
        Some(0.0),
        "buffer clamped at 0"
    );
}

#[test]
fn shift_display_uses_live_countdowns() {
    let mut m = ready_model();
    m.ingest("seq", &int(1), 0);
    m.ingest("match_phase", &int(3), 0);
    m.ingest("hub_status", &int(2), 0);
    m.ingest("shift_time_remaining_s", &dbl(15.0), 0);
    m.ingest("period_time_remaining_s", &dbl(15.0), 0);
    m.step(0);
    near(m.shift_display(50 * MS).main, 14.95, 1e-9, "shift");
}

#[test]
fn pose_trust() {
    let mut m = ready_model();
    m.ingest("seq", &int(1), 0);
    m.step(0);
    assert!(m.pose_trusted(), "unknown validity is trusted");
    m.ingest("robot_pose_valid", &b(false), 0);
    assert!(!m.pose_trusted());
    m.ingest("robot_pose_valid", &b(true), 0);
    assert!(m.pose_trusted());
    m.set_nt_ready(false, 10);
    assert!(!m.pose_trusted(), "no live data -> pose not current");
}

#[test]
fn phase_event_and_alliance() {
    let mut m = ready_model();
    let seen: Vec<_> = [1, 1, 2]
        .into_iter()
        .filter_map(|p| m.ingest("match_phase", &int(p), 0))
        .collect();
    assert_eq!(
        seen,
        [
            MatchEvent::PhaseChanged(Phase::Autonomous),
            MatchEvent::PhaseChanged(Phase::Transition)
        ]
    );
    assert_eq!(m.is_red_alliance, None);
    m.ingest("is_red_alliance", &b(true), 0);
    assert_eq!(m.is_red_alliance, Some(true));
}

#[test]
fn paused_value_never_drifts() {
    let mut m = ready_model();
    let mut t = 0;
    m.ingest("seq", &int(1), t);
    m.ingest("total_time_remaining_s", &dbl(140.0), t);
    m.ingest("period_time_remaining_s", &dbl(0.0), t);
    for i in 0..600 {
        t += 20 * MS;
        m.ingest("seq", &int(i + 2), t);
        m.step(t);
    }
    near(
        m.total_display(t),
        140.0,
        1e-9,
        "12 s of a held value: no drift",
    );
    near(m.total_display(t + 15 * MS), 140.0, 1e-9, "between seqs");
    assert!(m.link_ok());
}

#[test]
fn dead_reckoning_when_link_lost() {
    let mut m = ready_model();
    let mut t = 0;
    for i in 0..10 {
        m.ingest("seq", &int(i + 1), t);
        m.ingest("total_time_remaining_s", &dbl(100.0 - t as f64 / 1e6), t);
        m.step(t);
        t += 20 * MS;
    }
    let last_t = t - 20 * MS;
    let last_v = 100.0 - last_t as f64 / 1e6;
    m.set_nt_ready(false, t);
    assert!(!m.link_ok());
    near(
        m.total_display(last_t + 2 * S),
        last_v - 2.0,
        1e-6,
        "a running timer keeps counting while disconnected",
    );
    near(m.total_display(last_t + 200 * S), 0.0, 1e-9, "clamped at 0");
}

#[test]
fn held_timer_stays_put_when_link_lost() {
    let mut m = ready_model();
    m.ingest("seq", &int(1), 0);
    m.ingest("total_time_remaining_s", &dbl(140.0), 0);
    m.ingest("seq", &int(2), 20 * MS);
    m.ingest("seq", &int(3), 40 * MS);
    m.step(40 * MS);
    m.set_nt_ready(false, 50 * MS);
    near(m.total_display(5 * S), 140.0, 1e-9, "held");
}

#[test]
fn stale_seq_counts_as_link_down() {
    let mut m = ready_model();
    m.ingest("seq", &int(7), 0);
    m.ingest("total_time_remaining_s", &dbl(50.0), 0);
    m.step(900 * MS);
    assert!(m.link_ok() && !m.stale());
    assert_eq!(
        m.step(1_000 * MS),
        Some(MatchEvent::LinkChanged(false)),
        "seq unchanged for 1 s"
    );
    assert!(m.stale());
    assert!(!m.link_ok());
    assert_eq!(m.banner(), Banner::Stale);
    near(
        m.total_display(1_000 * MS),
        49.0,
        1e-9,
        "dead-reckons while stale",
    );
    m.ingest("seq", &int(8), 1_100 * MS);
    m.step(1_100 * MS);
    assert!(
        m.link_ok() && m.banner() == Banner::None,
        "recovers on the next seq"
    );
}

#[test]
fn toast_reset_in_pre_match() {
    let mut m = ready_model();
    let mut fired = Vec::new();
    let mut feed = |m: &mut MatchModel, key: &str, v: Value, t: i64| {
        if let Some(MatchEvent::ToastFired(on)) = m.ingest(key, &v, t) {
            fired.push(on);
        }
    };
    feed(&mut m, LANE_KEY, b(false), 0);
    feed(&mut m, LANE_KEY, b(true), S);
    feed(&mut m, "match_phase", int(3), 2 * S);
    feed(&mut m, "match_phase", int(0), 3 * S);
    feed(&mut m, LANE_KEY, b(false), 4 * S);
    feed(&mut m, LANE_KEY, b(true), 5 * S);
    feed(&mut m, "match_phase", int(1), 6 * S);
    feed(&mut m, LANE_KEY, b(false), 7 * S);
    assert_eq!(
        fired,
        [true, true, false],
        "first value after returning to pre-match is silent, later changes fire, no reset outside pre-match"
    );
}

#[test]
fn frozen_clock_advances_only_on_request() {
    let mut c = Clock::frozen(10 * S);
    assert_eq!(c.now_us(), 10 * S);
    c.advance_s(0.6);
    assert_eq!(c.now_us(), 10 * S + 600 * MS);
    assert!(c.is_frozen());
}

#[test]
fn match_state_keys_cover_the_countdowns() {
    for k in CountdownKey::ALL {
        assert!(
            MATCH_STATE_KEYS
                .iter()
                .any(|(key, ty)| *key == k.key() && *ty == "double")
        );
        assert_eq!(CountdownKey::from_key(k.key()), Some(k));
    }
    assert_eq!(MATCH_STATE_KEYS.len(), 28);
    assert_eq!(match_topic("seq"), "/matchhud/state/seq");
}
