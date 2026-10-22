//! Screen-level tools: hot corners that run a saved action, saved display profiles (resolution, refresh rate, position),
//! software dimming and the file shelf's settings. The shell reads the displays and applies the changes; this module keeps
//! the rules and the settings.

use std::collections::HashSet;

use rusqlite::{params, OptionalExtension};
use serde::{Deserialize, Serialize};

use crate::error::CoreError;
use crate::store::Store;

const SETTINGS_KEY: &str = "screen_tools";
const MAX_CORNERS: usize = 8;
const MAX_PROFILES: usize = 20;
const MAX_DISPLAYS: usize = 8;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum ScreenCorner {
    TopLeft,
    TopRight,
    BottomLeft,
    BottomRight,
}

/// A screen corner that runs a saved action when the pointer rests in it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct HotCorner {
    pub corner: ScreenCorner,
    /// A saved action's id, or a built-in command.
    pub action_id: String,
    /// Keys that must be held as well, so it is not set off by accident. 0 means none.
    pub modifiers: u64,
}

/// One display as it was saved: which display, its mode and where it sat.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct DisplayState {
    /// The display's stable identifier (its UUID).
    pub key: String,
    pub width: u32,
    pub height: u32,
    pub refresh_hz: f64,
    pub hidpi: bool,
    pub x: i32,
    pub y: i32,
    pub is_main: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct DisplayProfile {
    pub id: String,
    pub name: String,
    pub displays: Vec<DisplayState>,
}

/// How dark one display is made in software, from 0 (normal) to 0.9.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct DimLevel {
    pub key: String,
    pub level: f64,
    /// How much of the blue is taken out, from 0 (none) to 0.8, for a warmer screen at night.
    #[serde(default)]
    pub warmth: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum ShelfEdge {
    Left,
    Right,
    Bottom,
    Pointer,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
#[serde(default)]
pub struct ScreenToolsConfig {
    pub hot_corners_enabled: bool,
    pub corners: Vec<HotCorner>,
    /// How long the pointer must rest in a corner, in milliseconds.
    pub corner_dwell_ms: u32,
    /// How far into the corner counts, in points.
    pub corner_size: f64,
    pub display_profiles: Vec<DisplayProfile>,
    /// Put the saved profile that matches back when displays are plugged in or removed.
    pub restore_profile_on_change: bool,
    pub dim_levels: Vec<DimLevel>,

    /// The file shelf.
    pub shelf_enabled: bool,
    /// Open the shelf when the pointer is shaken while dragging files.
    pub shelf_on_shake: bool,
    /// Show the shelf as soon as files start to be dragged.
    pub shelf_on_drag: bool,
    pub shelf_edge: ShelfEdge,
    pub shelf_auto_hide_seconds: f64,
    pub shelf_excluded_app_ids: Vec<String>,
}

impl Default for ScreenToolsConfig {
    fn default() -> Self {
        ScreenToolsConfig {
            hot_corners_enabled: false,
            corners: Vec::new(),
            corner_dwell_ms: 350,
            corner_size: 6.0,
            display_profiles: Vec::new(),
            restore_profile_on_change: false,
            dim_levels: Vec::new(),
            shelf_enabled: false,
            shelf_on_shake: true,
            shelf_on_drag: false,
            shelf_edge: ShelfEdge::Pointer,
            shelf_auto_hide_seconds: 0.0,
            shelf_excluded_app_ids: Vec::new(),
        }
    }
}

impl ScreenToolsConfig {
    pub fn sanitized(mut self) -> Self {
        self.corner_dwell_ms = self.corner_dwell_ms.clamp(100, 2000);
        self.corner_size = if self.corner_size.is_finite() {
            self.corner_size.clamp(2.0, 40.0)
        } else {
            6.0
        };
        let mut seen = HashSet::new();
        self.corners = self
            .corners
            .into_iter()
            .map(|mut c| {
                c.action_id = c.action_id.trim().to_string();
                c.modifiers &= crate::actions::modifiers::ALL;
                c
            })
            .filter(|c| !c.action_id.is_empty() && seen.insert(c.corner))
            .take(MAX_CORNERS)
            .collect();

        let mut ids = HashSet::new();
        let mut profiles = Vec::new();
        for mut profile in self.display_profiles {
            profile.id = profile.id.trim().to_string();
            profile.name = profile.name.trim().to_string();
            profile.displays.retain(|d| {
                !d.key.trim().is_empty()
                    && d.width >= 320
                    && d.height >= 240
                    && d.refresh_hz.is_finite()
            });
            profile.displays.truncate(MAX_DISPLAYS);
            let valid = !profile.id.is_empty()
                && !profile.name.is_empty()
                && profile.name.chars().count() <= 60
                && !profile.displays.is_empty();
            if valid && ids.insert(profile.id.clone()) {
                profiles.push(profile);
            }
        }
        profiles.truncate(MAX_PROFILES);
        self.display_profiles = profiles;

        let mut dim_seen = HashSet::new();
        self.dim_levels = self
            .dim_levels
            .into_iter()
            .map(|mut d| {
                d.level = if d.level.is_finite() {
                    d.level.clamp(0.0, 0.9)
                } else {
                    0.0
                };
                d.warmth = if d.warmth.is_finite() {
                    d.warmth.clamp(0.0, 0.8)
                } else {
                    0.0
                };
                d
            })
            .filter(|d| {
                !d.key.trim().is_empty()
                    && (d.level > 0.0 || d.warmth > 0.0)
                    && dim_seen.insert(d.key.clone())
            })
            .take(MAX_DISPLAYS)
            .collect();

        self.shelf_auto_hide_seconds = if self.shelf_auto_hide_seconds.is_finite() {
            self.shelf_auto_hide_seconds.clamp(0.0, 120.0)
        } else {
            0.0
        };
        let mut apps = HashSet::new();
        self.shelf_excluded_app_ids = self
            .shelf_excluded_app_ids
            .iter()
            .map(|a| a.trim().to_string())
            .filter(|a| !a.is_empty() && apps.insert(a.clone()))
            .take(50)
            .collect();
        self
    }
}

/// The saved profile whose set of displays is exactly the displays connected now, if there is one.
pub fn matching_profile<'a>(
    profiles: &'a [DisplayProfile],
    connected: &[String],
) -> Option<&'a DisplayProfile> {
    let wanted: HashSet<&str> = connected.iter().map(String::as_str).collect();
    profiles.iter().find(|p| {
        p.displays.len() == wanted.len()
            && p.displays.iter().all(|d| wanted.contains(d.key.as_str()))
    })
}

