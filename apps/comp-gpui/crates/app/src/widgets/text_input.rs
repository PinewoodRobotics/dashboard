use std::cell::RefCell;
use std::ops::Range;
use std::time::{Duration, Instant};

use gpui_kit::*;
use unicode_segmentation::UnicodeSegmentation;

use super::{OnChange, tracked};
use crate::anim::Tween;
use crate::input::{self, Phase, TAP_SLOP};
use crate::theme::{
    self, ACCENT, ERROR, FOCUS_FILL, MOTION_PRESS_S, PANEL, WHITE, ZINC_600, hex, lerp_rgba, u,
};

const CARET_BLINK: Duration = Duration::from_millis(500);
const FIELD_H: f32 = 72.0;
const TEXT_PX: f32 = 24.0;
const LINE_PX: f32 = 32.0;
const CARET_H: f32 = TEXT_PX * (1984.0 + 494.0) / 2048.0;
const SELECTION: Rgba = hex(0x3f638b);
const CONTEXT: &str = "TextInput";

actions!(
    text_input,
    [
        Backspace,
        Delete,
        DeleteWordLeft,
        DeleteWordRight,
        DeleteToStart,
        Left,
        Right,
        WordLeft,
        WordRight,
        Home,
        End,
        SelectLeft,
        SelectRight,
        SelectWordLeft,
        SelectWordRight,
        SelectHome,
        SelectEnd,
        SelectAll,
        Copy,
        Cut,
        Paste,
        FocusNext,
        FocusPrev,
    ]
);

/// The editing keys of a Chromium `<input type="text">` on this platform.
pub fn init(cx: &mut App) {
    let c = Some(CONTEXT);
    cx.bind_keys([
        KeyBinding::new("backspace", Backspace, c),
        KeyBinding::new("shift-backspace", Backspace, c),
        KeyBinding::new("delete", Delete, c),
        KeyBinding::new("left", Left, c),
        KeyBinding::new("right", Right, c),
        KeyBinding::new("shift-left", SelectLeft, c),
        KeyBinding::new("shift-right", SelectRight, c),
        KeyBinding::new("home", Home, c),
        KeyBinding::new("end", End, c),
        KeyBinding::new("shift-home", SelectHome, c),
        KeyBinding::new("shift-end", SelectEnd, c),
        KeyBinding::new("tab", FocusNext, c),
        KeyBinding::new("shift-tab", FocusPrev, c),
    ]);
    #[cfg(target_os = "macos")]
    cx.bind_keys([
        KeyBinding::new("alt-left", WordLeft, c),
        KeyBinding::new("alt-right", WordRight, c),
        KeyBinding::new("alt-shift-left", SelectWordLeft, c),
        KeyBinding::new("alt-shift-right", SelectWordRight, c),
        KeyBinding::new("cmd-left", Home, c),
        KeyBinding::new("cmd-right", End, c),
        KeyBinding::new("cmd-shift-left", SelectHome, c),
        KeyBinding::new("cmd-shift-right", SelectEnd, c),
        KeyBinding::new("up", Home, c),
        KeyBinding::new("down", End, c),
        KeyBinding::new("shift-up", SelectHome, c),
        KeyBinding::new("shift-down", SelectEnd, c),
        KeyBinding::new("ctrl-a", Home, c),
        KeyBinding::new("ctrl-e", End, c),
        KeyBinding::new("ctrl-h", Backspace, c),
        KeyBinding::new("ctrl-d", Delete, c),
        KeyBinding::new("alt-backspace", DeleteWordLeft, c),
        KeyBinding::new("alt-delete", DeleteWordRight, c),
        KeyBinding::new("cmd-backspace", DeleteToStart, c),
        KeyBinding::new("cmd-a", SelectAll, c),
        KeyBinding::new("cmd-c", Copy, c),
        KeyBinding::new("cmd-x", Cut, c),
        KeyBinding::new("cmd-v", Paste, c),
    ]);
    #[cfg(not(target_os = "macos"))]
    cx.bind_keys([
        KeyBinding::new("ctrl-left", WordLeft, c),
        KeyBinding::new("ctrl-right", WordRight, c),
        KeyBinding::new("ctrl-shift-left", SelectWordLeft, c),
        KeyBinding::new("ctrl-shift-right", SelectWordRight, c),
        KeyBinding::new("ctrl-backspace", DeleteWordLeft, c),
        KeyBinding::new("ctrl-delete", DeleteWordRight, c),
        KeyBinding::new("ctrl-a", SelectAll, c),
        KeyBinding::new("ctrl-c", Copy, c),
        KeyBinding::new("ctrl-insert", Copy, c),
        KeyBinding::new("ctrl-x", Cut, c),
        KeyBinding::new("shift-delete", Cut, c),
        KeyBinding::new("ctrl-v", Paste, c),
        KeyBinding::new("shift-insert", Paste, c),
    ]);
}

