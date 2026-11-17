//! Auto selector (AutoSelector.tsx, Godot's auto_tab.gd). The left third
//! (PathListPane.tsx): "No Auto", then every exported auto, then the autos
//! the robot lists that the export lacks (selectable, no preview); a tap
//! views one. The rest (PathDetailPane.tsx): its left half has the viewed
//! auto's title, file and description over the Select button (Selecting...,
//! Selected, Locked During Match); its right half the preview box, or the
//! Howard error picture when the auto has no preview. The preview can expand
//! over the whole tab. An amber banner covers the top while the robot is
//! enabled, a popup when another dashboard fights over the selection.
//! Selection logic lives in `dash_core::selection_sync`; the export summary
//! and Reload Autos are on the Settings tab ([`export_box`]).

mod export_box;
mod kit;
mod preview;
mod scrub;

use std::cell::Cell;
use std::rc::Rc;
use std::time::{SystemTime, UNIX_EPOCH};

use dash_core::autos::FreshnessLevel;
use dash_core::selection_sync::NONE;
use gpui_kit::prelude::FluentBuilder;
use gpui_kit::*;

pub(super) use export_box::export_box;
use kit::{Btn, Look, ROSE, ROSE_TEXT, text};
use preview::{Notes, PreviewState};

use super::TouchScreen;
use crate::autos::{AutoService, service};
use crate::icons::lucide;
use crate::theme::{
    ACCENT, BLACK, CARD, PANEL, RAIL_W, TOUCH_DESIGN, TRANSPARENT, WHITE, ZINC_100, ZINC_300,
    ZINC_500, alpha, hex, touch_weight, u,
};
use crate::widgets::{Axis2, Scroll, press_state, reveal_in_scroll, tappable};

const NO_AUTO_DESC: &str = "Do not run an autonomous routine";
const RETRY_TEXT: &str = "Failed to load. Tap to retry.";
const EMPTY_TEXT: &str = "No paths found";
const NO_AUTO_DETAIL: &str =
    "Do not run an autonomous routine. The robot will stay still during autonomous.";
const ROBOT_ONLY_FILE: &str = "On the robot: no preview, not exported";
const ROBOT_ONLY_DETAIL: &str =
    "The robot has this auto, but the dashboard's export does not, so there is no preview.";
const UNCONFIRMED_FILE: &str = "Saved choice: not exported, robot list unknown";
const UNCONFIRMED_DETAIL: &str = "This saved choice is not in the dashboard's export. It is held back until the robot's auto list confirms it, and dropped if the robot does not have it.";
const PATHS_DIFFER: &str =
    "The robot's paths differ from this export: the preview may be out of date";
const LOCK_TEXT: &str = "Auto selector locked while match is active.";
const AMBER_BG: Rgba = Rgba {
    r: 0.961,
    g: 0.62,
    b: 0.043,
    a: 0.15,
};
const AMBER_LINE: Rgba = Rgba {
    r: 0.984,
    g: 0.749,
    b: 0.141,
    a: 0.6,
};
const AMBER_TEXT: Rgba = hex(0xfef3c7);
const PAD: f32 = 16.0;
const DESC_MAX_W: f32 = 660.0;
const CARD_H: f32 = 192.0;
const STATUS_H: f32 = 180.0;
const LIST_GAP: f32 = 10.0;

fn export_old(age: &str) -> String {
    format!("This export is {age} old: re-export the autos if a path changed")
}

struct TabState {
    viewing: String,
    expanded: bool,
    no_preview_key: Option<String>,
    howard_pick: usize,
    reveal: Option<String>,
    width: Rc<Cell<f32>>,
    preview: Entity<PreviewState>,
    _observe: Subscription,
}

#[derive(Clone)]
struct CardInfo {
    name: String,
    title: String,
    file: String,
    desc: String,
}

