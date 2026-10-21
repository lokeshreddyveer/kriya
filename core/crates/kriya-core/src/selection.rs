//! The selection bar: which actions exist, which of them apply to a given selection in a given app, how the bar looks,
//! and the packages used to share custom actions. The shell finds the selection and carries the action out.

use std::collections::HashSet;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::actions::modifiers as m;
use crate::clipboard::DEFAULT_EXCLUDED_APPS;
use crate::error::CoreError;
use crate::finder::FinderScript;
use crate::text_tools::{check_ops, check_url_template, TextOp};

pub const MAX_ACTIONS: usize = 200;
pub const MAX_SCRIPT_BYTES: usize = 100_000;
pub const PACKAGE_KIND: &str = "selection_actions";
pub const PACKAGE_VERSION: u32 = 1;
pub const MAX_PACKAGE_BYTES: usize = 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum TranslateProvider {
    Google,
    DeepL,
    Bing,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum SelectionActionKind {
    Copy,
    Cut,
    Paste,
    PastePlain,
    /// Changes the text. In an editable field it replaces the selection; otherwise (or with `copy_only`) the result is copied.
    Transform {
        ops: Vec<TextOp>,
        copy_only: bool,
    },
    UrlTemplate {
        template: String,
    },
    OpenUrls,
    Dictionary,
    Spelling,
    /// Copies the selection as plain text, without its formatting.
    CopyPlain,
    /// Copies the selection as Markdown: headings, bold, links and lists keep their meaning.
    CopyMarkdown,
    /// Shows the number of words, characters and lines.
    Count,
    /// Opens the system share menu with the selected text.
    Share,
    /// Presses a key combination in the app, such as Command-B for bold.
    PressKeys {
        key_code: u16,
        modifiers: u64,
    },
    /// Opens the text in another app, as a text file.
    OpenInApp {
        app_id: String,
    },
    /// Replaces the selection with a new random identifier (UUID); copies it where text cannot be replaced.
    Uuid,
    Translate {
        target: String,
        provider: TranslateProvider,
    },
    /// The selection is given to the script as its first argument and in `KRIYA_SELECTION`.
    Script {
        language: FinderScript,
        source: String,
        replace_with_output: bool,
    },
    Shortcut {
        name: String,
        replace_with_output: bool,
    },
    Workflow {
        workflow_id: String,
    },
}

/// What a selection has to be like for an action to be offered.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum SelectionTarget {
    Anything,
    EditableOnly,
    ReadOnlyOnly,
    ContainsUrl,
    MultipleLines,
    LooksLikeJson,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct SelectionAction {
    pub id: String,
    pub title: String,
    /// An SF Symbol name for the button.
    pub symbol: String,
    pub kind: SelectionActionKind,
    pub enabled: bool,
    pub applies: SelectionTarget,
    /// Offered only in these apps. Empty means every app.
    pub app_ids: Vec<String>,
    /// Actions that share a group sit under one button in the bar, which opens a small menu of them.
    #[serde(default)]
    #[uniffi(default = None)]
    pub group: Option<String>,
}

impl SelectionAction {
    pub fn check(&self) -> Result<(), CoreError> {
        if self.id.trim().is_empty() {
            return Err(CoreError::invalid("an action needs an id"));
        }
        if self.title.trim().is_empty() || self.title.chars().count() > 60 {
            return Err(CoreError::invalid(
                "an action needs a name of up to 60 characters",
            ));
        }
        if self.symbol.chars().count() > 80 {
            return Err(CoreError::invalid("the symbol name is too long"));
        }
        if self.group.as_ref().is_some_and(|g| g.chars().count() > 40) {
            return Err(CoreError::invalid(
                "a group name can be up to 40 characters",
            ));
        }
        match &self.kind {
            SelectionActionKind::Transform { ops, .. } => {
                check_ops(ops).map_err(CoreError::invalid)?
            }
            SelectionActionKind::UrlTemplate { template } => {
                check_url_template(template).map_err(CoreError::invalid)?
            }
            SelectionActionKind::Translate { target, .. } if !valid_language(target) => {
                return Err(CoreError::invalid(
                    "the language code should look like en or pt-BR",
                ));
            }
            SelectionActionKind::Script { source, .. } => {
                if source.trim().is_empty() {
                    return Err(CoreError::invalid("the script is empty"));
                }
                if source.len() > MAX_SCRIPT_BYTES {
                    return Err(CoreError::invalid("the script is too long"));
                }
            }
            SelectionActionKind::Shortcut { name, .. } if name.trim().is_empty() => {
                return Err(CoreError::invalid("choose a shortcut to run"));
            }
            SelectionActionKind::Workflow { workflow_id } if workflow_id.trim().is_empty() => {
                return Err(CoreError::invalid("choose a workflow to run"));
            }
            SelectionActionKind::PressKeys { modifiers, .. }
                if *modifiers == 0 || *modifiers & !crate::actions::modifiers::ALL != 0 =>
            {
                return Err(CoreError::invalid(
                    "a key press needs at least one modifier key",
                ));
            }
            SelectionActionKind::OpenInApp { app_id } if app_id.trim().is_empty() => {
                return Err(CoreError::invalid("choose an app to open the text in"));
            }
            _ => {}
        }
        Ok(())
    }

    /// Code the person must approve before it runs for the first time.
    pub fn needs_approval(&self) -> bool {
        matches!(self.kind, SelectionActionKind::Script { .. })
    }
}

fn valid_language(code: &str) -> bool {
    let parts: Vec<&str> = code.split('-').collect();
    (1..=2).contains(&parts.len())
        && parts
            .iter()
            .all(|p| p.chars().all(|c| c.is_ascii_alphabetic()))
        && (2..=3).contains(&parts[0].len())
        && parts.get(1).is_none_or(|p| (2..=4).contains(&p.len()))
}

/// The address that opens a translation of the text in the chosen service. The text goes to that service when it is opened.
pub fn translate_url(
    provider: TranslateProvider,
    target: &str,
    text: &str,
) -> Result<String, String> {
    if !valid_language(target) {
        return Err("the language code should look like en or pt-BR".into());
    }
    let template = match provider {
        TranslateProvider::Google => {
            format!("https://translate.google.com/?sl=auto&tl={target}&op=translate&text={{text}}")
        }
        TranslateProvider::DeepL => {
            format!("https://www.deepl.com/translator#auto/{target}/{{text}}")
        }
        TranslateProvider::Bing => {
            format!("https://www.bing.com/translator?from=auto&to={target}&text={{text}}")
        }
    };
    crate::text_tools::expand_url_template(&template, text)
}

// ---- appearance and behaviour ----------------------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum ToolbarTheme {
    #[default]
    System,
    Light,
    Dark,
    Accent,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum ToolbarSize {
    Small,
    #[default]
    Regular,
    Large,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum ToolbarPosition {
    #[default]
    AboveSelection,
    BelowSelection,
    NearPointer,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum SelectionMode {
    /// The bar appears by itself when text is selected.
    #[default]
    Automatic,
    /// The bar appears only when the manual shortcut is pressed.
    ManualOnly,
    Off,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct AppBehavior {
    pub app_id: String,
    pub mode: SelectionMode,
    /// May Kriya copy the selection (and put the clipboard back) in this app when it cannot read the selection directly?
    pub allow_copy_fallback: bool,
    /// Only these actions in this app. Empty means all of them.
    pub action_ids: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
#[serde(default)]
pub struct SelectionConfig {
    pub theme: ToolbarTheme,
    pub size: ToolbarSize,
    pub position: ToolbarPosition,
    pub show_labels: bool,
    /// Buttons shown before the rest go into a "more" menu.
    pub max_visible: u32,
    /// How long text must stay selected before the bar appears.
    pub activation_delay_ms: u32,
    /// Hide the bar again after this long with no use. 0 keeps it until something else happens.
    pub auto_hide_seconds: u32,
    pub manual_key: Option<u16>,
    pub manual_modifiers: u64,
    pub excluded_app_ids: Vec<String>,
    pub app_behaviors: Vec<AppBehavior>,
    /// Where the selection cannot be read directly, copy it and put the clipboard back. Off unless turned on here or per app.
    pub copy_fallback_default: bool,
    pub min_length: u32,
    pub max_length: u32,
}

impl Default for SelectionConfig {
    fn default() -> Self {
        SelectionConfig {
            theme: ToolbarTheme::System,
            size: ToolbarSize::Regular,
            position: ToolbarPosition::AboveSelection,
            show_labels: false,
            max_visible: 7,
            activation_delay_ms: 250,
            auto_hide_seconds: 8,
            manual_key: Some(2),
            manual_modifiers: m::CONTROL | m::OPTION | m::COMMAND,
            excluded_app_ids: DEFAULT_EXCLUDED_APPS
                .iter()
                .map(|s| (*s).to_string())
                .collect(),
            app_behaviors: Vec::new(),
            copy_fallback_default: true,
            min_length: 1,
            max_length: 20_000,
        }
    }
}

impl SelectionConfig {
    pub fn sanitized(mut self) -> Self {
        self.max_visible = self.max_visible.clamp(2, 14);
        self.activation_delay_ms = self.activation_delay_ms.min(3000);
        self.auto_hide_seconds = self.auto_hide_seconds.min(120);
        self.min_length = self.min_length.clamp(1, 1000);
        self.max_length = self.max_length.clamp(self.min_length, 200_000);
        self.manual_modifiers &= m::ALL;
        if self.manual_modifiers == 0 {
            self.manual_key = None;
        }
        let mut seen = HashSet::new();
        self.excluded_app_ids = self
            .excluded_app_ids
            .iter()
            .map(|a| a.trim().to_string())
            .filter(|a| !a.is_empty() && seen.insert(a.clone()))
            .collect();
        let mut apps = HashSet::new();
        self.app_behaviors
            .retain(|b| !b.app_id.trim().is_empty() && apps.insert(b.app_id.clone()));
        self
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct EffectiveBehavior {
    pub mode: SelectionMode,
    pub allow_copy_fallback: bool,
    pub action_ids: Vec<String>,
}

/// What the bar does in an app: excluded apps get nothing; an app with its own settings uses them.
pub fn behavior_for(config: &SelectionConfig, app_id: Option<&str>) -> EffectiveBehavior {
    if app_id.is_some_and(|a| config.excluded_app_ids.iter().any(|x| x == a)) {
        return EffectiveBehavior {
            mode: SelectionMode::Off,
            allow_copy_fallback: false,
            action_ids: Vec::new(),
        };
    }
    if let Some(over) = app_id.and_then(|a| config.app_behaviors.iter().find(|b| b.app_id == a)) {
        return EffectiveBehavior {
            mode: over.mode,
            allow_copy_fallback: over.allow_copy_fallback,
            action_ids: over.action_ids.clone(),
        };
    }
    EffectiveBehavior {
        mode: SelectionMode::Automatic,
        allow_copy_fallback: config.copy_fallback_default,
        action_ids: Vec::new(),
    }
}

/// Whether text is a sensible length for the bar.
pub fn selection_length_ok(config: &SelectionConfig, text: &str) -> bool {
    let n = text.chars().count();
    n >= config.min_length as usize && n <= config.max_length as usize && !text.trim().is_empty()
}

/// The ids of the actions to offer, in order, for some selected text in an app.
pub fn actions_for(
    actions: &[SelectionAction],
    config: &SelectionConfig,
    app_id: Option<&str>,
    editable: bool,
    text: &str,
) -> Vec<String> {
    let behavior = behavior_for(config, app_id);
    if behavior.mode == SelectionMode::Off || !selection_length_ok(config, text) {
        return Vec::new();
    }
    let has_url = !crate::text_tools::find_urls(text).is_empty();
    let multiline = text.trim().contains('\n');
    let json_like = {
        let t = text.trim();
        (t.starts_with('{') && t.ends_with('}')) || (t.starts_with('[') && t.ends_with(']'))
    };
    actions
        .iter()
        .filter(|a| a.enabled)
        .filter(|a| {
            a.app_ids.is_empty() || app_id.is_some_and(|id| a.app_ids.iter().any(|x| x == id))
        })
        .filter(|a| behavior.action_ids.is_empty() || behavior.action_ids.contains(&a.id))
        .filter(|a| match a.applies {
            SelectionTarget::Anything => true,
            SelectionTarget::EditableOnly => editable,
            SelectionTarget::ReadOnlyOnly => !editable,
            SelectionTarget::ContainsUrl => has_url,
            SelectionTarget::MultipleLines => multiline,
            SelectionTarget::LooksLikeJson => json_like,
        })
        .map(|a| a.id.clone())
        .collect()
}

// ---- scripts must be approved -----------------------------------------------------------------------------------------

/// A fingerprint of a script. Approval belongs to this exact text: changing one character needs approval again.
pub fn script_fingerprint(language: &str, source: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(language.as_bytes());
    hasher.update(b"\0");
    hasher.update(source.as_bytes());
    hasher
        .finalize()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct ApprovedScript {
    pub fingerprint: String,
    pub label: String,
    pub approved_at: i64,
}

/// Ready-made actions the person can add: Markdown helpers, encodings, more searches, counting, sharing and a few that
/// create a note, a reminder or a calendar event. Fixed ids, so adding them twice does nothing. Related ones share a
/// group, so they take one button in the bar.
pub fn suggested_actions() -> Vec<SelectionAction> {
    use crate::actions::modifiers::COMMAND;
    use SelectionActionKind::*;
    use SelectionTarget::*;
    let make =
        |id: &str, title: &str, symbol: &str, kind, applies, group: Option<&str>| SelectionAction {
            id: format!("s-{id}"),
            title: title.to_string(),
            symbol: symbol.to_string(),
            kind,
            enabled: true,
            applies,
            app_ids: Vec::new(),
            group: group.map(str::to_string),
        };
    let wrap = |before: &str, after: &str| Transform {
        ops: vec![TextOp::Wrap {
            before: before.to_string(),
            after: after.to_string(),
        }],
        copy_only: false,
    };
    let ops = |op: TextOp| Transform {
        ops: vec![op],
        copy_only: false,
    };
    let search = |template: &str| UrlTemplate {
        template: template.to_string(),
    };
    let script = |source: &str| Script {
        language: FinderScript::AppleScript,
        source: source.to_string(),
        replace_with_output: false,
    };
    vec![
        make("md-bold", "Bold", "bold", wrap("**", "**"), EditableOnly, Some("Markdown")),
        make("md-italic", "Italic", "italic", wrap("*", "*"), EditableOnly, Some("Markdown")),
        make("md-code", "Code", "chevron.left.forwardslash.chevron.right", wrap("`", "`"), EditableOnly, Some("Markdown")),
        make("md-strike", "Strikethrough", "strikethrough", wrap("~~", "~~"), EditableOnly, Some("Markdown")),
        make("md-quote", "Quote", "text.quote", ops(TextOp::PrefixLines { text: "> ".into() }), EditableOnly, Some("Markdown")),
        make("md-checklist", "Checklist", "checklist", ops(TextOp::PrefixLines { text: "- [ ] ".into() }), EditableOnly, Some("Markdown")),
        make("case-pascal", "PascalCase", "textformat", ops(TextOp::PascalCase), EditableOnly, Some("Code")),
        make("case-constant", "CONSTANT_CASE", "textformat.abc", ops(TextOp::ConstantCase), EditableOnly, Some("Code")),
        make("b64-encode", "Base64 encode", "lock", ops(TextOp::Base64Encode), EditableOnly, Some("Code")),
        make("b64-decode", "Base64 decode", "lock.open", ops(TextOp::Base64Decode), EditableOnly, Some("Code")),
        make("escape", "Escape for a string", "arrow.turn.down.right", ops(TextOp::EscapeString), EditableOnly, Some("Code")),
        make("unescape", "Unescape a string", "arrow.turn.up.left", ops(TextOp::UnescapeString), EditableOnly, Some("Code")),
        make("uuid", "New UUID", "number", Uuid, EditableOnly, Some("Code")),
        make("key-bold", "Bold (⌘B)", "bold", PressKeys { key_code: 11, modifiers: COMMAND }, EditableOnly, Some("Format")),
        make("key-italic", "Italic (⌘I)", "italic", PressKeys { key_code: 34, modifiers: COMMAND }, EditableOnly, Some("Format")),
        make("key-underline", "Underline (⌘U)", "underline", PressKeys { key_code: 32, modifiers: COMMAND }, EditableOnly, Some("Format")),
        make("wikipedia", "Wikipedia", "book", search("https://en.wikipedia.org/w/index.php?search={text}"), Anything, Some("Search")),
        make("duckduckgo", "DuckDuckGo", "magnifyingglass", search("https://duckduckgo.com/?q={text}"), Anything, Some("Search")),
        make("github", "GitHub", "chevron.left.forwardslash.chevron.right", search("https://github.com/search?q={text}"), Anything, Some("Search")),
        make("youtube", "YouTube", "play.rectangle", search("https://www.youtube.com/results?search_query={text}"), Anything, Some("Search")),
        make("maps", "Maps", "map", search("https://maps.apple.com/?q={text}"), Anything, Some("Search")),
        make("count", "Count words", "textformat.123", Count, Anything, None),
        make("share", "Share", "square.and.arrow.up", Share, Anything, None),
        make("email", "Email this", "envelope", search("mailto:?body={text}"), Anything, Some("Create")),
        make("note", "New note", "note.text", script("tell application \"Notes\" to make new note at default account with properties {body:(item 1 of argv)}"), Anything, Some("Create")),
        make("reminder", "New reminder", "checklist.unchecked", script("tell application \"Reminders\" to make new reminder with properties {name:(item 1 of argv)}"), Anything, Some("Create")),
        make(
            "event",
            "New calendar event",
            "calendar.badge.plus",
            script("set startTime to (current date) + 1 * hours\ntell application \"Calendar\" to tell calendar 1 to make new event with properties {summary:(item 1 of argv), start date:startTime, end date:startTime + 1 * hours}"),
            Anything,
            Some("Create"),
        ),
    ]
}

// ---- shipped actions -----------------------------------------------------------------------------------------------------

pub fn default_actions() -> Vec<SelectionAction> {
    use SelectionActionKind::*;
    use SelectionTarget::*;
    let a = |id: &str, title: &str, symbol: &str, kind, applies| SelectionAction {
        id: id.to_string(),
        title: title.to_string(),
        symbol: symbol.to_string(),
        kind,
        enabled: true,
        applies,
        app_ids: Vec::new(),
        group: None,
    };
    let t = |ops: Vec<TextOp>| Transform {
        ops,
        copy_only: false,
    };
    let mut list = vec![
        a("copy", "Copy", "doc.on.doc", Copy, Anything),
        a("cut", "Cut", "scissors", Cut, EditableOnly),
        a("paste", "Paste", "doc.on.clipboard", Paste, EditableOnly),
        a(
            "paste-plain",
            "Paste without formatting",
            "doc.plaintext",
            PastePlain,
            EditableOnly,
        ),
        a(
            "copy-plain",
            "Copy as plain text",
            "textformat",
            CopyPlain,
            Anything,
        ),
        a(
            "copy-markdown",
            "Copy as Markdown",
            "text.badge.checkmark",
            CopyMarkdown,
            Anything,
        ),
        a(
            "search",
            "Search the web",
            "magnifyingglass",
            UrlTemplate {
                template: "https://www.google.com/search?q={text}".into(),
            },
            Anything,
        ),
        a("open-links", "Open link", "safari", OpenUrls, ContainsUrl),
        a(
            "dictionary",
            "Look up",
            "character.book.closed",
            Dictionary,
            Anything,
        ),
        a(
            "spelling",
            "Spelling",
            "textformat.abc",
            Spelling,
            EditableOnly,
        ),
        a(
            "uppercase",
            "UPPERCASE",
            "textformat.size.larger",
            t(vec![TextOp::Uppercase]),
            EditableOnly,
        ),
        a(
            "lowercase",
            "lowercase",
            "textformat.size.smaller",
            t(vec![TextOp::Lowercase]),
            EditableOnly,
        ),
        a(
            "title-case",
            "Title Case",
            "textformat",
            t(vec![TextOp::TitleCase]),
            EditableOnly,
        ),
        a(
            "sentence-case",
            "Sentence case",
            "text.alignleft",
            t(vec![TextOp::SentenceCase]),
            EditableOnly,
        ),
        a(
            "trim",
            "Trim whitespace",
            "scissors.badge.ellipsis",
            t(vec![TextOp::Trim]),
            EditableOnly,
        ),
        a(
            "dedupe",
            "Remove duplicate lines",
            "list.bullet.indent",
            t(vec![TextOp::RemoveDuplicateLines]),
            MultipleLines,
        ),
        a(
            "sort",
            "Sort lines",
            "arrow.up.arrow.down",
            t(vec![TextOp::SortLines {
                descending: false,
                case_sensitive: false,
                numeric: false,
            }]),
            MultipleLines,
        ),
        a(
            "url-encode",
            "URL encode",
            "link.badge.plus",
            t(vec![TextOp::UrlEncode]),
            EditableOnly,
        ),
        a(
            "url-decode",
            "URL decode",
            "link",
            t(vec![TextOp::UrlDecode]),
            EditableOnly,
        ),
        a(
            "html-escape",
            "HTML escape",
            "chevron.left.forwardslash.chevron.right",
            t(vec![TextOp::HtmlEscape]),
            EditableOnly,
        ),
        a(
            "json-format",
            "Format JSON",
            "curlybraces",
            t(vec![TextOp::JsonFormat]),
            LooksLikeJson,
        ),
        a(
            "translate",
            "Translate",
            "globe",
            Translate {
                target: "en".into(),
                provider: TranslateProvider::Google,
            },
            Anything,
        ),
    ];
    // The less common ones start switched off, so the bar starts short.
    for id in [
        "url-encode",
        "url-decode",
        "html-escape",
        "translate",
        "sentence-case",
        "trim",
    ] {
        if let Some(x) = list.iter_mut().find(|x| x.id == id) {
            x.enabled = false;
        }
    }
    list
}

// ---- sharing ---------------------------------------------------------------------------------------------------------------

#[derive(Debug, Serialize, Deserialize)]
struct Package {
    manifest_version: u32,
    app: String,
    kind: String,
    name: String,
    actions: Vec<SelectionAction>,
}

pub fn export_package(name: &str, actions: &[SelectionAction]) -> Result<String, CoreError> {
    let package = Package {
        manifest_version: PACKAGE_VERSION,
        app: crate::backup::BACKUP_APP_NAME.to_string(),
        kind: PACKAGE_KIND.to_string(),
        name: name.to_string(),
        actions: actions.to_vec(),
    };
    Ok(serde_json::to_string_pretty(&package)?)
}

/// Reads a package of actions. Every action is checked; ids that clash with `existing` are replaced by new ones built
/// from `salt`, and imported actions start switched on but unapproved: a script runs only after the person approves it.
pub fn import_package(
    json: &str,
    existing: &[String],
    salt: &str,
) -> Result<Vec<SelectionAction>, CoreError> {
    let bad = |message: &str| CoreError::Backup {
        message: message.to_string(),
    };
    if json.len() > MAX_PACKAGE_BYTES {
        return Err(bad("the file is not a Kriya action package"));
    }
    let package: Package =
        serde_json::from_str(json).map_err(|_| bad("the file is not a Kriya action package"))?;
    if package.app != crate::backup::BACKUP_APP_NAME || package.kind != PACKAGE_KIND {
        return Err(bad("the file is not a Kriya action package"));
    }
    if package.manifest_version > PACKAGE_VERSION {
        return Err(bad("the package was made by a newer version of Kriya"));
    }
    if package.actions.is_empty() || package.actions.len() > MAX_ACTIONS {
        return Err(bad("the package holds no actions, or too many"));
    }
    let mut taken: HashSet<String> = existing.iter().cloned().collect();
    let mut out = Vec::new();
    for (i, mut action) in package.actions.into_iter().enumerate() {
        action.check().map_err(|e| CoreError::Backup {
            message: e.to_string(),
        })?;
        if taken.contains(&action.id) {
            action.id = format!("{}-{salt}-{i}", action.id);
        }
        taken.insert(action.id.clone());
        action.enabled = true;
        out.push(action);
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn action(id: &str, kind: SelectionActionKind, applies: SelectionTarget) -> SelectionAction {
        SelectionAction {
            id: id.into(),
            title: id.into(),
            symbol: "star".into(),
            kind,
            enabled: true,
            applies,
            app_ids: vec![],
            group: None,
        }
    }

    fn ids(
        actions: &[SelectionAction],
        config: &SelectionConfig,
        app: Option<&str>,
        editable: bool,
        text: &str,
    ) -> Vec<String> {
        actions_for(actions, config, app, editable, text)
    }

    #[test]
    fn shipped_actions_are_valid_and_unique() {
        let list = default_actions();
        let unique: HashSet<_> = list.iter().map(|a| a.id.clone()).collect();
        assert_eq!(unique.len(), list.len());
        for a in &list {
            assert!(a.check().is_ok(), "{} should be valid", a.id);
        }
        assert!(
            list.iter().filter(|a| a.enabled).count() <= 16,
            "the bar starts short"
        );
    }

    #[test]
    fn actions_follow_the_selection() {
        let list = default_actions();
        let config = SelectionConfig::default();
        let read_only = ids(
            &list,
            &config,
            Some("com.apple.Safari"),
            false,
            "just words",
        );
        assert!(read_only.contains(&"copy".to_string()) && !read_only.contains(&"cut".to_string()));
        let editable = ids(
            &list,
            &config,
            Some("com.apple.TextEdit"),
            true,
            "just words",
        );
        assert!(
            editable.contains(&"cut".to_string()) && editable.contains(&"uppercase".to_string())
        );
        assert!(!ids(&list, &config, None, true, "one line").contains(&"sort".to_string()));
        assert!(ids(&list, &config, None, true, "b\na").contains(&"sort".to_string()));
        assert!(ids(&list, &config, None, false, "see https://example.com")
            .contains(&"open-links".to_string()));
        assert!(!ids(&list, &config, None, false, "no links").contains(&"open-links".to_string()));
        assert!(ids(&list, &config, None, true, "{\"a\": 1}").contains(&"json-format".to_string()));
        assert!(!ids(&list, &config, None, true, "plain").contains(&"json-format".to_string()));
    }

    #[test]
    fn excluded_apps_and_bad_lengths_get_nothing() {
        let list = default_actions();
        let config = SelectionConfig::default();
        assert!(ids(
            &list,
            &config,
            Some("com.1password.1password"),
            true,
            "secret"
        )
        .is_empty());
        assert!(ids(&list, &config, None, true, "   ").is_empty());
        let short = SelectionConfig {
            min_length: 5,
            ..SelectionConfig::default()
        };
        assert!(ids(&list, &short, None, true, "abc").is_empty());
        let long = SelectionConfig {
            max_length: 10,
            ..SelectionConfig::default()
        };
        assert!(ids(&list, &long, None, true, "this is longer than ten").is_empty());
    }

    #[test]
    fn per_app_behavior_can_turn_the_bar_off_restrict_it_or_allow_the_fallback() {
        let list = default_actions();
        let config = SelectionConfig {
            app_behaviors: vec![
                AppBehavior {
                    app_id: "com.game".into(),
                    mode: SelectionMode::Off,
                    allow_copy_fallback: false,
                    action_ids: vec![],
                },
                AppBehavior {
                    app_id: "com.editor".into(),
                    mode: SelectionMode::Automatic,
                    allow_copy_fallback: true,
                    action_ids: vec!["copy".into(), "search".into()],
                },
                AppBehavior {
                    app_id: "com.manual".into(),
                    mode: SelectionMode::ManualOnly,
                    allow_copy_fallback: false,
                    action_ids: vec![],
                },
            ],
            ..SelectionConfig::default()
        };
        assert!(ids(&list, &config, Some("com.game"), true, "text").is_empty());
        assert_eq!(
            ids(&list, &config, Some("com.editor"), true, "text"),
            vec!["copy".to_string(), "search".to_string()]
        );
        assert!(behavior_for(&config, Some("com.editor")).allow_copy_fallback);
        assert_eq!(
            behavior_for(&config, Some("com.manual")).mode,
            SelectionMode::ManualOnly
        );
        assert_eq!(
            behavior_for(&config, Some("com.other")).mode,
            SelectionMode::Automatic
        );
        assert!(
            behavior_for(&config, None).allow_copy_fallback,
            "the fallback is on by default"
        );
        let strict = SelectionConfig {
            copy_fallback_default: false,
            ..SelectionConfig::default()
        };
        assert!(!behavior_for(&strict, None).allow_copy_fallback);
    }

    #[test]
    fn app_specific_actions_appear_only_in_their_apps() {
        let mut only = action("only", SelectionActionKind::Copy, SelectionTarget::Anything);
        only.app_ids = vec!["com.a".into()];
        let list = vec![only];
        let config = SelectionConfig::default();
        assert_eq!(
            ids(&list, &config, Some("com.a"), false, "x"),
            vec!["only".to_string()]
        );
        assert!(ids(&list, &config, Some("com.b"), false, "x").is_empty());
        assert!(ids(&list, &config, None, false, "x").is_empty());
        let mut off = list[0].clone();
        off.enabled = false;
        assert!(ids(&[off], &config, Some("com.a"), false, "x").is_empty());
    }

    #[test]
    fn config_is_clamped() {
        let c = SelectionConfig {
            max_visible: 0,
            activation_delay_ms: 99_999,
            min_length: 0,
            max_length: 0,
            manual_modifiers: 0,
            ..SelectionConfig::default()
        }
        .sanitized();
        assert_eq!(
            (c.max_visible, c.activation_delay_ms, c.min_length),
            (2, 3000, 1)
        );
        assert!(c.max_length >= c.min_length);
        assert_eq!(c.manual_key, None);
    }

    #[test]
    fn actions_are_checked() {
        let bad_template = action(
            "t",
            SelectionActionKind::UrlTemplate {
                template: "https://x.test/".into(),
            },
            SelectionTarget::Anything,
        );
        assert!(bad_template.check().is_err());
        let bad_ops = action(
            "o",
            SelectionActionKind::Transform {
                ops: vec![],
                copy_only: false,
            },
            SelectionTarget::Anything,
        );
        assert!(bad_ops.check().is_err());
        let bad_language = action(
            "l",
            SelectionActionKind::Translate {
                target: "english!".into(),
                provider: TranslateProvider::Google,
            },
            SelectionTarget::Anything,
        );
        assert!(bad_language.check().is_err());
        let script = |s: &str| {
            action(
                "s",
                SelectionActionKind::Script {
                    language: FinderScript::Shell,
                    source: s.into(),
                    replace_with_output: false,
                },
                SelectionTarget::Anything,
            )
        };
        assert!(script("").check().is_err());
        assert!(script("echo hi").check().is_ok());
        assert!(script("echo hi").needs_approval());
        assert!(
            !action("c", SelectionActionKind::Copy, SelectionTarget::Anything).needs_approval()
        );
        let mut untitled = action("u", SelectionActionKind::Copy, SelectionTarget::Anything);
        untitled.title = " ".into();
        assert!(untitled.check().is_err());
    }

    #[test]
    fn translation_links_use_the_language_and_encode_the_text() {
        let url = translate_url(TranslateProvider::Google, "fr", "hello world").unwrap();
        assert!(url.contains("tl=fr") && url.ends_with("text=hello%20world"));
        assert!(translate_url(TranslateProvider::DeepL, "pt-BR", "hi")
            .unwrap()
            .contains("#auto/pt-BR/hi"));
        assert!(translate_url(TranslateProvider::Bing, "de", "x")
            .unwrap()
            .contains("to=de"));
        assert!(translate_url(TranslateProvider::Google, "../x", "x").is_err());
        assert!(translate_url(TranslateProvider::Google, "e", "x").is_err());
    }

    #[test]
    fn script_fingerprints_change_with_the_script_or_language() {
        let a = script_fingerprint("shell", "echo hi");
        assert_eq!(a, script_fingerprint("shell", "echo hi"));
        assert_ne!(a, script_fingerprint("shell", "echo hi "));
        assert_ne!(a, script_fingerprint("applescript", "echo hi"));
        assert_eq!(a.len(), 64);
    }

    #[test]
    fn packages_round_trip_and_imports_never_reuse_ids_or_skip_checks() {
        let mine = vec![
            action(
                "one",
                SelectionActionKind::Transform {
                    ops: vec![TextOp::Uppercase],
                    copy_only: true,
                },
                SelectionTarget::Anything,
            ),
            action(
                "two",
                SelectionActionKind::Script {
                    language: FinderScript::Shell,
                    source: "echo $1".into(),
                    replace_with_output: true,
                },
                SelectionTarget::Anything,
            ),
        ];
        let json = export_package("My actions", &mine).unwrap();
        let imported = import_package(&json, &["one".to_string()], "x").unwrap();
        assert_eq!(imported.len(), 2);
        assert_eq!(imported[0].id, "one-x-0", "a clashing id is replaced");
        assert_eq!(imported[1].id, "two");
        assert!(imported.iter().all(|a| a.enabled));

        assert!(import_package("{}", &[], "x").is_err());
        assert!(import_package(&json.replace("selection_actions", "other"), &[], "x").is_err());
        assert!(import_package(
            &json.replace("\"manifest_version\": 1", "\"manifest_version\": 9"),
            &[],
            "x"
        )
        .is_err());
        let hostile = json.replace("echo $1", "");
        assert!(
            import_package(&hostile, &[], "x").is_err(),
            "an empty script is refused"
        );
        let empty = export_package("none", &[]).unwrap();
        assert!(import_package(&empty, &[], "x").is_err());
    }

    #[test]
    fn actions_round_trip_through_json() {
        for a in default_actions() {
            let json = serde_json::to_string(&a).unwrap();
            assert_eq!(serde_json::from_str::<SelectionAction>(&json).unwrap(), a);
        }
    }

    #[test]
    fn suggested_actions_are_valid_unique_and_grouped_sensibly() {
        let list = suggested_actions();
        let mut ids: Vec<&str> = list.iter().map(|a| a.id.as_str()).collect();
        ids.sort_unstable();
        let count = ids.len();
        ids.dedup();
        assert_eq!(ids.len(), count, "ids are unique");
        let shipped: Vec<String> = default_actions().into_iter().map(|a| a.id).collect();
        for action in &list {
            action
                .check()
                .unwrap_or_else(|e| panic!("{}: {e:?}", action.id));
            assert!(
                !shipped.contains(&action.id),
                "{} repeats a shipped action",
                action.id
            );
        }
        // The scripts are the only ones that need approval; everything else runs freely.
        assert!(list
            .iter()
            .filter(|a| a.needs_approval())
            .all(|a| a.group.as_deref() == Some("Create")));
        assert!(list.iter().any(|a| a.group.as_deref() == Some("Markdown")));
    }

    #[test]
    fn key_press_and_open_in_app_actions_are_checked() {
        let press = |modifiers| {
            action(
                "k",
                SelectionActionKind::PressKeys {
                    key_code: 11,
                    modifiers,
                },
                SelectionTarget::EditableOnly,
            )
        };
        assert!(press(crate::actions::modifiers::COMMAND).check().is_ok());
        assert!(press(0).check().is_err(), "a key press needs a modifier");
        assert!(press(1 << 40).check().is_err());
        let open = |app: &str| {
            action(
                "o",
                SelectionActionKind::OpenInApp { app_id: app.into() },
                SelectionTarget::Anything,
            )
        };
        assert!(open("com.apple.TextEdit").check().is_ok());
        assert!(open("  ").check().is_err());
        let mut long = action("g", SelectionActionKind::Count, SelectionTarget::Anything);
        long.group = Some("x".repeat(41));
        assert!(long.check().is_err());
    }
}
