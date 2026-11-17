use gpui_kit::*;

use crate::mock::MockData;
use crate::theme::u;

const MINIMAP: Bounds<f32> = Bounds {
    origin: Point { x: 540.0, y: 480.0 },
    size: Size {
        width: 840.0,
        height: 1080.0 + 19.2 - 480.0,
    },
};

/// MiniMap3D.tsx's frame around the 3D placeholder.
pub fn render(_data: &MockData, _window: &mut Window) -> impl IntoElement {
    let fill = crate::placeholder::VIEW3D_FILL;
    div()
        .absolute()
        .left(u(MINIMAP.origin.x))
        .top(u(MINIMAP.origin.y))
        .w(u(MINIMAP.size.width))
        .h(u(MINIMAP.size.height))
        .child(
            canvas(
                |_, _, _| {},
                move |b, _, window, _| {
                    let rx = b.size.width * 0.3;
                    let ry = b.size.height * 0.3;
                    let (l, t) = (b.origin.x, b.origin.y);
                    let (r, btm) = (l + b.size.width, t + b.size.height);
                    let mut path = PathBuilder::fill();
                    path.move_to(point(l, btm));
                    path.line_to(point(l, t + ry));
                    arc(
                        &mut path,
                        point(l + rx, t + ry),
                        rx,
                        ry,
                        std::f32::consts::PI,
                        1.5 * std::f32::consts::PI,
                    );
                    path.line_to(point(r - rx, t));
                    arc(
                        &mut path,
                        point(r - rx, t + ry),
                        rx,
                        ry,
                        1.5 * std::f32::consts::PI,
                        2.0 * std::f32::consts::PI,
                    );
                    path.line_to(point(r, btm));
                    path.close();
                    if let Ok(p) = path.build() {
                        window.paint_path(p, fill);
                    }
                },
            )
            .absolute()
            .top_0()
            .left_0()
            .size_full(),
        )
        .child(
            div()
                .absolute()
                .top_0()
                .left_0()
                .size_full()
                .flex()
                .items_center()
                .justify_center()
                .text_size(u(18.))
                .line_height(u(27.))
                .text_color(crate::theme::ZINC_500)
                .child("Minimap (3D)"),
        )
}

fn arc(path: &mut PathBuilder, c: Point<Pixels>, rx: Pixels, ry: Pixels, from: f32, to: f32) {
    const STEPS: usize = 24;
    for i in 1..=STEPS {
        let a = from + (to - from) * i as f32 / STEPS as f32;
        path.line_to(point(c.x + rx * a.cos(), c.y + ry * a.sin()));
    }
}
