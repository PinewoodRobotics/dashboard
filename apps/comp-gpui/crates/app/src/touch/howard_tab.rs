use std::sync::OnceLock;

use gpui_kit::prelude::FluentBuilder;
use gpui_kit::*;

use super::TouchScreen;
use crate::theme::{
    BLACK, INTER, PANEL, WHITE, ZINC_300, ZINC_500, ZINC_800, alpha, hex, touch_weight, u,
};
use crate::widgets::{press_state, tappable};

const PAD: f32 = 16.0;
const RADIUS: f32 = 6.0;
const ZINC_950: Rgba = hex(0x09090b);
/// The picture the Godot `touch_tab_howard` fixture shows, so frozen
/// fixtures render the same frame as the reference shots.
const FIXTURE_INDEX: usize = 1;

const PICTURES: [(&str, &[u8]); 12] = [
    (
        "howard/Amused.webp",
        include_bytes!("../../assets/howard/Amused.webp"),
    ),
    (
        "howard/Boba.webp",
        include_bytes!("../../assets/howard/Boba.webp"),
    ),
    (
        "howard/Carry.webp",
        include_bytes!("../../assets/howard/Carry.webp"),
    ),
    (
        "howard/Cookie.webp",
        include_bytes!("../../assets/howard/Cookie.webp"),
    ),
    (
        "howard/Email.webp",
        include_bytes!("../../assets/howard/Email.webp"),
    ),
    (
        "howard/FunnyNumber.webp",
        include_bytes!("../../assets/howard/FunnyNumber.webp"),
    ),
    (
        "howard/Glare.webp",
        include_bytes!("../../assets/howard/Glare.webp"),
    ),
    (
        "howard/History.webp",
        include_bytes!("../../assets/howard/History.webp"),
    ),
    (
        "howard/Photography.webp",
        include_bytes!("../../assets/howard/Photography.webp"),
    ),
    (
        "howard/Scroll.webp",
        include_bytes!("../../assets/howard/Scroll.webp"),
    ),
    (
        "howard/Shocked.webp",
        include_bytes!("../../assets/howard/Shocked.webp"),
    ),
    (
        "howard/Watch.webp",
        include_bytes!("../../assets/howard/Watch.webp"),
    ),
];

const ENTRIES_JSON: &str = include_str!("../../assets/howard/howard.json");

#[derive(Clone, Debug, PartialEq)]
pub struct Entry {
    pub image: SharedString,
    /// The failed-preview line (PathDetailPane.tsx).
    pub text: SharedString,
    /// The Howard tab caption.
    pub happy_text: SharedString,
}

pub fn asset(path: &str) -> Option<&'static [u8]> {
    PICTURES.iter().find(|(p, _)| *p == path).map(|(_, b)| *b)
}

pub fn entries() -> &'static [Entry] {
    static ENTRIES: OnceLock<Vec<Entry>> = OnceLock::new();
    ENTRIES.get_or_init(|| parse_entries(ENTRIES_JSON))
}

fn parse_entries(json: &str) -> Vec<Entry> {
    let parsed: serde_json::Value = serde_json::from_str(json).unwrap_or_default();
    let field = |e: &serde_json::Value, k: &str| -> SharedString {
        e.get(k)
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_owned()
            .into()
    };
    parsed
        .as_array()
        .map(|a| {
            a.iter()
                .map(|e| Entry {
                    image: field(e, "image"),
                    text: field(e, "text"),
                    happy_text: field(e, "happy_text"),
                })
                .collect()
        })
        .unwrap_or_default()
}

/// A different index than `current` whenever there is more than one picture;
/// `current` of `None` picks any. `r` is a uniform random number.
pub fn pick_other(current: Option<usize>, count: usize, r: u64) -> usize {
    if count <= 1 {
        return 0;
    }
    match current {
        Some(c) if c < count => {
            let i = (r % (count as u64 - 1)) as usize;
            if i >= c { i + 1 } else { i }
        }
        _ => (r % count as u64) as usize,
    }
}

/// xorshift64*, seeded from the clock: enough to shuffle pictures.
#[derive(Clone, Copy, Debug)]
pub struct Rng(u64);

