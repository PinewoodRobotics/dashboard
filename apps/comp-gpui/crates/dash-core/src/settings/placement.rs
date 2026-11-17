//! Where each window goes, as a pure function of the display list
//! (apps/comp-godot/app/window_placement.gd):
//! - an override display index from the settings wins when it exists;
//! - otherwise the HUD takes the display that is exactly 1920x1080 and the
//!   touchscreen the one that is exactly 1920x515, fullscreen;
//! - two windows sharing a single display both stay windowed (a dev laptop);
//! - a display is never given to two windows: the first claim wins (HUD first).
//!
//! Display sizes are logical, so a scaled display matches when its logical
//! size times a common Windows scale factor is the design size.

use super::app::WindowsSettings;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WindowKey {
    Hud,
    Touch,
}

impl WindowKey {
    pub const ORDER: [WindowKey; 2] = [WindowKey::Hud, WindowKey::Touch];

    pub fn design(self) -> (f32, f32) {
        match self {
            WindowKey::Hud => (1920.0, 1080.0),
            WindowKey::Touch => (1920.0, 515.0),
        }
    }

    fn override_index(self, o: &WindowsSettings) -> i32 {
        match self {
            WindowKey::Hud => o.hud_screen,
            WindowKey::Touch => o.touch_screen,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum Plan {
    Fullscreen { screen: usize, reason: String },
    Windowed { reason: String },
}

impl Plan {
    pub fn reason(&self) -> &str {
        match self {
            Plan::Fullscreen { reason, .. } | Plan::Windowed { reason } => reason,
        }
    }
}

const SCALES: [f32; 5] = [1.0, 1.25, 1.5, 1.75, 2.0];

pub fn fits_design(logical: (f32, f32), key: WindowKey) -> bool {
    let (w, h) = key.design();
    SCALES
        .iter()
        .any(|k| (logical.0 * k - w).abs() < 1.0 && (logical.1 * k - h).abs() < 1.0)
}

/// `screens` are logical display sizes in display order; the result follows
/// [`WindowKey::ORDER`] for the windows that are open.
pub fn plan(
    screens: &[(f32, f32)],
    windows: &[WindowKey],
    overrides: &WindowsSettings,
) -> Vec<(WindowKey, Plan)> {
    let keys: Vec<WindowKey> = WindowKey::ORDER
        .into_iter()
        .filter(|k| windows.contains(k))
        .collect();
    let mut out: Vec<(WindowKey, Option<Plan>)> = keys.iter().map(|k| (*k, None)).collect();
    let mut claimed: Vec<usize> = Vec::new();
    for (key, slot) in out.iter_mut() {
        let idx = key.override_index(overrides);
        if idx >= 0 && (idx as usize) < screens.len() && !claimed.contains(&(idx as usize)) {
            *slot = Some(Plan::Fullscreen {
                screen: idx as usize,
                reason: "override".into(),
            });
            claimed.push(idx as usize);
        }
    }
    for (key, slot) in out.iter_mut() {
        if slot.is_some() {
            continue;
        }
        if screens.len() <= 1 && keys.len() > 1 {
            *slot = Some(Plan::Windowed {
                reason: "single screen".into(),
            });
            continue;
        }
        let found = (0..screens.len()).find(|i| !claimed.contains(i) && fits_design(screens[*i], *key));
        *slot = Some(match found {
            Some(i) => {
                claimed.push(i);
                Plan::Fullscreen {
                    screen: i,
                    reason: "exact size".into(),
                }
            }
            None => {
                let (w, h) = key.design();
                Plan::Windowed {
                    reason: format!("no {w}x{h} display"),
                }
            }
        });
    }
    out.into_iter()
        .map(|(k, p)| (k, p.expect("every window planned")))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use WindowKey::{Hud, Touch};

    const LAPTOP: (f32, f32) = (1366.0, 768.0);
    const HUD: (f32, f32) = (1920.0, 1080.0);
    const TOUCH: (f32, f32) = (1920.0, 515.0);
    const BOTH: [WindowKey; 2] = [Hud, Touch];

    fn auto() -> WindowsSettings {
        WindowsSettings::default()
    }

    fn ov(hud: i32, touch: i32) -> WindowsSettings {
        WindowsSettings {
            hud_screen: hud,
            touch_screen: touch,
        }
    }

    fn get(p: &[(WindowKey, Plan)], k: WindowKey) -> &Plan {
        &p.iter().find(|(key, _)| *key == k).unwrap().1
    }

    fn screen(p: &Plan) -> Option<usize> {
        match p {
            Plan::Fullscreen { screen, .. } => Some(*screen),
            Plan::Windowed { .. } => None,
        }
    }

    #[test]
    fn exact_sizes_pick_the_displays() {
        let p = plan(&[HUD, TOUCH], &BOTH, &auto());
        assert_eq!(*get(&p, Hud), Plan::Fullscreen { screen: 0, reason: "exact size".into() });
        assert_eq!(screen(get(&p, Touch)), Some(1));
    }

    #[test]
    fn reversed_order_follows_the_sizes() {
        let p = plan(&[TOUCH, HUD], &BOTH, &auto());
        assert_eq!(screen(get(&p, Hud)), Some(1));
        assert_eq!(screen(get(&p, Touch)), Some(0));
    }

    #[test]
    fn driver_station_with_laptop_panel() {
        let p = plan(&[LAPTOP, TOUCH, HUD], &BOTH, &auto());
        assert_eq!(screen(get(&p, Hud)), Some(2));
        assert_eq!(screen(get(&p, Touch)), Some(1));
    }

    #[test]
    fn single_screen_gives_two_windowed_windows() {
        for s in [LAPTOP, HUD] {
            let p = plan(&[s], &BOTH, &auto());
            assert_eq!(*get(&p, Hud), Plan::Windowed { reason: "single screen".into() });
            assert_eq!(screen(get(&p, Touch)), None);
        }
        assert_eq!(screen(get(&plan(&[], &BOTH, &auto()), Hud)), None, "no screens at all");
    }

    #[test]
    fn one_window_per_process_still_tiles_on_a_single_screen() {
        assert_eq!(screen(get(&plan(&[HUD], &[Hud], &auto()), Hud)), Some(0), "--screen=hud on a 1080p display");
        assert_eq!(screen(get(&plan(&[LAPTOP], &[Hud], &auto()), Hud)), None, "--screen=hud on a laptop panel");
        let t = plan(&[HUD, TOUCH], &[Touch], &auto());
        assert_eq!(t.len(), 1);
        assert_eq!(screen(get(&t, Touch)), Some(1));
    }

    #[test]
    fn missing_display_leaves_that_window_windowed() {
        let p = plan(&[LAPTOP, HUD], &BOTH, &auto());
        assert_eq!(screen(get(&p, Hud)), Some(1));
        assert_eq!(*get(&p, Touch), Plan::Windowed { reason: "no 1920x515 display".into() });
    }

    #[test]
    fn settings_overrides_win() {
        let p = plan(&[HUD, TOUCH, LAPTOP], &BOTH, &ov(2, -1));
        assert_eq!(*get(&p, Hud), Plan::Fullscreen { screen: 2, reason: "override".into() });
        assert_eq!(screen(get(&p, Touch)), Some(1), "the other window still matches by size");
        let swapped = plan(&[HUD, TOUCH], &BOTH, &ov(1, 0));
        assert_eq!(screen(get(&swapped, Hud)), Some(1));
        assert_eq!(screen(get(&swapped, Touch)), Some(0));
        let single = plan(&[LAPTOP], &BOTH, &ov(-1, 0));
        assert_eq!(screen(get(&single, Touch)), Some(0), "an explicit override is honored on a single screen");
        assert_eq!(screen(get(&single, Hud)), None);
    }

    #[test]
    fn a_screen_is_never_given_twice() {
        let p = plan(&[HUD, TOUCH], &BOTH, &ov(1, 1));
        assert_eq!(screen(get(&p, Hud)), Some(1), "first claim wins");
        assert_eq!(screen(get(&p, Touch)), None, "touch's 1920x515 display is taken");
        let q = plan(&[HUD, HUD, TOUCH], &BOTH, &ov(-1, 0));
        assert_eq!(screen(get(&q, Touch)), Some(0));
        assert_eq!(screen(get(&q, Hud)), Some(1), "HUD takes the next exact match");
    }

    #[test]
    fn out_of_range_override_falls_back_to_auto() {
        let p = plan(&[HUD, TOUCH], &BOTH, &ov(5, -1));
        assert_eq!(*get(&p, Hud), Plan::Fullscreen { screen: 0, reason: "exact size".into() });
    }

    #[test]
    fn scaled_displays_match_by_logical_size() {
        assert!(fits_design((1536.0, 864.0), Hud), "1920x1080 at 125%");
        assert!(fits_design((1280.0, 343.33), Touch), "1920x515 at 150%");
        assert!(!fits_design(LAPTOP, Hud));
    }
}
