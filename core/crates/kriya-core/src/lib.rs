//! Kriya's shared core. Profiles, the action engine, rules, configuration, backup and storage live here and know
//! nothing about an operating system. The macOS app (and later the Windows app) call this surface through UniFFI and
//! supply the platform adapters: permissions, input events, window control, device discovery and the user interface.

use std::path::PathBuf;

uniffi::setup_scaffolding!();

pub mod actions;
pub mod backup;
pub mod clipboard;
mod clipboard_db;
pub mod drag_tools;
pub mod error;
pub mod expansion;
pub mod finder;
mod finder_store;
pub mod gestures;
pub mod keyboard;
mod keyboard_store;
pub mod link_routing;
pub mod markdown;
pub mod model;
pub mod mouse;
mod mouse_store;
pub mod pointer_effects;
pub mod pointer_menu;
pub mod profiles;
pub mod remap;
pub mod rules;
pub mod screen_tools;
pub mod scroll;
pub mod selection;
mod selection_store;
pub mod session;
pub mod store;
pub mod template;
pub mod text_tools;
pub mod traffic;
mod traffic_store;
mod vault;
pub mod window_extras;
mod window_store;
pub mod windows;
pub mod workflow;
mod workflow_store;
pub mod workspace;

pub use actions::{Action, ActionStep, NamedAction, ScriptLanguage};
pub use backup::BackupSummary;
pub use clipboard::{ClipConfig, ClipKind, ClipSkipReason, NewClip};
pub use clipboard_db::{
    ClipBlob, ClipCollection, ClipFilter, ClipItem, ClipRecordOutcome, ClipRecordStatus, ClipStats,
    SnippetImportSummary, VaultStatus,
};
pub use drag_tools::{
    ButtonScrollBinding, DoubleClickBinding, DragMove, DragToolsConfig, GlideStep, Velocity,
};
pub use error::CoreError;
pub use expansion::{
    ExpandOn, ExpansionMatch, ExpansionMatcher, ExpansionSnippet, SnippetConflict,
    SnippetConflictKind, TextSnippetImportSummary,
};
pub use gestures::{ButtonDecision, GestureEngine, GestureEngineConfig, RockerKind};
pub use keyboard::{
    KeyShortcut, KeyboardConfig, ReservedKey, ShortcutConflict, ShortcutConflictKind,
    ShortcutScope, ShortcutTarget,
};
pub use link_routing::{LinkDecision, LinkRoutingConfig, LinkRule, LinkTarget, MatchKind};
pub use model::{
    AppSettings, AppearanceMode, ConnectionKind, DeviceKind, DeviceRecord, FeatureId,
    FeatureOverride, LogLevel, Profile,
};
pub use mouse::{
    ButtonRule, GestureBinding, GestureDirection, GestureSettings, MouseAssignment, MouseConfig,
    MousePreset, MouseSettings, PointerAccelerationPreset, PointerSettings, ScrollAxis,
};
pub use pointer_effects::{HaloStyle, MagnifierShape, PointerEffectsConfig, SavedPosition};
pub use pointer_menu::{PointerMenuConfig, PointerMenuItem};
pub use remap::{EngineEffect, EngineResult, RemapConfig, RemapEngine, RemapOutput, RemapRule};
pub use rules::{Rule, Trigger};
pub use screen_tools::{
    DimLevel, DisplayProfile, DisplayState, HotCorner, ScreenCorner, ScreenToolsConfig, ShelfEdge,
};
pub use scroll::{ScrollShaper, ScrollStep, SmoothScroller};
pub use selection::{
    AppBehavior, ApprovedScript, SelectionAction, SelectionActionKind, SelectionConfig,
    SelectionMode, SelectionTarget, ToolbarPosition, ToolbarSize, ToolbarTheme, TranslateProvider,
};
pub use session::SessionOutcome;
pub use template::{PromptValue, TemplateContext, TemplateOutput};
pub use text_tools::TextOp;
pub use traffic::{
    HoverSet, TrafficAction, TrafficBinding, TrafficButton, TrafficConfig, TrafficProfile,
};
pub use window_extras::{Direction, FocusCandidate, GridBlock, StashEdge};
pub use windows::{
    CustomSize, FrameHistory, LayoutEntry, PlacementRule, Point, Rect, SavedLayout,
    ShortcutBinding, SwitcherItem, UnplacedPolicy, WindowConfig, WindowLayout,
};
pub use workflow::{
    ConditionGroup, ConditionItem, ConditionKind, ConditionMode, ConditionTemplate, Corner, Edge,
    EvalContext, OnError, Risk, RunStatus, StepKind, StepResult, StepRisk, StepStatus,
    StepTemplate, SystemOp, TrackpadGesture, TriggerTemplate, Workflow, WorkflowRun, WorkflowStep,
    WorkflowTrigger,
};
pub use workspace::{FavoriteWindow, Workspace, WorkspaceConfig};

use clipboard_db::ClipStore;
use session::SessionGuard;
use store::Store;

/// The version of this core, for diagnostics.
#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

#[uniffi::export]
pub fn all_features() -> Vec<FeatureId> {
    FeatureId::ALL.to_vec()
}

/// Returns why an action cannot run, or nothing when it is complete and allowed.
#[uniffi::export]
pub fn action_problem(action: Action) -> Option<String> {
    actions::validate(&action).err().map(|e| e.to_string())
}

/// Ready-made actions (Back, Forward, Mission Control, desktops, tabs and a few window and pointer commands).
#[uniffi::export]
pub fn suggested_actions() -> Vec<NamedAction> {
    actions::suggested_actions()
}

/// Checks an action and flattens it into the ordered steps the shell carries out.
#[uniffi::export]
pub fn plan_action(action: Action) -> Result<Vec<ActionStep>, CoreError> {
    actions::plan(&action)
}

/// The features switched off for the app in front, given the profiles the shell already holds. No I/O.
#[uniffi::export]
pub fn disabled_features(profiles: Vec<Profile>, app_id: Option<String>) -> Vec<FeatureId> {
    profiles::disabled_features(&profiles, app_id.as_deref())
}

/// Which preset applies to a device in an app, given the saved assignments.
#[uniffi::export]
pub fn resolve_mouse_preset(
    assignments: Vec<MouseAssignment>,
    default_preset_id: String,
    device_id: Option<String>,
    app_id: Option<String>,
) -> String {
    mouse::resolve_preset_id(
        &assignments,
        &default_preset_id,
        device_id.as_deref(),
        app_id.as_deref(),
    )
}

/// The settings a new preset starts from.
#[uniffi::export]
pub fn default_mouse_settings() -> MouseSettings {
    MouseSettings::default()
}

/// The pointer tracking value to give macOS for these settings: nothing to leave it alone, -1 for no acceleration,
/// otherwise a speed on macOS's 0 to 3 scale.
#[uniffi::export]
pub fn pointer_tracking_value(pointer: PointerSettings) -> Option<f64> {
    pointer.tracking_value()
}

/// The same, while the precision modifier is held.
#[uniffi::export]
pub fn pointer_precision_tracking_value(pointer: PointerSettings) -> Option<f64> {
    pointer.precision_tracking_value()
}

// ---- window management ------------------------------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct WindowCommandInfo {
    pub command: String,
    pub title: String,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct WindowRef {
    pub app_id: String,
    pub title: String,
}

