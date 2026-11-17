//! PwKeyboard (comp-godot ui/widgets/pw_keyboard.gd): the in-app on-screen
//! keyboard. A touch kiosk on Windows has no usable system keyboard, so each
//! window that mounts [`layer`] gets one bottom sheet, opened by any
//! [`super::TextInput`] in that window. It shows the field being edited, a
//! text layout with a one-shot shift or a numeric keypad, and takes physical
//! keys while open. Edits apply live; Done, Enter, Escape or a tap outside
//! the sheet closes it and submits.

use std::collections::HashMap;
use std::rc::Rc;

use gpui_kit::*;

use super::tap::{press_state, tappable};
use super::{OnChange, tracked};
use crate::icons::lucide;
use crate::input::{self, Phase};
use crate::theme::{self, ACCENT, BLACK, BORDER, WHITE, ZINC_400, ZINC_600, ZINC_800, alpha, u};

pub const KEY_H: f32 = 46.0;
pub const KEY_GAP: f32 = 6.0;
pub const PAD: f32 = 10.0;
pub const HEADER_H: f32 = 56.0;
const KEY_PX: f32 = 22.0;
const KEYPAD_W: f32 = 560.0;
const KEYPAD_DONE_W: f32 = 120.0;
const KEYPAD_DONE_GAP: f32 = 10.0;
const MAX_SHEET_W: f32 = 1200.0;
const SHEET_MARGIN: f32 = 40.0;
const PREVIEW_PX: f32 = 26.0;
pub const MAX_LENGTH: usize = 64;

const ROWS: &[&[&str]] = &[
    &["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-"],
    &["q", "w", "e", "r", "t", "y", "u", "i", "o", "p", "/"],
    &["a", "s", "d", "f", "g", "h", "j", "k", "l", ".", ":"],
    &["SHIFT", "z", "x", "c", "v", "b", "n", "m", "_", "BKSP"],
    &["SPACE", "DONE"],
];
const PAD_ROWS: &[&[&str]] = &[
    &["1", "2", "3"],
    &["4", "5", "6"],
    &["7", "8", "9"],
    &["CLEAR", "0", "BKSP"],
];

/// PwTextInput.filter: digits only for numeric fields, never a line break
/// or tab.
pub fn filter(s: &str, digits_only: bool) -> String {
    if digits_only {
        s.chars().filter(char::is_ascii_digit).collect()
    } else {
        s.chars().filter(|c| *c != '\n' && *c != '\t').collect()
    }
}

/// The text a field takes after an edit: filtered, then cut to its length.
pub fn accept(s: &str, numeric: bool, max_length: usize) -> String {
    filter(s, numeric).chars().take(max_length).collect()
}

fn units(k: &str, numeric: bool) -> f32 {
    match k {
        "SPACE" => 8.0,
        "DONE" => 2.0,
        "SHIFT" | "BKSP" if !numeric => 1.5,
        _ => 1.0,
    }
}

/// Where the sheet sits in a window of `size` design pixels.
pub fn sheet_rect(numeric: bool, size: Size<f32>) -> Bounds<f32> {
    let rows = if numeric { PAD_ROWS.len() } else { ROWS.len() } as f32;
    let h = PAD * 2.0 + HEADER_H + rows * KEY_H + (rows - 1.0) * KEY_GAP;
    let w = if numeric {
        KEYPAD_W
    } else {
        (size.width - SHEET_MARGIN).min(MAX_SHEET_W)
    };
    Bounds::new(
        point((size.width - w) * 0.5, size.height - h),
        gpui_kit::size(w, h),
    )
}

/// Every key and its rect inside the sheet.
pub fn layout(numeric: bool, size: Size<f32>) -> Vec<(&'static str, Bounds<f32>)> {
    let sheet = sheet_rect(numeric, size);
    let rows = if numeric { PAD_ROWS } else { ROWS };
    let top = PAD + HEADER_H;
    let mut avail = sheet.size.width - PAD * 2.0;
    if numeric {
        avail -= KEYPAD_DONE_W + KEYPAD_DONE_GAP;
    }
    let mut out = Vec::new();
    for (ri, row) in rows.iter().enumerate() {
        let total: f32 = row.iter().map(|k| units(k, numeric)).sum();
        let unit_w = (avail - KEY_GAP * (row.len() as f32 - 1.0)) / total;
        let mut x = PAD;
        for k in row.iter() {
            let w = unit_w * units(k, numeric);
            out.push((
                *k,
                Bounds::new(
                    point(x, top + ri as f32 * (KEY_H + KEY_GAP)),
                    gpui_kit::size(w, KEY_H),
                ),
            ));
            x += w + KEY_GAP;
        }
    }
    if numeric {
        let n = rows.len() as f32;
        out.push((
            "DONE",
            Bounds::new(
                point(sheet.size.width - PAD - KEYPAD_DONE_W, top),
                gpui_kit::size(KEYPAD_DONE_W, n * KEY_H + (n - 1.0) * KEY_GAP),
            ),
        ));
    }
    out
}

