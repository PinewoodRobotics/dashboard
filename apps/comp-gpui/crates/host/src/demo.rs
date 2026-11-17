//! `--demo-input`: scripted pointer input dispatched through the window like real input, so
//! hit testing, capture and the Godot round trip are all exercised. Each stage is logged as
//! `demo: <stage>` so an outside script can take screenshots in step.

use std::time::Duration;

use gpui_kit::*;

const STEP: Duration = Duration::from_millis(16);

fn log(stage: &str) {
    eprintln!("demo: {stage} at {}", protocol::now_us());
}

async fn wait(cx: &mut AsyncApp, duration: Duration) {
    cx.background_executor().timer(duration).await;
}

fn send(cx: &mut AsyncApp, window: AnyWindowHandle, input: PlatformInput) {
    cx.update_window(window, |_, window, cx| {
        window.dispatch_event(input, cx);
    })
    .ok();
}

async fn drag(
    cx: &mut AsyncApp,
    window: AnyWindowHandle,
    from: Point<Pixels>,
    step: Point<Pixels>,
    steps: u32,
    hold: Duration,
) {
    send(
        cx,
        window,
        PlatformInput::MouseDown(MouseDownEvent {
            button: MouseButton::Left,
            position: from,
            click_count: 1,
            ..Default::default()
        }),
    );
    let mut position = from;
    for _ in 0..steps {
        wait(cx, STEP).await;
        position = point(position.x + step.x, position.y + step.y);
        send(
            cx,
            window,
            PlatformInput::MouseMove(MouseMoveEvent {
                position,
                pressed_button: Some(MouseButton::Left),
                ..Default::default()
            }),
        );
    }
    log("drag held");
    wait(cx, hold).await;
    send(
        cx,
        window,
        PlatformInput::MouseUp(MouseUpEvent {
            button: MouseButton::Left,
            position,
            click_count: 1,
            ..Default::default()
        }),
    );
}

/// `view_point` is a point over the 3D view, `drawer_point` one over the drawer.
pub fn run(
    window: AnyWindowHandle,
    view_point: Point<Pixels>,
    drawer_point: Point<Pixels>,
    cx: &mut App,
) {
    cx.spawn(async move |cx| {
        wait(cx, Duration::from_secs(12)).await;
        log("start");
        wait(cx, Duration::from_secs(2)).await;

        log("drag on view");
        drag(
            cx,
            window,
            view_point,
            point(px(8.), px(1.5)),
            40,
            Duration::from_millis(2500),
        )
        .await;
        log("drag released");
        wait(cx, Duration::from_secs(3)).await;

        log("wheel on view");
        for _ in 0..12 {
            send(
                cx,
                window,
                PlatformInput::Scroll(ScrollEvent {
                    position: view_point,
                    delta: ScrollDelta::Lines(point(0., 1.)),
                    ..Default::default()
                }),
            );
            wait(cx, Duration::from_millis(30)).await;
        }
        log("wheel done");
        wait(cx, Duration::from_secs(3)).await;

        log("drag on drawer");
        drag(
            cx,
            window,
            drawer_point,
            point(px(-8.), px(0.)),
            30,
            Duration::from_millis(500),
        )
        .await;
        log("drawer drag released");
        wait(cx, Duration::from_secs(3)).await;
        log("done");
    })
    .detach();
}

/// Grows the window in small steps like a live resize drag, then holds still.
pub fn resize(window: AnyWindowHandle, cx: &mut App) {
    cx.spawn(async move |cx| {
        wait(cx, Duration::from_secs(12)).await;
        log("resize start");
        for step in 0..=20 {
            let grow = step as f32 * 12.0;
            cx.update_window(window, |_, window, _| {
                window.resize(size(px(1100. + grow), px(700. + grow * 0.4)));
            })
            .ok();
            wait(cx, Duration::from_millis(25)).await;
        }
        log("resize dragging stopped");
        wait(cx, Duration::from_secs(2)).await;
        log("resize settled");
        wait(cx, Duration::from_secs(1)).await;
        log("done");
    })
    .detach();
}
