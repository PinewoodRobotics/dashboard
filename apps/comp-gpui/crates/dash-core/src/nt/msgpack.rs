//! MessagePack as NT4 uses it (core/nt/msgpack.gd). Hand-rolled rather than
//! `rmp` so the decoder keeps Godot's error contract: a corrupt or truncated
//! tail keeps every value decoded before it, a uint64 above `i64::MAX`
//! clamps, and a huge length header fails as "truncated" without allocating.

#[derive(Clone, Debug, PartialEq)]
pub enum MsgValue {
    Nil,
    Bool(bool),
    Int(i64),
    /// float32 and float64 both decode to f64.
    Float(f64),
    Str(String),
    Bin(Vec<u8>),
    Array(Vec<MsgValue>),
    Map(Vec<(MsgValue, MsgValue)>),
    Ext(i8, Vec<u8>),
}

impl From<i64> for MsgValue {
    fn from(v: i64) -> Self {
        MsgValue::Int(v)
    }
}

impl From<f64> for MsgValue {
    fn from(v: f64) -> Self {
        MsgValue::Float(v)
    }
}

impl From<bool> for MsgValue {
    fn from(v: bool) -> Self {
        MsgValue::Bool(v)
    }
}

impl From<&str> for MsgValue {
    fn from(v: &str) -> Self {
        MsgValue::Str(v.to_owned())
    }
}

pub fn encode(v: &MsgValue) -> Vec<u8> {
    let mut w = Writer::default();
    w.write_value(v);
    w.into_bytes()
}

pub fn decode(bytes: &[u8]) -> Result<MsgValue, String> {
    let mut r = Reader::new(bytes);
    let v = r.read_value()?;
    if r.p != bytes.len() {
        return Err("trailing bytes".into());
    }
    Ok(v)
}

/// Back-to-back values. On a corrupt or truncated tail: the values before
/// it, the byte offset where decoding stopped, and the error.
pub struct DecodeAll {
    pub values: Vec<MsgValue>,
    pub error: Option<String>,
    pub offset: usize,
}

pub fn decode_all(bytes: &[u8]) -> DecodeAll {
    let mut r = Reader::new(bytes);
    let mut values = Vec::new();
    while r.p < bytes.len() {
        let start = r.p;
        match r.read_value() {
            Ok(v) => values.push(v),
            Err(e) => {
                return DecodeAll {
                    values,
                    error: Some(e),
                    offset: start,
                };
            }
        }
    }
    DecodeAll {
        values,
        error: None,
        offset: r.p,
    }
}

pub struct Reader<'a> {
    b: &'a [u8],
    pub p: usize,
}

const TRUNCATED: &str = "truncated";

impl<'a> Reader<'a> {
    pub fn new(b: &'a [u8]) -> Self {
        Self { b, p: 0 }
    }

