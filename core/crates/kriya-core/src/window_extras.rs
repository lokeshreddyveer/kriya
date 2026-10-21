//! Window features beyond snapping: moving focus by direction, parking a window at the screen edge, and the radial
//! menu's sectors. All plain geometry; the app supplies the windows and does the moving.

use serde::{Deserialize, Serialize};

use crate::windows::{Point, Rect, WindowLayout};

// ---- focus by direction ----------------------------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
pub enum Direction {
    Left,
    Right,
    Up,
    Down,
}

impl Direction {
    pub fn command(self) -> &'static str {
        match self {
            Direction::Left => "window.focus_left",
            Direction::Right => "window.focus_right",
            Direction::Up => "window.focus_up",
            Direction::Down => "window.focus_down",
        }
    }

    pub fn from_command(command: &str) -> Option<Direction> {
        [
            Direction::Left,
            Direction::Right,
            Direction::Up,
            Direction::Down,
        ]
        .into_iter()
        .find(|d| d.command() == command)
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct FocusCandidate {
    pub id: String,
    pub frame: Rect,
}

/// Which window to focus when moving `direction` from `from`. Windows that lie in that direction are ranked by how far
/// away they are and how far off to the side; one that overlaps the current window along the other axis wins over one
/// that only lies roughly that way. `None` when nothing lies that way.
pub fn focus_target(
    from: Rect,
    candidates: &[FocusCandidate],
    direction: Direction,
) -> Option<String> {
    let (fx, fy) = center(&from);
    candidates
        .iter()
        .filter(|c| c.frame.is_valid())
        .filter_map(|c| {
            let (cx, cy) = center(&c.frame);
            // `along` is how far the centre is in the wanted direction; `across` is the sideways gap between the two
            // windows' extents (zero when they overlap) plus how far off-centre the target is.
            let (along, across) = match direction {
                Direction::Right => (
                    cx - fx,
                    interval_gap(from.y, from.max_y(), c.frame.y, c.frame.max_y())
                        + (cy - fy).abs() * 0.25,
                ),
                Direction::Left => (
                    fx - cx,
                    interval_gap(from.y, from.max_y(), c.frame.y, c.frame.max_y())
                        + (cy - fy).abs() * 0.25,
                ),
                Direction::Down => (
                    cy - fy,
                    interval_gap(from.x, from.max_x(), c.frame.x, c.frame.max_x())
                        + (cx - fx).abs() * 0.25,
                ),
                Direction::Up => (
                    fy - cy,
                    interval_gap(from.x, from.max_x(), c.frame.x, c.frame.max_x())
                        + (cx - fx).abs() * 0.25,
                ),
            };
            // Only windows within a cone around the wanted direction count; one far off to the side is not "below".
            let sideways = match direction {
                Direction::Left | Direction::Right => (cy - fy).abs(),
                Direction::Up | Direction::Down => (cx - fx).abs(),
            };
            if along <= 1.0 || along < sideways * 0.5 {
                return None;
            }
            Some((c.id.clone(), along + across * 2.0))
        })
        .min_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal))
        .map(|(id, _)| id)
}

fn center(r: &Rect) -> (f64, f64) {
    (r.x + r.width / 2.0, r.y + r.height / 2.0)
}

/// The gap between two ranges on a line; zero when they overlap.
fn interval_gap(a_start: f64, a_end: f64, b_start: f64, b_end: f64) -> f64 {
    (b_start - a_end).max(a_start - b_end).max(0.0)
}

// ---- stash -------------------------------------------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
pub enum StashEdge {
    Left,
    Right,
}

/// Which side a window is closer to, so stashing tucks it away the shorter way.
pub fn nearest_stash_edge(frame: Rect, area: Rect) -> StashEdge {
    let (cx, _) = center(&frame);
    if cx < area.x + area.width / 2.0 {
        StashEdge::Left
    } else {
        StashEdge::Right
    }
}

/// Where a window sits when stashed: pushed past the edge, leaving `sliver` points visible to bring it back with.
/// The window keeps its size and its height on screen.
pub fn stash_frame(frame: Rect, area: Rect, edge: StashEdge, sliver: f64) -> Rect {
    let sliver = if sliver.is_finite() {
        sliver.clamp(6.0, 60.0)
    } else {
        14.0
    };
    let y = frame
        .y
        .max(area.y)
        .min((area.max_y() - frame.height).max(area.y));
    let x = match edge {
        StashEdge::Left => area.x - frame.width + sliver,
        StashEdge::Right => area.max_x() - sliver,
    };
    Rect::new(x, y, frame.width, frame.height)
}

