use std::rc::Rc;
use std::time::{Duration, Instant};

use gpui_kit::prelude::FluentBuilder;
use gpui_kit::*;

use super::keyboard::{self, MAX_LENGTH, Target};
use super::tap::{press_state, tappable};
use super::{OnChange, tracked};
use crate::anim::Tween;
use crate::theme::{
    self, ACCENT, ERROR, FOCUS_FILL, MOTION_PRESS_S, PANEL, WHITE, ZINC_600, lerp_rgba, u,
};

const CARET_BLINK: Duration = Duration::from_millis(500);
const FIELD_H: f32 = 72.0;
const TEXT_PX: f32 = 24.0;
const CARET_H: f32 = TEXT_PX * (1984.0 + 494.0) / 2048.0;

/// CustomTextInput.tsx as comp-godot's PwTextInput: a tap opens this
/// window's on-screen keyboard (the keypad for numeric fields), which edits
/// the field live. Focused it is green on the focus fill, else red when
/// invalid, else white on the panel gray, fading over 100 ms. In a window
/// without a keyboard a tap focuses the field for physical typing.
#[derive(IntoElement)]
pub struct TextInput {
    id: ElementId,
    value: SharedString,
    label: Option<SharedString>,
    placeholder: Option<SharedString>,
    numeric: bool,
    invalid: bool,
    max_length: usize,
    on_change: Option<OnChange<String>>,
    on_submit: Option<OnChange<String>>,
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
            max_length: MAX_LENGTH,
            on_change: None,
            on_submit: None,
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

    pub fn max_length(mut self, n: usize) -> Self {
        self.max_length = n;
        self
    }

    pub fn on_change(mut self, f: impl Fn(String, &mut Window, &mut App) + 'static) -> Self {
        self.on_change = Some(Rc::new(f));
        self
    }

    /// The keyboard closed on this field (Done, Enter, Escape or a tap
    /// outside it), with the final text.
    pub fn on_submit(mut self, f: impl Fn(String, &mut Window, &mut App) + 'static) -> Self {
        self.on_submit = Some(Rc::new(f));
        self
    }

    fn target(&self) -> Target {
        Target {
            id: self.id.clone(),
            label: self.label.clone().unwrap_or_default(),
            placeholder: self.placeholder.clone().unwrap_or_default(),
            numeric: self.numeric,
            max_length: self.max_length,
            on_change: self.on_change.clone(),
            on_submit: self.on_submit.clone(),
        }
    }
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

struct FieldState {
    focus: FocusHandle,
    fade: Option<Fade>,
    editing: bool,
    caret_epoch: Instant,
    blink_due: Option<Instant>,
}

impl FieldState {
    /// Starts the 100 ms color fade when the look changes; the first look
    /// shows at once.
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
        phase % 2 == 0
    }

    fn next_blink(&self, now: Instant) -> Instant {
        let n = now.duration_since(self.caret_epoch).as_millis() / CARET_BLINK.as_millis() + 1;
        self.caret_epoch + CARET_BLINK * n as u32
    }
}

