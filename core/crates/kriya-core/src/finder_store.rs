//! Storage for the Finder and right-click actions, templates and settings.

use std::collections::HashSet;

use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};

use crate::backup::BackupFile;
use crate::error::CoreError;
use crate::finder::{
    default_file_templates, default_folder_templates, default_items, FileTemplate, FinderConfig,
    FinderItem, FolderTemplate, MAX_ITEMS,
};
use crate::store::Store;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FinderBackup {
    pub config: FinderConfig,
    pub items: Vec<FinderItem>,
    pub file_templates: Vec<FileTemplate>,
    pub folder_templates: Vec<FolderTemplate>,
}

impl Store {
    pub fn finder_config(&self) -> Result<FinderConfig, CoreError> {
        read_config(&self.conn())
    }

    pub fn save_finder_config(&self, config: &FinderConfig) -> Result<(), CoreError> {
        write_json(&self.conn(), "finder_config", &config.clone().sanitized())
    }

    /// The actions in the order the person arranged them.
    pub fn finder_items(&self) -> Result<Vec<FinderItem>, CoreError> {
        read_items(&self.conn())
    }

    /// Saves the whole list, which is also how it is reordered.
    pub fn save_finder_items(&self, items: &[FinderItem]) -> Result<(), CoreError> {
        check_items(items)?;
        write_json(&self.conn(), "finder_items", &items)
    }

    pub fn file_templates(&self) -> Result<Vec<FileTemplate>, CoreError> {
        read_file_templates(&self.conn())
    }

    pub fn save_file_template(&self, template: &FileTemplate) -> Result<(), CoreError> {
        template.check()?;
        let conn = self.conn();
        let mut all = read_file_templates(&conn)?;
        match all.iter_mut().find(|t| t.id == template.id) {
            Some(existing) => *existing = template.clone(),
            None => all.push(template.clone()),
        }
        write_json(&conn, "finder_file_templates", &all)
    }

    pub fn delete_file_template(&self, id: &str) -> Result<(), CoreError> {
        let conn = self.conn();
        let mut all = read_file_templates(&conn)?;
        all.retain(|t| t.id != id);
        write_json(&conn, "finder_file_templates", &all)
    }

    pub fn folder_templates(&self) -> Result<Vec<FolderTemplate>, CoreError> {
        read_folder_templates(&self.conn())
    }

    pub fn save_folder_template(&self, template: &FolderTemplate) -> Result<(), CoreError> {
        template.check()?;
        let conn = self.conn();
        let mut all = read_folder_templates(&conn)?;
        match all.iter_mut().find(|t| t.id == template.id) {
            Some(existing) => *existing = template.clone(),
            None => all.push(template.clone()),
        }
        write_json(&conn, "finder_folder_templates", &all)
    }

    pub fn delete_folder_template(&self, id: &str) -> Result<(), CoreError> {
        let conn = self.conn();
        let mut all = read_folder_templates(&conn)?;
        all.retain(|t| t.id != id);
        write_json(&conn, "finder_folder_templates", &all)
    }

    /// Puts the actions and settings back to how they shipped. With `everything`, the templates too.
    pub fn restore_default_finder_settings(&self, everything: bool) -> Result<(), CoreError> {
        let conn = self.conn();
        let tx = conn.unchecked_transaction()?;
        write_json(&tx, "finder_config", &FinderConfig::default())?;
        write_json(&tx, "finder_items", &default_items())?;
        if everything {
            write_json(&tx, "finder_file_templates", &default_file_templates())?;
            write_json(&tx, "finder_folder_templates", &default_folder_templates())?;
        }
        tx.commit()?;
        Ok(())
    }
}

/// Removes the Finder actions that ran a workflow that no longer exists.
pub(crate) fn remove_workflow_refs(conn: &Connection, workflow_id: &str) -> Result<(), CoreError> {
    let mut list = read_items(conn)?;
    let before = list.len();
    list.retain(|i| !matches!(&i.kind, crate::finder::FinderActionKind::RunWorkflow { workflow_id: id } if id == workflow_id));
    if list.len() != before {
        write_json(conn, "finder_items", &list)?;
    }
    Ok(())
}

pub(crate) fn backup_part(conn: &Connection) -> Result<FinderBackup, CoreError> {
    Ok(FinderBackup {
        config: read_config(conn)?,
        items: read_items(conn)?,
        file_templates: read_file_templates(conn)?,
        folder_templates: read_folder_templates(conn)?,
    })
}

