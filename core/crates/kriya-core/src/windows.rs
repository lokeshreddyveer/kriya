//! Window management logic shared by every platform: where each layout puts a window, which screen edge snaps to what,
//! how a window moves between displays, saved layouts, placement rules, the window switcher's ranking and undo history.
//!
//! All rectangles use a top-left origin with y growing downward, in points. The shell converts from its own coordinates.

use std::collections::{HashMap, HashSet};
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

use crate::actions::modifiers as m;

pub const MIN_WINDOW_SIZE: f64 = 100.0;
pub const MAX_HISTORY: usize = 30;

#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize, uniffi::Record)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Rect {
    pub fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Rect {
            x,
            y,
            width,
            height,
        }
    }

    pub fn max_x(&self) -> f64 {
        self.x + self.width
    }

    pub fn max_y(&self) -> f64 {
        self.y + self.height
    }

    pub fn contains(&self, p: Point) -> bool {
        p.x >= self.x && p.x < self.max_x() && p.y >= self.y && p.y < self.max_y()
    }

    /// How much of `self` lies inside `other`, in square points.
    pub fn overlap_area(&self, other: &Rect) -> f64 {
        let w = (self.max_x().min(other.max_x()) - self.x.max(other.x)).max(0.0);
        let h = (self.max_y().min(other.max_y()) - self.y.max(other.y)).max(0.0);
        w * h
    }

    fn approx_eq(&self, o: &Rect) -> bool {
        (self.x - o.x).abs() < 1.0
            && (self.y - o.y).abs() < 1.0
            && (self.width - o.width).abs() < 1.0
            && (self.height - o.height).abs() < 1.0
    }

    pub fn is_valid(&self) -> bool {
        [self.x, self.y, self.width, self.height]
            .iter()
            .all(|v| v.is_finite())
            && self.width > 0.0
            && self.height > 0.0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

// ---- layouts ---------------------------------------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum WindowLayout {
    LeftHalf,
    RightHalf,
    TopHalf,
    BottomHalf,
    TopLeft,
    TopRight,
    BottomLeft,
    BottomRight,
    FirstThird,
    CenterThird,
    LastThird,
    FirstTwoThirds,
    LastTwoThirds,
    TopLeftSixth,
    TopCenterSixth,
    TopRightSixth,
    BottomLeftSixth,
    BottomCenterSixth,
    BottomRightSixth,
    Maximize,
    Center,
}

pub const ALL_LAYOUTS: [WindowLayout; 21] = [
    WindowLayout::LeftHalf,
    WindowLayout::RightHalf,
    WindowLayout::TopHalf,
    WindowLayout::BottomHalf,
    WindowLayout::TopLeft,
    WindowLayout::TopRight,
    WindowLayout::BottomLeft,
    WindowLayout::BottomRight,
    WindowLayout::FirstThird,
    WindowLayout::CenterThird,
    WindowLayout::LastThird,
    WindowLayout::FirstTwoThirds,
    WindowLayout::LastTwoThirds,
    WindowLayout::TopLeftSixth,
    WindowLayout::TopCenterSixth,
    WindowLayout::TopRightSixth,
    WindowLayout::BottomLeftSixth,
    WindowLayout::BottomCenterSixth,
    WindowLayout::BottomRightSixth,
    WindowLayout::Maximize,
    WindowLayout::Center,
];

impl WindowLayout {
    pub fn command(self) -> &'static str {
        use WindowLayout::*;
        match self {
            LeftHalf => "window.left_half",
            RightHalf => "window.right_half",
            TopHalf => "window.top_half",
            BottomHalf => "window.bottom_half",
            TopLeft => "window.top_left",
            TopRight => "window.top_right",
            BottomLeft => "window.bottom_left",
            BottomRight => "window.bottom_right",
            FirstThird => "window.first_third",
            CenterThird => "window.center_third",
            LastThird => "window.last_third",
            FirstTwoThirds => "window.first_two_thirds",
            LastTwoThirds => "window.last_two_thirds",
            TopLeftSixth => "window.top_left_sixth",
            TopCenterSixth => "window.top_center_sixth",
            TopRightSixth => "window.top_right_sixth",
            BottomLeftSixth => "window.bottom_left_sixth",
            BottomCenterSixth => "window.bottom_center_sixth",
            BottomRightSixth => "window.bottom_right_sixth",
            Maximize => "window.maximize",
            Center => "window.center",
        }
    }

    pub fn title(self) -> &'static str {
        use WindowLayout::*;
        match self {
            LeftHalf => "Left half",
            RightHalf => "Right half",
            TopHalf => "Top half",
            BottomHalf => "Bottom half",
            TopLeft => "Top left quarter",
            TopRight => "Top right quarter",
            BottomLeft => "Bottom left quarter",
            BottomRight => "Bottom right quarter",
            FirstThird => "First third",
            CenterThird => "Center third",
            LastThird => "Last third",
            FirstTwoThirds => "First two thirds",
            LastTwoThirds => "Last two thirds",
            TopLeftSixth => "Top left sixth",
            TopCenterSixth => "Top center sixth",
            TopRightSixth => "Top right sixth",
            BottomLeftSixth => "Bottom left sixth",
            BottomCenterSixth => "Bottom center sixth",
            BottomRightSixth => "Bottom right sixth",
            Maximize => "Maximize",
            Center => "Center",
        }
    }

    pub fn from_command(command: &str) -> Option<Self> {
        ALL_LAYOUTS.into_iter().find(|l| l.command() == command)
    }

    /// The share of the screen this layout covers as (x, y, width, height) fractions. `Center` keeps the window's size.
    fn fractions(self) -> Option<(f64, f64, f64, f64)> {
        use WindowLayout::*;
        let (t, s) = (1.0 / 3.0, 1.0 / 2.0);
        Some(match self {
            LeftHalf => (0.0, 0.0, s, 1.0),
            RightHalf => (s, 0.0, s, 1.0),
            TopHalf => (0.0, 0.0, 1.0, s),
            BottomHalf => (0.0, s, 1.0, s),
            TopLeft => (0.0, 0.0, s, s),
            TopRight => (s, 0.0, s, s),
            BottomLeft => (0.0, s, s, s),
            BottomRight => (s, s, s, s),
            FirstThird => (0.0, 0.0, t, 1.0),
            CenterThird => (t, 0.0, t, 1.0),
            LastThird => (2.0 * t, 0.0, t, 1.0),
            FirstTwoThirds => (0.0, 0.0, 2.0 * t, 1.0),
            LastTwoThirds => (t, 0.0, 2.0 * t, 1.0),
            TopLeftSixth => (0.0, 0.0, t, s),
            TopCenterSixth => (t, 0.0, t, s),
            TopRightSixth => (2.0 * t, 0.0, t, s),
            BottomLeftSixth => (0.0, s, t, s),
            BottomCenterSixth => (t, s, t, s),
            BottomRightSixth => (2.0 * t, s, t, s),
            Maximize => (0.0, 0.0, 1.0, 1.0),
            Center => return None,
        })
    }
}