impl RenderOnce for TextInput {
    fn render(self, window: &mut Window, cx: &mut App) -> impl IntoElement {
        let st = window.use_keyed_state(self.id.clone(), cx, |_, cx| FieldState {
            focus: cx.focus_handle(),
            fade: None,
            editing: false,
            caret_epoch: Instant::now(),
            blink_due: None,
        });
        let kb = keyboard::for_window(window, cx);
        let focus = st.read(cx).focus.clone();
        let editing = match kb.as_ref() {
            Some(kb) => {
                keyboard::sync_target(kb, &self.value, self.target(), cx);
                kb.read(cx).model.is_target(&self.id)
            }
            None => focus.is_focused(window),
        };

        let look = if editing {
            (ACCENT, FOCUS_FILL)
        } else if self.invalid {
            (ERROR, PANEL)
        } else {
            (WHITE, PANEL)
        };
        let now = Instant::now();
        let (border, bg, caret, fading) = st.update(cx, |s, _| {
            if editing != s.editing {
                s.editing = editing;
                s.caret_epoch = now;
                s.blink_due = None;
            }
            let (border, bg) = s.colors(look);
            (border, bg, editing && s.caret_on(now), s.fading())
        });
        if fading {
            window.request_animation_frame();
        }
        if editing {
            schedule_blink(&st, now, window, cx);
        }

        let empty = self.value.is_empty();
        let shown: SharedString = if empty {
            self.placeholder.clone().unwrap_or_default()
        } else {
            self.value.clone()
        };

        let mut field = div()
            .flex()
            .items_center()
            .h(u(FIELD_H))
            .w_full()
            .px(u(20.))
            .border(u(4.))
            .border_color(border)
            .bg(bg)
            .font_family(theme::INTER)
            .font_weight(theme::touch_weight(300))
            .text_size(u(TEXT_PX))
            .line_height(u(32.))
            .relative()
            .overflow_hidden()
            .when(caret && empty, |d| {
                d.child(
                    caret_bar()
                        .absolute()
                        .left(u(20.))
                        .top(u((FIELD_H - 8.0 - CARET_H) * 0.5)),
                )
            })
            .child(
                div()
                    .whitespace_nowrap()
                    .text_color(if empty { ZINC_600 } else { WHITE })
                    .child(shown),
            )
            .when(caret && !empty, |d| d.child(caret_bar()));

        if kb.is_none() {
            field = field.track_focus(&focus).on_key_down(typing(
                self.value.to_string(),
                self.numeric,
                self.max_length,
                self.on_change.clone(),
                self.on_submit.clone(),
            ));
        }

        let target = self.target();
        let value = self.value.to_string();
        let open = move |window: &mut Window, cx: &mut App| match keyboard::for_window(window, cx) {
            Some(kb) => keyboard::open(&kb, target.clone(), &value, window, cx),
            None => window.focus(&focus, cx),
        };
        let press = press_state((self.id.clone(), "press"), window, cx);
        let root = div()
            .id(self.id.clone())
            .flex()
            .flex_col()
            .gap(u(8.))
            .w_full()
            .when_some(self.label, |d, l| {
                d.child(tracked(&l, 12., 600, 0.2, 16., WHITE))
            })
            .child(field);
        tappable(root, press, false, Some(Rc::new(open)))
    }
}

fn caret_bar() -> Div {
    div().flex_none().w(u(1.)).h(u(CARET_H)).bg(WHITE)
}

/// Redraws the window at the caret's next blink, once per blink.
fn schedule_blink(st: &Entity<FieldState>, now: Instant, window: &mut Window, cx: &mut App) {
    let due = st.read(cx).next_blink(now);
    if st.read(cx).blink_due == Some(due) {
        return;
    }
    st.update(cx, |s, _| s.blink_due = Some(due));
    window
        .spawn(cx, async move |cx| {
            cx.background_executor()
                .timer(due.saturating_duration_since(Instant::now()))
                .await;
            let _ = cx.update(|window, _| window.refresh());
        })
        .detach();
}

/// Physical typing for a focused field in a window without a keyboard.
fn typing(
    value: String,
    numeric: bool,
    max_length: usize,
    on_change: Option<OnChange<String>>,
    on_submit: Option<OnChange<String>>,
) -> impl Fn(&KeyDownEvent, &mut Window, &mut App) + 'static {
    move |e, window, cx| {
        let ks = &e.keystroke;
        if ks.modifiers.platform || ks.modifiers.control {
            return;
        }
        let mut next = value.clone();
        match ks.key.as_str() {
            "backspace" => {
                next.pop();
            }
            "enter" | "escape" | "tab" => {
                window.blur(cx);
                if let Some(f) = on_submit.as_ref() {
                    f(value.clone(), window, cx);
                }
                return;
            }
            _ => match ks.key_char.as_deref() {
                Some(c) if !c.chars().any(char::is_control) => next.push_str(c),
                _ => return,
            },
        }
        let next = keyboard::accept(&next, numeric, max_length);
        cx.stop_propagation();
        if next != value {
            if let Some(f) = on_change.as_ref() {
                f(next, window, cx);
            }
        }
    }
}