pub fn caption(k: &str, shift: bool) -> String {
    match k {
        "SPACE" => "space".into(),
        "DONE" => "Done".into(),
        "CLEAR" => "Clear".into(),
        "BKSP" | "SHIFT" => String::new(),
        _ if shift => k.to_uppercase(),
        _ => k.into(),
    }
}

fn key_icon(k: &str) -> Option<&'static str> {
    match k {
        "BKSP" => Some("delete"),
        "SHIFT" => Some("arrow-big-up"),
        "DONE" => Some("corner-down-left"),
        _ => None,
    }
}

/// The field being edited: what the sheet shows and where edits go.
#[derive(Clone)]
pub struct Target {
    pub id: ElementId,
    pub label: SharedString,
    pub placeholder: SharedString,
    pub numeric: bool,
    pub max_length: usize,
    pub on_change: Option<OnChange<String>>,
    pub on_submit: Option<OnChange<String>>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    None,
    Changed(String),
    Closed(String),
}

/// The keyboard's state without any UI, so the key logic is testable.
#[derive(Default)]
pub struct Model {
    pub target: Option<Target>,
    pub text: String,
    pub shift: bool,
}

impl Model {
    pub fn is_open(&self) -> bool {
        self.target.is_some()
    }

    pub fn numeric(&self) -> bool {
        self.target.as_ref().is_some_and(|t| t.numeric)
    }

    pub fn is_target(&self, id: &ElementId) -> bool {
        self.target.as_ref().is_some_and(|t| &t.id == id)
    }

    pub fn open(&mut self, target: Target, text: &str) {
        self.text = accept(text, target.numeric, target.max_length);
        self.target = Some(target);
        self.shift = false;
    }

    pub fn close(&mut self) -> Outcome {
        match self.target.take() {
            Some(_) => Outcome::Closed(std::mem::take(&mut self.text)),
            None => Outcome::None,
        }
    }

    fn set_text(&mut self, s: &str) -> Outcome {
        let Some(t) = self.target.as_ref() else {
            return Outcome::None;
        };
        let next = accept(s, t.numeric, t.max_length);
        if next == self.text {
            return Outcome::None;
        }
        self.text = next.clone();
        Outcome::Changed(next)
    }

    pub fn insert(&mut self, s: &str) -> Outcome {
        let next = format!("{}{s}", self.text);
        self.set_text(&next)
    }

    pub fn backspace(&mut self) -> Outcome {
        let mut next = self.text.clone();
        if next.pop().is_none() {
            return Outcome::None;
        }
        self.set_text(&next)
    }

    pub fn press_key(&mut self, k: &str) -> Outcome {
        if self.target.is_none() {
            return Outcome::None;
        }
        match k {
            "BKSP" => self.backspace(),
            "CLEAR" => self.set_text(""),
            "DONE" => self.close(),
            "SPACE" => self.insert(" "),
            "SHIFT" => {
                self.shift = !self.shift;
                Outcome::None
            }
            _ => {
                let s = if self.shift {
                    k.to_uppercase()
                } else {
                    k.to_owned()
                };
                self.shift = false;
                self.insert(&s)
            }
        }
    }
}

pub struct Keyboard {
    pub model: Model,
    focus: FocusHandle,
}

struct Registry(HashMap<WindowId, Entity<Keyboard>>);

impl Global for Registry {}

/// PwKeyboard.for_window: the keyboard of this window, once a screen in it
/// has mounted [`layer`].
pub fn for_window(window: &Window, cx: &App) -> Option<Entity<Keyboard>> {
    let id = window.window_handle().window_id();
    cx.try_global::<Registry>()
        .and_then(|r| r.0.get(&id).cloned())
}

fn ensure(window: &Window, cx: &mut App) -> Entity<Keyboard> {
    if let Some(kb) = for_window(window, cx) {
        return kb;
    }
    let id = window.window_handle().window_id();
    let kb = cx.new(|cx| Keyboard {
        model: Model::default(),
        focus: cx.focus_handle(),
    });
    if !cx.has_global::<Registry>() {
        cx.set_global(Registry(HashMap::new()));
    }
    cx.global_mut::<Registry>().0.insert(id, kb.clone());
    kb
}

