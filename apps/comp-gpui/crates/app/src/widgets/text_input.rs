use std::rc::Rc;

use gpui_kit::prelude::FluentBuilder;
use gpui_kit::*;

use super::{OnChange, tracked};
use crate::theme::{self, ACCENT, ERROR, FOCUS_FILL, PANEL, WHITE, ZINC_600, u};

/// CustomTextInput.tsx. Typing comes from GPUI key events; the Godot port's
/// on-screen keyboard is not ported yet.
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
        self.on_change = Some(Rc::new(f));
        self
    }
}

impl RenderOnce for TextInput {
    fn render(self, window: &mut Window, cx: &mut App) -> impl IntoElement {
        let focus = window
            .use_keyed_state(self.id.clone(), cx, |_, cx| cx.focus_handle())
            .read(cx)
            .clone();
        let focused = focus.is_focused(window);
        let border = if focused {
            ACCENT
        } else if self.invalid {
            ERROR
        } else {
            WHITE
        };
        let bg = if focused { FOCUS_FILL } else { PANEL };
        let empty = self.value.is_empty();
        let shown: SharedString = if empty {
            self.placeholder.clone().unwrap_or_default()
        } else {
            self.value.clone()
        };

        let value = self.value.to_string();
        let numeric = self.numeric;
        let on_change = self.on_change.clone();
        let click_focus = focus.clone();
        let field = div()
            .id(self.id.clone())
            .track_focus(&focus)
            .flex()
            .items_center()
            .h(u(72.))
            .w_full()
            .px(u(20.))
            .border(u(4.))
            .border_color(border)
            .bg(bg)
            .font_family(theme::INTER)
            .font_weight(theme::touch_weight(300))
            .text_size(u(24.))
            .line_height(u(32.))
            .overflow_hidden()
            .child(
                div()
                    .whitespace_nowrap()
                    .text_color(if empty { ZINC_600 } else { WHITE })
                    .child(shown),
            )
            .when(focused, |d| {
                d.child(div().flex_none().w(u(2.)).h(u(28.)).bg(WHITE))
            })
            .on_mouse_down(MouseButton::Left, move |_, window, cx| {
                window.focus(&click_focus, cx);
            })
            .on_key_down(move |e, window, cx| {
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
                        return;
                    }
                    _ => match ks.key_char.as_deref() {
                        Some(c) if !c.chars().any(char::is_control) => next.push_str(c),
                        _ => return,
                    },
                }
                if numeric {
                    next.retain(|c| c.is_ascii_digit());
                }
                cx.stop_propagation();
                if next != value {
                    if let Some(f) = on_change.as_ref() {
                        f(next, window, cx);
                    }
                }
            });

        div()
            .flex()
            .flex_col()
            .gap(u(8.))
            .w_full()
            .when_some(self.label, |d, l| {
                d.child(tracked(&l, 12., 600, 0.2, 16., WHITE))
            })
            .child(field)
    }
}
