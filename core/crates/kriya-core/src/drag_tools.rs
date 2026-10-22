//! Dragging tools: hold a mouse button and drag to scroll like grabbing the page, glide on after letting go, and hold
//! keys so the window under the pointer follows it without any click.

use rusqlite::{params, OptionalExtension};
use serde::{Deserialize, Serialize};

use crate::actions::modifiers as m;
use crate::error::CoreError;
use crate::store::Store;

const SETTINGS_KEY: &str = "drag_tools";

/// A double click of a mouse button that runs a saved action. The first click still goes through as normal.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct DoubleClickBinding {
    pub button: u32,
    pub modifiers: u64,
    pub action_id: String,
}

/// Hold a mouse button and turn the wheel: one saved action for each direction.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct ButtonScrollBinding {
    pub button: u32,
    pub up_action_id: Option<String>,
    pub down_action_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
#[serde(default)]
pub struct DragToolsConfig {
    /// Hold the button and drag to scroll the page under the pointer.
    pub scroll_enabled: bool,
    /// Which button, as the system numbers them: 0 left, 1 right, 2 middle, 3 and up the side buttons.
    pub scroll_button: u32,
    /// Keys that must be held as well. Needed for the left and right buttons, which have other jobs.
    pub scroll_modifier: u64,
    /// Off: the page follows the hand. On: the other way round.
    pub scroll_invert: bool,
    /// How far the page moves for each point the pointer moves.
    pub scroll_speed: f64,
    /// The page keeps gliding for a moment after the button is let go.
    pub momentum: bool,
    /// How much of its speed the glide keeps every sixtieth of a second. Nearer one glides longer.
    pub momentum_keep: f64,
    /// Hold these keys and the window under the pointer follows it, with no click. 0 turns it off.
    pub follow_modifier: u64,
    pub double_clicks: Vec<DoubleClickBinding>,
    /// How soon the second click must follow the first, in milliseconds.
    pub double_click_ms: u32,
    pub button_scrolls: Vec<ButtonScrollBinding>,
    /// Click a button and the page scrolls by itself, faster the further the pointer is moved from where it was clicked.
    /// A click, the Escape key or turning the wheel stops it.
    pub auto_scroll_enabled: bool,
    pub auto_scroll_button: u32,
    pub auto_scroll_modifier: u64,
    /// How fast it scrolls for a given distance. 1 is the usual speed.
    pub auto_scroll_speed: f64,
}

impl Default for DragToolsConfig {
    fn default() -> Self {
        DragToolsConfig {
            scroll_enabled: false,
            scroll_button: 2,
            scroll_modifier: 0,
            scroll_invert: false,
            scroll_speed: 1.0,
            momentum: true,
            momentum_keep: 0.94,
            follow_modifier: 0,
            double_clicks: Vec::new(),
            double_click_ms: 300,
            button_scrolls: Vec::new(),
            auto_scroll_enabled: false,
            auto_scroll_button: 2,
            auto_scroll_modifier: 0,
            auto_scroll_speed: 1.0,
        }
    }
}

impl DragToolsConfig {
    pub fn sanitized(mut self) -> Self {
        self.scroll_button = self.scroll_button.clamp(0, 31);
        self.scroll_modifier &= m::ALL;
        self.scroll_speed = if self.scroll_speed.is_finite() {
            self.scroll_speed.clamp(0.2, 5.0)
        } else {
            1.0
        };
        self.momentum_keep = if self.momentum_keep.is_finite() {
            self.momentum_keep.clamp(0.80, 0.99)
        } else {
            0.94
        };
        self.follow_modifier &= m::ALL;
        self.auto_scroll_button = self.auto_scroll_button.clamp(0, 31);
        self.auto_scroll_modifier &= m::ALL;
        self.auto_scroll_speed = if self.auto_scroll_speed.is_finite() {
            self.auto_scroll_speed.clamp(0.2, 5.0)
        } else {
            1.0
        };
        // A plain click of the main buttons would break ordinary use, so those need keys held.
        if self.auto_scroll_button < 2 && self.auto_scroll_modifier == 0 {
            self.auto_scroll_enabled = false;
        }
        self.double_click_ms = self.double_click_ms.clamp(150, 600);
        let mut seen = std::collections::HashSet::new();
        self.double_clicks = self
            .double_clicks
            .into_iter()
            .map(|mut b| {
                b.button = b.button.clamp(0, 31);
                b.modifiers &= m::ALL;
                b.action_id = b.action_id.trim().to_string();
                b
            })
            // A plain double click of the main buttons would break ordinary use.
            .filter(|b| {
                !b.action_id.is_empty()
                    && (b.button >= 2 || b.modifiers != 0)
                    && seen.insert((b.button, b.modifiers))
            })
            .take(20)
            .collect();
        let mut seen_buttons = std::collections::HashSet::new();
        self.button_scrolls = self
            .button_scrolls
            .into_iter()
            .map(|mut b| {
                b.button = b.button.clamp(2, 31);
                b.up_action_id = b
                    .up_action_id
                    .map(|a| a.trim().to_string())
                    .filter(|a| !a.is_empty());
                b.down_action_id = b
                    .down_action_id
                    .map(|a| a.trim().to_string())
                    .filter(|a| !a.is_empty());
                b
            })
            .filter(|b| {
                (b.up_action_id.is_some() || b.down_action_id.is_some())
                    && seen_buttons.insert(b.button)
            })
            .take(10)
            .collect();
        // The left and right buttons are for clicking: without keys held as well, taking them would break the mouse.
        if self.scroll_button <= 1 && self.scroll_modifier == 0 {
            self.scroll_enabled = false;
        }
        self
    }
}