/// CustomTextInput.tsx: a single-line field typed into from the physical
/// keyboard through the platform text input (IME included). A tap focuses
/// it with the caret at the tap; Tab focuses it with its text selected.
/// Focused it is green on the focus fill, else red when invalid, else white
/// on the panel gray, fading over 100 ms. Numeric fields drop every
/// non-digit, as the web's `replace(/\D+/g, "")`.
#[derive(IntoElement)]
pub struct TextInput {
    id: ElementId,
    value: SharedString,
    label: Option<SharedString>,
    placeholder: Option<SharedString>,
    numeric: bool,
    invalid: bool,
    on_change: Option<OnChange<String>>,
}

impl TextInput {
    pub fn new(id: impl Into<ElementId>, value: impl Into<SharedString>) -> Self {
        Self {
            id: id.into(),
            value: value.into(),
            label: None,
            placeholder: None,
            numeric: false,
            invalid: false,
            on_change: None,
        }
    }

    pub fn label(mut self, label: impl Into<SharedString>) -> Self {
        self.label = Some(label.into());
        self
    }

    pub fn placeholder(mut self, text: impl Into<SharedString>) -> Self {
        self.placeholder = Some(text.into());
        self
    }

    pub fn numeric(mut self, numeric: bool) -> Self {
        self.numeric = numeric;
        self
    }

    pub fn invalid(mut self, invalid: bool) -> Self {
        self.invalid = invalid;
        self
    }

    pub fn on_change(mut self, f: impl Fn(String, &mut Window, &mut App) + 'static) -> Self {
        self.on_change = Some(std::rc::Rc::new(f));
        self
    }
}

/// What the field keeps of its text: digits only when numeric, and never a
/// control character (a pasted line break, Enter, Tab).
fn sanitize(s: &str, numeric: bool) -> String {
    s.chars()
        .filter(|c| {
            if numeric {
                c.is_ascii_digit()
            } else {
                !c.is_control()
            }
        })
        .collect()
}

fn prev_word(text: &str, offset: usize) -> usize {
    text.split_word_bound_indices()
        .rev()
        .find(|(i, w)| *i < offset && !w.trim().is_empty())
        .map(|(i, _)| i)
        .unwrap_or(0)
}

fn next_word(text: &str, offset: usize) -> usize {
    text.split_word_bound_indices()
        .map(|(i, w)| (i + w.len(), w))
        .find(|(end, w)| *end > offset && !w.trim().is_empty())
        .map(|(end, _)| end)
        .unwrap_or(text.len())
}

fn word_at(text: &str, offset: usize) -> Range<usize> {
    text.split_word_bound_indices()
        .map(|(i, w)| i..i + w.len())
        .find(|r| r.contains(&offset))
        .unwrap_or(offset..offset)
}

fn prev_grapheme(text: &str, offset: usize) -> usize {
    text.grapheme_indices(true)
        .rev()
        .map(|(i, _)| i)
        .find(|i| *i < offset)
        .unwrap_or(0)
}

fn next_grapheme(text: &str, offset: usize) -> usize {
    text.grapheme_indices(true)
        .map(|(i, _)| i)
        .find(|i| *i > offset)
        .unwrap_or(text.len())
}

struct Fade {
    from: (Rgba, Rgba),
    to: (Rgba, Rgba),
    t: Tween,
}

impl Fade {
    fn value(&self) -> (Rgba, Rgba) {
        let p = self.t.value();
        (
            lerp_rgba(self.from.0, self.to.0, p),
            lerp_rgba(self.from.1, self.to.1, p),
        )
    }
}

struct Editor {
    focus: FocusHandle,
    text: String,
    selected: Range<usize>,
    reversed: bool,
    marked: Option<Range<usize>>,
    numeric: bool,
    on_change: Option<OnChange<String>>,
    layout: Option<ShapedLine>,
    bounds: Option<Bounds<Pixels>>,
    scroll_x: Pixels,
    was_focused: bool,
    pointer_focus: bool,
    outside_press: Option<Point<f32>>,
    caret_epoch: Instant,
    blink_due: Option<Instant>,
    fade: Option<Fade>,
}

thread_local! {
    static FOCUSED: RefCell<Option<WeakEntity<Editor>>> = const { RefCell::new(None) };
}