#[uniffi::export]
pub fn window_layouts() -> Vec<WindowLayout> {
    windows::ALL_LAYOUTS.to_vec()
}

#[uniffi::export]
pub fn window_layout_command(layout: WindowLayout) -> String {
    layout.command().to_string()
}

#[uniffi::export]
pub fn window_layout_title(layout: WindowLayout) -> String {
    layout.title().to_string()
}

#[uniffi::export]
pub fn window_layout_from_command(command: String) -> Option<WindowLayout> {
    WindowLayout::from_command(&command)
}

/// Which window to focus when moving in a direction, or `None` when nothing lies that way.
#[uniffi::export]
pub fn window_focus_target(
    from: Rect,
    candidates: Vec<FocusCandidate>,
    direction: Direction,
) -> Option<String> {
    window_extras::focus_target(from, &candidates, direction)
}

#[uniffi::export]
pub fn window_direction_from_command(command: String) -> Option<Direction> {
    Direction::from_command(&command)
}

#[uniffi::export]
pub fn window_nearest_stash_edge(frame: Rect, area: Rect) -> StashEdge {
    window_extras::nearest_stash_edge(frame, area)
}

#[uniffi::export]
pub fn window_stash_frame(frame: Rect, area: Rect, edge: StashEdge, sliver: f64) -> Rect {
    window_extras::stash_frame(frame, area, edge, sliver)
}

#[uniffi::export]
pub fn window_stash_hit(pointer: Point, stashed: Rect, area: Rect, edge: StashEdge) -> bool {
    window_extras::stash_hit(pointer, stashed, area, edge)
}

#[uniffi::export]
pub fn window_unstash_frame(stashed: Rect, area: Rect, edge: StashEdge) -> Rect {
    window_extras::unstash_frame(stashed, area, edge)
}

/// The frame for a block of keyboard-grid cells inside an area.
#[uniffi::export]
pub fn window_grid_frame(area: Rect, columns: u32, rows: u32, block: GridBlock, gap: f64) -> Rect {
    window_extras::grid_frame(
        area,
        columns,
        rows,
        (block.from_column, block.from_row),
        (block.to_column, block.to_row),
        gap,
    )
}

/// One step of the grid cursor. Returns the new (column, row) as a two-item list.
#[uniffi::export]
pub fn window_grid_step(
    column: u32,
    row: u32,
    direction: Direction,
    columns: u32,
    rows: u32,
) -> Vec<u32> {
    let (c, r) = window_extras::grid_step((column, row), direction, columns, rows);
    vec![c, r]
}

/// The todo window's column and the space left for everything else.
#[uniffi::export]
pub fn window_todo_split(area: Rect, fraction: f64, on_right: bool) -> Vec<Rect> {
    let (todo, rest) = window_extras::todo_split(area, fraction, on_right);
    vec![todo, rest]
}

/// The drop zone under the pointer, as an index into `zones` (fractions of the display's usable area).
#[uniffi::export]
pub fn window_drop_zone_at(point: Point, area: Rect, zones: Vec<Rect>) -> Option<u32> {
    window_extras::drop_zone_at(point, area, &zones).map(|i| i as u32)
}

/// A zone given as fractions of an area, as a frame in points.
#[uniffi::export]
pub fn window_zone_frame(area: Rect, zone: Rect) -> Rect {
    window_extras::zone_frame(area, zone)
}

/// A display's usable area with a margin all round ("almost maximize").
#[uniffi::export]
pub fn window_inset_frame(area: Rect, margin: f64) -> Rect {
    window_extras::inset_frame(area, margin)
}

/// Full width or full height, leaving the other direction as it is.
#[uniffi::export]
pub fn window_maximize_axis(frame: Rect, area: Rect, horizontal: bool) -> Rect {
    window_extras::maximize_axis(frame, area, horizontal)
}

/// Narrows a window on an ultrawide display, centred. Unchanged when the limit is off or the display is not ultrawide.
#[uniffi::export]
pub fn window_limit_width(frame: Rect, area: Rect, max_width: f64) -> Rect {
    window_extras::limit_width(frame, area, max_width)
}

/// Grows or shrinks a window around its centre.
#[uniffi::export]
pub fn window_resize_by(frame: Rect, area: Rect, dw: f64, dh: f64, keep_aspect: bool) -> Rect {
    window_extras::resize_by(frame, area, dw, dh, keep_aspect)
}

/// Frames for a cascade of `count` windows.
#[uniffi::export]
pub fn window_cascade_frames(area: Rect, count: u32, offset: f64) -> Vec<Rect> {
    window_extras::cascade_frames(area, count as usize, offset)
}

/// Frames for `count` windows tiled to fill the area.
#[uniffi::export]
pub fn window_tile_frames(area: Rect, count: u32, gap: f64) -> Vec<Rect> {
    window_extras::tile_frames(area, count as usize, gap)
}

/// The layout for a pointer offset from the radial menu's centre (y grows downward).
#[uniffi::export]
pub fn window_radial_layout(dx: f64, dy: f64, dead_zone: f64) -> WindowLayout {
    window_extras::radial_layout(dx, dy, dead_zone)
}

/// Commands other than layouts that can have a shortcut.
#[uniffi::export]
pub fn window_extra_commands() -> Vec<WindowCommandInfo> {
    windows::EXTRA_COMMANDS
        .iter()
        .map(|(c, t)| WindowCommandInfo {
            command: (*c).to_string(),
            title: (*t).to_string(),
        })
        .collect()
}

#[uniffi::export]
pub fn window_layout_frame(layout: WindowLayout, area: Rect, current: Rect, gap: f64) -> Rect {
    windows::layout_frame(layout, area, current, gap)
}

#[uniffi::export]
pub fn window_custom_frame(size: CustomSize, area: Rect) -> Rect {
    windows::custom_frame(&size, area)
}

#[uniffi::export]
pub fn window_cycle_layout(pressed: WindowLayout, previous: Option<WindowLayout>) -> WindowLayout {
    windows::cycle_layout(pressed, previous)
}

#[uniffi::export]
pub fn window_snap_zone(point: Point, area: Rect, edge: f64, corner: f64) -> Option<WindowLayout> {
    windows::snap_zone(point, area, edge, corner)
}

#[uniffi::export]
pub fn window_translate_frame(
    frame: Rect,
    from: Rect,
    to: Rect,
    preserve_proportions: bool,
) -> Rect {
    windows::translate_frame(frame, from, to, preserve_proportions)
}

#[uniffi::export]
pub fn window_contain(frame: Rect, area: Rect) -> Rect {
    windows::contain(frame, area)
}

#[uniffi::export]
pub fn window_display_index(frame: Rect, areas: Vec<Rect>) -> Option<u32> {
    windows::display_index_for(frame, &areas).map(|i| i as u32)
}

#[uniffi::export]
pub fn window_display_set_key(display_ids: Vec<String>) -> String {
    windows::display_set_key(&display_ids)
}

#[uniffi::export]
pub fn window_match_entries(
    entries: Vec<LayoutEntry>,
    open_windows: Vec<WindowRef>,
) -> Vec<Option<u32>> {
    let pairs: Vec<(String, String)> = open_windows
        .into_iter()
        .map(|w| (w.app_id, w.title))
        .collect();
    windows::match_layout_entries(&entries, &pairs)
        .into_iter()
        .map(|m| m.map(|i| i as u32))
        .collect()
}