/// The corner the pointer is in, for a display of this size. `y` grows downward.
pub fn corner_at(x: f64, y: f64, width: f64, height: f64, size: f64) -> Option<ScreenCorner> {
    if !(x.is_finite() && y.is_finite()) {
        return None;
    }
    let left = x <= size;
    let right = x >= width - size;
    let top = y <= size;
    let bottom = y >= height - size;
    match (left, right, top, bottom) {
        (true, _, true, _) => Some(ScreenCorner::TopLeft),
        (_, true, true, _) => Some(ScreenCorner::TopRight),
        (true, _, _, true) => Some(ScreenCorner::BottomLeft),
        (_, true, _, true) => Some(ScreenCorner::BottomRight),
        _ => None,
    }
}

impl Store {
    pub fn screen_tools_config(&self) -> Result<ScreenToolsConfig, CoreError> {
        let conn = self.conn();
        let json: Option<String> = conn
            .query_row(
                "SELECT value FROM settings WHERE key = ?1",
                params![SETTINGS_KEY],
                |r| r.get(0),
            )
            .optional()?;
        Ok(json
            .and_then(|j| serde_json::from_str::<ScreenToolsConfig>(&j).ok())
            .unwrap_or_default()
            .sanitized())
    }

    pub fn save_screen_tools_config(&self, config: &ScreenToolsConfig) -> Result<(), CoreError> {
        let clean = config.clone().sanitized();
        self.conn().execute(
            "INSERT INTO settings (key, value) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![SETTINGS_KEY, serde_json::to_string(&clean)?],
        )?;
        Ok(())
    }
}

/// Which corner the pointer is in, for the shell's hot-corner watcher.
#[uniffi::export]
pub fn screen_corner_at(
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    size: f64,
) -> Option<ScreenCorner> {
    corner_at(x, y, width, height, size)
}