/// The frame for a layout inside `area` (a display's usable space). `gap` is the space left between windows and at the
/// screen's edge; it is clamped so a window never shrinks below a usable size.
pub fn layout_frame(layout: WindowLayout, area: Rect, current: Rect, gap: f64) -> Rect {
    let gap = if gap.is_finite() {
        gap.clamp(0.0, 100.0)
    } else {
        0.0
    };
    let Some((fx, fy, fw, fh)) = layout.fractions() else {
        // Center: keep the size, but never larger than the area.
        let width = current
            .width
            .min(area.width)
            .max(MIN_WINDOW_SIZE.min(area.width));
        let height = current
            .height
            .min(area.height)
            .max(MIN_WINDOW_SIZE.min(area.height));
        return Rect::new(
            area.x + (area.width - width) / 2.0,
            area.y + (area.height - height) / 2.0,
            width,
            height,
        );
    };
    let mut left = area.x + fx * area.width;
    let mut top = area.y + fy * area.height;
    let mut right = left + fw * area.width;
    let mut bottom = top + fh * area.height;
    // Full gap at the screen's edge, half a gap on an edge shared with another window.
    left += if fx <= 0.0 { gap } else { gap / 2.0 };
    top += if fy <= 0.0 { gap } else { gap / 2.0 };
    right -= if fx + fw >= 0.999 { gap } else { gap / 2.0 };
    bottom -= if fy + fh >= 0.999 { gap } else { gap / 2.0 };
    let width = (right - left).max(MIN_WINDOW_SIZE.min(area.width));
    let height = (bottom - top).max(MIN_WINDOW_SIZE.min(area.height));
    Rect::new(left.round(), top.round(), width.round(), height.round())
}

// ---- custom sizes ----------------------------------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct CustomSize {
    pub id: String,
    pub name: String,
    /// Width and height, as a share of the display (0.1 to 1.0) or in points.
    pub width: f64,
    pub height: f64,
    pub as_fraction: bool,
    /// Place at the center of the display. Otherwise at `x` and `y` fractions of the free space.
    pub centered: bool,
    pub x: f64,
    pub y: f64,
}

impl CustomSize {
    pub fn sanitized(mut self) -> Self {
        let fix = |v: f64, lo: f64, hi: f64, fallback: f64| {
            if v.is_finite() {
                v.clamp(lo, hi)
            } else {
                fallback
            }
        };
        if self.as_fraction {
            self.width = fix(self.width, 0.1, 1.0, 0.6);
            self.height = fix(self.height, 0.1, 1.0, 0.6);
        } else {
            self.width = fix(self.width, MIN_WINDOW_SIZE, 20_000.0, 800.0);
            self.height = fix(self.height, MIN_WINDOW_SIZE, 20_000.0, 600.0);
        }
        self.x = fix(self.x, 0.0, 1.0, 0.5);
        self.y = fix(self.y, 0.0, 1.0, 0.5);
        self
    }
}

pub fn custom_frame(size: &CustomSize, area: Rect) -> Rect {
    let width = if size.as_fraction {
        size.width * area.width
    } else {
        size.width
    }
    .clamp(MIN_WINDOW_SIZE.min(area.width), area.width);
    let height = if size.as_fraction {
        size.height * area.height
    } else {
        size.height
    }
    .clamp(MIN_WINDOW_SIZE.min(area.height), area.height);
    let (fx, fy) = if size.centered {
        (0.5, 0.5)
    } else {
        (size.x, size.y)
    };
    Rect::new(
        (area.x + (area.width - width) * fx).round(),
        (area.y + (area.height - height) * fy).round(),
        width.round(),
        height.round(),
    )
}

// ---- cycling ---------------------------------------------------------------------------------------------------------

/// Pressing the same shortcut again steps through sizes: a half becomes a third, then two thirds, then a half again.
const CYCLES: [[WindowLayout; 3]; 2] = [
    [
        WindowLayout::LeftHalf,
        WindowLayout::FirstThird,
        WindowLayout::FirstTwoThirds,
    ],
    [
        WindowLayout::RightHalf,
        WindowLayout::LastThird,
        WindowLayout::LastTwoThirds,
    ],
];

/// `previous` is the layout last applied to this window by a shortcut, or `None` if it was not the last thing done.
pub fn cycle_layout(pressed: WindowLayout, previous: Option<WindowLayout>) -> WindowLayout {
    let Some(group) = CYCLES.iter().find(|g| g[0] == pressed) else {
        return pressed;
    };
    match previous.and_then(|p| group.iter().position(|l| *l == p)) {
        Some(i) => group[(i + 1) % group.len()],
        None => pressed,
    }
}

// ---- dragging to the edge --------------------------------------------------------------------------------------------

/// What a window snaps to when it is dragged until the pointer is at `p`: a corner gives a quarter, the left or right
/// edge a half, the top edge maximizes, the bottom edge the bottom half. `None` away from the edges.
pub fn snap_zone(p: Point, area: Rect, edge: f64, corner: f64) -> Option<WindowLayout> {
    if !area.contains(Point { x: p.x, y: p.y }) && !near(p, area, edge) {
        return None;
    }
    let left = p.x <= area.x + edge;
    let right = p.x >= area.max_x() - edge - 1.0;
    let top = p.y <= area.y + edge;
    let bottom = p.y >= area.max_y() - edge - 1.0;
    let in_left_corner = p.x <= area.x + corner;
    let in_right_corner = p.x >= area.max_x() - corner;
    let in_top_corner = p.y <= area.y + corner;
    let in_bottom_corner = p.y >= area.max_y() - corner;
    if (left || right) && (top || bottom || in_top_corner || in_bottom_corner)
        || (top || bottom) && (in_left_corner || in_right_corner)
    {
        let is_left = left || (!right && in_left_corner);
        let is_top = top || (!bottom && in_top_corner);
        return Some(match (is_left, is_top) {
            (true, true) => WindowLayout::TopLeft,
            (false, true) => WindowLayout::TopRight,
            (true, false) => WindowLayout::BottomLeft,
            (false, false) => WindowLayout::BottomRight,
        });
    }
    if left {
        Some(WindowLayout::LeftHalf)
    } else if right {
        Some(WindowLayout::RightHalf)
    } else if top {
        Some(WindowLayout::Maximize)
    } else if bottom {
        Some(WindowLayout::BottomHalf)
    } else {
        None
    }
}