#[uniffi::export]
pub fn window_rule_for_app(rules: Vec<PlacementRule>, app_id: String) -> Option<PlacementRule> {
    windows::rule_for_app(&rules, &app_id).cloned()
}

#[uniffi::export]
pub fn window_rank_switcher(items: Vec<SwitcherItem>, query: String) -> Vec<String> {
    windows::rank_switcher(&items, &query)
}

#[uniffi::export]
pub fn window_frame_miss(wanted: Rect, actual: Rect) -> f64 {
    windows::frame_miss(wanted, actual)
}

#[uniffi::export]
pub fn default_window_shortcuts() -> Vec<ShortcutBinding> {
    windows::default_shortcuts()
}

#[uniffi::export]
pub fn window_shortcut_problem(list: Vec<ShortcutBinding>) -> Option<String> {
    windows::check_shortcuts(&list).err()
}

#[uniffi::export]
pub fn default_window_config() -> WindowConfig {
    WindowConfig::default()
}

// ---- traffic-light buttons ---------------------------------------------------------------------------------------------

#[uniffi::export]
pub fn traffic_resolve(
    config: TrafficConfig,
    profiles: Vec<TrafficProfile>,
    app_id: Option<String>,
    button: TrafficButton,
    modifiers: u64,
) -> TrafficAction {
    traffic::resolve(&config, &profiles, app_id.as_deref(), button, modifiers)
}

#[uniffi::export]
pub fn traffic_is_customized(
    config: TrafficConfig,
    profiles: Vec<TrafficProfile>,
    app_id: Option<String>,
    button: TrafficButton,
) -> bool {
    traffic::is_customized(&config, &profiles, app_id.as_deref(), button)
}

#[uniffi::export]
pub fn traffic_is_idle(config: TrafficConfig, profiles: Vec<TrafficProfile>) -> bool {
    config.is_idle(&profiles)
}

#[uniffi::export]
pub fn traffic_is_excluded(config: TrafficConfig, app_id: Option<String>) -> bool {
    config.is_excluded(app_id.as_deref())
}

#[uniffi::export]
pub fn traffic_action_title(action: TrafficAction) -> String {
    action.title()
}

#[uniffi::export]
pub fn traffic_modifier_title(modifiers: u64) -> String {
    traffic::describe_modifiers(modifiers)
}

#[uniffi::export]
pub fn suggested_traffic_bindings() -> Vec<TrafficBinding> {
    traffic::suggested_bindings()
}

#[uniffi::export]
pub fn suggested_traffic_hover_sets() -> Vec<HoverSet> {
    traffic::suggested_hover_sets()
}

#[uniffi::export]
pub fn default_traffic_config() -> TrafficConfig {
    TrafficConfig::default()
}

/// Apps whose windows are never intercepted.
#[uniffi::export]
pub fn builtin_traffic_exclusions() -> Vec<String> {
    traffic::BUILTIN_EXCLUSIONS
        .iter()
        .map(|s| (*s).to_string())
        .collect()
}

// ---- Finder and right-click actions ------------------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct FileNameParts {
    pub stem: String,
    pub extension: String,
}

#[uniffi::export]
pub fn finder_shell_escape(path: String) -> String {
    finder::shell_escape(&path)
}

#[uniffi::export]
pub fn finder_path_text(style: finder::PathStyle, paths: Vec<String>) -> String {
    finder::path_text(style, &paths)
}

#[uniffi::export]
pub fn finder_unique_name(candidate: String, existing: Vec<String>) -> String {
    finder::unique_name(&candidate, &existing)
}

#[uniffi::export]
pub fn finder_copy_name(name: String, existing: Vec<String>) -> String {
    finder::copy_name(&name, &existing)
}

#[uniffi::export]
pub fn finder_name_problem(name: String) -> Option<String> {
    finder::name_problem(&name)
}

#[uniffi::export]
pub fn finder_split_extension(name: String) -> FileNameParts {
    let (stem, extension) = finder::split_extension(&name);
    FileNameParts { stem, extension }
}

#[uniffi::export]
pub fn finder_plan_batch_rename(
    names: Vec<String>,
    rule: finder::BatchRenameRule,
    others: Vec<String>,
) -> Vec<finder::RenamePlanItem> {
    finder::plan_batch_rename(&names, &rule, &others)
}

#[uniffi::export]
pub fn finder_rename_plan_ready(plan: Vec<finder::RenamePlanItem>) -> bool {
    finder::rename_plan_ready(&plan)
}

#[uniffi::export]
pub fn finder_confirmation_message(
    item: finder::FinderItem,
    count: u32,
    config: finder::FinderConfig,
) -> Option<String> {
    finder::confirmation_message(&item, count, &config)
}

#[uniffi::export]
pub fn finder_default_items() -> Vec<finder::FinderItem> {
    finder::default_items()
}

/// Ready-made selection-bar actions (Markdown helpers, encodings, searches, share, create a note or reminder).
#[uniffi::export]
pub fn selection_suggested_actions() -> Vec<selection::SelectionAction> {
    selection::suggested_actions()
}

/// A colour as `[red, green, blue]` from 0 to 1, or an empty list when the text is not a colour.
#[uniffi::export]
pub fn pointer_parse_color(text: String) -> Vec<f64> {
    pointer_effects::parse_color(&text)
        .map(|c| c.to_vec())
        .unwrap_or_default()
}

/// The command that moves the pointer to a saved position.
#[uniffi::export]
pub fn pointer_position_command(id: String) -> String {
    pointer_effects::position_command(&id)
}

/// Where a saved position lands on a display's frame.
#[uniffi::export]
pub fn pointer_position_point(area: Rect, x: f64, y: f64) -> Point {
    pointer_effects::position_point(area, x, y)
}

/// The part of the screen the magnifier shows around the pointer.
#[uniffi::export]
pub fn pointer_magnifier_source(pointer: Point, size: f64, zoom: f64, bounds: Rect) -> Rect {
    pointer_effects::magnifier_source(pointer, size, zoom, bounds)
}

/// The command that launches a workspace.
#[uniffi::export]
pub fn workspace_command(id: String) -> String {
    workspace::workspace_command(&id)
}

/// The running apps focus mode or "hide all" should hide (bundle ids in, bundle ids out).
#[uniffi::export]
pub fn workspace_apps_to_hide(
    running: Vec<String>,
    keep: Vec<String>,
    self_id: String,
) -> Vec<String> {
    workspace::apps_to_hide(&running, &keep, &self_id)
}

/// The running apps "quit all" would close.
#[uniffi::export]
pub fn workspace_quit_candidates(
    running: Vec<String>,
    keep: Vec<String>,
    self_id: String,
) -> Vec<String> {
    workspace::quit_candidates(&running, &keep, &self_id)
}

/// What to do with a link: the browser or profile, the cleaned address, and what was changed.
#[uniffi::export]
pub fn resolve_link(
    config: LinkRoutingConfig,
    url: String,
    source_app_id: Option<String>,
    modifiers: u64,
) -> LinkDecision {
    link_routing::resolve_link(&config, &url, source_app_id.as_deref(), modifiers)
}