/// One row of the auto list (PathCard.tsx): 192 px on #3c3c3c, 10 px
/// padding, a 4 px border that is green for the selected auto and white for
/// the one being viewed; the title with the file name below, the
/// description, and "Currently Selected" (kept in place, transparent unless
/// selected), 8 px apart and clipped to the card.
fn card(
    id: SharedString,
    c: &CardInfo,
    active: bool,
    viewing: bool,
    on_tap: impl Fn(&mut Window, &mut App) + 'static,
    window: &mut Window,
    cx: &mut App,
) -> impl IntoElement {
    let press = press_state(id.clone(), window, cx);
    let border = if active {
        ACCENT
    } else if viewing {
        WHITE
    } else {
        TRANSPARENT
    };
    let el = div()
        .id(id)
        .flex_none()
        .w_full()
        .h(u(CARD_H))
        .overflow_hidden()
        .bg(CARD)
        .border(u(4.))
        .border_color(border)
        .p(u(10.))
        .child(
            div()
                .flex()
                .flex_col()
                .gap(u(8.))
                .child(
                    div()
                        .flex()
                        .flex_col()
                        .child(text(c.title.clone(), 28., 600, WHITE, 28.))
                        .when(!c.file.is_empty(), |d| {
                            d.child(text(c.file.clone(), 14., 400, ZINC_500, 20.).mt(u(4.)))
                        }),
                )
                .child(text(c.desc.clone(), 18., 400, WHITE, 27.))
                .child(text(
                    "Currently Selected",
                    18.,
                    700,
                    if active { ACCENT } else { TRANSPARENT },
                    18.,
                )),
        );
    tappable(el, press, false, Some(Rc::new(on_tap)))
}

/// PathListPane.tsx's loading, empty and error rows.
fn status_row(
    id: SharedString,
    message: &'static str,
    color: Rgba,
    on_tap: Option<Rc<dyn Fn(&mut Window, &mut App)>>,
    window: &mut Window,
    cx: &mut App,
) -> impl IntoElement {
    let press = press_state(id.clone(), window, cx);
    let el = div()
        .id(id)
        .flex_none()
        .w_full()
        .h(u(STATUS_H))
        .flex()
        .items_center()
        .justify_center()
        .p(u(10.))
        .bg(CARD)
        .child(text(message, 18., 400, color, 27.).text_center());
    tappable(el, press, on_tap.is_none(), on_tap)
}

fn random_pick() -> usize {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.subsec_nanos() as usize / 7919)
}

