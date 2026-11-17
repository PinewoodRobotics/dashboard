mod godot;
mod iosurface;
mod shell;
mod test_pattern;
mod viewport;

use gpui_kit::*;

use crate::godot::{GodotConfig, GodotProcess};
use crate::shell::Shell;
use crate::test_pattern::TestPattern;
use crate::viewport::{GodotView, ViewportSource};

gpui_kit::actions!(host, [Quit]);

fn arg_value(args: &[String], key: &str) -> Option<String> {
    let index = args.iter().position(|a| a == key)?;
    args.get(index + 1).cloned()
}

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let auto_drawer = args.iter().any(|a| a == "--auto-drawer");
    let (source, messages) = if args.iter().any(|a| a == "--test-pattern") {
        (
            ViewportSource::TestPattern(TestPattern::new(1280, 720)?),
            None,
        )
    } else {
        let mut config = GodotConfig::from_env();
        if let Some(fps) = arg_value(&args, "--fps") {
            config.fps = fps.parse()?;
        }
        let (process, messages) = GodotProcess::spawn(&config)?;
        (
            ViewportSource::Godot(GodotView::new(process)),
            Some(messages),
        )
    };

    gpui_kit::application().run(move |cx| {
        gpui_kit::init(cx);
        cx.on_action(|_: &Quit, cx| cx.quit());
        cx.bind_keys([KeyBinding::new("cmd-q", Quit, None)]);
        cx.set_menus(vec![
            Menu::new("comp-gpui").items([MenuItem::action("Quit comp-gpui", Quit)]),
        ]);
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
            cx.new(|cx| {
                if let Some(messages) = messages {
                    cx.spawn(async move |this, cx| {
                        let mut activated = false;
                        while let Ok(message) = messages.recv().await {
                            let first_surfaces =
                                !activated && matches!(message, protocol::ToHost::Surfaces { .. });
                            let alive = this.update(cx, |shell: &mut Shell, cx| {
                                if let ViewportSource::Godot(view) = shell.source_mut() {
                                    view.on_message(message);
                                }
                                if first_surfaces {
                                    cx.activate(true);
                                }
                                cx.notify();
                            });
                            activated |= first_surfaces;
                            if alive.is_err() {
                                break;
                            }
                        }
                    })
                    .detach();
                }
                Shell::new(source, auto_drawer)
            })
        })
        .expect("failed to open window");
        cx.activate(true);
        window
            .update(cx, |_, window, _| window.activate_window())
            .ok();
    });
    Ok(())
}