/// Whether the pointer is over the visible sliver of a stashed window, with a little slack for a quick flick.
pub fn stash_hit(pointer: Point, stashed: Rect, area: Rect, edge: StashEdge) -> bool {
    let slack = 6.0;
    let visible = match edge {
        StashEdge::Left => Rect::new(
            area.x,
            stashed.y,
            (stashed.max_x() - area.x).max(0.0) + slack,
            stashed.height,
        ),
        StashEdge::Right => {
            let left = stashed.x - slack;
            Rect::new(
                left,
                stashed.y,
                (area.max_x() - left).max(0.0),
                stashed.height,
            )
        }
    };
    visible.contains(pointer)
}

/// The frame a window returns to when brought back from the stash: fully on screen, hugging the edge it hid behind.
pub fn unstash_frame(stashed: Rect, area: Rect, edge: StashEdge) -> Rect {
    let x = match edge {
        StashEdge::Left => area.x,
        StashEdge::Right => area.max_x() - stashed.width,
    };
    Rect::new(x, stashed.y, stashed.width, stashed.height)
}

// ---- radial menu -------------------------------------------------------------------------------------------------------

/// The layout for a pointer offset from the radial menu's centre. `dx` and `dy` are in screen points with y growing
/// downward. Inside `dead_zone` the window is maximized; outside it the eight compass sectors give halves and quarters.
pub fn radial_layout(dx: f64, dy: f64, dead_zone: f64) -> WindowLayout {
    if !dx.is_finite() || !dy.is_finite() || dx.hypot(dy) <= dead_zone.max(0.0) {
        return WindowLayout::Maximize;
    }
    // 0° points right and angles grow clockwise on screen, because y grows downward.
    let degrees = dy.atan2(dx).to_degrees().rem_euclid(360.0);
    let sector = (((degrees + 22.5) / 45.0).floor() as i64).rem_euclid(8);
    match sector {
        0 => WindowLayout::RightHalf,
        1 => WindowLayout::BottomRight,
        2 => WindowLayout::BottomHalf,
        3 => WindowLayout::BottomLeft,
        4 => WindowLayout::LeftHalf,
        5 => WindowLayout::TopLeft,
        6 => WindowLayout::TopHalf,
        _ => WindowLayout::TopRight,
    }
}

// ---- keyboard grid -----------------------------------------------------------------------------------------------------

/// A block of grid cells, from one corner to the other (column, row).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct GridBlock {
    pub from_column: u32,
    pub from_row: u32,
    pub to_column: u32,
    pub to_row: u32,
}

/// The frame covering the grid cells from `from` to `to` (column, row; either corner first) inside `area`. The grid
/// is clamped to 2 to 12 columns and rows, and `gap` is left at the screen's edge and half of it between neighbours,
/// the same as for the other layouts.
pub fn grid_frame(
    area: Rect,
    columns: u32,
    rows: u32,
    from: (u32, u32),
    to: (u32, u32),
    gap: f64,
) -> Rect {
    let columns = columns.clamp(2, 12);
    let rows = rows.clamp(2, 12);
    let gap = if gap.is_finite() {
        gap.clamp(0.0, 100.0)
    } else {
        0.0
    };
    let (c0, c1) = (
        from.0.min(to.0).min(columns - 1),
        from.0.max(to.0).min(columns - 1),
    );
    let (r0, r1) = (
        from.1.min(to.1).min(rows - 1),
        from.1.max(to.1).min(rows - 1),
    );
    let (cw, rh) = (
        area.width / f64::from(columns),
        area.height / f64::from(rows),
    );
    let mut left = area.x + f64::from(c0) * cw;
    let mut top = area.y + f64::from(r0) * rh;
    let mut right = area.x + f64::from(c1 + 1) * cw;
    let mut bottom = area.y + f64::from(r1 + 1) * rh;
    left += if c0 == 0 { gap } else { gap / 2.0 };
    top += if r0 == 0 { gap } else { gap / 2.0 };
    right -= if c1 + 1 == columns { gap } else { gap / 2.0 };
    bottom -= if r1 + 1 == rows { gap } else { gap / 2.0 };
    Rect::new(
        left.round(),
        top.round(),
        (right - left).max(40.0).round(),
        (bottom - top).max(40.0).round(),
    )
}

