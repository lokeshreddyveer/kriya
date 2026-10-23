//! File actions for the right-click menu and the launcher: what each action is, the names it creates, how a batch rename
//! is planned and checked, when to ask before going ahead, and the templates it can create from. Nothing here touches
//! the file system; the shell does the work and uses these functions to decide what to do.

use std::collections::HashSet;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::actions::modifiers as m;
use crate::error::CoreError;

pub const MAX_NAME_BYTES: usize = 255;
pub const MAX_TEMPLATE_ENTRIES: usize = 200;
pub const MAX_ITEMS: usize = 200;
pub const MAX_RENAME_STEPS: usize = 12;

// ---- what an action is -----------------------------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum PathStyle {
    Full,
    Name,
    NameWithoutExtension,
    Parent,
    ShellEscaped,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum FinderScript {
    Shell,
    AppleScript,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum CaseMode {
    Lower,
    Upper,
    Title,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum NumberPosition {
    Start,
    End,
}

/// One step of a batch rename. Steps run in order on each name, without its extension unless the step says otherwise.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum RenameStep {
    FindReplace {
        find: String,
        replace: String,
        case_sensitive: bool,
    },
    Prefix {
        text: String,
    },
    Suffix {
        text: String,
    },
    /// Adds a counter: the first file gets `start`, the next `start + step`, and so on.
    Number {
        start: i64,
        step: i64,
        digits: u32,
        position: NumberPosition,
        separator: String,
    },
    ChangeCase {
        mode: CaseMode,
    },
    Trim,
    RemoveCharacters {
        characters: String,
    },
    ReplaceExtension {
        extension: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize, uniffi::Record)]
pub struct BatchRenameRule {
    pub steps: Vec<RenameStep>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum FinderActionKind {
    NewFile {
        name: String,
    },
    /// `None` shows the templates as a submenu.
    NewFromTemplate {
        template_id: Option<String>,
    },
    NewFolder {
        name: String,
    },
    NewFolderFromTemplate {
        template_id: Option<String>,
    },
    CopyPath {
        style: PathStyle,
    },
    /// `None` uses the default terminal.
    OpenInTerminal {
        app_id: Option<String>,
    },
    /// `None` shows the favorite apps as a submenu.
    OpenWith {
        app_id: Option<String>,
    },
    Duplicate,
    Rename,
    BatchRename {
        rule: BatchRenameRule,
    },
    /// `None` asks for a folder each time.
    MoveTo {
        folder: Option<String>,
    },
    CopyTo {
        folder: Option<String>,
    },
    Compress,
    Extract,
    /// `None` shows the formats the selection can become as a submenu.
    Convert {
        target: Option<String>,
    },
    CopyMetadata,
    RunScript {
        language: FinderScript,
        source: String,
    },
    RunShortcut {
        name: String,
    },
    /// Starts a workflow with the selected files as its input.
    RunWorkflow {
        workflow_id: String,
    },
    /// Shows or hides the hidden files in Finder.
    ShowHiddenFiles,
    /// Opens the folder that holds the selected item and selects it.
    OpenParentFolder,
    /// Asks for a list of names, one per line, and makes a folder for each.
    NewFolders,
    /// Lists the biggest files inside a folder, at least this many megabytes each.
    FindLargeFiles {
        min_mb: u32,
    },
    /// Sorts the loose files of a folder into subfolders by kind (Images, Documents and so on). Nothing is deleted.
    CleanupFolder,
    /// Puts back what the last cleanup moved.
    UndoLast,
    /// Copies the SHA-256 checksum of each selected file.
    CopyChecksum,
    /// Takes away the "downloaded from the internet" warning macOS puts on files, so an app opens without the prompt.
    RemoveQuarantine,
    /// Makes a Finder alias beside each selected item.
    MakeAlias,
    /// Asks for Finder tags and puts them on each selected item (adding to the tags it has).
    EditTags,
    /// Asks for a Finder comment and writes it on each selected item.
    EditComment,
    /// Opens the system share menu for the selected items.
    Share,
}

/// What a selection has to look like for an action to be offered.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum Applies {
    Anything,
    Files,
    Folders,
    SingleItem,
    MultipleItems,
    Archives,
    /// A right-click on the empty space of a folder window.
    FolderBackground,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct FinderItem {
    pub id: String,
    pub title: String,
    pub kind: FinderActionKind,
    pub enabled: bool,
    pub applies: Applies,
    /// File extensions (lower case, no dot) the action is limited to. Empty means any.
    pub extensions: Vec<String>,
    /// Apps the action is limited to in the launcher. Empty means any. The Finder menu is always Finder's.
    pub app_ids: Vec<String>,
    /// Ask first (`Some(true)`), never ask (`Some(false)`), or follow the general rule (`None`).
    pub confirm: Option<bool>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum MenuStyle {
    /// One "Kriya" submenu holding every action.
    #[default]
    Submenu,
    /// The actions sit directly in Finder's menu.
    Flat,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
#[serde(default)]
pub struct FinderConfig {
    pub menu_style: MenuStyle,
    pub menu_title: String,
    /// Bundle id of the terminal used by "Open in Terminal". `None` is Terminal.
    pub default_terminal: Option<String>,
    pub favorite_apps: Vec<String>,
    /// Ask before actions that change or replace files.
    pub confirm_destructive: bool,
    /// Also ask before copying or duplicating at least this many items.
    pub confirm_over: u32,
    /// The launcher's global shortcut. A key code of `None` turns it off.
    pub launcher_key_code: Option<u16>,
    pub launcher_modifiers: u64,
    /// The app that opens each kind of file, by extension. Applied to macOS on request.
    pub default_apps: Vec<DefaultApp>,
}

/// One kind of file and the app that should open it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct DefaultApp {
    /// The extension without the dot, in lower case: `md`, `csv`.
    pub extension: String,
    pub app_id: String,
}

impl Default for FinderConfig {
    fn default() -> Self {
        FinderConfig {
            menu_style: MenuStyle::Flat,
            menu_title: "Kriya".to_string(),
            default_terminal: None,
            favorite_apps: Vec::new(),
            confirm_destructive: true,
            confirm_over: 25,
            launcher_key_code: Some(40),
            launcher_modifiers: m::CONTROL | m::OPTION | m::COMMAND,
            default_apps: Vec::new(),
        }
    }
}

impl FinderConfig {
    pub fn sanitized(mut self) -> Self {
        let title = self.menu_title.trim();
        self.menu_title = if title.is_empty() || title.chars().count() > 40 {
            "Kriya".to_string()
        } else {
            title.to_string()
        };
        self.confirm_over = self.confirm_over.clamp(2, 10_000);
        self.launcher_modifiers &= m::ALL;
        if self.launcher_modifiers == 0 {
            self.launcher_key_code = None;
        }
        let mut seen = HashSet::new();
        self.favorite_apps = self
            .favorite_apps
            .iter()
            .map(|a| a.trim().to_string())
            .filter(|a| !a.is_empty() && seen.insert(a.clone()))
            .collect();
        self.default_terminal = self
            .default_terminal
            .map(|t| t.trim().to_string())
            .filter(|t| !t.is_empty());
        // One app per extension; the last one listed wins.
        let mut cleaned: Vec<DefaultApp> = Vec::new();
        for entry in &self.default_apps {
            let extension = entry
                .extension
                .trim()
                .trim_start_matches('.')
                .to_lowercase();
            let app_id = entry.app_id.trim().to_string();
            let valid = !extension.is_empty()
                && extension.len() <= 16
                && extension.chars().all(|c| c.is_ascii_alphanumeric())
                && !app_id.is_empty();
            if !valid {
                continue;
            }
            cleaned.retain(|d| d.extension != extension);
            cleaned.push(DefaultApp { extension, app_id });
        }
        cleaned.truncate(100);
        self.default_apps = cleaned;
        self
    }
}

// ---- templates -------------------------------------------------------------------------------------------------------

/// A file that "New from template" creates: text written out, or a file copied from somewhere.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct FileTemplate {
    pub id: String,
    pub name: String,
    /// The name of the new file, with its extension.
    pub file_name: String,
    pub content: Option<String>,
    /// A file to copy instead of writing `content`.
    pub source_path: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct TemplateEntry {
    /// Relative to the new folder. A trailing slash makes a folder; anything else is a file.
    pub path: String,
    pub content: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct FolderTemplate {
    pub id: String,
    pub name: String,
    pub folder_name: String,
    pub entries: Vec<TemplateEntry>,
}

/// Why a file or folder name cannot be used, or `None` when it can.
pub fn name_problem(name: &str) -> Option<String> {
    if name.trim().is_empty() {
        return Some("the name is empty".into());
    }
    if name == "." || name == ".." {
        return Some("that name is not allowed".into());
    }
    if name.contains('/') || name.contains(':') || name.contains('\0') {
        return Some("a name cannot contain / or :".into());
    }
    if name.len() > MAX_NAME_BYTES {
        return Some("the name is too long".into());
    }
    None
}

/// A relative path inside a template: no leading slash, no `..`, every part a valid name.
fn relative_path_problem(path: &str) -> Option<String> {
    let trimmed = path.trim_end_matches('/');
    if trimmed.is_empty() || path.starts_with('/') {
        return Some("a template path must be relative".into());
    }
    trimmed
        .split('/')
        .find_map(|part| name_problem(part).map(|p| format!("“{part}”: {p}")))
}

impl FileTemplate {
    pub fn check(&self) -> Result<(), CoreError> {
        check_id_name(&self.id, &self.name, "a template")?;
        if let Some(p) = name_problem(&self.file_name) {
            return Err(CoreError::invalid(format!("the file name {p}")));
        }
        if self
            .source_path
            .as_ref()
            .is_some_and(|s| !s.starts_with('/'))
        {
            return Err(CoreError::invalid(
                "a template's source file needs a full path",
            ));
        }
        Ok(())
    }
}

impl FolderTemplate {
    pub fn check(&self) -> Result<(), CoreError> {
        check_id_name(&self.id, &self.name, "a folder template")?;
        if let Some(p) = name_problem(&self.folder_name) {
            return Err(CoreError::invalid(format!("the folder name {p}")));
        }
        if self.entries.len() > MAX_TEMPLATE_ENTRIES {
            return Err(CoreError::invalid(
                "the folder template has too many entries",
            ));
        }
        for e in &self.entries {
            if let Some(p) = relative_path_problem(&e.path) {
                return Err(CoreError::invalid(p));
            }
            if e.path.ends_with('/') && e.content.is_some() {
                return Err(CoreError::invalid("a folder entry cannot have content"));
            }
        }
        Ok(())
    }
}

fn check_id_name(id: &str, name: &str, what: &str) -> Result<(), CoreError> {
    if id.trim().is_empty() {
        return Err(CoreError::invalid(format!("{what} needs an id")));
    }
    if name.trim().is_empty() || name.chars().count() > 100 {
        return Err(CoreError::invalid(format!(
            "{what} needs a name of up to 100 characters"
        )));
    }
    Ok(())
}

impl FinderItem {
    pub fn check(&self) -> Result<(), CoreError> {
        check_id_name(&self.id, &self.title, "an action")?;
        match &self.kind {
            FinderActionKind::NewFile { name } | FinderActionKind::NewFolder { name } => {
                if let Some(p) = name_problem(name) {
                    return Err(CoreError::invalid(format!("the default name {p}")));
                }
            }
            FinderActionKind::FindLargeFiles { min_mb } if !(1..=100_000).contains(min_mb) => {
                return Err(CoreError::invalid(
                    "the size must be between 1 MB and 100,000 MB",
                ));
            }
            FinderActionKind::RunScript { source, .. } if source.trim().is_empty() => {
                return Err(CoreError::invalid("the script is empty"));
            }
            FinderActionKind::RunScript { source, .. } if source.len() > 100_000 => {
                return Err(CoreError::invalid("the script is too long"));
            }
            FinderActionKind::RunShortcut { name } if name.trim().is_empty() => {
                return Err(CoreError::invalid("choose a shortcut to run"));
            }
            FinderActionKind::RunWorkflow { workflow_id } if workflow_id.trim().is_empty() => {
                return Err(CoreError::invalid("choose a workflow to run"));
            }
            FinderActionKind::BatchRename { rule } => {
                if rule.steps.is_empty() || rule.steps.len() > MAX_RENAME_STEPS {
                    return Err(CoreError::invalid(
                        "a batch rename needs between 1 and 12 steps",
                    ));
                }
            }
            FinderActionKind::MoveTo { folder: Some(f) }
            | FinderActionKind::CopyTo { folder: Some(f) }
                if !f.starts_with('/') =>
            {
                return Err(CoreError::invalid("the destination needs a full path"));
            }
            _ => {}
        }
        Ok(())
    }
}

// ---- paths and names -------------------------------------------------------------------------------------------------

/// Wraps a path in single quotes so a shell reads it as one word, whatever it holds.
pub fn shell_escape(path: &str) -> String {
    format!("'{}'", path.replace('\'', "'\\''"))
}

pub fn file_name(path: &str) -> String {
    Path::new(path)
        .file_name()
        .map_or_else(|| path.to_string(), |n| n.to_string_lossy().into_owned())
}

pub fn parent_path(path: &str) -> String {
    Path::new(path)
        .parent()
        .map_or_else(|| "/".to_string(), |p| p.to_string_lossy().into_owned())
}

/// The name and extension of a file name. A leading dot is part of the name (".zshrc" has no extension), and only the
/// last dot starts the extension ("a.tar.gz" is "a.tar" and "gz").
pub fn split_extension(name: &str) -> (String, String) {
    match name.rfind('.') {
        Some(i) if i > 0 && i + 1 < name.len() => {
            (name[..i].to_string(), name[i + 1..].to_string())
        }
        _ => (name.to_string(), String::new()),
    }
}

fn join_extension(stem: &str, ext: &str) -> String {
    if ext.is_empty() {
        stem.to_string()
    } else {
        format!("{stem}.{ext}")
    }
}

/// The text a "copy path" action puts on the clipboard: one line per item.
pub fn path_text(style: PathStyle, paths: &[String]) -> String {
    paths
        .iter()
        .map(|p| match style {
            PathStyle::Full => p.clone(),
            PathStyle::Name => file_name(p),
            PathStyle::NameWithoutExtension => split_extension(&file_name(p)).0,
            PathStyle::Parent => parent_path(p),
            PathStyle::ShellEscaped => shell_escape(p),
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// `candidate` if it is free, otherwise "name 2.ext", "name 3.ext" and so on.
pub fn unique_name(candidate: &str, existing: &[String]) -> String {
    let taken: HashSet<String> = existing.iter().map(|e| e.to_lowercase()).collect();
    if !taken.contains(&candidate.to_lowercase()) {
        return candidate.to_string();
    }
    let (stem, ext) = split_extension(candidate);
    (2..)
        .map(|n| join_extension(&format!("{stem} {n}"), &ext))
        .find(|name| !taken.contains(&name.to_lowercase()))
        .unwrap_or_else(|| candidate.to_string())
}

/// The name for a duplicate, the way Finder writes it: "name copy.ext", then "name copy 2.ext".
pub fn copy_name(name: &str, existing: &[String]) -> String {
    let (stem, ext) = split_extension(name);
    unique_name(&join_extension(&format!("{stem} copy"), &ext), existing)
}

// ---- batch rename ----------------------------------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RenamePlanItem {
    pub from: String,
    pub to: String,
    pub unchanged: bool,
    pub problem: Option<String>,
}

fn title_case(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut start = true;
    for c in s.chars() {
        if c.is_alphanumeric() {
            if start {
                out.extend(c.to_uppercase());
            } else {
                out.extend(c.to_lowercase());
            }
            start = false;
        } else {
            out.push(c);
            start = true;
        }
    }
    out
}

fn replace_ignoring_case(text: &str, find: &str, replace: &str) -> String {
    if find.is_empty() {
        return text.to_string();
    }
    let lower_text = text.to_lowercase();
    let lower_find = find.to_lowercase();
    // Case folding can change a string's length; only match by position when it did not.
    if lower_text.len() != text.len() {
        return text.replace(find, replace);
    }
    let mut out = String::new();
    let mut last = 0;
    for (start, matched) in lower_text.match_indices(&lower_find) {
        out.push_str(&text[last..start]);
        out.push_str(replace);
        last = start + matched.len();
    }
    out.push_str(&text[last..]);
    out
}

fn apply_steps(name: &str, index: usize, rule: &BatchRenameRule) -> String {
    let (mut stem, mut ext) = split_extension(name);
    for step in &rule.steps {
        match step {
            RenameStep::FindReplace {
                find,
                replace,
                case_sensitive,
            } => {
                stem = if *case_sensitive {
                    stem.replace(find.as_str(), replace)
                } else {
                    replace_ignoring_case(&stem, find, replace)
                };
            }
            RenameStep::Prefix { text } => stem = format!("{text}{stem}"),
            RenameStep::Suffix { text } => stem = format!("{stem}{text}"),
            RenameStep::Number {
                start,
                step,
                digits,
                position,
                separator,
            } => {
                let value = start.saturating_add(step.saturating_mul(index as i64));
                let width = (*digits).clamp(1, 12) as usize;
                let counter = if value < 0 {
                    format!("-{:0>width$}", value.unsigned_abs())
                } else {
                    format!("{value:0>width$}")
                };
                stem = match position {
                    NumberPosition::Start => format!("{counter}{separator}{stem}"),
                    NumberPosition::End => format!("{stem}{separator}{counter}"),
                };
            }
            RenameStep::ChangeCase { mode } => {
                stem = match mode {
                    CaseMode::Lower => stem.to_lowercase(),
                    CaseMode::Upper => stem.to_uppercase(),
                    CaseMode::Title => title_case(&stem),
                };
            }
            RenameStep::Trim => stem = stem.trim().to_string(),
            RenameStep::RemoveCharacters { characters } => stem.retain(|c| !characters.contains(c)),
            RenameStep::ReplaceExtension { extension } => {
                ext = extension.trim_start_matches('.').to_string()
            }
        }
    }
    join_extension(&stem, &ext)
}

/// Works out what each file would be called, and what would go wrong: empty or invalid names, two files getting the
/// same name, or a name already used by another file in the folder. `others` are the other names in that folder.
pub fn plan_batch_rename(
    names: &[String],
    rule: &BatchRenameRule,
    others: &[String],
) -> Vec<RenamePlanItem> {
    let targets: Vec<String> = names
        .iter()
        .enumerate()
        .map(|(i, n)| apply_steps(n, i, rule))
        .collect();
    let renamed: HashSet<&str> = names.iter().map(String::as_str).collect();
    let outside: HashSet<String> = others
        .iter()
        .filter(|o| !renamed.contains(o.as_str()))
        .map(|o| o.to_lowercase())
        .collect();
    let mut counts = std::collections::HashMap::new();
    for t in &targets {
        *counts.entry(t.to_lowercase()).or_insert(0usize) += 1;
    }
    names
        .iter()
        .zip(&targets)
        .map(|(from, to)| {
            let unchanged = from == to;
            let problem = if unchanged {
                None
            } else if let Some(p) = name_problem(to) {
                Some(p)
            } else if counts.get(&to.to_lowercase()).copied().unwrap_or(0) > 1 {
                Some("another file would get the same name".to_string())
            } else if outside.contains(&to.to_lowercase()) {
                Some("a file with that name already exists".to_string())
            } else {
                None
            };
            RenamePlanItem {
                from: from.clone(),
                to: to.clone(),
                unchanged,
                problem,
            }
        })
        .collect()
}

/// The plan can be carried out when something changes and nothing is wrong.
pub fn rename_plan_ready(plan: &[RenamePlanItem]) -> bool {
    plan.iter().any(|p| !p.unchanged) && plan.iter().all(|p| p.problem.is_none())
}

// ---- asking first ----------------------------------------------------------------------------------------------------

/// Actions that change or replace the person's files, or run code on them.
pub fn is_destructive(kind: &FinderActionKind) -> bool {
    matches!(
        kind,
        FinderActionKind::BatchRename { .. }
            | FinderActionKind::MoveTo { .. }
            | FinderActionKind::RunScript { .. }
            | FinderActionKind::RunShortcut { .. }
            | FinderActionKind::RunWorkflow { .. }
            | FinderActionKind::Convert { .. }
            | FinderActionKind::Extract
            | FinderActionKind::CleanupFolder
            | FinderActionKind::RemoveQuarantine
    )
}

/// The question to ask before carrying out an action on `count` items, or `None` to go ahead.
pub fn confirmation_message(
    item: &FinderItem,
    count: u32,
    config: &FinderConfig,
) -> Option<String> {
    let ask = match item.confirm {
        Some(choice) => choice,
        None => {
            config.confirm_destructive
                && (is_destructive(&item.kind)
                    || (matches!(
                        item.kind,
                        FinderActionKind::Duplicate | FinderActionKind::CopyTo { .. }
                    ) && count >= config.confirm_over))
        }
    };
    if !ask {
        return None;
    }
    let things = if count == 1 {
        "1 item".to_string()
    } else {
        format!("{count} items")
    };
    Some(match &item.kind {
        FinderActionKind::BatchRename { .. } => format!("Rename {things}?"),
        FinderActionKind::MoveTo { .. } => format!("Move {things}?"),
        FinderActionKind::RunScript { .. } => format!("Run “{}” on {things}?", item.title),
        FinderActionKind::RunShortcut { name } => format!("Run the shortcut “{name}” on {things}?"),
        FinderActionKind::RunWorkflow { .. } => format!("Run “{}” on {things}?", item.title),
        FinderActionKind::Convert { .. } => format!("Convert {things}?"),
        FinderActionKind::Extract => format!("Extract {things}?"),
        FinderActionKind::CleanupFolder => {
            "Sort the loose files in this folder into subfolders?".to_string()
        }
        FinderActionKind::Duplicate => format!("Duplicate {things}?"),
        FinderActionKind::CopyTo { .. } => format!("Copy {things}?"),
        _ => format!("{} {things}?", item.title),
    })
}

// ---- the shipped actions ---------------------------------------------------------------------------------------------

/// Extra ready-made actions the person can add: an editor, hidden files and the parent folder. Fixed ids, so adding
/// them twice does nothing.
pub fn suggested_items() -> Vec<FinderItem> {
    let item = |id: &str, title: &str, kind, applies| FinderItem {
        id: id.to_string(),
        title: title.to_string(),
        kind,
        enabled: true,
        applies,
        extensions: Vec::new(),
        app_ids: Vec::new(),
        confirm: None,
    };
    vec![
        item(
            "open-in-vscode",
            "Open in Visual Studio Code",
            FinderActionKind::OpenWith {
                app_id: Some("com.microsoft.VSCode".to_string()),
            },
            Applies::Anything,
        ),
        item(
            "show-hidden-files",
            "Show or Hide Hidden Files",
            FinderActionKind::ShowHiddenFiles,
            Applies::FolderBackground,
        ),
        item(
            "open-parent-folder",
            "Open Parent Folder",
            FinderActionKind::OpenParentFolder,
            Applies::SingleItem,
        ),
        item(
            "new-folders",
            "New Folders…",
            FinderActionKind::NewFolders,
            Applies::FolderBackground,
        ),
        item(
            "find-large-files",
            "Find Large Files",
            FinderActionKind::FindLargeFiles { min_mb: 100 },
            Applies::Folders,
        ),
        item(
            "find-large-files-here",
            "Find Large Files Here",
            FinderActionKind::FindLargeFiles { min_mb: 100 },
            Applies::FolderBackground,
        ),
        item(
            "tidy-folder",
            "Tidy Up This Folder",
            FinderActionKind::CleanupFolder,
            Applies::FolderBackground,
        ),
        item(
            "undo-last",
            "Undo Last Tidy-Up",
            FinderActionKind::UndoLast,
            Applies::FolderBackground,
        ),
        item(
            "copy-checksum",
            "Copy SHA-256 Checksum",
            FinderActionKind::CopyChecksum,
            Applies::Files,
        ),
        item(
            "remove-quarantine",
            "Remove Download Warning",
            FinderActionKind::RemoveQuarantine,
            Applies::Anything,
        ),
        item(
            "make-alias",
            "Make Alias",
            FinderActionKind::MakeAlias,
            Applies::Anything,
        ),
        item(
            "edit-tags",
            "Edit Tags…",
            FinderActionKind::EditTags,
            Applies::Anything,
        ),
        item(
            "edit-comment",
            "Edit Comment…",
            FinderActionKind::EditComment,
            Applies::Anything,
        ),
        item("share", "Share…", FinderActionKind::Share, Applies::Files),
    ]
}

pub fn default_items() -> Vec<FinderItem> {
    use FinderActionKind::*;
    let item = |id: &str, title: &str, kind, applies| FinderItem {
        id: id.to_string(),
        title: title.to_string(),
        kind,
        enabled: true,
        applies,
        extensions: Vec::new(),
        app_ids: Vec::new(),
        confirm: None,
    };
    vec![
        item(
            "new-folder",
            "New Folder",
            NewFolder {
                name: "untitled folder".into(),
            },
            Applies::FolderBackground,
        ),
        item(
            "new-file",
            "New Empty File",
            NewFile {
                name: "untitled.txt".into(),
            },
            Applies::FolderBackground,
        ),
        item(
            "new-from-template",
            "New File from Template",
            NewFromTemplate { template_id: None },
            Applies::FolderBackground,
        ),
        item(
            "new-folder-from-template",
            "New Folder from Template",
            NewFolderFromTemplate { template_id: None },
            Applies::FolderBackground,
        ),
        item(
            "copy-path",
            "Copy Full Path",
            CopyPath {
                style: PathStyle::Full,
            },
            Applies::Anything,
        ),
        item(
            "copy-name",
            "Copy Filename",
            CopyPath {
                style: PathStyle::Name,
            },
            Applies::Anything,
        ),
        item(
            "copy-parent",
            "Copy Parent Folder Path",
            CopyPath {
                style: PathStyle::Parent,
            },
            Applies::Anything,
        ),
        item(
            "copy-shell-path",
            "Copy Shell-Escaped Path",
            CopyPath {
                style: PathStyle::ShellEscaped,
            },
            Applies::Anything,
        ),
        item(
            "open-terminal",
            "Open in Terminal",
            OpenInTerminal { app_id: None },
            Applies::Anything,
        ),
        item(
            "open-with",
            "Open With Favorite App",
            OpenWith { app_id: None },
            Applies::Files,
        ),
        item("duplicate", "Duplicate", Duplicate, Applies::Anything),
        item("rename", "Rename…", Rename, Applies::SingleItem),
        item(
            "batch-rename",
            "Batch Rename…",
            BatchRename {
                rule: BatchRenameRule {
                    steps: vec![RenameStep::Prefix {
                        text: String::new(),
                    }],
                },
            },
            Applies::MultipleItems,
        ),
        item(
            "move-to",
            "Move To…",
            MoveTo { folder: None },
            Applies::Anything,
        ),
        item(
            "copy-to",
            "Copy To…",
            CopyTo { folder: None },
            Applies::Anything,
        ),
        item("compress", "Compress", Compress, Applies::Anything),
        item("extract", "Extract", Extract, Applies::Archives),
        item(
            "convert",
            "Convert To",
            Convert { target: None },
            Applies::Files,
        ),
        item(
            "copy-info",
            "Copy File Info",
            CopyMetadata,
            Applies::Anything,
        ),
    ]
}

/// Starter templates the person can edit.
pub fn default_file_templates() -> Vec<FileTemplate> {
    let t = |id: &str, name: &str, file_name: &str, content: &str| FileTemplate {
        id: id.to_string(),
        name: name.to_string(),
        file_name: file_name.to_string(),
        content: Some(content.to_string()),
        source_path: None,
    };
    vec![
        t("tpl-text", "Text file", "untitled.txt", ""),
        t("tpl-markdown", "Markdown note", "untitled.md", "# Title\n\n"),
        t("tpl-html", "HTML page", "index.html", "<!doctype html>\n<html lang=\"en\">\n<head>\n  <meta charset=\"utf-8\">\n  <title>Title</title>\n</head>\n<body>\n\n</body>\n</html>\n"),
        t("tpl-shell", "Shell script", "script.sh", "#!/bin/zsh\nset -euo pipefail\n\n"),
    ]
}

pub fn default_folder_templates() -> Vec<FolderTemplate> {
    let e = |path: &str, content: Option<&str>| TemplateEntry {
        path: path.to_string(),
        content: content.map(str::to_string),
    };
    vec![FolderTemplate {
        id: "tpl-project".into(),
        name: "Project folder".into(),
        folder_name: "New Project".into(),
        entries: vec![
            e("docs/", None),
            e("src/", None),
            e("README.md", Some("# New Project\n")),
        ],
    }]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    fn rule(steps: Vec<RenameStep>) -> BatchRenameRule {
        BatchRenameRule { steps }
    }

    #[test]
    fn folder_tools_are_offered_checked_and_cleanup_asks_first() {
        let list = suggested_items();
        for id in [
            "new-folders",
            "find-large-files",
            "tidy-folder",
            "undo-last",
        ] {
            assert!(list.iter().any(|i| i.id == id), "{id}");
        }
        assert!(list.iter().all(|i| i.check().is_ok()));
        let mut big = list
            .iter()
            .find(|i| i.id == "find-large-files")
            .unwrap()
            .clone();
        big.kind = FinderActionKind::FindLargeFiles { min_mb: 0 };
        assert!(big.check().is_err());
        let tidy = list.iter().find(|i| i.id == "tidy-folder").unwrap();
        assert!(is_destructive(&tidy.kind));
        let quarantine = list.iter().find(|i| i.id == "remove-quarantine").unwrap();
        assert!(
            is_destructive(&quarantine.kind),
            "it changes a security setting, so it asks first"
        );
        let plain = list.iter().find(|i| i.id == "copy-checksum").unwrap();
        assert!(!is_destructive(&plain.kind));
        assert!(confirmation_message(tidy, 1, &FinderConfig::default())
            .unwrap()
            .contains("subfolders"));
    }

    #[test]
    fn shell_escaping_survives_hostile_names() {
        assert_eq!(shell_escape("/a b/c"), "'/a b/c'");
        assert_eq!(shell_escape("/it's"), "'/it'\\''s'");
        assert_eq!(shell_escape("/$(rm -rf ~)"), "'/$(rm -rf ~)'");
        assert_eq!(shell_escape("/a;b`c`\n"), "'/a;b`c`\n'");
    }

    #[test]
    fn path_text_covers_every_style() {
        let p = names(&["/Users/me/Docs/report.final.pdf", "/Users/me/Docs/notes"]);
        assert_eq!(
            path_text(PathStyle::Full, &p),
            "/Users/me/Docs/report.final.pdf\n/Users/me/Docs/notes"
        );
        assert_eq!(path_text(PathStyle::Name, &p), "report.final.pdf\nnotes");
        assert_eq!(
            path_text(PathStyle::NameWithoutExtension, &p),
            "report.final\nnotes"
        );
        assert_eq!(
            path_text(PathStyle::Parent, &p),
            "/Users/me/Docs\n/Users/me/Docs"
        );
        assert_eq!(
            path_text(PathStyle::ShellEscaped, &names(&["/a b"])),
            "'/a b'"
        );
        assert_eq!(parent_path("/"), "/");
    }

    #[test]
    fn extensions_split_on_the_last_dot_only() {
        assert_eq!(split_extension("a.tar.gz"), ("a.tar".into(), "gz".into()));
        assert_eq!(split_extension(".zshrc"), (".zshrc".into(), String::new()));
        assert_eq!(
            split_extension("trailing."),
            ("trailing.".into(), String::new())
        );
        assert_eq!(split_extension("noext"), ("noext".into(), String::new()));
    }

    #[test]
    fn new_names_never_clash() {
        assert_eq!(unique_name("untitled folder", &[]), "untitled folder");
        assert_eq!(
            unique_name("untitled folder", &names(&["untitled folder"])),
            "untitled folder 2"
        );
        assert_eq!(
            unique_name("a.txt", &names(&["A.TXT", "a 2.txt"])),
            "a 3.txt"
        );
        assert_eq!(copy_name("report.pdf", &[]), "report copy.pdf");
        assert_eq!(
            copy_name("report.pdf", &names(&["report copy.pdf"])),
            "report copy 2.pdf"
        );
        assert_eq!(copy_name("Makefile", &[]), "Makefile copy");
    }

    #[test]
    fn names_are_checked() {
        assert!(name_problem("ok.txt").is_none());
        for bad in ["", "  ", ".", "..", "a/b", "a:b"] {
            assert!(name_problem(bad).is_some(), "{bad:?} should be refused");
        }
        assert!(name_problem(&"x".repeat(300)).is_some());
    }

    #[test]
    fn find_replace_respects_case_and_the_extension() {
        let plan = plan_batch_rename(
            &names(&["IMG_001.JPG", "img_002.jpg"]),
            &rule(vec![RenameStep::FindReplace {
                find: "img".into(),
                replace: "Photo".into(),
                case_sensitive: false,
            }]),
            &[],
        );
        assert_eq!(plan[0].to, "Photo_001.JPG");
        assert_eq!(plan[1].to, "Photo_002.jpg");
        let strict = plan_batch_rename(
            &names(&["IMG_001.jpg"]),
            &rule(vec![RenameStep::FindReplace {
                find: "img".into(),
                replace: "x".into(),
                case_sensitive: true,
            }]),
            &[],
        );
        assert!(strict[0].unchanged);
    }

    #[test]
    fn numbering_counts_up_with_padding_and_position() {
        let plan = plan_batch_rename(
            &names(&["a.png", "b.png", "c.png"]),
            &rule(vec![RenameStep::Number {
                start: 8,
                step: 1,
                digits: 3,
                position: NumberPosition::End,
                separator: "-".into(),
            }]),
            &[],
        );
        assert_eq!(
            plan.iter().map(|p| p.to.as_str()).collect::<Vec<_>>(),
            ["a-008.png", "b-009.png", "c-010.png"]
        );
        let front = plan_batch_rename(
            &names(&["x.txt"]),
            &rule(vec![RenameStep::Number {
                start: 1,
                step: 1,
                digits: 2,
                position: NumberPosition::Start,
                separator: "_".into(),
            }]),
            &[],
        );
        assert_eq!(front[0].to, "01_x.txt");
    }

    #[test]
    fn steps_combine_in_order() {
        let plan = plan_batch_rename(
            &names(&["  hello world .TXT"]),
            &rule(vec![
                RenameStep::Trim,
                RenameStep::ChangeCase {
                    mode: CaseMode::Title,
                },
                RenameStep::RemoveCharacters {
                    characters: " ".into(),
                },
                RenameStep::Prefix { text: "My".into() },
                RenameStep::ReplaceExtension {
                    extension: ".md".into(),
                },
            ]),
            &[],
        );
        assert_eq!(plan[0].to, "MyHelloWorld.md");
    }

    #[test]
    fn clashes_and_bad_names_are_reported_before_anything_changes() {
        let same = plan_batch_rename(
            &names(&["a.txt", "b.txt"]),
            &rule(vec![RenameStep::FindReplace {
                find: "a".into(),
                replace: "b".into(),
                case_sensitive: true,
            }]),
            &[],
        );
        assert!(same[0]
            .problem
            .as_deref()
            .is_some_and(|p| p.contains("same name")));
        assert!(!rename_plan_ready(&same));

        let existing = plan_batch_rename(
            &names(&["a.txt"]),
            &rule(vec![RenameStep::Prefix { text: "z-".into() }]),
            &names(&["a.txt", "Z-A.txt"]),
        );
        assert!(existing[0]
            .problem
            .as_deref()
            .is_some_and(|p| p.contains("already exists")));

        let empty = plan_batch_rename(
            &names(&["abc"]),
            &rule(vec![RenameStep::RemoveCharacters {
                characters: "abc".into(),
            }]),
            &[],
        );
        assert!(empty[0].problem.is_some());

        let slash = plan_batch_rename(
            &names(&["a"]),
            &rule(vec![RenameStep::Suffix { text: "/x".into() }]),
            &[],
        );
        assert!(slash[0].problem.is_some());
    }

    #[test]
    fn a_plan_that_changes_nothing_is_not_ready() {
        let plan = plan_batch_rename(&names(&["a.txt"]), &rule(vec![RenameStep::Trim]), &[]);
        assert!(plan[0].unchanged);
        assert!(!rename_plan_ready(&plan));
    }

    fn item_of(kind: FinderActionKind) -> FinderItem {
        FinderItem {
            id: "i".into(),
            title: "Do it".into(),
            kind,
            enabled: true,
            applies: Applies::Anything,
            extensions: vec![],
            app_ids: vec![],
            confirm: None,
        }
    }

    #[test]
    fn destructive_actions_ask_and_safe_ones_do_not() {
        let config = FinderConfig::default();
        let batch = item_of(FinderActionKind::BatchRename {
            rule: BatchRenameRule::default(),
        });
        assert_eq!(
            confirmation_message(&batch, 3, &config).as_deref(),
            Some("Rename 3 items?")
        );
        assert!(confirmation_message(
            &item_of(FinderActionKind::CopyPath {
                style: PathStyle::Full
            }),
            100,
            &config
        )
        .is_none());
        assert!(confirmation_message(&item_of(FinderActionKind::Compress), 100, &config).is_none());
        assert_eq!(
            confirmation_message(
                &item_of(FinderActionKind::MoveTo { folder: None }),
                1,
                &config
            )
            .as_deref(),
            Some("Move 1 item?")
        );
    }

    #[test]
    fn big_copies_ask_and_the_rules_can_be_overridden() {
        let config = FinderConfig::default();
        let dup = item_of(FinderActionKind::Duplicate);
        assert!(confirmation_message(&dup, 5, &config).is_none());
        assert!(confirmation_message(&dup, 25, &config).is_some());
        let off = FinderConfig {
            confirm_destructive: false,
            ..FinderConfig::default()
        };
        assert!(confirmation_message(&item_of(FinderActionKind::Extract), 1, &off).is_none());
        let forced = FinderItem {
            confirm: Some(true),
            ..item_of(FinderActionKind::Compress)
        };
        assert!(confirmation_message(&forced, 1, &off).is_some());
        let never = FinderItem {
            confirm: Some(false),
            ..item_of(FinderActionKind::Extract)
        };
        assert!(confirmation_message(&never, 1, &config).is_none());
    }

    #[test]
    fn templates_cannot_escape_their_folder() {
        let ok = default_folder_templates().remove(0);
        assert!(ok.check().is_ok());
        for bad in ["../x", "/abs", "a/../b", "a//b", ""] {
            let t = FolderTemplate {
                entries: vec![TemplateEntry {
                    path: bad.into(),
                    content: None,
                }],
                ..ok.clone()
            };
            assert!(t.check().is_err(), "{bad:?} should be refused");
        }
        let folder_with_content = FolderTemplate {
            entries: vec![TemplateEntry {
                path: "d/".into(),
                content: Some("x".into()),
            }],
            ..ok
        };
        assert!(folder_with_content.check().is_err());
        assert!(FileTemplate {
            id: "t".into(),
            name: "T".into(),
            file_name: "a/b".into(),
            content: None,
            source_path: None
        }
        .check()
        .is_err());
        assert!(FileTemplate {
            id: "t".into(),
            name: "T".into(),
            file_name: "a.txt".into(),
            content: None,
            source_path: Some("relative".into())
        }
        .check()
        .is_err());
    }

    #[test]
    fn shipped_items_and_templates_are_valid() {
        let items = default_items();
        let ids: HashSet<_> = items.iter().map(|i| i.id.clone()).collect();
        assert_eq!(ids.len(), items.len());
        for i in &items {
            assert!(i.check().is_ok(), "{} should be valid", i.id);
        }
        assert!(default_file_templates().iter().all(|t| t.check().is_ok()));
    }

    #[test]
    fn items_are_checked() {
        let script = |source: &str| {
            item_of(FinderActionKind::RunScript {
                language: FinderScript::Shell,
                source: source.into(),
            })
        };
        assert!(script(" ").check().is_err());
        assert!(script("echo hi").check().is_ok());
        assert!(item_of(FinderActionKind::MoveTo {
            folder: Some("relative".into())
        })
        .check()
        .is_err());
        assert!(item_of(FinderActionKind::BatchRename {
            rule: BatchRenameRule::default()
        })
        .check()
        .is_err());
        assert!(item_of(FinderActionKind::NewFile { name: "a/b".into() })
            .check()
            .is_err());
    }

    #[test]
    fn config_is_cleaned() {
        let c = FinderConfig {
            menu_title: "  ".into(),
            confirm_over: 0,
            launcher_modifiers: 0,
            favorite_apps: names(&[" a ", "a", ""]),
            default_terminal: Some(" ".into()),
            ..FinderConfig::default()
        }
        .sanitized();
        assert_eq!(c.menu_title, "Kriya");
        assert_eq!(c.confirm_over, 2);
        assert_eq!(
            c.launcher_key_code, None,
            "a shortcut with no modifier keys is turned off"
        );
        assert_eq!(c.favorite_apps, names(&["a"]));
        assert_eq!(c.default_terminal, None);
    }

    #[test]
    fn items_round_trip_through_json() {
        for item in default_items() {
            let json = serde_json::to_string(&item).unwrap();
            assert_eq!(serde_json::from_str::<FinderItem>(&json).unwrap(), item);
        }
    }

    #[test]
    fn default_apps_are_cleaned_and_one_per_extension() {
        let config = FinderConfig {
            default_apps: vec![
                DefaultApp {
                    extension: " .MD ".into(),
                    app_id: "com.a".into(),
                },
                DefaultApp {
                    extension: "md".into(),
                    app_id: "com.b".into(),
                },
                DefaultApp {
                    extension: "csv".into(),
                    app_id: "  ".into(),
                },
                DefaultApp {
                    extension: "a/b".into(),
                    app_id: "com.c".into(),
                },
                DefaultApp {
                    extension: "txt".into(),
                    app_id: "com.d".into(),
                },
            ],
            ..FinderConfig::default()
        }
        .sanitized();
        assert_eq!(
            config.default_apps,
            vec![
                DefaultApp {
                    extension: "md".into(),
                    app_id: "com.b".into()
                },
                DefaultApp {
                    extension: "txt".into(),
                    app_id: "com.d".into()
                },
            ]
        );
    }

    #[test]
    fn suggested_items_are_valid_and_unique() {
        let list = suggested_items();
        let mut ids: Vec<&str> = list.iter().map(|i| i.id.as_str()).collect();
        ids.sort_unstable();
        ids.dedup();
        assert_eq!(ids.len(), list.len());
        for item in &list {
            item.check().unwrap();
        }
        let taken: Vec<String> = default_items().into_iter().map(|i| i.id).collect();
        assert!(
            list.iter().all(|i| !taken.contains(&i.id)),
            "none repeats a shipped action"
        );
    }
}
