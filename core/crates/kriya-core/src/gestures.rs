//! Button gestures: hold a button and move to draw a direction, and "rocker" clicks (hold one button, click the other).
//! The engine only decides what a press means; the shell swallows or passes the event and runs the action.

use std::sync::Mutex;

use crate::mouse::GestureDirection;

const LEFT: u32 = 0;
const RIGHT: u32 = 1;

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct GestureEngineConfig {
    /// The button held to draw a gesture, or `None` when gestures are off.
    pub activation_button: Option<u32>,
    /// Points the pointer must travel to count as a gesture.
    pub threshold: f64,
    /// A gesture must be finished within this many milliseconds.
    pub timeout_ms: u32,
    /// Whether rocker clicks are watched for.
    pub rocker: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum RockerKind {
    /// The right button was held, then the left was clicked.
    RightThenLeft,
    /// The left button was held, then the right was clicked.
    LeftThenRight,
}

/// What the shell should do with a button event.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum ButtonDecision {
    /// Not ours: let the event through.
    PassThrough,
    /// Ours: drop the event.
    Swallow,
    /// The press was held back to see if it became a gesture and it did not: perform an ordinary click of this button.
    ReplayClick { button: u32 },
    /// A gesture was drawn. The event is dropped.
    Gesture { direction: GestureDirection },
    /// A rocker click. The event is dropped.
    Rocker { kind: RockerKind },
}

struct Press {
    button: u32,
    start_x: f64,
    start_y: f64,
    start_ms: u64,
    x: f64,
    y: f64,
}

struct State {
    config: GestureEngineConfig,
    press: Option<Press>,
    left_down: bool,
    right_down: bool,
    /// Buttons whose next release belongs to a press the engine already consumed.
    swallow_release: Vec<u32>,
}

#[derive(uniffi::Object)]
pub struct GestureEngine {
    state: Mutex<State>,
}

#[uniffi::export]
impl GestureEngine {
    #[uniffi::constructor]
    pub fn new(config: GestureEngineConfig) -> Self {
        GestureEngine {
            state: Mutex::new(State {
                config,
                press: None,
                left_down: false,
                right_down: false,
                swallow_release: Vec::new(),
            }),
        }
    }

    /// Replaces the settings and forgets any press in progress.
    pub fn set_config(&self, config: GestureEngineConfig) {
        let mut state = self.lock();
        state.config = config;
        state.press = None;
        state.swallow_release.clear();
    }

    pub fn reset(&self) {
        let mut state = self.lock();
        state.press = None;
        state.left_down = false;
        state.right_down = false;
        state.swallow_release.clear();
    }

    pub fn button_down(&self, button: u32, x: f64, y: f64, now_ms: u64) -> ButtonDecision {
        let mut state = self.lock();
        if state.config.rocker {
            if button == LEFT && state.right_down {
                state.swallow_release.push(LEFT);
                return ButtonDecision::Rocker {
                    kind: RockerKind::RightThenLeft,
                };
            }
            if button == RIGHT && state.left_down {
                state.swallow_release.push(RIGHT);
                return ButtonDecision::Rocker {
                    kind: RockerKind::LeftThenRight,
                };
            }
        }
        match button {
            LEFT => state.left_down = true,
            RIGHT => state.right_down = true,
            _ => {}
        }
        if state.config.activation_button == Some(button) && state.press.is_none() {
            state.press = Some(Press {
                button,
                start_x: x,
                start_y: y,
                start_ms: now_ms,
                x,
                y,
            });
            return ButtonDecision::Swallow;
        }
        ButtonDecision::PassThrough
    }

    /// True while the activation button is held and its press is being watched, so the shell can hide the drag
    /// events from other apps while a gesture is being drawn.
    pub fn is_gesture_active(&self) -> bool {
        self.lock().press.is_some()
    }

    /// Records where the pointer is while the activation button is held. Cheap enough for every drag event.
    pub fn moved(&self, x: f64, y: f64) {
        let mut state = self.lock();
        if let Some(press) = state.press.as_mut() {
            press.x = x;
            press.y = y;
        }
    }

    pub fn button_up(&self, button: u32, x: f64, y: f64, now_ms: u64) -> ButtonDecision {
        let mut state = self.lock();
        if let Some(index) = state.swallow_release.iter().position(|b| *b == button) {
            state.swallow_release.remove(index);
            return ButtonDecision::Swallow;
        }
        match button {
            LEFT => state.left_down = false,
            RIGHT => state.right_down = false,
            _ => {}
        }
        let held = matches!(&state.press, Some(p) if p.button == button);
        if !held {
            return ButtonDecision::PassThrough;
        }
        let Some(mut press) = state.press.take() else {
            return ButtonDecision::PassThrough;
        };
        press.x = x;
        press.y = y;
        let dx = press.x - press.start_x;
        let dy = press.y - press.start_y;
        let travelled = dx.hypot(dy);
        let took = now_ms.saturating_sub(press.start_ms);
        let far_enough = travelled >= state.config.threshold;
        let in_time = took <= u64::from(state.config.timeout_ms);
        match (far_enough, in_time) {
            (true, true) => ButtonDecision::Gesture {
                direction: direction_of(dx, dy),
            },
            (true, false) => ButtonDecision::Swallow,
            (false, _) => ButtonDecision::ReplayClick { button },
        }
    }
}

impl GestureEngine {
    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }
}