fn near(p: Point, area: Rect, margin: f64) -> bool {
    p.x >= area.x - margin
        && p.x <= area.max_x() + margin
        && p.y >= area.y - margin
        && p.y <= area.max_y() + margin
}

// ---- moving between displays -----------------------------------------------------------------------------------------

/// Where a window goes when it moves from one display's area to another's. With `preserve_proportions` it keeps its
/// share of the screen (a left half stays a left half); otherwise it keeps its size and offset, pulled back inside
/// the new area if it would not fit.
pub fn translate_frame(frame: Rect, from: Rect, to: Rect, preserve_proportions: bool) -> Rect {
    if from.width <= 0.0 || from.height <= 0.0 {
        return contain(frame, to);
    }
    if preserve_proportions {
        let rx = (frame.x - from.x) / from.width;
        let ry = (frame.y - from.y) / from.height;
        let rw = frame.width / from.width;
        let rh = frame.height / from.height;
        return contain(
            Rect::new(
                to.x + rx * to.width,
                to.y + ry * to.height,
                rw * to.width,
                rh * to.height,
            ),
            to,
        );
    }
    contain(
        Rect::new(
            to.x + (frame.x - from.x),
            to.y + (frame.y - from.y),
            frame.width,
            frame.height,
        ),
        to,
    )
}

/// Shrinks and moves `frame` so it lies inside `area`.
pub fn contain(frame: Rect, area: Rect) -> Rect {
    let width = frame.width.min(area.width);
    let height = frame.height.min(area.height);
    let x = frame.x.clamp(area.x, (area.max_x() - width).max(area.x));
    let y = frame.y.clamp(area.y, (area.max_y() - height).max(area.y));
    Rect::new(x.round(), y.round(), width.round(), height.round())
}

/// The index of the area that holds most of `frame`, or the nearest one when it is off every display.
pub fn display_index_for(frame: Rect, areas: &[Rect]) -> Option<usize> {
    if areas.is_empty() {
        return None;
    }
    let best = areas
        .iter()
        .enumerate()
        .map(|(i, a)| (i, frame.overlap_area(a)))
        .max_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal))?;
    if best.1 > 0.0 {
        return Some(best.0);
    }
    let center = Point {
        x: frame.x + frame.width / 2.0,
        y: frame.y + frame.height / 2.0,
    };
    areas
        .iter()
        .enumerate()
        .min_by(|a, b| {
            distance(center, a.1)
                .partial_cmp(&distance(center, b.1))
                .unwrap_or(std::cmp::Ordering::Equal)
        })
        .map(|(i, _)| i)
}

fn distance(p: Point, r: &Rect) -> f64 {
    let dx = (r.x - p.x).max(0.0).max(p.x - r.max_x());
    let dy = (r.y - p.y).max(0.0).max(p.y - r.max_y());
    dx.hypot(dy)
}

/// A name for a set of connected displays, the same for the same displays in any order.
pub fn display_set_key(display_ids: &[String]) -> String {
    let mut ids: Vec<&str> = display_ids.iter().map(String::as_str).collect();
    ids.sort_unstable();
    ids.dedup();
    ids.join("|")
}

// ---- settings --------------------------------------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
#[serde(default)]
pub struct WindowConfig {
    pub gap: f64,
    pub snap_on_drag: bool,
    /// Keys that must be held while dragging for the window to snap. 0 means no key is needed.
    pub snap_drag_modifier: u64,
    pub edge_margin: f64,
    pub corner_size: f64,
    pub show_preview: bool,
    /// Hold this (modifier bits) and drag anywhere in a window to move it. 0 turns it off.
    pub move_modifier: u64,
    /// Hold this and drag to resize from the nearest corner. 0 turns it off.
    pub resize_modifier: u64,
    pub preserve_proportions: bool,
    pub cycle_sizes: bool,
    pub excluded_app_ids: Vec<String>,
    pub restore_on_reconnect: bool,
    pub apply_rules_on_launch: bool,
    /// A light tap on the trackpad when a dragged window snaps into place.
    pub haptic_on_snap: bool,
    /// How much of a stashed window stays visible at the screen edge, in points.
    pub stash_sliver: f64,
    /// Columns and rows of the keyboard grid.
    pub grid_columns: u32,
    pub grid_rows: u32,
    /// Todo mode: the app kept in a column at the side, its share of the display's width, and which side.
    pub todo_app_id: Option<String>,
    pub todo_fraction: f64,
    pub todo_on_right: bool,
    /// Hold these keys while dragging a window to show a saved layout's places as drop zones. 0 turns it off.
    pub drop_zone_modifier: u64,
    /// The saved layout whose places are the drop zones.
    pub drop_zone_layout_id: Option<String>,
    /// "Almost maximize" leaves this much at every edge, in points.
    pub almost_maximize_margin: f64,
    /// How much grow and shrink change a window each press, in points.
    pub resize_step: f64,
    /// Grow and shrink keep the window's shape.
    pub keep_aspect: bool,
    /// On an ultrawide display a maximized window is no wider than this. 0 turns it off.
    pub ultrawide_max_width: f64,
    /// Shortcuts and the menu act on the window under the pointer instead of the one with focus.
    pub act_on_pointer_window: bool,
    /// Show a small picture of each window in the switcher. Needs Screen Recording.
    pub switcher_thumbnails: bool,
    /// The radial menu's highlight colour (`#RRGGBB`) and its outer radius in points.
    pub radial_color: String,
    pub radial_size: f64,
    /// Put an app's windows where its rules say every time the app comes to the front, not only when it launches.
    pub apply_rules_on_activate: bool,
    /// Like ⌘Tab: press the shortcut again to step through the windows, and letting go of its keys switches to the chosen one.
    pub switcher_hold_release: bool,
}