/// An address without tracking parameters.
#[uniffi::export]
pub fn link_strip_tracking(url: String, extra: Vec<String>) -> String {
    link_routing::strip_tracking(&url, &extra).0
}

/// Markdown for a piece of HTML, as formatted text on the clipboard comes.
#[uniffi::export]
pub fn html_to_markdown(html: String) -> String {
    markdown::html_to_markdown(&html)
}

/// The pointer-menu items to show while an app is in front.
#[uniffi::export]
pub fn pointer_menu_items_for_app(
    items: Vec<PointerMenuItem>,
    app_id: Option<String>,
) -> Vec<PointerMenuItem> {
    pointer_menu::items_for_app(&items, app_id.as_deref())
}

/// Extra ready-made Finder actions (an editor, hidden files, the parent folder).
#[uniffi::export]
pub fn finder_suggested_items() -> Vec<finder::FinderItem> {
    finder::suggested_items()
}

#[uniffi::export]
pub fn default_finder_config() -> finder::FinderConfig {
    finder::FinderConfig::default()
}

// ---- clipboard ---------------------------------------------------------------------------------------------------------

#[uniffi::export]
pub fn default_clip_config() -> ClipConfig {
    ClipConfig::default()
}

/// Pasteboard types that mark a copy as secret or temporary.
#[uniffi::export]
pub fn clip_concealed_types() -> Vec<String> {
    clipboard::CONCEALED_TYPES
        .iter()
        .map(|s| (*s).to_string())
        .collect()
}

/// A cheap check the shell can make before reading a copy at all.
#[uniffi::export]
pub fn clip_early_skip(
    config: ClipConfig,
    source_app: Option<String>,
    concealed: bool,
) -> Option<ClipSkipReason> {
    if config.paused {
        Some(ClipSkipReason::Paused)
    } else if concealed {
        Some(ClipSkipReason::Concealed)
    } else if config.is_excluded(source_app.as_deref()) {
        Some(ClipSkipReason::ExcludedApp)
    } else {
        None
    }
}

#[uniffi::export]
pub fn clip_looks_sensitive(text: String) -> bool {
    clipboard::looks_sensitive(&text)
}

#[uniffi::export]
pub fn clip_classify_text(text: String) -> ClipKind {
    clipboard::classify_text(&text)
}

#[uniffi::export]
pub fn clip_shortcut_problem(config: ClipConfig) -> Option<String> {
    config.shortcut_problem()
}

// ---- text tools and the selection bar -----------------------------------------------------------------------------------

/// Runs one text step. The error is a plain sentence.
#[uniffi::export]
pub fn text_apply(op: TextOp, text: String) -> Result<String, CoreError> {
    text_tools::apply(&op, &text).map_err(CoreError::invalid)
}

#[uniffi::export]
pub fn text_apply_all(ops: Vec<TextOp>, text: String) -> Result<String, CoreError> {
    text_tools::apply_all(&ops, &text).map_err(CoreError::invalid)
}

#[uniffi::export]
pub fn text_ops_problem(ops: Vec<TextOp>) -> Option<String> {
    text_tools::check_ops(&ops).err()
}

/// Ready-made rules that open a site's links in its own app.
#[uniffi::export]
pub fn suggested_link_rules() -> Vec<LinkRule> {
    link_routing::suggested_rules()
}

#[uniffi::export]
pub fn text_op_title(op: TextOp) -> String {
    op.title().to_string()
}

#[uniffi::export]
pub fn text_json_validate(text: String) -> Option<String> {
    text_tools::json_validate(&text).err()
}

#[uniffi::export]
pub fn text_url_template(template: String, text: String) -> Result<String, CoreError> {
    text_tools::expand_url_template(&template, &text).map_err(CoreError::invalid)
}

#[uniffi::export]
pub fn text_url_template_problem(template: String) -> Option<String> {
    text_tools::check_url_template(&template).err()
}

#[uniffi::export]
pub fn text_find_urls(text: String) -> Vec<String> {
    text_tools::find_urls(&text)
}

#[uniffi::export]
pub fn selection_translate_url(
    provider: TranslateProvider,
    target: String,
    text: String,
) -> Result<String, CoreError> {
    selection::translate_url(provider, &target, &text).map_err(CoreError::invalid)
}

#[uniffi::export]
pub fn selection_default_actions() -> Vec<SelectionAction> {
    selection::default_actions()
}

#[uniffi::export]
pub fn default_selection_config() -> SelectionConfig {
    SelectionConfig::default()
}

#[uniffi::export]
pub fn selection_action_problem(action: SelectionAction) -> Option<String> {
    action.check().err().map(|e| e.to_string())
}

#[uniffi::export]
pub fn selection_action_needs_approval(action: SelectionAction) -> bool {
    action.needs_approval()
}

#[uniffi::export]
pub fn selection_actions_for(
    actions: Vec<SelectionAction>,
    config: SelectionConfig,
    app_id: Option<String>,
    editable: bool,
    text: String,
) -> Vec<String> {
    selection::actions_for(&actions, &config, app_id.as_deref(), editable, &text)
}

#[uniffi::export]
pub fn selection_behavior(
    config: SelectionConfig,
    app_id: Option<String>,
) -> selection::EffectiveBehavior {
    selection::behavior_for(&config, app_id.as_deref())
}

#[uniffi::export]
pub fn selection_length_ok(config: SelectionConfig, text: String) -> bool {
    selection::selection_length_ok(&config, &text)
}

/// A fingerprint of a script, for approving it.
#[uniffi::export]
pub fn script_fingerprint(language: String, source: String) -> String {
    selection::script_fingerprint(&language, &source)
}

// ---- keyboard, shortcuts and text expansion ---------------------------------------------------------------------------------

#[uniffi::export]
pub fn default_keyboard_config() -> KeyboardConfig {
    KeyboardConfig::default()
}

/// Fills in a snippet's placeholders. Call once to learn which `{prompt:…}` values are needed, then again with them.
#[uniffi::export]
pub fn render_snippet(body: String, context: TemplateContext) -> TemplateOutput {
    template::render_template(&body, &context)
}

#[uniffi::export]
pub fn snippet_format_time(timestamp: i64, utc_offset_seconds: i32, format: String) -> String {
    template::format_time(timestamp, utc_offset_seconds, &format)
}

#[uniffi::export]
pub fn snippet_problem(snippet: ExpansionSnippet) -> Option<String> {
    snippet.tidied().check().err().map(|e| e.to_string())
}

#[uniffi::export]
pub fn snippet_conflicts(
    candidate: ExpansionSnippet,
    all: Vec<ExpansionSnippet>,
) -> Vec<SnippetConflict> {
    expansion::abbreviation_conflicts(&candidate.tidied(), &all)
}

#[uniffi::export]
pub fn key_shortcut_problem(shortcut: KeyShortcut) -> Option<String> {
    shortcut.check().err().map(|e| e.to_string())
}

#[uniffi::export]
pub fn key_shortcut_conflicts(
    candidate: KeyShortcut,
    existing: Vec<KeyShortcut>,
    reserved: Vec<ReservedKey>,
) -> Vec<ShortcutConflict> {
    keyboard::shortcut_conflicts(&candidate, &existing, &reserved)
}

