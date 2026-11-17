//! NT4 wire format (core/nt/nt4_protocol.gd and nt4_frame_decoder.gd): JSON
//! control messages, msgpack `[id, ts, typeNum, value]` value frames, and the
//! coercion of decoded values to each topic's announced type.

use serde::Serialize;
use serde_json::{Map, Value as Json, json};

use super::msgpack::{MsgValue, Reader, Writer};
use crate::request_state::Value;

pub const PROTOCOL_V40: &str = "networktables.first.wpi.edu";
pub const PROTOCOL_V41: &str = "v4.1.networktables.first.wpi.edu";

pub const RTT_ID: i64 = -1;

pub const TYPE_BOOLEAN: u8 = 0;
pub const TYPE_DOUBLE: u8 = 1;
pub const TYPE_INT: u8 = 2;
pub const TYPE_FLOAT: u8 = 3;
pub const TYPE_STRING: u8 = 4;
pub const TYPE_RAW: u8 = 5;
pub const TYPE_BOOLEAN_ARRAY: u8 = 16;
pub const TYPE_DOUBLE_ARRAY: u8 = 17;
pub const TYPE_INT_ARRAY: u8 = 18;
pub const TYPE_FLOAT_ARRAY: u8 = 19;
pub const TYPE_STRING_ARRAY: u8 = 20;

/// Unknown type strings (struct:*, structschema, proto:*, ...) travel as raw bytes.
pub fn type_num(type_str: &str) -> u8 {
    match type_str {
        "boolean" => TYPE_BOOLEAN,
        "double" => TYPE_DOUBLE,
        "int" => TYPE_INT,
        "float" => TYPE_FLOAT,
        "string" | "json" => TYPE_STRING,
        "boolean[]" => TYPE_BOOLEAN_ARRAY,
        "double[]" => TYPE_DOUBLE_ARRAY,
        "int[]" => TYPE_INT_ARRAY,
        "float[]" => TYPE_FLOAT_ARRAY,
        "string[]" => TYPE_STRING_ARRAY,
        _ => TYPE_RAW,
    }
}

/// A topic value after coercion to its announced type. `float` topics decode
/// to `Double`.
#[derive(Clone, Debug, PartialEq)]
pub enum NtValue {
    Bool(bool),
    Int(i64),
    Double(f64),
    String(String),
    Raw(Vec<u8>),
    BoolArray(Vec<bool>),
    DoubleArray(Vec<f64>),
    IntArray(Vec<i64>),
    StringArray(Vec<String>),
}

impl NtValue {
    /// Finite numbers only.
    pub fn as_f64(&self) -> Option<f64> {
        let v = match *self {
            NtValue::Double(v) => v,
            NtValue::Int(v) => v as f64,
            _ => return None,
        };
        v.is_finite().then_some(v)
    }

    pub fn as_i64(&self) -> Option<i64> {
        match *self {
            NtValue::Int(v) => Some(v),
            NtValue::Double(v) if v.is_finite() && v == v.floor() => Some(v as i64),
            _ => None,
        }
    }

    pub fn as_bool(&self) -> Option<bool> {
        match *self {
            NtValue::Bool(b) => Some(b),
            _ => None,
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            NtValue::String(s) => Some(s),
            _ => None,
        }
    }

    pub fn as_string_array(&self) -> Option<&[String]> {
        match self {
            NtValue::StringArray(v) => Some(v),
            _ => None,
        }
    }

    pub fn to_control_value(&self) -> Option<Value> {
        Some(match self {
            NtValue::Bool(b) => Value::Bool(*b),
            NtValue::Int(i) => Value::Int(*i),
            NtValue::Double(d) => Value::Double(*d),
            NtValue::String(s) => Value::String(s.clone()),
            NtValue::StringArray(a) => Value::StringArray(a.clone()),
            _ => return None,
        })
    }

    pub fn from_control_value(v: &Value) -> Self {
        match v {
            Value::Bool(b) => NtValue::Bool(*b),
            Value::Int(i) => NtValue::Int(*i),
            Value::Double(d) => NtValue::Double(*d),
            Value::String(s) => NtValue::String(s.clone()),
            Value::StringArray(a) => NtValue::StringArray(a.clone()),
        }
    }
}