impl Default for WindowConfig {
    fn default() -> Self {
        WindowConfig {
            gap: 0.0,
            snap_on_drag: true,
            snap_drag_modifier: 0,
            edge_margin: 6.0,
            corner_size: 40.0,
            show_preview: true,
            move_modifier: 0,
            resize_modifier: 0,
            preserve_proportions: true,
            cycle_sizes: true,
            excluded_app_ids: Vec::new(),
            restore_on_reconnect: true,
            apply_rules_on_launch: true,
            haptic_on_snap: true,
            stash_sliver: 14.0,
            grid_columns: 6,
            grid_rows: 4,
            todo_app_id: None,
            todo_fraction: 0.25,
            todo_on_right: true,
            drop_zone_modifier: m::SHIFT,
            drop_zone_layout_id: None,
            almost_maximize_margin: 40.0,
            resize_step: 60.0,
            keep_aspect: true,
            ultrawide_max_width: 0.0,
            act_on_pointer_window: false,
            switcher_thumbnails: false,
            switcher_hold_release: true,
            radial_color: "#7B97B9".to_string(),
            radial_size: 104.0,
            apply_rules_on_activate: false,
        }
    }
}

impl WindowConfig {
    pub fn sanitized(mut self) -> Self {
        let fix = |v: f64, lo: f64, hi: f64, fallback: f64| {
            if v.is_finite() {
                v.clamp(lo, hi)
            } else {
                fallback
            }
        };
        self.gap = fix(self.gap, 0.0, 100.0, 0.0);
        self.edge_margin = fix(self.edge_margin, 1.0, 60.0, 6.0);
        self.corner_size = fix(self.corner_size, 10.0, 200.0, 40.0);
        self.stash_sliver = fix(self.stash_sliver, 6.0, 60.0, 14.0);
        self.grid_columns = self.grid_columns.clamp(2, 12);
        self.grid_rows = self.grid_rows.clamp(2, 12);
        self.todo_fraction = fix(self.todo_fraction, 0.10, 0.50, 0.25);
        self.drop_zone_modifier &= m::ALL;
        self.almost_maximize_margin = fix(self.almost_maximize_margin, 0.0, 200.0, 40.0);
        self.resize_step = fix(self.resize_step, 10.0, 400.0, 60.0);
        // 0 turns the limit off; anything else is kept to a sensible width.
        self.ultrawide_max_width =
            if self.ultrawide_max_width.is_finite() && self.ultrawide_max_width >= 400.0 {
                self.ultrawide_max_width.min(10000.0)
            } else {
                0.0
            };
        self.snap_drag_modifier &= m::ALL;
        self.radial_size = if self.radial_size.is_finite() {
            self.radial_size.clamp(70.0, 220.0)
        } else {
            104.0
        };
        let hex = self.radial_color.trim().trim_start_matches('#');
        self.radial_color = if hex.len() == 6 && hex.chars().all(|c| c.is_ascii_hexdigit()) {
            format!("#{}", hex.to_uppercase())
        } else {
            "#7B97B9".to_string()
        };
        self.move_modifier &= m::ALL;
        self.resize_modifier &= m::ALL;
        // The same keys cannot both move and resize.
        if self.move_modifier != 0 && self.move_modifier == self.resize_modifier {
            self.resize_modifier = 0;
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
        app_id.is_some_and(|a| self.excluded_app_ids.iter().any(|x| x == a))
    }
}

// ---- shortcuts -------------------------------------------------------------------------------------------------------

/// Commands that are not layouts but can still have a shortcut.
pub const EXTRA_COMMANDS: [(&str, &str); 31] = [
    ("window.restore", "Undo last move or resize"),
    (
        "window.restore_original",
        "Restore original size and position",
    ),
    ("window.next_display", "Move to next display"),
    ("window.previous_display", "Move to previous display"),
    ("window.switcher", "Open the window switcher"),
    (
        "window.apply_rules",
        "Apply placement rules to open windows",
    ),
    ("window.focus_left", "Focus the window to the left"),
    ("window.focus_right", "Focus the window to the right"),
    ("window.focus_up", "Focus the window above"),
    ("window.focus_down", "Focus the window below"),
    (
        "window.pointer_to_window",
        "Move the pointer to the active window",
    ),
    ("window.stash", "Stash or bring back the active window"),
    ("window.unstash_all", "Bring back every stashed window"),
    ("window.radial", "Open the radial menu"),
    (
        "window.grid",
        "Place the window on a grid with the keyboard",
    ),
    (
        "window.todo_toggle",
        "Keep this app in the todo column, or stop",
    ),
    ("window.todo_focus", "Focus the todo window"),
    ("window.almost_maximize", "Almost maximize, with a margin"),
    ("window.maximize_width", "Maximize width only"),
    ("window.maximize_height", "Maximize height only"),
    ("window.grow", "Make the window bigger"),
    ("window.shrink", "Make the window smaller"),
    ("window.wider", "Make the window wider"),
    ("window.narrower", "Make the window narrower"),
    ("window.taller", "Make the window taller"),
    ("window.shorter", "Make the window shorter"),
    ("window.cascade", "Cascade the windows on this display"),
    ("window.tile", "Tile the windows on this display"),
    ("window.previous", "Switch to the previous window"),
    ("window.next_same_app", "Next window of the same app"),
    ("window.send_behind", "Send this window behind the others"),
];

/// Shortcuts added after the first release, with the version of the shortcut list that introduced each. A person who
/// already has saved shortcuts is offered the ones newer than the version they last had, once, unless a key is taken.
pub const SHORTCUT_LIST_VERSION: u32 = 4;
const ADDED_COMMANDS: [(u32, &str); 11] = [
    (2, "window.focus_left"),
    (2, "window.focus_right"),
    (2, "window.focus_up"),
    (2, "window.focus_down"),
    (2, "window.pointer_to_window"),
    (2, "window.stash"),
    (2, "window.unstash_all"),
    (2, "window.radial"),
    (3, "window.grid"),
    (3, "window.todo_toggle"),
    (3, "window.todo_focus"),
];

pub fn added_default_shortcuts(since_version: u32) -> Vec<ShortcutBinding> {
    default_shortcuts()
        .into_iter()
        .filter(|b| {
            ADDED_COMMANDS
                .iter()
                .any(|(v, c)| *v > since_version && *c == b.command)
        })
        .collect()
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct ShortcutBinding {
    pub command: String,
    pub key_code: u16,
    pub modifiers: u64,
}

/// A command a shortcut may run: a layout, one of the extras, a custom size or a saved layout.
pub fn is_known_window_command(command: &str) -> bool {
    WindowLayout::from_command(command).is_some()
        || EXTRA_COMMANDS.iter().any(|(c, _)| *c == command)
        || command.starts_with(CUSTOM_PREFIX)
        || command.starts_with(LAYOUT_PREFIX)
}

pub const CUSTOM_PREFIX: &str = "window.size.";
pub const LAYOUT_PREFIX: &str = "window.layout.";

pub fn default_shortcuts() -> Vec<ShortcutBinding> {
    use WindowLayout::*;
    let co = m::CONTROL | m::OPTION;
    let cos = co | m::SHIFT;
    let coc = co | m::COMMAND;
    let bind = |command: &str, key_code: u16, modifiers: u64| ShortcutBinding {
        command: command.to_string(),
        key_code,
        modifiers,
    };
    let layout = |l: WindowLayout, key: u16, mods: u64| bind(l.command(), key, mods);
    vec![
        layout(LeftHalf, 123, co),
        layout(RightHalf, 124, co),
        layout(TopHalf, 126, co),
        layout(BottomHalf, 125, co),
        layout(TopLeft, 32, co),
        layout(TopRight, 34, co),
        layout(BottomLeft, 38, co),
        layout(BottomRight, 40, co),
        layout(FirstThird, 2, co),
        layout(CenterThird, 3, co),
        layout(LastThird, 5, co),
        layout(FirstTwoThirds, 14, co),
        layout(LastTwoThirds, 17, co),
        layout(TopLeftSixth, 32, cos),
        layout(TopCenterSixth, 34, cos),
        layout(TopRightSixth, 31, cos),
        layout(BottomLeftSixth, 38, cos),
        layout(BottomCenterSixth, 40, cos),
        layout(BottomRightSixth, 37, cos),
        layout(Maximize, 36, co),
        layout(Center, 8, co),
        bind("window.restore", 51, co),
        bind("window.restore_original", 51, cos),
        bind("window.next_display", 124, coc),
        bind("window.previous_display", 123, coc),
        bind("window.switcher", 48, m::OPTION),
        bind("window.focus_left", 123, cos),
        bind("window.focus_right", 124, cos),
        bind("window.focus_up", 126, cos),
        bind("window.focus_down", 125, cos),
        bind("window.pointer_to_window", 35, co),
        bind("window.stash", 1, co),
        bind("window.unstash_all", 1, cos),
        bind("window.radial", 15, co),
        bind("window.grid", 11, co),
        bind("window.todo_toggle", 16, co),
        bind("window.todo_focus", 16, cos),
    ]
}

/// Why a set of shortcuts cannot be used, or `Ok` when it can.
pub fn check_shortcuts(list: &[ShortcutBinding]) -> Result<(), String> {
    let mut seen: HashMap<(u16, u64), &str> = HashMap::new();
    let mut commands = HashSet::new();
    for b in list {
        if !is_known_window_command(&b.command) {
            return Err(format!("“{}” is not a window command", b.command));
        }
        if b.modifiers & !m::ALL != 0 {
            return Err("a shortcut has unknown modifier keys".into());
        }
        if b.modifiers == 0 {
            return Err(
                "a shortcut needs at least one modifier key, or it would take over normal typing"
                    .into(),
            );
        }
        if !commands.insert(b.command.as_str()) {
            return Err("a command has more than one shortcut".into());
        }
        if let Some(other) = seen.insert((b.key_code, b.modifiers), &b.command) {
            return Err(format!(
                "two commands share a shortcut ({other} and {})",
                b.command
            ));
        }
    }
    Ok(())
}

// ---- saved layouts and placement rules -------------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct LayoutEntry {
    pub app_id: String,
    pub title: String,
    pub display_id: String,
    /// The window's frame as fractions of its display's usable area, so a layout still fits a different resolution.
    pub frame: Rect,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct SavedLayout {
    pub id: String,
    pub name: String,
    /// The display set the layout was made for. Automatic snapshots are kept per display set.
    pub display_key: String,
    pub is_auto: bool,
    pub created_at: i64,
    pub entries: Vec<LayoutEntry>,
}

impl SavedLayout {
    pub fn command(&self) -> String {
        format!("{LAYOUT_PREFIX}{}", self.id.to_lowercase())
    }
}

/// Pairs open windows with a layout's entries. A window takes the entry with the same app and title, otherwise the next
/// unused entry for the same app. Returns, for each window, the index of its entry.
pub fn match_layout_entries(
    entries: &[LayoutEntry],
    windows: &[(String, String)],
) -> Vec<Option<usize>> {
    let mut used = vec![false; entries.len()];
    let mut result = vec![None; windows.len()];
    for (wi, (app, title)) in windows.iter().enumerate() {
        if let Some(ei) = entries
            .iter()
            .enumerate()
            .position(|(i, e)| !used[i] && &e.app_id == app && &e.title == title)
        {
            used[ei] = true;
            result[wi] = Some(ei);
        }
    }
    for (wi, (app, _)) in windows.iter().enumerate() {
        if result[wi].is_some() {
            continue;
        }
        if let Some(ei) = entries
            .iter()
            .enumerate()
            .position(|(i, e)| !used[i] && &e.app_id == app)
        {
            used[ei] = true;
            result[wi] = Some(ei);
        }
    }
    result
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct PlacementRule {
    pub id: String,
    pub app_id: String,
    pub enabled: bool,
    pub layout: Option<WindowLayout>,
    pub custom_size_id: Option<String>,
    /// Put the window on this display. `None` leaves it where it opened.
    pub display_id: Option<String>,
}

/// The first enabled rule for an app.
pub fn rule_for_app<'a>(rules: &'a [PlacementRule], app_id: &str) -> Option<&'a PlacementRule> {
    rules.iter().find(|r| r.enabled && r.app_id == app_id)
}

// ---- the window switcher ---------------------------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SwitcherItem {
    pub id: String,
    pub app_name: String,
    pub title: String,
    /// Higher means used more recently.
    pub last_used: i64,
}

