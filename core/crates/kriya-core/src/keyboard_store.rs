//! Storage for text-expansion snippets, keyboard shortcuts and their settings.

use std::collections::HashSet;

use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};

use crate::backup::BackupFile;
use crate::error::CoreError;
use crate::expansion::{
    abbreviation_conflicts, categories, export_package, import_package, search_snippets,
    ExpansionSnippet, SnippetConflict, SnippetConflictKind, TextSnippetImportSummary, MAX_SNIPPETS,
};
use crate::keyboard::{
    check_list, shortcut_conflicts, KeyShortcut, KeyboardConfig, ReservedKey, ShortcutConflict,
    ShortcutTarget,
};
use crate::store::Store;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct KeyboardBackup {
    pub config: KeyboardConfig,
    pub shortcuts: Vec<KeyShortcut>,
    pub snippets: Vec<ExpansionSnippet>,
}

impl Store {
    // ---- snippets ---------------------------------------------------------------------------------------------

    pub fn text_snippets(&self) -> Result<Vec<ExpansionSnippet>, CoreError> {
        read_snippets(&self.conn())
    }

    /// Saves a snippet. An abbreviation another snippet already uses (in an overlapping set of apps) is refused; one that
    /// would be cut short by a shorter abbreviation is saved and returned as a warning.
    pub fn save_text_snippet(
        &self,
        snippet: &ExpansionSnippet,
        now: i64,
    ) -> Result<Vec<SnippetConflict>, CoreError> {
        let mut s = snippet.clone().tidied();
        s.check()?;
        let conn = self.conn();
        let all = read_snippets(&conn)?;
        let existing = all.iter().find(|x| x.id == s.id);
        if existing.is_none() && all.len() >= MAX_SNIPPETS {
            return Err(CoreError::invalid("there are too many snippets"));
        }
        let conflicts = abbreviation_conflicts(&s, &all);
        if let Some(c) = conflicts
            .iter()
            .find(|c| c.kind == SnippetConflictKind::Duplicate)
        {
            return Err(CoreError::invalid(format!(
                "“{}” already uses the abbreviation {}",
                c.title, c.abbreviation
            )));
        }
        s.created_at = existing.map_or(now, |e| e.created_at);
        s.updated_at = now;
        write_snippet(&conn, &s)?;
        Ok(conflicts)
    }

    pub fn delete_text_snippet(&self, id: &str) -> Result<(), CoreError> {
        let conn = self.conn();
        let tx = conn.unchecked_transaction()?;
        tx.execute("DELETE FROM text_snippets WHERE id = ?1", params![id])?;
        // A shortcut that inserted this snippet has nothing left to do.
        let mut shortcuts = read_shortcuts(&tx)?;
        shortcuts.retain(
            |s| !matches!(&s.target, ShortcutTarget::Snippet { snippet_id } if snippet_id == id),
        );
        write_json(&tx, "key_shortcuts", &shortcuts)?;
        tx.commit()?;
        Ok(())
    }

    pub fn mark_text_snippet_used(&self, id: &str) -> Result<(), CoreError> {
        let conn = self.conn();
        let mut all = read_snippets(&conn)?;
        if let Some(s) = all.iter_mut().find(|s| s.id == id) {
            s.use_count = s.use_count.saturating_add(1);
            write_snippet(&conn, s)?;
        }
        Ok(())
    }

    pub fn search_text_snippets(
        &self,
        query: &str,
        category: Option<&str>,
        favorites_only: bool,
        limit: usize,
    ) -> Result<Vec<ExpansionSnippet>, CoreError> {
        let mut found = search_snippets(
            &read_snippets(&self.conn())?,
            query,
            category,
            favorites_only,
        );
        found.truncate(limit.clamp(1, 5000));
        Ok(found)
    }

    pub fn text_snippet_categories(&self) -> Result<Vec<String>, CoreError> {
        Ok(categories(&read_snippets(&self.conn())?))
    }

    pub fn export_text_snippets(&self, ids: &[String]) -> Result<String, CoreError> {
        let chosen: Vec<ExpansionSnippet> = read_snippets(&self.conn())?
            .into_iter()
            .filter(|s| ids.contains(&s.id))
            .collect();
        export_package(&chosen)
    }

    pub fn import_text_snippets(
        &self,
        json: &str,
        now: i64,
    ) -> Result<TextSnippetImportSummary, CoreError> {
        let conn = self.conn();
        let existing = read_snippets(&conn)?;
        let (added, summary) = import_package(json, &existing, now)?;
        if existing.len() + added.len() > MAX_SNIPPETS {
            return Err(CoreError::invalid("that would be too many snippets"));
        }
        let tx = conn.unchecked_transaction()?;
        for s in &added {
            write_snippet(&tx, s)?;
        }
        tx.commit()?;
        Ok(summary)
    }

