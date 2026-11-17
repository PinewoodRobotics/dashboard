use crate::icons::sf;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum TabId {
    Auto,
    Settings,
    Effects,
    Howard,
    Robot3d,
    Visual,
    Gallery,
}

pub struct TabInfo {
    pub label: &'static str,
    pub symbol: u32,
    pub active_symbol: u32,
}

impl TabId {
    /// touchscreen/model/defs.ts order; the Record tab is dropped as in the
    /// Godot port, and the widget gallery is a dev-only tab off the dock.
    pub const ALL: [TabId; 6] = [
        TabId::Auto,
        TabId::Settings,
        TabId::Effects,
        TabId::Howard,
        TabId::Robot3d,
        TabId::Visual,
    ];

    pub fn info(self) -> TabInfo {
        let (label, symbol, active_symbol) = match self {
            TabId::Auto => ("Auto Select", sf::AUTO, sf::AUTO_FILL),
            TabId::Settings => ("Connection Settings", sf::SETTINGS, sf::SETTINGS_FILL),
            TabId::Effects => ("Special Effects", sf::EFFECTS, sf::EFFECTS_FILL),
            TabId::Howard => ("Pictures of Howard", sf::HOWARD, sf::HOWARD_FILL),
            TabId::Robot3d => ("Robot 3D", sf::ROBOT3D, sf::ROBOT3D_FILL),
            TabId::Visual => ("Visual Settings", sf::VISUAL, sf::VISUAL_FILL),
            TabId::Gallery => ("Widget Gallery", sf::EFFECTS, sf::EFFECTS_FILL),
        };
        TabInfo {
            label,
            symbol,
            active_symbol,
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "auto" => TabId::Auto,
            "settings" => TabId::Settings,
            "effects" => TabId::Effects,
            "howard" => TabId::Howard,
            "robot3d" => TabId::Robot3d,
            "visual" => TabId::Visual,
            "gallery" => TabId::Gallery,
            _ => return None,
        })
    }

    pub fn key(self) -> &'static str {
        match self {
            TabId::Auto => "auto",
            TabId::Settings => "settings",
            TabId::Effects => "effects",
            TabId::Howard => "howard",
            TabId::Robot3d => "robot3d",
            TabId::Visual => "visual",
            TabId::Gallery => "gallery",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum PanelId {
    Map,
    Intake,
}

impl PanelId {
    pub const ALL: [PanelId; 2] = [PanelId::Map, PanelId::Intake];

    pub fn info(self) -> TabInfo {
        match self {
            PanelId::Map => TabInfo {
                label: "Map",
                symbol: sf::MAP,
                active_symbol: sf::MAP_FILL,
            },
            PanelId::Intake => TabInfo {
                label: "Intake Speed",
                symbol: sf::INTAKE,
                active_symbol: sf::INTAKE_FILL,
            },
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "map" | "showMap" => Some(PanelId::Map),
            "intake" | "intakeSpeed" => Some(PanelId::Intake),
            _ => None,
        }
    }
}

/// useTouchscreenLayoutState.ts. `None` active tab is the driver base,
/// `None` open panel a collapsed drawer. Views animate from this state.
#[derive(Clone, Debug)]
pub struct LayoutState {
    pub active_tab: Option<TabId>,
    pub open_panel: Option<PanelId>,
    /// The panel whose content stays while the drawer collapses.
    pub last_panel: Option<PanelId>,
    pub dock_open: bool,
    pub dock_closing: bool,
    /// One-shot: the next drawer width change jumps (a swipe animated it).
    pub skip_panel_anim: bool,
    /// One-shot: the next dismissal has no exit slide (a swipe animated it).
    pub skip_exit_anim: bool,
    pub rail: Vec<TabId>,
    pub dock: Vec<TabId>,
}

impl Default for LayoutState {
    fn default() -> Self {
        Self {
            active_tab: None,
            open_panel: None,
            last_panel: None,
            dock_open: false,
            dock_closing: false,
            skip_panel_anim: false,
            skip_exit_anim: false,
            rail: vec![TabId::Auto, TabId::Settings],
            dock: TabId::ALL.to_vec(),
        }
    }
}

impl LayoutState {
    pub fn is_driver_base(&self) -> bool {
        self.active_tab.is_none()
    }

    pub fn display_panel(&self) -> Option<PanelId> {
        self.open_panel.or(self.last_panel)
    }

    fn begin_dock_close(&mut self) {
        if self.dock_open {
            self.dock_closing = true;
        }
    }

    pub fn switch_tab(&mut self, id: TabId) {
        self.begin_dock_close();
        self.skip_exit_anim = false;
        self.active_tab = if self.active_tab == Some(id) {
            None
        } else {
            Some(id)
        };
    }

    pub fn dismiss_overlay(&mut self) {
        self.begin_dock_close();
        if self.active_tab.is_some() {
            self.active_tab = None;
            self.skip_exit_anim = false;
        }
    }

    pub fn dismiss_overlay_immediate(&mut self) {
        self.begin_dock_close();
        if self.active_tab.is_some() {
            self.active_tab = None;
            self.skip_exit_anim = true;
        }
    }

    pub fn toggle_panel(&mut self, id: PanelId) {
        self.begin_dock_close();
        self.skip_panel_anim = false;
        if self.open_panel == Some(id) {
            self.open_panel = None;
        } else {
            self.open_panel = Some(id);
            self.last_panel = Some(id);
        }
    }

    pub fn close_panel_immediate(&mut self) {
        if self.open_panel.is_none() {
            return;
        }
        self.begin_dock_close();
        self.open_panel = None;
        self.skip_panel_anim = true;
    }

    pub fn toggle_dock(&mut self) {
        if self.dock_open && !self.dock_closing {
            self.dock_closing = true;
        } else if !self.dock_open {
            self.dock_open = true;
        }
    }

    pub fn close_dock(&mut self) {
        if self.dock_open && !self.dock_closing {
            self.dock_closing = true;
        }
    }

    pub fn finish_dock_close(&mut self) {
        if self.dock_closing {
            self.dock_closing = false;
            self.dock_open = false;
        }
    }

    pub fn take_skip_panel_anim(&mut self) -> bool {
        std::mem::take(&mut self.skip_panel_anim)
    }

    pub fn take_skip_exit_anim(&mut self) -> bool {
        std::mem::take(&mut self.skip_exit_anim)
    }
}