/// Orders windows for the switcher. With no query, most recently used first. With one, windows whose app or title
/// contain the letters in order are kept, best match first, ties broken by recency.
pub fn rank_switcher(items: &[SwitcherItem], query: &str) -> Vec<String> {
    let q: Vec<char> = query
        .to_lowercase()
        .chars()
        .filter(|c| !c.is_whitespace())
        .collect();
    let mut scored: Vec<(i64, i64, &str)> = Vec::new();
    for item in items {
        let score = if q.is_empty() {
            Some(0)
        } else {
            match_score(&q, &item.app_name, &item.title)
        };
        if let Some(s) = score {
            scored.push((s, item.last_used, item.id.as_str()));
        }
    }
    scored.sort_by(|a, b| b.0.cmp(&a.0).then(b.1.cmp(&a.1)).then(a.2.cmp(b.2)));
    scored
        .into_iter()
        .map(|(_, _, id)| id.to_string())
        .collect()
}

fn match_score(query: &[char], app: &str, title: &str) -> Option<i64> {
    let a = subsequence_score(query, &app.to_lowercase()).map(|s| s + 10);
    let t = subsequence_score(query, &title.to_lowercase());
    let both = subsequence_score(
        query,
        &format!("{} {}", app.to_lowercase(), title.to_lowercase()),
    );
    [a, t, both].into_iter().flatten().max()
}