    // ---- shortcuts and settings -------------------------------------------------------------------------------

    pub fn keyboard_config(&self) -> Result<KeyboardConfig, CoreError> {
        read_config(&self.conn())
    }

    pub fn save_keyboard_config(&self, config: &KeyboardConfig) -> Result<(), CoreError> {
        write_json(&self.conn(), "keyboard_config", &config.clone().sanitized())
    }

    pub fn key_shortcuts(&self) -> Result<Vec<KeyShortcut>, CoreError> {
        read_shortcuts(&self.conn())
    }

    /// Saves the whole list. Nothing is saved if any shortcut is invalid or clashes with another or with `reserved`.
    pub fn save_key_shortcuts(
        &self,
        list: &[KeyShortcut],
        reserved: &[ReservedKey],
    ) -> Result<(), CoreError> {
        check_list(list, reserved)?;
        write_json(&self.conn(), "key_shortcuts", &list)
    }

    /// What a shortcut would clash with, without saving anything.
    pub fn check_key_shortcut(
        &self,
        candidate: &KeyShortcut,
        reserved: &[ReservedKey],
    ) -> Result<Vec<ShortcutConflict>, CoreError> {
        Ok(shortcut_conflicts(
            candidate,
            &read_shortcuts(&self.conn())?,
            reserved,
        ))
    }

    /// The chosen shortcuts as a file to share.
    pub fn export_key_shortcuts(&self, ids: &[String]) -> Result<String, CoreError> {
        let chosen: Vec<KeyShortcut> = read_shortcuts(&self.conn())?
            .into_iter()
            .filter(|s| ids.is_empty() || ids.contains(&s.id))
            .collect();
        crate::keyboard::export_shortcut_package(&chosen)
    }

    /// Adds the shortcuts a file holds that can be added, switched off. Returns what was added and what was left out.
    pub fn import_key_shortcuts(
        &self,
        json: &str,
        reserved: &[ReservedKey],
        now: i64,
    ) -> Result<crate::keyboard::ShortcutImportPlan, CoreError> {
        let conn = self.conn();
        let existing = read_shortcuts(&conn)?;
        let actions: HashSet<String> = crate::store::read_actions(&conn)?
            .into_iter()
            .map(|a| a.id)
            .collect();
        let snippets: HashSet<String> = read_snippets(&conn)?.into_iter().map(|s| s.id).collect();
        let known = |target: &ShortcutTarget| match target {
            ShortcutTarget::Action { action_id } => actions.contains(action_id),
            ShortcutTarget::Snippet { snippet_id } => snippets.contains(snippet_id),
            ShortcutTarget::Command { .. } => true,
        };
        let plan = crate::keyboard::plan_shortcut_import(json, &existing, reserved, &known, now)?;
        let mut all = existing;
        all.extend(plan.add.iter().cloned());
        check_list(&all, reserved)?;
        write_json(&conn, "key_shortcuts", &all)?;
        Ok(plan)
    }

    pub fn restore_default_keyboard_settings(&self, everything: bool) -> Result<(), CoreError> {
        let conn = self.conn();
        let tx = conn.unchecked_transaction()?;
        write_json(&tx, "keyboard_config", &KeyboardConfig::default())?;
        if everything {
            write_json::<Vec<KeyShortcut>>(&tx, "key_shortcuts", &Vec::new())?;
            tx.execute("DELETE FROM text_snippets", [])?;
        }
        tx.commit()?;
        Ok(())
    }
}

/// How many shortcuts run a saved action, so it is not deleted from under them.
pub(crate) fn uses_of_action(conn: &Connection, action_id: &str) -> Result<usize, CoreError> {
    Ok(read_shortcuts(conn)?
        .iter()
        .filter(|s| matches!(&s.target, ShortcutTarget::Action { action_id: a } if a == action_id))
        .count())
}

/// Removes the shortcuts that started a workflow that no longer exists.
pub(crate) fn remove_workflow_refs(conn: &Connection, workflow_id: &str) -> Result<(), CoreError> {
    let command = format!("workflow.{}", workflow_id.to_lowercase());
    let mut list = read_shortcuts(conn)?;
    let before = list.len();
    list.retain(|s| !matches!(&s.target, ShortcutTarget::Command { command: c } if *c == command));
    if list.len() != before {
        write_json(conn, "key_shortcuts", &list)?;
    }
    Ok(())
}

