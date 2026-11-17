mod button;
mod keyboard;
mod pill;
mod scroll;
mod selector;
mod slider;
mod tap;
mod text;
mod text_input;

pub use button::{Button, ButtonStyle};
pub use pill::status_pill;
pub use scroll::{Axis2, Scroll};
pub use selector::{Selector, SelectorOption, toggle};
pub use slider::{Slider, SliderHint};
pub use tap::{on_tap, press_state, tappable};
pub use text::{label, tracked};
pub use text_input::TextInput;

use std::rc::Rc;

use gpui_kit::*;

pub type OnTap = Rc<dyn Fn(&mut Window, &mut App)>;
pub type OnChange<T> = Rc<dyn Fn(T, &mut Window, &mut App)>;

/// Design pixels to window pixels, for the APIs that take `Pixels`
/// (shadows, painting).
pub fn dpx(window: &Window, x: f32) -> Pixels {
    window.rem_size() * x
}