/// Letters must appear in order. Consecutive letters and letters at the start of a word score more.
fn subsequence_score(query: &[char], text: &str) -> Option<i64> {
    let chars: Vec<char> = text.chars().collect();
    let mut score = 0i64;
    let mut pos = 0usize;
    let mut previous: Option<usize> = None;
    for &q in query {
        let found = (pos..chars.len()).find(|&i| chars[i] == q)?;
        score += 10;
        if previous.is_some_and(|p| found == p + 1) {
            score += 15;
        }
        if found == 0 || !chars[found - 1].is_alphanumeric() {
            score += 12;
        }
        score -= i64::try_from(found - previous.map_or(0, |p| p + 1))
            .unwrap_or(0)
            .min(10);
        previous = Some(found);
        pos = found + 1;
    }
    Some(score)
}

// ---- undo history ----------------------------------------------------------------------------------------------------

/// Remembers each window's earlier frames so a move can be undone. The key is whatever the shell uses to tell windows apart.
#[derive(uniffi::Object)]
pub struct FrameHistory {
    frames: Mutex<HashMap<String, Vec<Rect>>>,
}

#[uniffi::export]
impl FrameHistory {
    #[uniffi::constructor]
    pub fn new() -> Self {
        FrameHistory {
            frames: Mutex::new(HashMap::new()),
        }
    }

    /// Notes the frame a window had before it was moved. A repeat of the last frame is ignored.
    pub fn record(&self, key: String, frame: Rect) {
        if !frame.is_valid() {
            return;
        }
        let mut map = self.lock();
        let stack = map.entry(key).or_default();
        if stack.last().is_some_and(|last| last.approx_eq(&frame)) {
            return;
        }
        stack.push(frame);
        if stack.len() > MAX_HISTORY {
            stack.remove(0);
        }
    }

    /// The frame to go back to, if it differs from where the window is now. Each call steps further back.
    pub fn undo(&self, key: String, current: Rect) -> Option<Rect> {
        let mut map = self.lock();
        let stack = map.get_mut(&key)?;
        while let Some(frame) = stack.pop() {
            if !frame.approx_eq(&current) {
                return Some(frame);
            }
        }
        None
    }

    /// The very first frame recorded, for "restore original". Clears the history, since the window is back where it started.
    pub fn original(&self, key: String) -> Option<Rect> {
        let mut map = self.lock();
        let stack = map.remove(&key)?;
        stack.first().copied()
    }

    pub fn forget(&self, key: String) {
        self.lock().remove(&key);
    }

    pub fn count(&self, key: String) -> u32 {
        self.lock().get(&key).map_or(0, |s| s.len() as u32)
    }
}

impl Default for FrameHistory {
    fn default() -> Self {
        Self::new()
    }
}

impl FrameHistory {
    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<String, Vec<Rect>>> {
        self.frames.lock().unwrap_or_else(|e| e.into_inner())
    }
}

// ---- diagnostics -----------------------------------------------------------------------------------------------------

/// How far a window ended up from the frame that was asked for. Apps with minimum sizes or fixed sizes cannot always comply.
pub fn frame_miss(wanted: Rect, actual: Rect) -> f64 {
    (wanted.x - actual.x)
        .abs()
        .max((wanted.y - actual.y).abs())
        .max((wanted.width - actual.width).abs())
        .max((wanted.height - actual.height).abs())
}

#[cfg(test)]
mod tests {
    use super::*;

    const AREA: Rect = Rect {
        x: 0.0,
        y: 25.0,
        width: 1200.0,
        height: 775.0,
    };
    const CURRENT: Rect = Rect {
        x: 100.0,
        y: 100.0,
        width: 400.0,
        height: 300.0,
    };

    #[test]
    fn halves_and_quarters_fill_the_area() {
        let left = layout_frame(WindowLayout::LeftHalf, AREA, CURRENT, 0.0);
        let right = layout_frame(WindowLayout::RightHalf, AREA, CURRENT, 0.0);
        assert_eq!(left, Rect::new(0.0, 25.0, 600.0, 775.0));
        assert_eq!(right.x, 600.0);
        assert_eq!(
            layout_frame(WindowLayout::BottomRight, AREA, CURRENT, 0.0).width,
            600.0
        );
        assert_eq!(
            layout_frame(WindowLayout::Maximize, AREA, CURRENT, 0.0),
            AREA
        );
    }

    #[test]
    fn thirds_and_sixths_tile_without_overlap() {
        let thirds = [
            WindowLayout::FirstThird,
            WindowLayout::CenterThird,
            WindowLayout::LastThird,
        ];
        let frames: Vec<Rect> = thirds
            .iter()
            .map(|l| layout_frame(*l, AREA, CURRENT, 0.0))
            .collect();
        assert_eq!(frames[0].width, 400.0);
        assert_eq!(frames[1].x, 400.0);
        assert_eq!(frames[2].x, 800.0);
        assert_eq!(
            layout_frame(WindowLayout::FirstTwoThirds, AREA, CURRENT, 0.0).width,
            800.0
        );
        let sixth = layout_frame(WindowLayout::BottomCenterSixth, AREA, CURRENT, 0.0);
        assert_eq!((sixth.x, sixth.width), (400.0, 400.0));
        assert!(sixth.y > AREA.y + 300.0);
    }