pub(crate) fn backup_part(conn: &Connection) -> Result<KeyboardBackup, CoreError> {
    Ok(KeyboardBackup {
        config: read_config(conn)?,
        shortcuts: read_shortcuts(conn)?,
        snippets: read_snippets(conn)?,
    })
}

pub(crate) fn validate_backup(
    file: &BackupFile,
    action_ids: &HashSet<&str>,
) -> Result<(), CoreError> {
    let Some(k) = &file.keyboard else {
        return Ok(());
    };
    let bad = |message: String| CoreError::Backup { message };
    if k.snippets.len() > MAX_SNIPPETS {
        return Err(bad("the backup holds too many snippets".into()));
    }
    let mut ids = HashSet::new();
    for s in &k.snippets {
        s.check().map_err(|e| bad(e.to_string()))?;
        if !ids.insert(s.id.as_str()) {
            return Err(bad("two snippets share an id".into()));
        }
    }
    check_list(&k.shortcuts, &[]).map_err(|e| bad(e.to_string()))?;
    for s in &k.shortcuts {
        match &s.target {
            ShortcutTarget::Action { action_id } if !action_ids.contains(action_id.as_str()) => {
                return Err(bad(
                    "a shortcut runs an action that is not in the backup".into()
                ));
            }
            ShortcutTarget::Snippet { snippet_id } if !ids.contains(snippet_id.as_str()) => {
                return Err(bad(
                    "a shortcut inserts a snippet that is not in the backup".into(),
                ));
            }
            _ => {}
        }
    }
    Ok(())
}

pub(crate) fn restore_backup(tx: &Connection, file: &BackupFile) -> Result<(), CoreError> {
    let Some(k) = &file.keyboard else {
        return Ok(());
    };
    write_json(tx, "keyboard_config", &k.config.clone().sanitized())?;
    write_json(tx, "key_shortcuts", &k.shortcuts)?;
    tx.execute("DELETE FROM text_snippets", [])?;
    for s in &k.snippets {
        write_snippet(tx, s)?;
    }
    Ok(())
}

fn read_snippets(conn: &Connection) -> Result<Vec<ExpansionSnippet>, CoreError> {
    let mut stmt =
        conn.prepare("SELECT snippet_json FROM text_snippets ORDER BY sort_order, id")?;
    let rows = stmt.query_map([], |r| r.get::<_, String>(0))?;
    let mut out = Vec::new();
    for row in rows {
        if let Ok(s) = serde_json::from_str::<ExpansionSnippet>(&row?) {
            out.push(s);
        }
    }
    Ok(out)
}

fn write_snippet(conn: &Connection, s: &ExpansionSnippet) -> Result<(), CoreError> {
    conn.execute(
        "INSERT INTO text_snippets (id, sort_order, snippet_json) VALUES (?1, COALESCE((SELECT MAX(sort_order) + 1 FROM text_snippets), 0), ?2)
         ON CONFLICT(id) DO UPDATE SET snippet_json = excluded.snippet_json",
        params![s.id, serde_json::to_string(s)?],
    )?;
    Ok(())
}

fn read_json<T: serde::de::DeserializeOwned>(
    conn: &Connection,
    key: &str,
) -> Result<Option<T>, CoreError> {
    let json: Option<String> = conn
        .query_row(
            "SELECT value FROM settings WHERE key = ?1",
            params![key],
            |r| r.get(0),
        )
        .optional()?;
    Ok(json.and_then(|j| serde_json::from_str(&j).ok()))
}

fn write_json<T: Serialize>(conn: &Connection, key: &str, value: &T) -> Result<(), CoreError> {
    conn.execute(
        "INSERT INTO settings (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![key, serde_json::to_string(value)?],
    )?;
    Ok(())
}

fn read_config(conn: &Connection) -> Result<KeyboardConfig, CoreError> {
    Ok(read_json::<KeyboardConfig>(conn, "keyboard_config")?
        .unwrap_or_default()
        .sanitized())
}