pub fn render(
    _ts: &TouchScreen,
    key: u64,
    window: &mut Window,
    cx: &mut Context<TouchScreen>,
) -> impl IntoElement {
    let svc = service(cx);
    svc.update(cx, |s, _| s.note_tab_drawn());
    let state = window.use_keyed_state(("auto-tab", key), cx, {
        let svc = svc.clone();
        move |_, cx| {
            let start = svc.update(cx, |s, _| std::mem::take(&mut s.tab_start));
            TabState {
                viewing: start.view.clone().unwrap_or_default(),
                expanded: start.expanded,
                no_preview_key: None,
                howard_pick: random_pick(),
                reveal: start.view,
                width: Rc::new(Cell::new(TOUCH_DESIGN.width - 2.0 * RAIL_W)),
                preview: cx.new(|_| PreviewState::default()),
                _observe: cx.observe(&svc, |_, _, cx| cx.notify()),
            }
        }
    });

    let s = svc.read(cx);
    let names: Vec<String> = s
        .model
        .library
        .names()
        .into_iter()
        .map(String::from)
        .collect();
    let (robot_only, unconfirmed, active, locked, conflict, selected, robot_known, robot_auto) = s
        .read_link(cx, |sync, link| {
            (
                sync.robot_only_names(),
                if sync.awaiting_robot_list() {
                    vec![sync.selected.clone()]
                } else {
                    Vec::new()
                },
                sync.active_name(link),
                sync.locked(link),
                sync.conflict,
                sync.selected.clone(),
                sync.robot_known(link),
                sync.robot_auto(link),
            )
        });
    let extra: Vec<String> = robot_only.iter().chain(&unconfirmed).cloned().collect();
    let all: Vec<String> = names.iter().chain(&extra).cloned().collect();

    let viewing = state.update(cx, |st, _| {
        if st.viewing != NONE && !st.viewing.is_empty() && !all.contains(&st.viewing) {
            st.viewing.clear();
        }
        if st.viewing.is_empty() {
            st.viewing = if !active.is_empty() {
                active.clone()
            } else {
                names.first().cloned().unwrap_or_else(|| NONE.to_owned())
            };
        }
        st.viewing.clone()
    });

    let s = svc.read(cx);
    let lib = &s.model.library;
    let lib_loaded = lib.is_loaded();
    let mut cards = vec![CardInfo {
        name: NONE.into(),
        title: "No Auto".into(),
        file: String::new(),
        desc: NO_AUTO_DESC.into(),
    }];
    cards.extend(names.iter().map(|n| CardInfo {
        name: n.clone(),
        title: lib.display_name(n).to_owned(),
        file: format!("{n}.auto"),
        desc: lib.description(n).to_owned(),
    }));
    cards.extend(extra.iter().map(|n| {
        CardInfo {
            name: n.clone(),
            title: n.clone(),
            file: if robot_only.contains(n) {
                ROBOT_ONLY_FILE
            } else {
                UNCONFIRMED_FILE
            }
            .into(),
            desc: String::new(),
        }
    }));
    let status = names.is_empty().then(|| {
        if lib_loaded {
            (EMPTY_TEXT, ZINC_500, false)
        } else {
            (RETRY_TEXT, ROSE_TEXT, true)
        }
    });

    let is_robot_only = viewing != NONE && !names.contains(&viewing) && extra.contains(&viewing);
    let failed = if viewing != NONE && !is_robot_only {
        lib.auto_error(&viewing).to_owned()
    } else {
        String::new()
    };
    let has_preview = viewing != NONE && !is_robot_only && failed.is_empty();
    let no_preview_key = if viewing == NONE || has_preview {
        None
    } else if is_robot_only {
        Some(format!("robot:{viewing}"))
    } else {
        Some(format!("failed:{viewing}"))
    };

    let validity = s.read_link(cx, |sync, link| sync.validity(link, &viewing));
    let mut warning = validity.text().to_owned();
    if warning.is_empty() && names.contains(&viewing) {
        if !lib.auto_error(&viewing).is_empty() {
            warning = "Preview failed to load".into();
        } else if !lib.auto_note(&viewing).is_empty() {
            warning = "Event copy broken: older preview".into();
        }
    }
    let fresh = s.freshness(cx);
    if warning.is_empty() {
        match fresh.as_ref().map(|f| f.level) {
            Some(FreshnessLevel::Differs) => warning = PATHS_DIFFER.into(),
            Some(FreshnessLevel::Old) => warning = export_old(&fresh.as_ref().unwrap().age),
            _ => {}
        }
    }
    let robot_line = if robot_known {
        format!(
            "Robot reports: {}",
            if robot_auto == NONE {
                "No Auto"
            } else {
                &robot_auto
            }
        )
    } else {
        "Robot: not connected".to_owned()
    };
    let start = (s.model.inputs.pre_match && !locked)
        .then(|| s.model.start_check(&viewing))
        .flatten();
    let button = s.read_link(cx, |sync, link| sync.button_for(link, &viewing));
    let (title, file, desc, desc_color) = if viewing == NONE {
        (
            "No Auto".to_owned(),
            None,
            NO_AUTO_DETAIL.to_owned(),
            ZINC_300,
        )
    } else if is_robot_only {
        let listed = robot_only.contains(&viewing);
        (
            viewing.clone(),
            Some(
                if listed {
                    ROBOT_ONLY_FILE
                } else {
                    UNCONFIRMED_FILE
                }
                .to_owned(),
            ),
            if listed {
                ROBOT_ONLY_DETAIL
            } else {
                UNCONFIRMED_DETAIL
            }
            .to_owned(),
            WHITE,
        )
    } else {
        (
            lib.display_name(&viewing).to_owned(),
            Some(format!("{viewing}.auto")),
            lib.description(&viewing).to_owned(),
            WHITE,
        )
    };
    let (expanded, howard_pick, preview_state, width_cell, reveal) = state.update(cx, |st, _| {
        if !has_preview {
            st.expanded = false;
        }
        if st.no_preview_key != no_preview_key {
            if no_preview_key.is_some() {
                st.howard_pick = random_pick();
            }
            st.no_preview_key = no_preview_key.clone();
        }
        (
            st.expanded,
            st.howard_pick,
            st.preview.clone(),
            st.width.clone(),
            st.reveal.clone(),
        )
    });
    let tab_w = width_cell.get();

    let list_id: ElementId = ("auto-list", key).into();
    let mut list = Scroll::new(list_id.clone(), Axis2::Vertical)
        .content(div().flex().flex_col().gap(u(LIST_GAP)).p(u(10.)));
    for (i, c) in cards.iter().enumerate() {
        let st = state.clone();
        let name = c.name.clone();
        list = list.child(card(
            SharedString::from(format!("auto-card-{key}-{i}")),
            c,
            c.name == active,
            c.name == viewing,
            move |_, cx| {
                st.update(cx, |s, cx| {
                    s.viewing = name.clone();
                    cx.notify();
                })
            },
            window,
            cx,
        ));
    }
    if let Some((message, color, retry)) = status {
        let svc = svc.clone();
        let on_tap: Option<Rc<dyn Fn(&mut Window, &mut App)>> = retry.then(|| {
            Rc::new(move |_: &mut Window, cx: &mut App| svc.update(cx, |s, cx| s.reload(cx)))
                as Rc<dyn Fn(&mut Window, &mut App)>
        });
        list = list.child(status_row(
            SharedString::from(format!("auto-status-{key}")),
            message,
            color,
            on_tap,
            window,
            cx,
        ));
    }
    let reveal_range = reveal.and_then(|n| {
        let i = cards.iter().position(|c| c.name == n)? as f32;
        let top = 10.0 + i * (CARD_H + LIST_GAP);
        Some((top, top + CARD_H))
    });
    let reveal_state = state.clone();
    let reveal_probe = canvas(
        move |_, window, cx| {
            if let Some((a, b)) = reveal_range {
                if reveal_in_scroll(list_id.clone(), Axis2::Vertical, a, b, window, cx) {
                    reveal_state.update(cx, |s, _| s.reveal = None);
                    window.request_animation_frame();
                }
            }
        },
        |_, _, _, _| {},
    )
    .absolute()
    .size_0();
    let list_pane = div()
        .relative()
        .flex_none()
        .w(relative(1.0 / 3.0))
        .h_full()
        .child(list)
        .child(reveal_probe);

    let select_svc = svc.clone();
    let select_view = viewing.clone();
    let select = Btn::new(("auto-select", key), Look::Dark)
        .text(button.text)
        .selected(button.selected)
        .disabled(!button.enabled)
        .on_tap(move |_, cx| {
            let v = select_view.clone();
            select_svc.update(cx, |s, cx| {
                s.with_link(cx, |sync, link, now| sync.select(link, &v, now));
                cx.notify();
            })
        });
    let detail_left = div()
        .flex_none()
        .w(relative(0.5))
        .h_full()
        .overflow_hidden()
        .p(u(PAD))
        .flex()
        .flex_col()
        .child(
            div()
                .flex()
                .flex_col()
                .gap(u(10.))
                .child(
                    div()
                        .flex()
                        .flex_col()
                        .child(text(title, 34., 600, WHITE, 34.))
                        .when_some(file, |d, f| {
                            d.child(text(f, 16., 400, ZINC_500, 20.8).mt(u(4.)))
                        }),
                )
                .when(!desc.is_empty(), |d| {
                    d.child(text(desc, 22., 400, desc_color, 26.4).max_w(u(DESC_MAX_W)))
                }),
        )
        .child(div().flex_1())
        .child(div().flex().child(select));

    let detail_right = if viewing == NONE {
        None
    } else if has_preview {
        let st = state.clone();
        let on_expand: Rc<dyn Fn(bool, &mut Window, &mut App)> = Rc::new(move |on, _, cx| {
            st.update(cx, |s, cx| {
                s.expanded = on;
                cx.notify();
            })
        });
        let list_w = if expanded { 0.0 } else { tab_w / 3.0 };
        let detail_w = tab_w - list_w;
        let right_w = if expanded { detail_w } else { detail_w * 0.5 } - 2.0 * PAD;
        Some(
            preview::render(
                key,
                svc.clone(),
                preview_state,
                &viewing,
                Notes {
                    robot_line,
                    warning,
                    start,
                },
                expanded,
                on_expand,
                right_w,
                window,
                cx,
            )
            .into_any_element(),
        )
    } else {
        Some(super::howard_tab::howard_error(howard_pick as u64).into_any_element())
    };

    let banner = locked.then(|| {
        div()
            .absolute()
            .top_0()
            .left_0()
            .right_0()
            .px(u(20.))
            .pt(u(8.))
            .pb(u(8.))
            .bg(AMBER_BG)
            .border_b(px(1.))
            .border_color(AMBER_LINE)
            .child(text(LOCK_TEXT, 18., 600, AMBER_TEXT, 21.6).whitespace_nowrap())
    });

    let popup = conflict.then(|| conflict_popup(key, &svc, &selected, locked));

    let width_probe = canvas(
        move |b, window, _| {
            let rem = f32::from(window.rem_size()).max(0.0001);
            width_cell.set(f32::from(b.size.width) / rem);
        },
        |_, _, _, _| {},
    )
    .absolute()
    .top_0()
    .left_0()
    .size_full();

    div()
        .relative()
        .size_full()
        .bg(PANEL)
        .flex()
        .flex_row()
        .child(width_probe)
        .when(!expanded, |d| d.child(list_pane))
        .child(
            div()
                .flex_1()
                .min_w_0()
                .h_full()
                .flex()
                .flex_row()
                .when(!expanded, |d| d.child(detail_left))
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .h_full()
                        .p(u(PAD))
                        .children(detail_right),
                ),
        )
        .children(banner)
        .children(popup)
}