    #[test]
    fn gap_is_full_at_the_edge_and_half_between_windows() {
        let left = layout_frame(WindowLayout::LeftHalf, AREA, CURRENT, 10.0);
        let right = layout_frame(WindowLayout::RightHalf, AREA, CURRENT, 10.0);
        assert_eq!(left.x, 10.0);
        assert_eq!(
            right.x - left.max_x(),
            10.0,
            "the space between two windows is one full gap"
        );
        assert_eq!(right.max_x(), 1190.0);
    }

    #[test]
    fn a_huge_gap_cannot_collapse_a_window() {
        let f = layout_frame(
            WindowLayout::FirstThird,
            Rect::new(0.0, 0.0, 300.0, 300.0),
            CURRENT,
            100.0,
        );
        assert!(f.width >= MIN_WINDOW_SIZE && f.height >= MIN_WINDOW_SIZE);
    }

    #[test]
    fn center_keeps_the_size() {
        let f = layout_frame(WindowLayout::Center, AREA, CURRENT, 0.0);
        assert_eq!((f.width, f.height), (400.0, 300.0));
        assert_eq!(f.x, 400.0);
        let big = layout_frame(
            WindowLayout::Center,
            AREA,
            Rect::new(0.0, 0.0, 5000.0, 5000.0),
            0.0,
        );
        assert_eq!((big.width, big.height), (1200.0, 775.0));
    }

    #[test]
    fn every_layout_has_a_unique_command_that_parses_back() {
        let commands: HashSet<_> = ALL_LAYOUTS.iter().map(|l| l.command()).collect();
        assert_eq!(commands.len(), ALL_LAYOUTS.len());
        for l in ALL_LAYOUTS {
            assert_eq!(WindowLayout::from_command(l.command()), Some(l));
            assert!(!l.title().is_empty());
        }
    }

    #[test]
    fn custom_sizes_in_fractions_and_points() {
        let size = CustomSize {
            id: "s".into(),
            name: "Reading".into(),
            width: 0.5,
            height: 1.0,
            as_fraction: true,
            centered: true,
            x: 0.0,
            y: 0.0,
        };
        let f = custom_frame(&size, AREA);
        assert_eq!((f.width, f.height, f.x), (600.0, 775.0, 300.0));
        let fixed = CustomSize {
            as_fraction: false,
            width: 5000.0,
            height: 400.0,
            ..size.clone()
        };
        assert_eq!(
            custom_frame(&fixed, AREA).width,
            1200.0,
            "never wider than the display"
        );
        let wild = CustomSize {
            width: f64::NAN,
            ..size
        }
        .sanitized();
        assert_eq!(wild.width, 0.6);
    }

    #[test]
    fn repeated_presses_cycle_the_size() {
        use WindowLayout::*;
        assert_eq!(cycle_layout(LeftHalf, None), LeftHalf);
        assert_eq!(cycle_layout(LeftHalf, Some(LeftHalf)), FirstThird);
        assert_eq!(cycle_layout(LeftHalf, Some(FirstThird)), FirstTwoThirds);
        assert_eq!(cycle_layout(LeftHalf, Some(FirstTwoThirds)), LeftHalf);
        assert_eq!(cycle_layout(LeftHalf, Some(RightHalf)), LeftHalf);
        assert_eq!(cycle_layout(TopHalf, Some(TopHalf)), TopHalf);
    }

    #[test]
    fn edges_and_corners_choose_the_layout() {
        let at = |x, y| snap_zone(Point { x, y }, AREA, 6.0, 40.0);
        assert_eq!(at(2.0, 400.0), Some(WindowLayout::LeftHalf));
        assert_eq!(at(1199.0, 400.0), Some(WindowLayout::RightHalf));
        assert_eq!(at(600.0, 26.0), Some(WindowLayout::Maximize));
        assert_eq!(at(600.0, 799.0), Some(WindowLayout::BottomHalf));
        assert_eq!(at(2.0, 30.0), Some(WindowLayout::TopLeft));
        assert_eq!(at(1199.0, 30.0), Some(WindowLayout::TopRight));
        assert_eq!(at(2.0, 799.0), Some(WindowLayout::BottomLeft));
        assert_eq!(at(1199.0, 799.0), Some(WindowLayout::BottomRight));
        assert_eq!(
            at(20.0, 30.0),
            Some(WindowLayout::TopLeft),
            "near the top and inside the corner zone"
        );
        assert_eq!(at(600.0, 400.0), None);
    }

    #[test]
    fn moving_between_displays_keeps_proportions_or_size() {
        let from = Rect::new(0.0, 0.0, 1000.0, 800.0);
        let to = Rect::new(1000.0, 0.0, 2000.0, 1600.0);
        let left_half = Rect::new(0.0, 0.0, 500.0, 800.0);
        assert_eq!(
            translate_frame(left_half, from, to, true),
            Rect::new(1000.0, 0.0, 1000.0, 1600.0)
        );
        assert_eq!(
            translate_frame(left_half, from, to, false),
            Rect::new(1000.0, 0.0, 500.0, 800.0)
        );
        let small = Rect::new(0.0, 0.0, 400.0, 300.0);
        let tiny_target = Rect::new(2000.0, 0.0, 200.0, 200.0);
        let fit = translate_frame(small, from, tiny_target, false);
        assert!(fit.width <= 200.0 && fit.height <= 200.0, "shrunk to fit");
    }

    #[test]
    fn the_display_with_most_of_the_window_wins() {
        let areas = [
            Rect::new(0.0, 0.0, 1000.0, 800.0),
            Rect::new(1000.0, 0.0, 1000.0, 800.0),
        ];
        assert_eq!(
            display_index_for(Rect::new(900.0, 0.0, 400.0, 300.0), &areas),
            Some(1)
        );
        assert_eq!(
            display_index_for(Rect::new(5000.0, 0.0, 100.0, 100.0), &areas),
            Some(1),
            "off-screen: nearest"
        );
        assert_eq!(display_index_for(CURRENT, &[]), None);
    }

    #[test]
    fn display_set_keys_ignore_order() {
        let a = display_set_key(&["b".into(), "a".into()]);
        assert_eq!(a, display_set_key(&["a".into(), "b".into(), "a".into()]));
        assert_ne!(a, display_set_key(&["a".into()]));
    }