impl Rng {
    pub fn from_clock() -> Self {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos() as u64)
            .unwrap_or(0x9e37_79b9_7f4a_7c15);
        Self(nanos | 1)
    }

    pub fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545_f491_4f6c_dd1d)
    }
}

struct HowardState {
    index: Option<usize>,
    rng: Rng,
}

/// HowardTab.tsx: a third-width column with the title, the picture's caption
/// and "More Howard", and the picture letterboxed in a rounded box beside it.
pub fn render(
    ts: &TouchScreen,
    key: u64,
    window: &mut Window,
    cx: &mut Context<TouchScreen>,
) -> impl IntoElement {
    let list = entries();
    let demo = ts.data.read(cx).demo;
    let state = window.use_keyed_state(("howard", key), cx, move |_, _| {
        let mut rng = Rng::from_clock();
        let index = if list.is_empty() {
            None
        } else if demo {
            Some(pick_other(None, list.len(), rng.next()))
        } else {
            Some(FIXTURE_INDEX.min(list.len() - 1))
        };
        HowardState { index, rng }
    });
    let Some(entry) = state.read(cx).index.and_then(|i| list.get(i)) else {
        return div()
            .size_full()
            .bg(PANEL)
            .flex()
            .items_center()
            .justify_center()
            .font_family(INTER)
            .text_size(u(34.))
            .line_height(u(51.))
            .text_color(ZINC_500)
            .child("Loading...");
    };

    let more_state = state.clone();
    let more = more_button(key, window, cx, move |_, cx| {
        more_state.update(cx, |s, cx| {
            let r = s.rng.next();
            s.index = Some(pick_other(s.index, list.len(), r));
            cx.notify();
        });
    });

    let text_col = div()
        .flex()
        .flex_col()
        .gap(u(10.))
        .font_family(INTER)
        .child(
            div()
                .text_size(u(34.))
                .line_height(u(34.))
                .font_weight(touch_weight(600))
                .text_color(WHITE)
                .child("Pictures of Howard"),
        )
        .child(
            div()
                .id("howard-caption")
                .text_size(u(22.))
                .line_height(u(26.4))
                .text_color(ZINC_300)
                .child(entry.happy_text.clone()),
        );

    div()
        .size_full()
        .flex()
        .bg(PANEL)
        .child(
            div()
                .flex_none()
                .w(relative(1. / 3.))
                .h_full()
                .p(u(PAD))
                .flex()
                .flex_col()
                .justify_between()
                .items_start()
                .child(text_col)
                .child(more),
        )
        .child(
            div()
                .flex_1()
                .min_w_0()
                .h_full()
                .p(u(PAD))
                .child(image_box(entry, PANEL)),
        )
}

fn more_button(
    key: u64,
    window: &mut Window,
    cx: &mut App,
    on_tap: impl Fn(&mut Window, &mut App) + 'static,
) -> impl IntoElement {
    let id = ElementId::from(("howard-more", key as usize));
    let state = press_state(id.clone(), window, cx);
    let pressed = state.read(cx).pressed;
    let el = div()
        .id(id)
        .flex_none()
        .px(u(10.))
        .py(u(4.))
        .bg(if pressed { ZINC_800 } else { BLACK })
        .font_family(INTER)
        .text_size(u(34.))
        .line_height(u(34.))
        .text_color(WHITE)
        .whitespace_nowrap()
        .child("More Howard");
    tappable(el, state, false, crate::widgets::on_tap(on_tap))
}
/// rounded-md bg-zinc-950 overflow-hidden: the box both the Howard tab and
/// the Auto tab's failed preview letterbox their picture in.
fn picture_box() -> Div {
    div()
        .relative()
        .size_full()
        .rounded(u(RADIUS))
        .overflow_hidden()
        .bg(ZINC_950)
}

fn picture(image: SharedString) -> Img {
    img(image)
        .absolute()
        .inset_0()
        .size_full()
        .object_fit(ObjectFit::Contain)
}

