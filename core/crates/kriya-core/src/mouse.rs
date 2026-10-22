//! Mouse and trackpad settings: what a preset holds, which preset applies to which device and app, and the files used
//! to share a preset. Nothing here touches the operating system.

use std::collections::{HashMap, HashSet};

use serde::{Deserialize, Serialize};

use crate::actions::NamedAction;
use crate::error::CoreError;

pub const DEFAULT_PRESET_ID: &str = "default";
/// Ids of the presets that ship with the app. They are read-only; duplicate one to change it.
pub const BUILTIN_PREFIX: &str = "builtin.";
pub const PRESET_FILE_KIND: &str = "mouse_preset";
pub const PRESET_FILE_VERSION: u32 = 1;
pub const MAX_PRESET_FILE_BYTES: usize = 1024 * 1024;
/// Mouse buttons are numbered like macOS numbers them: 0 left, 1 right, 2 middle, 3 and up the extra buttons.
pub const MAX_BUTTON: u32 = 31;

fn clamp(value: f64, low: f64, high: f64, fallback: f64) -> f64 {
    if value.is_nan() {
        fallback
    } else {
        value.clamp(low, high)
    }
}

// ---- scrolling -------------------------------------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
#[serde(default)]
pub struct ScrollAxis {
    /// Scroll the opposite way to how macOS is set for this device.
    pub reverse: bool,
    /// Multiplier on how far each movement scrolls. 1.0 is unchanged.
    pub speed: f64,
    /// 0 turns smoothing off; higher values glide longer after each wheel notch.
    pub smoothing: f64,
    /// 0 turns acceleration off; higher values scroll further the faster the wheel is turned.
    pub acceleration: f64,
    /// How strongly small wheel movements count. 1.0 is unchanged.
    pub sensitivity: f64,
}

impl Default for ScrollAxis {
    fn default() -> Self {
        ScrollAxis {
            reverse: false,
            speed: 1.0,
            smoothing: 0.0,
            acceleration: 0.0,
            sensitivity: 1.0,
        }
    }
}

impl ScrollAxis {
    pub fn sanitized(self) -> Self {
        ScrollAxis {
            reverse: self.reverse,
            speed: clamp(self.speed, 0.1, 5.0, 1.0),
            smoothing: clamp(self.smoothing, 0.0, 1.0, 0.0),
            acceleration: clamp(self.acceleration, 0.0, 1.0, 0.0),
            sensitivity: clamp(self.sensitivity, 0.25, 4.0, 1.0),
        }
    }

    /// True when this axis changes nothing, so the event can pass through untouched.
    pub fn is_neutral(&self) -> bool {
        *self == ScrollAxis::default()
    }
}

// ---- pointer ---------------------------------------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum PointerAccelerationPreset {
    /// Leave the macOS setting alone.
    #[default]
    System,
    /// A constant speed with no acceleration curve.
    Off,
    Low,
    Medium,
    High,
    Custom,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
#[serde(default)]
pub struct PointerSettings {
    pub acceleration: PointerAccelerationPreset,
    /// Tracking speed on macOS's 0 to 3 scale, used with `Custom`.
    pub custom_speed: f64,
    /// Modifier bits held to slow the pointer down for fine work. 0 turns precision mode off.
    pub precision_modifier: u64,
    /// The share of normal speed while precision mode is held, 0.1 to 1.0.
    pub precision_factor: f64,
}

impl Default for PointerSettings {
    fn default() -> Self {
        PointerSettings {
            acceleration: PointerAccelerationPreset::System,
            custom_speed: 0.6875,
            precision_modifier: 0,
            precision_factor: 0.4,
        }
    }
}

pub const POINTER_OFF: f64 = -1.0;

impl PointerSettings {
    pub fn sanitized(self) -> Self {
        PointerSettings {
            acceleration: self.acceleration,
            custom_speed: clamp(self.custom_speed, 0.0, 3.0, 0.6875),
            precision_modifier: self.precision_modifier & crate::actions::modifiers::ALL,
            precision_factor: clamp(self.precision_factor, 0.1, 1.0, 0.4),
        }
    }

