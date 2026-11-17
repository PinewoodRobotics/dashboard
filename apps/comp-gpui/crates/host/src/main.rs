mod iosurface;
mod shell;
mod test_pattern;
mod viewport;

use gpui_kit::*;

use crate::shell::Shell;
use crate::test_pattern::TestPattern;
use crate::viewport::ViewportSource;

gpui_kit::actions!(host, [Quit]);

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let auto_drawer = args.iter().any(|a| a == "--auto-drawer");
    let source = if args.iter().any(|a| a == "--test-pattern") {
        ViewportSource::TestPattern(TestPattern::new(1280, 720)?)
    } else {
        anyhow::bail!("usage: host --test-pattern");
    };

    gpui_kit::application().run(move |cx| {
        gpui_kit::init(cx);
        cx.on_action(|_: &Quit, cx| cx.quit());
        cx.bind_keys([KeyBinding::new("cmd-q", Quit, None)]);
        cx.on_window_closed(|cx, _| cx.quit()).detach();

        let options = WindowOptions {
            window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
                None,
                size(px(1100.), px(700.)),
                cx,
            ))),
            titlebar: Some(TitlebarOptions {
                title: Some("PWRUP comp-gpui".into()),
                ..Default::default()
            }),
            ..Default::default()
        };
        let (window, _) = gpui_kit::open_window(options, cx, move |_, cx| {
            cx.new(|_| Shell::new(source, auto_drawer))
        })
        .expect("failed to open window");
        cx.activate(true);
        window
            .update(cx, |_, window, _| window.activate_window())
            .ok();
    });
    Ok(())
}