pub fn open(kb: &Entity<Keyboard>, target: Target, text: &str, window: &mut Window, cx: &mut App) {
    let focus = kb.update(cx, |k, cx| {
        k.model.open(target, text);
        cx.notify();
        k.focus.clone()
    });
    window.focus(&focus, cx);
}

/// Runs an edit and tells the field about it, outside the keyboard's update.
fn apply(
    kb: &Entity<Keyboard>,
    window: &mut Window,
    cx: &mut App,
    f: impl FnOnce(&mut Model) -> Outcome,
) {
    let (outcome, target) = kb.update(cx, |k, cx| {
        let target = k.model.target.clone();
        let outcome = f(&mut k.model);
        cx.notify();
        (outcome, target)
    });
    let Some(target) = target else {
        return;
    };
    match outcome {
        Outcome::None => {}
        Outcome::Changed(text) => {
            if let Some(f) = target.on_change.as_ref() {
                f(text, window, cx);
            }
        }
        Outcome::Closed(text) => {
            let focus = kb.read(cx).focus.clone();
            if focus.is_focused(window) {
                window.blur(cx);
            }
            if let Some(f) = target.on_submit.as_ref() {
                f(text, window, cx);
            }
        }
    }
}

/// The field shown by `id` was re-rendered with `value`: the owner may have
/// reformatted or reset it, so the preview follows, and its callbacks are
/// the current ones.
pub fn sync_target(kb: &Entity<Keyboard>, value: &str, target: Target, cx: &mut App) {
    if !kb.read(cx).model.is_target(&target.id) {
        return;
    }
    kb.update(cx, |k, _| {
        k.model.text = accept(value, target.numeric, target.max_length);
        k.model.target = Some(target);
    });
}

fn on_physical_key(kb: &Entity<Keyboard>, e: &KeyDownEvent, window: &mut Window, cx: &mut App) {
    let ks = &e.keystroke;
    if ks.modifiers.platform || ks.modifiers.control {
        return;
    }
    cx.stop_propagation();
    match ks.key.as_str() {
        "backspace" => apply(kb, window, cx, |m| m.backspace()),
        "enter" | "escape" => apply(kb, window, cx, |m| m.close()),
        _ => {
            if let Some(c) = ks.key_char.as_deref().filter(|c| !c.chars().any(char::is_control)) {
                let c = c.to_owned();
                apply(kb, window, cx, move |m| m.insert(&c));
            }
        }
    }
}

/// The keyboard sheet over everything else in the window, nothing while
/// closed. `size` is the window's design size.
pub fn layer(size: Size<f32>, window: &mut Window, cx: &mut App) -> AnyElement {
    let kb = ensure(window, cx);
    let k = kb.read(cx);
    let Some(target) = k.model.target.clone() else {
        return div().into_any_element();
    };
    let numeric = target.numeric;
    let shift = k.model.shift;
    let text = k.model.text.clone();
    let focus = k.focus.clone();
    let sheet = sheet_rect(numeric, size);

    let mut keys = div()
        .absolute()
        .left(u(sheet.origin.x))
        .top(u(sheet.origin.y))
        .w(u(sheet.size.width))
        .h(u(sheet.size.height))
        .bg(alpha(theme::hex(0x0a0a0a), 0.98))
        .child(
            div()
                .absolute()
                .top_0()
                .left_0()
                .w_full()
                .h(u(BORDER))
                .bg(ACCENT),
        )
        .child(
            div()
                .absolute()
                .left(u(PAD + 4.0))
                .top(u(PAD + 4.0))
                .child(tracked(&target.label, 12., 600, 0.2, 16., ZINC_400)),
        )
        .child(preview(&text, &target.placeholder, sheet.size.width));
    for (name, rect) in layout(numeric, size) {
        keys = keys.child(key_button(&kb, name, rect, shift, window, cx));
    }

    let scrim_kb = kb.clone();
    div()
        .id("pw-keyboard")
        .absolute()
        .top_0()
        .left_0()
        .size_full()
        .occlude()
        .track_focus(&focus)
        .bg(alpha(BLACK, 0.55))
        .on_key_down({
            let kb = kb.clone();
            move |e, window, cx| on_physical_key(&kb, e, window, cx)
        })
        .on_mouse_down(MouseButton::Left, move |e, window, _| {
            input::veto_swipe();
            let at = input::to_design(e.position, window);
            if sheet.contains(&at) {
                return;
            }
            let kb = scrim_kb.clone();
            input::capture(window, move |p, window, cx| {
                if p.phase == Phase::Up && !sheet.contains(&p.pos) {
                    apply(&kb, window, cx, |m| m.close());
                }
            });
        })
        .child(keys)
        .into_any_element()
}