#[uniffi::export]
pub fn key_shortcut_applies(scope: ShortcutScope, app_id: Option<String>) -> bool {
    keyboard::applies_in(&scope, app_id.as_deref())
}

#[uniffi::export]
pub fn key_shortcut_find(
    list: Vec<KeyShortcut>,
    key_code: u16,
    modifiers: u64,
    app_id: Option<String>,
) -> Option<KeyShortcut> {
    keyboard::find_shortcut(&list, key_code, modifiers, app_id.as_deref())
}

#[uniffi::export]
pub fn key_system_reserved() -> Vec<ReservedKey> {
    keyboard::system_reserved()
}

// ---- automation ------------------------------------------------------------------------------------------------------------

#[uniffi::export]
pub fn workflow_step_catalog() -> Vec<StepTemplate> {
    workflow::step_catalog()
}

#[uniffi::export]
pub fn workflow_trigger_catalog() -> Vec<TriggerTemplate> {
    workflow::trigger_catalog()
}

#[uniffi::export]
pub fn workflow_condition_catalog() -> Vec<ConditionTemplate> {
    workflow::condition_catalog()
}

#[uniffi::export]
pub fn workflow_evaluate(group: ConditionGroup, context: EvalContext) -> bool {
    workflow::evaluate(&group, &context)
}

#[uniffi::export]
pub fn workflow_risks(workflow: Workflow) -> Vec<Risk> {
    workflow::risks(&workflow)
}

#[uniffi::export]
pub fn workflow_needs_authorization(workflow: Workflow) -> bool {
    workflow::needs_authorization(&workflow)
}

#[uniffi::export]
pub fn workflow_fingerprint(workflow: Workflow) -> String {
    workflow::fingerprint(&workflow)
}

#[uniffi::export]
pub fn workflow_problem(workflow: Workflow) -> Option<String> {
    workflow.check().err().map(|e| e.to_string())
}

#[uniffi::export]
pub fn workflow_step_summary(step: WorkflowStep) -> String {
    step.title()
}

#[uniffi::export]
pub fn workflow_step_risk(kind: StepKind) -> StepRisk {
    kind.risk()
}

#[uniffi::export]
pub fn workflow_trigger_title(trigger: WorkflowTrigger) -> String {
    trigger.title().to_string()
}

#[uniffi::export]
pub fn workflow_command(workflow: Workflow) -> String {
    workflow.command()
}

#[uniffi::export]
pub fn workflow_max_chain_depth() -> u32 {
    workflow::MAX_CHAIN_DEPTH
}

/// The handle a shell opens once at launch and keeps for the life of the app.
#[derive(uniffi::Object)]
pub struct KriyaCore {
    store: Store,
    clips: ClipStore,
    session: SessionGuard,
}

#[uniffi::export]
impl KriyaCore {
    /// Opens (or creates) the data folder. `now` is the current unix time in seconds.
    #[uniffi::constructor]
    pub fn open(support_dir: String, now: i64) -> Result<Self, CoreError> {
        let dir = PathBuf::from(support_dir);
        let store = Store::open(&dir, now)?;
        let session = SessionGuard::new(dir.join("session.json"));
        // If the history cannot be opened, this run keeps it in memory rather than refusing to start.
        let clips = ClipStore::open(&dir, now).or_else(|_| ClipStore::open_in_memory())?;
        Ok(KriyaCore {
            store,
            clips,
            session,
        })
    }

    /// The saved data was damaged and a fresh copy was started; the old file was kept beside it.
    pub fn recovered_from_corruption(&self) -> bool {
        self.store.recovered_from_corruption
    }

    /// Changes this run makes will not be saved, because no database file could be opened.
    pub fn is_ephemeral(&self) -> bool {
        self.store.ephemeral
    }

    // ---- crash recovery and safe mode -----------------------------------------------------------------------

    pub fn begin_session(
        &self,
        now: i64,
        debugger_attached: bool,
        force_safe_mode: bool,
    ) -> SessionOutcome {
        self.session.begin(now, debugger_attached, force_safe_mode)
    }

    pub fn mark_feature_starting(&self, feature: FeatureId) {
        self.session.mark_starting(feature);
    }

    pub fn mark_feature_started(&self) {
        self.session.mark_started();
    }

    pub fn end_session(&self) {
        self.session.end();
    }

    pub fn leave_safe_mode(&self) {
        self.session.leave_safe_mode();
    }

    // ---- settings -------------------------------------------------------------------------------------------

    pub fn settings(&self) -> Result<AppSettings, CoreError> {
        self.store.settings()
    }

    pub fn save_settings(&self, settings: AppSettings) -> Result<(), CoreError> {
        self.store.save_settings(&settings)
    }

    // ---- devices --------------------------------------------------------------------------------------------

    pub fn devices(&self) -> Result<Vec<DeviceRecord>, CoreError> {
        self.store.devices()
    }

    pub fn upsert_device(&self, device: DeviceRecord) -> Result<(), CoreError> {
        self.store.upsert_device(&device)
    }

    pub fn touch_device(&self, id: String, last_seen: i64) -> Result<(), CoreError> {
        self.store.touch_device(&id, last_seen)
    }

    pub fn set_device_nickname(
        &self,
        id: String,
        nickname: Option<String>,
    ) -> Result<(), CoreError> {
        self.store.set_device_nickname(&id, nickname)
    }

    pub fn set_device_connection_override(
        &self,
        id: String,
        value: Option<ConnectionKind>,
    ) -> Result<(), CoreError> {
        self.store.set_device_connection_override(&id, value)
    }

    pub fn forget_device(&self, id: String) -> Result<(), CoreError> {
        self.store.forget_device(&id)
    }

    // ---- profiles -------------------------------------------------------------------------------------------

    pub fn profiles(&self) -> Result<Vec<Profile>, CoreError> {
        self.store.profiles()
    }

    pub fn save_profile(&self, profile: Profile) -> Result<(), CoreError> {
        self.store.save_profile(&profile)
    }

    pub fn delete_profile(&self, id: String) -> Result<(), CoreError> {
        self.store.delete_profile(&id)
    }

    // ---- actions and rules ----------------------------------------------------------------------------------

    pub fn actions(&self) -> Result<Vec<NamedAction>, CoreError> {
        self.store.actions()
    }

    pub fn save_action(&self, action: NamedAction) -> Result<(), CoreError> {
        self.store.save_action(&action)
    }

    pub fn delete_action(&self, id: String) -> Result<(), CoreError> {
        self.store.delete_action(&id)
    }

    pub fn rules(&self) -> Result<Vec<Rule>, CoreError> {
        self.store.rules()
    }

    pub fn save_rule(&self, rule: Rule) -> Result<(), CoreError> {
        self.store.save_rule(&rule)
    }

    pub fn delete_rule(&self, id: String) -> Result<(), CoreError> {
        self.store.delete_rule(&id)
    }

    pub fn matching_rules(
        &self,
        trigger: Trigger,
        app_id: Option<String>,
        device_id: Option<String>,
    ) -> Result<Vec<Rule>, CoreError> {
        self.store
            .matching_rules(&trigger, app_id.as_deref(), device_id.as_deref())
    }

    // ---- mouse and trackpad ---------------------------------------------------------------------------------

    pub fn mouse_presets(&self) -> Result<Vec<MousePreset>, CoreError> {
        self.store.mouse_presets()
    }