    /// The tracking value to give macOS: `None` leaves it alone, `-1.0` switches acceleration off, otherwise the
    /// speed on macOS's 0 to 3 scale.
    pub fn tracking_value(&self) -> Option<f64> {
        match self.acceleration {
            PointerAccelerationPreset::System => None,
            PointerAccelerationPreset::Off => Some(POINTER_OFF),
            PointerAccelerationPreset::Low => Some(0.3125),
            PointerAccelerationPreset::Medium => Some(0.6875),
            PointerAccelerationPreset::High => Some(1.5),
            PointerAccelerationPreset::Custom => Some(self.custom_speed),
        }
    }

    /// The tracking value while precision mode is held. Only a real speed can be slowed; "System" and "Off" stay as they are.
    pub fn precision_tracking_value(&self) -> Option<f64> {
        match self.tracking_value() {
            Some(v) if v > 0.0 => Some((v * self.precision_factor).max(0.05)),
            other => other,
        }
    }
}

// ---- buttons ---------------------------------------------------------------------------------------------------------

/// When a button rule runs: when the button is clicked, or only when it is held down for a moment.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize, uniffi::Enum,
)]
#[serde(rename_all = "snake_case")]
pub enum ButtonTrigger {
    /// As soon as it is pressed. The way every rule worked before holding existed.
    #[default]
    Click,
    /// After it has been held for `MouseSettings::hold_ms`. A press let go sooner is an ordinary click.
    Hold,
}

/// Makes one mouse button (optionally with modifier keys held) run a saved action.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct ButtonRule {
    pub button: u32,
    pub modifiers: u64,
    pub action_id: String,
    /// A rule saved before holding existed has none, and is a click rule.
    #[serde(default)]
    pub trigger: ButtonTrigger,
}

/// How long a button is held before a hold rule runs, in milliseconds, and the range it may be set to.
pub const DEFAULT_HOLD_MS: u32 = 350;
pub const HOLD_MS_RANGE: std::ops::RangeInclusive<u32> = 150..=1500;