/// Subscription options as NT4 names them; unset fields are left out.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct SubOptions {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub periodic: Option<f64>,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub prefix: bool,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub all: bool,
    #[serde(rename = "topicsonly", skip_serializing_if = "std::ops::Not::not")]
    pub topics_only: bool,
}

pub fn subscribe_msg(subuid: i64, topics: &[String], options: &SubOptions) -> Json {
    json!({"method": "subscribe", "params": {"topics": topics, "subuid": subuid, "options": options}})
}

pub fn unsubscribe_msg(subuid: i64) -> Json {
    json!({"method": "unsubscribe", "params": {"subuid": subuid}})
}

pub fn publish_msg(pubuid: i64, name: &str, type_str: &str, properties: &Map<String, Json>) -> Json {
    json!({"method": "publish", "params": {"name": name, "pubuid": pubuid, "type": type_str, "properties": properties}})
}

pub fn unpublish_msg(pubuid: i64) -> Json {
    json!({"method": "unpublish", "params": {"pubuid": pubuid}})
}

pub fn setproperties_msg(name: &str, update: &Map<String, Json>) -> Json {
    json!({"method": "setproperties", "params": {"name": name, "update": update}})
}

pub fn encode_text(messages: &[Json]) -> String {
    Json::Array(messages.to_vec()).to_string()
}

#[derive(Clone, Debug, PartialEq)]
pub struct Message {
    pub method: String,
    pub params: Map<String, Json>,
}

impl Message {
    pub fn int(&self, key: &str) -> Option<i64> {
        self.params.get(key).and_then(Json::as_i64)
    }

    pub fn str(&self, key: &str) -> Option<&str> {
        self.params.get(key).and_then(Json::as_str)
    }
}

/// Entries that are not objects with a string `method` are skipped; integral
/// float ids become ints and an announce always has a `properties` object.
pub fn parse_text(text: &str) -> Result<Vec<Message>, String> {
    let data: Json = serde_json::from_str(text).map_err(|e| format!("json: {e}"))?;
    let Json::Array(items) = data else {
        return Err("json: top level is not an array".into());
    };
    let mut out = Vec::new();
    for m in items {
        let Json::Object(mut m) = m else { continue };
        let Some(method) = m.get("method").and_then(Json::as_str).map(str::to_owned) else {
            continue;
        };
        let mut params = match m.remove("params") {
            Some(Json::Object(p)) => p,
            _ => Map::new(),
        };
        for key in ["id", "pubuid", "subuid"] {
            if let Some(f) = params.get(key).filter(|v| v.is_f64()).and_then(Json::as_f64) {
                params.insert(key.into(), Json::from(f as i64));
            }
        }
        if method == "announce" && !params.get("properties").is_some_and(Json::is_object) {
            params.insert("properties".into(), Json::Object(Map::new()));
        }
        out.push(Message { method, params });
    }
    Ok(out)
}

pub fn rtt_frame(local_now_us: i64) -> Vec<u8> {
    let mut w = Writer::default();
    w.write_array_header(4);
    w.write_int(RTT_ID);
    w.write_int(0);
    w.write_int(i64::from(TYPE_INT));
    w.write_int(local_now_us);
    w.into_bytes()
}

fn finite(v: f64) -> bool {
    v.is_finite()
}

pub fn is_publishable(value: &NtValue, type_str: &str) -> bool {
    use NtValue as N;
    match (type_num(type_str), value) {
        (TYPE_BOOLEAN, N::Bool(_)) => true,
        (TYPE_DOUBLE | TYPE_FLOAT | TYPE_INT, N::Int(_)) => true,
        (TYPE_DOUBLE | TYPE_FLOAT | TYPE_INT, N::Double(v)) => finite(*v),
        (TYPE_STRING, N::String(_)) => true,
        (TYPE_RAW, N::Raw(_) | N::String(_)) => true,
        (TYPE_BOOLEAN_ARRAY, N::BoolArray(_)) => true,
        (TYPE_DOUBLE_ARRAY | TYPE_FLOAT_ARRAY | TYPE_INT_ARRAY, N::IntArray(_)) => true,
        (TYPE_DOUBLE_ARRAY | TYPE_FLOAT_ARRAY | TYPE_INT_ARRAY, N::DoubleArray(a)) => {
            a.iter().all(|v| finite(*v))
        }
        (TYPE_STRING_ARRAY, N::StringArray(_)) => true,
        _ => false,
    }
}