    pub fn save_mouse_preset(&self, preset: MousePreset) -> Result<(), CoreError> {
        self.store.save_mouse_preset(&preset)
    }

    pub fn delete_mouse_preset(&self, id: String) -> Result<(), CoreError> {
        self.store.delete_mouse_preset(&id)
    }

    pub fn mouse_assignments(&self) -> Result<Vec<MouseAssignment>, CoreError> {
        self.store.mouse_assignments()
    }

    pub fn save_mouse_assignment(&self, assignment: MouseAssignment) -> Result<(), CoreError> {
        self.store.save_mouse_assignment(&assignment)
    }

    pub fn delete_mouse_assignment(&self, id: String) -> Result<(), CoreError> {
        self.store.delete_mouse_assignment(&id)
    }

    pub fn mouse_config(&self) -> Result<MouseConfig, CoreError> {
        self.store.mouse_config()
    }

    pub fn save_mouse_config(&self, config: MouseConfig) -> Result<(), CoreError> {
        self.store.save_mouse_config(&config)
    }

    /// Resets the default preset. With `everything`, also removes custom presets, assignments and app exclusions.
    pub fn restore_default_mouse_settings(&self, everything: bool) -> Result<(), CoreError> {
        self.store.restore_default_mouse_settings(everything)
    }

    pub fn export_mouse_preset(&self, id: String) -> Result<String, CoreError> {
        self.store.export_mouse_preset(&id)
    }

    pub fn import_mouse_preset(
        &self,
        json: String,
        new_id: String,
    ) -> Result<MousePreset, CoreError> {
        self.store.import_mouse_preset(&json, &new_id)
    }

    // ---- window management ----------------------------------------------------------------------------------

    pub fn window_config(&self) -> Result<WindowConfig, CoreError> {
        self.store.window_config()
    }

    pub fn save_window_config(&self, config: WindowConfig) -> Result<(), CoreError> {
        self.store.save_window_config(&config)
    }

    pub fn window_shortcuts(&self) -> Result<Vec<ShortcutBinding>, CoreError> {
        self.store.window_shortcuts()
    }

    pub fn save_window_shortcuts(&self, list: Vec<ShortcutBinding>) -> Result<(), CoreError> {
        self.store.save_window_shortcuts(&list)
    }

    pub fn custom_sizes(&self) -> Result<Vec<CustomSize>, CoreError> {
        self.store.custom_sizes()
    }

    pub fn save_custom_size(&self, size: CustomSize) -> Result<(), CoreError> {
        self.store.save_custom_size(&size)
    }

    pub fn delete_custom_size(&self, id: String) -> Result<(), CoreError> {
        self.store.delete_custom_size(&id)
    }

    pub fn saved_layouts(&self, include_auto: bool) -> Result<Vec<SavedLayout>, CoreError> {
        self.store.saved_layouts(include_auto)
    }

    pub fn save_layout(&self, layout: SavedLayout) -> Result<(), CoreError> {
        self.store.save_layout(&layout)
    }

    pub fn delete_layout(&self, id: String) -> Result<(), CoreError> {
        self.store.delete_layout(&id)
    }

    pub fn save_auto_layout(
        &self,
        display_key: String,
        entries: Vec<LayoutEntry>,
        now: i64,
    ) -> Result<(), CoreError> {
        self.store.save_auto_layout(&display_key, entries, now)
    }

    pub fn auto_layout_for(&self, display_key: String) -> Result<Option<SavedLayout>, CoreError> {
        self.store.auto_layout_for(&display_key)
    }

    pub fn window_rules(&self) -> Result<Vec<PlacementRule>, CoreError> {
        self.store.window_rules()
    }

    pub fn save_window_rule(&self, rule: PlacementRule) -> Result<(), CoreError> {
        self.store.save_window_rule(&rule)
    }

    pub fn delete_window_rule(&self, id: String) -> Result<(), CoreError> {
        self.store.delete_window_rule(&id)
    }

    /// Resets window settings and shortcuts. With `everything`, also removes custom sizes, layouts and rules.
    pub fn restore_default_window_settings(&self, everything: bool) -> Result<(), CoreError> {
        self.store.restore_default_window_settings(everything)
    }

    // ---- traffic-light buttons ------------------------------------------------------------------------------

    pub fn traffic_config(&self) -> Result<TrafficConfig, CoreError> {
        self.store.traffic_config()
    }

    pub fn save_traffic_config(&self, config: TrafficConfig) -> Result<(), CoreError> {
        self.store.save_traffic_config(&config)
    }

    pub fn traffic_profiles(&self) -> Result<Vec<TrafficProfile>, CoreError> {
        self.store.traffic_profiles()
    }

    pub fn save_traffic_profile(&self, profile: TrafficProfile) -> Result<(), CoreError> {
        self.store.save_traffic_profile(&profile)
    }

    pub fn delete_traffic_profile(&self, id: String) -> Result<(), CoreError> {
        self.store.delete_traffic_profile(&id)
    }

    /// Puts every button back to normal. With `everything`, also removes app profiles, hover menus and exclusions.
    pub fn restore_default_traffic_settings(&self, everything: bool) -> Result<(), CoreError> {
        self.store.restore_default_traffic_settings(everything)
    }

    // ---- Finder and right-click actions ---------------------------------------------------------------------

    pub fn finder_config(&self) -> Result<finder::FinderConfig, CoreError> {
        self.store.finder_config()
    }

    pub fn save_finder_config(&self, config: finder::FinderConfig) -> Result<(), CoreError> {
        self.store.save_finder_config(&config)
    }

    pub fn pointer_menu_config(&self) -> Result<PointerMenuConfig, CoreError> {
        self.store.pointer_menu_config()
    }

    pub fn save_pointer_menu_config(&self, config: PointerMenuConfig) -> Result<(), CoreError> {
        self.store.save_pointer_menu_config(&config)
    }

    pub fn link_routing_config(&self) -> Result<LinkRoutingConfig, CoreError> {
        self.store.link_routing_config()
    }

    pub fn save_link_routing_config(&self, config: LinkRoutingConfig) -> Result<(), CoreError> {
        self.store.save_link_routing_config(&config)
    }

    pub fn workspace_config(&self) -> Result<WorkspaceConfig, CoreError> {
        self.store.workspace_config()
    }

    pub fn save_workspace_config(&self, config: WorkspaceConfig) -> Result<(), CoreError> {
        self.store.save_workspace_config(&config)
    }

    pub fn drag_tools_config(&self) -> Result<DragToolsConfig, CoreError> {
        self.store.drag_tools_config()
    }

    pub fn save_drag_tools_config(&self, config: DragToolsConfig) -> Result<(), CoreError> {
        self.store.save_drag_tools_config(&config)
    }

    pub fn screen_tools_config(&self) -> Result<ScreenToolsConfig, CoreError> {
        self.store.screen_tools_config()
    }

    pub fn save_screen_tools_config(&self, config: ScreenToolsConfig) -> Result<(), CoreError> {
        self.store.save_screen_tools_config(&config)
    }

    pub fn remap_config(&self) -> Result<RemapConfig, CoreError> {
        self.store.remap_config()
    }

    pub fn save_remap_config(&self, config: RemapConfig) -> Result<(), CoreError> {
        self.store.save_remap_config(&config)
    }