// ---- gestures --------------------------------------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum GestureDirection {
    Up,
    Down,
    Left,
    Right,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct GestureBinding {
    pub direction: GestureDirection,
    pub action_id: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
#[serde(default)]
pub struct GestureSettings {
    pub enabled: bool,
    /// Hold this button and move the mouse to draw a gesture.
    pub activation_button: u32,
    /// How far the pointer must move, in points, to count as a gesture. Smaller is more sensitive.
    pub threshold: f64,
    /// A gesture must finish within this time; a longer press is treated as an ordinary click.
    pub timeout_ms: u32,
    pub bindings: Vec<GestureBinding>,
    /// Hold the right button, then click the left.
    pub rocker_right_then_left: Option<String>,
    /// Hold the left button, then click the right.
    pub rocker_left_then_right: Option<String>,
}

impl Default for GestureSettings {
    fn default() -> Self {
        GestureSettings {
            enabled: false,
            activation_button: 2,
            threshold: 60.0,
            timeout_ms: 600,
            bindings: Vec::new(),
            rocker_right_then_left: None,
            rocker_left_then_right: None,
        }
    }
}

impl GestureSettings {
    pub fn sanitized(mut self) -> Self {
        self.activation_button = self.activation_button.clamp(2, MAX_BUTTON);
        self.threshold = clamp(self.threshold, 10.0, 400.0, 60.0);
        self.timeout_ms = self.timeout_ms.clamp(100, 3000);
        let mut seen = HashSet::new();
        self.bindings.retain(|b| seen.insert(b.direction));
        self
    }

    pub fn action_for(&self, direction: GestureDirection) -> Option<&str> {
        self.bindings
            .iter()
            .find(|b| b.direction == direction)
            .map(|b| b.action_id.as_str())
    }
}

// ---- a whole set of settings -----------------------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
#[serde(default)]
pub struct MouseSettings {
    pub vertical: ScrollAxis,
    pub horizontal: ScrollAxis,
    pub pointer: PointerSettings,
    pub buttons: Vec<ButtonRule>,
    pub gestures: GestureSettings,
    /// Hold these keys while turning the wheel to scroll sideways. 0 turns it off.
    pub horizontal_scroll_modifier: u64,
    /// Hold these keys to scroll with no smoothing, acceleration or other change. 0 turns it off.
    pub raw_scroll_modifier: u64,
    /// How long a button must be held before a hold rule runs.
    pub hold_ms: u32,
}

impl Default for MouseSettings {
    fn default() -> Self {
        MouseSettings {
            vertical: ScrollAxis::default(),
            horizontal: ScrollAxis::default(),
            pointer: PointerSettings::default(),
            buttons: Vec::new(),
            gestures: GestureSettings::default(),
            horizontal_scroll_modifier: 0,
            raw_scroll_modifier: 0,
            hold_ms: DEFAULT_HOLD_MS,
        }
    }
}

impl MouseSettings {
    /// Clamps every number into its allowed range and drops entries that cannot work (buttons 0 and 1, repeats).
    pub fn sanitized(mut self) -> Self {
        self.vertical = self.vertical.sanitized();
        self.horizontal = self.horizontal.sanitized();
        self.pointer = self.pointer.sanitized();
        self.gestures = self.gestures.sanitized();
        self.horizontal_scroll_modifier &= crate::actions::modifiers::ALL;
        self.raw_scroll_modifier &= crate::actions::modifiers::ALL;
        // The same keys cannot do both: the plain, untouched scroll wins.
        if self.horizontal_scroll_modifier == self.raw_scroll_modifier {
            self.horizontal_scroll_modifier = 0;
        }
        self.hold_ms = self
            .hold_ms
            .clamp(*HOLD_MS_RANGE.start(), *HOLD_MS_RANGE.end());
        // A button can have a click rule and a hold rule at once, but not two of the same kind.
        let mut seen = HashSet::new();
        self.buttons.retain(|b| {
            (2..=MAX_BUTTON).contains(&b.button) && seen.insert((b.button, b.modifiers, b.trigger))
        });
        self
    }

    pub fn referenced_action_ids(&self) -> Vec<String> {
        let mut ids: Vec<String> = self.buttons.iter().map(|b| b.action_id.clone()).collect();
        ids.extend(self.gestures.bindings.iter().map(|b| b.action_id.clone()));
        ids.extend(self.gestures.rocker_right_then_left.clone());
        ids.extend(self.gestures.rocker_left_then_right.clone());
        ids.sort();
        ids.dedup();
        ids
    }

    /// Points every action reference at a new id, for importing a preset whose actions were renumbered.
    pub fn remap_action_ids(&mut self, map: &HashMap<String, String>) {
        let swap = |id: &mut String| {
            if let Some(new) = map.get(id.as_str()) {
                *id = new.clone();
            }
        };
        self.buttons.iter_mut().for_each(|b| swap(&mut b.action_id));
        self.gestures
            .bindings
            .iter_mut()
            .for_each(|b| swap(&mut b.action_id));
        if let Some(id) = self.gestures.rocker_right_then_left.as_mut() {
            swap(id);
        }
        if let Some(id) = self.gestures.rocker_left_then_right.as_mut() {
            swap(id);
        }
    }
}

// ---- presets, assignments, configuration -----------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct MousePreset {
    pub id: String,
    pub name: String,
    /// Built-in presets cannot be deleted. Only `default` can be edited; the rest are templates to duplicate.
    pub is_builtin: bool,
    pub settings: MouseSettings,
}

impl MousePreset {
    pub fn is_read_only(&self) -> bool {
        self.id.starts_with(BUILTIN_PREFIX)
    }

    pub fn factory_default() -> Self {
        MousePreset {
            id: DEFAULT_PRESET_ID.to_string(),
            name: "Default".to_string(),
            is_builtin: true,
            settings: MouseSettings::default(),
        }
    }
}

