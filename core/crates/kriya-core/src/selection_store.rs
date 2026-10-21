//! Storage for the selection bar's actions and settings, and for the scripts the person has approved.

use std::collections::HashSet;

use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};

use crate::backup::BackupFile;
use crate::error::CoreError;
use crate::selection::{
    default_actions, export_package, import_package, ApprovedScript, SelectionAction,
    SelectionConfig, MAX_ACTIONS,
};
use crate::store::Store;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SelectionBackup {
    pub config: SelectionConfig,
    pub actions: Vec<SelectionAction>,
}

impl Store {
    pub fn selection_config(&self) -> Result<SelectionConfig, CoreError> {
        read_config(&self.conn())
    }

    pub fn save_selection_config(&self, config: &SelectionConfig) -> Result<(), CoreError> {
        write_json(
            &self.conn(),
            "selection_config",
            &config.clone().sanitized(),
        )
    }

    /// The actions in the order they show in the bar.
    pub fn selection_actions(&self) -> Result<Vec<SelectionAction>, CoreError> {
        read_actions(&self.conn())
    }

    /// Saves the whole list in order, which is also how it is reordered. Nothing is saved if any action is not valid.
    pub fn save_selection_actions(&self, list: &[SelectionAction]) -> Result<(), CoreError> {
        check_list(list)?;
        write_json(&self.conn(), "selection_actions", &list)
    }

    pub fn export_selection_actions(
        &self,
        ids: &[String],
        name: &str,
    ) -> Result<String, CoreError> {
        let all = read_actions(&self.conn())?;
        let chosen: Vec<SelectionAction> =
            all.into_iter().filter(|a| ids.contains(&a.id)).collect();
        export_package(name, &chosen)
    }

    /// Adds the actions in a package to the end of the list. Returns what was added.
    pub fn import_selection_actions(
        &self,
        json: &str,
        now: i64,
    ) -> Result<Vec<SelectionAction>, CoreError> {
        let conn = self.conn();
        let mut all = read_actions(&conn)?;
        let existing: Vec<String> = all.iter().map(|a| a.id.clone()).collect();
        let added = import_package(json, &existing, &format!("{now:x}"))?;
        all.extend(added.iter().cloned());
        check_list(&all)?;
        write_json(&conn, "selection_actions", &all)?;
        Ok(added)
    }

    pub fn restore_default_selection_settings(&self, everything: bool) -> Result<(), CoreError> {
        let conn = self.conn();
        let tx = conn.unchecked_transaction()?;
        write_json(&tx, "selection_config", &SelectionConfig::default())?;
        if everything {
            write_json(&tx, "selection_actions", &default_actions())?;
        }
        tx.commit()?;
        Ok(())
    }

    // ---- approved scripts -------------------------------------------------------------------------------------

    pub fn approved_scripts(&self) -> Result<Vec<ApprovedScript>, CoreError> {
        read_approved(&self.conn())
    }

    pub fn is_script_approved(&self, fingerprint: &str) -> Result<bool, CoreError> {
        Ok(read_approved(&self.conn())?
            .iter()
            .any(|a| a.fingerprint == fingerprint))
    }

    pub fn approve_script(
        &self,
        fingerprint: &str,
        label: &str,
        now: i64,
    ) -> Result<(), CoreError> {
        if fingerprint.len() != 64 || !fingerprint.chars().all(|c| c.is_ascii_hexdigit()) {
            return Err(CoreError::invalid("that is not a script fingerprint"));
        }
        let conn = self.conn();
        let mut all = read_approved(&conn)?;
        all.retain(|a| a.fingerprint != fingerprint);
        all.push(ApprovedScript {
            fingerprint: fingerprint.to_string(),
            label: label.chars().take(80).collect(),
            approved_at: now,
        });
        write_json(&conn, "approved_scripts", &all)
    }

    pub fn revoke_script(&self, fingerprint: &str) -> Result<(), CoreError> {
        let conn = self.conn();
        let mut all = read_approved(&conn)?;
        all.retain(|a| a.fingerprint != fingerprint);
        write_json(&conn, "approved_scripts", &all)
    }
}

/// Removes the selection actions that ran a workflow that no longer exists.
pub(crate) fn remove_workflow_refs(conn: &Connection, workflow_id: &str) -> Result<(), CoreError> {
    let mut list = read_actions(conn)?;
    let before = list.len();
    list.retain(|a| !matches!(&a.kind, crate::selection::SelectionActionKind::Workflow { workflow_id: id } if id == workflow_id));
    if list.len() != before {
        write_json(conn, "selection_actions", &list)?;
    }
    Ok(())
}