    pub fn pointer_effects_config(&self) -> Result<PointerEffectsConfig, CoreError> {
        self.store.pointer_effects_config()
    }

    pub fn save_pointer_effects_config(
        &self,
        config: PointerEffectsConfig,
    ) -> Result<(), CoreError> {
        self.store.save_pointer_effects_config(&config)
    }

    pub fn finder_items(&self) -> Result<Vec<finder::FinderItem>, CoreError> {
        self.store.finder_items()
    }

    /// Saves the whole list in order, which is also how actions are reordered.
    pub fn save_finder_items(&self, items: Vec<finder::FinderItem>) -> Result<(), CoreError> {
        self.store.save_finder_items(&items)
    }

    pub fn file_templates(&self) -> Result<Vec<finder::FileTemplate>, CoreError> {
        self.store.file_templates()
    }

    pub fn save_file_template(&self, template: finder::FileTemplate) -> Result<(), CoreError> {
        self.store.save_file_template(&template)
    }

    pub fn delete_file_template(&self, id: String) -> Result<(), CoreError> {
        self.store.delete_file_template(&id)
    }

    pub fn folder_templates(&self) -> Result<Vec<finder::FolderTemplate>, CoreError> {
        self.store.folder_templates()
    }

    pub fn save_folder_template(&self, template: finder::FolderTemplate) -> Result<(), CoreError> {
        self.store.save_folder_template(&template)
    }

    pub fn delete_folder_template(&self, id: String) -> Result<(), CoreError> {
        self.store.delete_folder_template(&id)
    }

    /// Resets the actions and settings. With `everything`, the templates too.
    pub fn restore_default_finder_settings(&self, everything: bool) -> Result<(), CoreError> {
        self.store.restore_default_finder_settings(everything)
    }

    // ---- clipboard ------------------------------------------------------------------------------------------

    /// The history file was damaged and a fresh one was started.
    pub fn clip_recovered(&self) -> bool {
        self.clips.recovered_from_corruption
    }

    pub fn clip_is_ephemeral(&self) -> bool {
        self.clips.ephemeral
    }

    pub fn clip_config(&self) -> Result<ClipConfig, CoreError> {
        self.store.clip_config()
    }

    pub fn save_clip_config(&self, config: ClipConfig) -> Result<(), CoreError> {
        self.store.save_clip_config(&config)
    }

    /// Records a copy under the current settings.
    pub fn clip_record(&self, new: NewClip, now: i64) -> Result<ClipRecordOutcome, CoreError> {
        let config = self.store.clip_config()?;
        self.clips.record(new, now, &config)
    }

    pub fn clip_search(
        &self,
        query: String,
        filter: ClipFilter,
        limit: u32,
    ) -> Result<Vec<ClipItem>, CoreError> {
        self.clips.search(&query, &filter, limit)
    }

    pub fn clip_item(&self, id: String) -> Result<Option<ClipItem>, CoreError> {
        self.clips.item(&id)
    }

    pub fn clip_blob(&self, id: String) -> Result<Option<ClipBlob>, CoreError> {
        self.clips.blob(&id)
    }

    pub fn clip_stats(&self) -> Result<ClipStats, CoreError> {
        self.clips.stats()
    }

    pub fn clip_mark_used(&self, id: String, now: i64) -> Result<(), CoreError> {
        self.clips.mark_used(&id, now)
    }

    pub fn clip_set_pinned(&self, id: String, pinned: bool) -> Result<(), CoreError> {
        self.clips.set_pinned(&id, pinned)
    }

    pub fn clip_set_favorite(
        &self,
        id: String,
        favorite: bool,
        title: Option<String>,
    ) -> Result<(), CoreError> {
        self.clips.set_favorite(&id, favorite, title)
    }

    pub fn clip_set_title(&self, id: String, title: Option<String>) -> Result<(), CoreError> {
        self.clips.set_title(&id, title)
    }

    pub fn clip_set_tags(&self, id: String, tags: Vec<String>) -> Result<(), CoreError> {
        self.clips.set_tags(&id, &tags)
    }

    pub fn clip_all_tags(&self) -> Result<Vec<String>, CoreError> {
        self.clips.all_tags()
    }

    pub fn clip_set_collection(
        &self,
        id: String,
        collection: Option<String>,
    ) -> Result<(), CoreError> {
        self.clips.set_collection(&id, collection)
    }

    pub fn clip_delete(&self, id: String) -> Result<(), CoreError> {
        self.clips.delete(&id)
    }

    /// Removes the history; pinned items and snippets can be kept. Removed content is overwritten on disk.
    pub fn clip_clear(&self, keep_pinned: bool, keep_snippets: bool) -> Result<u32, CoreError> {
        self.clips.clear(keep_pinned, keep_snippets)
    }

    pub fn clip_add_snippet(
        &self,
        title: Option<String>,
        text: String,
        collection: Option<String>,
        now: i64,
    ) -> Result<String, CoreError> {
        self.clips.add_snippet(title, &text, collection, now)
    }

    pub fn clip_update_snippet(
        &self,
        id: String,
        title: Option<String>,
        text: Option<String>,
    ) -> Result<(), CoreError> {
        self.clips.update_snippet(&id, title, text)
    }

    pub fn clip_collections(&self) -> Result<Vec<ClipCollection>, CoreError> {
        self.clips.collections()
    }

    pub fn clip_save_collection(&self, id: String, name: String) -> Result<(), CoreError> {
        self.clips.save_collection(&id, &name)
    }

    pub fn clip_delete_collection(&self, id: String) -> Result<(), CoreError> {
        self.clips.delete_collection(&id)
    }

    /// Applies the retention period and limits now. Returns how many items were removed.
    pub fn clip_cleanup(&self, now: i64) -> Result<u32, CoreError> {
        let config = self.store.clip_config()?;
        self.clips.cleanup(&config, now)
    }

    /// Where the encrypted history stands.
    pub fn clip_vault_status(&self) -> Result<VaultStatus, CoreError> {
        self.clips.vault_status()
    }

    /// Hands over the 32-byte key kept in the Keychain (or None to forget it).
    pub fn clip_vault_set_key(&self, key: Option<Vec<u8>>) -> Result<VaultStatus, CoreError> {
        self.clips.vault_set_key(key)
    }

    /// Encrypts the history already saved and turns encryption on.
    pub fn clip_vault_enable(&self) -> Result<u32, CoreError> {
        self.clips.vault_enable()
    }

    /// Opens the history back into plain storage and turns encryption off.
    pub fn clip_vault_disable(&self) -> Result<u32, CoreError> {
        self.clips.vault_disable()
    }

    /// Removes all history and turns encryption off, for when the key is gone.
    pub fn clip_vault_reset(&self) -> Result<u32, CoreError> {
        self.clips.vault_reset()
    }

    /// Removes items labelled sensitive (pinned items and snippets stay).
    pub fn clip_purge_sensitive(&self) -> Result<u32, CoreError> {
        self.clips.purge_sensitive()
    }

    pub fn clip_export_snippets(&self, ids: Vec<String>) -> Result<String, CoreError> {
        self.clips.export_snippets(&ids)
    }