/// The presets that ship with the app, other than the editable default.
pub fn builtin_templates() -> Vec<MousePreset> {
    let template = |id: &str, name: &str, settings: MouseSettings| MousePreset {
        id: format!("{BUILTIN_PREFIX}{id}"),
        name: name.to_string(),
        is_builtin: true,
        settings,
    };
    let reversed = ScrollAxis {
        reverse: true,
        ..ScrollAxis::default()
    };
    let smooth = ScrollAxis {
        smoothing: 0.5,
        acceleration: 0.3,
        ..ScrollAxis::default()
    };
    vec![
        template(
            "reversed",
            "Reversed scrolling",
            MouseSettings {
                vertical: reversed.clone(),
                ..MouseSettings::default()
            },
        ),
        template(
            "smooth",
            "Smooth scrolling",
            MouseSettings {
                vertical: smooth.clone(),
                horizontal: smooth,
                ..MouseSettings::default()
            },
        ),
        template(
            "precise",
            "Precise",
            MouseSettings {
                vertical: ScrollAxis {
                    speed: 0.6,
                    ..ScrollAxis::default()
                },
                horizontal: ScrollAxis {
                    speed: 0.6,
                    ..ScrollAxis::default()
                },
                pointer: PointerSettings {
                    acceleration: PointerAccelerationPreset::Low,
                    precision_modifier: crate::actions::modifiers::OPTION,
                    precision_factor: 0.3,
                    ..PointerSettings::default()
                },
                ..MouseSettings::default()
            },
        ),
        template(
            "fast",
            "Fast",
            MouseSettings {
                vertical: ScrollAxis {
                    speed: 1.8,
                    acceleration: 0.6,
                    ..ScrollAxis::default()
                },
                horizontal: ScrollAxis {
                    speed: 1.8,
                    acceleration: 0.6,
                    ..ScrollAxis::default()
                },
                pointer: PointerSettings {
                    acceleration: PointerAccelerationPreset::High,
                    ..PointerSettings::default()
                },
                ..MouseSettings::default()
            },
        ),
        template(
            "gaming",
            "Gaming (no acceleration)",
            MouseSettings {
                pointer: PointerSettings {
                    acceleration: PointerAccelerationPreset::Off,
                    ..PointerSettings::default()
                },
                ..MouseSettings::default()
            },
        ),
    ]
}

/// Makes one preset apply to a device, an app, or one device in one app.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct MouseAssignment {
    pub id: String,
    pub device_id: Option<String>,
    pub app_id: Option<String>,
    pub preset_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
#[serde(default)]
pub struct MouseConfig {
    /// Apps where Kriya leaves the mouse completely alone.
    pub excluded_app_ids: Vec<String>,
    /// The preset used when no assignment matches.
    pub default_preset_id: String,
}

impl Default for MouseConfig {
    fn default() -> Self {
        MouseConfig {
            excluded_app_ids: Vec::new(),
            default_preset_id: DEFAULT_PRESET_ID.to_string(),
        }
    }
}

impl MouseConfig {
    pub fn is_excluded(&self, app_id: Option<&str>) -> bool {
        app_id.is_some_and(|a| self.excluded_app_ids.iter().any(|x| x == a))
    }
}

/// Picks the preset for a device in an app. An assignment for both the device and the app beats one for the app,
/// which beats one for the device; with none, the default preset applies.
pub fn resolve_preset_id(
    assignments: &[MouseAssignment],
    default_preset_id: &str,
    device_id: Option<&str>,
    app_id: Option<&str>,
) -> String {
    fn matches(wanted: &Option<String>, actual: Option<&str>) -> bool {
        match (wanted, actual) {
            (None, _) => true,
            (Some(w), Some(a)) => w == a,
            (Some(_), None) => false,
        }
    }
    let mut best: Option<(u8, &MouseAssignment)> = None;
    for a in assignments {
        if a.device_id.is_none() && a.app_id.is_none() {
            continue;
        }
        if !matches(&a.device_id, device_id) || !matches(&a.app_id, app_id) {
            continue;
        }
        let score = u8::from(a.app_id.is_some()) * 2 + u8::from(a.device_id.is_some());
        if best.is_none_or(|(s, _)| score > s) {
            best = Some((score, a));
        }
    }
    best.map_or_else(
        || default_preset_id.to_string(),
        |(_, a)| a.preset_id.clone(),
    )
}