/// The field's text (or its placeholder) on the 26 px line whose baseline
/// sits 46 px below the sheet's padding.
fn preview(text: &str, placeholder: &SharedString, sheet_w: f32) -> Div {
    let line = 32.0;
    let ascent = PREVIEW_PX * 1984.0 / 2048.0;
    let descent = PREVIEW_PX * 494.0 / 2048.0;
    let baseline = PAD + 46.0;
    let top = baseline - ((line - ascent - descent) * 0.5 + ascent);
    let (shown, color): (SharedString, Rgba) = if text.is_empty() {
        (placeholder.clone(), ZINC_600)
    } else {
        (text.to_owned().into(), WHITE)
    };
    div()
        .absolute()
        .left(u(PAD + 4.0))
        .top(u(top))
        .w(u(sheet_w - PAD * 2.0))
        .h(u(line))
        .overflow_hidden()
        .whitespace_nowrap()
        .font_family(theme::INTER)
        .font_weight(theme::touch_weight(500))
        .text_size(u(PREVIEW_PX))
        .line_height(u(line))
        .text_color(color)
        .child(shown)
}

/// A PwButton DARK key (PRIMARY for Done) at 22 px.
fn key_button(
    kb: &Entity<Keyboard>,
    name: &'static str,
    rect: Bounds<f32>,
    shift: bool,
    window: &mut Window,
    cx: &mut App,
) -> Stateful<Div> {
    let id = ElementId::Name(format!("pw-key-{name}").into());
    let state = press_state(id.clone(), window, cx);
    let pressed = state.read(cx).pressed;
    let done = name == "DONE";
    let (bg, fg, opacity) = if done {
        (ACCENT, BLACK, if pressed { 0.7 } else { 1.0 })
    } else if name == "SHIFT" && shift {
        (ACCENT, WHITE, 1.0)
    } else if pressed {
        (ZINC_800, WHITE, 1.0)
    } else {
        (BLACK, WHITE, 1.0)
    };
    let text = caption(name, shift);
    let el = div()
        .id(id)
        .absolute()
        .left(u(rect.origin.x))
        .top(u(rect.origin.y))
        .w(u(rect.size.width))
        .h(u(rect.size.height))
        .flex()
        .items_center()
        .justify_center()
        .gap(u(10.))
        .bg(bg)
        .opacity(opacity)
        .font_family(theme::INTER)
        .font_weight(theme::touch_weight(if done { 600 } else { 400 }))
        .text_size(u(KEY_PX))
        .line_height(u(KEY_H))
        .text_color(fg)
        .whitespace_nowrap();
    let el = match key_icon(name) {
        Some(icon) => el.child(lucide(icon, KEY_PX, fg)),
        None => el,
    };
    let el = if text.is_empty() { el } else { el.child(text) };
    let kb = kb.clone();
    tappable(
        el,
        state,
        false,
        Some(Rc::new(move |window, cx| {
            apply(&kb, window, cx, |m| m.press_key(name))
        })),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    const SCREEN: Size<f32> = Size {
        width: 1920.0,
        height: 515.0,
    };

    fn target(label: &str, numeric: bool) -> Target {
        Target {
            id: ElementId::Name(label.to_owned().into()),
            label: label.to_owned().into(),
            placeholder: SharedString::default(),
            numeric,
            max_length: MAX_LENGTH,
            on_change: None,
            on_submit: None,
        }
    }

    fn key_rect(numeric: bool, k: &str) -> Option<Bounds<f32>> {
        layout(numeric, SCREEN)
            .into_iter()
            .find(|(n, _)| *n == k)
            .map(|(_, r)| r)
    }

    #[std::prelude::v1::test]
    fn text_input_with_keyboard_and_keypad() {
        let mut kb = Model::default();
        kb.open(target("Host", false), "");
        assert!(kb.is_open() && !kb.numeric());
        for k in ["1", "0", ".", "4"] {
            kb.press_key(k);
        }
        kb.press_key("SHIFT");
        kb.press_key("a");
        kb.press_key("b");
        assert_eq!(kb.text, "10.4Ab", "shift applies to one key");
        kb.press_key("BKSP");
        assert_eq!(kb.text, "10.4A");
        assert_eq!(kb.press_key("DONE"), Outcome::Closed("10.4A".into()));
        assert!(!kb.is_open());

        kb.open(target("Port", true), "");
        assert!(kb.numeric(), "numeric fields get the keypad");
        assert!(key_rect(true, "q").is_none() && key_rect(true, "5").is_some());
        kb.press_key("5");
        kb.press_key("8");
        kb.insert("1a.0");
        assert_eq!(kb.text, "5810", "numeric filter strips non-digits");
        assert_eq!(kb.press_key("CLEAR"), Outcome::Changed(String::new()));
        assert_eq!(kb.text, "");
        assert_eq!(filter("a1-2 3", true), "123");
    }

    #[std::prelude::v1::test]
    fn edits_report_changes_only() {
        let mut kb = Model::default();
        assert_eq!(kb.press_key("a"), Outcome::None, "closed keyboard ignores keys");
        kb.open(target("Host", false), "ab");
        assert_eq!(kb.press_key("SHIFT"), Outcome::None);
        assert!(kb.shift);
        assert_eq!(kb.press_key("c"), Outcome::Changed("abC".into()));
        assert!(!kb.shift);
        assert_eq!(kb.press_key("SPACE"), Outcome::Changed("abC ".into()));
        kb.open(target("Port", true), "");
        assert_eq!(kb.press_key("BKSP"), Outcome::None, "nothing to delete");
        assert_eq!(kb.insert("x"), Outcome::None, "filtered to nothing");
    }

    #[std::prelude::v1::test]
    fn opening_filters_the_current_text_and_resets_shift() {
        let mut kb = Model::default();
        kb.open(target("Host", false), "a");
        kb.press_key("SHIFT");
        kb.open(target("Port", true), "58a10");
        assert_eq!(kb.text, "5810");
        assert!(!kb.shift);
    }

    #[std::prelude::v1::test]
    fn text_is_cut_to_max_length_and_strips_line_breaks() {
        let mut kb = Model::default();
        let mut t = target("Host", false);
        t.max_length = 4;
        kb.open(t, "");
        kb.insert("ab\ncd\tef");
        assert_eq!(kb.text, "abcd");
        assert_eq!(filter("a\nb\tc", false), "abc");
    }

    #[std::prelude::v1::test]
    fn sheet_sits_at_the_bottom_center() {
        let r = sheet_rect(false, SCREEN);
        assert_eq!((r.origin.x, r.origin.y), (360.0, 185.0));
        assert_eq!((r.size.width, r.size.height), (1200.0, 330.0));
        let p = sheet_rect(true, SCREEN);
        assert_eq!((p.origin.x, p.origin.y), (680.0, 237.0));
        assert_eq!((p.size.width, p.size.height), (560.0, 278.0));
        let narrow = sheet_rect(false, Size {
            width: 1000.0,
            height: 600.0,
        });
        assert_eq!(narrow.size.width, 960.0, "40 px margin below 1240 px");
    }

    #[std::prelude::v1::test]
    fn keys_fill_their_rows() {
        let row0 = key_rect(false, "1").unwrap();
        assert_eq!((row0.origin.x, row0.origin.y), (PAD, PAD + HEADER_H));
        let dash = key_rect(false, "-").unwrap();
        let right = dash.origin.x + dash.size.width;
        assert!((right - (1200.0 - PAD)).abs() < 0.01);
        let shift = key_rect(false, "SHIFT").unwrap();
        let z = key_rect(false, "z").unwrap();
        assert!((shift.size.width - z.size.width * 1.5).abs() < 0.01);
        let space = key_rect(false, "SPACE").unwrap();
        let done = key_rect(false, "DONE").unwrap();
        assert!((space.size.width - done.size.width * 4.0).abs() < 0.01);
        assert_eq!(done.origin.y, PAD + HEADER_H + 4.0 * (KEY_H + KEY_GAP));

        let pad_done = key_rect(true, "DONE").unwrap();
        assert_eq!(pad_done.origin.x, 560.0 - PAD - KEYPAD_DONE_W);
        assert_eq!(pad_done.size.height, 4.0 * KEY_H + 3.0 * KEY_GAP);
        let bksp = key_rect(true, "BKSP").unwrap();
        assert!(bksp.origin.x + bksp.size.width <= pad_done.origin.x - KEYPAD_DONE_GAP + 0.01);
        assert!((bksp.size.width - key_rect(true, "0").unwrap().size.width).abs() < 0.01);
    }

    #[std::prelude::v1::test]
    fn captions_follow_shift() {
        assert_eq!(caption("q", true), "Q");
        assert_eq!(caption("q", false), "q");
        assert_eq!(caption(".", true), ".");
        assert_eq!(caption("SPACE", true), "space");
        assert_eq!(caption("BKSP", false), "");
        assert_eq!(caption("DONE", false), "Done");
    }
}