    fn take(&mut self, k: usize) -> Result<&'a [u8], String> {
        if self.b.len() - self.p < k {
            return Err(TRUNCATED.into());
        }
        let s = &self.b[self.p..self.p + k];
        self.p += k;
        Ok(s)
    }

    fn uint(&mut self, k: usize) -> Result<u64, String> {
        Ok(self
            .take(k)?
            .iter()
            .fold(0u64, |v, &b| (v << 8) | u64::from(b)))
    }

    fn sint(&mut self, k: usize) -> Result<i64, String> {
        let v = self.uint(k)?;
        let shift = 64 - 8 * k as u32;
        Ok(((v << shift) as i64) >> shift)
    }

    fn len(&mut self, k: usize) -> Result<usize, String> {
        Ok(self.uint(k)? as usize)
    }

    fn str(&mut self, n: usize) -> Result<MsgValue, String> {
        Ok(MsgValue::Str(
            String::from_utf8_lossy(self.take(n)?).into_owned(),
        ))
    }

    fn bin(&mut self, n: usize) -> Result<MsgValue, String> {
        Ok(MsgValue::Bin(self.take(n)?.to_vec()))
    }

    fn array(&mut self, n: usize) -> Result<MsgValue, String> {
        if n > self.b.len() - self.p {
            return Err(TRUNCATED.into());
        }
        let mut a = Vec::with_capacity(n);
        for _ in 0..n {
            a.push(self.read_value()?);
        }
        Ok(MsgValue::Array(a))
    }

    fn map(&mut self, n: usize) -> Result<MsgValue, String> {
        if n.saturating_mul(2) > self.b.len() - self.p {
            return Err(TRUNCATED.into());
        }
        let mut m = Vec::with_capacity(n);
        for _ in 0..n {
            let k = self.read_value()?;
            let v = self.read_value()?;
            m.push((k, v));
        }
        Ok(MsgValue::Map(m))
    }

    fn ext(&mut self, n: usize) -> Result<MsgValue, String> {
        let t = self.sint(1)? as i8;
        Ok(MsgValue::Ext(t, self.take(n)?.to_vec()))
    }

    pub fn read_value(&mut self) -> Result<MsgValue, String> {
        let t = *self.take(1)?.first().unwrap();
        Ok(match t {
            0x00..=0x7f => MsgValue::Int(i64::from(t)),
            0xe0..=0xff => MsgValue::Int(i64::from(t) - 256),
            0xa0..=0xbf => return self.str(usize::from(t & 0x1f)),
            0x90..=0x9f => return self.array(usize::from(t & 0x0f)),
            0x80..=0x8f => return self.map(usize::from(t & 0x0f)),
            0xc0 => MsgValue::Nil,
            0xc2 => MsgValue::Bool(false),
            0xc3 => MsgValue::Bool(true),
            0xcc => MsgValue::Int(self.uint(1)? as i64),
            0xcd => MsgValue::Int(self.uint(2)? as i64),
            0xce => MsgValue::Int(self.uint(4)? as i64),
            0xcf => MsgValue::Int(i64::try_from(self.uint(8)?).unwrap_or(i64::MAX)),
            0xd0 => MsgValue::Int(self.sint(1)?),
            0xd1 => MsgValue::Int(self.sint(2)?),
            0xd2 => MsgValue::Int(self.sint(4)?),
            0xd3 => MsgValue::Int(self.sint(8)?),
            0xca => {
                let b = self.take(4)?;
                MsgValue::Float(f64::from(f32::from_be_bytes(b.try_into().unwrap())))
            }
            0xcb => {
                let b = self.take(8)?;
                MsgValue::Float(f64::from_be_bytes(b.try_into().unwrap()))
            }
            0xd9 => {
                let n = self.len(1)?;
                return self.str(n);
            }
            0xda => {
                let n = self.len(2)?;
                return self.str(n);
            }
            0xdb => {
                let n = self.len(4)?;
                return self.str(n);
            }
            0xc4 => {
                let n = self.len(1)?;
                return self.bin(n);
            }
            0xc5 => {
                let n = self.len(2)?;
                return self.bin(n);
            }
            0xc6 => {
                let n = self.len(4)?;
                return self.bin(n);
            }
            0xdc => {
                let n = self.len(2)?;
                return self.array(n);
            }
            0xdd => {
                let n = self.len(4)?;
                return self.array(n);
            }
            0xde => {
                let n = self.len(2)?;
                return self.map(n);
            }
            0xdf => {
                let n = self.len(4)?;
                return self.map(n);
            }
            0xd4 => return self.ext(1),
            0xd5 => return self.ext(2),
            0xd6 => return self.ext(4),
            0xd7 => return self.ext(8),
            0xd8 => return self.ext(16),
            0xc7 => {
                let n = self.len(1)?;
                return self.ext(n);
            }
            0xc8 => {
                let n = self.len(2)?;
                return self.ext(n);
            }
            0xc9 => {
                let n = self.len(4)?;
                return self.ext(n);
            }
            _ => return Err(format!("invalid byte 0x{t:02x} at {}", self.p - 1)),
        })
    }
}

#[derive(Default)]
pub struct Writer {
    b: Vec<u8>,
}

impl Writer {
    pub fn bytes(&self) -> &[u8] {
        &self.b
    }

    pub fn into_bytes(self) -> Vec<u8> {
        self.b
    }

    pub fn write_nil(&mut self) {
        self.b.push(0xc0);
    }

    pub fn write_bool(&mut self, v: bool) {
        self.b.push(if v { 0xc3 } else { 0xc2 });
    }

    pub fn write_int(&mut self, v: i64) {
        let b = &mut self.b;
        if v >= 0 {
            match v {
                0..=0x7f => b.push(v as u8),
                0x80..=0xff => b.extend_from_slice(&[0xcc, v as u8]),
                0x100..=0xffff => {
                    b.push(0xcd);
                    b.extend_from_slice(&(v as u16).to_be_bytes());
                }
                0x1_0000..=0xffff_ffff => {
                    b.push(0xce);
                    b.extend_from_slice(&(v as u32).to_be_bytes());
                }
                _ => {
                    b.push(0xcf);
                    b.extend_from_slice(&(v as u64).to_be_bytes());
                }
            }
        } else if v >= -32 {
            b.push(v as u8);
        } else if v >= -128 {
            b.extend_from_slice(&[0xd0, v as i8 as u8]);
        } else if v >= -32768 {
            b.push(0xd1);
            b.extend_from_slice(&(v as i16).to_be_bytes());
        } else if v >= -2_147_483_648 {
            b.push(0xd2);
            b.extend_from_slice(&(v as i32).to_be_bytes());
        } else {
            b.push(0xd3);
            b.extend_from_slice(&v.to_be_bytes());
        }
    }