fn nums(value: &NtValue) -> Vec<f64> {
    match value {
        NtValue::IntArray(a) => a.iter().map(|&v| v as f64).collect(),
        NtValue::DoubleArray(a) => a.clone(),
        _ => Vec::new(),
    }
}

/// Appends one `[id, ts, typeNum, value]` frame. Returns false (and writes
/// nothing) when the value cannot be represented as the given NT type.
pub fn write_value_frame(w: &mut Writer, id: i64, ts_us: i64, type_str: &str, value: &NtValue) -> bool {
    if !is_publishable(value, type_str) {
        return false;
    }
    let num = type_num(type_str);
    w.write_array_header(4);
    w.write_int(id);
    w.write_int(ts_us);
    w.write_int(i64::from(num));
    match (num, value) {
        (TYPE_BOOLEAN, NtValue::Bool(b)) => w.write_bool(*b),
        (TYPE_DOUBLE, v) => w.write_float64(v.as_f64().unwrap()),
        (TYPE_FLOAT, v) => w.write_float32(v.as_f64().unwrap() as f32),
        (TYPE_INT, NtValue::Int(i)) => w.write_int(*i),
        (TYPE_INT, NtValue::Double(d)) => w.write_int(*d as i64),
        (TYPE_STRING, NtValue::String(s)) => w.write_str(s),
        (TYPE_RAW, NtValue::Raw(b)) => w.write_bin(b),
        (TYPE_RAW, NtValue::String(s)) => w.write_bin(s.as_bytes()),
        (TYPE_BOOLEAN_ARRAY, NtValue::BoolArray(a)) => {
            w.write_array_header(a.len());
            a.iter().for_each(|b| w.write_bool(*b));
        }
        (TYPE_DOUBLE_ARRAY, v) => {
            let a = nums(v);
            w.write_array_header(a.len());
            a.iter().for_each(|f| w.write_float64(*f));
        }
        (TYPE_FLOAT_ARRAY, v) => {
            let a = nums(v);
            w.write_array_header(a.len());
            a.iter().for_each(|f| w.write_float32(*f as f32));
        }
        (TYPE_INT_ARRAY, NtValue::IntArray(a)) => {
            w.write_array_header(a.len());
            a.iter().for_each(|i| w.write_int(*i));
        }
        (TYPE_INT_ARRAY, v) => {
            let a = nums(v);
            w.write_array_header(a.len());
            a.iter().for_each(|f| w.write_int(*f as i64));
        }
        (TYPE_STRING_ARRAY, NtValue::StringArray(a)) => {
            w.write_array_header(a.len());
            a.iter().for_each(|s| w.write_str(s));
        }
        _ => unreachable!("is_publishable admitted {value:?} as {type_str}"),
    }
    true
}

pub fn value_frame(id: i64, ts_us: i64, type_str: &str, value: &NtValue) -> Option<Vec<u8>> {
    let mut w = Writer::default();
    write_value_frame(&mut w, id, ts_us, type_str, value).then(|| w.into_bytes())
}

/// Coerces a decoded value to the announced type, or None when it cannot
/// represent that type.
pub fn coerce(value: MsgValue, type_str: &str) -> Option<NtValue> {
    use MsgValue as M;
    let array = |v: MsgValue| match v {
        M::Array(a) => Some(a),
        _ => None,
    };
    Some(match type_str {
        "boolean" => match value {
            M::Bool(b) => NtValue::Bool(b),
            M::Int(i) => NtValue::Bool(i != 0),
            _ => return None,
        },
        "double" | "float" => match value {
            M::Float(f) => NtValue::Double(f),
            M::Int(i) => NtValue::Double(i as f64),
            _ => return None,
        },
        "int" => match value {
            M::Int(i) => NtValue::Int(i),
            M::Float(f) if f.is_finite() => NtValue::Int(f as i64),
            _ => return None,
        },
        "string" | "json" => match value {
            M::Str(s) => NtValue::String(s),
            M::Bin(b) => NtValue::String(String::from_utf8_lossy(&b).into_owned()),
            _ => return None,
        },
        "double[]" | "float[]" => NtValue::DoubleArray(
            array(value)?
                .into_iter()
                .map(|e| match e {
                    M::Float(f) => Some(f),
                    M::Int(i) => Some(i as f64),
                    _ => None,
                })
                .collect::<Option<_>>()?,
        ),
        "int[]" => NtValue::IntArray(
            array(value)?
                .into_iter()
                .map(|e| match e {
                    M::Int(i) => Some(i),
                    M::Float(f) if f.is_finite() => Some(f as i64),
                    _ => None,
                })
                .collect::<Option<_>>()?,
        ),
        "boolean[]" => NtValue::BoolArray(
            array(value)?
                .into_iter()
                .map(|e| match e {
                    M::Bool(b) => Some(b),
                    _ => None,
                })
                .collect::<Option<_>>()?,
        ),
        "string[]" => NtValue::StringArray(
            array(value)?
                .into_iter()
                .map(|e| match e {
                    M::Str(s) => Some(s),
                    _ => None,
                })
                .collect::<Option<_>>()?,
        ),
        _ => match value {
            M::Bin(b) => NtValue::Raw(b),
            M::Str(s) => NtValue::Raw(s.into_bytes()),
            _ => return None,
        },
    })
}

