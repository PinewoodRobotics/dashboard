use std::fs;
use std::io;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Map, Number, Value};

pub(crate) fn num(v: Option<&Value>) -> Option<f64> {
    v.and_then(Value::as_f64).filter(|f| f.is_finite())
}

pub(crate) fn obj(v: Option<&Value>) -> Option<&Map<String, Value>> {
    v.and_then(Value::as_object)
}

/// An f32 setting as the decimal it was typed as (0.3, not 0.30000001192092896).
pub(crate) fn f32_value(v: f32) -> Value {
    format!("{v}")
        .parse::<f64>()
        .ok()
        .and_then(Number::from_f64)
        .map(Value::Number)
        .unwrap_or(Value::Null)
}

/// Whole numbers are written as integers (`"port": 5810`, never `5810.0`),
/// as JavaScript's JSON.stringify does for the other apps.
pub(crate) fn integral_floats_to_int(v: Value) -> Value {
    match v {
        Value::Number(n) if n.is_f64() => {
            let f = n.as_f64().unwrap_or(f64::NAN);
            if f.is_finite() && f == f.floor() && f.abs() < 9.0e15 {
                Value::from(f as i64)
            } else {
                Value::Number(n)
            }
        }
        Value::Object(m) => Value::Object(
            m.into_iter()
                .map(|(k, v)| (k, integral_floats_to_int(v)))
                .collect(),
        ),
        Value::Array(a) => Value::Array(a.into_iter().map(integral_floats_to_int).collect()),
        other => other,
    }
}

/// `JSON.stringify(v, null, 2)`.
pub(crate) fn stringify(v: &Value) -> String {
    serde_json::to_string_pretty(&integral_floats_to_int(v.clone())).unwrap_or_default()
}

/// None for empty or malformed text: a half-written file from another app is
/// expected now and then.
pub(crate) fn parse(text: &str) -> Option<Value> {
    let t = text.trim_start_matches('\u{feff}');
    if t.trim().is_empty() {
        return None;
    }
    serde_json::from_str(t).ok()
}

/// Writes a sibling temp file and renames it over the target, so a reader in
/// another process never sees a partial file.
pub(crate) fn write_atomically(target: &Path, text: &str) -> io::Result<()> {
    static SEQ: AtomicU64 = AtomicU64::new(0);
    if let Some(dir) = target.parent().filter(|d| !d.as_os_str().is_empty()) {
        fs::create_dir_all(dir)?;
    }
    let micros = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_micros())
        .unwrap_or(0);
    let mut tmp = target.as_os_str().to_owned();
    tmp.push(format!(
        ".tmp-{}-{}-{}",
        std::process::id(),
        micros,
        SEQ.fetch_add(1, Ordering::Relaxed)
    ));
    let tmp = Path::new(&tmp);
    fs::write(tmp, text)?;
    if let Err(e) = fs::rename(tmp, target) {
        let _ = fs::remove_file(tmp);
        return Err(e);
    }
    Ok(())
}

/// `new Date().toISOString()`.
pub(crate) fn iso_utc_now() -> String {
    let d = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    iso_utc(d.as_secs() as i64, d.subsec_millis())
}

pub(crate) fn iso_utc(secs: i64, millis: u32) -> String {
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    let (y, m, d) = civil_from_days(days);
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}.{millis:03}Z",
        rem / 3600,
        rem % 3600 / 60,
        rem % 60
    )
}

/// Howard Hinnant's days-to-civil for the proleptic Gregorian calendar.
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let y = yoe + era * 400 + i64::from(m <= 2);
    (y, m, d)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn iso_dates_match_to_iso_string() {
        assert_eq!(iso_utc(0, 0), "1970-01-01T00:00:00.000Z");
        assert_eq!(iso_utc(1_783_388_358, 69), "2026-07-07T01:39:18.069Z");
        assert_eq!(iso_utc(951_782_400, 5), "2000-02-29T00:00:00.005Z");
    }

    #[test]
    fn stringify_matches_json_stringify_two_spaces() {
        let v = json!({"b": 5810.0, "a": [1, 2.5, "x"], "e": {}, "z": [], "f": 0.3});
        assert_eq!(
            stringify(&v),
            "{\n  \"b\": 5810,\n  \"a\": [\n    1,\n    2.5,\n    \"x\"\n  ],\n  \"e\": {},\n  \"z\": [],\n  \"f\": 0.3\n}"
        );
    }

    #[test]
    fn f32_settings_keep_their_decimal() {
        assert_eq!(f32_value(0.3).to_string(), "0.3");
        assert_eq!(f32_value(0.25).to_string(), "0.25");
    }

    #[test]
    fn parse_tolerates_junk() {
        assert_eq!(parse(""), None);
        assert_eq!(parse("  \n"), None);
        assert_eq!(parse("{not json"), None);
        assert_eq!(parse("\u{feff}{\"a\":1}"), Some(json!({"a": 1})));
    }
}
