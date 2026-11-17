mod demo;
mod shell;

use std::time::Duration;

use gpui_kit::*;
use host::bridge3d::Bridge3d;
use host::godot::GodotConfig;
use host::test_pattern::TestPattern;

use crate::shell::{DRAWER_WIDTH, KIOSK_VIEW_PX, Layout, ShellOptions, open_shell_window};

gpui_kit::actions!(host, [Quit]);

const USAGE: &str = "\
host [options]
  --test-pattern        show a host-written shared texture instead of Godot
  --kiosk               robot view full-bleed at 1920x515 device pixels, like the touchscreen
  --fps N               robot view frame rate (default 120)
  --minimap-fps N       HUD minimap view frame rate (default 30)
  --no-minimap          start with the minimap view inactive
  --second-window       also open a second window with its own orbit view
  --demo-input          drive scripted pointer input (logged as `demo:` lines)
  --demo-resize         grow the window in steps like a live resize, then hold still
  --no-idle-return      robot camera stays where it was dragged
  --log-stats SECS      print the overlay to stderr every SECS seconds
  --auto-drawer         toggle the drawer every 2 s
  env GODOT_BIN, PWRUP_ROBOT_GLB, PWRUP_FIELD_GLB override the Godot binary and models";

fn arg_value(args: &[String], key: &str) -> Option<String> {
    let index = args.iter().position(|a| a == key)?;
    args.get(index + 1).cloned()
}

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.iter().any(|a| a == "--help" || a == "-h") {
        println!("{USAGE}");
        return Ok(());
    }
    let flag = |name: &str| args.iter().any(|a| a == name);
    let layout = if flag("--kiosk") {
        Layout::Kiosk
    } else {
        Layout::Spike
    };
    let options = ShellOptions {
        layout,
        robot_fps: arg_value(&args, "--fps")
            .map(|v| v.parse())
            .transpose()?
            .unwrap_or(120),
        minimap_fps: arg_value(&args, "--minimap-fps")
            .map(|v| v.parse())
            .transpose()?
            .unwrap_or(30),
        minimap: !flag("--no-minimap"),
        auto_drawer: flag("--auto-drawer"),
        log_stats: arg_value(&args, "--log-stats")
            .map(|v| v.parse::<f32>())
            .transpose()?
            .map(Duration::from_secs_f32),
    };
    let log_stats = options.log_stats;
    let test_pattern = flag("--test-pattern");
    let second_window = flag("--second-window");
    let demo_input = flag("--demo-input");
    let demo_resize = flag("--demo-resize");
    let mut config = GodotConfig::from_env();
    if flag("--no-idle-return") {
        config.extra_args.push("--no-idle-return".into());
    }

    #[cfg(windows)]
    host::win_log::install_stderr_logger();
    gpui_kit::application().run(move |cx| {
        gpui_kit::init(cx);
        host::present::install();
        cx.on_action(|_: &Quit, cx| cx.quit());
        cx.bind_keys([KeyBinding::new("cmd-q", Quit, None)]);
        cx.set_menus(vec![
            Menu::new("comp-gpui").items([MenuItem::action("Quit comp-gpui", Quit)]),
        ]);
        cx.on_window_closed(|cx, _| {
            if cx.windows().is_empty() {
                cx.quit();
            }
        })
        .detach();

        let (bridge, pattern) = if test_pattern {
            (
                None,
                Some(TestPattern::new(1280, 720).expect("test pattern surface")),
            )
        } else {
            match Bridge3d::start(config, cx) {
                Ok(bridge) => (Some(bridge), None),
                Err(error) => {
                    eprintln!("host: {error:#}");
                    cx.quit();
                    return;
                }
            }
        };

        let content = match layout {
            Layout::Kiosk => size(px(960.), px(257.5)),
            _ => size(px(1100.), px(700.)),
        };
        let Some((window, _)) = open_shell_window(
            cx,
            bridge.clone(),
            pattern,
            options,
            content,
            "PWRUP comp-gpui",
        ) else {
            eprintln!("host: failed to open window");
            cx.quit();
            return;
        };
        if layout == Layout::Kiosk {
            window
                .update(cx, |_, window, _| {
                    let scale = window.scale_factor();
                    window.resize(size(
                        px(KIOSK_VIEW_PX.0 / scale),
                        px(KIOSK_VIEW_PX.1 / scale),
                    ));
                })
                .ok();
        }
        if second_window && bridge.is_some() {
            open_shell_window(
                cx,
                bridge,
                None,
                ShellOptions {
                    layout: Layout::Second,
                    robot_fps: 60,
                    minimap_fps: 0,
                    minimap: false,
                    auto_drawer: false,
                    log_stats,
                },
                size(px(720.), px(480.)),
                "PWRUP comp-gpui (second window)",
            );
        }
        cx.activate(true);
        window
            .update(cx, |_, window, _| window.activate_window())
            .ok();
        if demo_input {
            let bounds = window
                .update(cx, |_, window, _| window.viewport_size())
                .unwrap_or(size(px(1100.), px(700.)));
            let view_point = point(bounds.width * 0.3, bounds.height * 0.4);
            let drawer_point = point(bounds.width - px(32. + DRAWER_WIDTH / 2.), px(200.));
            demo::run(window, view_point, drawer_point, cx);
        }
        if demo_resize {
            demo::resize(window, cx);
        }
    });
    Ok(())
}
