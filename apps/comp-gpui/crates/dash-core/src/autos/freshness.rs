//! Whether the preview can be trusted to match the robot's paths. A path
//! edited and deployed without a re-export keeps its auto names, so the
//! robot's auto list cannot tell. When the robot publishes the hash of its
//! deploy/pathplanner folder it is compared with the export's source_hash;
//! otherwise the export's age is the only hint.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FreshnessLevel {
    Fresh,
    Old,
    MatchesRobot,
    Differs,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Freshness {
    /// -1 when the export time cannot be parsed or lies in the future.
    pub age_s: f64,
    pub age: String,
    pub level: FreshnessLevel,
    pub text: String,
}

pub const OLD_AFTER_S: f64 = 3.0 * 86400.0;

impl Freshness {
    pub fn check(
        exported_at: &str,
        source_hash: &str,
        robot_hash: Option<&str>,
        now_unix: f64,
    ) -> Self {
        let age_s = age_s(exported_at, now_unix);
        let age = age_text(age_s);
        let (level, text) = match robot_hash.filter(|h| !h.is_empty()) {
            Some(robot) => {
                if !source_hash.is_empty() && robot.eq_ignore_ascii_case(source_hash) {
                    (FreshnessLevel::MatchesRobot, "matches robot".to_owned())
                } else {
                    (FreshnessLevel::Differs, "differs from robot".to_owned())
                }
            }
            None if age_s > OLD_AFTER_S => (FreshnessLevel::Old, format!("{age} old")),
            None if age_s >= 0.0 => (FreshnessLevel::Fresh, format!("{age} ago")),
            None => (FreshnessLevel::Fresh, String::new()),
        };
        Self {
            age_s,
            age,
            level,
            text,
        }
    }
}

pub fn age_s(exported_at: &str, now_unix: f64) -> f64 {
    let iso = exported_at.trim();
    let iso = iso.strip_suffix('Z').unwrap_or(iso);
    if iso.len() < 19 {
        return -1.0;
    }
    match parse_unix(iso) {
        Some(t) if t > 0 && (t as f64) <= now_unix + 60.0 => (now_unix - t as f64).max(0.0),
        _ => -1.0,
    }
}

pub fn age_text(s: f64) -> String {
    if s < 0.0 {
        "unknown age".into()
    } else if s < 3600.0 {
        format!("{} min", ((s / 60.0).floor() as i64).max(1))
    } else if s < 86400.0 {
        format!("{} h", (s / 3600.0).floor() as i64)
    } else {
        format!("{} d", (s / 86400.0).floor() as i64)
    }
}

/// "2026-11-14T12:28:09Z" -> "2026-11-14 12:28".
pub fn short_time(iso: &str) -> String {
    let s = iso.replace('T', " ");
    let s = s.strip_suffix('Z').unwrap_or(&s);
    s.chars().take(16).collect()
}

/// Seconds since the Unix epoch of "YYYY-MM-DD[T ]HH:MM:SS[.fff]" in UTC.
pub fn parse_unix(iso: &str) -> Option<i64> {
    let b = iso.as_bytes();
    if b.len() < 19
        || b[4] != b'-'
        || b[7] != b'-'
        || !(b[10] == b'T' || b[10] == b' ')
        || b[13] != b':'
        || b[16] != b':'
    {
        return None;
    }
    let rest = &iso[19..];
    if !(rest.is_empty()
        || (rest.starts_with('.') && rest[1..].bytes().all(|c| c.is_ascii_digit())))
    {
        return None;
    }
    let field = |r: std::ops::Range<usize>| -> Option<i64> {
        let s = iso.get(r)?;
        s.bytes()
            .all(|c| c.is_ascii_digit())
            .then(|| s.parse().ok())?
    };
    let (y, mo, d) = (field(0..4)?, field(5..7)?, field(8..10)?);
    let (h, mi, s) = (field(11..13)?, field(14..16)?, field(17..19)?);
    if !(1..=12).contains(&mo)
        || !(1..=days_in_month(y, mo)).contains(&d)
        || h > 23
        || mi > 59
        || s > 59
    {
        return None;
    }
    Some(days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + s)
}

fn days_in_month(y: i64, m: i64) -> i64 {
    match m {
        2 if (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    }
}

fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

#[cfg(test)]
mod tests {
    use super::*;

    const AT: &str = "2026-11-14T12:00:00Z";
    const HASH: &str = "3e03068c8f377014417fb19d87aa685f6bdf1c078e85db1650972f7c88b9a807";

    fn now() -> f64 {
        parse_unix("2026-11-14T12:00:00").unwrap() as f64
    }

    #[test]
    fn parses_utc_times() {
        assert_eq!(parse_unix("1970-01-01T00:00:00"), Some(0));
        assert_eq!(parse_unix("2026-11-14T12:00:00"), Some(1_794_657_600));
        assert_eq!(parse_unix("2024-02-29 23:59:59.5"), Some(1_709_251_199));
        assert_eq!(parse_unix("2023-02-29T00:00:00"), None);
        assert_eq!(parse_unix("2026-11-14T12:00:00+01"), None);
    }

    #[test]
    fn age_without_a_robot_hash() {
        let f = Freshness::check(AT, HASH, None, now() + 2.5 * 3600.0);
        assert_eq!(f.level, FreshnessLevel::Fresh);
        assert_eq!(f.text, "2 h ago");
        assert_eq!(
            Freshness::check(AT, HASH, None, now() + 30.0).text,
            "1 min ago"
        );
        let old = Freshness::check(AT, HASH, Some(""), now() + 4.0 * 86400.0);
        assert_eq!(old.level, FreshnessLevel::Old);
        assert_eq!(old.text, "4 d old");
    }

    #[test]
    fn unknown_or_future_time_shows_no_age() {
        for at in ["", "garbage", "2999-01-02T03:04:00Z"] {
            let f = Freshness::check(at, HASH, None, now());
            assert_eq!(f.level, FreshnessLevel::Fresh, "{at}");
            assert_eq!(f.text, "", "{at}");
            assert_eq!(f.age, "unknown age", "{at}");
        }
    }

    #[test]
    fn robot_hash_decides_over_age() {
        let upper = HASH.to_uppercase();
        let same = Freshness::check(AT, HASH, Some(&upper), now() + 30.0 * 86400.0);
        assert_eq!(same.level, FreshnessLevel::MatchesRobot);
        assert_eq!(same.text, "matches robot");
        let diff = Freshness::check(AT, HASH, Some("deadbeef"), now() + 60.0);
        assert_eq!(diff.level, FreshnessLevel::Differs);
        assert_eq!(diff.text, "differs from robot");
        assert_eq!(
            Freshness::check(AT, "", Some("deadbeef"), now()).level,
            FreshnessLevel::Differs,
            "an export without a hash never matches"
        );
    }

    #[test]
    fn short_time_trims_seconds() {
        assert_eq!(short_time("2026-11-14T12:28:09Z"), "2026-11-14 12:28");
    }
}
