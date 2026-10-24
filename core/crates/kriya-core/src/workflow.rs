//! Automation: workflows made of a trigger, conditions and steps; the catalog every part of Kriya adds its actions to
//! (the one registry the visual builder reads); which steps need the person's authorization before they may run; and the
//! versioned packages used to share workflows. The shell carries the steps out; this module decides what a workflow is,
//! whether it may run, and in what shape its history is kept.

use std::collections::{HashMap, HashSet};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::actions::{self, Action};
use crate::clipboard::ClipKind;
use crate::error::CoreError;
use crate::finder::FinderScript;
use crate::model::FeatureId;
use crate::text_tools::{check_ops, TextOp};
use crate::windows::WindowLayout;

pub const SCHEMA_VERSION: u32 = 1;
pub const MANIFEST_VERSION: u32 = 1;
pub const PACKAGE_KIND: &str = "workflows";
pub const MAX_WORKFLOWS: usize = 200;
pub const MAX_STEPS: usize = 100;
pub const MAX_DELAY_MS: u32 = 60_000;
pub const DEFAULT_TIMEOUT_SECONDS: u32 = 60;
pub const MAX_TIMEOUT_SECONDS: u32 = 600;
/// A workflow may start another this many levels deep.
pub const MAX_CHAIN_DEPTH: u32 = 5;
pub const MAX_PACKAGE_BYTES: usize = 5 * 1024 * 1024;
pub const MAX_RUNS_KEPT: i64 = 300;
/// How many earlier saved versions of each workflow are kept.
pub const MAX_VERSIONS_KEPT: i64 = 20;
/// A step may be tried again this many times after it fails.
pub const MAX_RETRIES: u32 = 5;
pub const DEFAULT_RETRY_DELAY_MS: u32 = 1_000;
/// A loop runs its steps at most this many times.
pub const MAX_REPEAT: u32 = 100;
/// Steps that run side by side.
pub const MAX_PARALLEL: usize = 8;
/// Loops and parallel groups inside one another, at most this deep.
pub const MAX_NESTING: usize = 3;
/// The most conditions one if step can decide by.
pub const MAX_BRANCH_CONDITIONS: usize = 10;
pub const MAX_STEP_TIMEOUT_SECONDS: u32 = 600;
pub const MAX_VARIABLE_NAME: usize = 32;
pub const MAX_CHOICES: usize = 20;