/// Text the platform would insert for an unbound keystroke, delivered to
/// the focused field the way the OS text input delivers it (`--script`
/// typing, which cannot reach the OS).
pub fn type_into_focused(text: &str, window: &mut Window, cx: &mut App) {
    let Some(ed) = FOCUSED.with(|f| f.borrow().as_ref().and_then(WeakEntity::upgrade)) else {
        return;
    };
    if !ed.read(cx).focus.is_focused(window) {
        return;
    }
    ed.update(cx, |ed, cx| ed.replace_text_in_range(None, text, window, cx));
}

impl Editor {
    fn new(cx: &mut App) -> Self {
        Self {
            focus: cx.focus_handle().tab_stop(true),
            text: String::new(),
            selected: 0..0,
            reversed: false,
            marked: None,
            numeric: false,
            on_change: None,
            layout: None,
            bounds: None,
            scroll_x: px(0.),
            was_focused: false,
            pointer_focus: false,
            outside_press: None,
            caret_epoch: Instant::now(),
            blink_due: None,
            fade: None,
        }
    }

    /// The owner's value wins: an edit it did not take, or a reset from
    /// outside, shows at once with the caret at the end.
    fn sync(&mut self, value: &str, numeric: bool, on_change: Option<OnChange<String>>) {
        self.numeric = numeric;
        self.on_change = on_change;
        if self.text != value {
            self.text = value.to_owned();
            self.selected = self.text.len()..self.text.len();
            self.reversed = false;
            self.marked = None;
        }
    }

    fn cursor(&self) -> usize {
        if self.reversed {
            self.selected.start
        } else {
            self.selected.end
        }
    }

    fn touched(&mut self, cx: &mut Context<Self>) {
        self.caret_epoch = Instant::now();
        self.blink_due = None;
        cx.notify();
    }

    fn move_to(&mut self, offset: usize, cx: &mut Context<Self>) {
        self.selected = offset..offset;
        self.reversed = false;
        self.touched(cx);
    }

    fn select_to(&mut self, offset: usize, cx: &mut Context<Self>) {
        if self.reversed {
            self.selected.start = offset;
        } else {
            self.selected.end = offset;
        }
        if self.selected.end < self.selected.start {
            self.reversed = !self.reversed;
            self.selected = self.selected.end..self.selected.start;
        }
        self.touched(cx);
    }

    fn select_range(&mut self, range: Range<usize>, cx: &mut Context<Self>) {
        self.selected = range;
        self.reversed = false;
        self.touched(cx);
    }