    pub fn write_float64(&mut self, v: f64) {
        self.b.push(0xcb);
        self.b.extend_from_slice(&v.to_be_bytes());
    }

    pub fn write_float32(&mut self, v: f32) {
        self.b.push(0xca);
        self.b.extend_from_slice(&v.to_be_bytes());
    }

    fn write_len(&mut self, n: usize, fix: Option<(u8, usize)>, tags: [u8; 3]) {
        let b = &mut self.b;
        match fix {
            Some((base, max)) if n <= max => b.push(base | n as u8),
            _ if n <= 0xff && tags[0] != 0 => b.extend_from_slice(&[tags[0], n as u8]),
            _ if n <= 0xffff => {
                b.push(tags[1]);
                b.extend_from_slice(&(n as u16).to_be_bytes());
            }
            _ => {
                b.push(tags[2]);
                b.extend_from_slice(&(n as u32).to_be_bytes());
            }
        }
    }

    pub fn write_str(&mut self, v: &str) {
        self.write_len(v.len(), Some((0xa0, 31)), [0xd9, 0xda, 0xdb]);
        self.b.extend_from_slice(v.as_bytes());
    }

    pub fn write_bin(&mut self, v: &[u8]) {
        self.write_len(v.len(), None, [0xc4, 0xc5, 0xc6]);
        self.b.extend_from_slice(v);
    }

    pub fn write_array_header(&mut self, n: usize) {
        self.write_len(n, Some((0x90, 15)), [0, 0xdc, 0xdd]);
    }

    pub fn write_map_header(&mut self, n: usize) {
        self.write_len(n, Some((0x80, 15)), [0, 0xde, 0xdf]);
    }