    #[test]
    fn config_is_clamped_and_modifiers_cannot_clash() {
        let c = WindowConfig {
            gap: -5.0,
            edge_margin: 999.0,
            move_modifier: m::OPTION | m::CONTROL,
            resize_modifier: m::OPTION | m::CONTROL,
            excluded_app_ids: vec![" a ".into(), "a".into(), "".into()],
            ..WindowConfig::default()
        }
        .sanitized();
        assert_eq!((c.gap, c.edge_margin), (0.0, 60.0));
        assert_eq!(c.resize_modifier, 0);
        assert_eq!(c.excluded_app_ids, vec!["a".to_string()]);
        assert!(c.is_excluded(Some("a")) && !c.is_excluded(Some("b")) && !c.is_excluded(None));
    }

    #[test]
    fn default_shortcuts_are_valid_and_cover_every_layout() {
        let defaults = default_shortcuts();
        assert_eq!(check_shortcuts(&defaults), Ok(()));
        for l in ALL_LAYOUTS {
            assert!(
                defaults.iter().any(|b| b.command == l.command()),
                "{} has no default shortcut",
                l.command()
            );
        }
    }

    #[test]
    fn bad_shortcuts_are_refused() {
        let one = |c: &str, k, mods| ShortcutBinding {
            command: c.into(),
            key_code: k,
            modifiers: mods,
        };
        assert!(check_shortcuts(&[one("window.nonsense", 1, m::OPTION)]).is_err());
        assert!(check_shortcuts(&[one("window.maximize", 1, 0)]).is_err());
        assert!(check_shortcuts(&[
            one("window.maximize", 1, m::OPTION),
            one("window.center", 1, m::OPTION)
        ])
        .is_err());
        assert!(check_shortcuts(&[
            one("window.maximize", 1, m::OPTION),
            one("window.maximize", 2, m::OPTION)
        ])
        .is_err());
        assert!(check_shortcuts(&[one("window.size.abc", 1, m::OPTION)]).is_ok());
    }

    fn entry(app: &str, title: &str) -> LayoutEntry {
        LayoutEntry {
            app_id: app.into(),
            title: title.into(),
            display_id: "d".into(),
            frame: Rect::new(0.0, 0.0, 0.5, 1.0),
        }
    }

    #[test]
    fn layout_entries_match_by_title_then_by_app() {
        let entries = vec![
            entry("mail", "Inbox"),
            entry("mail", "Drafts"),
            entry("notes", "Todo"),
        ];
        let windows = vec![
            ("mail".to_string(), "Drafts".to_string()),
            ("mail".to_string(), "Something new".to_string()),
            ("chat".to_string(), "Room".to_string()),
        ];
        assert_eq!(
            match_layout_entries(&entries, &windows),
            vec![Some(1), Some(0), None]
        );
    }

    #[test]
    fn rules_apply_only_when_enabled() {
        let rule = |id: &str, app: &str, on: bool| PlacementRule {
            id: id.into(),
            app_id: app.into(),
            enabled: on,
            layout: Some(WindowLayout::LeftHalf),
            custom_size_id: None,
            display_id: None,
        };
        let rules = vec![
            rule("1", "a", false),
            rule("2", "a", true),
            rule("3", "b", true),
        ];
        assert_eq!(rule_for_app(&rules, "a").map(|r| r.id.as_str()), Some("2"));
        assert!(rule_for_app(&rules, "c").is_none());
    }

    fn item(id: &str, app: &str, title: &str, used: i64) -> SwitcherItem {
        SwitcherItem {
            id: id.into(),
            app_name: app.into(),
            title: title.into(),
            last_used: used,
        }
    }

    #[test]
    fn switcher_lists_recent_windows_first_and_searches_by_letters() {
        let items = vec![
            item("1", "Safari", "Apple", 1),
            item("2", "Xcode", "Kriya.xcodeproj", 5),
            item("3", "Terminal", "zsh", 3),
        ];
        assert_eq!(rank_switcher(&items, ""), vec!["2", "3", "1"]);
        assert_eq!(rank_switcher(&items, "xc"), vec!["2"]);
        assert_eq!(rank_switcher(&items, "ter"), vec!["3"]);
        assert_eq!(rank_switcher(&items, "kri"), vec!["2"]);
        assert!(rank_switcher(&items, "qqq").is_empty());
    }

    #[test]
    fn a_tighter_match_beats_a_scattered_one() {
        let items = vec![
            item("a", "Notes", "Shopping list", 9),
            item("b", "Safari", "Reading", 1),
        ];
        assert_eq!(
            rank_switcher(&items, "read").first().map(String::as_str),
            Some("b")
        );
    }

    #[test]
    fn history_undoes_step_by_step_and_restores_the_original() {
        let h = FrameHistory::new();
        let a = Rect::new(0.0, 0.0, 400.0, 300.0);
        let b = Rect::new(0.0, 0.0, 600.0, 775.0);
        let c = Rect::new(600.0, 0.0, 600.0, 775.0);
        h.record("w".into(), a);
        h.record("w".into(), b);
        assert_eq!(h.undo("w".into(), c), Some(b));
        assert_eq!(h.undo("w".into(), b), Some(a));
        assert_eq!(h.undo("w".into(), a), None);

        h.record("x".into(), a);
        h.record("x".into(), b);
        assert_eq!(h.original("x".into()), Some(a));
        assert_eq!(h.count("x".into()), 0);
    }

    #[test]
    fn history_ignores_repeats_invalid_frames_and_stays_bounded() {
        let h = FrameHistory::new();
        h.record("w".into(), Rect::new(0.0, 0.0, 10.0, 10.0));
        h.record("w".into(), Rect::new(0.0, 0.0, 10.0, 10.0));
        h.record("w".into(), Rect::new(f64::NAN, 0.0, 10.0, 10.0));
        assert_eq!(h.count("w".into()), 1);
        for i in 0..100 {
            h.record(
                "w".into(),
                Rect::new(f64::from(i) * 10.0, 0.0, 300.0, 300.0),
            );
        }
        assert_eq!(h.count("w".into()) as usize, MAX_HISTORY);
    }

    #[test]
    fn misses_are_measured_in_points() {
        assert_eq!(
            frame_miss(
                Rect::new(0.0, 0.0, 600.0, 700.0),
                Rect::new(0.0, 0.0, 640.0, 700.0)
            ),
            40.0
        );
    }
}