#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct DragMove {
    pub dx: f64,
    pub dy: f64,
    pub at_ms: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct Velocity {
    pub x: f64,
    pub y: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct GlideStep {
    /// How far to scroll now.
    pub dx: f64,
    pub dy: f64,
    /// The speed left; both zero when the glide is over.
    pub rest: Velocity,
}

/// The speed to glide on at when the button is let go, in points per millisecond, from the last few pointer moves.
/// Only moves in the final 100 ms count, so pausing before letting go stops the page.
#[uniffi::export]
pub fn drag_release_velocity(moves: Vec<DragMove>, released_at_ms: u64) -> Velocity {
    let recent: Vec<&DragMove> = moves
        .iter()
        .filter(|mv| released_at_ms.saturating_sub(mv.at_ms) <= 100)
        .collect();
    let (Some(first), Some(last)) = (recent.first(), recent.last()) else {
        return Velocity { x: 0.0, y: 0.0 };
    };
    let span = last.at_ms.saturating_sub(first.at_ms).max(16) as f64;
    let (dx, dy) = recent
        .iter()
        .fold((0.0, 0.0), |(x, y), mv| (x + mv.dx, y + mv.dy));
    Velocity {
        x: dx / span,
        y: dy / span,
    }
}

/// How far the pointer must be from where auto-scroll started, in points, before the page moves.
pub const AUTO_SCROLL_DEAD_ZONE: f64 = 12.0;
/// The fastest auto-scroll goes, in points per second, at the usual speed setting.
pub const AUTO_SCROLL_MAX_SPEED: f64 = 2400.0;

/// How fast the page scrolls, in points per second along each axis, for a pointer this far from where auto-scroll was
/// started. Nothing inside a small dead zone, then faster the further out, up to a limit. Positive means the pointer is
/// to the right of, or below, the start.
#[uniffi::export]
pub fn auto_scroll_velocity(offset_x: f64, offset_y: f64, speed: f64) -> Velocity {
    let speed = if speed.is_finite() {
        speed.clamp(0.2, 5.0)
    } else {
        1.0
    };
    let axis = |offset: f64| {
        if !offset.is_finite() || offset.abs() <= AUTO_SCROLL_DEAD_ZONE {
            return 0.0;
        }
        let beyond = offset.abs() - AUTO_SCROLL_DEAD_ZONE;
        // Gentle near the centre so a slow scroll is easy to hold, steeper further out.
        let rate = (beyond * 6.0 + beyond * beyond * 0.04) * speed;
        rate.min(AUTO_SCROLL_MAX_SPEED * speed) * offset.signum()
    };
    Velocity {
        x: axis(offset_x),
        y: axis(offset_y),
    }
}

/// One step of the glide after `dt_ms`. It ends once the speed is below a fiftieth of a point per millisecond.
#[uniffi::export]
pub fn drag_glide_step(velocity: Velocity, dt_ms: f64, keep_per_frame: f64) -> GlideStep {
    let frames = (dt_ms / (1000.0 / 60.0)).max(0.0);
    let decay = keep_per_frame.clamp(0.0, 1.0).powf(frames);
    let next = Velocity {
        x: velocity.x * decay,
        y: velocity.y * decay,
    };
    let rest = if next.x.abs() < 0.02 && next.y.abs() < 0.02 {
        Velocity { x: 0.0, y: 0.0 }
    } else {
        next
    };
    GlideStep {
        dx: velocity.x * dt_ms,
        dy: velocity.y * dt_ms,
        rest,
    }
}

impl Store {
    pub fn drag_tools_config(&self) -> Result<DragToolsConfig, CoreError> {
        let conn = self.conn();
        let json: Option<String> = conn
            .query_row(
                "SELECT value FROM settings WHERE key = ?1",
                params![SETTINGS_KEY],
                |r| r.get(0),
            )
            .optional()?;
        Ok(json
            .and_then(|j| serde_json::from_str::<DragToolsConfig>(&j).ok())
            .unwrap_or_default()
            .sanitized())
    }

    pub fn save_drag_tools_config(&self, config: &DragToolsConfig) -> Result<(), CoreError> {
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

    #[test]
    fn settings_are_kept_in_range_and_the_main_buttons_need_keys() {
        let wild = DragToolsConfig {
            scroll_enabled: true,
            scroll_button: 99,
            scroll_modifier: 1 << 40,
            scroll_speed: f64::NAN,
            momentum_keep: 5.0,
            follow_modifier: 1 << 50,
            ..DragToolsConfig::default()
        }
        .sanitized();
        assert_eq!(
            (
                wild.scroll_button,
                wild.scroll_modifier,
                wild.follow_modifier
            ),
            (31, 0, 0)
        );
        assert_eq!((wild.scroll_speed, wild.momentum_keep), (1.0, 0.99));
        let left_alone = DragToolsConfig {
            scroll_enabled: true,
            scroll_button: 0,
            ..DragToolsConfig::default()
        }
        .sanitized();
        assert!(
            !left_alone.scroll_enabled,
            "the left button alone would break clicking"
        );
        let left_with_keys = DragToolsConfig {
            scroll_enabled: true,
            scroll_button: 0,
            scroll_modifier: m::OPTION,
            ..DragToolsConfig::default()
        }
        .sanitized();
        assert!(left_with_keys.scroll_enabled);
        let middle = DragToolsConfig {
            scroll_enabled: true,
            ..DragToolsConfig::default()
        }
        .sanitized();
        assert!(middle.scroll_enabled, "the middle button is free to take");
    }

    #[test]
    fn letting_go_after_a_pause_stops_the_page() {
        let mv = |dx, at_ms| DragMove { dx, dy: 0.0, at_ms };
        let moves = vec![mv(10.0, 1000), mv(10.0, 1016), mv(10.0, 1032)];
        let v = drag_release_velocity(moves.clone(), 1040);
        assert!(
            v.x > 0.5 && v.y == 0.0,
            "about 30 points over 32 ms: {}",
            v.x
        );
        assert_eq!(
            drag_release_velocity(moves, 1300),
            Velocity { x: 0.0, y: 0.0 },
            "paused for 250 ms"
        );
        assert_eq!(
            drag_release_velocity(vec![], 5),
            Velocity { x: 0.0, y: 0.0 }
        );
    }

    #[test]
    fn the_glide_slows_down_and_ends() {
        let mut velocity = Velocity { x: 1.0, y: -0.5 };
        let mut travelled = 0.0;
        let mut steps = 0;
        while velocity != (Velocity { x: 0.0, y: 0.0 }) && steps < 2000 {
            let step = drag_glide_step(velocity, 8.0, 0.94);
            assert!(step.rest.x.abs() <= velocity.x.abs());
            travelled += step.dx;
            velocity = step.rest;
            steps += 1;
        }
        assert!(steps < 2000, "it must end");
        assert!(travelled > 50.0 && travelled < 2000.0, "{travelled}");
        assert_eq!(
            drag_glide_step(Velocity { x: 1.0, y: 1.0 }, 0.0, 0.94).rest,
            Velocity { x: 1.0, y: 1.0 },
            "no time, no slowing"
        );
    }

    #[test]
    fn double_click_and_wheel_bindings_are_kept_safe() {
        let config = DragToolsConfig {
            double_clicks: vec![
                DoubleClickBinding {
                    button: 0,
                    modifiers: 0,
                    action_id: "a".into(),
                },
                DoubleClickBinding {
                    button: 2,
                    modifiers: 0,
                    action_id: "b".into(),
                },
                DoubleClickBinding {
                    button: 2,
                    modifiers: 0,
                    action_id: "dup".into(),
                },
                DoubleClickBinding {
                    button: 1,
                    modifiers: m::OPTION,
                    action_id: " c ".into(),
                },
                DoubleClickBinding {
                    button: 3,
                    modifiers: 0,
                    action_id: "  ".into(),
                },
            ],
            double_click_ms: 5,
            button_scrolls: vec![
                ButtonScrollBinding {
                    button: 3,
                    up_action_id: Some(" up ".into()),
                    down_action_id: None,
                },
                ButtonScrollBinding {
                    button: 3,
                    up_action_id: Some("dup".into()),
                    down_action_id: None,
                },
                ButtonScrollBinding {
                    button: 4,
                    up_action_id: None,
                    down_action_id: Some(" ".into()),
                },
                ButtonScrollBinding {
                    button: 0,
                    up_action_id: Some("x".into()),
                    down_action_id: None,
                },
            ],
            ..DragToolsConfig::default()
        }
        .sanitized();
        let ids: Vec<&str> = config
            .double_clicks
            .iter()
            .map(|b| b.action_id.as_str())
            .collect();
        assert_eq!(
            ids,
            vec!["b", "c"],
            "the main button alone, repeats and empty actions are dropped"
        );
        assert_eq!(config.double_click_ms, 150);
        assert_eq!(config.button_scrolls.len(), 2);
        assert_eq!(config.button_scrolls[0].up_action_id.as_deref(), Some("up"));
        assert_eq!(
            config.button_scrolls[1].button, 2,
            "the left button cannot hold a wheel action"
        );
    }

    #[test]
    fn auto_scroll_waits_for_the_pointer_to_leave_the_dead_zone() {
        let v = auto_scroll_velocity(0.0, 0.0, 1.0);
        assert_eq!((v.x, v.y), (0.0, 0.0));
        let v = auto_scroll_velocity(AUTO_SCROLL_DEAD_ZONE, -AUTO_SCROLL_DEAD_ZONE, 1.0);
        assert_eq!(
            (v.x, v.y),
            (0.0, 0.0),
            "the edge of the zone is still inside it"
        );
        let v = auto_scroll_velocity(AUTO_SCROLL_DEAD_ZONE + 5.0, 0.0, 1.0);
        assert!(v.x > 0.0 && v.y == 0.0);
    }

    #[test]
    fn auto_scroll_goes_the_way_the_pointer_went_and_faster_the_further_out() {
        let near = auto_scroll_velocity(0.0, 40.0, 1.0);
        let far = auto_scroll_velocity(0.0, 200.0, 1.0);
        assert!(near.y > 0.0 && far.y > near.y);
        let up = auto_scroll_velocity(0.0, -200.0, 1.0);
        assert_eq!(up.y, -far.y, "the same speed either way");
        let left = auto_scroll_velocity(-80.0, 0.0, 1.0);
        assert!(left.x < 0.0);
        let diagonal = auto_scroll_velocity(60.0, 60.0, 1.0);
        assert!(diagonal.x > 0.0 && diagonal.y > 0.0 && (diagonal.x - diagonal.y).abs() < 1e-9);
    }

    #[test]
    fn auto_scroll_is_capped_and_the_speed_setting_scales_it() {
        let far = auto_scroll_velocity(0.0, 100_000.0, 1.0);
        assert_eq!(far.y, AUTO_SCROLL_MAX_SPEED);
        let slow = auto_scroll_velocity(0.0, 100.0, 0.5);
        let usual = auto_scroll_velocity(0.0, 100.0, 1.0);
        assert!((slow.y * 2.0 - usual.y).abs() < 1e-9);
        let nonsense = auto_scroll_velocity(f64::NAN, f64::INFINITY, f64::NAN);
        assert!(
            nonsense.x == 0.0 && nonsense.y == 0.0,
            "numbers that are not numbers do nothing"
        );
        assert_eq!(
            auto_scroll_velocity(0.0, 100.0, 1_000.0).y,
            auto_scroll_velocity(0.0, 100.0, 5.0).y
        );
    }

    #[test]
    fn auto_scroll_settings_are_kept_safe() {
        let c = DragToolsConfig {
            auto_scroll_enabled: true,
            auto_scroll_button: 0,
            auto_scroll_speed: 99.0,
            ..DragToolsConfig::default()
        }
        .sanitized();
        assert!(
            !c.auto_scroll_enabled,
            "a plain click of the left button cannot start it"
        );
        assert_eq!(c.auto_scroll_speed, 5.0);
        let with_keys = DragToolsConfig {
            auto_scroll_enabled: true,
            auto_scroll_button: 0,
            auto_scroll_modifier: m::OPTION,
            ..DragToolsConfig::default()
        }
        .sanitized();
        assert!(with_keys.auto_scroll_enabled);
        let middle = DragToolsConfig {
            auto_scroll_enabled: true,
            ..DragToolsConfig::default()
        }
        .sanitized();
        assert!(middle.auto_scroll_enabled);
        // A saved configuration from before auto-scroll existed has it off.
        let old: DragToolsConfig = serde_json::from_str(r#"{"scroll_enabled":true}"#).unwrap();
        assert!(!old.auto_scroll_enabled && old.auto_scroll_speed == 1.0);
    }

    #[test]
    fn the_configuration_is_stored() {
        let store = Store::open_in_memory().unwrap();
        assert!(!store.drag_tools_config().unwrap().scroll_enabled);
        store
            .save_drag_tools_config(&DragToolsConfig {
                scroll_enabled: true,
                scroll_invert: true,
                ..DragToolsConfig::default()
            })
            .unwrap();
        let back = store.drag_tools_config().unwrap();
        assert!(back.scroll_enabled && back.scroll_invert);
    }
}