    pub fn write_value(&mut self, v: &MsgValue) {
        match v {
            MsgValue::Nil => self.write_nil(),
            MsgValue::Bool(b) => self.write_bool(*b),
            MsgValue::Int(i) => self.write_int(*i),
            MsgValue::Float(f) => self.write_float64(*f),
            MsgValue::Str(s) => self.write_str(s),
            MsgValue::Bin(b) => self.write_bin(b),
            MsgValue::Array(a) => {
                self.write_array_header(a.len());
                for e in a {
                    self.write_value(e);
                }
            }
            MsgValue::Map(m) => {
                self.write_map_header(m.len());
                for (k, e) in m {
                    self.write_value(k);
                    self.write_value(e);
                }
            }
            MsgValue::Ext(t, data) => {
                match data.len() {
                    1 => self.b.push(0xd4),
                    2 => self.b.push(0xd5),
                    4 => self.b.push(0xd6),
                    8 => self.b.push(0xd7),
                    16 => self.b.push(0xd8),
                    n => self.write_len(n, None, [0xc7, 0xc8, 0xc9]),
                }
                self.b.push(*t as u8);
                self.b.extend_from_slice(data);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::MsgValue as V;
    use super::*;

    fn dec(b: &[u8]) -> V {
        decode(b).unwrap_or_else(|e| panic!("decode error {e} for {b:02x?}"))
    }

    fn arr(v: Vec<V>) -> V {
        V::Array(v)
    }

    #[test]
    fn nil_and_bool() {
        assert_eq!(dec(&[0xc0]), V::Nil);
        assert_eq!(dec(&[0xc2]), V::Bool(false));
        assert_eq!(dec(&[0xc3]), V::Bool(true));
    }

    #[test]
    fn fixints() {
        assert_eq!(dec(&[0x00]), V::Int(0));
        assert_eq!(dec(&[0x7f]), V::Int(127));
        assert_eq!(dec(&[0xff]), V::Int(-1));
        assert_eq!(dec(&[0xe0]), V::Int(-32));
    }

    #[test]
    fn unsigned_ints() {
        assert_eq!(dec(&[0xcc, 0xff]), V::Int(255));
        assert_eq!(dec(&[0xcd, 0x01, 0x00]), V::Int(256));
        assert_eq!(dec(&[0xcd, 0xff, 0xff]), V::Int(65535));
        assert_eq!(dec(&[0xce, 0xff, 0xff, 0xff, 0xff]), V::Int(4294967295));
        assert_eq!(dec(&[0xcf, 0, 0, 0, 1, 0, 0, 0, 0]), V::Int(4294967296));
        assert_eq!(
            dec(&[0xcf, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]),
            V::Int(i64::MAX)
        );
        assert_eq!(dec(&[0xcf, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]), V::Int(i64::MAX), "uint64 max clamps");
    }

    #[test]
    fn signed_ints() {
        assert_eq!(dec(&[0xd0, 0x80]), V::Int(-128));
        assert_eq!(dec(&[0xd0, 0x7f]), V::Int(127));
        assert_eq!(dec(&[0xd1, 0x80, 0x00]), V::Int(-32768));
        assert_eq!(dec(&[0xd2, 0x80, 0, 0, 0]), V::Int(-2147483648));
        assert_eq!(dec(&[0xd2, 0xff, 0xff, 0xff, 0xfe]), V::Int(-2));
        assert_eq!(dec(&[0xd3, 0x80, 0, 0, 0, 0, 0, 0, 0]), V::Int(i64::MIN));
        assert_eq!(
            dec(&[0xd3, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]),
            V::Int(i64::MAX)
        );
        assert_eq!(
            dec(&[0xd3, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]),
            V::Int(-1)
        );
    }

    #[test]
    fn floats() {
        assert_eq!(dec(&[0xca, 0x3f, 0xc0, 0x00, 0x00]), V::Float(1.5));
        assert_eq!(dec(&[0xca, 0xc0, 0x20, 0x00, 0x00]), V::Float(-2.5));
        assert_eq!(
            dec(&[0xcb, 0x40, 0x09, 0x21, 0xfb, 0x54, 0x44, 0x2d, 0x18]),
            V::Float(std::f64::consts::PI)
        );
        assert_eq!(dec(&[0xcb, 0xbf, 0xf0, 0, 0, 0, 0, 0, 0]), V::Float(-1.0));
    }

    #[test]
    fn strings() {
        assert_eq!(dec(&[0xa0]), V::Str(String::new()));
        assert_eq!(dec(&[0xa3, 0x61, 0x62, 0x63]), V::Str("abc".into()));
        let long = "x".repeat(40);
        let mut b = vec![0xd9, 40];
        b.extend_from_slice(long.as_bytes());
        assert_eq!(dec(&b), V::Str(long));
        let utf = "Höhe°";
        let mut b = vec![0xa0 | utf.len() as u8];
        b.extend_from_slice(utf.as_bytes());
        assert_eq!(dec(&b), V::Str(utf.into()));
        let big = "y".repeat(300);
        let mut b = vec![0xda, 0x01, 0x2c];
        b.extend_from_slice(big.as_bytes());
        assert_eq!(dec(&b), V::Str(big));
    }

    #[test]
    fn bin() {
        assert_eq!(dec(&[0xc4, 0x03, 1, 2, 3]), V::Bin(vec![1, 2, 3]));
        assert_eq!(dec(&[0xc4, 0x00]), V::Bin(vec![]));
        let mut b = vec![0xc5, 0x01, 0x00];
        b.extend(0..=255u8);
        let V::Bin(v) = dec(&b) else { panic!() };
        assert_eq!(v.len(), 256);
        assert_eq!(v[255], 255);
    }

    #[test]
    fn arrays_and_maps() {
        assert_eq!(dec(&[0x90]), arr(vec![]));
        assert_eq!(
            dec(&[0x93, 0x01, 0xc3, 0xa1, 0x7a]),
            arr(vec![V::Int(1), V::Bool(true), V::Str("z".into())])
        );
        assert_eq!(
            dec(&[0x92, 0x91, 0x01, 0x90]),
            arr(vec![arr(vec![V::Int(1)]), arr(vec![])])
        );
        let mut b = vec![0xdc, 0x00, 0x11];
        b.extend(0..17u8);
        let V::Array(a) = dec(&b) else { panic!() };
        assert_eq!(a.len(), 17);
        assert_eq!(
            dec(&[0x81, 0xa1, 0x61, 0x02]),
            V::Map(vec![(V::Str("a".into()), V::Int(2))])
        );
    }

    #[test]
    fn nt_value_frame_shape() {
        let b = [
            0x94, 0x05, 0xce, 0x07, 0x5b, 0xcd, 0x15, 0x01, 0xcb, 0x40, 0x04, 0, 0, 0, 0, 0, 0,
        ];
        assert_eq!(
            dec(&b),
            arr(vec![V::Int(5), V::Int(123456789), V::Int(1), V::Float(2.5)])
        );
    }

    fn frame(id: i64, ts: i64, t: i64, v: V) -> V {
        arr(vec![V::Int(id), V::Int(ts), V::Int(t), v])
    }

    #[test]
    fn concatenated_values() {
        let mut w = Writer::default();
        w.write_value(&frame(1, 100, 2, V::Int(7)));
        w.write_value(&frame(2, 101, 0, V::Bool(true)));
        w.write_value(&frame(3, 102, 4, "hello".into()));
        w.write_value(&frame(-1, 5000, 2, V::Int(4000)));
        let res = decode_all(w.bytes());
        assert_eq!(res.error, None);
        assert_eq!(res.values.len(), 4);
        assert_eq!(res.values[2], frame(3, 102, 4, "hello".into()));
        assert_eq!(res.values[3], frame(-1, 5000, 2, V::Int(4000)));
        assert_eq!(res.offset, w.bytes().len());
    }

    #[test]
    fn corrupt_tail_keeps_prefix() {
        let mut w = Writer::default();
        w.write_value(&frame(1, 100, 1, V::Float(1.25)));
        w.write_value(&frame(2, 200, 4, "ok".into()));
        let good = w.into_bytes();
        let mut truncated = good.clone();
        truncated.extend_from_slice(&[0x94, 0x03, 0xcd, 0x01]);
        let res = decode_all(&truncated);
        assert_eq!(res.values.len(), 2, "prefix values");
        assert_eq!(res.values[0], frame(1, 100, 1, V::Float(1.25)));
        assert_eq!(res.error.as_deref(), Some("truncated"));
        assert_eq!(res.offset, good.len());
        let mut invalid = good.clone();
        invalid.push(0xc1);
        let res2 = decode_all(&invalid);
        assert_eq!(res2.values.len(), 2);
        assert!(res2.error.unwrap().starts_with("invalid byte"));
        let mut huge = good.clone();
        huge.extend_from_slice(&[0xdd, 0x7f, 0xff, 0xff, 0xff]);
        let res3 = decode_all(&huge);
        assert_eq!(res3.values.len(), 2, "huge array header does not allocate");
        assert_eq!(res3.error.as_deref(), Some("truncated"));
    }

    #[test]
    fn truncated_scalars() {
        for b in [
            &[0xcd, 0x01][..],
            &[0xcb, 0x40, 0x09],
            &[0xa5, 0x61],
            &[0xc4, 0x05, 1],
            &[0xd3, 0, 0],
        ] {
            assert_eq!(decode(b), Err("truncated".into()), "for {b:02x?}");
        }
    }

    #[test]
    fn encoder_int_widths() {
        assert_eq!(encode(&V::Int(5)), vec![0x05]);
        assert_eq!(encode(&V::Int(-1)), vec![0xff]);
        assert_eq!(encode(&V::Int(200)), vec![0xcc, 200]);
        assert_eq!(encode(&V::Int(-100)), vec![0xd0, 0x9c]);
        assert_eq!(encode(&V::Int(70000)), vec![0xce, 0x00, 0x01, 0x11, 0x70]);
        for v in [
            0,
            1,
            127,
            128,
            255,
            256,
            65535,
            65536,
            4294967295,
            4294967296,
            i64::MAX,
            -1,
            -32,
            -33,
            -128,
            -129,
            -32768,
            -32769,
            -2147483648,
            -2147483649,
            i64::MIN,
        ] {
            assert_eq!(decode(&encode(&V::Int(v))), Ok(V::Int(v)), "round trip {v}");
        }
    }

    #[test]
    fn encoder_doubles_always_float64() {
        assert_eq!(encode(&V::Float(0.0)), vec![0xcb, 0, 0, 0, 0, 0, 0, 0, 0]);
        assert_eq!(encode(&V::Float(-1.0))[0], 0xcb);
        let mut w = Writer::default();
        w.write_float32(1.5);
        assert_eq!(w.bytes(), &[0xca, 0x3f, 0xc0, 0x00, 0x00]);
        assert_eq!(decode(&encode(&V::Float(0.1))), Ok(V::Float(0.1)));
    }

    #[test]
    fn encoder_round_trip_mixed() {
        let v = arr(vec![
            V::Int(1),
            V::Int(-2),
            V::Float(3.25),
            "s".into(),
            V::Bool(true),
            V::Nil,
            V::Bin(vec![9, 8]),
            arr(vec![V::Int(1), arr(vec![V::Int(2), V::Str("x".repeat(70000))])]),
            V::Map(vec![("k".into(), V::Int(1))]),
            V::Ext(3, vec![1, 2, 3]),
        ]);
        assert_eq!(decode(&encode(&v)), Ok(v));
    }
}