pub(crate) fn validate_backup(file: &BackupFile) -> Result<(), CoreError> {
    let Some(f) = &file.finder else { return Ok(()) };
    check_items(&f.items).map_err(|e| CoreError::Backup {
        message: e.to_string(),
    })?;
    let mut ids = HashSet::new();
    for t in &f.file_templates {
        t.check().map_err(|e| CoreError::Backup {
            message: e.to_string(),
        })?;
        if !ids.insert(t.id.as_str()) {
            return Err(CoreError::Backup {
                message: "two file templates share an id".into(),
            });
        }
    }
    let mut folder_ids = HashSet::new();
    for t in &f.folder_templates {
        t.check().map_err(|e| CoreError::Backup {
            message: e.to_string(),
        })?;
        if !folder_ids.insert(t.id.as_str()) {
            return Err(CoreError::Backup {
                message: "two folder templates share an id".into(),
            });
        }
    }
    Ok(())
}

pub(crate) fn restore_backup(tx: &Connection, file: &BackupFile) -> Result<(), CoreError> {
    let Some(f) = &file.finder else { return Ok(()) };
    write_json(tx, "finder_config", &f.config.clone().sanitized())?;
    write_json(tx, "finder_items", &f.items)?;
    write_json(tx, "finder_file_templates", &f.file_templates)?;
    write_json(tx, "finder_folder_templates", &f.folder_templates)
}