// ---- sharing a preset ------------------------------------------------------------------------------------------------

/// A preset on its own, with the saved actions it uses, so it can be shared and opened on another Mac.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PresetFile {
    pub format_version: u32,
    pub app: String,
    pub kind: String,
    pub name: String,
    pub settings: MouseSettings,
    pub actions: Vec<NamedAction>,
}

pub fn make_preset_file(
    preset: &MousePreset,
    all_actions: &[NamedAction],
) -> Result<String, CoreError> {
    let wanted = preset.settings.referenced_action_ids();
    let actions = all_actions
        .iter()
        .filter(|a| wanted.contains(&a.id))
        .cloned()
        .collect();
    let file = PresetFile {
        format_version: PRESET_FILE_VERSION,
        app: crate::backup::BACKUP_APP_NAME.to_string(),
        kind: PRESET_FILE_KIND.to_string(),
        name: preset.name.clone(),
        settings: preset.settings.clone(),
        actions,
    };
    Ok(serde_json::to_string_pretty(&file)?)
}

pub fn parse_preset_file(json: &str) -> Result<PresetFile, CoreError> {
    let not_ours = || CoreError::Backup {
        message: "the file is not a Kriya mouse preset".into(),
    };
    if json.len() > MAX_PRESET_FILE_BYTES {
        return Err(not_ours());
    }
    let file: PresetFile = serde_json::from_str(json).map_err(|_| not_ours())?;
    if file.app != crate::backup::BACKUP_APP_NAME || file.kind != PRESET_FILE_KIND {
        return Err(not_ours());
    }
    if file.format_version > PRESET_FILE_VERSION {
        return Err(CoreError::Backup {
            message: "the preset was made by a newer version of Kriya".into(),
        });
    }
    Ok(file)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::actions::Action;

    fn assignment(
        id: &str,
        device: Option<&str>,
        app: Option<&str>,
        preset: &str,
    ) -> MouseAssignment {
        MouseAssignment {
            id: id.into(),
            device_id: device.map(str::to_string),
            app_id: app.map(str::to_string),
            preset_id: preset.into(),
        }
    }

    #[test]
    fn settings_are_clamped() {
        let wild = MouseSettings {
            vertical: ScrollAxis {
                speed: 99.0,
                smoothing: -3.0,
                acceleration: f64::NAN,
                sensitivity: 0.0,
                reverse: true,
            },
            gestures: GestureSettings {
                threshold: 1.0,
                timeout_ms: 5,
                activation_button: 0,
                ..GestureSettings::default()
            },
            ..MouseSettings::default()
        }
        .sanitized();
        assert_eq!(wild.vertical.speed, 5.0);
        assert_eq!(wild.vertical.smoothing, 0.0);
        assert_eq!(wild.vertical.acceleration, 0.0);
        assert_eq!(wild.vertical.sensitivity, 0.25);
        assert!(wild.vertical.reverse);
        assert_eq!(wild.gestures.threshold, 10.0);
        assert_eq!(wild.gestures.timeout_ms, 100);
        assert_eq!(wild.gestures.activation_button, 2);
    }

    #[test]
    fn a_rule_saved_before_holding_existed_is_a_click_rule_and_the_hold_time_has_a_default() {
        let old = r#"{"buttons":[{"button":3,"modifiers":0,"action_id":"a"}]}"#;
        let settings: MouseSettings = serde_json::from_str(old).unwrap();
        assert_eq!(settings.buttons[0].trigger, ButtonTrigger::Click);
        assert_eq!(settings.hold_ms, DEFAULT_HOLD_MS);
        assert_eq!(MouseSettings::default().hold_ms, DEFAULT_HOLD_MS);
        let json = serde_json::to_string(&settings).unwrap();
        assert_eq!(
            serde_json::from_str::<MouseSettings>(&json).unwrap(),
            settings
        );
    }

    #[test]
    fn a_button_can_have_one_click_rule_and_one_hold_rule_but_not_two_of_a_kind() {
        let rule = |trigger: ButtonTrigger, action: &str| ButtonRule {
            button: 3,
            modifiers: 0,
            action_id: action.into(),
            trigger,
        };
        let s = MouseSettings {
            buttons: vec![
                rule(ButtonTrigger::Click, "click"),
                rule(ButtonTrigger::Hold, "hold"),
                rule(ButtonTrigger::Hold, "second hold"),
                rule(ButtonTrigger::Click, "second click"),
            ],
            ..MouseSettings::default()
        }
        .sanitized();
        let ids: Vec<&str> = s.buttons.iter().map(|b| b.action_id.as_str()).collect();
        assert_eq!(ids, ["click", "hold"]);
    }

    #[test]
    fn the_hold_time_is_kept_in_range() {
        let sanitized = |ms: u32| {
            MouseSettings {
                hold_ms: ms,
                ..MouseSettings::default()
            }
            .sanitized()
            .hold_ms
        };
        assert_eq!(sanitized(0), 150);
        assert_eq!(sanitized(350), 350);
        assert_eq!(sanitized(60_000), 1500);
    }

    #[test]
    fn left_and_right_buttons_cannot_be_remapped_and_repeats_are_dropped() {
        let s = MouseSettings {
            buttons: vec![
                ButtonRule {
                    button: 0,
                    modifiers: 0,
                    action_id: "a".into(),
                    trigger: ButtonTrigger::Click,
                },
                ButtonRule {
                    button: 1,
                    modifiers: 0,
                    action_id: "a".into(),
                    trigger: ButtonTrigger::Click,
                },
                ButtonRule {
                    button: 3,
                    modifiers: 0,
                    action_id: "a".into(),
                    trigger: ButtonTrigger::Click,
                },
                ButtonRule {
                    button: 3,
                    modifiers: 0,
                    action_id: "b".into(),
                    trigger: ButtonTrigger::Click,
                },
                ButtonRule {
                    button: 3,
                    modifiers: 8,
                    action_id: "b".into(),
                    trigger: ButtonTrigger::Click,
                },
            ],
            ..MouseSettings::default()
        }
        .sanitized();
        assert_eq!(s.buttons.len(), 2);
        assert_eq!(s.buttons[0].action_id, "a");
    }

    #[test]
    fn pointer_presets_map_to_tracking_values() {
        let mut p = PointerSettings::default();
        assert_eq!(p.tracking_value(), None);
        p.acceleration = PointerAccelerationPreset::Off;
        assert_eq!(p.tracking_value(), Some(POINTER_OFF));
        assert_eq!(p.precision_tracking_value(), Some(POINTER_OFF));
        p.acceleration = PointerAccelerationPreset::Custom;
        p.custom_speed = 2.0;
        p.precision_factor = 0.5;
        assert_eq!(p.tracking_value(), Some(2.0));
        assert_eq!(p.precision_tracking_value(), Some(1.0));
    }

    #[test]
    fn most_specific_assignment_wins() {
        let list = vec![
            assignment("1", Some("mouse"), None, "dev"),
            assignment("2", None, Some("app"), "app"),
            assignment("3", Some("mouse"), Some("app"), "both"),
        ];
        let pick = |d, a| resolve_preset_id(&list, "default", d, a);
        assert_eq!(pick(Some("mouse"), Some("app")), "both");
        assert_eq!(pick(Some("other"), Some("app")), "app");
        assert_eq!(pick(Some("mouse"), Some("x")), "dev");
        assert_eq!(pick(Some("other"), Some("x")), "default");
        assert_eq!(pick(None, None), "default");
    }

    #[test]
    fn an_assignment_for_nothing_in_particular_is_ignored() {
        let list = vec![assignment("1", None, None, "x")];
        assert_eq!(
            resolve_preset_id(&list, "default", Some("m"), Some("a")),
            "default"
        );
    }

    #[test]
    fn exclusions_match_exact_apps() {
        let config = MouseConfig {
            excluded_app_ids: vec!["com.game".into()],
            ..MouseConfig::default()
        };
        assert!(config.is_excluded(Some("com.game")));
        assert!(!config.is_excluded(Some("com.other")));
        assert!(!config.is_excluded(None));
    }

    #[test]
    fn builtin_templates_are_read_only_and_distinct() {
        let templates = builtin_templates();
        assert!(templates.iter().all(|t| t.is_read_only() && t.is_builtin));
        let ids: HashSet<_> = templates.iter().map(|t| t.id.clone()).collect();
        assert_eq!(ids.len(), templates.len());
        assert!(!MousePreset::factory_default().is_read_only());
    }

    #[test]
    fn preset_files_carry_their_actions_and_reject_other_files() {
        let action = NamedAction {
            id: "a".into(),
            name: "Open".into(),
            action: Action::Noop,
        };
        let other = NamedAction {
            id: "z".into(),
            name: "Unused".into(),
            action: Action::Noop,
        };
        let preset = MousePreset {
            id: "p".into(),
            name: "Mine".into(),
            is_builtin: false,
            settings: MouseSettings {
                buttons: vec![ButtonRule {
                    button: 3,
                    modifiers: 0,
                    action_id: "a".into(),
                    trigger: ButtonTrigger::Click,
                }],
                ..MouseSettings::default()
            },
        };
        let json = make_preset_file(&preset, &[action.clone(), other]).unwrap();
        let file = parse_preset_file(&json).unwrap();
        assert_eq!(file.actions, vec![action]);
        assert_eq!(file.name, "Mine");
        assert!(parse_preset_file("{}").is_err());
        assert!(parse_preset_file(&json.replace("mouse_preset", "something")).is_err());
    }

    #[test]
    fn remapping_changes_every_reference() {
        let mut s = MouseSettings {
            buttons: vec![ButtonRule {
                button: 3,
                modifiers: 0,
                action_id: "a".into(),
                trigger: ButtonTrigger::Click,
            }],
            gestures: GestureSettings {
                bindings: vec![GestureBinding {
                    direction: GestureDirection::Up,
                    action_id: "a".into(),
                }],
                rocker_left_then_right: Some("a".into()),
                ..GestureSettings::default()
            },
            ..MouseSettings::default()
        };
        let map = HashMap::from([("a".to_string(), "b".to_string())]);
        s.remap_action_ids(&map);
        assert_eq!(s.referenced_action_ids(), vec!["b".to_string()]);
    }

    #[test]
    fn scroll_modifiers_are_kept_to_real_keys_and_cannot_clash() {
        let s = MouseSettings {
            horizontal_scroll_modifier: crate::actions::modifiers::SHIFT | (1 << 40),
            raw_scroll_modifier: crate::actions::modifiers::OPTION,
            ..MouseSettings::default()
        }
        .sanitized();
        assert_eq!(
            s.horizontal_scroll_modifier,
            crate::actions::modifiers::SHIFT
        );
        assert_eq!(s.raw_scroll_modifier, crate::actions::modifiers::OPTION);
        let same = MouseSettings {
            horizontal_scroll_modifier: crate::actions::modifiers::SHIFT,
            raw_scroll_modifier: crate::actions::modifiers::SHIFT,
            ..MouseSettings::default()
        }
        .sanitized();
        assert_eq!(same.horizontal_scroll_modifier, 0);
        assert_eq!(same.raw_scroll_modifier, crate::actions::modifiers::SHIFT);
        assert_eq!(MouseSettings::default().horizontal_scroll_modifier, 0);
    }
}