/// One decoded value frame; the type number is dropped because values are
/// coerced to the announced type.
#[derive(Clone, Debug, PartialEq)]
pub struct Frame {
    pub id: i64,
    pub ts: i64,
    pub value: MsgValue,
}

/// Decodes back-to-back value frames into `out`. Returns the error that
/// stopped decoding; everything decoded before it is kept.
pub fn decode_frames(b: &[u8], out: &mut Vec<Frame>) -> Option<String> {
    let mut r = Reader::new(b);
    while r.p < b.len() {
        let start = r.p;
        match r.read_value() {
            Err(e) => return Some(e),
            Ok(MsgValue::Array(a)) if a.len() == 4 => {
                let mut it = a.into_iter();
                let (Some(MsgValue::Int(id)), Some(MsgValue::Int(ts)), Some(MsgValue::Int(_)), Some(value)) =
                    (it.next(), it.next(), it.next(), it.next())
                else {
                    return Some(format!("malformed value frame at {start}"));
                };
                out.push(Frame { id, ts, value });
            }
            Ok(_) => return Some(format!("malformed value frame at {start}")),
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::super::msgpack::{self, MsgValue as M};
    use super::*;

    #[test]
    fn type_numbers() {
        assert_eq!(type_num("boolean"), 0);
        assert_eq!(type_num("double"), 1);
        assert_eq!(type_num("int"), 2);
        assert_eq!(type_num("float"), 3);
        assert_eq!(type_num("string"), 4);
        assert_eq!(type_num("json"), 4);
        assert_eq!(type_num("raw"), 5);
        assert_eq!(type_num("string[]"), 20);
        assert_eq!(type_num("struct:Pose2d"), 5, "unknown types are raw");
        assert_eq!(type_num("structschema"), 5);
    }

    #[test]
    fn control_messages() {
        let text = encode_text(&[
            subscribe_msg(
                3,
                &["/matchhud/state/".into()],
                &SubOptions {
                    prefix: true,
                    periodic: Some(0.02),
                    ..Default::default()
                },
            ),
            publish_msg(7, "/Shared/X/Request", "string", &Map::new()),
        ]);
        let parsed: Json = serde_json::from_str(&text).unwrap();
        assert_eq!(parsed[0]["method"], "subscribe");
        assert_eq!(parsed[0]["params"]["topics"], json!(["/matchhud/state/"]));
        assert_eq!(parsed[0]["params"]["options"]["periodic"], 0.02);
        assert_eq!(parsed[0]["params"]["options"]["prefix"], true);
        assert_eq!(parsed[1]["params"]["name"], "/Shared/X/Request");
        assert_eq!(parsed[1]["params"]["type"], "string");
        assert!(text.contains("\"properties\":{}"), "publish carries empty properties object: {text}");
    }

    #[test]
    fn parse_announce_converts_ids_to_int() {
        let res = parse_text(r#"[{"method":"announce","params":{"name":"/a","id":12.0,"type":"double","pubuid":4,"properties":{"retained":true}}},{"method":"unannounce","params":{"name":"/b","id":3}}]"#).unwrap();
        assert_eq!(res.len(), 2);
        assert!(res[0].params["id"].is_i64());
        assert_eq!(res[0].int("id"), Some(12));
        assert_eq!(res[0].int("pubuid"), Some(4));
        assert_eq!(res[1].int("id"), Some(3));
    }

    #[test]
    fn parse_bad_text() {
        assert!(parse_text("{nope").is_err());
        assert!(parse_text("{}").is_err(), "object at top level is rejected");
        let ok = parse_text(r#"[1, {"x":1}, {"method":"announce","params":{"id":1,"name":"/a","type":"int"}}]"#).unwrap();
        assert_eq!(ok.len(), 1);
        assert_eq!(ok[0].params["properties"], json!({}));
    }

    #[test]
    fn rtt_frame_shape() {
        assert_eq!(
            msgpack::decode(&rtt_frame(1234567)),
            Ok(M::Array(vec![M::Int(-1), M::Int(0), M::Int(2), M::Int(1234567)]))
        );
    }

    #[test]
    fn value_frames_by_type() {
        use NtValue as N;
        let s = |v: &str| M::Str(v.into());
        let cases: Vec<(&str, NtValue, M)> = vec![
            ("boolean", N::Bool(true), M::Bool(true)),
            ("double", N::Int(3), M::Float(3.0)),
            ("double", N::Int(-1), M::Float(-1.0)),
            ("int", N::Int(42), M::Int(42)),
            ("float", N::Double(1.5), M::Float(1.5)),
            ("string", N::String("Move Forward".into()), s("Move Forward")),
            ("raw", N::Raw(vec![1, 2]), M::Bin(vec![1, 2])),
            ("struct:Pose2d", N::Raw(vec![7]), M::Bin(vec![7])),
            ("double[]", N::DoubleArray(vec![1.0, 2.5]), M::Array(vec![M::Float(1.0), M::Float(2.5)])),
            ("int[]", N::IntArray(vec![1, -2]), M::Array(vec![M::Int(1), M::Int(-2)])),
            ("boolean[]", N::BoolArray(vec![true, false]), M::Array(vec![M::Bool(true), M::Bool(false)])),
            ("string[]", N::StringArray(vec!["a".into(), "b".into()]), M::Array(vec![s("a"), s("b")])),
        ];
        for (t, value, expected) in cases {
            let frame = value_frame(9, 1000, t, &value).unwrap_or_else(|| panic!("encodes {t}"));
            let M::Array(v) = msgpack::decode(&frame).unwrap() else { panic!() };
            assert_eq!(v[0], M::Int(9));
            assert_eq!(v[1], M::Int(1000));
            assert_eq!(v[2], M::Int(i64::from(type_num(t))), "type num for {t}");
            assert_eq!(v[3], expected, "value for {t}");
        }
        let dbl = value_frame(1, 1, "double", &N::Int(0)).unwrap();
        assert_eq!(dbl[dbl.len() - 9], 0xcb, "doubles always go out as float64");
        let flt = value_frame(1, 1, "float", &N::Double(0.5)).unwrap();
        assert_eq!(flt[flt.len() - 5], 0xca, "float topics go out as float32");
    }

    #[test]
    fn unpublishable_values_rejected() {
        use NtValue as N;
        assert!(value_frame(1, 1, "double", &N::Double(f64::NAN)).is_none(), "NaN");
        assert!(value_frame(1, 1, "double", &N::Double(f64::INFINITY)).is_none(), "Inf");
        assert!(value_frame(1, 1, "double", &N::String("x".into())).is_none(), "string as double");
        assert!(value_frame(1, 1, "boolean", &N::Int(1)).is_none(), "int as bool");
        assert!(value_frame(1, 1, "double[]", &N::DoubleArray(vec![1.0, f64::NAN])).is_none(), "NaN element");
        assert!(value_frame(1, 1, "double[]", &N::StringArray(vec!["a".into()])).is_none(), "string array as double[]");
        assert!(value_frame(1, 1, "string", &N::Int(5)).is_none(), "int as string");
    }

    #[test]
    fn coerce_to_announced_type() {
        use NtValue as N;
        assert_eq!(coerce(M::Int(3), "double"), Some(N::Double(3.0)));
        assert_eq!(coerce(M::Float(2.0), "int"), Some(N::Int(2)));
        assert_eq!(coerce(M::Int(1), "boolean"), Some(N::Bool(true)));
        assert_eq!(coerce(M::Array(vec![M::Int(1), M::Int(2)]), "double[]"), Some(N::DoubleArray(vec![1.0, 2.0])));
        assert_eq!(coerce(M::Array(vec![M::Float(1.0), M::Int(2)]), "int[]"), Some(N::IntArray(vec![1, 2])));
        assert_eq!(coerce(M::Array(vec![M::Str("a".into())]), "string[]"), Some(N::StringArray(vec!["a".into()])));
        assert_eq!(coerce(M::Bin(vec![1]), "struct:Pose2d"), Some(N::Raw(vec![1])));
        assert_eq!(coerce(M::Bin(vec![104, 105]), "string"), Some(N::String("hi".into())));
        assert_eq!(coerce(M::Str("x".into()), "double"), None);
        assert_eq!(coerce(M::Array(vec![M::Bool(true), M::Int(1)]), "boolean[]"), None);
    }

    fn sample_frames() -> Vec<M> {
        let f = |id: i64, ts: i64, t: i64, v: M| M::Array(vec![M::Int(id), M::Int(ts), M::Int(t), v]);
        vec![
            f(3, 1794644876875594, 1, M::Float(447.074)),
            f(-1, 123, 2, M::Int(4567)),
            f(300, 4_000_000_000, 2, M::Int(i64::MIN)),
            f(70000, 5, 0, M::Bool(true)),
            f(1, 6, 0, M::Bool(false)),
            f(2, 7, 4, M::Str("fixstr".into())),
            f(4, 8, 4, M::Str("long string ".repeat(5))),
            f(5, 9, 2, M::Int(-5)),
            f(6, 10, 2, M::Int(200)),
            f(7, 11, 2, M::Int(-300)),
            f(8, 12, 2, M::Int(70000)),
            f(9, 13, 2, M::Int(-70000)),
            f(10, 14, 5, M::Bin(vec![1, 2, 3])),
            f(11, 15, 17, M::Array(vec![M::Float(1.0), M::Float(2.5)])),
            f(12, 16, 20, M::Array(vec![M::Str("a".into()), M::Str("b".into())])),
            f(13, 17, 2, M::Int(i64::MAX)),
        ]
    }

    fn encode_all(frames: &[M]) -> Vec<u8> {
        let mut w = Writer::default();
        frames.iter().for_each(|f| w.write_value(f));
        w.into_bytes()
    }

    #[test]
    fn frames_match_generic_decoder() {
        let mut bytes = encode_all(&sample_frames());
        let mut w = Writer::default();
        w.write_array_header(4);
        w.write_int(14);
        w.write_int(18);
        w.write_int(3);
        w.write_float32(0.25);
        bytes.extend_from_slice(w.bytes());
        let mut out = Vec::new();
        assert_eq!(decode_frames(&bytes, &mut out), None);
        let generic = msgpack::decode_all(&bytes).values;
        assert_eq!(out.len(), generic.len());
        for (i, (g, f)) in generic.iter().zip(&out).enumerate() {
            let M::Array(g) = g else { panic!() };
            assert_eq!((M::Int(f.id), M::Int(f.ts), &f.value), (g[0].clone(), g[1].clone(), &g[3]), "frame {i}");
        }
    }

    #[test]
    fn frames_truncated_tail_keeps_prefix() {
        let good = encode_all(&sample_frames()[..3]);
        let tail = encode_all(&[M::Array(vec![M::Int(9), M::Int(1794644876875594), M::Int(1), M::Float(1.5)])]);
        for cut in 1..12 {
            let mut bytes = good.clone();
            bytes.extend_from_slice(&tail[..tail.len() - cut]);
            let mut out = Vec::new();
            assert_eq!(decode_frames(&bytes, &mut out).as_deref(), Some("truncated"), "cut {cut}");
            assert_eq!(out.len(), 3, "prefix kept for cut {cut}");
        }
    }

    #[test]
    fn frames_non_frame_values_rejected() {
        let f = |id: i64, ts: i64, v: f64| M::Array(vec![M::Int(id), M::Int(ts), M::Int(1), M::Float(v)]);
        let bytes = encode_all(&[f(1, 2, 0.5), M::Str("not a frame".into()), f(3, 4, 1.5)]);
        let mut out = Vec::new();
        assert!(decode_frames(&bytes, &mut out).unwrap().starts_with("malformed"));
        assert_eq!(out, vec![Frame { id: 1, ts: 2, value: M::Float(0.5) }]);
    }

    #[test]
    fn frames_empty() {
        let mut out = Vec::new();
        assert_eq!(decode_frames(&[], &mut out), None);
        assert!(out.is_empty());
    }
}