// ---- conditions ------------------------------------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ConditionKind {
    FrontApp {
        app_ids: Vec<String>,
    },
    AppRunning {
        app_id: String,
    },
    /// Minutes since midnight. If the start is after the end the range wraps past midnight.
    TimeBetween {
        start_minute: u32,
        end_minute: u32,
    },
    /// 0 is Sunday.
    Weekdays {
        days: Vec<u8>,
    },
    /// A maximum of 0 means no upper limit.
    DisplayCount {
        min: u32,
        max: u32,
    },
    ClipboardContains {
        text: String,
        case_sensitive: bool,
    },
    FeatureEnabled {
        feature: FeatureId,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct ConditionItem {
    pub kind: ConditionKind,
    /// True when the condition must NOT hold.
    pub negate: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum ConditionMode {
    #[default]
    All,
    Any,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct ConditionGroup {
    pub mode: ConditionMode,
    pub items: Vec<ConditionItem>,
}

/// What the shell knows when it asks whether conditions hold.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct EvalContext {
    pub front_app: Option<String>,
    pub minute_of_day: u32,
    pub weekday: u8,
    pub display_count: u32,
    pub clipboard_text: Option<String>,
    pub enabled_features: Vec<FeatureId>,
    pub running_apps: Vec<String>,
}

fn holds(kind: &ConditionKind, ctx: &EvalContext) -> bool {
    match kind {
        ConditionKind::FrontApp { app_ids } => {
            ctx.front_app.as_ref().is_some_and(|a| app_ids.contains(a))
        }
        ConditionKind::AppRunning { app_id } => ctx.running_apps.contains(app_id),
        ConditionKind::TimeBetween {
            start_minute,
            end_minute,
        } => {
            let t = ctx.minute_of_day;
            if start_minute <= end_minute {
                t >= *start_minute && t < *end_minute
            } else {
                t >= *start_minute || t < *end_minute
            }
        }
        ConditionKind::Weekdays { days } => days.contains(&ctx.weekday),
        ConditionKind::DisplayCount { min, max } => {
            ctx.display_count >= *min && (*max == 0 || ctx.display_count <= *max)
        }
        ConditionKind::ClipboardContains {
            text,
            case_sensitive,
        } => ctx.clipboard_text.as_ref().is_some_and(|c| {
            if *case_sensitive {
                c.contains(text.as_str())
            } else {
                c.to_lowercase().contains(&text.to_lowercase())
            }
        }),
        ConditionKind::FeatureEnabled { feature } => ctx.enabled_features.contains(feature),
    }
}

/// Whether a group holds. A group with no conditions always does.
pub fn evaluate(group: &ConditionGroup, ctx: &EvalContext) -> bool {
    if group.items.is_empty() {
        return true;
    }
    let result = |i: &ConditionItem| holds(&i.kind, ctx) != i.negate;
    match group.mode {
        ConditionMode::All => group.items.iter().all(result),
        ConditionMode::Any => group.items.iter().any(result),
    }
}

// ---- triggers --------------------------------------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum Corner {
    TopLeft,
    TopRight,
    BottomLeft,
    BottomRight,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum Edge {
    Top,
    Bottom,
    Left,
    Right,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum TrackpadGesture {
    SwipeLeft,
    SwipeRight,
    SwipeUp,
    SwipeDown,
    PinchIn,
    PinchOut,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum WorkflowTrigger {
    /// Runs only when started: from a button, a keyboard shortcut or mouse rule that runs `workflow.<id>`, the Finder
    /// menu, the selection bar, the command launcher, or another workflow.
    Manual,
    Hotkey {
        key_code: u16,
        modifiers: u64,
    },
    /// Watches the button; the click still reaches the app.
    MouseButton {
        button: u32,
        modifiers: u64,
    },
    Trackpad {
        gesture: TrackpadGesture,
    },
    /// After a window is placed by Kriya, in any layout or a chosen one.
    WindowPlaced {
        layout: Option<WindowLayout>,
    },
    ClipboardChanged {
        kind: Option<ClipKind>,
        contains: Option<String>,
    },
    HotCorner {
        corner: Corner,
        dwell_ms: u32,
    },
    ScreenEdge {
        edge: Edge,
        dwell_ms: u32,
    },
    AppActivated {
        app_id: String,
    },
    AppLaunched {
        app_id: String,
    },
    AppQuit {
        app_id: String,
    },
    DisplayConnected,
    DisplayDisconnected,
    /// Every so many minutes while Kriya is running and the Mac is awake. The first run is one interval after it is turned on.
    Interval {
        minutes: u32,
    },
    /// At a time of day on chosen days (1 = Monday … 7 = Sunday; none chosen means every day). A time that passes while the Mac is
    /// asleep is run once when it wakes, if that is within 15 minutes.
    Daily {
        hour: u8,
        minute: u8,
        weekdays: Vec<u8>,
    },
    /// When a new item appears directly inside a folder (a file saved, downloaded or moved in). The workflow gets the new paths as
    /// its input, one per line.
    FolderChanged {
        path: String,
    },
}

impl WorkflowTrigger {
    pub fn title(&self) -> &'static str {
        match self {
            WorkflowTrigger::Manual => "Started by hand or by a shortcut",
            WorkflowTrigger::Hotkey { .. } => "A keyboard shortcut",
            WorkflowTrigger::MouseButton { .. } => "A mouse button",
            WorkflowTrigger::Trackpad { .. } => "A trackpad gesture",
            WorkflowTrigger::WindowPlaced { .. } => "A window is placed",
            WorkflowTrigger::ClipboardChanged { .. } => "Something is copied",
            WorkflowTrigger::HotCorner { .. } => "The pointer rests in a corner",
            WorkflowTrigger::ScreenEdge { .. } => "The pointer rests at a screen edge",
            WorkflowTrigger::AppActivated { .. } => "An app comes to the front",
            WorkflowTrigger::AppLaunched { .. } => "An app opens",
            WorkflowTrigger::AppQuit { .. } => "An app quits",
            WorkflowTrigger::DisplayConnected => "A display is connected",
            WorkflowTrigger::DisplayDisconnected => "A display is disconnected",
            WorkflowTrigger::Interval { .. } => "Every so often",
            WorkflowTrigger::Daily { .. } => "At a time of day",
            WorkflowTrigger::FolderChanged { .. } => "A new item appears in a folder",
        }
    }

    fn check(&self) -> Result<(), CoreError> {
        match self {
            WorkflowTrigger::Hotkey {
                key_code,
                modifiers,
            } => {
                if *key_code > 127 || modifiers & !actions::modifiers::ALL != 0 {
                    return Err(CoreError::invalid("the keyboard shortcut is not valid"));
                }
                if modifiers
                    & (actions::modifiers::COMMAND
                        | actions::modifiers::CONTROL
                        | actions::modifiers::OPTION)
                    == 0
                {
                    return Err(CoreError::invalid(
                        "a shortcut needs ⌘, ⌃ or ⌥ held with the key",
                    ));
                }
            }
            WorkflowTrigger::MouseButton { button, modifiers } => {
                if !(2..=31).contains(button) || modifiers & !actions::modifiers::ALL != 0 {
                    return Err(CoreError::invalid(
                        "choose the middle button or an extra button",
                    ));
                }
            }
            WorkflowTrigger::HotCorner { dwell_ms, .. }
            | WorkflowTrigger::ScreenEdge { dwell_ms, .. }
                if !(100..=5000).contains(dwell_ms) =>
            {
                return Err(CoreError::invalid(
                    "the wait should be between 100 ms and 5 seconds",
                ));
            }
            WorkflowTrigger::AppActivated { app_id }
            | WorkflowTrigger::AppLaunched { app_id }
            | WorkflowTrigger::AppQuit { app_id }
                if app_id.trim().is_empty() =>
            {
                return Err(CoreError::invalid("choose an app"));
            }
            WorkflowTrigger::Interval { minutes } if !(1..=1440).contains(minutes) => {
                return Err(CoreError::invalid("choose between 1 minute and 24 hours"));
            }
            WorkflowTrigger::Daily {
                hour,
                minute,
                weekdays,
            } => {
                if *hour > 23 || *minute > 59 {
                    return Err(CoreError::invalid("the time of day is not valid"));
                }
                if weekdays.iter().any(|d| !(1..=7).contains(d)) {
                    return Err(CoreError::invalid(
                        "a day should be from 1 (Monday) to 7 (Sunday)",
                    ));
                }
            }
            WorkflowTrigger::FolderChanged { path } => {
                let clean = path.trim();
                if clean.is_empty() {
                    return Err(CoreError::invalid("choose a folder"));
                }
                if !(clean.starts_with('/') || clean.starts_with("~/")) {
                    return Err(CoreError::invalid("give the folder's full path"));
                }
                if clean.split('/').any(|part| part == "..") || clean.contains('\0') {
                    return Err(CoreError::invalid(
                        "the folder path should not go up with ..",
                    ));
                }
            }
            _ => {}
        }
        Ok(())
    }
}

// ---- steps -----------------------------------------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum SystemOp {
    LockScreen,
    SleepDisplay,
    Sleep,
    StartScreenSaver,
    ToggleAppearance,
    Mute,
    Unmute,
    SetVolume,
    OpenSystemSettings,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum StepKind {
    /// Anything the shared action engine can do: open an app or address, run a Shortcut, press keys, a window command.
    Action {
        action: Action,
    },
    QuitApp {
        app_id: String,
        force: bool,
    },
    HideApp {
        app_id: String,
    },
    ActivateApp {
        app_id: String,
    },
    Script {
        language: FinderScript,
        source: String,
    },
    System {
        op: SystemOp,
        value: u32,
    },
    SwitchMousePreset {
        preset_id: String,
    },
    SetFeature {
        feature: FeatureId,
        enabled: bool,
    },
    SetClipboardPaused {
        paused: bool,
    },
    Delay {
        ms: u32,
    },
    /// Starts another workflow and waits for it.
    RunWorkflow {
        workflow_id: String,
    },
    Notify {
        message: String,
    },
    /// Changes the text the workflow was given (a selection, or what was copied).
    TextTransform {
        ops: Vec<TextOp>,
    },
    /// Copies text to the clipboard. `{selection}` stands for the workflow's current text.
    CopyText {
        template: String,
    },
    /// Types text into the app in front. `{selection}` stands for the workflow's current text.
    InsertText {
        template: String,
    },
    /// Keeps a value under a name for later steps. `{{name}}` in any text a step uses stands for it; `{{loop}}` is the
    /// number of the round a loop is on (from 1).
    SetVariable {
        name: String,
        template: String,
    },
    /// Runs the steps again and again, `times` times.
    Repeat {
        times: u32,
        steps: Vec<WorkflowStep>,
    },
    /// Runs the steps side by side and waits for all of them.
    Parallel {
        steps: Vec<WorkflowStep>,
    },
    /// Runs `then_steps` if the conditions hold and `else_steps` (which may be empty) if they do not.
    Branch {
        when: ConditionGroup,
        then_steps: Vec<WorkflowStep>,
        else_steps: Vec<WorkflowStep>,
    },
    /// Asks the person whether to go on. If they say no, the workflow stops.
    Confirm {
        message: String,
    },
    /// Asks the person for a line of text and keeps it under `variable`. Cancelling stops the workflow.
    Ask {
        prompt: String,
        variable: String,
    },
    /// Shows a short menu at the pointer and keeps the choice under `variable`. Cancelling stops the workflow.
    Choose {
        prompt: String,
        options: Vec<String>,
        variable: String,
    },
    /// Runs JavaScript on this Mac with no access to files, the network or other apps. `input` is the workflow's text, `vars`
    /// holds its variables, and the result becomes the workflow's text.
    JavaScript {
        source: String,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum StepRisk {
    Safe,
    /// Runs code, controls other apps or the system: the person must authorize the workflow first.
    NeedsAuthorization,
}

impl StepKind {
    pub fn risk(&self) -> StepRisk {
        use StepRisk::{NeedsAuthorization as Ask, Safe};
        match self {
            StepKind::Action { action } => match action {
                Action::RunShell { .. }
                | Action::RunScript { .. }
                | Action::KeyPress { .. }
                | Action::RunShortcut { .. } => Ask,
                Action::Sequence { steps, .. } => steps
                    .iter()
                    .map(|a| StepKind::Action { action: a.clone() }.risk())
                    .find(|r| *r == Ask)
                    .unwrap_or(Safe),
                _ => Safe,
            },
            StepKind::QuitApp { .. }
            | StepKind::Script { .. }
            | StepKind::System { .. }
            | StepKind::InsertText { .. }
            | StepKind::JavaScript { .. } => Ask,
            // A group is as risky as the riskiest step inside it.
            StepKind::Repeat { steps, .. } | StepKind::Parallel { steps } => steps
                .iter()
                .map(|s| s.kind.risk())
                .find(|r| *r == Ask)
                .unwrap_or(Safe),
            StepKind::Branch {
                then_steps,
                else_steps,
                ..
            } => then_steps
                .iter()
                .chain(else_steps.iter())
                .map(|s| s.kind.risk())
                .find(|r| *r == Ask)
                .unwrap_or(Safe),
            _ => Safe,
        }
    }

    pub fn summary(&self) -> String {
        match self {
            StepKind::Action { action } => describe_action(action),
            StepKind::QuitApp { app_id, force } => {
                format!("{} {app_id}", if *force { "Force quit" } else { "Quit" })
            }
            StepKind::HideApp { app_id } => format!("Hide {app_id}"),
            StepKind::ActivateApp { app_id } => format!("Bring {app_id} to the front"),
            StepKind::Script { language, source } => format!(
                "Run a {} script: {}",
                if *language == FinderScript::Shell {
                    "shell"
                } else {
                    "AppleScript"
                },
                first_line(source)
            ),
            StepKind::System { op, value } => match op {
                SystemOp::LockScreen => "Lock the screen".into(),
                SystemOp::SleepDisplay => "Put the display to sleep".into(),
                SystemOp::Sleep => "Put the Mac to sleep".into(),
                SystemOp::StartScreenSaver => "Start the screen saver".into(),
                SystemOp::ToggleAppearance => "Switch between light and dark".into(),
                SystemOp::Mute => "Mute the sound".into(),
                SystemOp::Unmute => "Unmute the sound".into(),
                SystemOp::SetVolume => format!("Set the volume to {value}%"),
                SystemOp::OpenSystemSettings => "Open System Settings".into(),
            },
            StepKind::SwitchMousePreset { preset_id } => format!("Use mouse preset {preset_id}"),
            StepKind::SetFeature { feature, enabled } => {
                format!("Turn {:?} {}", feature, if *enabled { "on" } else { "off" })
            }
            StepKind::SetClipboardPaused { paused } => (if *paused {
                "Pause clipboard recording"
            } else {
                "Resume clipboard recording"
            })
            .into(),
            StepKind::Delay { ms } => format!("Wait {:.1} s", f64::from(*ms) / 1000.0),
            StepKind::RunWorkflow { workflow_id } => format!("Run workflow {workflow_id}"),
            StepKind::Notify { message } => format!("Show “{message}”"),
            StepKind::TextTransform { ops } => format!(
                "Change the text: {}",
                ops.iter()
                    .map(TextOp::title)
                    .collect::<Vec<_>>()
                    .join(" → ")
            ),
            StepKind::CopyText { template } => format!("Copy “{}”", first_line(template)),
            StepKind::InsertText { template } => format!("Type “{}”", first_line(template)),
            StepKind::SetVariable { name, template } => {
                format!("Set {{{{{name}}}}} to “{}”", first_line(template))
            }
            StepKind::Repeat { times, steps } => format!(
                "Repeat {times} time{}: {} step{}",
                if *times == 1 { "" } else { "s" },
                steps.len(),
                if steps.len() == 1 { "" } else { "s" }
            ),
            StepKind::Parallel { steps } => {
                format!("Run {} steps at the same time", steps.len())
            }
            StepKind::Branch {
                then_steps,
                else_steps,
                ..
            } => {
                let plural = |n: usize| if n == 1 { "step" } else { "steps" };
                if else_steps.is_empty() {
                    format!(
                        "If its conditions hold: {} {}",
                        then_steps.len(),
                        plural(then_steps.len())
                    )
                } else {
                    format!(
                        "If its conditions hold: {} {}, otherwise {} {}",
                        then_steps.len(),
                        plural(then_steps.len()),
                        else_steps.len(),
                        plural(else_steps.len())
                    )
                }
            }
            StepKind::Confirm { message } => {
                format!("Ask “{}” before going on", first_line(message))
            }
            StepKind::Ask { prompt, variable } => {
                format!(
                    "Ask “{}” and keep it as {{{{{variable}}}}}",
                    first_line(prompt)
                )
            }
            StepKind::Choose {
                prompt, variable, ..
            } => format!(
                "Offer a menu “{}” and keep it as {{{{{variable}}}}}",
                first_line(prompt)
            ),
            StepKind::JavaScript { source } => format!("Run JavaScript: {}", first_line(source)),
        }
    }

    fn check(&self) -> Result<(), CoreError> {
        match self {
            StepKind::Action { action } => actions::validate(action)?,
            StepKind::QuitApp { app_id, .. }
            | StepKind::HideApp { app_id }
            | StepKind::ActivateApp { app_id }
                if app_id.trim().is_empty() =>
            {
                return Err(CoreError::invalid("choose an app"));
            }
            StepKind::Script { source, .. }
                if source.trim().is_empty() || source.len() > 100_000 =>
            {
                return Err(CoreError::invalid(
                    "a script step needs a script of a sensible length",
                ));
            }
            StepKind::System {
                op: SystemOp::SetVolume,
                value,
            } if *value > 100 => return Err(CoreError::invalid("the volume goes from 0 to 100")),
            StepKind::SwitchMousePreset { preset_id } if preset_id.trim().is_empty() => {
                return Err(CoreError::invalid("choose a mouse preset"))
            }
            StepKind::Delay { ms } if *ms > MAX_DELAY_MS => {
                return Err(CoreError::invalid("a pause can be up to 60 seconds"))
            }
            StepKind::RunWorkflow { workflow_id } if workflow_id.trim().is_empty() => {
                return Err(CoreError::invalid("choose a workflow"))
            }
            StepKind::Notify { message }
                if message.trim().is_empty() || message.chars().count() > 300 =>
            {
                return Err(CoreError::invalid("a message needs 1 to 300 characters"));
            }
            StepKind::TextTransform { ops } => check_ops(ops).map_err(CoreError::invalid)?,
            StepKind::CopyText { template } | StepKind::InsertText { template }
                if template.is_empty() || template.len() > 100_000 =>
            {
                return Err(CoreError::invalid("the text is empty or too long"));
            }
            StepKind::SetVariable { name, template } => {
                check_variable_name(name)?;
                if template.len() > 100_000 {
                    return Err(CoreError::invalid("the value is too long"));
                }
            }
            StepKind::Repeat { times, steps } => {
                if !(1..=MAX_REPEAT).contains(times) {
                    return Err(CoreError::invalid("a loop runs 1 to 100 times"));
                }
                if steps.is_empty() {
                    return Err(CoreError::invalid("a loop needs at least one step"));
                }
            }
            StepKind::Parallel { steps } => {
                if steps.len() < 2 || steps.len() > MAX_PARALLEL {
                    return Err(CoreError::invalid("steps side by side need 2 to 8 steps"));
                }
            }
            StepKind::Branch {
                when, then_steps, ..
            } => {
                if when.items.is_empty() || when.items.len() > MAX_BRANCH_CONDITIONS {
                    return Err(CoreError::invalid(
                        "an if step needs 1 to 10 conditions to decide by",
                    ));
                }
                if then_steps.is_empty() {
                    return Err(CoreError::invalid(
                        "an if step needs at least one step for when its conditions hold",
                    ));
                }
            }
            StepKind::Confirm { message }
                if message.trim().is_empty() || message.chars().count() > 300 =>
            {
                return Err(CoreError::invalid("a question needs 1 to 300 characters"));
            }
            StepKind::Ask { prompt, variable } => {
                if prompt.trim().is_empty() || prompt.chars().count() > 200 {
                    return Err(CoreError::invalid("a question needs 1 to 200 characters"));
                }
                check_variable_name(variable)?;
            }
            StepKind::Choose {
                prompt,
                options,
                variable,
            } => {
                if prompt.chars().count() > 200 {
                    return Err(CoreError::invalid("the title is at most 200 characters"));
                }
                if options.len() < 2 || options.len() > MAX_CHOICES {
                    return Err(CoreError::invalid("a menu needs 2 to 20 choices"));
                }
                if options
                    .iter()
                    .any(|o| o.trim().is_empty() || o.chars().count() > 80)
                {
                    return Err(CoreError::invalid("each choice needs 1 to 80 characters"));
                }
                check_variable_name(variable)?;
            }
            StepKind::JavaScript { source }
                if source.trim().is_empty() || source.len() > 100_000 =>
            {
                return Err(CoreError::invalid(
                    "a JavaScript step needs a script of a sensible length",
                ));
            }
            _ => {}
        }
        Ok(())
    }

    /// The steps inside a loop or a parallel group.
    pub fn children(&self) -> &[WorkflowStep] {
        match self {
            StepKind::Repeat { steps, .. } | StepKind::Parallel { steps } => steps,
            _ => &[],
        }
    }

    /// Every list of steps inside this one: a loop's or group's steps, or the "then" and "otherwise" steps of an if.
    pub fn branches(&self) -> Vec<&[WorkflowStep]> {
        match self {
            StepKind::Repeat { steps, .. } | StepKind::Parallel { steps } => vec![steps],
            StepKind::Branch {
                then_steps,
                else_steps,
                ..
            } => vec![then_steps, else_steps],
            _ => vec![],
        }
    }
}

/// A variable name is a letter or underscore, then letters, digits and underscores, up to 32 characters. `loop` is the
/// loop counter and cannot be set.
pub fn check_variable_name(name: &str) -> Result<(), CoreError> {
    let mut chars = name.chars();
    let ok = matches!(chars.next(), Some(c) if c.is_ascii_alphabetic() || c == '_')
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
        && name.len() <= MAX_VARIABLE_NAME;
    if !ok {
        return Err(CoreError::invalid(
            "a variable name is letters, digits and underscores, starting with a letter",
        ));
    }
    if name == "loop" {
        return Err(CoreError::invalid(
            "“loop” is the loop counter; pick another name",
        ));
    }
    Ok(())
}

/// Puts variables into text: each `{{name}}` becomes its value. A name without a value is left as it is, and a value is
/// never searched again, so a value that contains `{{other}}` stays as typed.
pub fn render_variables(template: &str, names: &[String], values: &[String]) -> String {
    let mut out = String::with_capacity(template.len());
    let mut rest = template;
    while let Some(start) = rest.find("{{") {
        out.push_str(&rest[..start]);
        let after = &rest[start + 2..];
        match after.find("}}") {
            Some(end) => {
                let name = after[..end].trim();
                match names.iter().position(|n| n == name) {
                    Some(i) => out.push_str(values.get(i).map(String::as_str).unwrap_or("")),
                    None => out.push_str(&rest[start..start + 2 + end + 2]),
                }
                rest = &after[end + 2..];
            }
            None => {
                out.push_str(&rest[start..]);
                rest = "";
            }
        }
    }
    out.push_str(rest);
    out
}

fn first_line(s: &str) -> String {
    let line = s.lines().next().unwrap_or("").trim();
    if line.chars().count() > 60 {
        format!("{}…", line.chars().take(60).collect::<String>())
    } else {
        line.to_string()
    }
}

fn describe_action(action: &Action) -> String {
    match action {
        Action::Noop => "Do nothing".into(),
        Action::KeyPress {
            key_code,
            modifiers,
        } => format!("Press key {key_code} with modifiers {modifiers}"),
        Action::Click { button, count, .. } => match (button, count) {
            (1, _) => "Right-click".into(),
            (_, 2) => "Double-click".into(),
            (_, 3) => "Triple-click".into(),
            _ => "Click".into(),
        },
        Action::OpenApplication { target } => format!("Open {target}"),
        Action::OpenUrl { url } => format!("Open {url}"),
        Action::RunShell { script } => format!("Run a shell command: {}", first_line(script)),
        Action::RunScript { source, .. } => format!("Run a script: {}", first_line(source)),
        Action::RunShortcut { name } => format!("Run the Shortcut “{name}”"),
        Action::Builtin { command } => format!("Command {command}"),
        Action::Sequence { steps, .. } => format!("{} actions in order", steps.len()),
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum OnError {
    /// The workflow ends and is marked failed.
    #[default]
    Stop,
    /// The failure is recorded and the next step runs.
    Continue,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct WorkflowStep {
    pub id: String,
    pub label: Option<String>,
    /// The step runs only if this holds. Several steps with opposite conditions make an "if … otherwise …".
    pub when: Option<ConditionGroup>,
    pub on_error: OnError,
    pub kind: StepKind,
    /// How many more times to try after a failure (0 to 5).
    #[serde(default)]
    #[uniffi(default = 0)]
    pub retries: u32,
    /// How long to wait between tries.
    #[serde(default = "default_retry_delay")]
    #[uniffi(default = 1000)]
    pub retry_delay_ms: u32,
    /// A time limit for this step alone, in seconds. None is only the workflow's limit.
    #[serde(default)]
    #[uniffi(default = None)]
    pub timeout_seconds: Option<u32>,
}

fn default_retry_delay() -> u32 {
    DEFAULT_RETRY_DELAY_MS
}

impl WorkflowStep {
    /// A plain step: no condition, stops the workflow if it fails, no retries.
    pub fn new(id: &str, kind: StepKind) -> Self {
        WorkflowStep {
            id: id.to_string(),
            label: None,
            when: None,
            on_error: OnError::Stop,
            kind,
            retries: 0,
            retry_delay_ms: DEFAULT_RETRY_DELAY_MS,
            timeout_seconds: None,
        }
    }

    pub fn title(&self) -> String {
        self.label
            .clone()
            .filter(|l| !l.trim().is_empty())
            .unwrap_or_else(|| self.kind.summary())
    }
}

// ---- the workflow ----------------------------------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
#[serde(default)]
pub struct Workflow {
    pub id: String,
    pub name: String,
    pub notes: Option<String>,
    pub enabled: bool,
    pub trigger: WorkflowTrigger,
    /// A condition for the whole workflow. If it does not hold when the trigger fires, nothing runs.
    pub conditions: Option<ConditionGroup>,
    pub steps: Vec<WorkflowStep>,
    pub timeout_seconds: u32,
    /// May a second run start while one is running?
    pub allow_parallel: bool,
    pub schema_version: u32,
    /// Counts saves, so history can say which version ran.
    pub revision: u32,
    /// The fingerprint the person authorized. If the workflow changes, it no longer matches and must be authorized again.
    pub authorized_fingerprint: Option<String>,
    pub created_at: i64,
    pub updated_at: i64,
    /// A name for the macro menu. A workflow with a group is offered in the menu that opens at the pointer.
    #[serde(default)]
    #[uniffi(default = None)]
    pub group: Option<String>,
    /// The apps whose macro menu offers this workflow. Empty means every app.
    #[serde(default)]
    #[uniffi(default = [])]
    pub app_ids: Vec<String>,
}

impl Default for Workflow {
    fn default() -> Self {
        Workflow {
            id: String::new(),
            name: String::new(),
            notes: None,
            enabled: false,
            trigger: WorkflowTrigger::Manual,
            conditions: None,
            steps: Vec::new(),
            timeout_seconds: DEFAULT_TIMEOUT_SECONDS,
            allow_parallel: false,
            schema_version: SCHEMA_VERSION,
            revision: 0,
            authorized_fingerprint: None,
            created_at: 0,
            updated_at: 0,
            group: None,
            app_ids: Vec::new(),
        }
    }
}

/// One workflow in the macro menu.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MacroItem {
    pub id: String,
    pub name: String,
}

/// A heading in the macro menu and the workflows under it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MacroGroup {
    pub name: String,
    /// Offered only in some apps, so the menu can show these first.
    pub app_specific: bool,
    pub items: Vec<MacroItem>,
}

/// The menu of macros for the app in front: the enabled workflows that have a group, those meant for this app first, then
/// those for every app. Within a group, by name.
pub fn macro_menu(all: &[Workflow], front_app: Option<&str>) -> Vec<MacroGroup> {
    let mut groups: Vec<MacroGroup> = Vec::new();
    let mut offered: Vec<&Workflow> = all
        .iter()
        .filter(|w| w.enabled && w.group.as_deref().is_some_and(|g| !g.trim().is_empty()))
        .filter(|w| {
            w.app_ids.is_empty() || front_app.is_some_and(|app| w.app_ids.iter().any(|a| a == app))
        })
        .collect();
    offered.sort_by_key(|w| w.name.to_lowercase());
    for w in offered {
        let name = w.group.clone().unwrap_or_default().trim().to_string();
        let specific = !w.app_ids.is_empty();
        let slot = groups
            .iter()
            .position(|g| g.name == name && g.app_specific == specific);
        let item = MacroItem {
            id: w.id.clone(),
            name: w.name.clone(),
        };
        match slot {
            Some(i) => groups[i].items.push(item),
            None => groups.push(MacroGroup {
                name,
                app_specific: specific,
                items: vec![item],
            }),
        }
    }
    groups.sort_by_key(|g| std::cmp::Reverse(g.app_specific));
    groups
}

impl Workflow {
    pub fn check(&self) -> Result<(), CoreError> {
        if self.id.trim().is_empty() {
            return Err(CoreError::invalid("a workflow needs an id"));
        }
        if self.name.trim().is_empty() || self.name.chars().count() > 80 {
            return Err(CoreError::invalid(
                "a workflow needs a name of up to 80 characters",
            ));
        }
        if self.steps.is_empty() {
            return Err(CoreError::invalid("add at least one step"));
        }
        if self.steps.len() > MAX_STEPS {
            return Err(CoreError::invalid("a workflow can have up to 100 steps"));
        }
        if !(1..=MAX_TIMEOUT_SECONDS).contains(&self.timeout_seconds) {
            return Err(CoreError::invalid(
                "the time limit should be between 1 and 600 seconds",
            ));
        }
        self.trigger.check()?;
        let mut ids = HashSet::new();
        let mut total = 0;
        check_steps(&self.steps, 0, &mut ids, &mut total, "")?;
        if total > MAX_STEPS {
            return Err(CoreError::invalid(
                "a workflow can have up to 100 steps, counting those inside loops",
            ));
        }
        Ok(())
    }

    /// Which workflows this one starts, including from inside loops.
    pub fn references(&self) -> Vec<String> {
        fn collect(steps: &[WorkflowStep], out: &mut Vec<String>) {
            for s in steps {
                if let StepKind::RunWorkflow { workflow_id } = &s.kind {
                    out.push(workflow_id.clone());
                }
                for inner in s.kind.branches() {
                    collect(inner, out);
                }
            }
        }
        let mut out = Vec::new();
        collect(&self.steps, &mut out);
        out
    }

    pub fn command(&self) -> String {
        format!("workflow.{}", self.id.to_lowercase())
    }
}

/// Checks steps and the steps inside them. `path` is "3." for the third step's children, so a message says where.
fn check_steps(
    steps: &[WorkflowStep],
    depth: usize,
    ids: &mut HashSet<String>,
    total: &mut usize,
    path: &str,
) -> Result<(), CoreError> {
    for (i, step) in steps.iter().enumerate() {
        *total += 1;
        let place = format!("{path}{}", i + 1);
        if step.id.trim().is_empty() || !ids.insert(step.id.clone()) {
            return Err(CoreError::invalid(format!("step {place} needs its own id")));
        }
        step.kind
            .check()
            .map_err(|e| CoreError::invalid(format!("step {place}: {e}")))?;
        if step.retries > MAX_RETRIES {
            return Err(CoreError::invalid(format!(
                "step {place}: it can be tried again up to {MAX_RETRIES} times"
            )));
        }
        if step.retry_delay_ms > MAX_DELAY_MS {
            return Err(CoreError::invalid(format!(
                "step {place}: the wait between tries can be up to 60 seconds"
            )));
        }
        if let Some(t) = step.timeout_seconds {
            if !(1..=MAX_STEP_TIMEOUT_SECONDS).contains(&t) {
                return Err(CoreError::invalid(format!(
                    "step {place}: the time limit should be between 1 and 600 seconds"
                )));
            }
        }
        let branches = step.kind.branches();
        if branches.iter().any(|b| !b.is_empty()) {
            if depth + 1 > MAX_NESTING {
                return Err(CoreError::invalid(format!(
                    "step {place}: loops and ifs can be inside each other up to {MAX_NESTING} levels"
                )));
            }
            for (n, inner) in branches.into_iter().enumerate() {
                let path = if n == 0 {
                    format!("{place}.")
                } else {
                    format!("{place}b.")
                };
                check_steps(inner, depth + 1, ids, total, &path)?;
            }
        }
    }
    Ok(())
}

/// What a workflow does, for deciding whether to trust it. The same content gives the same fingerprint, whatever its
/// name, notes, revision or on/off state.
pub fn fingerprint(w: &Workflow) -> String {
    #[derive(Serialize)]
    struct Body<'a> {
        trigger: &'a WorkflowTrigger,
        conditions: &'a Option<ConditionGroup>,
        steps: &'a [WorkflowStep],
        timeout_seconds: u32,
        allow_parallel: bool,
    }
    let json = serde_json::to_string(&Body {
        trigger: &w.trigger,
        conditions: &w.conditions,
        steps: &w.steps,
        timeout_seconds: w.timeout_seconds,
        allow_parallel: w.allow_parallel,
    })
    .unwrap_or_default();
    Sha256::digest(json.as_bytes())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Risk {
    pub step_index: u32,
    pub summary: String,
}

/// The steps that run code or control other apps or the system.
pub fn risks(w: &Workflow) -> Vec<Risk> {
    w.steps
        .iter()
        .enumerate()
        .filter(|(_, s)| s.kind.risk() == StepRisk::NeedsAuthorization)
        .map(|(i, s)| Risk {
            step_index: i as u32,
            summary: s.kind.summary(),
        })
        .collect()
}

/// Whether the person has to authorize the workflow before it may run.
pub fn needs_authorization(w: &Workflow) -> bool {
    !risks(w).is_empty() && w.authorized_fingerprint.as_deref() != Some(fingerprint(w).as_str())
}

/// A chain of workflows that starts itself, if there is one.
pub fn find_cycle(all: &[Workflow]) -> Option<Vec<String>> {
    let graph: HashMap<&str, Vec<String>> = all
        .iter()
        .map(|w| (w.id.as_str(), w.references()))
        .collect();
    fn visit<'a>(
        node: &'a str,
        graph: &'a HashMap<&str, Vec<String>>,
        path: &mut Vec<String>,
        done: &mut HashSet<String>,
    ) -> Option<Vec<String>> {
        if let Some(pos) = path.iter().position(|p| p == node) {
            let mut cycle = path[pos..].to_vec();
            cycle.push(node.to_string());
            return Some(cycle);
        }
        if done.contains(node) {
            return None;
        }
        path.push(node.to_string());
        for next in graph.get(node).into_iter().flatten() {
            if let Some(c) = visit(next.as_str(), graph, path, done) {
                return Some(c);
            }
        }
        path.pop();
        done.insert(node.to_string());
        None
    }
    let mut done = HashSet::new();
    for w in all {
        if let Some(c) = visit(&w.id, &graph, &mut Vec::new(), &mut done) {
            return Some(c);
        }
    }
    None
}

/// A copy to experiment with: new id, switched off, and not authorized.
pub fn duplicate(w: &Workflow, new_id: &str, now: i64) -> Workflow {
    Workflow {
        id: new_id.to_string(),
        name: format!("{} copy", w.name),
        enabled: false,
        authorized_fingerprint: None,
        revision: 0,
        created_at: now,
        updated_at: now,
        steps: renumber(&w.steps, &mut 0),
        ..w.clone()
    }
}

/// The same steps with new ids in order, including those inside loops.
fn renumber(steps: &[WorkflowStep], next: &mut usize) -> Vec<WorkflowStep> {
    steps
        .iter()
        .map(|s| {
            let id = format!("s{}", *next);
            *next += 1;
            let kind = match &s.kind {
                StepKind::Repeat { times, steps } => StepKind::Repeat {
                    times: *times,
                    steps: renumber(steps, next),
                },
                StepKind::Parallel { steps } => StepKind::Parallel {
                    steps: renumber(steps, next),
                },
                StepKind::Branch {
                    when,
                    then_steps,
                    else_steps,
                } => StepKind::Branch {
                    when: when.clone(),
                    then_steps: renumber(then_steps, next),
                    else_steps: renumber(else_steps, next),
                },
                other => other.clone(),
            };
            WorkflowStep {
                id,
                kind,
                ..s.clone()
            }
        })
        .collect()
}

// ---- templates and dependencies --------------------------------------------------------------------------------------

/// A ready-made workflow to start from. It is switched off and needs authorization like any other.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct WorkflowTemplate {
    pub title: String,
    pub description: String,
    pub workflow: Workflow,
}

pub fn templates() -> Vec<WorkflowTemplate> {
    let make = |title: &str, description: &str, steps: Vec<WorkflowStep>| WorkflowTemplate {
        title: title.into(),
        description: description.into(),
        workflow: Workflow {
            id: format!("template-{}", title.to_lowercase().replace(' ', "-")),
            name: title.into(),
            notes: Some(description.into()),
            steps,
            ..Workflow::default()
        },
    };
    let step = WorkflowStep::new;
    vec![
        make(
            "Search the web for what I type",
            "Asks for words, then searches DuckDuckGo for them in your browser.",
            vec![
                step(
                    "ask",
                    StepKind::Ask {
                        prompt: "Search the web for".into(),
                        variable: "query".into(),
                    },
                ),
                step(
                    "open",
                    StepKind::Action {
                        action: Action::OpenUrl {
                            url: "https://duckduckgo.com/?q={{query}}".into(),
                        },
                    },
                ),
            ],
        ),
        make(
            "Clean up the selected text",
            "Trims it, squeezes repeated spaces and drops blank lines, then copies the result.",
            vec![
                step(
                    "clean",
                    StepKind::TextTransform {
                        ops: vec![
                            TextOp::Trim,
                            TextOp::TrimLines,
                            TextOp::CollapseSpaces,
                            TextOp::RemoveBlankLines,
                        ],
                    },
                ),
                step(
                    "copy",
                    StepKind::CopyText {
                        template: "{selection}".into(),
                    },
                ),
                step(
                    "say",
                    StepKind::Notify {
                        message: "Cleaned text copied".into(),
                    },
                ),
            ],
        ),
        make(
            "Ask before locking the screen",
            "Shows a question first, so a stray shortcut cannot lock the screen.",
            vec![
                step(
                    "ask",
                    StepKind::Confirm {
                        message: "Lock the screen now?".into(),
                    },
                ),
                step(
                    "lock",
                    StepKind::System {
                        op: SystemOp::LockScreen,
                        value: 0,
                    },
                ),
            ],
        ),
        make(
            "Count to three",
            "A loop that shows {{loop}} each round: a starting point for your own loops.",
            vec![step(
                "loop",
                StepKind::Repeat {
                    times: 3,
                    steps: vec![
                        step(
                            "say",
                            StepKind::Notify {
                                message: "Round {{loop}}".into(),
                            },
                        ),
                        step("wait", StepKind::Delay { ms: 700 }),
                    ],
                },
            )],
        ),
        make(
            "Pick a name, then greet it",
            "Offers a small menu at the pointer and shows the choice.",
            vec![
                step(
                    "pick",
                    StepKind::Choose {
                        prompt: "Who?".into(),
                        options: vec!["Ann".into(), "Ben".into(), "Chen".into()],
                        variable: "name".into(),
                    },
                ),
                step(
                    "greet",
                    StepKind::Notify {
                        message: "Hello, {{name}}".into(),
                    },
                ),
            ],
        ),
        make(
            "Retry a flaky shell command",
            "Runs a command and tries again up to three times if it fails. Edit the command.",
            vec![{
                let mut run = step(
                    "run",
                    StepKind::Script {
                        language: FinderScript::Shell,
                        source: "echo hello".into(),
                    },
                );
                run.retries = 3;
                run.retry_delay_ms = 2000;
                run.timeout_seconds = Some(30);
                run
            }],
        ),
    ]
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum DependencyKind {
    Workflow,
    App,
    Shortcut,
    Command,
}

/// Something a workflow needs outside itself.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WorkflowDependency {
    pub kind: DependencyKind,
    /// A workflow id, an app identifier, a Shortcut name or a command name.
    pub name: String,
    /// Only decided for workflows; the caller checks whether an app, Shortcut or command exists.
    pub missing: bool,
}

/// What a workflow needs: other workflows (and whether they exist among `known_ids`), apps it quits, hides or brings forward,
/// Shortcuts it runs and commands it calls, each once, inside loops too.
pub fn dependencies(w: &Workflow, known_ids: &[String]) -> Vec<WorkflowDependency> {
    fn add(out: &mut Vec<WorkflowDependency>, kind: DependencyKind, name: &str, missing: bool) {
        if !name.is_empty() && !out.iter().any(|d| d.kind == kind && d.name == name) {
            out.push(WorkflowDependency {
                kind,
                name: name.to_string(),
                missing,
            });
        }
    }
    fn walk(steps: &[WorkflowStep], known: &[String], out: &mut Vec<WorkflowDependency>) {
        for s in steps {
            match &s.kind {
                StepKind::RunWorkflow { workflow_id } => add(
                    out,
                    DependencyKind::Workflow,
                    workflow_id,
                    !known.contains(workflow_id),
                ),
                StepKind::QuitApp { app_id, .. }
                | StepKind::HideApp { app_id }
                | StepKind::ActivateApp { app_id } => add(out, DependencyKind::App, app_id, false),
                StepKind::Action { action } => match action {
                    Action::RunShortcut { name } => add(out, DependencyKind::Shortcut, name, false),
                    Action::OpenApplication { target } => {
                        add(out, DependencyKind::App, target, false)
                    }
                    Action::Builtin { command } => {
                        add(out, DependencyKind::Command, command, false)
                    }
                    _ => {}
                },
                _ => {}
            }
            for inner in s.kind.branches() {
                walk(inner, known, out);
            }
        }
    }
    let mut out = Vec::new();
    walk(&w.steps, known_ids, &mut out);
    out
}

/// What a package holds, found without importing anything.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PackageReport {
    pub workflows: Vec<String>,
    /// Steps that run code or control other apps or the system, as "Workflow: step".
    pub risky_steps: Vec<String>,
    /// Workflows started from inside the package that are in neither the package nor `existing_ids`.
    pub missing_workflows: Vec<String>,
    /// Problems that would stop the import, in words.
    pub problems: Vec<String>,
}

/// Reads a package and says what importing it would bring in, without changing anything.
pub fn package_report(json: &str, existing_ids: &[String]) -> PackageReport {
    let mut report = PackageReport {
        workflows: Vec::new(),
        risky_steps: Vec::new(),
        missing_workflows: Vec::new(),
        problems: Vec::new(),
    };
    match import_package(json, existing_ids, 0) {
        Err(e) => report.problems.push(e.to_string()),
        Ok(imported) => {
            let ids: Vec<String> = imported
                .iter()
                .map(|w| w.id.clone())
                .chain(existing_ids.iter().cloned())
                .collect();
            for w in &imported {
                report.workflows.push(w.name.clone());
                for r in risks(w) {
                    report
                        .risky_steps
                        .push(format!("{}: {}", w.name, r.summary));
                }
                for d in dependencies(w, &ids) {
                    if d.kind == DependencyKind::Workflow
                        && d.missing
                        && !report.missing_workflows.contains(&d.name)
                    {
                        report.missing_workflows.push(d.name);
                    }
                }
            }
        }
    }
    report
}

// ---- history ---------------------------------------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum RunStatus {
    Succeeded,
    Failed,
    Cancelled,
    TimedOut,
    /// Not started: it needed authorization, was already running, or fired too often.
    Blocked,
    /// The conditions did not hold.
    Skipped,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum StepStatus {
    Ok,
    Skipped,
    Failed,
    Cancelled,
    /// A dry run: described, not carried out.
    Planned,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct StepResult {
    pub index: u32,
    pub title: String,
    pub status: StepStatus,
    pub message: Option<String>,
    pub duration_ms: u32,
}

/// One run. It records what happened, never the text a workflow was working on.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct WorkflowRun {
    pub id: String,
    pub workflow_id: String,
    pub workflow_name: String,
    pub revision: u32,
    /// What started it, in words ("Keyboard shortcut", "Test run").
    pub trigger: String,
    pub started_at: i64,
    pub duration_ms: u32,
    pub status: RunStatus,
    pub error: Option<String>,
    pub steps: Vec<StepResult>,
    pub test: bool,
}

// ---- the catalog (the registry the builder reads) ---------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct StepTemplate {
    pub category: String,
    pub title: String,
    pub symbol: String,
    pub kind: StepKind,
    pub risk: StepRisk,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TriggerTemplate {
    pub category: String,
    pub title: String,
    pub symbol: String,
    pub trigger: WorkflowTrigger,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ConditionTemplate {
    pub title: String,
    pub kind: ConditionKind,
}

pub fn step_catalog() -> Vec<StepTemplate> {
    let t = |category: &str, title: &str, symbol: &str, kind: StepKind| {
        let risk = kind.risk();
        StepTemplate {
            category: category.into(),
            title: title.into(),
            symbol: symbol.into(),
            kind,
            risk,
        }
    };
    let act = |a: Action| StepKind::Action { action: a };
    let cmd = actions::modifiers::COMMAND;
    vec![
        t(
            "Apps",
            "Open an app",
            "app",
            act(Action::OpenApplication {
                target: String::new(),
            }),
        ),
        t(
            "Apps",
            "Quit an app",
            "power",
            StepKind::QuitApp {
                app_id: String::new(),
                force: false,
            },
        ),
        t(
            "Apps",
            "Hide an app",
            "eye.slash",
            StepKind::HideApp {
                app_id: String::new(),
            },
        ),
        t(
            "Apps",
            "Bring an app to the front",
            "macwindow",
            StepKind::ActivateApp {
                app_id: String::new(),
            },
        ),
        t(
            "Apps",
            "Open a web address",
            "link",
            act(Action::OpenUrl {
                url: "https://".into(),
            }),
        ),
        t(
            "Windows",
            "Move or resize the front window",
            "rectangle.split.2x1",
            act(Action::Builtin {
                command: "window.left_half".into(),
            }),
        ),
        t(
            "Windows",
            "Restore a saved window layout",
            "rectangle.3.group",
            act(Action::Builtin {
                command: "window.layout.".into(),
            }),
        ),
        t(
            "Input",
            "Press a key combination",
            "keyboard",
            act(Action::KeyPress {
                key_code: 0,
                modifiers: cmd,
            }),
        ),
        t(
            "Input",
            "Type text",
            "text.cursor",
            StepKind::InsertText {
                template: String::new(),
            },
        ),
        t(
            "Input",
            "Copy text to the clipboard",
            "doc.on.clipboard",
            StepKind::CopyText {
                template: String::new(),
            },
        ),
        t(
            "Flow",
            "Keep a value in a variable",
            "character.textbox",
            StepKind::SetVariable {
                name: "value".into(),
                template: String::new(),
            },
        ),
        t(
            "Flow",
            "Repeat steps",
            "repeat",
            StepKind::Repeat {
                times: 3,
                steps: vec![WorkflowStep::new("r1", StepKind::Delay { ms: 500 })],
            },
        ),
        t(
            "Flow",
            "If … otherwise",
            "arrow.triangle.branch",
            StepKind::Branch {
                when: ConditionGroup {
                    mode: ConditionMode::All,
                    items: vec![ConditionItem {
                        kind: ConditionKind::FrontApp { app_ids: vec![] },
                        negate: false,
                    }],
                },
                then_steps: vec![WorkflowStep::new("t1", StepKind::Delay { ms: 500 })],
                else_steps: vec![],
            },
        ),
        t(
            "Flow",
            "Run steps at the same time",
            "arrow.triangle.branch",
            StepKind::Parallel {
                steps: vec![
                    WorkflowStep::new("p1", StepKind::Delay { ms: 500 }),
                    WorkflowStep::new("p2", StepKind::Delay { ms: 500 }),
                ],
            },
        ),
        t(
            "Flow",
            "Ask before going on",
            "questionmark.circle",
            StepKind::Confirm {
                message: "Go on?".into(),
            },
        ),
        t(
            "Flow",
            "Ask for a line of text",
            "text.bubble",
            StepKind::Ask {
                prompt: "What should it use?".into(),
                variable: "answer".into(),
            },
        ),
        t(
            "Flow",
            "Offer a menu to choose from",
            "list.bullet.rectangle",
            StepKind::Choose {
                prompt: "Choose".into(),
                options: vec!["One".into(), "Two".into()],
                variable: "choice".into(),
            },
        ),
        t(
            "Scripts",
            "Run JavaScript",
            "curlybraces",
            StepKind::JavaScript {
                source: "input.toUpperCase()".into(),
            },
        ),
        t(
            "Text",
            "Change the text",
            "textformat",
            StepKind::TextTransform {
                ops: vec![TextOp::Trim],
            },
        ),
        t(
            "Scripts",
            "Run a shell script",
            "terminal",
            StepKind::Script {
                language: FinderScript::Shell,
                source: String::new(),
            },
        ),
        t(
            "Scripts",
            "Run an AppleScript",
            "applescript",
            StepKind::Script {
                language: FinderScript::AppleScript,
                source: String::new(),
            },
        ),
        t(
            "Scripts",
            "Run an Apple Shortcut",
            "square.2.layers.3d",
            act(Action::RunShortcut {
                name: String::new(),
            }),
        ),
        t(
            "System",
            "Lock the screen",
            "lock",
            StepKind::System {
                op: SystemOp::LockScreen,
                value: 0,
            },
        ),
        t(
            "System",
            "Put the display to sleep",
            "display",
            StepKind::System {
                op: SystemOp::SleepDisplay,
                value: 0,
            },
        ),
        t(
            "System",
            "Put the Mac to sleep",
            "moon.zzz",
            StepKind::System {
                op: SystemOp::Sleep,
                value: 0,
            },
        ),
        t(
            "System",
            "Start the screen saver",
            "sparkles.tv",
            StepKind::System {
                op: SystemOp::StartScreenSaver,
                value: 0,
            },
        ),
        t(
            "System",
            "Switch between light and dark",
            "circle.lefthalf.filled",
            StepKind::System {
                op: SystemOp::ToggleAppearance,
                value: 0,
            },
        ),
        t(
            "System",
            "Mute the sound",
            "speaker.slash",
            StepKind::System {
                op: SystemOp::Mute,
                value: 0,
            },
        ),
        t(
            "System",
            "Unmute the sound",
            "speaker.wave.2",
            StepKind::System {
                op: SystemOp::Unmute,
                value: 0,
            },
        ),
        t(
            "System",
            "Set the volume",
            "speaker.wave.1",
            StepKind::System {
                op: SystemOp::SetVolume,
                value: 50,
            },
        ),
        t(
            "System",
            "Open System Settings",
            "gearshape",
            StepKind::System {
                op: SystemOp::OpenSystemSettings,
                value: 0,
            },
        ),
        t(
            "Kriya",
            "Use a mouse preset",
            "computermouse",
            StepKind::SwitchMousePreset {
                preset_id: String::new(),
            },
        ),
        t(
            "Kriya",
            "Turn a feature on or off",
            "switch.2",
            StepKind::SetFeature {
                feature: FeatureId::Mouse,
                enabled: true,
            },
        ),
        t(
            "Kriya",
            "Pause clipboard recording",
            "pause.circle",
            StepKind::SetClipboardPaused { paused: true },
        ),
        t("Flow", "Wait", "timer", StepKind::Delay { ms: 1000 }),
        t(
            "Flow",
            "Run another workflow",
            "arrow.triangle.branch",
            StepKind::RunWorkflow {
                workflow_id: String::new(),
            },
        ),
        t(
            "Flow",
            "Show a message",
            "bubble.left",
            StepKind::Notify {
                message: String::new(),
            },
        ),
    ]
}

pub fn trigger_catalog() -> Vec<TriggerTemplate> {
    let t = |category: &str, symbol: &str, trigger: WorkflowTrigger| TriggerTemplate {
        category: category.into(),
        title: trigger.title().into(),
        symbol: symbol.into(),
        trigger,
    };
    let co = actions::modifiers::CONTROL | actions::modifiers::OPTION;
    vec![
        t("Manual", "hand.tap", WorkflowTrigger::Manual),
        t(
            "Keyboard",
            "keyboard",
            WorkflowTrigger::Hotkey {
                key_code: 0,
                modifiers: co,
            },
        ),
        t(
            "Mouse",
            "computermouse",
            WorkflowTrigger::MouseButton {
                button: 3,
                modifiers: 0,
            },
        ),
        t(
            "Trackpad",
            "hand.draw",
            WorkflowTrigger::Trackpad {
                gesture: TrackpadGesture::SwipeLeft,
            },
        ),
        t(
            "Windows",
            "rectangle.split.2x1",
            WorkflowTrigger::WindowPlaced { layout: None },
        ),
        t(
            "Clipboard",
            "doc.on.clipboard",
            WorkflowTrigger::ClipboardChanged {
                kind: None,
                contains: None,
            },
        ),
        t(
            "Screen",
            "rectangle.topthird.inset.filled",
            WorkflowTrigger::HotCorner {
                corner: Corner::TopRight,
                dwell_ms: 600,
            },
        ),
        t(
            "Screen",
            "rectangle.leadinghalf.inset.filled",
            WorkflowTrigger::ScreenEdge {
                edge: Edge::Left,
                dwell_ms: 800,
            },
        ),
        t(
            "Apps",
            "app",
            WorkflowTrigger::AppActivated {
                app_id: String::new(),
            },
        ),
        t(
            "Apps",
            "app.badge.checkmark",
            WorkflowTrigger::AppLaunched {
                app_id: String::new(),
            },
        ),
        t(
            "Apps",
            "xmark.app",
            WorkflowTrigger::AppQuit {
                app_id: String::new(),
            },
        ),
        t("Displays", "display", WorkflowTrigger::DisplayConnected),
        t(
            "Displays",
            "display.slash",
            WorkflowTrigger::DisplayDisconnected,
        ),
        t("Time", "clock", WorkflowTrigger::Interval { minutes: 60 }),
        t(
            "Time",
            "calendar.badge.clock",
            WorkflowTrigger::Daily {
                hour: 9,
                minute: 0,
                weekdays: vec![],
            },
        ),
        t(
            "Files",
            "folder.badge.plus",
            WorkflowTrigger::FolderChanged {
                path: String::new(),
            },
        ),
    ]
}

pub fn condition_catalog() -> Vec<ConditionTemplate> {
    let c = |title: &str, kind: ConditionKind| ConditionTemplate {
        title: title.into(),
        kind,
    };
    vec![
        c(
            "The app in front is…",
            ConditionKind::FrontApp { app_ids: vec![] },
        ),
        c(
            "An app is running",
            ConditionKind::AppRunning {
                app_id: String::new(),
            },
        ),
        c(
            "The time is between…",
            ConditionKind::TimeBetween {
                start_minute: 9 * 60,
                end_minute: 17 * 60,
            },
        ),
        c(
            "It is one of these days",
            ConditionKind::Weekdays {
                days: vec![1, 2, 3, 4, 5],
            },
        ),
        c(
            "Number of displays",
            ConditionKind::DisplayCount { min: 2, max: 0 },
        ),
        c(
            "The clipboard contains…",
            ConditionKind::ClipboardContains {
                text: String::new(),
                case_sensitive: false,
            },
        ),
        c(
            "A Kriya feature is on",
            ConditionKind::FeatureEnabled {
                feature: FeatureId::Mouse,
            },
        ),
    ]
}

// ---- sharing, with versions ------------------------------------------------------------------------------------------------

#[derive(Debug, Serialize, Deserialize)]
struct Package {
    manifest_version: u32,
    app: String,
    kind: String,
    exported_at: i64,
    workflows: Vec<serde_json::Value>,
}

pub fn export_package(workflows: &[Workflow], now: i64) -> Result<String, CoreError> {
    let cleaned: Vec<serde_json::Value> = workflows
        .iter()
        .cloned()
        .map(|mut w| {
            w.authorized_fingerprint = None;
            w.enabled = false;
            serde_json::to_value(w)
        })
        .collect::<Result<_, _>>()?;
    Ok(serde_json::to_string_pretty(&Package {
        manifest_version: MANIFEST_VERSION,
        app: crate::backup::BACKUP_APP_NAME.to_string(),
        kind: PACKAGE_KIND.to_string(),
        exported_at: now,
        workflows: cleaned,
    })?)
}

/// Brings a workflow written by an older version up to date. A newer one is refused.
pub fn migrate(value: serde_json::Value) -> Result<Workflow, String> {
    let version = value
        .get("schema_version")
        .and_then(serde_json::Value::as_u64)
        .unwrap_or(0);
    if version > u64::from(SCHEMA_VERSION) {
        return Err("a workflow was made by a newer version of Kriya".into());
    }
    // Version 0 had no schema_version or revision; every other field has a default, so it reads as it is.
    let mut w: Workflow =
        serde_json::from_value(value).map_err(|e| format!("a workflow could not be read: {e}"))?;
    w.schema_version = SCHEMA_VERSION;
    Ok(w)
}

/// Reads a package. Every workflow is migrated and checked; they come in switched off and not authorized, with new ids
/// where the id is already used, so importing never changes or runs anything by itself.
pub fn import_package(
    json: &str,
    existing_ids: &[String],
    now: i64,
) -> Result<Vec<Workflow>, CoreError> {
    let bad = |message: &str| CoreError::Backup {
        message: message.to_string(),
    };
    if json.len() > MAX_PACKAGE_BYTES {
        return Err(bad("the file is not a Kriya workflow package"));
    }
    let package: Package =
        serde_json::from_str(json).map_err(|_| bad("the file is not a Kriya workflow package"))?;
    if package.app != crate::backup::BACKUP_APP_NAME || package.kind != PACKAGE_KIND {
        return Err(bad("the file is not a Kriya workflow package"));
    }
    if package.manifest_version > MANIFEST_VERSION {
        return Err(bad("the package was made by a newer version of Kriya"));
    }
    if package.workflows.is_empty() || package.workflows.len() > MAX_WORKFLOWS {
        return Err(bad("the package holds no workflows, or too many"));
    }
    let mut taken: HashSet<String> = existing_ids.iter().cloned().collect();
    let mut remap: HashMap<String, String> = HashMap::new();
    let mut out = Vec::new();
    for (i, value) in package.workflows.into_iter().enumerate() {
        let mut w = migrate(value).map_err(|m| CoreError::Backup { message: m })?;
        let old = w.id.clone();
        if taken.contains(&w.id) {
            w.id = format!("{}-imp-{now:x}-{i}", old);
        }
        taken.insert(w.id.clone());
        remap.insert(old, w.id.clone());
        w.enabled = false;
        w.authorized_fingerprint = None;
        w.revision = 0;
        w.created_at = now;
        w.updated_at = now;
        out.push(w);
    }
    // Workflows in the package that start each other keep doing so under their new ids.
    for w in &mut out {
        for step in &mut w.steps {
            if let StepKind::RunWorkflow { workflow_id } = &mut step.kind {
                if let Some(new) = remap.get(workflow_id.as_str()) {
                    *workflow_id = new.clone();
                }
            }
        }
        w.check().map_err(|e| CoreError::Backup {
            message: e.to_string(),
        })?;
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::actions::modifiers as m;

    fn step(id: &str, kind: StepKind) -> WorkflowStep {
        WorkflowStep::new(id, kind)
    }

    fn workflow(id: &str, steps: Vec<WorkflowStep>) -> Workflow {
        Workflow {
            id: id.into(),
            name: format!("Workflow {id}"),
            steps,
            enabled: true,
            ..Workflow::default()
        }
    }

    fn ctx() -> EvalContext {
        EvalContext {
            front_app: Some("com.apple.Safari".into()),
            minute_of_day: 10 * 60,
            weekday: 2,
            display_count: 2,
            clipboard_text: Some("Hello World".into()),
            enabled_features: vec![FeatureId::Mouse],
            running_apps: vec!["com.apple.mail".into()],
        }
    }

    fn group(mode: ConditionMode, items: Vec<(ConditionKind, bool)>) -> ConditionGroup {
        ConditionGroup {
            mode,
            items: items
                .into_iter()
                .map(|(kind, negate)| ConditionItem { kind, negate })
                .collect(),
        }
    }

    #[test]
    fn conditions_are_evaluated_against_the_situation() {
        let c = ctx();
        let t = |k: ConditionKind| group(ConditionMode::All, vec![(k, false)]);
        assert!(evaluate(
            &t(ConditionKind::FrontApp {
                app_ids: vec!["com.apple.Safari".into()]
            }),
            &c
        ));
        assert!(!evaluate(
            &t(ConditionKind::FrontApp {
                app_ids: vec!["com.other".into()]
            }),
            &c
        ));
        assert!(evaluate(
            &t(ConditionKind::AppRunning {
                app_id: "com.apple.mail".into()
            }),
            &c
        ));
        assert!(evaluate(
            &t(ConditionKind::TimeBetween {
                start_minute: 9 * 60,
                end_minute: 17 * 60
            }),
            &c
        ));
        assert!(!evaluate(
            &t(ConditionKind::TimeBetween {
                start_minute: 11 * 60,
                end_minute: 17 * 60
            }),
            &c
        ));
        assert!(evaluate(
            &t(ConditionKind::Weekdays {
                days: vec![1, 2, 3]
            }),
            &c
        ));
        assert!(evaluate(
            &t(ConditionKind::DisplayCount { min: 2, max: 0 }),
            &c
        ));
        assert!(!evaluate(
            &t(ConditionKind::DisplayCount { min: 3, max: 0 }),
            &c
        ));
        assert!(!evaluate(
            &t(ConditionKind::DisplayCount { min: 0, max: 1 }),
            &c
        ));
        assert!(evaluate(
            &t(ConditionKind::ClipboardContains {
                text: "hello".into(),
                case_sensitive: false
            }),
            &c
        ));
        assert!(!evaluate(
            &t(ConditionKind::ClipboardContains {
                text: "hello".into(),
                case_sensitive: true
            }),
            &c
        ));
        assert!(evaluate(
            &t(ConditionKind::FeatureEnabled {
                feature: FeatureId::Mouse
            }),
            &c
        ));
        assert!(!evaluate(
            &t(ConditionKind::FeatureEnabled {
                feature: FeatureId::Clipboard
            }),
            &c
        ));
    }

    #[test]
    fn a_time_range_can_wrap_past_midnight() {
        let night = ConditionKind::TimeBetween {
            start_minute: 22 * 60,
            end_minute: 6 * 60,
        };
        let at = |minute: u32| {
            evaluate(
                &group(ConditionMode::All, vec![(night.clone(), false)]),
                &EvalContext {
                    minute_of_day: minute,
                    ..ctx()
                },
            )
        };
        assert!(at(23 * 60) && at(2 * 60) && !at(12 * 60) && !at(6 * 60));
    }

    #[test]
    fn groups_combine_all_any_and_not() {
        let c = ctx();
        let yes = ConditionKind::AppRunning {
            app_id: "com.apple.mail".into(),
        };
        let no = ConditionKind::AppRunning {
            app_id: "com.nothing".into(),
        };
        assert!(
            evaluate(&group(ConditionMode::All, vec![]), &c),
            "no conditions always hold"
        );
        assert!(!evaluate(
            &group(
                ConditionMode::All,
                vec![(yes.clone(), false), (no.clone(), false)]
            ),
            &c
        ));
        assert!(evaluate(
            &group(
                ConditionMode::Any,
                vec![(yes.clone(), false), (no.clone(), false)]
            ),
            &c
        ));
        assert!(
            evaluate(
                &group(ConditionMode::All, vec![(yes, false), (no, true)]),
                &c
            ),
            "not running"
        );
        assert!(!evaluate(
            &group(
                ConditionMode::Any,
                vec![(ConditionKind::Weekdays { days: vec![] }, false)]
            ),
            &c
        ));
    }

    #[test]
    fn risky_steps_are_found_and_safe_ones_are_not() {
        let safe = workflow(
            "a",
            vec![
                step(
                    "1",
                    StepKind::Action {
                        action: Action::OpenUrl {
                            url: "https://example.com".into(),
                        },
                    },
                ),
                step(
                    "2",
                    StepKind::Notify {
                        message: "hi".into(),
                    },
                ),
                step("3", StepKind::HideApp { app_id: "x".into() }),
                step("4", StepKind::SetClipboardPaused { paused: true }),
            ],
        );
        assert!(risks(&safe).is_empty());
        assert!(!needs_authorization(&safe));
        let risky = workflow(
            "b",
            vec![
                step(
                    "1",
                    StepKind::Action {
                        action: Action::RunShell {
                            script: "ls".into(),
                        },
                    },
                ),
                step(
                    "2",
                    StepKind::QuitApp {
                        app_id: "x".into(),
                        force: false,
                    },
                ),
                step(
                    "3",
                    StepKind::Script {
                        language: FinderScript::AppleScript,
                        source: "beep".into(),
                    },
                ),
                step(
                    "4",
                    StepKind::System {
                        op: SystemOp::Sleep,
                        value: 0,
                    },
                ),
                step(
                    "5",
                    StepKind::Action {
                        action: Action::KeyPress {
                            key_code: 0,
                            modifiers: m::COMMAND,
                        },
                    },
                ),
                step(
                    "6",
                    StepKind::Action {
                        action: Action::RunShortcut { name: "x".into() },
                    },
                ),
                step(
                    "7",
                    StepKind::Action {
                        action: Action::Sequence {
                            steps: vec![
                                Action::Noop,
                                Action::RunShell {
                                    script: "ls".into(),
                                },
                            ],
                            delay_ms: 0,
                        },
                    },
                ),
            ],
        );
        assert_eq!(risks(&risky).len(), 7);
        assert!(needs_authorization(&risky));
    }

    #[test]
    fn authorization_belongs_to_the_exact_content() {
        let mut w = workflow(
            "a",
            vec![step(
                "1",
                StepKind::Script {
                    language: FinderScript::Shell,
                    source: "echo hi".into(),
                },
            )],
        );
        assert!(needs_authorization(&w));
        w.authorized_fingerprint = Some(fingerprint(&w));
        assert!(!needs_authorization(&w));
        let mut renamed = w.clone();
        renamed.name = "Other name".into();
        renamed.notes = Some("notes".into());
        renamed.enabled = false;
        renamed.revision = 9;
        assert!(
            !needs_authorization(&renamed),
            "name, notes, on/off and revision are not content"
        );
        let mut edited = w.clone();
        edited.steps[0].kind = StepKind::Script {
            language: FinderScript::Shell,
            source: "echo hi; rm -rf ~".into(),
        };
        assert!(
            needs_authorization(&edited),
            "an edited script must be authorized again"
        );
        let mut retimed = w.clone();
        retimed.trigger = WorkflowTrigger::AppActivated { app_id: "x".into() };
        assert!(
            needs_authorization(&retimed),
            "a new trigger is new content"
        );
    }

    #[test]
    fn workflows_are_validated() {
        let ok = workflow("a", vec![step("1", StepKind::Delay { ms: 100 })]);
        assert!(ok.check().is_ok());
        assert!(workflow("a", vec![]).check().is_err());
        assert!(
            workflow(
                "a",
                vec![
                    step("1", StepKind::Delay { ms: 100 }),
                    step("1", StepKind::Delay { ms: 100 })
                ]
            )
            .check()
            .is_err(),
            "duplicate step ids"
        );
        assert!(
            workflow("a", vec![step("1", StepKind::Delay { ms: 999_999 })])
                .check()
                .is_err()
        );
        assert!(workflow(
            "a",
            vec![step(
                "1",
                StepKind::QuitApp {
                    app_id: " ".into(),
                    force: false
                }
            )]
        )
        .check()
        .is_err());
        assert!(workflow(
            "a",
            vec![step(
                "1",
                StepKind::Action {
                    action: Action::OpenUrl {
                        url: "javascript:1".into()
                    }
                }
            )]
        )
        .check()
        .is_err());
        assert!(Workflow {
            timeout_seconds: 0,
            ..ok.clone()
        }
        .check()
        .is_err());
        assert!(Workflow {
            timeout_seconds: 9999,
            ..ok.clone()
        }
        .check()
        .is_err());
        assert!(Workflow {
            name: " ".into(),
            ..ok.clone()
        }
        .check()
        .is_err());
        assert!(Workflow {
            trigger: WorkflowTrigger::Hotkey {
                key_code: 0,
                modifiers: 0
            },
            ..ok.clone()
        }
        .check()
        .is_err());
        assert!(
            Workflow {
                trigger: WorkflowTrigger::MouseButton {
                    button: 0,
                    modifiers: 0
                },
                ..ok.clone()
            }
            .check()
            .is_err(),
            "the left button cannot be a trigger"
        );
        assert!(Workflow {
            trigger: WorkflowTrigger::HotCorner {
                corner: Corner::TopLeft,
                dwell_ms: 5
            },
            ..ok.clone()
        }
        .check()
        .is_err());
        assert!(Workflow {
            trigger: WorkflowTrigger::AppQuit {
                app_id: String::new()
            },
            ..ok
        }
        .check()
        .is_err());
    }

    #[test]
    fn workflows_that_start_themselves_are_found() {
        let a = workflow(
            "a",
            vec![step(
                "1",
                StepKind::RunWorkflow {
                    workflow_id: "b".into(),
                },
            )],
        );
        let b = workflow(
            "b",
            vec![step(
                "1",
                StepKind::RunWorkflow {
                    workflow_id: "c".into(),
                },
            )],
        );
        let c = workflow("c", vec![step("1", StepKind::Delay { ms: 1 })]);
        assert_eq!(find_cycle(&[a.clone(), b.clone(), c.clone()]), None);
        let looped = workflow(
            "c",
            vec![step(
                "1",
                StepKind::RunWorkflow {
                    workflow_id: "a".into(),
                },
            )],
        );
        let cycle = find_cycle(&[a.clone(), b, looped]).unwrap();
        assert_eq!(cycle.first(), cycle.last());
        let selfish = workflow(
            "s",
            vec![step(
                "1",
                StepKind::RunWorkflow {
                    workflow_id: "s".into(),
                },
            )],
        );
        assert!(find_cycle(&[selfish]).is_some());
        assert_eq!(a.references(), vec!["b".to_string()]);
    }

    #[test]
    fn a_copy_is_off_unauthorized_and_independent() {
        let mut w = workflow(
            "a",
            vec![step(
                "x",
                StepKind::Script {
                    language: FinderScript::Shell,
                    source: "echo".into(),
                },
            )],
        );
        w.authorized_fingerprint = Some(fingerprint(&w));
        w.revision = 4;
        let copy = duplicate(&w, "b", 99);
        assert_eq!(
            (copy.id.as_str(), copy.enabled, copy.revision),
            ("b", false, 0)
        );
        assert_eq!(copy.name, "Workflow a copy");
        assert!(copy.authorized_fingerprint.is_none() && needs_authorization(&copy));
        assert_eq!(fingerprint(&copy).len(), 64);
    }

    #[test]
    fn the_catalog_covers_every_kind_of_step_and_is_all_valid() {
        let steps = step_catalog();
        assert!(steps.len() >= 25);
        for t in &steps {
            assert_eq!(t.risk, t.kind.risk(), "{} reports its risk", t.title);
            assert!(!t.title.is_empty() && !t.category.is_empty() && !t.symbol.is_empty());
            assert!(!t.kind.summary().is_empty());
        }
        let categories: HashSet<_> = steps.iter().map(|t| t.category.as_str()).collect();
        for needed in [
            "Apps", "Windows", "Input", "Scripts", "System", "Flow", "Kriya", "Text",
        ] {
            assert!(categories.contains(needed), "missing {needed}");
        }
        assert!(trigger_catalog().len() >= 13);
        assert!(trigger_catalog().iter().all(|t| t.trigger.check().is_ok()
            || matches!(
                t.trigger,
                WorkflowTrigger::Hotkey { .. }
                    | WorkflowTrigger::AppActivated { .. }
                    | WorkflowTrigger::AppLaunched { .. }
                    | WorkflowTrigger::AppQuit { .. }
                    | WorkflowTrigger::FolderChanged { .. }
            )));
        assert!(condition_catalog().len() >= 7);
    }

    #[test]
    fn time_and_folder_triggers_are_checked() {
        assert!(WorkflowTrigger::Interval { minutes: 1 }.check().is_ok());
        assert!(WorkflowTrigger::Interval { minutes: 1440 }.check().is_ok());
        assert!(WorkflowTrigger::Interval { minutes: 0 }.check().is_err());
        assert!(WorkflowTrigger::Interval { minutes: 1441 }.check().is_err());
        let daily = |hour, minute, weekdays: Vec<u8>| WorkflowTrigger::Daily {
            hour,
            minute,
            weekdays,
        };
        assert!(daily(0, 0, vec![]).check().is_ok());
        assert!(daily(23, 59, vec![1, 2, 3, 4, 5]).check().is_ok());
        assert!(daily(24, 0, vec![]).check().is_err());
        assert!(daily(9, 60, vec![]).check().is_err());
        assert!(daily(9, 0, vec![0]).check().is_err());
        assert!(daily(9, 0, vec![8]).check().is_err());
        let folder = |p: &str| WorkflowTrigger::FolderChanged { path: p.into() };
        assert!(folder("/Users/me/Downloads").check().is_ok());
        assert!(folder("~/Downloads").check().is_ok());
        assert!(folder("").check().is_err());
        assert!(folder("   ").check().is_err());
        assert!(folder("Downloads").check().is_err());
        assert!(folder("/Users/me/../../etc").check().is_err());
        assert!(folder("~/Downloads/../../etc").check().is_err());
        // They survive a save and a load, and have names a person can read.
        for trigger in [
            WorkflowTrigger::Interval { minutes: 15 },
            daily(8, 30, vec![1, 3, 5]),
            folder("~/Downloads"),
        ] {
            let json = serde_json::to_string(&trigger).unwrap();
            assert_eq!(
                serde_json::from_str::<WorkflowTrigger>(&json).unwrap(),
                trigger
            );
            assert!(!trigger.title().is_empty());
        }
        let titles: Vec<_> = trigger_catalog()
            .iter()
            .map(|t| t.trigger.title())
            .collect();
        assert!(titles.contains(&"Every so often"));
        assert!(titles.contains(&"At a time of day"));
        assert!(titles.contains(&"A new item appears in a folder"));
    }

    #[test]
    fn packages_round_trip_with_new_ids_and_nothing_enabled_or_authorized() {
        let mut a = workflow(
            "a",
            vec![step(
                "1",
                StepKind::RunWorkflow {
                    workflow_id: "b".into(),
                },
            )],
        );
        let mut b = workflow(
            "b",
            vec![step(
                "1",
                StepKind::Script {
                    language: FinderScript::Shell,
                    source: "echo hi".into(),
                },
            )],
        );
        b.authorized_fingerprint = Some(fingerprint(&b));
        a.enabled = true;
        let json = export_package(&[a, b], 5).unwrap();
        assert!(
            !json.contains(&fingerprint(&workflow(
                "b",
                vec![step(
                    "1",
                    StepKind::Script {
                        language: FinderScript::Shell,
                        source: "echo hi".into()
                    }
                )]
            ))),
            "authorization does not travel"
        );

        let imported = import_package(&json, &["a".to_string()], 255).unwrap();
        assert_eq!(imported.len(), 2);
        assert!(imported
            .iter()
            .all(|w| !w.enabled && w.authorized_fingerprint.is_none() && w.revision == 0));
        assert_eq!(imported[0].id, "a-imp-ff-0", "a clashing id is replaced");
        assert_eq!(imported[1].id, "b");
        assert_eq!(imported[0].references(), vec!["b".to_string()]);
        assert!(needs_authorization(&imported[1]));
    }

    #[test]
    fn imports_repoint_chained_workflows_when_their_ids_change() {
        let a = workflow(
            "a",
            vec![step(
                "1",
                StepKind::RunWorkflow {
                    workflow_id: "b".into(),
                },
            )],
        );
        let b = workflow("b", vec![step("1", StepKind::Delay { ms: 1 })]);
        let json = export_package(&[a, b], 1).unwrap();
        let imported = import_package(&json, &["b".to_string()], 16).unwrap();
        assert_eq!(imported[1].id, "b-imp-10-1");
        assert_eq!(imported[0].references(), vec!["b-imp-10-1".to_string()]);
    }

    #[test]
    fn old_versions_are_migrated_and_newer_ones_refused() {
        let old = serde_json::json!({"id": "old", "name": "Old", "steps": [{"id": "1", "label": null, "when": null, "on_error": "stop", "kind": {"type": "delay", "ms": 5}}]});
        let w = migrate(old).unwrap();
        assert_eq!(
            (w.schema_version, w.revision, w.timeout_seconds),
            (SCHEMA_VERSION, 0, DEFAULT_TIMEOUT_SECONDS)
        );
        assert!(migrate(serde_json::json!({"id": "x", "schema_version": 99})).is_err());
        assert!(migrate(serde_json::json!({"id": 5})).is_err());
    }

    #[test]
    fn bad_packages_are_refused() {
        let w = workflow("a", vec![step("1", StepKind::Delay { ms: 1 })]);
        let json = export_package(&[w], 1).unwrap();
        assert!(import_package("{}", &[], 1).is_err());
        assert!(import_package(&json.replace("\"workflows\":", "\"x\":"), &[], 1).is_err());
        assert!(import_package(&json.replace(PACKAGE_KIND, "other"), &[], 1).is_err());
        assert!(import_package(
            &json.replace("\"manifest_version\": 1", "\"manifest_version\": 2"),
            &[],
            1
        )
        .is_err());
        assert!(
            import_package(&json.replace("\"ms\": 1", "\"ms\": 999999"), &[], 1).is_err(),
            "a step that is not valid is refused"
        );
        assert!(import_package(&export_package(&[], 1).unwrap(), &[], 1).is_err());
    }

    fn names(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn variables_are_put_into_text_once() {
        let n = names(&["who", "n"]);
        let v = names(&["World", "3"]);
        assert_eq!(
            render_variables("Hi {{who}} x{{ n }}", &n, &v),
            "Hi World x3"
        );
        assert_eq!(
            render_variables("{{missing}} stays", &n, &v),
            "{{missing}} stays"
        );
        // A value that looks like a variable is not expanded again.
        let v2 = names(&["{{n}}", "3"]);
        assert_eq!(render_variables("{{who}}", &n, &v2), "{{n}}");
        assert_eq!(render_variables("open {{ brace", &n, &v), "open {{ brace");
        assert_eq!(render_variables("", &n, &v), "");
        assert_eq!(render_variables("é{{who}}é", &n, &v), "éWorldé");
    }

    #[test]
    fn variable_names_are_checked() {
        for good in ["a", "_x", "Name_2", "a_very_long_name_of_thirty_two_ch"] {
            if good.len() <= 32 {
                assert!(check_variable_name(good).is_ok(), "{good}");
            }
        }
        for bad in ["", "2a", "a b", "a-b", "loop", &"x".repeat(33), "é"] {
            assert!(check_variable_name(bad).is_err(), "{bad}");
        }
    }

    fn repeat(times: u32, steps: Vec<WorkflowStep>) -> StepKind {
        StepKind::Repeat { times, steps }
    }

    #[test]
    fn loops_and_parallel_groups_are_checked_inside() {
        let ok = workflow(
            "a",
            vec![step(
                "1",
                repeat(3, vec![step("2", StepKind::Delay { ms: 10 })]),
            )],
        );
        assert!(ok.check().is_ok());
        let empty = workflow("a", vec![step("1", repeat(3, vec![]))]);
        assert!(empty.check().is_err());
        let zero = workflow(
            "a",
            vec![step(
                "1",
                repeat(0, vec![step("2", StepKind::Delay { ms: 1 })]),
            )],
        );
        assert!(zero.check().is_err());
        let too_many = workflow(
            "a",
            vec![step(
                "1",
                repeat(101, vec![step("2", StepKind::Delay { ms: 1 })]),
            )],
        );
        assert!(too_many.check().is_err());
        let bad_inner = workflow(
            "a",
            vec![step(
                "1",
                repeat(
                    2,
                    vec![step(
                        "2",
                        StepKind::Delay {
                            ms: MAX_DELAY_MS + 1,
                        },
                    )],
                ),
            )],
        );
        let message = bad_inner.check().unwrap_err().to_string();
        assert!(message.contains("step 1.1"), "{message}");
        let clash = workflow(
            "a",
            vec![step(
                "1",
                repeat(2, vec![step("1", StepKind::Delay { ms: 1 })]),
            )],
        );
        assert!(clash.check().is_err(), "ids are unique across nested steps");
        let lone = workflow(
            "a",
            vec![step(
                "1",
                StepKind::Parallel {
                    steps: vec![step("2", StepKind::Delay { ms: 1 })],
                },
            )],
        );
        assert!(lone.check().is_err(), "parallel needs at least two steps");
    }

    fn if_step(then_steps: Vec<WorkflowStep>, else_steps: Vec<WorkflowStep>) -> StepKind {
        StepKind::Branch {
            when: group(
                ConditionMode::All,
                vec![(
                    ConditionKind::FrontApp {
                        app_ids: vec!["com.apple.Safari".into()],
                    },
                    false,
                )],
            ),
            then_steps,
            else_steps,
        }
    }

    #[test]
    fn an_if_step_needs_a_condition_and_something_to_do() {
        let ok = if_step(
            vec![step("a", StepKind::Delay { ms: 1 })],
            vec![step("b", StepKind::Delay { ms: 1 })],
        );
        assert!(workflow("w", vec![step("i", ok)]).check().is_ok());
        let no_else = if_step(vec![step("a", StepKind::Delay { ms: 1 })], vec![]);
        assert!(
            workflow("w", vec![step("i", no_else)]).check().is_ok(),
            "otherwise may be empty"
        );
        let nothing = if_step(vec![], vec![step("b", StepKind::Delay { ms: 1 })]);
        assert!(workflow("w", vec![step("i", nothing)]).check().is_err());
        let no_condition = StepKind::Branch {
            when: ConditionGroup {
                mode: ConditionMode::All,
                items: vec![],
            },
            then_steps: vec![step("a", StepKind::Delay { ms: 1 })],
            else_steps: vec![],
        };
        assert!(workflow("w", vec![step("i", no_condition)])
            .check()
            .is_err());
    }

    #[test]
    fn ids_must_be_unique_across_both_sides_of_an_if() {
        let clash = if_step(
            vec![step("same", StepKind::Delay { ms: 1 })],
            vec![step("same", StepKind::Delay { ms: 1 })],
        );
        assert!(workflow("w", vec![step("i", clash)]).check().is_err());
    }

    #[test]
    fn an_if_is_as_risky_as_the_riskiest_side_and_says_what_it_holds() {
        let risky = StepKind::Script {
            language: crate::finder::FinderScript::Shell,
            source: "ls".into(),
        };
        let a = if_step(
            vec![step("a", StepKind::Delay { ms: 1 })],
            vec![step("b", risky)],
        );
        assert_eq!(
            a.risk(),
            StepRisk::NeedsAuthorization,
            "the otherwise side counts too"
        );
        let b = if_step(vec![step("a", StepKind::Delay { ms: 1 })], vec![]);
        assert_eq!(b.risk(), StepRisk::Safe);
        assert_eq!(b.summary(), "If its conditions hold: 1 step");
        let c = if_step(
            vec![
                step("a", StepKind::Delay { ms: 1 }),
                step("c", StepKind::Delay { ms: 1 }),
            ],
            vec![step("b", StepKind::Delay { ms: 1 })],
        );
        assert_eq!(
            c.summary(),
            "If its conditions hold: 2 steps, otherwise 1 step"
        );
    }

    #[test]
    fn workflows_started_inside_an_if_are_found_and_ids_are_renumbered() {
        let inside = if_step(
            vec![step(
                "a",
                StepKind::RunWorkflow {
                    workflow_id: "one".into(),
                },
            )],
            vec![step(
                "b",
                StepKind::RunWorkflow {
                    workflow_id: "two".into(),
                },
            )],
        );
        let w = workflow("w", vec![step("i", inside)]);
        assert_eq!(w.references(), vec!["one".to_string(), "two".to_string()]);
        let copy = duplicate(&w, "w2", 5);
        assert!(copy.check().is_ok(), "no id clashes after renumbering");
        if let StepKind::Branch {
            then_steps,
            else_steps,
            ..
        } = &copy.steps[0].kind
        {
            assert_eq!(then_steps[0].id, "s1");
            assert_eq!(else_steps[0].id, "s2");
        } else {
            panic!("the copy lost its if step");
        }
    }

    #[test]
    fn an_if_counts_as_a_level_of_nesting() {
        let mut inner = step("deep", StepKind::Delay { ms: 1 });
        for level in 0..=MAX_NESTING {
            inner = step(&format!("l{level}"), if_step(vec![inner], vec![]));
        }
        assert!(workflow("a", vec![inner]).check().is_err());
    }

    #[test]
    fn nesting_is_limited() {
        let mut inner = step("deep", StepKind::Delay { ms: 1 });
        for level in 0..=MAX_NESTING {
            inner = step(&format!("l{level}"), repeat(2, vec![inner]));
        }
        assert!(workflow("a", vec![inner]).check().is_err());
        let mut fine = step("deep", StepKind::Delay { ms: 1 });
        for level in 0..MAX_NESTING {
            fine = step(&format!("l{level}"), repeat(2, vec![fine]));
        }
        assert!(workflow("a", vec![fine]).check().is_ok());
    }

    #[test]
    fn steps_inside_loops_count_toward_the_limit() {
        let inner: Vec<_> = (0..MAX_STEPS)
            .map(|i| step(&format!("i{i}"), StepKind::Delay { ms: 1 }))
            .collect();
        assert!(workflow("a", vec![step("outer", repeat(2, inner))])
            .check()
            .is_err());
    }

    #[test]
    fn a_loop_is_as_risky_as_what_is_inside() {
        let safe = repeat(2, vec![step("2", StepKind::Delay { ms: 1 })]);
        assert_eq!(safe.risk(), StepRisk::Safe);
        let risky = repeat(
            2,
            vec![step(
                "2",
                StepKind::Script {
                    language: FinderScript::Shell,
                    source: "ls".into(),
                },
            )],
        );
        assert_eq!(risky.risk(), StepRisk::NeedsAuthorization);
        assert_eq!(
            StepKind::JavaScript { source: "1".into() }.risk(),
            StepRisk::NeedsAuthorization
        );
        let w = workflow("a", vec![step("1", risky)]);
        assert!(needs_authorization(&w));
    }

    #[test]
    fn workflows_started_from_inside_a_loop_are_found() {
        let w = workflow(
            "a",
            vec![step(
                "1",
                repeat(
                    2,
                    vec![step(
                        "2",
                        StepKind::RunWorkflow {
                            workflow_id: "b".into(),
                        },
                    )],
                ),
            )],
        );
        assert_eq!(w.references(), vec!["b".to_string()]);
        let b = workflow(
            "b",
            vec![step(
                "1",
                StepKind::RunWorkflow {
                    workflow_id: "a".into(),
                },
            )],
        );
        assert!(
            find_cycle(&[w, b]).is_some(),
            "a cycle through a loop is still a cycle"
        );
    }

    #[test]
    fn retries_and_step_time_limits_are_checked() {
        let mut s = step("1", StepKind::Delay { ms: 1 });
        s.retries = MAX_RETRIES;
        s.timeout_seconds = Some(30);
        assert!(workflow("a", vec![s.clone()]).check().is_ok());
        s.retries = MAX_RETRIES + 1;
        assert!(workflow("a", vec![s.clone()]).check().is_err());
        s.retries = 1;
        s.timeout_seconds = Some(0);
        assert!(workflow("a", vec![s.clone()]).check().is_err());
        s.timeout_seconds = Some(MAX_STEP_TIMEOUT_SECONDS + 1);
        assert!(workflow("a", vec![s.clone()]).check().is_err());
        s.timeout_seconds = None;
        s.retry_delay_ms = MAX_DELAY_MS + 1;
        assert!(workflow("a", vec![s]).check().is_err());
    }

    #[test]
    fn prompts_and_menus_are_checked() {
        let ask = |p: &str, v: &str| {
            step(
                "1",
                StepKind::Ask {
                    prompt: p.into(),
                    variable: v.into(),
                },
            )
        };
        assert!(workflow("a", vec![ask("Name?", "who")]).check().is_ok());
        assert!(workflow("a", vec![ask("", "who")]).check().is_err());
        assert!(workflow("a", vec![ask("Name?", "loop")]).check().is_err());
        let choose = |options: Vec<&str>| {
            step(
                "1",
                StepKind::Choose {
                    prompt: "Pick".into(),
                    options: options.into_iter().map(String::from).collect(),
                    variable: "c".into(),
                },
            )
        };
        assert!(workflow("a", vec![choose(vec!["a", "b"])]).check().is_ok());
        assert!(workflow("a", vec![choose(vec!["a"])]).check().is_err());
        assert!(workflow("a", vec![choose(vec!["a", " "])]).check().is_err());
        assert!(workflow(
            "a",
            vec![step(
                "1",
                StepKind::Confirm {
                    message: "Sure?".into()
                }
            )]
        )
        .check()
        .is_ok());
        assert!(workflow(
            "a",
            vec![step(
                "1",
                StepKind::Confirm {
                    message: " ".into()
                }
            )]
        )
        .check()
        .is_err());
        assert!(workflow(
            "a",
            vec![step("1", StepKind::JavaScript { source: " ".into() })]
        )
        .check()
        .is_err());
    }

    #[test]
    fn a_duplicate_renumbers_steps_inside_loops_too() {
        let w = workflow(
            "a",
            vec![
                step(
                    "x",
                    repeat(
                        2,
                        vec![
                            step("y", StepKind::Delay { ms: 1 }),
                            step("s0", StepKind::Delay { ms: 1 }),
                        ],
                    ),
                ),
                step("z", StepKind::Delay { ms: 1 }),
            ],
        );
        assert!(w.check().is_ok());
        let copy = duplicate(&w, "b", 5);
        assert!(copy.check().is_ok(), "no id clashes after renumbering");
        let ids: Vec<_> = copy.steps[0]
            .kind
            .children()
            .iter()
            .map(|s| s.id.clone())
            .collect();
        assert_eq!(ids, vec!["s1".to_string(), "s2".to_string()]);
    }

    #[test]
    fn the_macro_menu_offers_grouped_workflows_for_the_front_app() {
        let mut a = workflow("a", vec![step("1", StepKind::Delay { ms: 1 })]);
        a.name = "Zoom in".into();
        a.group = Some("View".into());
        let mut b = workflow("b", vec![step("1", StepKind::Delay { ms: 1 })]);
        b.name = "Export".into();
        b.group = Some("File".into());
        b.app_ids = vec!["com.apple.Safari".into()];
        let mut c = workflow("c", vec![step("1", StepKind::Delay { ms: 1 })]);
        c.name = "Another".into();
        c.group = Some("File".into());
        c.app_ids = vec!["com.apple.Safari".into()];
        let mut off = workflow("d", vec![step("1", StepKind::Delay { ms: 1 })]);
        off.group = Some("File".into());
        off.enabled = false;
        let ungrouped = workflow("e", vec![step("1", StepKind::Delay { ms: 1 })]);
        let all = vec![a, b, c, off, ungrouped];

        let safari = macro_menu(&all, Some("com.apple.Safari"));
        assert_eq!(safari.len(), 2);
        assert_eq!(safari[0].name, "File", "this app's groups come first");
        assert!(safari[0].app_specific);
        assert_eq!(
            safari[0]
                .items
                .iter()
                .map(|i| i.name.as_str())
                .collect::<Vec<_>>(),
            vec!["Another", "Export"],
            "by name"
        );
        assert_eq!(safari[1].name, "View");

        let other = macro_menu(&all, Some("com.apple.Notes"));
        assert_eq!(other.len(), 1, "app-specific macros are hidden elsewhere");
        assert_eq!(other[0].name, "View");
        assert!(macro_menu(&all, None).iter().all(|g| !g.app_specific));
    }

    #[test]
    fn every_template_is_valid_off_and_unauthorized() {
        let all = templates();
        assert!(all.len() >= 5);
        let mut ids = HashSet::new();
        for t in &all {
            let mut w = t.workflow.clone();
            assert!(w.check().is_ok(), "{}: {:?}", t.title, w.check());
            assert!(
                !w.enabled && w.authorized_fingerprint.is_none(),
                "{}",
                t.title
            );
            assert!(ids.insert(w.id.clone()), "ids differ: {}", w.id);
            assert!(!t.description.is_empty());
            // Ask and Choose templates keep their variable names valid.
            w.id = "x".into();
        }
        // The shell template needs authorization, the safe ones do not.
        assert!(all.iter().any(|t| needs_authorization(&t.workflow)));
        assert!(all.iter().any(|t| !needs_authorization(&t.workflow)));
    }

    #[test]
    fn dependencies_list_what_a_workflow_needs_once_each() {
        let mut w = workflow(
            "a",
            vec![
                step(
                    "1",
                    StepKind::RunWorkflow {
                        workflow_id: "b".into(),
                    },
                ),
                step(
                    "2",
                    StepKind::RunWorkflow {
                        workflow_id: "gone".into(),
                    },
                ),
                step(
                    "3",
                    repeat(
                        2,
                        vec![
                            step(
                                "4",
                                StepKind::RunWorkflow {
                                    workflow_id: "b".into(),
                                },
                            ),
                            step(
                                "5",
                                StepKind::QuitApp {
                                    app_id: "com.x.App".into(),
                                    force: false,
                                },
                            ),
                            step(
                                "6",
                                StepKind::Action {
                                    action: Action::RunShortcut {
                                        name: "My Shortcut".into(),
                                    },
                                },
                            ),
                        ],
                    ),
                ),
                step(
                    "7",
                    StepKind::Action {
                        action: Action::Builtin {
                            command: "window.left_half".into(),
                        },
                    },
                ),
            ],
        );
        w.id = "a".into();
        let deps = dependencies(&w, &["a".to_string(), "b".to_string()]);
        let names: Vec<_> = deps
            .iter()
            .map(|d| (d.kind, d.name.as_str(), d.missing))
            .collect();
        assert_eq!(
            names,
            vec![
                (DependencyKind::Workflow, "b", false),
                (DependencyKind::Workflow, "gone", true),
                (DependencyKind::App, "com.x.App", false),
                (DependencyKind::Shortcut, "My Shortcut", false),
                (DependencyKind::Command, "window.left_half", false),
            ]
        );
    }

    #[test]
    fn a_package_report_says_what_is_risky_and_what_is_missing() {
        let caller = workflow(
            "caller",
            vec![
                step(
                    "1",
                    StepKind::RunWorkflow {
                        workflow_id: "helper".into(),
                    },
                ),
                step(
                    "2",
                    StepKind::Script {
                        language: FinderScript::Shell,
                        source: "ls".into(),
                    },
                ),
            ],
        );
        let json = export_package(&[caller], 1).unwrap();
        let report = package_report(&json, &[]);
        assert!(report.problems.is_empty());
        assert_eq!(report.workflows, vec!["Workflow caller".to_string()]);
        assert_eq!(report.missing_workflows, vec!["helper".to_string()]);
        assert!(report
            .risky_steps
            .iter()
            .any(|r| r.starts_with("Workflow caller:")));
        // With the helper already installed, nothing is missing.
        assert!(package_report(&json, &["helper".to_string()])
            .missing_workflows
            .is_empty());
        let bad = package_report("not a package", &[]);
        assert_eq!(bad.problems.len(), 1);
        assert!(bad.workflows.is_empty());
    }

    #[test]
    fn old_saved_steps_without_the_new_fields_still_load() {
        let json = r#"{"id":"1","label":null,"when":null,"on_error":"stop","kind":{"type":"delay","ms":5}}"#;
        let step: WorkflowStep = serde_json::from_str(json).unwrap();
        assert_eq!(step.retries, 0);
        assert_eq!(step.retry_delay_ms, DEFAULT_RETRY_DELAY_MS);
        assert_eq!(step.timeout_seconds, None);
    }

    #[test]
    fn the_catalog_has_flow_steps_that_pass_their_own_checks() {
        for template in step_catalog() {
            if matches!(
                template.kind,
                StepKind::Repeat { .. }
                    | StepKind::Parallel { .. }
                    | StepKind::Branch { .. }
                    | StepKind::SetVariable { .. }
                    | StepKind::Ask { .. }
                    | StepKind::Choose { .. }
                    | StepKind::Confirm { .. }
                    | StepKind::JavaScript { .. }
            ) {
                let w = workflow("a", vec![step("1", template.kind.clone())]);
                assert!(w.check().is_ok(), "{}: {:?}", template.title, w.check());
            }
        }
        assert!(step_catalog().iter().any(|t| t.category == "Flow"));
    }

    #[test]
    fn workflows_round_trip_through_json() {
        let mut w = workflow(
            "a",
            vec![WorkflowStep {
                id: "1".into(),
                label: Some("Go".into()),
                when: Some(group(
                    ConditionMode::Any,
                    vec![(ConditionKind::Weekdays { days: vec![1] }, true)],
                )),
                on_error: OnError::Continue,
                kind: StepKind::TextTransform {
                    ops: vec![TextOp::Uppercase],
                },
                retries: 2,
                retry_delay_ms: 250,
                timeout_seconds: Some(5),
            }],
        );
        w.trigger = WorkflowTrigger::WindowPlaced {
            layout: Some(WindowLayout::LeftHalf),
        };
        let json = serde_json::to_string(&w).unwrap();
        assert_eq!(serde_json::from_str::<Workflow>(&json).unwrap(), w);
        assert_eq!(w.command(), "workflow.a");
        assert_eq!(w.steps[0].title(), "Go");
    }
}

/// One earlier saved version of a workflow, for looking back and going back to.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct WorkflowVersion {
    pub workflow_id: String,
    pub revision: u32,
    pub saved_at: i64,
    pub name: String,
    pub step_count: u32,
    /// What changed from the version before it, in words ("2 steps added", "renamed").
    pub change: String,
}

/// A short description of how `new` differs from `old`.
pub fn describe_change(old: Option<&Workflow>, new: &Workflow) -> String {
    let Some(old) = old else {
        return "created".to_string();
    };
    let mut parts: Vec<String> = Vec::new();
    if old.name != new.name {
        parts.push("renamed".to_string());
    }
    let (a, b) = (old.steps.len(), new.steps.len());
    if b > a {
        parts.push(format!(
            "{} step{} added",
            b - a,
            if b - a == 1 { "" } else { "s" }
        ));
    } else if a > b {
        parts.push(format!(
            "{} step{} removed",
            a - b,
            if a - b == 1 { "" } else { "s" }
        ));
    } else if old.steps != new.steps {
        parts.push("steps changed".to_string());
    }
    if old.trigger != new.trigger {
        parts.push("trigger changed".to_string());
    }
    if old.enabled != new.enabled {
        parts.push(
            if new.enabled {
                "switched on"
            } else {
                "switched off"
            }
            .to_string(),
        );
    }
    if parts.is_empty() {
        "saved".to_string()
    } else {
        parts.join(", ")
    }
}