/// The dominant direction of a movement. Screen y grows downward.
fn direction_of(dx: f64, dy: f64) -> GestureDirection {
    if dx.abs() >= dy.abs() {
        if dx >= 0.0 {
            GestureDirection::Right
        } else {
            GestureDirection::Left
        }
    } else if dy >= 0.0 {
        GestureDirection::Down
    } else {
        GestureDirection::Up
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn engine(rocker: bool) -> GestureEngine {
        GestureEngine::new(GestureEngineConfig {
            activation_button: Some(2),
            threshold: 50.0,
            timeout_ms: 500,
            rocker,
        })
    }

    #[test]
    fn a_drag_past_the_threshold_is_a_gesture() {
        let e = engine(false);
        assert_eq!(e.button_down(2, 100.0, 100.0, 0), ButtonDecision::Swallow);
        e.moved(100.0, 130.0);
        assert_eq!(
            e.button_up(2, 100.0, 20.0, 200),
            ButtonDecision::Gesture {
                direction: GestureDirection::Up
            }
        );
    }

    #[test]
    fn directions_follow_the_dominant_axis() {
        assert_eq!(direction_of(80.0, 10.0), GestureDirection::Right);
        assert_eq!(direction_of(-80.0, 10.0), GestureDirection::Left);
        assert_eq!(direction_of(10.0, 80.0), GestureDirection::Down);
        assert_eq!(direction_of(10.0, -80.0), GestureDirection::Up);
    }

    #[test]
    fn a_click_without_movement_is_replayed() {
        let e = engine(false);
        e.button_down(2, 10.0, 10.0, 0);
        assert_eq!(
            e.button_up(2, 12.0, 11.0, 90),
            ButtonDecision::ReplayClick { button: 2 }
        );
    }

    #[test]
    fn a_slow_gesture_is_cancelled_not_run() {
        let e = engine(false);
        e.button_down(2, 0.0, 0.0, 0);
        assert_eq!(e.button_up(2, 200.0, 0.0, 5_000), ButtonDecision::Swallow);
    }

    #[test]
    fn a_long_press_without_movement_is_still_a_click() {
        let e = engine(false);
        e.button_down(2, 0.0, 0.0, 0);
        assert_eq!(
            e.button_up(2, 0.0, 0.0, 5_000),
            ButtonDecision::ReplayClick { button: 2 }
        );
    }

    #[test]
    fn a_gesture_is_active_only_while_the_button_is_held() {
        let e = engine(false);
        assert!(!e.is_gesture_active());
        e.button_down(2, 0.0, 0.0, 0);
        assert!(e.is_gesture_active());
        e.button_up(2, 0.0, 0.0, 10);
        assert!(!e.is_gesture_active());
    }

    #[test]
    fn other_buttons_pass_through() {
        let e = engine(false);
        assert_eq!(e.button_down(3, 0.0, 0.0, 0), ButtonDecision::PassThrough);
        assert_eq!(e.button_up(3, 0.0, 0.0, 10), ButtonDecision::PassThrough);
    }

    #[test]
    fn gestures_off_means_nothing_is_held_back() {
        let e = GestureEngine::new(GestureEngineConfig {
            activation_button: None,
            threshold: 50.0,
            timeout_ms: 500,
            rocker: false,
        });
        assert_eq!(e.button_down(2, 0.0, 0.0, 0), ButtonDecision::PassThrough);
    }

    #[test]
    fn rocker_right_then_left() {
        let e = engine(true);
        assert_eq!(e.button_down(1, 0.0, 0.0, 0), ButtonDecision::PassThrough);
        assert_eq!(
            e.button_down(0, 0.0, 0.0, 50),
            ButtonDecision::Rocker {
                kind: RockerKind::RightThenLeft
            }
        );
        assert_eq!(e.button_up(0, 0.0, 0.0, 80), ButtonDecision::Swallow);
        assert_eq!(e.button_up(1, 0.0, 0.0, 120), ButtonDecision::PassThrough);
    }

    #[test]
    fn rocker_left_then_right() {
        let e = engine(true);
        e.button_down(0, 0.0, 0.0, 0);
        assert_eq!(
            e.button_down(1, 0.0, 0.0, 50),
            ButtonDecision::Rocker {
                kind: RockerKind::LeftThenRight
            }
        );
        assert_eq!(e.button_up(1, 0.0, 0.0, 80), ButtonDecision::Swallow);
    }

    #[test]
    fn separate_clicks_are_not_a_rocker() {
        let e = engine(true);
        e.button_down(1, 0.0, 0.0, 0);
        e.button_up(1, 0.0, 0.0, 30);
        assert_eq!(e.button_down(0, 0.0, 0.0, 60), ButtonDecision::PassThrough);
    }

    #[test]
    fn rocker_does_nothing_when_switched_off() {
        let e = engine(false);
        e.button_down(1, 0.0, 0.0, 0);
        assert_eq!(e.button_down(0, 0.0, 0.0, 50), ButtonDecision::PassThrough);
    }

    #[test]
    fn changing_the_settings_drops_a_press_in_progress() {
        let e = engine(false);
        e.button_down(2, 0.0, 0.0, 0);
        e.set_config(GestureEngineConfig {
            activation_button: Some(2),
            threshold: 50.0,
            timeout_ms: 500,
            rocker: false,
        });
        assert_eq!(e.button_up(2, 100.0, 0.0, 50), ButtonDecision::PassThrough);
    }
}
