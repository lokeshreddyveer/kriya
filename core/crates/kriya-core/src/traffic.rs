//! The red, yellow and green window buttons: what each does for a plain click or a click with keys held, per app,
//! which apps are left alone, and what a hover menu offers. The shell finds the button under the pointer and carries out
//! the action; this module decides which action applies.

use std::collections::{HashMap, HashSet};

use serde::{Deserialize, Serialize};

use crate::actions::modifiers as m;
use crate::windows::WindowLayout;

pub const MAX_HOVER_ACTIONS: usize = 16;
/// Apps whose windows must never be intercepted: the login screen and system surfaces have no real window buttons.
pub const BUILTIN_EXCLUSIONS: [&str; 5] = [
    "com.apple.loginwindow",
    "com.apple.ScreenSaver.Engine",
    "com.apple.systemuiserver",
    "com.apple.dock",
    "com.apple.screencaptureui",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum TrafficButton {
    Close,
    Minimize,
    Zoom,
}

pub const ALL_BUTTONS: [TrafficButton; 3] = [
    TrafficButton::Close,
    TrafficButton::Minimize,
    TrafficButton::Zoom,
];

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize, uniffi::Enum)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum TrafficAction {
    /// Let macOS handle the click as it normally does.
    Native,
    /// Swallow the click: the button does nothing.
    DoNothing,
    CloseWindow,
    QuitApp,
    HideApp,
    HideOtherApps,
    MinimizeWindow,
    MinimizeAllWindows,
    /// Fill the display without native full screen. Doing it again restores the previous size.
    Maximize,
    ToggleFullScreen,
    Center,
    /// Closes the window, and quits the app when it was the app's last window.
    CloseOrQuit,
    /// Brings back the app's most recently minimized window.
    RestoreMinimized,
    /// Puts the window back to the size and place it had before the last move.
    RestoreSize,
    /// Opens the radial menu for this window, to pick a place for it.
    LayoutPalette,
    Snap {
        layout: WindowLayout,
    },
    /// A saved action from the action library.
    Run {
        action_id: String,
    },
}

impl TrafficAction {
    pub fn title(&self) -> String {
        match self {
            TrafficAction::Native => "Normal behavior".into(),
            TrafficAction::DoNothing => "Do nothing".into(),
            TrafficAction::CloseWindow => "Close window".into(),
            TrafficAction::QuitApp => "Quit app".into(),
            TrafficAction::HideApp => "Hide app".into(),
            TrafficAction::HideOtherApps => "Hide other apps".into(),
            TrafficAction::MinimizeWindow => "Minimize window".into(),
            TrafficAction::MinimizeAllWindows => "Minimize all windows of the app".into(),
            TrafficAction::Maximize => "Maximize (not full screen)".into(),
            TrafficAction::ToggleFullScreen => "Full screen".into(),
            TrafficAction::Center => "Center window".into(),
            TrafficAction::CloseOrQuit => "Close, or quit if it is the last window".into(),
            TrafficAction::RestoreMinimized => "Bring back a minimized window".into(),
            TrafficAction::RestoreSize => "Restore previous size".into(),
            TrafficAction::LayoutPalette => "Choose a place (radial menu)".into(),
            TrafficAction::Snap { layout } => format!("Snap: {}", layout.title()),
            TrafficAction::Run { .. } => "Run a saved action".into(),
        }
    }