/// Moves a grid cell one step, stopping at the edges.
pub fn grid_step(cell: (u32, u32), direction: Direction, columns: u32, rows: u32) -> (u32, u32) {
    let (columns, rows) = (columns.clamp(2, 12), rows.clamp(2, 12));
    let (c, r) = (cell.0.min(columns - 1), cell.1.min(rows - 1));
    match direction {
        Direction::Left => (c.saturating_sub(1), r),
        Direction::Right => ((c + 1).min(columns - 1), r),
        Direction::Up => (c, r.saturating_sub(1)),
        Direction::Down => (c, (r + 1).min(rows - 1)),
    }
}

// ---- todo mode ---------------------------------------------------------------------------------------------------------

/// Splits a display's usable area into a narrow column for the todo window and the rest for everything else. The
/// fraction is the todo window's share of the width, kept between 10% and 50%.
pub fn todo_split(area: Rect, fraction: f64, on_right: bool) -> (Rect, Rect) {
    let fraction = if fraction.is_finite() {
        fraction.clamp(0.10, 0.50)
    } else {
        0.25
    };
    let width = (area.width * fraction).round();
    if on_right {
        (
            Rect::new(area.max_x() - width, area.y, width, area.height),
            Rect::new(area.x, area.y, area.width - width, area.height),
        )
    } else {
        (
            Rect::new(area.x, area.y, width, area.height),
            Rect::new(area.x + width, area.y, area.width - width, area.height),
        )
    }
}

// ---- drop zones --------------------------------------------------------------------------------------------------------

/// The zone a pointer is over while dragging a window, from zones given as fractions of the display's usable area. When
/// zones overlap the smallest one wins, so a small zone inside a large one can still be reached.
pub fn drop_zone_at(point: Point, area: Rect, zones: &[Rect]) -> Option<usize> {
    zones
        .iter()
        .enumerate()
        .filter(|(_, z)| z.is_valid())
        .map(|(i, z)| (i, zone_frame(area, *z)))
        .filter(|(_, frame)| frame.contains(point))
        .min_by(|a, b| {
            (a.1.width * a.1.height)
                .partial_cmp(&(b.1.width * b.1.height))
                .unwrap_or(std::cmp::Ordering::Equal)
        })
        .map(|(i, _)| i)
}

/// A zone given as fractions of `area`, as a frame in points.
pub fn zone_frame(area: Rect, zone: Rect) -> Rect {
    Rect::new(
        (area.x + zone.x * area.width).round(),
        (area.y + zone.y * area.height).round(),
        (zone.width * area.width).round().max(40.0),
        (zone.height * area.height).round().max(40.0),
    )
}

// ---- resizing ----------------------------------------------------------------------------------------------------------

const MIN_SIZE: f64 = 120.0;

/// A display's usable area with a margin all round: "almost maximize".
pub fn inset_frame(area: Rect, margin: f64) -> Rect {
    let margin = if margin.is_finite() {
        margin.clamp(0.0, 200.0)
    } else {
        0.0
    };
    let margin = margin.min(area.width / 4.0).min(area.height / 4.0);
    Rect::new(
        (area.x + margin).round(),
        (area.y + margin).round(),
        (area.width - 2.0 * margin).round(),
        (area.height - 2.0 * margin).round(),
    )
}

/// Fills the area across one direction and leaves the other alone: full width, or full height.
pub fn maximize_axis(frame: Rect, area: Rect, horizontal: bool) -> Rect {
    if horizontal {
        Rect::new(area.x, frame.y, area.width, frame.height)
    } else {
        Rect::new(frame.x, area.y, frame.width, area.height)
    }
}

/// Whether a display is wide enough that a maximized window is uncomfortable to read.
pub fn is_ultrawide(area: Rect) -> bool {
    area.height > 0.0 && area.width / area.height >= 2.0
}

/// Narrows a window to `max_width`, centred in the area. Does nothing when the limit is off (0), the window is already
/// narrower, or the display is not ultrawide.
pub fn limit_width(frame: Rect, area: Rect, max_width: f64) -> Rect {
    if !max_width.is_finite()
        || max_width < 400.0
        || frame.width <= max_width
        || !is_ultrawide(area)
    {
        return frame;
    }
    Rect::new(
        (area.x + (area.width - max_width) / 2.0).round(),
        frame.y,
        max_width.round(),
        frame.height,
    )
}