    fn splice(
        &mut self,
        range: Range<usize>,
        new_text: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> usize {
        let clean = sanitize(new_text, self.numeric);
        let next = format!(
            "{}{}{}",
            &self.text[..range.start],
            clean,
            &self.text[range.end..]
        );
        let caret = range.start + clean.len();
        self.selected = caret..caret;
        self.reversed = false;
        self.marked = None;
        if next != self.text {
            self.text = next.clone();
            if let Some(f) = self.on_change.clone() {
                f(next, window, cx);
            }
        }
        window.notify_text_input_changed(&self.focus);
        self.touched(cx);
        clean.len()
    }

    fn delete_to(&mut self, offset: usize, window: &mut Window, cx: &mut Context<Self>) {
        if self.selected.is_empty() {
            self.select_to(offset, cx);
        }
        let range = self.selected.clone();
        self.splice(range, "", window, cx);
    }

    fn backspace(&mut self, _: &Backspace, window: &mut Window, cx: &mut Context<Self>) {
        self.delete_to(prev_grapheme(&self.text, self.cursor()), window, cx);
    }

    fn delete(&mut self, _: &Delete, window: &mut Window, cx: &mut Context<Self>) {
        self.delete_to(next_grapheme(&self.text, self.cursor()), window, cx);
    }

    fn delete_word_left(&mut self, _: &DeleteWordLeft, window: &mut Window, cx: &mut Context<Self>) {
        self.delete_to(prev_word(&self.text, self.cursor()), window, cx);
    }

    fn delete_word_right(
        &mut self,
        _: &DeleteWordRight,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.delete_to(next_word(&self.text, self.cursor()), window, cx);
    }

    fn delete_to_start(&mut self, _: &DeleteToStart, window: &mut Window, cx: &mut Context<Self>) {
        self.delete_to(0, window, cx);
    }

    fn left(&mut self, _: &Left, _: &mut Window, cx: &mut Context<Self>) {
        let to = if self.selected.is_empty() {
            prev_grapheme(&self.text, self.cursor())
        } else {
            self.selected.start
        };
        self.move_to(to, cx);
    }

    fn right(&mut self, _: &Right, _: &mut Window, cx: &mut Context<Self>) {
        let to = if self.selected.is_empty() {
            next_grapheme(&self.text, self.cursor())
        } else {
            self.selected.end
        };
        self.move_to(to, cx);
    }

    fn word_left(&mut self, _: &WordLeft, _: &mut Window, cx: &mut Context<Self>) {
        self.move_to(prev_word(&self.text, self.cursor()), cx);
    }

    fn word_right(&mut self, _: &WordRight, _: &mut Window, cx: &mut Context<Self>) {
        self.move_to(next_word(&self.text, self.cursor()), cx);
    }

    fn home(&mut self, _: &Home, _: &mut Window, cx: &mut Context<Self>) {
        self.move_to(0, cx);
    }

    fn end(&mut self, _: &End, _: &mut Window, cx: &mut Context<Self>) {
        self.move_to(self.text.len(), cx);
    }

    fn select_left(&mut self, _: &SelectLeft, _: &mut Window, cx: &mut Context<Self>) {
        self.select_to(prev_grapheme(&self.text, self.cursor()), cx);
    }

    fn select_right(&mut self, _: &SelectRight, _: &mut Window, cx: &mut Context<Self>) {
        self.select_to(next_grapheme(&self.text, self.cursor()), cx);
    }

    fn select_word_left(&mut self, _: &SelectWordLeft, _: &mut Window, cx: &mut Context<Self>) {
        self.select_to(prev_word(&self.text, self.cursor()), cx);
    }

    fn select_word_right(&mut self, _: &SelectWordRight, _: &mut Window, cx: &mut Context<Self>) {
        self.select_to(next_word(&self.text, self.cursor()), cx);
    }

    fn select_home(&mut self, _: &SelectHome, _: &mut Window, cx: &mut Context<Self>) {
        self.select_to(0, cx);
    }

    fn select_end(&mut self, _: &SelectEnd, _: &mut Window, cx: &mut Context<Self>) {
        self.select_to(self.text.len(), cx);
    }

    fn select_all(&mut self, _: &SelectAll, _: &mut Window, cx: &mut Context<Self>) {
        self.select_range(0..self.text.len(), cx);
    }

    fn copy(&mut self, _: &Copy, _: &mut Window, cx: &mut Context<Self>) {
        if !self.selected.is_empty() {
            cx.write_to_clipboard(ClipboardItem::new_string(
                self.text[self.selected.clone()].to_owned(),
            ));
        }
    }

    fn cut(&mut self, _: &Cut, window: &mut Window, cx: &mut Context<Self>) {
        if !self.selected.is_empty() {
            self.copy(&Copy, window, cx);
            let range = self.selected.clone();
            self.splice(range, "", window, cx);
        }
    }

    fn paste(&mut self, _: &Paste, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(text) = cx.read_from_clipboard().and_then(|item| item.text()) {
            self.replace_text_in_range(None, &text, window, cx);
        }
    }

    fn focus_next(&mut self, _: &FocusNext, window: &mut Window, cx: &mut Context<Self>) {
        window.focus_next(cx);
    }

    fn focus_prev(&mut self, _: &FocusPrev, window: &mut Window, cx: &mut Context<Self>) {
        window.focus_prev(cx);
    }

    /// The caret position under a window point; a press beside the text
    /// box (the label) puts it at the end.
    fn index_for(&self, pos: Point<Pixels>, rem: Pixels) -> usize {
        let (Some(bounds), Some(line)) = (self.bounds.as_ref(), self.layout.as_ref()) else {
            return self.text.len();
        };
        if self.text.is_empty() {
            return 0;
        }
        let pad = rem * ((FIELD_H - LINE_PX) * 0.5);
        if pos.y < bounds.top() - pad || pos.y > bounds.bottom() + pad {
            return self.text.len();
        }
        line.closest_index_for_x(pos.x - bounds.left() + self.scroll_x)
            .min(self.text.len())
    }

    fn on_focus_change(&mut self, focused: bool) {
        if focused == self.was_focused {
            return;
        }
        self.was_focused = focused;
        self.caret_epoch = Instant::now();
        self.blink_due = None;
        if focused && !self.pointer_focus {
            self.selected = 0..self.text.len();
            self.reversed = false;
        }
        if !focused {
            self.marked = None;
            self.scroll_x = px(0.);
        }
        self.pointer_focus = false;
    }

    fn colors(&mut self, look: (Rgba, Rgba)) -> (Rgba, Rgba) {
        match self.fade.as_mut() {
            None => {
                self.fade = Some(Fade {
                    from: look,
                    to: look,
                    t: Tween::new(1.0),
                });
            }
            Some(f) if f.to != look => {
                f.from = f.value();
                f.to = look;
                f.t = Tween::new(0.0).with_easing(theme::ease_tailwind);
                f.t.play(0.0, 1.0, MOTION_PRESS_S);
            }
            Some(_) => {}
        }
        self.fade.as_ref().map(Fade::value).unwrap_or(look)
    }

    fn fading(&self) -> bool {
        self.fade.as_ref().is_some_and(|f| f.t.running())
    }

    fn caret_on(&self, now: Instant) -> bool {
        let phase = now.duration_since(self.caret_epoch).as_millis() / CARET_BLINK.as_millis();
        phase.is_multiple_of(2)
    }

    fn next_blink(&self, now: Instant) -> Instant {
        let n = now.duration_since(self.caret_epoch).as_millis() / CARET_BLINK.as_millis() + 1;
        self.caret_epoch + CARET_BLINK * n as u32
    }

    fn offset_from_utf16(&self, offset: usize) -> usize {
        let mut utf8 = 0;
        let mut utf16 = 0;
        for ch in self.text.chars() {
            if utf16 >= offset {
                break;
            }
            utf16 += ch.len_utf16();
            utf8 += ch.len_utf8();
        }
        utf8
    }

    fn offset_to_utf16(&self, offset: usize) -> usize {
        self.text[..offset.min(self.text.len())]
            .chars()
            .map(char::len_utf16)
            .sum()
    }

    fn range_to_utf16(&self, r: &Range<usize>) -> Range<usize> {
        self.offset_to_utf16(r.start)..self.offset_to_utf16(r.end)
    }

    fn range_from_utf16(&self, r: &Range<usize>) -> Range<usize> {
        self.offset_from_utf16(r.start)..self.offset_from_utf16(r.end)
    }
}

impl EntityInputHandler for Editor {
    fn text_for_range(
        &mut self,
        range_utf16: Range<usize>,
        adjusted: &mut Option<Range<usize>>,
        _: &mut Window,
        _: &mut Context<Self>,
    ) -> Option<String> {
        let range = self.range_from_utf16(&range_utf16);
        adjusted.replace(self.range_to_utf16(&range));
        Some(self.text[range].to_owned())
    }