fn read_shortcuts(conn: &Connection) -> Result<Vec<KeyShortcut>, CoreError> {
    Ok(read_json::<Vec<KeyShortcut>>(conn, "key_shortcuts")?.unwrap_or_default())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::actions::modifiers as m;
    use crate::actions::{Action, NamedAction};
    use crate::expansion::ExpandOn;
    use crate::keyboard::ShortcutScope;

    fn open() -> Store {
        Store::open_in_memory().unwrap()
    }

    fn snippet(id: &str, abbr: Option<&str>) -> ExpansionSnippet {
        ExpansionSnippet {
            id: id.into(),
            title: format!("Snippet {id}"),
            abbreviation: abbr.map(str::to_string),
            body: format!("body of {id}"),
            category: None,
            favorite: false,
            enabled: true,
            app_ids: vec![],
            case_sensitive: false,
            expand_on: ExpandOn::Delimiter,
            use_count: 0,
            created_at: 0,
            updated_at: 0,
        }
    }

    fn shortcut(id: &str, key: u16, target: ShortcutTarget) -> KeyShortcut {
        KeyShortcut {
            id: id.into(),
            name: format!("Shortcut {id}"),
            key_code: key,
            modifiers: m::OPTION,
            scope: ShortcutScope::Global,
            target,
            enabled: true,
        }
    }

    #[test]
    fn snippets_save_search_count_and_delete() {
        let s = open();
        s.save_text_snippet(&snippet("a", Some("brb")), 10).unwrap();
        s.save_text_snippet(&snippet("b", None), 11).unwrap();
        assert_eq!(s.text_snippets().unwrap().len(), 2);
        let found = s
            .search_text_snippets("body of a", None, false, 10)
            .unwrap();
        assert_eq!(found[0].id, "a");
        assert_eq!(found[0].created_at, 10);
        s.mark_text_snippet_used("a").unwrap();
        assert_eq!(s.text_snippets().unwrap()[0].use_count, 1);
        let mut edited = snippet("a", Some("brb"));
        edited.body = "changed".into();
        s.save_text_snippet(&edited, 99).unwrap();
        let again = &s.text_snippets().unwrap()[0];
        assert_eq!(
            (again.created_at, again.updated_at),
            (10, 99),
            "the creation time is kept"
        );
        s.delete_text_snippet("a").unwrap();
        assert_eq!(s.text_snippets().unwrap().len(), 1);
    }

    #[test]
    fn a_duplicate_abbreviation_is_refused_and_a_shadowed_one_warned() {
        let s = open();
        s.save_text_snippet(&snippet("a", Some("brb")), 1).unwrap();
        let err = s
            .save_text_snippet(&snippet("b", Some("BRB")), 2)
            .unwrap_err()
            .to_string();
        assert!(err.contains("already uses"), "{err}");
        assert_eq!(s.text_snippets().unwrap().len(), 1);
        let mut short = snippet("s", Some("ad"));
        short.expand_on = ExpandOn::Immediately;
        s.save_text_snippet(&short, 3).unwrap();
        let warnings = s.save_text_snippet(&snippet("l", Some("add")), 4).unwrap();
        assert_eq!(warnings[0].kind, SnippetConflictKind::Shadowed);
        assert_eq!(s.text_snippets().unwrap().len(), 3, "a warning still saves");
        assert!(s.save_text_snippet(&snippet("bad", Some("x")), 5).is_err());
    }

    #[test]
    fn snippet_packages_round_trip() {
        let source = open();
        source
            .save_text_snippet(&snippet("a", Some("brb")), 1)
            .unwrap();
        let json = source.export_text_snippets(&["a".into()]).unwrap();
        let target = open();
        let summary = target.import_text_snippets(&json, 5).unwrap();
        assert_eq!(summary.added, 1);
        assert_eq!(
            target.text_snippets().unwrap()[0].abbreviation.as_deref(),
            Some("brb")
        );
        assert_eq!(
            target
                .import_text_snippets(&json, 6)
                .unwrap()
                .skipped_duplicates,
            1
        );
        assert!(target.import_text_snippets("nope", 7).is_err());
    }

    #[test]
    fn shortcuts_are_saved_whole_and_checked_for_clashes() {
        let s = open();
        let a = shortcut(
            "a",
            40,
            ShortcutTarget::Command {
                command: "window.maximize".into(),
            },
        );
        let b = shortcut(
            "b",
            38,
            ShortcutTarget::Command {
                command: "window.center".into(),
            },
        );
        s.save_key_shortcuts(&[a.clone(), b.clone()], &[]).unwrap();
        assert_eq!(s.key_shortcuts().unwrap().len(), 2);
        let clash = KeyShortcut {
            key_code: 40,
            ..b.clone()
        };
        assert!(s.save_key_shortcuts(&[a.clone(), clash], &[]).is_err());
        assert_eq!(s.key_shortcuts().unwrap().len(), 2, "nothing changed");
        let conflicts = s
            .check_key_shortcut(
                &KeyShortcut {
                    id: "c".into(),
                    ..a.clone()
                },
                &[],
            )
            .unwrap();
        assert!(conflicts.iter().any(|c| c.blocking));
        let reserved = vec![ReservedKey {
            key_code: 5,
            modifiers: m::OPTION,
            owner: "Window management".into(),
        }];
        assert!(s
            .save_key_shortcuts(
                &[shortcut(
                    "r",
                    5,
                    ShortcutTarget::Command {
                        command: "x".into()
                    }
                )],
                &reserved
            )
            .is_err());
    }

    #[test]
    fn deleting_a_snippet_removes_the_shortcut_that_inserted_it_and_actions_are_protected() {
        let s = open();
        s.save_text_snippet(&snippet("a", None), 1).unwrap();
        s.save_action(&NamedAction {
            id: "act".into(),
            name: "Act".into(),
            action: Action::Noop,
        })
        .unwrap();
        s.save_key_shortcuts(
            &[
                shortcut(
                    "one",
                    1,
                    ShortcutTarget::Snippet {
                        snippet_id: "a".into(),
                    },
                ),
                shortcut(
                    "two",
                    2,
                    ShortcutTarget::Action {
                        action_id: "act".into(),
                    },
                ),
            ],
            &[],
        )
        .unwrap();
        assert!(s.delete_action("act").is_err(), "a shortcut still uses it");
        s.delete_text_snippet("a").unwrap();
        assert_eq!(
            s.key_shortcuts()
                .unwrap()
                .iter()
                .map(|x| x.id.as_str())
                .collect::<Vec<_>>(),
            ["two"]
        );
    }

    #[test]
    fn keyboard_data_survives_a_backup_and_older_backups_leave_it_alone() {
        let source = open();
        source
            .save_text_snippet(&snippet("a", Some("brb")), 1)
            .unwrap();
        source
            .save_key_shortcuts(
                &[shortcut(
                    "one",
                    1,
                    ShortcutTarget::Snippet {
                        snippet_id: "a".into(),
                    },
                )],
                &[],
            )
            .unwrap();
        source
            .save_keyboard_config(&KeyboardConfig {
                type_instead_of_paste: false,
                ..KeyboardConfig::default()
            })
            .unwrap();
        let json = source.export_backup("0.8.0", 1).unwrap();

        let target = open();
        target
            .save_text_snippet(&snippet("old", Some("old")), 1)
            .unwrap();
        target.import_backup(&json).unwrap();
        let ids: Vec<String> = target
            .text_snippets()
            .unwrap()
            .into_iter()
            .map(|s| s.id)
            .collect();
        assert_eq!(ids, vec!["a".to_string()]);
        assert_eq!(target.key_shortcuts().unwrap().len(), 1);
        assert!(!target.keyboard_config().unwrap().type_instead_of_paste);

        let keeper = open();
        keeper.save_text_snippet(&snippet("mine", None), 1).unwrap();
        let mut value: serde_json::Value = serde_json::from_str(&json).unwrap();
        value.as_object_mut().unwrap().remove("keyboard");
        keeper.import_backup(&value.to_string()).unwrap();
        assert_eq!(keeper.text_snippets().unwrap().len(), 1);
    }

    #[test]
    fn a_backup_whose_shortcut_points_nowhere_changes_nothing() {
        let store = open();
        store.save_text_snippet(&snippet("keep", None), 1).unwrap();
        let json = open().export_backup("0.8.0", 1).unwrap();
        let mut value: serde_json::Value = serde_json::from_str(&json).unwrap();
        value["keyboard"]["shortcuts"] = serde_json::json!([{
            "id": "x", "name": "X", "key_code": 1, "modifiers": 4, "scope": {"type": "global"},
            "target": {"type": "snippet", "snippet_id": "ghost"}, "enabled": true
        }]);
        assert!(store.import_backup(&value.to_string()).is_err());
        assert_eq!(store.text_snippets().unwrap().len(), 1);
    }

    #[test]
    fn restoring_defaults_keeps_or_clears_the_persons_data() {
        let s = open();
        s.save_text_snippet(&snippet("a", None), 1).unwrap();
        s.save_keyboard_config(&KeyboardConfig {
            type_instead_of_paste: false,
            ..KeyboardConfig::default()
        })
        .unwrap();
        s.restore_default_keyboard_settings(false).unwrap();
        assert!(s.keyboard_config().unwrap().type_instead_of_paste);
        assert_eq!(s.text_snippets().unwrap().len(), 1);
        s.restore_default_keyboard_settings(true).unwrap();
        assert!(s.text_snippets().unwrap().is_empty());
    }
}