/// Grows or shrinks a window by `dw` and `dh` points around its centre, kept inside the area and no smaller than a
/// usable size. With `keep_aspect` and a change in both directions, the height follows the width so the shape holds.
pub fn resize_by(frame: Rect, area: Rect, dw: f64, dh: f64, keep_aspect: bool) -> Rect {
    if !(dw.is_finite() && dh.is_finite()) || frame.width <= 0.0 || frame.height <= 0.0 {
        return frame;
    }
    let mut width = (frame.width + dw).clamp(MIN_SIZE.min(area.width), area.width);
    let mut height = (frame.height + dh).clamp(MIN_SIZE.min(area.height), area.height);
    if keep_aspect && dw != 0.0 && dh != 0.0 {
        let scale = width / frame.width;
        height = (frame.height * scale).clamp(MIN_SIZE.min(area.height), area.height);
        // The height hit a limit: bring the width back to the same shape.
        width = (height / frame.height * frame.width).clamp(MIN_SIZE.min(area.width), area.width);
    }
    let cx = frame.x + frame.width / 2.0;
    let cy = frame.y + frame.height / 2.0;
    let x = (cx - width / 2.0).clamp(area.x, (area.max_x() - width).max(area.x));
    let y = (cy - height / 2.0).clamp(area.y, (area.max_y() - height).max(area.y));
    Rect::new(x.round(), y.round(), width.round(), height.round())
}

// ---- arranging many windows ----------------------------------------------------------------------------------------------

/// Frames for `count` windows stacked in a cascade, each offset from the last, all the same size. The step shrinks so
/// the whole cascade stays inside the area.
pub fn cascade_frames(area: Rect, count: usize, offset: f64) -> Vec<Rect> {
    if count == 0 {
        return Vec::new();
    }
    let offset = if offset.is_finite() {
        offset.clamp(10.0, 100.0)
    } else {
        30.0
    };
    let width = (area.width * 0.7).round();
    let height = (area.height * 0.7).round();
    let steps = (count - 1).max(1) as f64;
    let step_x = offset.min((area.width - width) / steps);
    let step_y = offset.min((area.height - height) / steps);
    (0..count)
        .map(|i| {
            let i = i as f64;
            Rect::new(
                (area.x + step_x * i).round(),
                (area.y + step_y * i).round(),
                width,
                height,
            )
        })
        .collect()
}