/// ImageBox: the picture letterboxed in [`picture_box`]. A picture that fails
/// to load shows the failed-preview card instead.
pub fn image_box(entry: &Entry, _outside: Rgba) -> impl IntoElement {
    let failed = entry.clone();
    picture_box().child(
        picture(entry.image.clone())
            .rounded(u(RADIUS))
            .with_fallback(move || unhappy_card(&failed.text).into_any_element()),
    )
}

/// HowardError (PathDetailPane.tsx's failed preview): a random picture of
/// Howard letterboxed in [`picture_box`], with a black/60 caption box
/// centered on it holding "Failed to load preview", the picture's unhappy
/// line and the small print. `roll` picks the picture; re-roll it for every
/// failed auto.
pub fn howard_error(roll: u64) -> impl IntoElement {
    let list = entries();
    let entry = (!list.is_empty()).then(|| &list[(roll % list.len() as u64) as usize]);
    let line: SharedString = entry
        .map(|e| e.text.clone())
        .unwrap_or_else(|| "Howard is unhappy now".into());
    picture_box()
        .when_some(entry, |d, e| d.child(picture(e.image.clone())))
        .child(unhappy_card(&line))
}

const SMALL_PRINT: &str =
    "The error does not mean the auto is broken, you can select it and it'll probably still work?";

fn unhappy_card(line: &SharedString) -> impl IntoElement {
    let centered = |size: f32, lh: f32| {
        div()
            .w_full()
            .flex()
            .justify_center()
            .text_center()
            .text_size(u(size))
            .line_height(u(lh))
    };
    let not = SMALL_PRINT.find(" not ").map_or(0..0, |i| i + 1..i + 4);
    let small_print = StyledText::new(SMALL_PRINT).with_highlights(vec![(
        not,
        HighlightStyle {
            font_weight: Some(FontWeight::BOLD),
            font_style: Some(FontStyle::Italic),
            ..Default::default()
        },
    )]);
    div()
        .absolute()
        .inset_0()
        .px(u(12.))
        .flex()
        .items_center()
        .justify_center()
        .font_family(INTER)
        .font_weight(touch_weight(600))
        .text_color(WHITE)
        .child(
            div()
                .flex()
                .flex_col()
                .px(u(12.))
                .py(u(4.))
                .bg(alpha(BLACK, 0.6))
                .child(centered(28., 42.).child("Failed to load preview"))
                .child(centered(18., 28.).child(line.clone()))
                .child(centered(12., 12.).mt(u(8.)).child(small_print)),
        )
}

#[cfg(test)]
mod tests {
    use super::{Rng, asset, entries, pick_other};

    #[test]
    fn entries_parse_with_assets() {
        let e = entries();
        assert_eq!(e.len(), 12);
        assert_eq!(
            e[1].happy_text.as_ref(),
            "Howard looking at two cups of boba"
        );
        for entry in e {
            assert!(asset(&entry.image).is_some(), "{} is embedded", entry.image);
            assert!(!entry.text.is_empty() && !entry.happy_text.is_empty());
        }
    }

    #[test]
    fn pick_other_never_repeats() {
        for count in 2..6 {
            for current in 0..count {
                let mut seen = vec![false; count];
                for r in 0..64 {
                    let i = pick_other(Some(current), count, r);
                    assert!(i < count);
                    assert_ne!(i, current, "count {count} current {current} r {r}");
                    seen[i] = true;
                }
                let others = seen
                    .iter()
                    .enumerate()
                    .filter(|(i, s)| *i != current && **s)
                    .count();
                assert_eq!(others, count - 1, "every other picture is reachable");
            }
        }
    }

    #[test]
    fn pick_other_edges() {
        assert_eq!(pick_other(None, 0, 7), 0);
        assert_eq!(pick_other(Some(0), 1, 7), 0, "one picture: itself");
        assert!(pick_other(None, 5, 9) < 5);
        assert!(
            pick_other(Some(9), 5, 9) < 5,
            "out of range current picks any"
        );
    }

    #[test]
    fn rng_tap_sequence_always_changes() {
        let mut rng = Rng(42);
        let mut i = Some(1);
        for _ in 0..100 {
            let next = pick_other(i, 12, rng.next());
            assert_ne!(Some(next), i);
            i = Some(next);
        }
    }
}
