//! Scroll maths shared by every platform: reversing, speed, acceleration, sensitivity and smooth scrolling.
//! The shells call these with plain numbers for every wheel event, so nothing here allocates or touches the OS.

use std::sync::Mutex;

use crate::mouse::ScrollAxis;

/// Wheel speed, in notches per second, at which acceleration starts to count.
const ACCELERATION_REFERENCE: f64 = 20.0;
/// The most acceleration can multiply a scroll by (on top of 1.0).
const ACCELERATION_CAP: f64 = 4.0;
/// A pause this long forgets how fast the wheel was turning.
const VELOCITY_RESET_MS: u64 = 250;
/// The longest glide, in milliseconds, at the highest smoothing setting.
const MAX_SMOOTHING_MS: f64 = 220.0;
const MAX_PENDING: f64 = 20_000.0;

/// Reverses and rescales one delta from a trackpad or Magic Mouse, which already sends fine movements.
#[uniffi::export]
pub fn scroll_continuous(delta: f64, speed: f64, reverse: bool) -> f64 {
    let scaled = delta * speed;
    if reverse {
        -scaled
    } else {
        scaled
    }
}

struct ShaperState {
    axis: ScrollAxis,
    last_ms: u64,
    velocity: f64,
}

/// Shapes the deltas from a notched mouse wheel for one axis.
#[derive(uniffi::Object)]
pub struct ScrollShaper {
    state: Mutex<ShaperState>,
}

#[uniffi::export]
impl ScrollShaper {
    #[uniffi::constructor]
    pub fn new(axis: ScrollAxis) -> Self {
        ScrollShaper {
            state: Mutex::new(ShaperState {
                axis: axis.sanitized(),
                last_ms: 0,
                velocity: 0.0,
            }),
        }
    }

    pub fn set_axis(&self, axis: ScrollAxis) {
        self.lock().axis = axis.sanitized();
    }

    /// Takes a wheel delta in lines (1.0 is one notch) and the time of the event in milliseconds, and returns the
    /// delta to use: faster wheel turns scroll further when acceleration is on, small movements are scaled by
    /// sensitivity, then speed and direction are applied.
    pub fn shape(&self, delta: f64, now_ms: u64) -> f64 {
        if delta == 0.0 {
            return 0.0;
        }
        let mut state = self.lock();
        let gap = now_ms.saturating_sub(state.last_ms);
        state.last_ms = now_ms;
        let instant = delta.abs() / (gap.max(1) as f64) * 1000.0;
        state.velocity = if gap > VELOCITY_RESET_MS {
            instant.min(ACCELERATION_REFERENCE)
        } else {
            0.6 * state.velocity + 0.4 * instant
        };

        let axis = &state.axis;
        let mut value = delta;
        if value.abs() < 1.0 {
            value *= axis.sensitivity;
        }
        let boost = 1.0
            + axis.acceleration * (state.velocity / ACCELERATION_REFERENCE).min(ACCELERATION_CAP);
        value *= axis.speed * boost;
        if axis.reverse {
            value = -value;
        }
        value
    }

    pub fn smoothing(&self) -> f64 {
        self.lock().axis.smoothing
    }
}

impl ScrollShaper {
    fn lock(&self) -> std::sync::MutexGuard<'_, ShaperState> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct ScrollStep {
    pub dx: f64,
    pub dy: f64,
}

struct SmootherState {
    pending_x: f64,
    pending_y: f64,
    tau_ms: f64,
}

/// Turns the jumps of a notched wheel into a glide. Wheel movement is added with `push`; the shell asks for the next
/// slice of it on a timer with `tick` and posts that as a smooth scroll.
#[derive(uniffi::Object)]
pub struct SmoothScroller {
    state: Mutex<SmootherState>,
}

#[uniffi::export]
impl SmoothScroller {
    #[uniffi::constructor]
    pub fn new() -> Self {
        SmoothScroller {
            state: Mutex::new(SmootherState {
                pending_x: 0.0,
                pending_y: 0.0,
                tau_ms: 0.0,
            }),
        }
    }

    /// Adds movement, in pixels, to glide through. `smoothing` is 0 to 1 and sets how long the glide takes.
    pub fn push(&self, dx: f64, dy: f64, smoothing: f64) {
        let mut state = self.lock();
        state.pending_x = (state.pending_x + dx).clamp(-MAX_PENDING, MAX_PENDING);
        state.pending_y = (state.pending_y + dy).clamp(-MAX_PENDING, MAX_PENDING);
        state.tau_ms = smoothing.clamp(0.0, 1.0) * MAX_SMOOTHING_MS;
    }