/// Frames for `count` windows tiled to fill the area: rows and columns as square as possible, the last row stretched to
/// fill its width. `gap` is left between windows and at the edges.
pub fn tile_frames(area: Rect, count: usize, gap: f64) -> Vec<Rect> {
    if count == 0 {
        return Vec::new();
    }
    let gap = if gap.is_finite() {
        gap.clamp(0.0, 100.0)
    } else {
        0.0
    };
    let inner = area;
    let columns = (count as f64).sqrt().ceil() as usize;
    let rows = count.div_ceil(columns);
    let row_height = inner.height / rows as f64;
    (0..count)
        .map(|i| {
            let (row, column) = (i / columns, i % columns);
            let in_row = if row == rows - 1 {
                count - columns * (rows - 1)
            } else {
                columns
            };
            let cell_width = inner.width / in_row as f64;
            Rect::new(
                (inner.x + cell_width * column as f64 + gap / 2.0).round(),
                (inner.y + row_height * row as f64 + gap / 2.0).round(),
                (cell_width - gap).round().max(40.0),
                (row_height - gap).round().max(40.0),
            )
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cand(id: &str, x: f64, y: f64, w: f64, h: f64) -> FocusCandidate {
        FocusCandidate {
            id: id.into(),
            frame: Rect::new(x, y, w, h),
        }
    }

    #[test]
    fn focus_goes_to_the_nearest_window_in_the_direction() {
        let from = Rect::new(500.0, 300.0, 400.0, 300.0);
        let list = vec![
            cand("left-near", 50.0, 300.0, 400.0, 300.0),
            cand("left-far", -600.0, 300.0, 400.0, 300.0),
            cand("right", 1000.0, 320.0, 400.0, 300.0),
            cand("above", 500.0, -100.0, 400.0, 300.0),
        ];
        assert_eq!(
            focus_target(from, &list, Direction::Left).as_deref(),
            Some("left-near")
        );
        assert_eq!(
            focus_target(from, &list, Direction::Right).as_deref(),
            Some("right")
        );
        assert_eq!(
            focus_target(from, &list, Direction::Up).as_deref(),
            Some("above")
        );
        assert_eq!(
            focus_target(from, &list, Direction::Down),
            None,
            "nothing lies below"
        );
    }

    #[test]
    fn focus_prefers_a_window_that_lines_up_over_one_that_is_closer_but_off_to_the_side() {
        let from = Rect::new(0.0, 0.0, 400.0, 300.0);
        let list = vec![
            cand("lined-up", 700.0, 0.0, 400.0, 300.0),
            cand("closer-but-lower", 450.0, 900.0, 400.0, 300.0),
        ];
        assert_eq!(
            focus_target(from, &list, Direction::Right).as_deref(),
            Some("lined-up")
        );
    }

    #[test]
    fn focus_ignores_unusable_frames_and_an_empty_list() {
        let from = Rect::new(0.0, 0.0, 100.0, 100.0);
        assert_eq!(focus_target(from, &[], Direction::Right), None);
        let bad = vec![
            cand("nan", f64::NAN, 0.0, 100.0, 100.0),
            cand("flat", 500.0, 0.0, 0.0, 0.0),
        ];
        assert_eq!(focus_target(from, &bad, Direction::Right), None);
    }

    #[test]
    fn direction_commands_round_trip() {
        for d in [
            Direction::Left,
            Direction::Right,
            Direction::Up,
            Direction::Down,
        ] {
            assert_eq!(Direction::from_command(d.command()), Some(d));
        }
        assert_eq!(Direction::from_command("window.focus_sideways"), None);
    }

    #[test]
    fn stash_tucks_a_window_to_the_nearer_edge_leaving_a_sliver() {
        let area = Rect::new(0.0, 25.0, 1440.0, 875.0);
        let left = Rect::new(100.0, 200.0, 600.0, 400.0);
        let right = Rect::new(900.0, 200.0, 400.0, 400.0);
        assert_eq!(nearest_stash_edge(left, area), StashEdge::Left);
        assert_eq!(nearest_stash_edge(right, area), StashEdge::Right);

        let hidden = stash_frame(left, area, StashEdge::Left, 14.0);
        assert_eq!(hidden.x, -586.0);
        assert_eq!((hidden.width, hidden.height), (600.0, 400.0));
        assert_eq!(hidden.max_x(), 14.0, "only the sliver shows");

        let hidden_right = stash_frame(right, area, StashEdge::Right, 14.0);
        assert_eq!(hidden_right.x, 1426.0);
    }

    #[test]
    fn stash_keeps_the_window_inside_the_screen_vertically_and_clamps_the_sliver() {
        let area = Rect::new(0.0, 25.0, 1440.0, 875.0);
        let tall = Rect::new(100.0, -50.0, 300.0, 400.0);
        assert_eq!(stash_frame(tall, area, StashEdge::Left, 14.0).y, 25.0);
        let low = Rect::new(100.0, 800.0, 300.0, 400.0);
        assert_eq!(stash_frame(low, area, StashEdge::Left, 14.0).y, 500.0);
        assert_eq!(stash_frame(tall, area, StashEdge::Left, 0.0).max_x(), 6.0);
        assert_eq!(
            stash_frame(tall, area, StashEdge::Left, f64::NAN).max_x(),
            14.0
        );
    }

    #[test]
    fn hovering_the_sliver_brings_a_stashed_window_back() {
        let area = Rect::new(0.0, 0.0, 1440.0, 900.0);
        let stashed = stash_frame(
            Rect::new(100.0, 100.0, 600.0, 400.0),
            area,
            StashEdge::Left,
            14.0,
        );
        assert!(stash_hit(
            Point { x: 5.0, y: 300.0 },
            stashed,
            area,
            StashEdge::Left
        ));
        assert!(!stash_hit(
            Point { x: 200.0, y: 300.0 },
            stashed,
            area,
            StashEdge::Left
        ));
        assert!(
            !stash_hit(Point { x: 5.0, y: 700.0 }, stashed, area, StashEdge::Left),
            "below the window"
        );
        let right = stash_frame(
            Rect::new(900.0, 100.0, 400.0, 400.0),
            area,
            StashEdge::Right,
            14.0,
        );
        assert!(stash_hit(
            Point {
                x: 1435.0,
                y: 200.0
            },
            right,
            area,
            StashEdge::Right
        ));
        assert!(!stash_hit(
            Point {
                x: 1000.0,
                y: 200.0
            },
            right,
            area,
            StashEdge::Right
        ));
    }

    #[test]
    fn unstash_puts_the_window_fully_on_screen_at_its_edge() {
        let area = Rect::new(0.0, 0.0, 1440.0, 900.0);
        let left = stash_frame(
            Rect::new(100.0, 100.0, 600.0, 400.0),
            area,
            StashEdge::Left,
            14.0,
        );
        assert_eq!(unstash_frame(left, area, StashEdge::Left).x, 0.0);
        let right = stash_frame(
            Rect::new(900.0, 100.0, 400.0, 400.0),
            area,
            StashEdge::Right,
            14.0,
        );
        assert_eq!(unstash_frame(right, area, StashEdge::Right).x, 1040.0);
    }

    #[test]
    fn radial_sectors_follow_the_compass() {
        use WindowLayout::*;
        let r = |dx: f64, dy: f64| radial_layout(dx, dy, 20.0);
        assert_eq!(r(100.0, 0.0), RightHalf);
        assert_eq!(r(70.0, 70.0), BottomRight);
        assert_eq!(r(0.0, 100.0), BottomHalf);
        assert_eq!(r(-70.0, 70.0), BottomLeft);
        assert_eq!(r(-100.0, 0.0), LeftHalf);
        assert_eq!(r(-70.0, -70.0), TopLeft);
        assert_eq!(r(0.0, -100.0), TopHalf);
        assert_eq!(r(70.0, -70.0), TopRight);
    }

    #[test]
    fn radial_centre_maximizes_and_bad_input_is_safe() {
        assert_eq!(radial_layout(5.0, 5.0, 20.0), WindowLayout::Maximize);
        assert_eq!(radial_layout(0.0, 0.0, 0.0), WindowLayout::Maximize);
        assert_eq!(radial_layout(f64::NAN, 10.0, 20.0), WindowLayout::Maximize);
        // Just either side of a sector boundary at 22.5 degrees.
        assert_eq!(radial_layout(100.0, 40.0, 20.0), WindowLayout::RightHalf);
        assert_eq!(radial_layout(100.0, 42.0, 20.0), WindowLayout::BottomRight);
    }

    #[test]
    fn grid_cells_make_frames_with_gaps_at_the_edges_and_between_neighbours() {
        let area = Rect::new(0.0, 0.0, 1200.0, 800.0);
        // A 6 by 4 grid: one cell is 200 by 200.
        assert_eq!(
            grid_frame(area, 6, 4, (0, 0), (0, 0), 0.0),
            Rect::new(0.0, 0.0, 200.0, 200.0)
        );
        assert_eq!(
            grid_frame(area, 6, 4, (2, 1), (3, 2), 0.0),
            Rect::new(400.0, 200.0, 400.0, 400.0)
        );
        // Either corner first.
        assert_eq!(
            grid_frame(area, 6, 4, (3, 2), (2, 1), 0.0),
            Rect::new(400.0, 200.0, 400.0, 400.0)
        );
        // The whole grid fills the area; with a gap the edges keep the full gap.
        assert_eq!(
            grid_frame(area, 6, 4, (0, 0), (5, 3), 10.0),
            Rect::new(10.0, 10.0, 1180.0, 780.0)
        );
        // A middle cell has half a gap on every side.
        assert_eq!(
            grid_frame(area, 6, 4, (2, 1), (2, 1), 10.0),
            Rect::new(405.0, 205.0, 190.0, 190.0)
        );
    }

    #[test]
    fn grid_input_is_clamped_and_steps_stop_at_the_edges() {
        let area = Rect::new(0.0, 0.0, 1000.0, 1000.0);
        assert_eq!(
            grid_frame(area, 99, 99, (0, 0), (0, 0), 0.0).width,
            (1000.0f64 / 12.0).round()
        );
        assert_eq!(
            grid_frame(area, 0, 0, (0, 0), (9, 9), 0.0),
            Rect::new(0.0, 0.0, 1000.0, 1000.0)
        );
        assert_eq!(
            grid_frame(area, 6, 4, (0, 0), (0, 0), f64::NAN),
            Rect::new(0.0, 0.0, 167.0, 250.0)
        );
        assert_eq!(grid_step((0, 0), Direction::Left, 6, 4), (0, 0));
        assert_eq!(grid_step((5, 3), Direction::Right, 6, 4), (5, 3));
        assert_eq!(grid_step((2, 2), Direction::Up, 6, 4), (2, 1));
        assert_eq!(grid_step((2, 3), Direction::Down, 6, 4), (2, 3));
        assert_eq!(
            grid_step((9, 9), Direction::Left, 6, 4),
            (4, 3),
            "an out-of-range cell is pulled in first"
        );
    }

    #[test]
    fn todo_split_gives_the_todo_window_a_column_and_everyone_else_the_rest() {
        let area = Rect::new(0.0, 25.0, 1440.0, 875.0);
        let (todo, rest) = todo_split(area, 0.25, true);
        assert_eq!(todo, Rect::new(1080.0, 25.0, 360.0, 875.0));
        assert_eq!(rest, Rect::new(0.0, 25.0, 1080.0, 875.0));
        let (todo, rest) = todo_split(area, 0.25, false);
        assert_eq!(todo, Rect::new(0.0, 25.0, 360.0, 875.0));
        assert_eq!(rest, Rect::new(360.0, 25.0, 1080.0, 875.0));
        // Too thin or too wide is pulled into range; nonsense falls back to a quarter.
        assert_eq!(todo_split(area, 0.01, true).0.width, 144.0);
        assert_eq!(todo_split(area, 0.9, true).0.width, 720.0);
        assert_eq!(todo_split(area, f64::NAN, true).0.width, 360.0);
    }

    #[test]
    fn the_smallest_drop_zone_under_the_pointer_wins() {
        let area = Rect::new(0.0, 0.0, 1000.0, 800.0);
        let zones = vec![
            Rect::new(0.0, 0.0, 0.5, 1.0),   // left half
            Rect::new(0.5, 0.0, 0.5, 1.0),   // right half
            Rect::new(0.0, 0.0, 0.25, 0.25), // a small zone inside the left half
        ];
        assert_eq!(
            drop_zone_at(Point { x: 100.0, y: 100.0 }, area, &zones),
            Some(2)
        );
        assert_eq!(
            drop_zone_at(Point { x: 100.0, y: 500.0 }, area, &zones),
            Some(0)
        );
        assert_eq!(
            drop_zone_at(Point { x: 900.0, y: 700.0 }, area, &zones),
            Some(1)
        );
        assert_eq!(drop_zone_at(Point { x: 100.0, y: 100.0 }, area, &[]), None);
        let bad = vec![
            Rect::new(f64::NAN, 0.0, 0.5, 0.5),
            Rect::new(0.0, 0.0, 0.0, 0.0),
        ];
        assert_eq!(drop_zone_at(Point { x: 10.0, y: 10.0 }, area, &bad), None);
        assert_eq!(
            zone_frame(area, Rect::new(0.25, 0.5, 0.5, 0.25)),
            Rect::new(250.0, 400.0, 500.0, 200.0)
        );
    }

    #[test]
    fn almost_maximize_leaves_a_margin_and_axis_maximize_fills_one_direction() {
        let area = Rect::new(0.0, 25.0, 1440.0, 875.0);
        assert_eq!(
            inset_frame(area, 40.0),
            Rect::new(40.0, 65.0, 1360.0, 795.0)
        );
        assert_eq!(inset_frame(area, f64::NAN), area);
        assert_eq!(
            inset_frame(area, 9999.0).width,
            1040.0,
            "never more than 200 from each side"
        );
        assert_eq!(
            inset_frame(Rect::new(0.0, 0.0, 400.0, 400.0), 9999.0).width,
            200.0,
            "nor more than a quarter"
        );
        let frame = Rect::new(300.0, 200.0, 600.0, 400.0);
        assert_eq!(
            maximize_axis(frame, area, true),
            Rect::new(0.0, 200.0, 1440.0, 400.0)
        );
        assert_eq!(
            maximize_axis(frame, area, false),
            Rect::new(300.0, 25.0, 600.0, 875.0)
        );
    }

    #[test]
    fn ultrawide_displays_can_limit_how_wide_a_window_gets() {
        let wide = Rect::new(0.0, 0.0, 3440.0, 1440.0);
        let normal = Rect::new(0.0, 0.0, 1920.0, 1080.0);
        assert!(is_ultrawide(wide));
        assert!(!is_ultrawide(normal));
        let full = Rect::new(0.0, 0.0, 3440.0, 1440.0);
        assert_eq!(
            limit_width(full, wide, 2000.0),
            Rect::new(720.0, 0.0, 2000.0, 1440.0)
        );
        assert_eq!(limit_width(full, wide, 0.0), full, "0 turns it off");
        assert_eq!(
            limit_width(Rect::new(0.0, 0.0, 1500.0, 1000.0), wide, 2000.0).width,
            1500.0,
            "already narrow enough"
        );
        let on_normal = Rect::new(0.0, 0.0, 1920.0, 1080.0);
        assert_eq!(
            limit_width(on_normal, normal, 1000.0),
            on_normal,
            "only ultrawide displays"
        );
    }

    #[test]
    fn growing_and_shrinking_keep_the_centre_and_stay_inside_the_area() {
        let area = Rect::new(0.0, 0.0, 1440.0, 900.0);
        let frame = Rect::new(400.0, 300.0, 600.0, 300.0);
        // Wider only.
        assert_eq!(
            resize_by(frame, area, 100.0, 0.0, true),
            Rect::new(350.0, 300.0, 700.0, 300.0)
        );
        // Both ways with the shape kept: 600x300 grows by a sixth to 700x350.
        let grown = resize_by(frame, area, 100.0, 100.0, true);
        assert_eq!((grown.width, grown.height), (700.0, 350.0));
        // Without keeping the shape, each side takes its own change.
        let free = resize_by(frame, area, 100.0, 100.0, false);
        assert_eq!((free.width, free.height), (700.0, 400.0));
        // Shrinking stops at a usable size, and the result never leaves the area.
        let small = resize_by(frame, area, -5000.0, -5000.0, false);
        assert_eq!((small.width, small.height), (120.0, 120.0));
        let big = resize_by(
            Rect::new(1200.0, 700.0, 200.0, 150.0),
            area,
            5000.0,
            5000.0,
            false,
        );
        assert_eq!(big, Rect::new(0.0, 0.0, 1440.0, 900.0));
        let near_edge = resize_by(
            Rect::new(1300.0, 100.0, 140.0, 140.0),
            area,
            200.0,
            0.0,
            false,
        );
        assert!(near_edge.max_x() <= 1440.0 && near_edge.x >= 0.0);
        assert_eq!(resize_by(frame, area, f64::NAN, 0.0, true), frame);
    }

    #[test]
    fn cascade_offsets_each_window_and_stays_inside_the_area() {
        let area = Rect::new(0.0, 25.0, 1440.0, 875.0);
        assert!(cascade_frames(area, 0, 30.0).is_empty());
        let one = cascade_frames(area, 1, 30.0);
        assert_eq!(one, vec![Rect::new(0.0, 25.0, 1008.0, 613.0)]);
        let four = cascade_frames(area, 4, 30.0);
        assert_eq!(four[1].x - four[0].x, 30.0);
        assert_eq!(four[3], Rect::new(90.0, 115.0, 1008.0, 613.0));
        let many = cascade_frames(area, 50, 100.0);
        let last = many.last().unwrap();
        assert!(
            last.max_x() <= area.max_x() + 1.0 && last.max_y() <= area.max_y() + 1.0,
            "the last window is still on screen"
        );
    }

    #[test]
    fn tiling_fills_the_area_with_the_last_row_stretched() {
        let area = Rect::new(0.0, 0.0, 1200.0, 800.0);
        assert!(tile_frames(area, 0, 0.0).is_empty());
        assert_eq!(tile_frames(area, 1, 0.0), vec![area]);
        let two = tile_frames(area, 2, 0.0);
        assert_eq!(
            two,
            vec![
                Rect::new(0.0, 0.0, 600.0, 800.0),
                Rect::new(600.0, 0.0, 600.0, 800.0)
            ]
        );
        // Five windows: three on top, two stretched across the bottom.
        let five = tile_frames(area, 5, 0.0);
        assert_eq!(five[0], Rect::new(0.0, 0.0, 400.0, 400.0));
        assert_eq!(five[2], Rect::new(800.0, 0.0, 400.0, 400.0));
        assert_eq!(five[3], Rect::new(0.0, 400.0, 600.0, 400.0));
        assert_eq!(five[4], Rect::new(600.0, 400.0, 600.0, 400.0));
        // A gap goes between windows and at the edges.
        let gapped = tile_frames(area, 2, 20.0);
        assert_eq!(gapped[0], Rect::new(10.0, 10.0, 580.0, 780.0));
        assert_eq!(gapped[1].x - (gapped[0].x + gapped[0].width), 20.0);
    }
}