    pub fn clip_import_snippets(
        &self,
        json: String,
        now: i64,
    ) -> Result<SnippetImportSummary, CoreError> {
        self.clips.import_snippets(&json, now)
    }

    // ---- selection bar and approved scripts -----------------------------------------------------------------

    pub fn selection_config(&self) -> Result<SelectionConfig, CoreError> {
        self.store.selection_config()
    }

    pub fn save_selection_config(&self, config: SelectionConfig) -> Result<(), CoreError> {
        self.store.save_selection_config(&config)
    }

    pub fn selection_actions(&self) -> Result<Vec<SelectionAction>, CoreError> {
        self.store.selection_actions()
    }

    pub fn save_selection_actions(&self, list: Vec<SelectionAction>) -> Result<(), CoreError> {
        self.store.save_selection_actions(&list)
    }

    pub fn export_selection_actions(
        &self,
        ids: Vec<String>,
        name: String,
    ) -> Result<String, CoreError> {
        self.store.export_selection_actions(&ids, &name)
    }

    pub fn import_selection_actions(
        &self,
        json: String,
        now: i64,
    ) -> Result<Vec<SelectionAction>, CoreError> {
        self.store.import_selection_actions(&json, now)
    }

    pub fn restore_default_selection_settings(&self, everything: bool) -> Result<(), CoreError> {
        self.store.restore_default_selection_settings(everything)
    }

    pub fn approved_scripts(&self) -> Result<Vec<ApprovedScript>, CoreError> {
        self.store.approved_scripts()
    }

    pub fn is_script_approved(&self, fingerprint: String) -> Result<bool, CoreError> {
        self.store.is_script_approved(&fingerprint)
    }

    pub fn approve_script(
        &self,
        fingerprint: String,
        label: String,
        now: i64,
    ) -> Result<(), CoreError> {
        self.store.approve_script(&fingerprint, &label, now)
    }

    pub fn revoke_script(&self, fingerprint: String) -> Result<(), CoreError> {
        self.store.revoke_script(&fingerprint)
    }

    // ---- keyboard, shortcuts and text expansion -----------------------------------------------------------------

    pub fn keyboard_config(&self) -> Result<KeyboardConfig, CoreError> {
        self.store.keyboard_config()
    }

    pub fn save_keyboard_config(&self, config: KeyboardConfig) -> Result<(), CoreError> {
        self.store.save_keyboard_config(&config)
    }

    pub fn text_snippets(&self) -> Result<Vec<ExpansionSnippet>, CoreError> {
        self.store.text_snippets()
    }

    /// Saves a snippet. Returns warnings (an abbreviation cut short by a shorter one); a duplicate is an error.
    pub fn save_text_snippet(
        &self,
        snippet: ExpansionSnippet,
        now: i64,
    ) -> Result<Vec<SnippetConflict>, CoreError> {
        self.store.save_text_snippet(&snippet, now)
    }

    pub fn delete_text_snippet(&self, id: String) -> Result<(), CoreError> {
        self.store.delete_text_snippet(&id)
    }

    pub fn mark_text_snippet_used(&self, id: String) -> Result<(), CoreError> {
        self.store.mark_text_snippet_used(&id)
    }

    pub fn search_text_snippets(
        &self,
        query: String,
        category: Option<String>,
        favorites_only: bool,
        limit: u32,
    ) -> Result<Vec<ExpansionSnippet>, CoreError> {
        self.store
            .search_text_snippets(&query, category.as_deref(), favorites_only, limit as usize)
    }

    pub fn text_snippet_categories(&self) -> Result<Vec<String>, CoreError> {
        self.store.text_snippet_categories()
    }

    pub fn export_text_snippets(&self, ids: Vec<String>) -> Result<String, CoreError> {
        self.store.export_text_snippets(&ids)
    }

    pub fn import_text_snippets(
        &self,
        json: String,
        now: i64,
    ) -> Result<TextSnippetImportSummary, CoreError> {
        self.store.import_text_snippets(&json, now)
    }

    pub fn key_shortcuts(&self) -> Result<Vec<KeyShortcut>, CoreError> {
        self.store.key_shortcuts()
    }

    /// Saves the whole list. `reserved` is what the rest of Kriya uses, so a clash is refused.
    pub fn save_key_shortcuts(
        &self,
        list: Vec<KeyShortcut>,
        reserved: Vec<ReservedKey>,
    ) -> Result<(), CoreError> {
        self.store.save_key_shortcuts(&list, &reserved)
    }

    pub fn restore_default_keyboard_settings(&self, everything: bool) -> Result<(), CoreError> {
        self.store.restore_default_keyboard_settings(everything)
    }

    // ---- automation ------------------------------------------------------------------------------------------

    pub fn workflows(&self) -> Result<Vec<Workflow>, CoreError> {
        self.store.workflows()
    }

    pub fn save_workflow(&self, workflow: Workflow, now: i64) -> Result<Workflow, CoreError> {
        self.store.save_workflow(&workflow, now)
    }

    pub fn delete_workflow(&self, id: String) -> Result<(), CoreError> {
        self.store.delete_workflow(&id)
    }

    pub fn duplicate_workflow(
        &self,
        id: String,
        new_id: String,
        now: i64,
    ) -> Result<Workflow, CoreError> {
        self.store.duplicate_workflow(&id, &new_id, now)
    }

    pub fn set_workflow_enabled(&self, id: String, enabled: bool) -> Result<(), CoreError> {
        self.store.set_workflow_enabled(&id, enabled)
    }

    pub fn authorize_workflow(&self, id: String) -> Result<(), CoreError> {
        self.store.authorize_workflow(&id)
    }

    pub fn revoke_workflow_authorization(&self, id: String) -> Result<(), CoreError> {
        self.store.revoke_workflow_authorization(&id)
    }

    pub fn export_workflows(&self, ids: Vec<String>, now: i64) -> Result<String, CoreError> {
        self.store.export_workflows(&ids, now)
    }

    pub fn import_workflows(&self, json: String, now: i64) -> Result<Vec<Workflow>, CoreError> {
        self.store.import_workflows(&json, now)
    }

    pub fn clear_workflows(&self) -> Result<(), CoreError> {
        self.store.clear_workflows()
    }

    pub fn record_workflow_run(&self, run: WorkflowRun) -> Result<(), CoreError> {
        self.store.record_workflow_run(&run)
    }

    pub fn workflow_runs(
        &self,
        workflow_id: Option<String>,
        limit: u32,
    ) -> Result<Vec<WorkflowRun>, CoreError> {
        self.store
            .workflow_runs(workflow_id.as_deref(), limit as usize)
    }

    pub fn clear_workflow_runs(&self) -> Result<(), CoreError> {
        self.store.clear_workflow_runs()
    }

    // ---- backup ---------------------------------------------------------------------------------------------

    /// The backup as JSON text for the shell to save to a file.
    pub fn export_backup(&self, app_version: String, now: i64) -> Result<String, CoreError> {
        self.store.export_backup(&app_version, now)
    }

    /// Reads a backup without applying it, so the shell can show what it holds before asking to restore.
    pub fn inspect_backup(&self, json: String) -> Result<BackupSummary, CoreError> {
        backup::parse(&json).map(|f| f.summary())
    }

    pub fn import_backup(&self, json: String) -> Result<BackupSummary, CoreError> {
        self.store.import_backup(&json)
    }
}