fn check_items(items: &[FinderItem]) -> Result<(), CoreError> {
    if items.len() > MAX_ITEMS {
        return Err(CoreError::invalid("there are too many actions"));
    }
    let mut ids = HashSet::new();
    for item in items {
        item.check()?;
        if !ids.insert(item.id.as_str()) {
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
        "INSERT INTO settings (key, value) VALUES (?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![key, serde_json::to_string(value)?],
    )?;
    Ok(())
}

fn read_config(conn: &Connection) -> Result<FinderConfig, CoreError> {
    Ok(read_json::<FinderConfig>(conn, "finder_config")?
        .unwrap_or_default()
        .sanitized())
}

fn read_items(conn: &Connection) -> Result<Vec<FinderItem>, CoreError> {
    Ok(read_json::<Vec<FinderItem>>(conn, "finder_items")?.unwrap_or_else(default_items))
}

fn read_file_templates(conn: &Connection) -> Result<Vec<FileTemplate>, CoreError> {
    Ok(
        read_json::<Vec<FileTemplate>>(conn, "finder_file_templates")?
            .unwrap_or_else(default_file_templates),
    )
}

fn read_folder_templates(conn: &Connection) -> Result<Vec<FolderTemplate>, CoreError> {
    Ok(
        read_json::<Vec<FolderTemplate>>(conn, "finder_folder_templates")?
            .unwrap_or_else(default_folder_templates),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::finder::{FinderActionKind, TemplateEntry};

    fn open() -> Store {
        Store::open_in_memory().unwrap()
    }

    #[test]
    fn a_fresh_store_has_the_shipped_actions_and_templates() {
        let store = open();
        assert_eq!(store.finder_items().unwrap(), default_items());
        assert_eq!(store.finder_config().unwrap(), FinderConfig::default());
        assert!(!store.file_templates().unwrap().is_empty());
        assert!(!store.folder_templates().unwrap().is_empty());
    }

    #[test]
    fn reordering_and_disabling_persist() {
        let store = open();
        let mut items = store.finder_items().unwrap();
        items.reverse();
        let first = items[0].id.clone();
        items[1].enabled = false;
        let second = items[1].id.clone();
        store.save_finder_items(&items).unwrap();
        let back = store.finder_items().unwrap();
        assert_eq!(back[0].id, first);
        assert!(!back.iter().find(|i| i.id == second).unwrap().enabled);
    }

    #[test]
    fn bad_action_lists_are_refused_whole() {
        let store = open();
        let mut items = store.finder_items().unwrap();
        items.push(items[0].clone());
        assert!(store.save_finder_items(&items).is_err(), "duplicate ids");
        let mut bad = store.finder_items().unwrap();
        bad[0].kind = FinderActionKind::NewFolder { name: "a/b".into() };
        assert!(store.save_finder_items(&bad).is_err());
        assert_eq!(
            store.finder_items().unwrap(),
            default_items(),
            "nothing was changed"
        );
    }

    #[test]
    fn templates_save_update_and_delete() {
        let store = open();
        let t = FileTemplate {
            id: "t1".into(),
            name: "Notes".into(),
            file_name: "notes.md".into(),
            content: Some("hi".into()),
            source_path: None,
        };
        store.save_file_template(&t).unwrap();
        store
            .save_file_template(&FileTemplate {
                name: "Renamed".into(),
                ..t.clone()
            })
            .unwrap();
        assert_eq!(
            store
                .file_templates()
                .unwrap()
                .iter()
                .filter(|x| x.id == "t1")
                .count(),
            1
        );
        assert!(store
            .save_file_template(&FileTemplate {
                file_name: "../x".into(),
                ..t
            })
            .is_err());
        store.delete_file_template("t1").unwrap();
        assert!(!store.file_templates().unwrap().iter().any(|x| x.id == "t1"));

        let f = FolderTemplate {
            id: "f1".into(),
            name: "Site".into(),
            folder_name: "site".into(),
            entries: vec![TemplateEntry {
                path: "css/".into(),
                content: None,
            }],
        };
        store.save_folder_template(&f).unwrap();
        assert!(store
            .save_folder_template(&FolderTemplate {
                entries: vec![TemplateEntry {
                    path: "../x".into(),
                    content: None
                }],
                ..f
            })
            .is_err());
        store.delete_folder_template("f1").unwrap();
    }

    #[test]
    fn restoring_defaults_keeps_or_resets_templates() {
        let store = open();
        store
            .save_finder_config(&FinderConfig {
                menu_title: "Mine".into(),
                ..FinderConfig::default()
            })
            .unwrap();
        store
            .save_file_template(&FileTemplate {
                id: "t1".into(),
                name: "N".into(),
                file_name: "n.txt".into(),
                content: None,
                source_path: None,
            })
            .unwrap();
        store.restore_default_finder_settings(false).unwrap();
        assert_eq!(store.finder_config().unwrap().menu_title, "Kriya");
        assert!(store.file_templates().unwrap().iter().any(|t| t.id == "t1"));
        store.restore_default_finder_settings(true).unwrap();
        assert!(!store.file_templates().unwrap().iter().any(|t| t.id == "t1"));
    }

    #[test]
    fn finder_data_survives_a_backup_and_older_backups_leave_it_alone() {
        let source = open();
        let mut items = source.finder_items().unwrap();
        items.retain(|i| i.id != "compress");
        source.save_finder_items(&items).unwrap();
        source
            .save_finder_config(&FinderConfig {
                favorite_apps: vec!["com.apple.TextEdit".into()],
                ..FinderConfig::default()
            })
            .unwrap();
        let json = source.export_backup("0.5.0", 1).unwrap();

        let target = open();
        target.import_backup(&json).unwrap();
        assert!(!target
            .finder_items()
            .unwrap()
            .iter()
            .any(|i| i.id == "compress"));
        assert_eq!(
            target.finder_config().unwrap().favorite_apps,
            vec!["com.apple.TextEdit".to_string()]
        );

        let keeper = open();
        keeper
            .save_finder_config(&FinderConfig {
                menu_title: "Keep".into(),
                ..FinderConfig::default()
            })
            .unwrap();
        let mut value: serde_json::Value = serde_json::from_str(&json).unwrap();
        value.as_object_mut().unwrap().remove("finder");
        keeper.import_backup(&value.to_string()).unwrap();
        assert_eq!(keeper.finder_config().unwrap().menu_title, "Keep");
    }

    #[test]
    fn a_backup_with_a_bad_finder_section_changes_nothing() {
        let store = open();
        store
            .save_finder_config(&FinderConfig {
                menu_title: "Keep".into(),
                ..FinderConfig::default()
            })
            .unwrap();
        let json = open().export_backup("0.5.0", 1).unwrap();
        let mut value: serde_json::Value = serde_json::from_str(&json).unwrap();
        value["finder"]["items"][1] = value["finder"]["items"][0].clone();
        assert!(store.import_backup(&value.to_string()).is_err());
        assert_eq!(store.finder_config().unwrap().menu_title, "Keep");
    }

    #[test]
    fn the_launcher_shortcut_is_kept_with_the_settings() {
        let store = open();
        store
            .save_finder_config(&FinderConfig {
                launcher_key_code: Some(11),
                launcher_modifiers: 8,
                ..FinderConfig::default()
            })
            .unwrap();
        let c = store.finder_config().unwrap();
        assert_eq!((c.launcher_key_code, c.launcher_modifiers), (Some(11), 8));
    }
}