    fn selected_text_range(
        &mut self,
        _: bool,
        _: &mut Window,
        _: &mut Context<Self>,
    ) -> Option<UTF16Selection> {
        Some(UTF16Selection {
            range: self.range_to_utf16(&self.selected),
            reversed: self.reversed,
        })
    }

    fn marked_text_range(&self, _: &mut Window, _: &mut Context<Self>) -> Option<Range<usize>> {
        self.marked.as_ref().map(|r| self.range_to_utf16(r))
    }

    fn unmark_text(&mut self, _: &mut Window, _: &mut Context<Self>) {
        self.marked = None;
    }

    fn replace_text_in_range(
        &mut self,
        range_utf16: Option<Range<usize>>,
        text: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let range = range_utf16
            .map(|r| self.range_from_utf16(&r))
            .or(self.marked.clone())
            .unwrap_or(self.selected.clone());
        self.splice(range, text, window, cx);
    }

    fn replace_and_mark_text_in_range(
        &mut self,
        range_utf16: Option<Range<usize>>,
        text: &str,
        new_selected_utf16: Option<Range<usize>>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let range = range_utf16
            .map(|r| self.range_from_utf16(&r))
            .or(self.marked.clone())
            .unwrap_or(self.selected.clone());
        let start = range.start;
        let inserted = self.splice(range, text, window, cx);
        if inserted > 0 {
            self.marked = Some(start..start + inserted);
            if let Some(sel) = new_selected_utf16 {
                let base = self.offset_to_utf16(start);
                let a = self.offset_from_utf16(base + sel.start).min(start + inserted);
                let b = self.offset_from_utf16(base + sel.end).min(start + inserted);
                self.selected = a..b;
            }
        }
    }

    fn bounds_for_range(
        &mut self,
        range_utf16: Range<usize>,
        bounds: Bounds<Pixels>,
        _: &mut Window,
        _: &mut Context<Self>,
    ) -> Option<Bounds<Pixels>> {
        let line = self.layout.as_ref()?;
        let range = self.range_from_utf16(&range_utf16);
        let left = bounds.left() - self.scroll_x;
        Some(Bounds::from_corners(
            point(left + line.x_for_index(range.start), bounds.top()),
            point(left + line.x_for_index(range.end), bounds.bottom()),
        ))
    }

