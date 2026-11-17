use std::f64::consts::{PI, TAU};

const CMP_EPSILON: f64 = 0.00001;

pub(crate) fn is_equal_approx(a: f64, b: f64) -> bool {
    if a == b {
        return true;
    }
    let tolerance = (CMP_EPSILON * a.abs()).max(CMP_EPSILON);
    (a - b).abs() < tolerance
}

pub fn angle_difference(from: f64, to: f64) -> f64 {
    let difference = (to - from) % TAU;
    (2.0 * difference) % TAU - difference
}

pub fn lerp_angle(from: f64, to: f64, weight: f64) -> f64 {
    from + angle_difference(from, to) * weight
}

pub fn lerp(from: f64, to: f64, weight: f64) -> f64 {
    from + (to - from) * weight
}

pub fn wrap(value: f64, min: f64, max: f64) -> f64 {
    let range = max - min;
    if range.abs() < CMP_EPSILON {
        return min;
    }
    let result = value - range * ((value - min) / range).floor();
    if is_equal_approx(result, max) {
        min
    } else {
        result
    }
}

pub fn wrap_pi(value: f64) -> f64 {
    wrap(value, -PI, PI)
}

pub fn smoothstep(from: f64, to: f64, s: f64) -> f64 {
    if is_equal_approx(from, to) {
        return if from <= to {
            if s <= from { 0.0 } else { 1.0 }
        } else if s <= to {
            1.0
        } else {
            0.0
        };
    }
    let s = ((s - from) / (to - from)).clamp(0.0, 1.0);
    s * s * (3.0 - 2.0 * s)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_godot_math() {
        assert!((angle_difference(3.0, -3.0) - (TAU - 6.0)).abs() < 1e-12);
        assert!((angle_difference(-3.0, 3.0) + (TAU - 6.0)).abs() < 1e-12);
        assert!((lerp_angle(3.0, -3.0, 0.5).abs() - PI).abs() < 1e-12);
        assert!((wrap_pi(PI + 0.5) - (-PI + 0.5)).abs() < 1e-12);
        assert_eq!(wrap_pi(PI), -PI);
        assert_eq!(smoothstep(0.0, 1.0, 0.5), 0.5);
        assert_eq!(smoothstep(0.0, 1.0, -1.0), 0.0);
        assert_eq!(smoothstep(0.0, 1.0, 2.0), 1.0);
        assert_eq!(smoothstep(2.0, 2.0, 1.0), 0.0);
        assert_eq!(smoothstep(2.0, 2.0, 3.0), 1.0);
    }
}