/// "Auto Sync Conflict Detected": another dashboard keeps changing the
/// robot's auto away from this one's choice.
fn conflict_popup(
    key: u64,
    svc: &Entity<AutoService>,
    selected: &str,
    locked: bool,
) -> Stateful<Div> {
    let name = if selected.is_empty() { NONE } else { selected };
    let lead = "Robot auto changed too many times in a short window while this dashboard was trying to enforce ";
    let body = format!("{lead}{name}.");
    let body = StyledText::new(body).with_highlights(vec![(
        lead.len()..lead.len() + name.len(),
        HighlightStyle {
            font_weight: Some(touch_weight(600)),
            ..Default::default()
        },
    )]);
    let dismiss_svc = svc.clone();
    let resync_svc = svc.clone();
    let shadow: Hsla = alpha(BLACK, 0.25).into();
    div()
        .id(("auto-conflict", key))
        .absolute()
        .top_0()
        .left_0()
        .size_full()
        .occlude()
        .bg(alpha(BLACK, 0.7))
        .flex()
        .items_center()
        .justify_center()
        .p(u(24.))
        .child(
            div()
                .w_full()
                .max_w(u(860.))
                .bg(hex(0x1f1f1f))
                .border(u(2.))
                .border_color(alpha(ROSE, 0.7))
                .p(u(24.))
                .shadow(vec![
                    BoxShadow::new(px(0.), px(25.), shadow)
                        .blur_radius(px(50.))
                        .spread_radius(px(-12.)),
                ])
                .flex()
                .flex_col()
                .child(
                    div()
                        .flex()
                        .flex_row()
                        .gap(u(16.))
                        .child(div().mt(u(4.)).child(lucide("triangle-alert", 32., ROSE_TEXT)))
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .flex()
                                .flex_col()
                                .child(text("Auto Sync Conflict Detected", 40., 600, WHITE, 40.))
                                .child(
                                    div()
                                        .mt(u(12.))
                                        .text_size(u(26.))
                                        .line_height(u(32.5))
                                        .text_color(ZINC_100)
                                        .child(body),
                                )
                                .child(
                                    text(
                                        "Another dashboard is likely connected and fighting for auto selection.",
                                        22.,
                                        400,
                                        ZINC_300,
                                        27.5,
                                    )
                                    .mt(u(8.)),
                                ),
                        ),
                )
                .child(
                    div()
                        .mt(u(24.))
                        .flex()
                        .flex_row()
                        .justify_end()
                        .gap(u(12.))
                        .child(
                            Btn::new(("auto-dismiss", key), Look::Dialog)
                                .text("Dismiss")
                                .on_tap(move |_, cx| {
                                    dismiss_svc.update(cx, |s, cx| {
                                        s.sync.dismiss_conflict();
                                        s.sync.take_events();
                                        cx.notify();
                                    })
                                }),
                        )
                        .child(
                            Btn::new(("auto-resync", key), Look::DialogPrimary)
                                .text("Resync Now")
                                .disabled(locked)
                                .on_tap(move |_, cx| {
                                    resync_svc.update(cx, |s, cx| {
                                        s.with_link(cx, |sync, link, now| sync.resync(link, now));
                                        cx.notify();
                                    })
                                }),
                        ),
                ),
        )
}