    fn character_index_for_point(
        &mut self,
        p: Point<Pixels>,
        _: &mut Window,
        _: &mut Context<Self>,
    ) -> Option<usize> {
        let bounds = self.bounds?;
        let line = self.layout.as_ref()?;
        let local = bounds.localize(&p)?;
        let i = line.index_for_x(local.x + self.scroll_x)?;
        Some(self.offset_to_utf16(i))
    }
}

fn to_window(p: Point<f32>, window: &Window) -> Point<Pixels> {
    let rem = window.rem_size();
    point(rem * p.x, rem * p.y)
}

fn moved_past_slop(a: Point<f32>, b: Point<f32>) -> bool {
    let (dx, dy) = (b.x - a.x, b.y - a.y);
    (dx * dx + dy * dy).sqrt() > TAP_SLOP
}

/// A mouse press focuses and places the caret at once and drags a
/// selection, as in Chromium; a touch focuses on a tap, so a swipe that
/// starts on the field still scrolls its column.
fn press(ed: &Entity<Editor>, e: &MouseDownEvent, window: &mut Window, cx: &mut App) {
    let p = input::pointer(Phase::Down, e.position, window);
    let focus = ed.read(cx).focus.clone();
    if p.is_touch() {
        let start = p.pos;
        let ed = ed.clone();
        let mut moved = false;
        input::capture(window, move |p, window, cx| match p.phase {
            Phase::Move => moved |= moved_past_slop(start, p.pos),
            Phase::Up if !moved => {
                let at = to_window(p.pos, window);
                ed.update(cx, |ed, cx| {
                    ed.pointer_focus = true;
                    let i = ed.index_for(at, window.rem_size());
                    ed.move_to(i, cx);
                });
                window.focus(&focus, cx);
            }
            _ => {}
        });
        return;
    }
    ed.update(cx, |ed, cx| {
        ed.pointer_focus = true;
        let i = ed.index_for(e.position, window.rem_size());
        match e.click_count {
            2 => ed.select_range(word_at(&ed.text, i), cx),
            n if n >= 3 => ed.select_range(0..ed.text.len(), cx),
            _ if e.modifiers.shift && ed.was_focused => ed.select_to(i, cx),
            _ => ed.move_to(i, cx),
        }
    });
    window.focus(&focus, cx);
    if e.click_count > 1 {
        return;
    }
    let ed = ed.clone();
    input::capture(window, move |p, window, cx| {
        if p.phase == Phase::Move {
            let at = to_window(p.pos, window);
            ed.update(cx, |ed, cx| {
                let i = ed.index_for(at, window.rem_size());
                ed.select_to(i, cx);
            });
        }
    });
}

/// A press elsewhere blurs the focused field, as a click on the page does
/// in Chromium; a touch blurs on the tap, not on a scrolling swipe.
fn press_outside(ed: &Entity<Editor>, e: &MouseDownEvent, window: &mut Window, cx: &mut App) {
    if e.button != MouseButton::Left || !ed.read(cx).focus.is_focused(window) {
        return;
    }
    let p = input::pointer(Phase::Down, e.position, window);
    if p.is_touch() {
        ed.update(cx, |ed, _| ed.outside_press = Some(p.pos));
    } else {
        window.blur(cx);
    }
}

fn release_outside(ed: &Entity<Editor>, e: &MouseUpEvent, window: &mut Window, cx: &mut App) {
    let Some(start) = ed.update(cx, |ed, _| ed.outside_press.take()) else {
        return;
    };
    let at = input::to_design(e.position, window);
    if !moved_past_slop(start, at) && ed.read(cx).focus.is_focused(window) {
        window.blur(cx);
    }
}

struct LinePaint {
    line: ShapedLine,
    origin: Point<Pixels>,
    line_h: Pixels,
    selection: Option<PaintQuad>,
    caret: Option<PaintQuad>,
}

fn line_canvas(
    ed: Entity<Editor>,
    placeholder: SharedString,
    focused: bool,
    caret_on: bool,
) -> impl IntoElement {
    let paint_ed = ed.clone();
    canvas(
        move |bounds, window, cx| {
            let style = window.text_style();
            let rem = window.rem_size();
            let e = ed.read(cx);
            let empty = e.text.is_empty();
            let (shown, color): (SharedString, Hsla) = if empty {
                (placeholder, ZINC_600.into())
            } else {
                (e.text.clone().into(), WHITE.into())
            };
            let run = TextRun {
                len: shown.len(),
                font: style.font(),
                color,
                background_color: None,
                underline: None,
                strikethrough: None,
            };
            let runs: Vec<TextRun> = match e.marked.clone().filter(|_| !empty) {
                Some(m) => [
                    TextRun {
                        len: m.start,
                        ..run.clone()
                    },
                    TextRun {
                        len: m.end - m.start,
                        underline: Some(UnderlineStyle {
                            color: Some(color),
                            thickness: rem * 1.0,
                            wavy: false,
                        }),
                        ..run.clone()
                    },
                    TextRun {
                        len: shown.len() - m.end,
                        ..run
                    },
                ]
                .into_iter()
                .filter(|r| r.len > 0)
                .collect(),
                None => vec![run],
            };
            let line = window.text_system().shape_line(
                shown,
                style.font_size.to_pixels(rem),
                &runs,
                None,
            );

            let caret_w = rem * 1.0;
            let cursor = if empty { 0 } else { e.cursor() };
            let cursor_x = if empty { px(0.) } else { line.x_for_index(cursor) };
            let width = bounds.size.width;
            let mut scroll = if focused { e.scroll_x } else { px(0.) };
            if focused && !empty {
                if cursor_x - scroll > width - caret_w {
                    scroll = cursor_x - width + caret_w;
                }
                if cursor_x < scroll {
                    scroll = cursor_x;
                }
                let max = (line.width + caret_w - width).max(px(0.));
                scroll = scroll.clamp(px(0.), max);
            }
            let line_h = bounds.size.height;
            let caret_h = rem * CARET_H;
            let top = bounds.top() + (line_h - caret_h) * 0.5;
            let left = bounds.left() - scroll;
            let selection = (focused && !empty && !e.selected.is_empty()).then(|| {
                fill(
                    Bounds::from_corners(
                        point(left + line.x_for_index(e.selected.start), top),
                        point(left + line.x_for_index(e.selected.end), top + caret_h),
                    ),
                    SELECTION,
                )
            });
            let caret = (focused && caret_on && e.selected.is_empty()).then(|| {
                fill(
                    Bounds::new(point(left + cursor_x, top), size(caret_w, caret_h)),
                    WHITE,
                )
            });
            ed.update(cx, |e, _| e.scroll_x = scroll);
            LinePaint {
                line,
                origin: point(left, bounds.top()),
                line_h,
                selection,
                caret,
            }
        },
        move |bounds, p, window, cx| {
            let focus = paint_ed.read(cx).focus.clone();
            if focused {
                FOCUSED.with(|f| *f.borrow_mut() = Some(paint_ed.downgrade()));
            }
            window.handle_input(
                &focus,
                ElementInputHandler::new(bounds, paint_ed.clone()),
                cx,
            );
            window.with_content_mask(Some(ContentMask { bounds }), |window| {
                if let Some(q) = p.selection {
                    window.paint_quad(q);
                }
                let _ = p
                    .line
                    .paint(p.origin, p.line_h, TextAlign::Left, None, window, cx);
                if let Some(q) = p.caret {
                    window.paint_quad(q);
                }
            });
            paint_ed.update(cx, |e, _| {
                e.layout = Some(p.line);
                e.bounds = Some(bounds);
            });
        },
    )
    .w_full()
    .h(u(LINE_PX))
}

impl RenderOnce for TextInput {
    fn render(self, window: &mut Window, cx: &mut App) -> impl IntoElement {
        let ed = window.use_keyed_state(self.id.clone(), cx, |_, cx| Editor::new(cx));
        ed.update(cx, |e, _| e.sync(&self.value, self.numeric, self.on_change.clone()));
        let focus = ed.read(cx).focus.clone();
        let focused = focus.is_focused(window);

        let look = if focused {
            (ACCENT, FOCUS_FILL)
        } else if self.invalid {
            (ERROR, PANEL)
        } else {
            (WHITE, PANEL)
        };
        let now = Instant::now();
        let (border, bg, caret_on, fading) = ed.update(cx, |e, _| {
            e.on_focus_change(focused);
            let (border, bg) = e.colors(look);
            (border, bg, e.caret_on(now), e.fading())
        });
        if fading {
            window.request_animation_frame();
        }
        if focused && ed.read(cx).selected.is_empty() {
            schedule_blink(&ed, now, window, cx);
        }

        let field = div()
            .flex()
            .items_center()
            .h(u(FIELD_H))
            .w_full()
            .px(u(20.))
            .border(u(4.))
            .border_color(border)
            .bg(bg)
            .cursor_text()
            .font_family(theme::INTER)
            .font_weight(theme::touch_weight(300))
            .text_size(u(TEXT_PX))
            .line_height(u(LINE_PX))
            .overflow_hidden()
            .child(line_canvas(
                ed.clone(),
                self.placeholder.unwrap_or_default(),
                focused,
                caret_on,
            ));

        let mut root = div()
            .id(self.id)
            .key_context(CONTEXT)
            .track_focus(&focus)
            .flex()
            .flex_col()
            .gap(u(8.))
            .w_full();
        if let Some(l) = self.label {
            root = root.child(tracked(&l, 12., 600, 0.2, 16., WHITE));
        }
        root.child(field)
            .on_action(window.listener_for(&ed, Editor::backspace))
            .on_action(window.listener_for(&ed, Editor::delete))
            .on_action(window.listener_for(&ed, Editor::delete_word_left))
            .on_action(window.listener_for(&ed, Editor::delete_word_right))
            .on_action(window.listener_for(&ed, Editor::delete_to_start))
            .on_action(window.listener_for(&ed, Editor::left))
            .on_action(window.listener_for(&ed, Editor::right))
            .on_action(window.listener_for(&ed, Editor::word_left))
            .on_action(window.listener_for(&ed, Editor::word_right))
            .on_action(window.listener_for(&ed, Editor::home))
            .on_action(window.listener_for(&ed, Editor::end))
            .on_action(window.listener_for(&ed, Editor::select_left))
            .on_action(window.listener_for(&ed, Editor::select_right))
            .on_action(window.listener_for(&ed, Editor::select_word_left))
            .on_action(window.listener_for(&ed, Editor::select_word_right))
            .on_action(window.listener_for(&ed, Editor::select_home))
            .on_action(window.listener_for(&ed, Editor::select_end))
            .on_action(window.listener_for(&ed, Editor::select_all))
            .on_action(window.listener_for(&ed, Editor::copy))
            .on_action(window.listener_for(&ed, Editor::cut))
            .on_action(window.listener_for(&ed, Editor::paste))
            .on_action(window.listener_for(&ed, Editor::focus_next))
            .on_action(window.listener_for(&ed, Editor::focus_prev))
            .on_mouse_down(MouseButton::Left, {
                let ed = ed.clone();
                move |e, window, cx| press(&ed, e, window, cx)
            })
            .on_mouse_down_out({
                let ed = ed.clone();
                move |e, window, cx| press_outside(&ed, e, window, cx)
            })
            .on_mouse_up_out(MouseButton::Left, move |e, window, cx| {
                release_outside(&ed, e, window, cx)
            })
    }
}

/// Redraws the window at the caret's next blink, once per blink.
fn schedule_blink(ed: &Entity<Editor>, now: Instant, window: &mut Window, cx: &mut App) {
    let due = ed.read(cx).next_blink(now);
    if ed.read(cx).blink_due == Some(due) {
        return;
    }
    ed.update(cx, |e, _| e.blink_due = Some(due));
    window
        .spawn(cx, async move |cx| {
            cx.background_executor()
                .timer(due.saturating_duration_since(Instant::now()))
                .await;
            let _ = cx.update(|window, _| window.refresh());
        })
        .detach();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[std::prelude::v1::test]
    fn numeric_fields_keep_digits_and_text_fields_drop_control_chars() {
        assert_eq!(sanitize("a1-2 3", true), "123");
        assert_eq!(sanitize("10.47.65.2\n\tx", false), "10.47.65.2x");
        assert_eq!(sanitize("Shared/Path Planner", false), "Shared/Path Planner");
    }

    #[std::prelude::v1::test]
    fn word_motion_skips_spaces_and_keeps_dotted_numbers_whole() {
        let s = "Shared/PathPlanner  10.47.65.2";
        assert_eq!(next_word(s, 0), 6);
        assert_eq!(prev_word(s, s.len()), 20);
        assert_eq!(next_word(s, 18), s.len());
        assert_eq!(prev_word(s, 20), 7);
        assert_eq!(word_at(s, 9), 7..18);
    }

    #[std::prelude::v1::test]
    fn grapheme_steps_cover_multibyte_text() {
        let s = "aé🙂";
        assert_eq!(next_grapheme(s, 0), 1);
        assert_eq!(next_grapheme(s, 1), 3);
        assert_eq!(prev_grapheme(s, s.len()), 3);
        assert_eq!(prev_grapheme(s, 0), 0);
    }
}
