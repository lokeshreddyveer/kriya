//! Plain data shared by every platform shell: features, settings, devices and profiles.
//! Times are unix seconds. Nothing here knows about an operating system.

use serde::{Deserialize, Serialize};

/// A switchable part of the app. The shells attach titles, icons and the permissions each one needs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum FeatureId {
    Mouse,
    WindowManagement,
    TrafficLights,
    ContextMenu,
    SelectionBar,
    Clipboard,
    Keyboard,
    Automation,
}

impl FeatureId {
    pub const ALL: [FeatureId; 8] = [
        FeatureId::Mouse,
        FeatureId::WindowManagement,
        FeatureId::TrafficLights,
        FeatureId::ContextMenu,
        FeatureId::SelectionBar,
        FeatureId::Clipboard,
        FeatureId::Keyboard,
        FeatureId::Automation,
    ];
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum AppearanceMode {
    #[default]
    System,
    Light,
    Dark,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum LogLevel {
    Debug,
    #[default]
    Info,
    Warning,
    Error,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
#[serde(default)]
pub struct AppSettings {
    pub appearance: AppearanceMode,
    /// Dock icon on macOS, taskbar button on Windows.
    pub show_app_icon: bool,
    pub automatically_check_for_updates: bool,
    pub log_level: LogLevel,
    pub enabled_features: Vec<FeatureId>,
    pub has_completed_onboarding: bool,
    /// Turn a feature off by itself if the app quit unexpectedly while starting it.
    pub auto_disable_crashing_feature: bool,
}

impl Default for AppSettings {
    fn default() -> Self {
        AppSettings {
            appearance: AppearanceMode::System,
            show_app_icon: false,
            automatically_check_for_updates: true,
            log_level: LogLevel::Info,
            enabled_features: Vec::new(),
            has_completed_onboarding: false,
            auto_disable_crashing_feature: true,
        }
    }
}

impl AppSettings {
    /// Drops duplicates so a hand-edited or restored file cannot hold a feature twice.
    pub fn sanitized(mut self) -> Self {
        let mut seen = Vec::new();
        self.enabled_features.retain(|f| {
            if seen.contains(f) {
                false
            } else {
                seen.push(*f);
                true
            }
        });
        self
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum DeviceKind {
    Mouse,
    Trackpad,
}

impl DeviceKind {
    pub fn as_str(self) -> &'static str {
        match self {
            DeviceKind::Mouse => "mouse",
            DeviceKind::Trackpad => "trackpad",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "mouse" => Some(DeviceKind::Mouse),
            "trackpad" => Some(DeviceKind::Trackpad),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum ConnectionKind {
    Wired,
    Wireless,
    BuiltIn,
}

impl ConnectionKind {
    pub fn as_str(self) -> &'static str {
        match self {
            ConnectionKind::Wired => "wired",
            ConnectionKind::Wireless => "wireless",
            ConnectionKind::BuiltIn => "built_in",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "wired" => Some(ConnectionKind::Wired),
            "wireless" => Some(ConnectionKind::Wireless),
            "built_in" => Some(ConnectionKind::BuiltIn),
            _ => None,
        }
    }
}

/// One pointing device the platform adapter has seen. The registry is shared, so profiles and rules on every
/// platform refer to a device by the same `id`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct DeviceRecord {
    pub id: String,
    pub name: String,
    pub vendor_id: u32,
    pub product_id: u32,
    pub serial: Option<String>,
    pub transport: String,
    pub kind: DeviceKind,
    pub detected_connection: ConnectionKind,
    /// Set by the person when the guess is wrong, for example a wireless mouse behind a USB receiver.
    pub connection_override: Option<ConnectionKind>,
    pub nickname: Option<String>,
    pub first_seen: i64,
    pub last_seen: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct FeatureOverride {
    pub feature: FeatureId,
    pub enabled: bool,
}

/// Settings for the default case, or for one app. Features without an override inherit from the default profile.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct Profile {
    pub id: String,
    pub name: String,
    /// Bundle identifier on macOS, executable name on Windows. `None` for the default profile.
    pub app_id: Option<String>,
    pub is_default: bool,
    pub is_enabled: bool,
    pub feature_overrides: Vec<FeatureOverride>,
    pub sort_order: i64,
}

pub const DEFAULT_PROFILE_ID: &str = "default";

impl Profile {
    pub fn default_profile() -> Self {
        Profile {
            id: DEFAULT_PROFILE_ID.to_string(),
            name: "Default".to_string(),
            app_id: None,
            is_default: true,
            is_enabled: true,
            feature_overrides: Vec::new(),
            sort_order: 0,
        }
    }

    pub fn override_for(&self, feature: FeatureId) -> Option<bool> {
        self.feature_overrides
            .iter()
            .find(|o| o.feature == feature)
            .map(|o| o.enabled)
    }
}