pub(crate) fn backup_part(conn: &Connection) -> Result<SelectionBackup, CoreError> {
    Ok(SelectionBackup {
        config: read_config(conn)?,
        actions: read_actions(conn)?,
    })
}

pub(crate) fn validate_backup(file: &BackupFile) -> Result<(), CoreError> {
    let Some(s) = &file.selection else {
        return Ok(());
    };
    check_list(&s.actions).map_err(|e| CoreError::Backup {
        message: e.to_string(),
    })
}

/// Settings and actions come back with a backup, but script approvals never do: a restored script asks again.
pub(crate) fn restore_backup(tx: &Connection, file: &BackupFile) -> Result<(), CoreError> {
    let Some(s) = &file.selection else {
        return Ok(());
    };
    write_json(tx, "selection_config", &s.config.clone().sanitized())?;
    write_json(tx, "selection_actions", &s.actions)
}

fn check_list(list: &[SelectionAction]) -> Result<(), CoreError> {
    if list.len() > MAX_ACTIONS {
        return Err(CoreError::invalid("there are too many actions"));
    }
    let mut ids = HashSet::new();
    for a in list {
        a.check()?;
        if !ids.insert(a.id.as_str()) {
            return Err(CoreError::invalid("two actions share an id"));
        }
    }
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

fn read_config(conn: &Connection) -> Result<SelectionConfig, CoreError> {
    Ok(read_json::<SelectionConfig>(conn, "selection_config")?
        .unwrap_or_default()
        .sanitized())
}

fn read_actions(conn: &Connection) -> Result<Vec<SelectionAction>, CoreError> {
    let Some(mut list) = read_json::<Vec<SelectionAction>>(conn, "selection_actions")? else {
        return Ok(default_actions());
    };
    // Actions added after the first release are offered once to a person who already has a saved list. One they
    // remove afterwards does not come back.
    if read_json::<bool>(conn, "selection_defaults_v2")?.is_none() {
        for extra in default_actions()
            .into_iter()
            .filter(|a| a.id == "copy-plain" || a.id == "copy-markdown")
        {
            if !list.iter().any(|a| a.id == extra.id) {
                list.push(extra);
            }
        }
        write_json(conn, "selection_actions", &list)?;
        write_json(conn, "selection_defaults_v2", &true)?;
    }
    Ok(list)
}

fn read_approved(conn: &Connection) -> Result<Vec<ApprovedScript>, CoreError> {
    Ok(read_json::<Vec<ApprovedScript>>(conn, "approved_scripts")?.unwrap_or_default())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::finder::FinderScript;
    use crate::selection::{script_fingerprint, SelectionActionKind, SelectionTarget};

    fn open() -> Store {
        Store::open_in_memory().unwrap()
    }

    fn script(id: &str) -> SelectionAction {
        SelectionAction {
            id: id.into(),
            title: "Mine".into(),
            symbol: "star".into(),
            kind: SelectionActionKind::Script {
                language: FinderScript::Shell,
                source: "echo $1".into(),
                replace_with_output: false,
            },
            enabled: true,
            applies: SelectionTarget::Anything,
            app_ids: vec![],
            group: None,
        }
    }

    #[test]
    fn fresh_store_has_the_shipped_actions_and_settings() {
        let s = open();
        assert_eq!(s.selection_actions().unwrap(), default_actions());
        assert_eq!(s.selection_config().unwrap(), SelectionConfig::default());
    }

    #[test]
    fn reordering_persists_and_bad_lists_change_nothing() {
        let s = open();
        let mut list = s.selection_actions().unwrap();
        list.reverse();
        let first = list[0].id.clone();
        s.save_selection_actions(&list).unwrap();
        assert_eq!(s.selection_actions().unwrap()[0].id, first);
        let mut dup = list.clone();
        dup.push(dup[0].clone());
        assert!(s.save_selection_actions(&dup).is_err());
        let mut bad = list.clone();
        bad[0].title = String::new();
        assert!(s.save_selection_actions(&bad).is_err());
        assert_eq!(s.selection_actions().unwrap()[0].id, first);
    }

    #[test]
    fn packages_move_actions_between_stores_without_clashes() {
        let source = open();
        let mut list = source.selection_actions().unwrap();
        list.push(script("mine"));
        source.save_selection_actions(&list).unwrap();
        let json = source
            .export_selection_actions(&["mine".into(), "copy".into()], "Shared")
            .unwrap();

        let target = open();
        let added = target.import_selection_actions(&json, 255).unwrap();
        assert_eq!(added.len(), 2);
        let all = target.selection_actions().unwrap();
        assert!(all.iter().any(|a| a.id == "mine"));
        assert!(
            all.iter().any(|a| a.id == "copy-ff-0"),
            "the shipped Copy already exists, so the imported one is renamed"
        );
        assert!(target.import_selection_actions("nope", 1).is_err());
    }

    #[test]
    fn script_approval_belongs_to_the_exact_text() {
        let s = open();
        let fp = script_fingerprint("shell", "echo hi");
        assert!(!s.is_script_approved(&fp).unwrap());
        s.approve_script(&fp, "Greeter", 5).unwrap();
        assert!(s.is_script_approved(&fp).unwrap());
        assert!(!s
            .is_script_approved(&script_fingerprint("shell", "echo hi!"))
            .unwrap());
        assert_eq!(s.approved_scripts().unwrap()[0].label, "Greeter");
        assert!(s.approve_script("short", "x", 1).is_err());
        s.revoke_script(&fp).unwrap();
        assert!(!s.is_script_approved(&fp).unwrap());
    }

    #[test]
    fn backups_carry_settings_and_actions_but_never_approvals() {
        let source = open();
        let fp = script_fingerprint("shell", "echo $1");
        source.approve_script(&fp, "Mine", 1).unwrap();
        let mut list = source.selection_actions().unwrap();
        list.push(script("mine"));
        source.save_selection_actions(&list).unwrap();
        source
            .save_selection_config(&SelectionConfig {
                activation_delay_ms: 777,
                ..SelectionConfig::default()
            })
            .unwrap();
        let json = source.export_backup("0.7.0", 1).unwrap();
        assert!(!json.contains(&fp), "approvals are not in the file");

        let target = open();
        target.import_backup(&json).unwrap();
        assert!(target
            .selection_actions()
            .unwrap()
            .iter()
            .any(|a| a.id == "mine"));
        assert_eq!(target.selection_config().unwrap().activation_delay_ms, 777);
        assert!(
            !target.is_script_approved(&fp).unwrap(),
            "a restored script has to be approved again"
        );

        let keeper = open();
        keeper
            .save_selection_config(&SelectionConfig {
                activation_delay_ms: 5,
                ..SelectionConfig::default()
            })
            .unwrap();
        let mut value: serde_json::Value = serde_json::from_str(&json).unwrap();
        value.as_object_mut().unwrap().remove("selection");
        keeper.import_backup(&value.to_string()).unwrap();
        assert_eq!(keeper.selection_config().unwrap().activation_delay_ms, 5);
    }

    #[test]
    fn restoring_defaults_keeps_or_resets_actions() {
        let s = open();
        let mut list = s.selection_actions().unwrap();
        list.push(script("mine"));
        s.save_selection_actions(&list).unwrap();
        s.save_selection_config(&SelectionConfig {
            max_visible: 3,
            ..SelectionConfig::default()
        })
        .unwrap();
        s.restore_default_selection_settings(false).unwrap();
        assert_eq!(s.selection_config().unwrap().max_visible, 7);
        assert!(s
            .selection_actions()
            .unwrap()
            .iter()
            .any(|a| a.id == "mine"));
        s.restore_default_selection_settings(true).unwrap();
        assert!(!s
            .selection_actions()
            .unwrap()
            .iter()
            .any(|a| a.id == "mine"));
    }

    #[test]
    fn plain_and_markdown_copy_reach_existing_users_once() {
        let store = open();
        let old: Vec<SelectionAction> = default_actions()
            .into_iter()
            .filter(|a| a.id != "copy-plain" && a.id != "copy-markdown")
            .collect();
        store.save_selection_actions(&old).unwrap();
        let first = store.selection_actions().unwrap();
        assert!(first.iter().any(|a| a.id == "copy-plain"));
        assert!(first.iter().any(|a| a.id == "copy-markdown"));
        let mut trimmed = first.clone();
        trimmed.retain(|a| a.id != "copy-markdown");
        store.save_selection_actions(&trimmed).unwrap();
        assert!(!store
            .selection_actions()
            .unwrap()
            .iter()
            .any(|a| a.id == "copy-markdown"));
    }
}
