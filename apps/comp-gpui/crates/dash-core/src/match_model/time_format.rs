//! Floor-based countdown formatting, clamped at 0. The epsilon keeps a value
//! published as 12.29 from flooring to 12.28 through binary rounding.

const EPS: f64 = 1e-6;

pub fn centis(t: f64) -> i64 {
    if !t.is_finite() || t <= 0.0 {
        return 0;
    }
    (t * 100.0 + EPS).floor() as i64
}

/// ("MM:SS", ".cc")
pub fn mm_ss_cc(t: f64) -> (String, String) {
    let cs = centis(t);
    let s = cs / 100;
    (
        format!("{:02}:{:02}", s / 60, s % 60),
        format!(".{:02}", cs % 100),
    )
}

/// ("NN", ".dd")
pub fn nn_dd(t: f64) -> (String, String) {
    let cs = centis(t);
    (format!("{:02}", cs / 100), format!(".{:02}", cs % 100))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(a: &str, b: &str) -> (String, String) {
        (a.into(), b.into())
    }

    #[test]
    fn mm_ss_cc_cases() {
        assert_eq!(mm_ss_cc(132.34), p("02:12", ".34"));
        assert_eq!(mm_ss_cc(160.0), p("02:40", ".00"));
        assert_eq!(
            mm_ss_cc(59.999),
            p("00:59", ".99"),
            "floor, never rounds up to the next second"
        );
        assert_eq!(mm_ss_cc(60.0), p("01:00", ".00"));
        assert_eq!(mm_ss_cc(0.009), p("00:00", ".00"));
        assert_eq!(
            mm_ss_cc(12.29),
            p("00:12", ".29"),
            "binary rounding does not drop a centisecond"
        );
        assert_eq!(mm_ss_cc(0.29), p("00:00", ".29"));
    }

    #[test]
    fn mm_ss_cc_clamps_at_zero() {
        assert_eq!(mm_ss_cc(-3.5), p("00:00", ".00"));
        assert_eq!(mm_ss_cc(f64::NAN), p("00:00", ".00"));
    }

    #[test]
    fn nn_dd_cases() {
        assert_eq!(nn_dd(15.42), p("15", ".42"));
        assert_eq!(nn_dd(1.749), p("01", ".74"), "floor, not toFixed rounding");
        assert_eq!(nn_dd(0.0), p("00", ".00"));
        assert_eq!(nn_dd(-1.0), p("00", ".00"));
        assert_eq!(nn_dd(9.999), p("09", ".99"));
        assert_eq!(nn_dd(125.5), p("125", ".50"));
    }
}