    /// The next slice of the glide after `dt_ms` milliseconds. Returns zeros when nothing is left.
    pub fn tick(&self, dt_ms: f64) -> ScrollStep {
        let mut state = self.lock();
        let fraction = if state.tau_ms <= 0.0 {
            1.0
        } else {
            1.0 - (-dt_ms.max(0.0) / state.tau_ms).exp()
        };
        let mut dx = state.pending_x * fraction;
        let mut dy = state.pending_y * fraction;
        state.pending_x -= dx;
        state.pending_y -= dy;
        // Finish the last fraction of a pixel instead of gliding on forever.
        if state.pending_x.abs() < 0.5 {
            dx += state.pending_x;
            state.pending_x = 0.0;
        }
        if state.pending_y.abs() < 0.5 {
            dy += state.pending_y;
            state.pending_y = 0.0;
        }
        ScrollStep { dx, dy }
    }

    pub fn is_idle(&self) -> bool {
        let state = self.lock();
        state.pending_x == 0.0 && state.pending_y == 0.0
    }

    pub fn clear(&self) {
        let mut state = self.lock();
        state.pending_x = 0.0;
        state.pending_y = 0.0;
    }
}

impl Default for SmoothScroller {
    fn default() -> Self {
        Self::new()
    }
}

impl SmoothScroller {
    fn lock(&self) -> std::sync::MutexGuard<'_, SmootherState> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn axis() -> ScrollAxis {
        ScrollAxis::default()
    }

    #[test]
    fn neutral_axis_changes_nothing() {
        let shaper = ScrollShaper::new(axis());
        assert_eq!(shaper.shape(1.0, 1000), 1.0);
        assert_eq!(shaper.shape(-2.0, 2000), -2.0);
    }

    #[test]
    fn reverse_flips_direction_and_speed_scales() {
        let shaper = ScrollShaper::new(ScrollAxis {
            reverse: true,
            speed: 2.0,
            ..axis()
        });
        assert_eq!(shaper.shape(1.0, 1000), -2.0);
    }

    #[test]
    fn sensitivity_only_affects_small_movements() {
        let shaper = ScrollShaper::new(ScrollAxis {
            sensitivity: 2.0,
            ..axis()
        });
        assert_eq!(shaper.shape(0.5, 1000), 1.0);
        assert_eq!(shaper.shape(3.0, 2000), 3.0);
    }

    #[test]
    fn acceleration_rewards_a_fast_wheel() {
        let shaper = ScrollShaper::new(ScrollAxis {
            acceleration: 1.0,
            ..axis()
        });
        let slow = shaper.shape(1.0, 10_000);
        let mut fast = 0.0;
        for i in 0..10 {
            fast = shaper.shape(1.0, 20_000 + i * 20);
        }
        assert!(fast > slow, "fast {fast} should beat slow {slow}");
    }

    #[test]
    fn a_pause_forgets_the_speed() {
        let shaper = ScrollShaper::new(ScrollAxis {
            acceleration: 1.0,
            ..axis()
        });
        for i in 0..10 {
            shaper.shape(1.0, 1000 + i * 10);
        }
        let after_pause = shaper.shape(1.0, 10_000);
        let steady = ScrollShaper::new(ScrollAxis {
            acceleration: 1.0,
            ..axis()
        })
        .shape(1.0, 10_000);
        // Both start from a long pause, so both see almost no speed.
        assert!((after_pause - steady).abs() < 0.01);
    }

    #[test]
    fn zero_stays_zero() {
        assert_eq!(ScrollShaper::new(axis()).shape(0.0, 5), 0.0);
    }

    #[test]
    fn continuous_scroll_scales_and_reverses() {
        assert_eq!(scroll_continuous(10.0, 1.5, false), 15.0);
        assert_eq!(scroll_continuous(10.0, 1.5, true), -15.0);
    }

    #[test]
    fn smooth_scroller_delivers_everything_it_was_given() {
        let scroller = SmoothScroller::new();
        scroller.push(0.0, -100.0, 0.5);
        let mut total = 0.0;
        let mut ticks = 0;
        while !scroller.is_idle() && ticks < 10_000 {
            total += scroller.tick(8.0).dy;
            ticks += 1;
        }
        assert!(scroller.is_idle());
        assert!((total + 100.0).abs() < 1e-6, "delivered {total}");
        assert!(ticks > 3, "a glide takes more than a few ticks");
    }

    #[test]
    fn no_smoothing_delivers_at_once() {
        let scroller = SmoothScroller::new();
        scroller.push(30.0, 40.0, 0.0);
        assert_eq!(scroller.tick(8.0), ScrollStep { dx: 30.0, dy: 40.0 });
        assert!(scroller.is_idle());
    }

    #[test]
    fn clear_drops_what_is_left() {
        let scroller = SmoothScroller::new();
        scroller.push(0.0, 500.0, 1.0);
        scroller.clear();
        assert!(scroller.is_idle());
    }
}
