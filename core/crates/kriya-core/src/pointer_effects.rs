//! Pointer effects: a highlight around the pointer, click indicators, finding the pointer, a magnifier, hiding the pointer
//! when it is idle, and saved pointer positions. This holds the settings and the plain geometry; the app draws.

use std::collections::HashSet;

use rusqlite::{params, OptionalExtension};
use serde::{Deserialize, Serialize};

use crate::error::CoreError;
use crate::store::Store;
use crate::windows::{Point, Rect};

const SETTINGS_KEY: &str = "pointer_effects";
pub const MAX_POSITIONS: usize = 20;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum HaloStyle {
    /// A soft disc.
    Filled,
    /// A ring with an empty middle.
    Ring,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum MagnifierShape {
    Circle,
    Square,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum SpotlightShape {
    Circle,
    RoundedRectangle,
}

/// A place the pointer can jump to: a spot on a display, as fractions of its width and height.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct SavedPosition {
    pub id: String,
    pub name: String,
    /// The display's position in left-to-right order, from 0. `None` means the display the pointer is on.
    pub display: Option<u32>,
    pub x: f64,
    pub y: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
#[serde(default)]
pub struct PointerEffectsConfig {
    /// Master switch. Off, no effect is drawn and no command does anything.
    pub enabled: bool,

    pub halo_enabled: bool,
    pub halo_style: HaloStyle,
    pub halo_size: f64,
    /// `#RRGGBB`.
    pub halo_color: String,
    pub halo_opacity: f64,
    /// A slow breathing movement.
    pub halo_pulse: bool,

    pub click_enabled: bool,
    pub click_size: f64,
    pub click_duration_ms: u32,
    pub left_click_color: String,
    pub right_click_color: String,

    /// The size of the rings shown by "find the pointer".
    pub locate_size: f64,

    pub magnifier_zoom: f64,
    pub magnifier_size: f64,
    pub magnifier_shape: MagnifierShape,

    pub hide_when_idle: bool,
    pub hide_after_seconds: f64,

    /// Show the effects to people watching a shared screen or a recording. Off hides them from capture where macOS allows.
    pub show_when_sharing: bool,

    pub positions: Vec<SavedPosition>,

    /// Tapping Control twice finds the pointer. Needs the effects to be on.
    pub double_tap_control: bool,
    /// Shaking the mouse finds the pointer.
    pub shake_to_locate: bool,
    /// Hold exactly these keys and the magnifier shows; let go and it goes. 0 turns it off.
    pub magnifier_hold_modifier: u64,
    /// Hide the pointer while typing, until the mouse moves again.
    pub hide_while_typing: bool,
    /// Apps in which the halo and the click rings are not drawn.
    pub excluded_app_ids: Vec<String>,

    /// The width of the bright area of the spotlight, in points.
    pub spotlight_size: f64,
    /// How dark the rest of the screen goes, from barely to nearly black.
    pub spotlight_dim: f64,
    pub spotlight_shape: SpotlightShape,
}

impl Default for PointerEffectsConfig {
    fn default() -> Self {
        PointerEffectsConfig {
            enabled: false,
            halo_enabled: false,
            halo_style: HaloStyle::Filled,
            halo_size: 64.0,
            halo_color: "#D4A84B".to_string(),
            halo_opacity: 0.35,
            halo_pulse: false,
            click_enabled: false,
            click_size: 56.0,
            click_duration_ms: 450,
            left_click_color: "#6F94B8".to_string(),
            right_click_color: "#C77B6E".to_string(),
            locate_size: 240.0,
            magnifier_zoom: 2.5,
            magnifier_size: 220.0,
            magnifier_shape: MagnifierShape::Circle,
            hide_when_idle: false,
            hide_after_seconds: 5.0,
            show_when_sharing: false,
            positions: Vec::new(),
            double_tap_control: true,
            shake_to_locate: false,
            magnifier_hold_modifier: 0,
            hide_while_typing: false,
            excluded_app_ids: Vec::new(),
            spotlight_size: 300.0,
            spotlight_dim: 0.6,
            spotlight_shape: SpotlightShape::Circle,
        }
    }
}

/// `#RGB`, `#RRGGBB` or either without the `#`, as red, green and blue from 0 to 1.
pub fn parse_color(text: &str) -> Option<[f64; 3]> {
    let hex = text.trim().trim_start_matches('#');
    let expanded: String = match hex.len() {
        3 => hex.chars().flat_map(|c| [c, c]).collect(),
        6 => hex.to_string(),
        _ => return None,
    };
    if !expanded.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    let channel = |i: usize| {
        u8::from_str_radix(&expanded[i..i + 2], 16)
            .ok()
            .map(|v| f64::from(v) / 255.0)
    };
    Some([channel(0)?, channel(2)?, channel(4)?])
}

fn clean_color(text: &str, fallback: &str) -> String {
    match parse_color(text) {
        Some(_) => format!("#{}", text.trim().trim_start_matches('#').to_uppercase()),
        None => fallback.to_string(),
    }
}

impl PointerEffectsConfig {
    pub fn sanitized(mut self) -> Self {
        let defaults = PointerEffectsConfig::default();
        let fix = |v: f64, lo: f64, hi: f64, fallback: f64| {
            if v.is_finite() {
                v.clamp(lo, hi)
            } else {
                fallback
            }
        };
        self.halo_size = fix(self.halo_size, 20.0, 300.0, defaults.halo_size);
        self.halo_opacity = fix(self.halo_opacity, 0.05, 1.0, defaults.halo_opacity);
        self.click_size = fix(self.click_size, 20.0, 200.0, defaults.click_size);
        self.click_duration_ms = self.click_duration_ms.clamp(150, 2000);
        self.locate_size = fix(self.locate_size, 100.0, 600.0, defaults.locate_size);
        self.magnifier_zoom = fix(self.magnifier_zoom, 1.5, 8.0, defaults.magnifier_zoom);
        self.magnifier_size = fix(self.magnifier_size, 120.0, 500.0, defaults.magnifier_size);
        self.spotlight_size = fix(self.spotlight_size, 100.0, 900.0, defaults.spotlight_size);
        self.spotlight_dim = fix(self.spotlight_dim, 0.1, 0.95, defaults.spotlight_dim);
        self.hide_after_seconds = fix(
            self.hide_after_seconds,
            1.0,
            60.0,
            defaults.hide_after_seconds,
        );
        self.halo_color = clean_color(&self.halo_color, &defaults.halo_color);
        self.left_click_color = clean_color(&self.left_click_color, &defaults.left_click_color);
        self.right_click_color = clean_color(&self.right_click_color, &defaults.right_click_color);
        let mut seen = HashSet::new();
        let mut kept = Vec::new();
        for mut position in self.positions {
            position.id = position.id.trim().to_string();
            position.name = position.name.trim().to_string();
            position.x = fix(position.x, 0.0, 1.0, 0.5);
            position.y = fix(position.y, 0.0, 1.0, 0.5);
            position.display = position.display.map(|d| d.min(15));
            let valid = !position.id.is_empty()
                && !position.name.is_empty()
                && position.name.chars().count() <= 40;
            if valid && seen.insert(position.id.clone()) {
                kept.push(position);
            }
        }
        kept.truncate(MAX_POSITIONS);
        self.magnifier_hold_modifier &= crate::actions::modifiers::ALL;
        self.positions = kept;
        let mut seen_apps = std::collections::HashSet::new();
        self.excluded_app_ids = self
            .excluded_app_ids
            .iter()
            .map(|a| a.trim().to_string())
            .filter(|a| !a.is_empty() && seen_apps.insert(a.clone()))
            .take(50)
            .collect();
        self
    }
}

pub fn position_command(id: &str) -> String {
    format!("pointer.go.{}", id.to_lowercase())
}

/// Where a saved position lands on a display's frame.
pub fn position_point(area: Rect, x: f64, y: f64) -> Point {
    let x = if x.is_finite() {
        x.clamp(0.0, 1.0)
    } else {
        0.5
    };
    let y = if y.is_finite() {
        y.clamp(0.0, 1.0)
    } else {
        0.5
    };
    Point {
        x: (area.x + x * (area.width - 1.0).max(0.0)).round(),
        y: (area.y + y * (area.height - 1.0).max(0.0)).round(),
    }
}

/// The part of the screen the magnifier shows: a square of `size / zoom` points around the pointer, slid back inside
/// `bounds` when the pointer is near an edge so the picture never goes blank.
pub fn magnifier_source(pointer: Point, size: f64, zoom: f64, bounds: Rect) -> Rect {
    let zoom = if zoom.is_finite() {
        zoom.clamp(1.0, 16.0)
    } else {
        2.0
    };
    let size = if size.is_finite() {
        size.clamp(40.0, 1000.0)
    } else {
        200.0
    };
    let side = (size / zoom).min(bounds.width).min(bounds.height);
    let x = (pointer.x - side / 2.0).clamp(bounds.x, (bounds.max_x() - side).max(bounds.x));
    let y = (pointer.y - side / 2.0).clamp(bounds.y, (bounds.max_y() - side).max(bounds.y));
    Rect::new(x, y, side, side)
}

impl Store {
    pub fn pointer_effects_config(&self) -> Result<PointerEffectsConfig, CoreError> {
        let conn = self.conn();
        let json: Option<String> = conn
            .query_row(
                "SELECT value FROM settings WHERE key = ?1",
                params![SETTINGS_KEY],
                |r| r.get(0),
            )
            .optional()?;
        Ok(json
            .and_then(|j| serde_json::from_str::<PointerEffectsConfig>(&j).ok())
            .unwrap_or_default()
            .sanitized())
    }

    pub fn save_pointer_effects_config(
        &self,
        config: &PointerEffectsConfig,
    ) -> Result<(), CoreError> {
        let clean = config.clone().sanitized();
        self.conn().execute(
            "INSERT INTO settings (key, value) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![SETTINGS_KEY, serde_json::to_string(&clean)?],
        )?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn position(id: &str, name: &str) -> SavedPosition {
        SavedPosition {
            id: id.into(),
            name: name.into(),
            display: None,
            x: 0.5,
            y: 0.5,
        }
    }

    #[test]
    fn the_spotlight_is_kept_within_sensible_bounds() {
        let defaults = PointerEffectsConfig::default();
        assert_eq!(defaults.spotlight_shape, SpotlightShape::Circle);
        let wild = PointerEffectsConfig {
            spotlight_size: 1.0,
            spotlight_dim: 5.0,
            ..PointerEffectsConfig::default()
        }
        .sanitized();
        assert_eq!(wild.spotlight_size, 100.0);
        assert_eq!(wild.spotlight_dim, 0.95);
        let nan = PointerEffectsConfig {
            spotlight_size: f64::NAN,
            spotlight_dim: f64::INFINITY,
            ..PointerEffectsConfig::default()
        }
        .sanitized();
        assert_eq!(nan.spotlight_size, defaults.spotlight_size);
        assert_eq!(nan.spotlight_dim, defaults.spotlight_dim);
        let faint = PointerEffectsConfig {
            spotlight_dim: 0.0,
            ..PointerEffectsConfig::default()
        }
        .sanitized();
        assert_eq!(
            faint.spotlight_dim, 0.1,
            "never so faint that it does nothing"
        );
    }

    #[test]
    fn settings_saved_before_the_spotlight_existed_still_load() {
        let old = r##"{"enabled":true,"halo_enabled":true,"halo_size":80.0}"##;
        let cfg: PointerEffectsConfig = serde_json::from_str(old).unwrap();
        assert!(cfg.enabled && cfg.halo_enabled);
        assert_eq!(cfg.spotlight_size, 300.0);
        assert_eq!(cfg.spotlight_shape, SpotlightShape::Circle);
    }

    #[test]
    fn colors_parse_in_the_common_forms() {
        assert_eq!(parse_color("#FF0000"), Some([1.0, 0.0, 0.0]));
        assert_eq!(parse_color("00ff00"), Some([0.0, 1.0, 0.0]));
        assert_eq!(parse_color(" #0F0 "), Some([0.0, 1.0, 0.0]));
        let grey = parse_color("#808080").unwrap();
        assert!((grey[0] - 128.0 / 255.0).abs() < 1e-9);
        assert_eq!(parse_color("#12345"), None);
        assert_eq!(parse_color("#GGGGGG"), None);
        assert_eq!(parse_color(""), None);
    }

    #[test]
    fn settings_are_clamped_and_bad_colors_fall_back() {
        let cfg = PointerEffectsConfig {
            halo_size: 9999.0,
            halo_opacity: f64::NAN,
            click_duration_ms: 1,
            magnifier_zoom: 0.1,
            magnifier_size: 5.0,
            hide_after_seconds: 0.0,
            halo_color: "red".into(),
            left_click_color: "6f94b8".into(),
            ..PointerEffectsConfig::default()
        }
        .sanitized();
        assert_eq!(cfg.halo_size, 300.0);
        assert_eq!(cfg.halo_opacity, 0.35);
        assert_eq!(cfg.click_duration_ms, 150);
        assert_eq!(cfg.magnifier_zoom, 1.5);
        assert_eq!(cfg.magnifier_size, 120.0);
        assert_eq!(cfg.hide_after_seconds, 1.0);
        assert_eq!(
            cfg.halo_color, "#D4A84B",
            "a colour that does not parse is replaced"
        );
        assert_eq!(
            cfg.left_click_color, "#6F94B8",
            "a good colour is kept, tidied"
        );
        assert!(
            !PointerEffectsConfig::default().enabled
                && !PointerEffectsConfig::default().show_when_sharing
        );
    }

    #[test]
    fn saved_positions_are_tidied_and_capped() {
        let mut spaced = position(" a ", " Left screen ");
        spaced.x = 2.0;
        spaced.y = f64::NAN;
        spaced.display = Some(99);
        let cfg = PointerEffectsConfig {
            positions: vec![
                spaced,
                position("a", "Repeated id"),
                position("b", "  "),
                position("", "No id"),
            ],
            ..PointerEffectsConfig::default()
        }
        .sanitized();
        assert_eq!(cfg.positions.len(), 1);
        let kept = &cfg.positions[0];
        assert_eq!(
            (
                kept.id.as_str(),
                kept.name.as_str(),
                kept.x,
                kept.y,
                kept.display
            ),
            ("a", "Left screen", 1.0, 0.5, Some(15))
        );
        let many = (0..30).map(|i| position(&format!("p{i}"), "P")).collect();
        assert_eq!(
            PointerEffectsConfig {
                positions: many,
                ..PointerEffectsConfig::default()
            }
            .sanitized()
            .positions
            .len(),
            MAX_POSITIONS
        );
        assert_eq!(position_command("AbC"), "pointer.go.abc");
    }

    #[test]
    fn a_saved_position_lands_inside_the_display() {
        let area = Rect::new(1440.0, 0.0, 1920.0, 1080.0);
        assert_eq!(position_point(area, 0.0, 0.0), Point { x: 1440.0, y: 0.0 });
        assert_eq!(
            position_point(area, 1.0, 1.0),
            Point {
                x: 3359.0,
                y: 1079.0
            }
        );
        assert_eq!(
            position_point(area, 0.5, 0.5),
            Point {
                x: 2400.0,
                y: 540.0
            }
        );
        assert_eq!(
            position_point(area, 5.0, f64::NAN),
            Point {
                x: 3359.0,
                y: 540.0
            }
        );
    }

    #[test]
    fn the_magnifier_shows_a_zoomed_square_that_stays_on_screen() {
        let bounds = Rect::new(0.0, 0.0, 1000.0, 800.0);
        let middle = magnifier_source(Point { x: 500.0, y: 400.0 }, 200.0, 2.0, bounds);
        assert_eq!(middle, Rect::new(450.0, 350.0, 100.0, 100.0));
        let corner = magnifier_source(Point { x: 5.0, y: 5.0 }, 200.0, 2.0, bounds);
        assert_eq!(
            (corner.x, corner.y),
            (0.0, 0.0),
            "slid back inside the screen"
        );
        let far = magnifier_source(Point { x: 999.0, y: 799.0 }, 200.0, 2.0, bounds);
        assert_eq!((far.max_x(), far.max_y()), (1000.0, 800.0));
        let tiny = magnifier_source(
            Point { x: 10.0, y: 10.0 },
            600.0,
            1.0,
            Rect::new(0.0, 0.0, 300.0, 200.0),
        );
        assert_eq!(tiny.width, 200.0, "never larger than the screen");
        assert!(magnifier_source(Point { x: 1.0, y: 1.0 }, f64::NAN, f64::NAN, bounds).width > 0.0);
    }

    #[test]
    fn the_configuration_is_stored() {
        let store = Store::open_in_memory().unwrap();
        assert!(!store.pointer_effects_config().unwrap().enabled);
        store
            .save_pointer_effects_config(&PointerEffectsConfig {
                enabled: true,
                halo_enabled: true,
                ..PointerEffectsConfig::default()
            })
            .unwrap();
        let back = store.pointer_effects_config().unwrap();
        assert!(back.enabled && back.halo_enabled);
    }
}
