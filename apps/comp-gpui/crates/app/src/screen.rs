use gpui_kit::*;

/// Scales the window's UI so the design size fills it: one rem is one
/// design pixel, and every size in the screens is in rems.
pub fn fit(window: &mut Window, design: Size<f32>) -> f32 {
    let vp = window.viewport_size();
    let scale = (f32::from(vp.width) / design.width)
        .min(f32::from(vp.height) / design.height)
        .max(0.05);
    if (f32::from(window.rem_size()) - scale).abs() > 1e-4 {
        window.set_rem_size(px(scale));
    }
    scale
}
