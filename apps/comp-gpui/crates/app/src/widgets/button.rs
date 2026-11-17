use std::rc::Rc;

use gpui_kit::*;

use super::tap::{press_state, tappable};
use super::{OnTap, dpx};
use crate::theme::{self, ACCENT, BLACK, OUTLINE, WHITE, ZINC_400, alpha, u};

/// The web touchscreen's inline Tailwind buttons.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ButtonStyle {
    /// Header Reset / Reconnect (SettingsHeader.tsx, VisualTab.tsx).
    Outline,
    /// Panel Reset (MapSettingsPanel.tsx): full width, text-xl.
    OutlineBlock,
    Primary,
    /// Driver camera presets (DriverTab.tsx).
    Pill,
}

#[derive(IntoElement)]
pub struct Button {
    id: ElementId,
    text: SharedString,
    style: ButtonStyle,
    disabled: bool,
    selected: bool,
    on_tap: Option<OnTap>,
}

impl Button {
    pub fn new(
        id: impl Into<ElementId>,
        text: impl Into<SharedString>,
        style: ButtonStyle,
    ) -> Self {
        Self {
            id: id.into(),
            text: text.into(),
            style,
            disabled: false,
            selected: false,
            on_tap: None,
        }
    }

    pub fn disabled(mut self, disabled: bool) -> Self {
        self.disabled = disabled;
        self
    }

    pub fn selected(mut self, selected: bool) -> Self {
        self.selected = selected;
        self
    }

    pub fn on_tap(mut self, f: impl Fn(&mut Window, &mut App) + 'static) -> Self {
        self.on_tap = Some(Rc::new(f));
        self
    }
}

impl RenderOnce for Button {
    fn render(self, window: &mut Window, cx: &mut App) -> impl IntoElement {
        let state = press_state(self.id.clone(), window, cx);
        let pressed = state.read(cx).pressed && !self.disabled;
        let style = self.style;
        let disabled = self.disabled;

        let mut el = div()
            .id(self.id.clone())
            .flex()
            .flex_none()
            .items_center()
            .justify_center()
            .font_family(theme::INTER)
            .whitespace_nowrap();

        el = match style {
            ButtonStyle::Outline | ButtonStyle::OutlineBlock => {
                let bg = if pressed {
                    alpha(WHITE, 0.1)
                } else {
                    alpha(WHITE, 0.0)
                };
                let mut e = el
                    .h(u(48.))
                    .px(u(24.))
                    .border(u(2.))
                    .border_color(OUTLINE)
                    .bg(bg)
                    .text_color(ZINC_400)
                    .font_weight(theme::touch_weight(600));
                if style == ButtonStyle::Outline {
                    e = e.text_size(u(14.)).line_height(u(20.));
                    if !disabled && !pressed {
                        e = e.hover(|s| s.bg(alpha(WHITE, 0.05)));
                    }
                } else {
                    e = e.w_full().text_size(u(20.)).line_height(u(28.));
                }
                if disabled {
                    e = e.opacity(0.5);
                }
                e
            }
            ButtonStyle::Primary => el
                .h(u(48.))
                .px(u(32.))
                .bg(ACCENT)
                .text_color(BLACK)
                .text_size(u(14.))
                .line_height(u(20.))
                .font_weight(theme::touch_weight(600))
                .opacity(if disabled {
                    0.3
                } else if pressed {
                    0.7
                } else {
                    1.0
                }),
            ButtonStyle::Pill => {
                let sel = self.selected;
                let mut e = el
                    .size(u(40.))
                    .rounded_full()
                    .text_size(u(14.))
                    .line_height(u(20.))
                    .font_weight(theme::touch_weight(500))
                    .bg(if sel { WHITE } else { alpha(WHITE, 0.1) })
                    .text_color(if sel { BLACK } else { alpha(WHITE, 0.6) });
                if sel {
                    let glow: Hsla = alpha(WHITE, 0.2).into();
                    e = e.shadow(vec![
                        BoxShadow::new(px(0.), dpx(window, 10.), glow)
                            .blur_radius(dpx(window, 15.))
                            .spread_radius(dpx(window, -3.)),
                        BoxShadow::new(px(0.), dpx(window, 4.), glow)
                            .blur_radius(dpx(window, 6.))
                            .spread_radius(dpx(window, -4.)),
                    ]);
                } else {
                    e = e.hover(|s| s.bg(alpha(WHITE, 0.2)));
                }
                e
            }
        };

        tappable(el.child(self.text), state, disabled, self.on_tap)
    }
}