/// The id of the saved profile that matches the displays connected now.
#[uniffi::export]
pub fn display_profile_for(
    profiles: Vec<DisplayProfile>,
    connected: Vec<String>,
) -> Option<String> {
    matching_profile(&profiles, &connected).map(|p| p.id.clone())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn display(key: &str) -> DisplayState {
        DisplayState {
            key: key.into(),
            width: 2560,
            height: 1440,
            refresh_hz: 60.0,
            hidpi: true,
            x: 0,
            y: 0,
            is_main: false,
        }
    }

    fn profile(id: &str, keys: &[&str]) -> DisplayProfile {
        DisplayProfile {
            id: id.into(),
            name: format!("P {id}"),
            displays: keys.iter().map(|k| display(k)).collect(),
        }
    }

    #[test]
    fn corners_are_found_and_only_inside_the_edge() {
        assert_eq!(
            corner_at(2.0, 3.0, 1440.0, 900.0, 6.0),
            Some(ScreenCorner::TopLeft)
        );
        assert_eq!(
            corner_at(1439.0, 1.0, 1440.0, 900.0, 6.0),
            Some(ScreenCorner::TopRight)
        );
        assert_eq!(
            corner_at(0.0, 899.0, 1440.0, 900.0, 6.0),
            Some(ScreenCorner::BottomLeft)
        );
        assert_eq!(
            corner_at(1438.0, 898.0, 1440.0, 900.0, 6.0),
            Some(ScreenCorner::BottomRight)
        );
        assert_eq!(
            corner_at(720.0, 2.0, 1440.0, 900.0, 6.0),
            None,
            "the middle of an edge is not a corner"
        );
        assert_eq!(corner_at(f64::NAN, 0.0, 1440.0, 900.0, 6.0), None);
    }

    #[test]
    fn settings_are_tidied() {
        let config = ScreenToolsConfig {
            corner_dwell_ms: 1,
            corner_size: 999.0,
            corners: vec![
                HotCorner {
                    corner: ScreenCorner::TopLeft,
                    action_id: " a ".into(),
                    modifiers: 1 << 40,
                },
                HotCorner {
                    corner: ScreenCorner::TopLeft,
                    action_id: "dup".into(),
                    modifiers: 0,
                },
                HotCorner {
                    corner: ScreenCorner::TopRight,
                    action_id: " ".into(),
                    modifiers: 0,
                },
            ],
            display_profiles: vec![
                profile("a", &["x", "y"]),
                profile("a", &["z"]),
                profile("", &["q"]),
                profile("empty", &[]),
            ],
            dim_levels: vec![
                DimLevel {
                    key: "x".into(),
                    level: 5.0,
                    warmth: 0.0,
                },
                DimLevel {
                    key: "x".into(),
                    level: 0.3,
                    warmth: 0.0,
                },
                DimLevel {
                    key: "y".into(),
                    level: 0.0,
                    warmth: 0.0,
                },
                DimLevel {
                    key: "w".into(),
                    level: 0.0,
                    warmth: 9.0,
                },
                DimLevel {
                    key: " ".into(),
                    level: 0.5,
                    warmth: 0.0,
                },
            ],
            shelf_auto_hide_seconds: f64::NAN,
            shelf_excluded_app_ids: vec![" com.x ".into(), "com.x".into(), "".into()],
            ..ScreenToolsConfig::default()
        }
        .sanitized();
        assert_eq!((config.corner_dwell_ms, config.corner_size), (100, 40.0));
        assert_eq!(config.corners.len(), 1);
        assert_eq!(
            (
                config.corners[0].action_id.as_str(),
                config.corners[0].modifiers
            ),
            ("a", 0)
        );
        assert_eq!(config.display_profiles.len(), 1);
        assert_eq!(
            config.dim_levels.len(),
            2,
            "a display with only warmth is kept"
        );
        assert_eq!(config.dim_levels[0].level, 0.9, "never fully black");
        assert_eq!(config.dim_levels[1].warmth, 0.8, "never fully red");
        assert_eq!(config.shelf_auto_hide_seconds, 0.0);
        assert_eq!(config.shelf_excluded_app_ids, vec!["com.x".to_string()]);
    }

    #[test]
    fn a_profile_matches_only_the_exact_set_of_displays() {
        let list = vec![profile("desk", &["a", "b"]), profile("laptop", &["a"])];
        assert_eq!(
            matching_profile(&list, &["b".into(), "a".into()]).map(|p| p.id.as_str()),
            Some("desk")
        );
        assert_eq!(
            matching_profile(&list, &["a".into()]).map(|p| p.id.as_str()),
            Some("laptop")
        );
        assert!(matching_profile(&list, &["a".into(), "c".into()]).is_none());
        assert!(matching_profile(&list, &[]).is_none());
    }

    #[test]
    fn the_configuration_is_stored() {
        let store = Store::open_in_memory().unwrap();
        assert!(!store.screen_tools_config().unwrap().hot_corners_enabled);
        store
            .save_screen_tools_config(&ScreenToolsConfig {
                hot_corners_enabled: true,
                shelf_enabled: true,
                ..ScreenToolsConfig::default()
            })
            .unwrap();
        let back = store.screen_tools_config().unwrap();
        assert!(back.hot_corners_enabled && back.shelf_enabled);
    }
}