    pub fn referenced_action(&self) -> Option<&str> {
        match self {
            TrafficAction::Run { action_id } => Some(action_id),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct TrafficBinding {
    pub button: TrafficButton,
    /// The modifier keys held with the click, exactly. 0 is a plain click.
    pub modifiers: u64,
    pub action: TrafficAction,
}

/// The actions offered when the pointer rests on a button.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct HoverSet {
    pub button: TrafficButton,
    pub actions: Vec<TrafficAction>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
#[serde(default)]
pub struct TrafficConfig {
    pub bindings: Vec<TrafficBinding>,
    pub hover_enabled: bool,
    pub hover_delay_ms: u32,
    pub hover_sets: Vec<HoverSet>,
    pub excluded_app_ids: Vec<String>,
    /// Ask before a window button quits an app.
    pub confirm_quit: bool,
    /// What a double-click on a window's title bar does. `Native` leaves macOS's own behavior.
    pub title_double_click: TrafficAction,
    /// What a middle-click on a window's title bar does.
    pub title_middle_click: TrafficAction,
}

impl Default for TrafficConfig {
    fn default() -> Self {
        TrafficConfig {
            bindings: Vec::new(),
            hover_enabled: false,
            hover_delay_ms: 700,
            hover_sets: Vec::new(),
            excluded_app_ids: Vec::new(),
            confirm_quit: true,
            title_double_click: TrafficAction::Native,
            title_middle_click: TrafficAction::Native,
        }
    }
}

fn clean_bindings(list: &[TrafficBinding]) -> Vec<TrafficBinding> {
    let mut seen = HashSet::new();
    list.iter()
        .map(|b| TrafficBinding {
            modifiers: b.modifiers & (m::SHIFT | m::CONTROL | m::OPTION | m::COMMAND),
            ..b.clone()
        })
        .filter(|b| seen.insert((b.button, b.modifiers)))
        .collect()
}

impl TrafficConfig {
    pub fn sanitized(mut self) -> Self {
        self.bindings = clean_bindings(&self.bindings);
        self.hover_delay_ms = self.hover_delay_ms.clamp(300, 3000);
        let mut seen_buttons = HashSet::new();
        self.hover_sets.retain(|s| seen_buttons.insert(s.button));
        for set in &mut self.hover_sets {
            let mut seen = HashSet::new();
            set.actions.retain(|a| {
                !matches!(a, TrafficAction::Native | TrafficAction::DoNothing)
                    && seen.insert(a.clone())
            });
            set.actions.truncate(MAX_HOVER_ACTIONS);
        }
        let mut seen = HashSet::new();
        self.excluded_app_ids = self
            .excluded_app_ids
            .iter()
            .map(|a| a.trim().to_string())
            .filter(|a| !a.is_empty() && seen.insert(a.clone()))
            .collect();
        self
    }

    pub fn is_excluded(&self, app_id: Option<&str>) -> bool {
        app_id.is_some_and(|a| {
            BUILTIN_EXCLUSIONS.contains(&a) || self.excluded_app_ids.iter().any(|x| x == a)
        })
    }

    pub fn referenced_actions(&self) -> Vec<String> {
        let mut ids: Vec<String> = self
            .bindings
            .iter()
            .filter_map(|b| b.action.referenced_action().map(str::to_string))
            .collect();
        for set in &self.hover_sets {
            ids.extend(
                set.actions
                    .iter()
                    .filter_map(|a| a.referenced_action().map(str::to_string)),
            );
        }
        ids.extend(
            self.title_double_click
                .referenced_action()
                .map(str::to_string),
        );
        ids.extend(
            self.title_middle_click
                .referenced_action()
                .map(str::to_string),
        );
        ids
    }

    pub fn hover_actions(&self, button: TrafficButton) -> Vec<TrafficAction> {
        self.hover_sets
            .iter()
            .find(|s| s.button == button)
            .map(|s| s.actions.clone())
            .unwrap_or_default()
    }

    /// True when nothing about the buttons is customized, so the shell can skip looking at clicks at all.
    pub fn is_idle(&self, profiles: &[TrafficProfile]) -> bool {
        self.bindings.is_empty()
            && self.title_double_click == TrafficAction::Native
            && self.title_middle_click == TrafficAction::Native
            && !(self.hover_enabled && self.hover_sets.iter().any(|s| !s.actions.is_empty()))
            && profiles.iter().all(|p| !p.enabled || p.bindings.is_empty())
    }
}

/// Button actions for one app, used instead of the general ones.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct TrafficProfile {
    pub id: String,
    pub app_id: String,
    pub enabled: bool,
    pub bindings: Vec<TrafficBinding>,
}

impl TrafficProfile {
    pub fn sanitized(mut self) -> Self {
        self.bindings = clean_bindings(&self.bindings);
        self
    }
}

/// The action for a click. An enabled profile for the app wins over the general bindings for the same button and keys,
/// including a profile saying "normal behavior" to switch a general binding off in that app. No match: normal behavior.
pub fn resolve(
    config: &TrafficConfig,
    profiles: &[TrafficProfile],
    app_id: Option<&str>,
    button: TrafficButton,
    modifiers: u64,
) -> TrafficAction {
    if config.is_excluded(app_id) {
        return TrafficAction::Native;
    }
    let modifiers = modifiers & (m::SHIFT | m::CONTROL | m::OPTION | m::COMMAND);
    let find = |list: &[TrafficBinding]| {
        list.iter()
            .find(|b| b.button == button && b.modifiers == modifiers)
            .map(|b| b.action.clone())
    };
    app_id
        .and_then(|id| profiles.iter().find(|p| p.enabled && p.app_id == id))
        .and_then(|p| find(&p.bindings))
        .or_else(|| find(&config.bindings))
        .unwrap_or(TrafficAction::Native)
}

/// Whether a drag-free click on this button needs Kriya at all for this app.
pub fn is_customized(
    config: &TrafficConfig,
    profiles: &[TrafficProfile],
    app_id: Option<&str>,
    button: TrafficButton,
) -> bool {
    ALL_MODIFIER_SETS
        .iter()
        .any(|mods| resolve(config, profiles, app_id, button, *mods) != TrafficAction::Native)
}

const ALL_MODIFIER_SETS: [u64; 8] = [
    0,
    m::SHIFT,
    m::CONTROL,
    m::OPTION,
    m::COMMAND,
    m::COMMAND | m::SHIFT,
    m::COMMAND | m::OPTION,
    m::CONTROL | m::OPTION,
];

/// A starting point the person can adopt and change: option-click closes everything, command-click quits, and so on.
pub fn suggested_bindings() -> Vec<TrafficBinding> {
    let b = |button, modifiers, action| TrafficBinding {
        button,
        modifiers,
        action,
    };
    vec![
        b(TrafficButton::Close, m::OPTION, TrafficAction::QuitApp),
        b(TrafficButton::Close, m::COMMAND, TrafficAction::HideApp),
        b(
            TrafficButton::Minimize,
            m::OPTION,
            TrafficAction::MinimizeAllWindows,
        ),
        // A plain click on the green button stays native. Option maximizes without full screen.
        b(TrafficButton::Zoom, m::OPTION, TrafficAction::Maximize),
        b(TrafficButton::Zoom, m::COMMAND, TrafficAction::Center),
    ]
}

pub fn suggested_hover_sets() -> Vec<HoverSet> {
    let snap = |layout| TrafficAction::Snap { layout };
    vec![HoverSet {
        button: TrafficButton::Zoom,
        actions: vec![
            snap(WindowLayout::LeftHalf),
            snap(WindowLayout::RightHalf),
            snap(WindowLayout::TopHalf),
            snap(WindowLayout::BottomHalf),
            snap(WindowLayout::TopLeft),
            snap(WindowLayout::TopRight),
            snap(WindowLayout::BottomLeft),
            snap(WindowLayout::BottomRight),
            snap(WindowLayout::FirstThird),
            snap(WindowLayout::CenterThird),
            snap(WindowLayout::LastThird),
            TrafficAction::Maximize,
            TrafficAction::Center,
            TrafficAction::ToggleFullScreen,
        ],
    }]
}

/// Checks that every saved action a configuration refers to exists.
pub fn missing_actions(refs: &[String], known: &HashSet<String>) -> Option<String> {
    refs.iter().find(|id| !known.contains(*id)).cloned()
}

/// "Option-click", "Command-Shift-click" and so on, for showing a binding.
pub fn describe_modifiers(bits: u64) -> String {
    let mut parts = Vec::new();
    if bits & m::CONTROL != 0 {
        parts.push("Control");
    }
    if bits & m::OPTION != 0 {
        parts.push("Option");
    }
    if bits & m::SHIFT != 0 {
        parts.push("Shift");
    }
    if bits & m::COMMAND != 0 {
        parts.push("Command");
    }
    if parts.is_empty() {
        "Click".into()
    } else {
        format!("{}-click", parts.join("-"))
    }
}

/// How many bindings each app profile adds, for a quick summary.
pub fn profile_counts(profiles: &[TrafficProfile]) -> HashMap<String, usize> {
    profiles
        .iter()
        .map(|p| (p.app_id.clone(), p.bindings.len()))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bind(button: TrafficButton, modifiers: u64, action: TrafficAction) -> TrafficBinding {
        TrafficBinding {
            button,
            modifiers,
            action,
        }
    }

    fn config(bindings: Vec<TrafficBinding>) -> TrafficConfig {
        TrafficConfig {
            bindings,
            ..TrafficConfig::default()
        }
    }

    #[test]
    fn nothing_is_customized_by_default() {
        let c = TrafficConfig::default();
        assert_eq!(
            resolve(&c, &[], Some("a"), TrafficButton::Close, 0),
            TrafficAction::Native
        );
        assert!(c.is_idle(&[]));
    }

    #[test]
    fn modifiers_must_match_exactly() {
        let c = config(vec![bind(
            TrafficButton::Close,
            m::OPTION,
            TrafficAction::QuitApp,
        )]);
        assert_eq!(
            resolve(&c, &[], None, TrafficButton::Close, m::OPTION),
            TrafficAction::QuitApp
        );
        assert_eq!(
            resolve(&c, &[], None, TrafficButton::Close, 0),
            TrafficAction::Native
        );
        assert_eq!(
            resolve(&c, &[], None, TrafficButton::Close, m::OPTION | m::SHIFT),
            TrafficAction::Native
        );
        assert_eq!(
            resolve(&c, &[], None, TrafficButton::Minimize, m::OPTION),
            TrafficAction::Native
        );
        // Keys that are not click modifiers (the arrow-key "fn" flag) are ignored.
        assert_eq!(
            resolve(&c, &[], None, TrafficButton::Close, m::OPTION | m::FUNCTION),
            TrafficAction::QuitApp
        );
    }

    #[test]
    fn an_app_profile_beats_the_general_bindings() {
        let c = config(vec![bind(TrafficButton::Close, 0, TrafficAction::HideApp)]);
        let profile = TrafficProfile {
            id: "p".into(),
            app_id: "com.editor".into(),
            enabled: true,
            bindings: vec![
                bind(TrafficButton::Close, 0, TrafficAction::Native),
                bind(TrafficButton::Zoom, 0, TrafficAction::Maximize),
            ],
        };
        let profiles = [profile];
        assert_eq!(
            resolve(&c, &profiles, Some("com.editor"), TrafficButton::Close, 0),
            TrafficAction::Native,
            "profile switches it off"
        );
        assert_eq!(
            resolve(&c, &profiles, Some("com.editor"), TrafficButton::Zoom, 0),
            TrafficAction::Maximize
        );
        assert_eq!(
            resolve(&c, &profiles, Some("com.other"), TrafficButton::Close, 0),
            TrafficAction::HideApp
        );
    }

    #[test]
    fn a_profile_falls_back_to_the_general_binding_for_what_it_does_not_mention() {
        let c = config(vec![bind(
            TrafficButton::Minimize,
            0,
            TrafficAction::HideApp,
        )]);
        let p = TrafficProfile {
            id: "p".into(),
            app_id: "a".into(),
            enabled: true,
            bindings: vec![bind(TrafficButton::Zoom, 0, TrafficAction::Center)],
        };
        assert_eq!(
            resolve(&c, &[p], Some("a"), TrafficButton::Minimize, 0),
            TrafficAction::HideApp
        );
    }

    #[test]
    fn disabled_profiles_are_ignored() {
        let c = config(vec![bind(TrafficButton::Close, 0, TrafficAction::HideApp)]);
        let p = TrafficProfile {
            id: "p".into(),
            app_id: "a".into(),
            enabled: false,
            bindings: vec![bind(TrafficButton::Close, 0, TrafficAction::QuitApp)],
        };
        assert_eq!(
            resolve(&c, &[p], Some("a"), TrafficButton::Close, 0),
            TrafficAction::HideApp
        );
    }

    #[test]
    fn excluded_and_system_apps_always_keep_native_behavior() {
        let mut c = config(vec![bind(TrafficButton::Close, 0, TrafficAction::QuitApp)]);
        c.excluded_app_ids = vec!["com.game".into()];
        assert_eq!(
            resolve(&c, &[], Some("com.game"), TrafficButton::Close, 0),
            TrafficAction::Native
        );
        assert_eq!(
            resolve(
                &c,
                &[],
                Some("com.apple.loginwindow"),
                TrafficButton::Close,
                0
            ),
            TrafficAction::Native
        );
        assert!(c.is_excluded(Some("com.apple.dock")));
        assert!(!c.is_excluded(None));
    }

    #[test]
    fn customization_is_detected_per_button_and_app() {
        let c = config(vec![bind(
            TrafficButton::Zoom,
            m::OPTION,
            TrafficAction::Center,
        )]);
        assert!(is_customized(&c, &[], Some("a"), TrafficButton::Zoom));
        assert!(!is_customized(&c, &[], Some("a"), TrafficButton::Close));
        assert!(!c.is_idle(&[]));
        let mut off = c.clone();
        off.excluded_app_ids = vec!["a".into()];
        assert!(!is_customized(&off, &[], Some("a"), TrafficButton::Zoom));
    }

    #[test]
    fn sanitizing_drops_repeats_bad_modifiers_and_useless_hover_entries() {
        let c = TrafficConfig {
            bindings: vec![
                bind(
                    TrafficButton::Close,
                    m::OPTION | m::FUNCTION,
                    TrafficAction::QuitApp,
                ),
                bind(TrafficButton::Close, m::OPTION, TrafficAction::HideApp),
            ],
            hover_delay_ms: 5,
            hover_sets: vec![
                HoverSet {
                    button: TrafficButton::Zoom,
                    actions: vec![
                        TrafficAction::Native,
                        TrafficAction::Center,
                        TrafficAction::Center,
                        TrafficAction::DoNothing,
                    ],
                },
                HoverSet {
                    button: TrafficButton::Zoom,
                    actions: vec![TrafficAction::QuitApp],
                },
            ],
            excluded_app_ids: vec![" a ".into(), "a".into(), String::new()],
            ..TrafficConfig::default()
        }
        .sanitized();
        assert_eq!(c.bindings.len(), 1);
        assert_eq!(c.bindings[0].action, TrafficAction::QuitApp);
        assert_eq!(c.hover_delay_ms, 300);
        assert_eq!(c.hover_sets.len(), 1);
        assert_eq!(c.hover_sets[0].actions, vec![TrafficAction::Center]);
        assert_eq!(c.excluded_app_ids, vec!["a".to_string()]);
    }

    #[test]
    fn hover_menus_need_a_button_with_actions() {
        let mut c = TrafficConfig {
            hover_enabled: true,
            ..TrafficConfig::default()
        };
        assert!(c.is_idle(&[]));
        c.hover_sets = suggested_hover_sets();
        assert!(!c.is_idle(&[]));
        assert_eq!(
            c.hover_actions(TrafficButton::Zoom).len(),
            suggested_hover_sets()[0].actions.len()
        );
        assert!(c.hover_actions(TrafficButton::Close).is_empty());
    }

    #[test]
    fn suggestions_are_valid_and_unique() {
        let c = config(suggested_bindings()).sanitized();
        assert_eq!(c.bindings.len(), suggested_bindings().len());
        assert!(suggested_hover_sets()[0].actions.len() <= MAX_HOVER_ACTIONS);
    }

    #[test]
    fn saved_action_references_are_collected() {
        let mut c = config(vec![bind(
            TrafficButton::Close,
            0,
            TrafficAction::Run {
                action_id: "a".into(),
            },
        )]);
        c.hover_sets = vec![HoverSet {
            button: TrafficButton::Zoom,
            actions: vec![TrafficAction::Run {
                action_id: "b".into(),
            }],
        }];
        let mut refs = c.referenced_actions();
        refs.sort();
        assert_eq!(refs, vec!["a".to_string(), "b".to_string()]);
        let known: HashSet<String> = ["a".to_string()].into();
        assert_eq!(missing_actions(&refs, &known), Some("b".to_string()));
    }

    #[test]
    fn titles_and_modifier_names_read_well() {
        assert_eq!(
            TrafficAction::Snap {
                layout: WindowLayout::LeftHalf
            }
            .title(),
            "Snap: Left half"
        );
        assert_eq!(describe_modifiers(0), "Click");
        assert_eq!(
            describe_modifiers(m::OPTION | m::COMMAND),
            "Option-Command-click"
        );
    }

    #[test]
    fn actions_round_trip_through_json() {
        let action = TrafficAction::Snap {
            layout: WindowLayout::TopLeft,
        };
        let json = serde_json::to_string(&action).unwrap();
        assert_eq!(
            serde_json::from_str::<TrafficAction>(&json).unwrap(),
            action
        );
    }

    #[test]
    fn title_bar_actions_keep_the_buttons_watched_and_count_as_references() {
        let mut config = TrafficConfig::default();
        assert!(config.is_idle(&[]));
        config.title_double_click = TrafficAction::Maximize;
        assert!(
            !config.is_idle(&[]),
            "a double-click action means clicks must be watched"
        );
        config.title_double_click = TrafficAction::Native;
        config.title_middle_click = TrafficAction::Run {
            action_id: "a1".into(),
        };
        assert!(!config.is_idle(&[]));
        assert_eq!(config.referenced_actions(), vec!["a1".to_string()]);
        assert!(
            TrafficConfig::default().confirm_quit,
            "quitting from a button asks first"
        );
    }

    #[test]
    fn the_new_actions_have_plain_titles() {
        for action in [
            TrafficAction::CloseOrQuit,
            TrafficAction::RestoreMinimized,
            TrafficAction::RestoreSize,
            TrafficAction::LayoutPalette,
        ] {
            assert!(!action.title().is_empty());
            assert!(action.referenced_action().is_none());
        }
    }
}
