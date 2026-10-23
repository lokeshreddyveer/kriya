//! Keyboard shortcuts that run actions, snippets and commands, globally or in chosen apps, and the checks that keep them
//! from clashing with each other, with other parts of Kriya, or with the shortcuts macOS and most apps rely on.

use std::collections::HashSet;

use serde::{Deserialize, Serialize};

use crate::actions::modifiers as m;
use crate::clipboard::DEFAULT_EXCLUDED_APPS;
use crate::error::CoreError;
use crate::expansion::ExpandOn;

pub const MAX_SHORTCUTS: usize = 500;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ShortcutScope {
    Global,
    OnlyApps { app_ids: Vec<String> },
    ExceptApps { app_ids: Vec<String> },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ShortcutTarget {
    /// A saved action from the action library.
    Action { action_id: String },
    /// Inserts a snippet (its placeholders filled in).
    Snippet { snippet_id: String },
    /// A command by name: `window.left_half`, `workflow.<id>`, `clipboard.quick` and so on.
    Command { command: String },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct KeyShortcut {
    pub id: String,
    pub name: String,
    pub key_code: u16,
    pub modifiers: u64,
    pub scope: ShortcutScope,
    pub target: ShortcutTarget,
    pub enabled: bool,
}

/// A combination that something else already owns.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct ReservedKey {
    pub key_code: u16,
    pub modifiers: u64,
    pub owner: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ShortcutConflictKind {
    /// macOS or an essential editing shortcut.
    System,
    /// Another part of Kriya uses these keys.
    OtherFeature,
    /// Another of your shortcuts uses these keys in an overlapping set of apps.
    Duplicate,
    /// Many apps use this combination themselves.
    CommonlyUsed,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ShortcutConflict {
    pub kind: ShortcutConflictKind,
    pub with: String,
    /// A blocking conflict stops the shortcut from being saved; the others are warnings.
    pub blocking: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
#[serde(default)]
pub struct KeyboardConfig {
    /// Apps where typed abbreviations are never expanded.
    pub expansion_excluded_app_ids: Vec<String>,
    pub expansion_default_expand_on: ExpandOn,
    /// Type short snippets key by key instead of pasting them, which leaves the clipboard alone.
    pub type_instead_of_paste: bool,
    /// The quick command launcher's shortcut.
    pub palette_key: Option<u16>,
    pub palette_modifiers: u64,
}

impl Default for KeyboardConfig {
    fn default() -> Self {
        KeyboardConfig {
            expansion_excluded_app_ids: DEFAULT_EXCLUDED_APPS
                .iter()
                .map(|s| (*s).to_string())
                .collect(),
            expansion_default_expand_on: ExpandOn::Delimiter,
            type_instead_of_paste: true,
            palette_key: Some(49),
            palette_modifiers: m::CONTROL | m::OPTION | m::COMMAND,
        }
    }
}

impl KeyboardConfig {
    pub fn sanitized(mut self) -> Self {
        let mut seen = HashSet::new();
        self.expansion_excluded_app_ids = self
            .expansion_excluded_app_ids
            .iter()
            .map(|a| a.trim().to_string())
            .filter(|a| !a.is_empty() && seen.insert(a.clone()))
            .collect();
        self.palette_modifiers &= m::ALL;
        if self.palette_modifiers == 0 {
            self.palette_key = None;
        }
        self
    }

    pub fn is_excluded(&self, app_id: Option<&str>) -> bool {
        app_id.is_some_and(|a| self.expansion_excluded_app_ids.iter().any(|x| x == a))
    }
}

// ---- keys ------------------------------------------------------------------------------------------------------------

/// Function keys can be used alone; every other key needs a modifier, or it would take over typing.
const FUNCTION_KEYS: [u16; 20] = [
    122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
];

pub fn needs_modifier(key_code: u16) -> bool {
    !FUNCTION_KEYS.contains(&key_code)
}

impl KeyShortcut {
    pub fn check(&self) -> Result<(), CoreError> {
        if self.id.trim().is_empty() {
            return Err(CoreError::invalid("a shortcut needs an id"));
        }
        if self.name.trim().is_empty() || self.name.chars().count() > 80 {
            return Err(CoreError::invalid(
                "a shortcut needs a name of up to 80 characters",
            ));
        }
        if self.key_code > 127 {
            return Err(CoreError::invalid("that key is not available"));
        }
        if self.modifiers & !m::ALL != 0 {
            return Err(CoreError::invalid("the shortcut has unknown modifier keys"));
        }
        if needs_modifier(self.key_code)
            && self.modifiers & (m::COMMAND | m::CONTROL | m::OPTION) == 0
        {
            return Err(CoreError::invalid(
                "a shortcut needs ⌘, ⌃ or ⌥ held with the key, or it would take over normal typing",
            ));
        }
        match &self.target {
            ShortcutTarget::Action { action_id } if action_id.trim().is_empty() => {
                return Err(CoreError::invalid("choose an action"))
            }
            ShortcutTarget::Snippet { snippet_id } if snippet_id.trim().is_empty() => {
                return Err(CoreError::invalid("choose a snippet"))
            }
            ShortcutTarget::Command { command } if command.trim().is_empty() => {
                return Err(CoreError::invalid("choose a command"))
            }
            _ => {}
        }
        match &self.scope {
            ShortcutScope::OnlyApps { app_ids } | ShortcutScope::ExceptApps { app_ids }
                if app_ids.is_empty() =>
            {
                return Err(CoreError::invalid(
                    "choose at least one app, or make the shortcut global",
                ));
            }
            _ => {}
        }
        Ok(())
    }
}

/// Whether the shortcut is active when this app is in front.
pub fn applies_in(scope: &ShortcutScope, app_id: Option<&str>) -> bool {
    match scope {
        ShortcutScope::Global => true,
        ShortcutScope::OnlyApps { app_ids } => {
            app_id.is_some_and(|a| app_ids.iter().any(|x| x == a))
        }
        ShortcutScope::ExceptApps { app_ids } => {
            !app_id.is_some_and(|a| app_ids.iter().any(|x| x == a))
        }
    }
}

/// Whether two scopes can both be active in some app.
pub fn scopes_overlap(a: &ShortcutScope, b: &ShortcutScope) -> bool {
    let mut apps: Vec<&str> = Vec::new();
    for scope in [a, b] {
        if let ShortcutScope::OnlyApps { app_ids } | ShortcutScope::ExceptApps { app_ids } = scope {
            apps.extend(app_ids.iter().map(String::as_str));
        }
    }
    // Every named app, plus "some other app", which is where the open-ended scopes meet.
    apps.iter()
        .any(|app| applies_in(a, Some(app)) && applies_in(b, Some(app)))
        || (applies_in(a, None) && applies_in(b, None))
}

/// The shortcut to run for a key press in an app. The first enabled match in list order.
pub fn find_shortcut(
    list: &[KeyShortcut],
    key_code: u16,
    modifiers: u64,
    app_id: Option<&str>,
) -> Option<KeyShortcut> {
    list.iter()
        .find(|s| {
            s.enabled
                && s.key_code == key_code
                && s.modifiers == modifiers
                && applies_in(&s.scope, app_id)
        })
        .cloned()
}

// ---- conflicts -----------------------------------------------------------------------------------------------------

/// Keys macOS or everyday editing depend on. Taking them over would break things, so they cannot be used.
pub fn system_reserved() -> Vec<ReservedKey> {
    let r = |key_code: u16, modifiers: u64, owner: &str| ReservedKey {
        key_code,
        modifiers,
        owner: owner.to_string(),
    };
    let cmd = m::COMMAND;
    vec![
        r(12, cmd, "Quit (⌘Q)"),
        r(13, cmd, "Close window (⌘W)"),
        r(4, cmd, "Hide (⌘H)"),
        r(46, cmd, "Minimize (⌘M)"),
        r(8, cmd, "Copy (⌘C)"),
        r(9, cmd, "Paste (⌘V)"),
        r(7, cmd, "Cut (⌘X)"),
        r(0, cmd, "Select All (⌘A)"),
        r(6, cmd, "Undo (⌘Z)"),
        r(6, cmd | m::SHIFT, "Redo (⇧⌘Z)"),
        r(48, cmd, "App switcher (⌘Tab)"),
        r(49, cmd, "Spotlight (⌘Space)"),
        r(49, cmd | m::OPTION, "Finder search (⌥⌘Space)"),
        r(53, cmd | m::OPTION, "Force Quit (⌥⌘Esc)"),
        r(43, cmd, "Settings (⌘,)"),
        r(50, cmd, "Switch windows (⌘`)"),
        r(12, cmd | m::CONTROL, "Lock screen (⌃⌘Q)"),
        r(20, cmd | m::SHIFT, "Screenshot (⇧⌘3)"),
        r(21, cmd | m::SHIFT, "Screenshot (⇧⌘4)"),
        r(23, cmd | m::SHIFT, "Screenshot (⇧⌘5)"),
        r(123, m::CONTROL, "Mission Control: previous space (⌃←)"),
        r(124, m::CONTROL, "Mission Control: next space (⌃→)"),
        r(126, m::CONTROL, "Mission Control (⌃↑)"),
        r(125, m::CONTROL, "App Exposé (⌃↓)"),
    ]
}

/// Problems with a candidate against the others. `reserved` is what the rest of Kriya uses (and whatever else the shell
/// knows about); the system's own list is always included.
pub fn shortcut_conflicts(
    candidate: &KeyShortcut,
    existing: &[KeyShortcut],
    reserved: &[ReservedKey],
) -> Vec<ShortcutConflict> {
    let mut found = Vec::new();
    for key in system_reserved() {
        if key.key_code == candidate.key_code && key.modifiers == candidate.modifiers {
            found.push(ShortcutConflict {
                kind: ShortcutConflictKind::System,
                with: key.owner,
                blocking: true,
            });
        }
    }
    for key in reserved {
        if key.key_code == candidate.key_code && key.modifiers == candidate.modifiers {
            found.push(ShortcutConflict {
                kind: ShortcutConflictKind::OtherFeature,
                with: key.owner.clone(),
                blocking: true,
            });
        }
    }
    for other in existing {
        if other.id != candidate.id
            && other.enabled
            && other.key_code == candidate.key_code
            && other.modifiers == candidate.modifiers
            && scopes_overlap(&candidate.scope, &other.scope)
        {
            found.push(ShortcutConflict {
                kind: ShortcutConflictKind::Duplicate,
                with: other.name.clone(),
                blocking: true,
            });
        }
    }
    // ⌘ plus a letter or digit is how most apps name their own commands.
    let only_command =
        candidate.modifiers == m::COMMAND || candidate.modifiers == m::COMMAND | m::SHIFT;
    if only_command
        && found.is_empty()
        && matches!(
            candidate.scope,
            ShortcutScope::Global | ShortcutScope::ExceptApps { .. }
        )
    {
        found.push(ShortcutConflict { kind: ShortcutConflictKind::CommonlyUsed, with: "Most apps use ⌘ with a letter for their own commands; this one will override them everywhere".into(), blocking: false });
    }
    found
}

/// Checks a whole list: valid shortcuts, no more than the limit, no blocking clashes among themselves.
pub fn check_list(list: &[KeyShortcut], reserved: &[ReservedKey]) -> Result<(), CoreError> {
    if list.len() > MAX_SHORTCUTS {
        return Err(CoreError::invalid("there are too many shortcuts"));
    }
    let mut ids = HashSet::new();
    for s in list {
        s.check()?;
        if !ids.insert(s.id.as_str()) {
            return Err(CoreError::invalid("two shortcuts share an id"));
        }
    }
    for (i, s) in list.iter().enumerate() {
        if let Some(c) = shortcut_conflicts(s, &list[..i], reserved)
            .into_iter()
            .find(|c| c.blocking)
        {
            return Err(CoreError::invalid(format!(
                "“{}” clashes with {}",
                s.name, c.with
            )));
        }
    }
    Ok(())
}

// ---- sharing -------------------------------------------------------------------------------------------------------

const SHORTCUT_PACKAGE_FORMAT: &str = "kriya-shortcuts";
const MAX_PACKAGE_BYTES: usize = 1_000_000;

#[derive(Serialize, Deserialize)]
struct ShortcutPackage {
    format: String,
    version: u32,
    shortcuts: Vec<KeyShortcut>,
}

/// A list of shortcuts as text to save to a file and share.
pub fn export_shortcut_package(list: &[KeyShortcut]) -> Result<String, CoreError> {
    Ok(serde_json::to_string_pretty(&ShortcutPackage {
        format: SHORTCUT_PACKAGE_FORMAT.to_string(),
        version: 1,
        shortcuts: list.to_vec(),
    })?)
}

/// What importing a shortcut file would do.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ShortcutImportPlan {
    /// Shortcuts to add: new ids, switched off.
    pub add: Vec<KeyShortcut>,
    /// "name: why" for each one left out.
    pub skipped: Vec<String>,
}

/// Reads a shortcut file and decides what can be added. Nothing arrives switched on, and anything that would clash with
/// macOS, another part of Kriya or a shortcut already on is left out with the reason.
pub fn plan_shortcut_import(
    json: &str,
    existing: &[KeyShortcut],
    reserved: &[ReservedKey],
    known_targets: &dyn Fn(&ShortcutTarget) -> bool,
    now: i64,
) -> Result<ShortcutImportPlan, CoreError> {
    if json.len() > MAX_PACKAGE_BYTES {
        return Err(CoreError::invalid("that file is too large"));
    }
    let package: ShortcutPackage = serde_json::from_str(json)
        .map_err(|_| CoreError::invalid("that is not a Kriya shortcut file"))?;
    if package.format != SHORTCUT_PACKAGE_FORMAT {
        return Err(CoreError::invalid("that is not a Kriya shortcut file"));
    }
    if package.version != 1 {
        return Err(CoreError::invalid("that file is from a newer Kriya"));
    }
    let mut taken: HashSet<String> = existing.iter().map(|s| s.id.clone()).collect();
    let mut add: Vec<KeyShortcut> = Vec::new();
    let mut skipped = Vec::new();
    for (index, original) in package.shortcuts.into_iter().enumerate() {
        let label = if original.name.trim().is_empty() {
            format!("shortcut {}", index + 1)
        } else {
            original.name.clone()
        };
        if existing.len() + add.len() >= MAX_SHORTCUTS {
            skipped.push(format!("{label}: there are too many shortcuts"));
            continue;
        }
        let mut id = format!("imported-{now}-{index}");
        while taken.contains(&id) {
            id.push('x');
        }
        let mut shortcut = original;
        shortcut.id = id.clone();
        shortcut.enabled = false;
        if let Err(e) = shortcut.check() {
            skipped.push(format!("{label}: {e}"));
            continue;
        }
        if !known_targets(&shortcut.target) {
            skipped.push(format!("{label}: what it runs is not on this Mac"));
            continue;
        }
        // Compared as if it were on, so a clash that would appear on switching it on is reported now.
        let mut probe = shortcut.clone();
        probe.enabled = true;
        let mut against: Vec<KeyShortcut> = existing.to_vec();
        against.extend(add.iter().cloned());
        if let Some(c) = shortcut_conflicts(&probe, &against, reserved)
            .into_iter()
            .find(|c| c.blocking)
        {
            skipped.push(format!("{label}: clashes with {}", c.with));
            continue;
        }
        taken.insert(id);
        add.push(shortcut);
    }
    Ok(ShortcutImportPlan { add, skipped })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sc(id: &str, key: u16, mods: u64, scope: ShortcutScope) -> KeyShortcut {
        KeyShortcut {
            id: id.into(),
            name: format!("Shortcut {id}"),
            key_code: key,
            modifiers: mods,
            scope,
            target: ShortcutTarget::Command {
                command: "window.maximize".into(),
            },
            enabled: true,
        }
    }

    fn only(apps: &[&str]) -> ShortcutScope {
        ShortcutScope::OnlyApps {
            app_ids: apps.iter().map(|s| s.to_string()).collect(),
        }
    }

    fn except(apps: &[&str]) -> ShortcutScope {
        ShortcutScope::ExceptApps {
            app_ids: apps.iter().map(|s| s.to_string()).collect(),
        }
    }

    #[test]
    fn scopes_say_where_a_shortcut_is_active() {
        assert!(applies_in(&ShortcutScope::Global, None));
        assert!(
            applies_in(&only(&["a"]), Some("a"))
                && !applies_in(&only(&["a"]), Some("b"))
                && !applies_in(&only(&["a"]), None)
        );
        assert!(
            !applies_in(&except(&["a"]), Some("a"))
                && applies_in(&except(&["a"]), Some("b"))
                && applies_in(&except(&["a"]), None)
        );
    }

    #[test]
    fn scopes_overlap_only_when_some_app_has_both() {
        assert!(scopes_overlap(&ShortcutScope::Global, &only(&["a"])));
        assert!(scopes_overlap(&only(&["a", "b"]), &only(&["b", "c"])));
        assert!(!scopes_overlap(&only(&["a"]), &only(&["b"])));
        assert!(
            !scopes_overlap(&only(&["a"]), &except(&["a"])),
            "one is only A, the other everything but A"
        );
        assert!(scopes_overlap(&only(&["a"]), &except(&["b"])));
        assert!(scopes_overlap(&except(&["a"]), &except(&["b"])));
        assert!(scopes_overlap(
            &ShortcutScope::Global,
            &ShortcutScope::Global
        ));
    }

    #[test]
    fn the_same_keys_in_different_apps_are_fine() {
        let a = sc("a", 40, m::OPTION, only(&["com.x"]));
        let b = sc("b", 40, m::OPTION, only(&["com.y"]));
        assert!(shortcut_conflicts(&b, std::slice::from_ref(&a), &[]).is_empty());
        let global = sc("g", 40, m::OPTION, ShortcutScope::Global);
        let c = shortcut_conflicts(&global, &[a], &[]);
        assert_eq!(c.len(), 1);
        assert_eq!(
            (c[0].kind, c[0].blocking),
            (ShortcutConflictKind::Duplicate, true)
        );
    }

    #[test]
    fn system_and_other_feature_keys_block() {
        let quit = sc("q", 12, m::COMMAND, ShortcutScope::Global);
        assert!(shortcut_conflicts(&quit, &[], &[])
            .iter()
            .any(|c| c.kind == ShortcutConflictKind::System && c.blocking));
        let mine = sc("w", 123, m::CONTROL | m::OPTION, ShortcutScope::Global);
        let reserved = vec![ReservedKey {
            key_code: 123,
            modifiers: m::CONTROL | m::OPTION,
            owner: "Window management: left half".into(),
        }];
        let c = shortcut_conflicts(&mine, &[], &reserved);
        assert_eq!(c[0].kind, ShortcutConflictKind::OtherFeature);
        assert!(c[0].with.contains("Window management"));
    }

    #[test]
    fn disabled_shortcuts_do_not_clash_and_command_letters_warn() {
        let mut off = sc("o", 40, m::OPTION, ShortcutScope::Global);
        off.enabled = false;
        assert!(
            shortcut_conflicts(&sc("n", 40, m::OPTION, ShortcutScope::Global), &[off], &[])
                .is_empty()
        );
        let warn = shortcut_conflicts(&sc("k", 40, m::COMMAND, ShortcutScope::Global), &[], &[]);
        assert_eq!(warn.len(), 1);
        assert!(!warn[0].blocking, "a warning does not stop the shortcut");
        assert!(
            shortcut_conflicts(&sc("k", 40, m::COMMAND, only(&["com.x"])), &[], &[]).is_empty(),
            "limited to one app: no warning"
        );
    }

    #[test]
    fn keys_need_a_modifier_unless_they_are_function_keys() {
        assert!(sc("a", 0, 0, ShortcutScope::Global).check().is_err());
        assert!(
            sc("a", 0, m::SHIFT, ShortcutScope::Global).check().is_err(),
            "shift alone is just typing a capital"
        );
        assert!(sc("a", 0, m::OPTION, ShortcutScope::Global).check().is_ok());
        assert!(
            sc("f", 122, 0, ShortcutScope::Global).check().is_ok(),
            "F1 on its own is fine"
        );
        assert!(sc("a", 200, m::OPTION, ShortcutScope::Global)
            .check()
            .is_err());
        assert!(sc("a", 0, 1 << 40, ShortcutScope::Global).check().is_err());
    }

    #[test]
    fn shortcuts_are_validated() {
        assert!(
            sc("a", 0, m::OPTION, only(&[])).check().is_err(),
            "an app scope needs an app"
        );
        let mut empty = sc("a", 0, m::OPTION, ShortcutScope::Global);
        empty.target = ShortcutTarget::Command {
            command: " ".into(),
        };
        assert!(empty.check().is_err());
        let mut unnamed = sc("a", 0, m::OPTION, ShortcutScope::Global);
        unnamed.name = String::new();
        assert!(unnamed.check().is_err());
    }

    #[test]
    fn the_right_shortcut_is_found_for_an_app() {
        let list = vec![
            sc("only-mail", 40, m::OPTION, only(&["com.mail"])),
            sc("everywhere", 40, m::OPTION, ShortcutScope::Global),
        ];
        assert_eq!(
            find_shortcut(&list, 40, m::OPTION, Some("com.mail"))
                .unwrap()
                .id,
            "only-mail",
            "the app's own comes first"
        );
        assert_eq!(
            find_shortcut(&list, 40, m::OPTION, Some("com.other"))
                .unwrap()
                .id,
            "everywhere"
        );
        assert!(find_shortcut(&list, 41, m::OPTION, None).is_none());
        assert!(
            find_shortcut(&list, 40, m::OPTION | m::SHIFT, None).is_none(),
            "modifiers must match exactly"
        );
        let mut off = list.clone();
        off[1].enabled = false;
        assert!(find_shortcut(&off, 40, m::OPTION, Some("com.other")).is_none());
    }

    #[test]
    fn a_list_with_a_blocking_clash_is_refused() {
        let a = sc("a", 40, m::OPTION, ShortcutScope::Global);
        let b = sc("b", 40, m::OPTION, ShortcutScope::Global);
        assert!(check_list(std::slice::from_ref(&a), &[]).is_ok());
        assert!(check_list(&[a.clone(), b], &[]).is_err());
        assert!(check_list(&[a.clone(), a.clone()], &[]).is_err(), "same id");
        let reserved = vec![ReservedKey {
            key_code: 40,
            modifiers: m::OPTION,
            owner: "Clipboard".into(),
        }];
        assert!(check_list(&[a], &reserved)
            .unwrap_err()
            .to_string()
            .contains("Clipboard"));
    }

    #[test]
    fn config_is_cleaned() {
        let c = KeyboardConfig {
            palette_modifiers: 0,
            expansion_excluded_app_ids: vec![" a ".into(), "a".into(), String::new()],
            ..KeyboardConfig::default()
        }
        .sanitized();
        assert_eq!(c.palette_key, None);
        assert_eq!(c.expansion_excluded_app_ids, vec!["a".to_string()]);
        assert!(KeyboardConfig::default().is_excluded(Some("com.bitwarden.desktop")));
    }

    #[test]
    fn shortcuts_round_trip_through_json() {
        let s = KeyShortcut {
            target: ShortcutTarget::Snippet {
                snippet_id: "x".into(),
            },
            ..sc("a", 5, m::OPTION, except(&["com.x"]))
        };
        let json = serde_json::to_string(&s).unwrap();
        assert_eq!(serde_json::from_str::<KeyShortcut>(&json).unwrap(), s);
    }

    fn known(_: &ShortcutTarget) -> bool {
        true
    }

    #[test]
    fn a_shortcut_file_round_trips_and_arrives_switched_off_with_new_ids() {
        let mut a = sc("a", 40, m::COMMAND | m::OPTION, ShortcutScope::Global);
        a.enabled = true;
        let json = export_shortcut_package(&[a.clone()]).unwrap();
        let plan = plan_shortcut_import(&json, &[], &[], &known, 100).unwrap();
        assert_eq!(plan.skipped, Vec::<String>::new());
        assert_eq!(plan.add.len(), 1);
        assert!(!plan.add[0].enabled);
        assert_eq!(plan.add[0].id, "imported-100-0");
        assert_eq!(plan.add[0].key_code, 40);
        assert_ne!(plan.add[0].id, a.id);
    }

    #[test]
    fn clashes_missing_targets_and_bad_shortcuts_are_left_out_with_a_reason() {
        let mut mine = sc("mine", 40, m::COMMAND | m::OPTION, ShortcutScope::Global);
        mine.enabled = true;
        let clash = KeyShortcut {
            name: "Same keys".into(),
            ..sc("x1", 40, m::COMMAND | m::OPTION, ShortcutScope::Global)
        };
        let system = KeyShortcut {
            name: "Quit".into(),
            ..sc("x2", 12, m::COMMAND, ShortcutScope::Global)
        };
        let bare = KeyShortcut {
            name: "Bare".into(),
            ..sc("x3", 0, 0, ShortcutScope::Global)
        };
        let fine = KeyShortcut {
            name: "Fine".into(),
            ..sc("x4", 41, m::CONTROL | m::OPTION, ShortcutScope::Global)
        };
        let json = export_shortcut_package(&[clash, system, bare, fine]).unwrap();
        let plan = plan_shortcut_import(&json, &[mine], &[], &known, 5).unwrap();
        assert_eq!(
            plan.add.iter().map(|s| s.name.as_str()).collect::<Vec<_>>(),
            vec!["Fine"]
        );
        assert_eq!(plan.skipped.len(), 3);
        assert!(plan.skipped[0].starts_with("Same keys: clashes with"));
        assert!(plan.skipped[2].starts_with("Bare:"));

        let nothing = |_: &ShortcutTarget| false;
        let again = plan_shortcut_import(
            &export_shortcut_package(&[sc("y", 41, m::CONTROL | m::OPTION, ShortcutScope::Global)])
                .unwrap(),
            &[],
            &[],
            &nothing,
            5,
        )
        .unwrap();
        assert!(again.add.is_empty());
        assert!(again.skipped[0].contains("not on this Mac"));
    }

    #[test]
    fn other_files_and_newer_versions_are_refused_and_two_in_one_file_do_not_collide() {
        assert!(plan_shortcut_import("{}", &[], &[], &known, 1).is_err());
        assert!(plan_shortcut_import("[1,2]", &[], &[], &known, 1).is_err());
        assert!(plan_shortcut_import(
            r#"{"format":"other","version":1,"shortcuts":[]}"#,
            &[],
            &[],
            &known,
            1
        )
        .is_err());
        assert!(plan_shortcut_import(
            r#"{"format":"kriya-shortcuts","version":2,"shortcuts":[]}"#,
            &[],
            &[],
            &known,
            1
        )
        .is_err());
        let a = sc("a", 40, m::COMMAND | m::OPTION, ShortcutScope::Global);
        let b = KeyShortcut {
            name: "Second".into(),
            ..sc("b", 40, m::COMMAND | m::OPTION, ShortcutScope::Global)
        };
        let plan = plan_shortcut_import(
            &export_shortcut_package(&[a, b]).unwrap(),
            &[],
            &[],
            &known,
            1,
        )
        .unwrap();
        assert_eq!(
            plan.add.len(),
            2,
            "both arrive switched off, so they do not block each other"
        );
        assert_ne!(plan.add[0].id, plan.add[1].id);
        let huge = "x".repeat(2_000_000);
        assert!(plan_shortcut_import(&huge, &[], &[], &known, 1).is_err());
    }
}
