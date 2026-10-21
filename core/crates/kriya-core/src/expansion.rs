//! Text expansion: snippets with abbreviations, the matcher that watches what is typed, conflict checks between
//! abbreviations, searching, and the packages used to share snippets. Pure logic; the shell supplies the typing.

use std::collections::HashSet;
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

use crate::error::CoreError;

pub const MAX_BODY_BYTES: usize = 200_000;
pub const MAX_SNIPPETS: usize = 5000;
pub const MIN_ABBREVIATION: usize = 2;
pub const MAX_ABBREVIATION: usize = 30;
const BUFFER_CAP: usize = 64;
pub const PACKAGE_KIND: &str = "text_snippets";
pub const PACKAGE_VERSION: u32 = 1;
pub const MAX_PACKAGE_BYTES: usize = 5 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum ExpandOn {
    /// When a space, punctuation mark or Return is typed after the abbreviation.
    #[default]
    Delimiter,
    /// As soon as the last letter of the abbreviation is typed.
    Immediately,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct ExpansionSnippet {
    pub id: String,
    pub title: String,
    /// What you type to get the snippet. A snippet without one is inserted from search or a shortcut.
    pub abbreviation: Option<String>,
    /// The text, with placeholders such as {date} and {cursor}.
    pub body: String,
    pub category: Option<String>,
    pub favorite: bool,
    pub enabled: bool,
    /// Expand only in these apps. Empty means every app.
    pub app_ids: Vec<String>,
    pub case_sensitive: bool,
    pub expand_on: ExpandOn,
    pub use_count: u32,
    pub created_at: i64,
    pub updated_at: i64,
}

impl ExpansionSnippet {
    pub fn check(&self) -> Result<(), CoreError> {
        if self.id.trim().is_empty() {
            return Err(CoreError::invalid("a snippet needs an id"));
        }
        if self.title.trim().is_empty() || self.title.chars().count() > 100 {
            return Err(CoreError::invalid(
                "a snippet needs a name of up to 100 characters",
            ));
        }
        if self.body.trim().is_empty() {
            return Err(CoreError::invalid("a snippet needs some text"));
        }
        if self.body.len() > MAX_BODY_BYTES {
            return Err(CoreError::invalid("the snippet is too long"));
        }
        if let Some(a) = &self.abbreviation {
            let n = a.chars().count();
            if !(MIN_ABBREVIATION..=MAX_ABBREVIATION).contains(&n) {
                return Err(CoreError::invalid(format!(
                    "an abbreviation needs {MIN_ABBREVIATION} to {MAX_ABBREVIATION} characters"
                )));
            }
            if a.chars().any(|c| c.is_whitespace() || c.is_control()) {
                return Err(CoreError::invalid(
                    "an abbreviation cannot hold spaces or line breaks",
                ));
            }
        }
        if self
            .category
            .as_ref()
            .is_some_and(|c| c.chars().count() > 40)
        {
            return Err(CoreError::invalid(
                "a category name can be up to 40 characters",
            ));
        }
        Ok(())
    }

    /// The same snippet with its text tidied: an empty abbreviation or category becomes none.
    pub fn tidied(mut self) -> Self {
        self.abbreviation = self
            .abbreviation
            .map(|a| a.trim().to_string())
            .filter(|a| !a.is_empty());
        self.category = self
            .category
            .map(|c| c.trim().to_string())
            .filter(|c| !c.is_empty());
        self.title = self.title.trim().to_string();
        let mut seen = HashSet::new();
        self.app_ids = self
            .app_ids
            .iter()
            .map(|a| a.trim().to_string())
            .filter(|a| !a.is_empty() && seen.insert(a.clone()))
            .collect();
        self
    }
}

// ---- conflicts -----------------------------------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SnippetConflictKind {
    /// Two snippets have the same abbreviation where they would both expand.
    Duplicate,
    /// The shorter abbreviation expands as soon as it is typed, so the longer one can never be finished.
    Shadowed,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SnippetConflict {
    pub snippet_id: String,
    pub title: String,
    pub abbreviation: String,
    pub kind: SnippetConflictKind,
}

fn scopes_overlap(a: &[String], b: &[String]) -> bool {
    a.is_empty() || b.is_empty() || a.iter().any(|x| b.contains(x))
}

fn same_text(a: &str, b: &str, case_sensitive: bool) -> bool {
    if case_sensitive {
        a == b
    } else {
        a.to_lowercase() == b.to_lowercase()
    }
}

/// Problems between a snippet's abbreviation and everyone else's.
pub fn abbreviation_conflicts(
    candidate: &ExpansionSnippet,
    all: &[ExpansionSnippet],
) -> Vec<SnippetConflict> {
    let Some(a) = candidate.abbreviation.as_deref().filter(|a| !a.is_empty()) else {
        return Vec::new();
    };
    let mut found = Vec::new();
    for other in all {
        if other.id == candidate.id || !other.enabled {
            continue;
        }
        let Some(b) = other.abbreviation.as_deref().filter(|b| !b.is_empty()) else {
            continue;
        };
        if !scopes_overlap(&candidate.app_ids, &other.app_ids) {
            continue;
        }
        let insensitive = !(candidate.case_sensitive && other.case_sensitive);
        let kind = if same_text(a, b, !insensitive) {
            Some(SnippetConflictKind::Duplicate)
        } else {
            let (la, lb) = (a.to_lowercase(), b.to_lowercase());
            // `short` is a prefix of `long`: typing `long` passes through `short`.
            let (short, long, short_snippet) = if la.len() <= lb.len() {
                (&la, &lb, candidate)
            } else {
                (&lb, &la, other)
            };
            (long.starts_with(short.as_str()) && short_snippet.expand_on == ExpandOn::Immediately)
                .then_some(SnippetConflictKind::Shadowed)
        };
        if let Some(kind) = kind {
            found.push(SnippetConflict {
                snippet_id: other.id.clone(),
                title: other.title.clone(),
                abbreviation: b.to_string(),
                kind,
            });
        }
    }
    found
}

// ---- searching -------------------------------------------------------------------------------------------------------

/// Snippets matching every word in `query` (in the name, abbreviation, text or category), favorites first, then the
/// most used.
pub fn search_snippets(
    all: &[ExpansionSnippet],
    query: &str,
    category: Option<&str>,
    favorites_only: bool,
) -> Vec<ExpansionSnippet> {
    let words: Vec<String> = query.split_whitespace().map(str::to_lowercase).collect();
    let mut found: Vec<ExpansionSnippet> = all
        .iter()
        .filter(|s| !favorites_only || s.favorite)
        .filter(|s| category.is_none_or(|c| s.category.as_deref() == Some(c)))
        .filter(|s| {
            let hay = format!(
                "{}\n{}\n{}\n{}",
                s.title,
                s.abbreviation.as_deref().unwrap_or(""),
                s.category.as_deref().unwrap_or(""),
                s.body
            )
            .to_lowercase();
            words.iter().all(|w| hay.contains(w.as_str()))
        })
        .cloned()
        .collect();
    found.sort_by(|a, b| {
        b.favorite
            .cmp(&a.favorite)
            .then(b.use_count.cmp(&a.use_count))
            .then_with(|| a.title.to_lowercase().cmp(&b.title.to_lowercase()))
    });
    found
}

pub fn categories(all: &[ExpansionSnippet]) -> Vec<String> {
    let mut names: Vec<String> = all
        .iter()
        .filter_map(|s| s.category.clone())
        .collect::<HashSet<_>>()
        .into_iter()
        .collect();
    names.sort_by_key(|n| n.to_lowercase());
    names
}

// ---- the matcher -----------------------------------------------------------------------------------------------------

struct Compiled {
    id: String,
    chars: Vec<char>,
    lower: Vec<char>,
    case_sensitive: bool,
    on: ExpandOn,
    app_ids: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ExpansionMatch {
    pub snippet_id: String,
    /// How many characters before the cursor to delete: the abbreviation, and the delimiter if one ended it.
    pub delete_count: u32,
    /// The delimiter that ended the abbreviation, to type again after the expansion. Empty for an immediate match.
    pub trailing: String,
}

struct MatcherState {
    snippets: Vec<Compiled>,
    buffer: Vec<char>,
}

/// Watches typed characters and says when an abbreviation was typed. It keeps only the last few characters, forgets
/// them whenever typing is interrupted (a click, an arrow key, a shortcut), and never looks at anything but what the shell feeds it.
#[derive(uniffi::Object)]
pub struct ExpansionMatcher {
    state: Mutex<MatcherState>,
}

fn is_delimiter(c: char) -> bool {
    c.is_whitespace()
        || matches!(
            c,
            '.' | ',' | ';' | ':' | '!' | '?' | ')' | ']' | '}' | '"' | '\'' | '/' | '\\'
        )
}

fn lower_char(c: char) -> char {
    c.to_lowercase().next().unwrap_or(c)
}

impl MatcherState {
    /// The longest abbreviation that the buffer ends with, among snippets of the wanted kind that apply in this app.
    fn find(&self, on: ExpandOn, app: Option<&str>, upto: usize) -> Option<(usize, &Compiled)> {
        let window = &self.buffer[..upto];
        self.snippets
            .iter()
            .filter(|s| s.on == on)
            .filter(|s| {
                s.app_ids.is_empty() || app.is_some_and(|a| s.app_ids.iter().any(|x| x == a))
            })
            .filter(|s| window.len() >= s.chars.len())
            .filter(|s| {
                let tail = &window[window.len() - s.chars.len()..];
                if s.case_sensitive {
                    tail == s.chars.as_slice()
                } else {
                    tail.iter()
                        .map(|c| lower_char(*c))
                        .eq(s.lower.iter().copied())
                }
            })
            .filter(|s| {
                // An abbreviation that starts with a letter or digit must start a word: "xsig" is not "sig".
                let start = window.len() - s.chars.len();
                let first = s.chars[0];
                !(first.is_alphanumeric() && start > 0 && window[start - 1].is_alphanumeric())
            })
            .map(|s| (s.chars.len(), s))
            .max_by_key(|(n, _)| *n)
    }
}

#[uniffi::export]
impl ExpansionMatcher {
    #[uniffi::constructor]
    pub fn new() -> Self {
        ExpansionMatcher {
            state: Mutex::new(MatcherState {
                snippets: Vec::new(),
                buffer: Vec::new(),
            }),
        }
    }

    /// Replaces the snippets watched for. Only enabled snippets with an abbreviation count.
    pub fn set_snippets(&self, snippets: Vec<ExpansionSnippet>) {
        let compiled = snippets
            .into_iter()
            .filter(|s| s.enabled)
            .filter_map(|s| {
                let abbr = s.abbreviation.filter(|a| !a.is_empty())?;
                let chars: Vec<char> = abbr.chars().collect();
                Some(Compiled {
                    id: s.id,
                    lower: chars.iter().map(|c| lower_char(*c)).collect(),
                    chars,
                    case_sensitive: s.case_sensitive,
                    on: s.expand_on,
                    app_ids: s.app_ids,
                })
            })
            .collect();
        let mut state = self.lock();
        state.snippets = compiled;
        state.buffer.clear();
    }

    /// One typed character. Returns what to expand, if the character completed an abbreviation.
    pub fn feed(&self, character: String, app_id: Option<String>) -> Option<ExpansionMatch> {
        let mut chars = character.chars();
        let c = chars.next()?;
        let mut state = self.lock();
        if chars.next().is_some() {
            state.buffer.clear();
            return None;
        }
        state.buffer.push(c);
        if state.buffer.len() > BUFFER_CAP {
            let extra = state.buffer.len() - BUFFER_CAP;
            state.buffer.drain(..extra);
        }
        let len = state.buffer.len();
        let app = app_id.as_deref();

        let delimited = if is_delimiter(c) {
            state
                .find(ExpandOn::Delimiter, app, len - 1)
                .map(|(n, s)| (n, s.id.clone(), true))
        } else {
            None
        };
        let immediate = state
            .find(ExpandOn::Immediately, app, len)
            .map(|(n, s)| (n, s.id.clone(), false));
        // The longest abbreviation wins; a delimited match counts the delimiter that ended it.
        let best = match (delimited, immediate) {
            (Some(d), Some(i)) => Some(if d.0 >= i.0 { d } else { i }),
            (d, i) => d.or(i),
        };
        let (n, id, with_delimiter) = best?;
        state.buffer.clear();
        Some(ExpansionMatch {
            snippet_id: id,
            delete_count: (n + usize::from(with_delimiter)) as u32,
            trailing: if with_delimiter {
                c.to_string()
            } else {
                String::new()
            },
        })
    }

    pub fn backspace(&self) {
        self.lock().buffer.pop();
    }

    /// Forgets what was typed: call it on a click, an arrow key, a shortcut, or a change of app.
    pub fn reset(&self) {
        self.lock().buffer.clear();
    }
}

impl Default for ExpansionMatcher {
    fn default() -> Self {
        Self::new()
    }
}

impl ExpansionMatcher {
    fn lock(&self) -> std::sync::MutexGuard<'_, MatcherState> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }
}

// ---- sharing ---------------------------------------------------------------------------------------------------------

#[derive(Debug, Serialize, Deserialize)]
struct Package {
    manifest_version: u32,
    app: String,
    kind: String,
    snippets: Vec<ExpansionSnippet>,
}

pub fn export_package(snippets: &[ExpansionSnippet]) -> Result<String, CoreError> {
    let cleaned: Vec<ExpansionSnippet> = snippets
        .iter()
        .cloned()
        .map(|mut s| {
            s.use_count = 0;
            s
        })
        .collect();
    Ok(serde_json::to_string_pretty(&Package {
        manifest_version: PACKAGE_VERSION,
        app: crate::backup::BACKUP_APP_NAME.to_string(),
        kind: PACKAGE_KIND.to_string(),
        snippets: cleaned,
    })?)
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TextSnippetImportSummary {
    pub added: u32,
    pub skipped_duplicates: u32,
    /// Snippets whose abbreviation clashed with one you already have, so they came in without it.
    pub abbreviations_dropped: u32,
}

/// Reads a package and returns the snippets to add (with new ids) and what happened. Nothing that exists is changed.
pub fn import_package(
    json: &str,
    existing: &[ExpansionSnippet],
    now: i64,
) -> Result<(Vec<ExpansionSnippet>, TextSnippetImportSummary), CoreError> {
    let bad = |message: &str| CoreError::Backup {
        message: message.to_string(),
    };
    if json.len() > MAX_PACKAGE_BYTES {
        return Err(bad("the file is not a Kriya snippet file"));
    }
    let package: Package =
        serde_json::from_str(json).map_err(|_| bad("the file is not a Kriya snippet file"))?;
    if package.app != crate::backup::BACKUP_APP_NAME || package.kind != PACKAGE_KIND {
        return Err(bad("the file is not a Kriya snippet file"));
    }
    if package.manifest_version > PACKAGE_VERSION {
        return Err(bad("the file was made by a newer version of Kriya"));
    }
    if package.snippets.len() > MAX_SNIPPETS {
        return Err(bad("the file holds too many snippets"));
    }
    let mut all: Vec<ExpansionSnippet> = existing.to_vec();
    let mut added = Vec::new();
    let mut summary = TextSnippetImportSummary {
        added: 0,
        skipped_duplicates: 0,
        abbreviations_dropped: 0,
    };
    for (i, snippet) in package.snippets.into_iter().enumerate() {
        let mut s = snippet.tidied();
        s.check().map_err(|e| CoreError::Backup {
            message: e.to_string(),
        })?;
        if all
            .iter()
            .any(|x| x.body == s.body && x.abbreviation == s.abbreviation && x.title == s.title)
        {
            summary.skipped_duplicates += 1;
            continue;
        }
        s.id = format!("imp-{now:x}-{i}");
        s.use_count = 0;
        s.created_at = now;
        s.updated_at = now;
        if abbreviation_conflicts(&s, &all)
            .iter()
            .any(|c| c.kind == SnippetConflictKind::Duplicate)
        {
            s.abbreviation = None;
            summary.abbreviations_dropped += 1;
        }
        all.push(s.clone());
        added.push(s);
        summary.added += 1;
    }
    Ok((added, summary))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn snippet(id: &str, abbr: Option<&str>, body: &str) -> ExpansionSnippet {
        ExpansionSnippet {
            id: id.into(),
            title: format!("Snippet {id}"),
            abbreviation: abbr.map(str::to_string),
            body: body.into(),
            category: None,
            favorite: false,
            enabled: true,
            app_ids: vec![],
            case_sensitive: false,
            expand_on: ExpandOn::Delimiter,
            use_count: 0,
            created_at: 1,
            updated_at: 1,
        }
    }

    fn matcher(list: Vec<ExpansionSnippet>) -> ExpansionMatcher {
        let m = ExpansionMatcher::new();
        m.set_snippets(list);
        m
    }

    fn type_text(m: &ExpansionMatcher, text: &str, app: Option<&str>) -> Option<ExpansionMatch> {
        let mut last = None;
        for c in text.chars() {
            last = m.feed(c.to_string(), app.map(str::to_string));
            if last.is_some() {
                break;
            }
        }
        last
    }

    #[test]
    fn a_delimited_abbreviation_expands_when_the_space_is_typed() {
        let m = matcher(vec![snippet("a", Some("brb"), "be right back")]);
        assert_eq!(type_text(&m, "brb", None), None, "not yet: no delimiter");
        let hit = m.feed(" ".into(), None).unwrap();
        assert_eq!(
            hit,
            ExpansionMatch {
                snippet_id: "a".into(),
                delete_count: 4,
                trailing: " ".into()
            }
        );
        assert!(
            type_text(&m, "brb", None).is_none(),
            "the buffer was cleared"
        );
    }

    #[test]
    fn an_immediate_abbreviation_expands_as_the_last_letter_arrives() {
        let mut s = snippet("a", Some(";sig"), "Regards");
        s.expand_on = ExpandOn::Immediately;
        let m = matcher(vec![s]);
        let hit = type_text(&m, "hello ;sig", None).unwrap();
        assert_eq!(
            hit,
            ExpansionMatch {
                snippet_id: "a".into(),
                delete_count: 4,
                trailing: String::new()
            }
        );
    }

    #[test]
    fn abbreviations_must_start_a_word() {
        let m = matcher(vec![snippet("a", Some("sig"), "Regards")]);
        assert!(
            type_text(&m, "design ", None).is_none(),
            "\"sig\" inside a word is not the abbreviation"
        );
        m.reset();
        assert!(type_text(&m, "my sig ", None).is_some());
        let mut symbol = snippet("b", Some(";x"), "X");
        symbol.expand_on = ExpandOn::Immediately;
        let m = matcher(vec![symbol]);
        assert!(
            type_text(&m, "word;x", None).is_some(),
            "a symbol-led abbreviation can follow a letter"
        );
    }

    #[test]
    fn case_rules_are_per_snippet() {
        let loose = matcher(vec![snippet("a", Some("BRB"), "x")]);
        assert!(type_text(&loose, "brb ", None).is_some());
        let mut strict = snippet("a", Some("BRB"), "x");
        strict.case_sensitive = true;
        let m = matcher(vec![strict]);
        assert!(type_text(&m, "brb ", None).is_none());
        m.reset();
        assert!(type_text(&m, "BRB ", None).is_some());
    }

    #[test]
    fn app_limits_and_disabled_snippets_are_respected() {
        let mut only = snippet("a", Some("mail"), "x");
        only.app_ids = vec!["com.apple.mail".into()];
        let mut off = snippet("b", Some("off"), "x");
        off.enabled = false;
        let m = matcher(vec![only, off]);
        assert!(type_text(&m, "mail ", Some("com.apple.Safari")).is_none());
        m.reset();
        assert!(type_text(&m, "mail ", None).is_none());
        m.reset();
        assert!(type_text(&m, "mail ", Some("com.apple.mail")).is_some());
        m.reset();
        assert!(type_text(&m, "off ", Some("com.apple.mail")).is_none());
    }

    #[test]
    fn the_longest_abbreviation_wins() {
        let m = matcher(vec![
            snippet("short", Some("ad"), "x"),
            snippet("long", Some("mad"), "y"),
        ]);
        assert_eq!(type_text(&m, "mad ", None).unwrap().snippet_id, "long");
    }

    #[test]
    fn interruptions_and_corrections_are_handled() {
        let m = matcher(vec![snippet("a", Some("brb"), "x")]);
        m.feed("b".into(), None);
        m.feed("r".into(), None);
        m.reset();
        m.feed("b".into(), None);
        assert!(
            m.feed(" ".into(), None).is_none(),
            "a reset forgets the start"
        );
        m.reset();
        for c in "brx".chars() {
            m.feed(c.to_string(), None);
        }
        m.backspace();
        m.feed("b".into(), None);
        assert!(
            m.feed(" ".into(), None).is_some(),
            "backspace then retype completes it"
        );
        assert!(
            m.feed("ab".into(), None).is_none(),
            "more than one character at once is not typing"
        );
    }

    #[test]
    fn a_delimiter_can_be_punctuation_or_a_line_break() {
        let m = matcher(vec![snippet("a", Some("brb"), "x")]);
        assert_eq!(type_text(&m, "brb.", None).unwrap().trailing, ".");
        m.reset();
        assert_eq!(type_text(&m, "brb\n", None).unwrap().trailing, "\n");
    }

    #[test]
    fn matching_is_by_characters_not_bytes() {
        let m = matcher(vec![snippet("a", Some("café"), "x")]);
        assert_eq!(type_text(&m, "café ", None).unwrap().delete_count, 5);
    }

    #[test]
    fn abbreviations_are_checked_for_clashes() {
        let a = snippet("a", Some("brb"), "x");
        let mut b = snippet("b", Some("BRB"), "y");
        assert_eq!(
            abbreviation_conflicts(&b, std::slice::from_ref(&a))[0].kind,
            SnippetConflictKind::Duplicate
        );
        b.case_sensitive = true;
        let mut a_strict = a.clone();
        a_strict.case_sensitive = true;
        assert!(
            abbreviation_conflicts(&b, std::slice::from_ref(&a_strict)).is_empty(),
            "case-sensitive and different"
        );
        let mut other_app = snippet("c", Some("brb"), "z");
        other_app.app_ids = vec!["com.x".into()];
        let mut only_y = snippet("d", Some("brb"), "z");
        only_y.app_ids = vec!["com.y".into()];
        assert!(
            abbreviation_conflicts(&only_y, &[other_app]).is_empty(),
            "different apps never meet"
        );

        let mut short = snippet("s", Some("ad"), "x");
        short.expand_on = ExpandOn::Immediately;
        let long = snippet("l", Some("add"), "y");
        assert_eq!(
            abbreviation_conflicts(&long, &[short])[0].kind,
            SnippetConflictKind::Shadowed
        );
        assert!(abbreviation_conflicts(&snippet("n", None, "x"), &[a]).is_empty());
    }

    #[test]
    fn snippets_are_validated_and_tidied() {
        assert!(snippet("a", Some("ok"), "body").check().is_ok());
        assert!(
            snippet("a", Some("x"), "body").check().is_err(),
            "too short"
        );
        assert!(snippet("a", Some("two words"), "body").check().is_err());
        assert!(snippet("a", None, "  ").check().is_err());
        let mut untitled = snippet("a", None, "body");
        untitled.title = " ".into();
        assert!(untitled.check().is_err());
        let t = snippet("a", Some("  "), "body").tidied();
        assert_eq!(t.abbreviation, None);
    }

    #[test]
    fn search_ranks_favorites_then_use() {
        let mut a = snippet("a", Some("sig"), "Kind regards, Ada");
        a.use_count = 5;
        let mut b = snippet("b", Some("addr"), "1 Main Street");
        b.favorite = true;
        b.category = Some("Home".into());
        let c = snippet("c", None, "Regards from Cy");
        let all = vec![a, b, c];
        assert_eq!(
            search_snippets(&all, "regards", None, false)
                .iter()
                .map(|s| s.id.as_str())
                .collect::<Vec<_>>(),
            ["a", "c"]
        );
        assert_eq!(search_snippets(&all, "", None, true).len(), 1);
        assert_eq!(
            search_snippets(&all, "main home", None, false).len(),
            1,
            "category text counts"
        );
        assert_eq!(search_snippets(&all, "", Some("Home"), false)[0].id, "b");
        assert_eq!(
            search_snippets(&all, "", None, false)[0].id,
            "b",
            "favorites first"
        );
        assert_eq!(categories(&all), vec!["Home".to_string()]);
    }

    #[test]
    fn packages_round_trip_without_overwriting_or_clashing() {
        let mine = vec![
            snippet("a", Some("brb"), "be right back"),
            snippet("b", Some("omw"), "on my way"),
        ];
        let json = export_package(&mine).unwrap();
        let existing = vec![snippet("x", Some("brb"), "something else")];
        let (added, summary) = import_package(&json, &existing, 255).unwrap();
        assert_eq!(
            (
                summary.added,
                summary.skipped_duplicates,
                summary.abbreviations_dropped
            ),
            (2, 0, 1)
        );
        assert_eq!(
            added[0].abbreviation, None,
            "its abbreviation clashed with an existing one"
        );
        assert_eq!(added[1].abbreviation.as_deref(), Some("omw"));
        assert!(added.iter().all(|s| s.id.starts_with("imp-ff-")));

        let (again, s2) = import_package(&json, &mine, 1).unwrap();
        assert!(again.is_empty());
        assert_eq!(s2.skipped_duplicates, 2);
        assert!(import_package("{}", &[], 1).is_err());
        assert!(import_package(&json.replace("text_snippets", "x"), &[], 1).is_err());
        assert!(import_package(
            &json.replace("\"manifest_version\": 1", "\"manifest_version\": 3"),
            &[],
            1
        )
        .is_err());
        assert!(import_package(&json.replace("be right back", ""), &[], 1).is_err());
    }
}
