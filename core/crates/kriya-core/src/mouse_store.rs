//! Storage for mouse presets, the assignments that choose a preset for a device or app, and the mouse configuration.

use std::collections::{HashMap, HashSet};

use rusqlite::{params, Connection, OptionalExtension};

use crate::actions::NamedAction;
use crate::backup::BackupFile;
use crate::error::CoreError;
use crate::mouse::{
    self, builtin_templates, MouseAssignment, MouseConfig, MousePreset, MouseSettings,
    BUILTIN_PREFIX, DEFAULT_PRESET_ID,
};
use crate::store::{self, Store};

impl Store {
    /// Every preset: the editable default first, then the built-in templates, then the person's own.
    pub fn mouse_presets(&self) -> Result<Vec<MousePreset>, CoreError> {
        let conn = self.conn();
        all_presets(&conn)
    }

    pub fn save_mouse_preset(&self, preset: &MousePreset) -> Result<(), CoreError> {
        let conn = self.conn();
        check_preset(&conn, preset)?;
        write_preset(&conn, preset)
    }

    pub fn delete_mouse_preset(&self, id: &str) -> Result<(), CoreError> {
        if id == DEFAULT_PRESET_ID || id.starts_with(BUILTIN_PREFIX) {
            return Err(CoreError::invalid("built-in presets cannot be deleted"));
        }
        let conn = self.conn();
        let tx = conn.unchecked_transaction()?;
        tx.execute("DELETE FROM mouse_presets WHERE id = ?1", params![id])?;
        tx.execute(
            "DELETE FROM mouse_assignments WHERE preset_id = ?1",
            params![id],
        )?;
        let mut config = read_config(&tx)?;
        if config.default_preset_id == id {
            config.default_preset_id = DEFAULT_PRESET_ID.to_string();
            write_config(&tx, &config)?;
        }
        tx.commit()?;
        Ok(())
    }

    pub fn mouse_assignments(&self) -> Result<Vec<MouseAssignment>, CoreError> {
        let conn = self.conn();
        read_assignments(&conn)
    }

    /// Saves an assignment. A second assignment for the same device and app replaces the first.
    pub fn save_mouse_assignment(&self, assignment: &MouseAssignment) -> Result<(), CoreError> {
        if assignment.id.trim().is_empty() {
            return Err(CoreError::invalid("an assignment needs an id"));
        }
        if assignment.device_id.is_none() && assignment.app_id.is_none() {
            return Err(CoreError::invalid(
                "choose a device, an app, or both; the default preset covers everything else",
            ));
        }
        let conn = self.conn();
        if !all_presets(&conn)?
            .iter()
            .any(|p| p.id == assignment.preset_id)
        {
            return Err(CoreError::invalid("that preset no longer exists"));
        }
        let tx = conn.unchecked_transaction()?;
        tx.execute(
            "DELETE FROM mouse_assignments WHERE id != ?1 AND device_id IS ?2 AND app_id IS ?3",
            params![assignment.id, assignment.device_id, assignment.app_id],
        )?;
        tx.execute(
            "INSERT INTO mouse_assignments (id, device_id, app_id, preset_id) VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(id) DO UPDATE SET device_id = excluded.device_id, app_id = excluded.app_id,
                                           preset_id = excluded.preset_id",
            params![assignment.id, assignment.device_id, assignment.app_id, assignment.preset_id],
        )?;
        tx.commit()?;
        Ok(())
    }

    pub fn delete_mouse_assignment(&self, id: &str) -> Result<(), CoreError> {
        self.conn()
            .execute("DELETE FROM mouse_assignments WHERE id = ?1", params![id])?;
        Ok(())
    }

    pub fn mouse_config(&self) -> Result<MouseConfig, CoreError> {
        let conn = self.conn();
        read_config(&conn)
    }

    pub fn save_mouse_config(&self, config: &MouseConfig) -> Result<(), CoreError> {
        let conn = self.conn();
        let clean = clean_config(config);
        if !all_presets(&conn)?
            .iter()
            .any(|p| p.id == clean.default_preset_id)
        {
            return Err(CoreError::invalid("the default preset no longer exists"));
        }
        write_config(&conn, &clean)
    }

    /// Puts the default preset back to how it shipped. With `everything`, also removes the person's own presets,
    /// the assignments and the app exclusions.
    pub fn restore_default_mouse_settings(&self, everything: bool) -> Result<(), CoreError> {
        let conn = self.conn();
        let tx = conn.unchecked_transaction()?;
        write_preset(&tx, &MousePreset::factory_default())?;
        if everything {
            tx.execute(
                "DELETE FROM mouse_presets WHERE id != ?1",
                params![DEFAULT_PRESET_ID],
            )?;
            tx.execute("DELETE FROM mouse_assignments", [])?;
            write_config(&tx, &MouseConfig::default())?;
        }
        tx.commit()?;
        Ok(())
    }

    /// A preset as a file's text, with the saved actions it uses.
    pub fn export_mouse_preset(&self, id: &str) -> Result<String, CoreError> {
        let conn = self.conn();
        let preset = all_presets(&conn)?
            .into_iter()
            .find(|p| p.id == id)
            .ok_or(CoreError::NotFound)?;
        let actions = store::read_actions(&conn)?;
        mouse::make_preset_file(&preset, &actions)
    }

    /// Adds a preset from a file under `new_id`. Its actions come with it; an action that clashes with a different
    /// one already saved is added under a new id and the preset is pointed at it.
    pub fn import_mouse_preset(&self, json: &str, new_id: &str) -> Result<MousePreset, CoreError> {
        if new_id.trim().is_empty()
            || new_id.starts_with(BUILTIN_PREFIX)
            || new_id == DEFAULT_PRESET_ID
        {
            return Err(CoreError::invalid("the new preset needs its own id"));
        }
        let file = mouse::parse_preset_file(json)?;
        let conn = self.conn();
        let tx = conn.unchecked_transaction()?;

        let existing: HashMap<String, NamedAction> = store::read_actions(&tx)?
            .into_iter()
            .map(|a| (a.id.clone(), a))
            .collect();
        let mut taken: HashSet<String> = existing.keys().cloned().collect();
        let mut remap = HashMap::new();
        for incoming in &file.actions {
            store::check_named_action(incoming).map_err(|e| CoreError::Backup {
                message: e.to_string(),
            })?;
            match existing.get(&incoming.id) {
                None => {
                    store::upsert_action(&tx, incoming)?;
                    taken.insert(incoming.id.clone());
                }
                Some(found) if found == incoming => {}
                Some(_) => {
                    let mut n = 1;
                    let fresh = loop {
                        let candidate = format!("{}-imported-{n}", incoming.id);
                        if !taken.contains(&candidate) {
                            break candidate;
                        }
                        n += 1;
                    };
                    taken.insert(fresh.clone());
                    let renamed = NamedAction {
                        id: fresh.clone(),
                        ..incoming.clone()
                    };
                    store::upsert_action(&tx, &renamed)?;
                    remap.insert(incoming.id.clone(), fresh);
                }
            }
        }

        let mut settings = file.settings.sanitized();
        settings.remap_action_ids(&remap);
        let names: HashSet<String> = all_presets(&tx)?.into_iter().map(|p| p.name).collect();
        let mut name = file.name.trim().to_string();
        if name.is_empty() {
            name = "Imported preset".to_string();
        }
        if names.contains(&name) {
            name = format!("{name} (imported)");
        }
        let preset = MousePreset {
            id: new_id.to_string(),
            name,
            is_builtin: false,
            settings,
        };
        check_preset(&tx, &preset)?;
        write_preset(&tx, &preset)?;
        tx.commit()?;
        Ok(preset)
    }
}

// ---- helpers shared with backup and the action store ------------------------------------------------------------------

/// How many saved presets use an action, so it is not deleted from under them.
pub(crate) fn preset_uses_of_action(
    conn: &Connection,
    action_id: &str,
) -> Result<usize, CoreError> {
    Ok(db_presets(conn)?
        .iter()
        .filter(|p| {
            p.settings
                .referenced_action_ids()
                .iter()
                .any(|id| id == action_id)
        })
        .count())
}

pub(crate) fn forget_device_assignments(
    conn: &Connection,
    device_id: &str,
) -> Result<(), CoreError> {
    conn.execute(
        "DELETE FROM mouse_assignments WHERE device_id = ?1",
        params![device_id],
    )?;
    Ok(())
}

/// The mouse data a backup holds: only presets the person owns (the default and their own), not the shipped templates.
pub(crate) fn backup_parts(
    conn: &Connection,
) -> Result<(Vec<MousePreset>, Vec<MouseAssignment>, MouseConfig), CoreError> {
    ensure_default_preset(conn)?;
    Ok((
        db_presets(conn)?,
        read_assignments(conn)?,
        read_config(conn)?,
    ))
}

/// Checks the mouse part of a backup against the actions the backup holds. Called before anything is changed.
pub(crate) fn validate_backup(
    file: &BackupFile,
    action_ids: &HashSet<&str>,
) -> Result<(), CoreError> {
    let bad = |message: &str| CoreError::Backup {
        message: message.to_string(),
    };
    let mut preset_ids = HashSet::new();
    for p in &file.mouse_presets {
        if p.id.starts_with(BUILTIN_PREFIX)
            || p.name.trim().is_empty()
            || !preset_ids.insert(p.id.as_str())
        {
            return Err(bad("a mouse preset in the backup is not valid"));
        }
        if p.settings
            .referenced_action_ids()
            .iter()
            .any(|id| !action_ids.contains(id.as_str()))
        {
            return Err(bad(
                "a mouse preset refers to an action that is not in the backup",
            ));
        }
    }
    let known = |id: &str| {
        id == DEFAULT_PRESET_ID
            || (id.starts_with(BUILTIN_PREFIX) && builtin_templates().iter().any(|t| t.id == id))
            || preset_ids.contains(id)
    };
    for a in &file.mouse_assignments {
        if (a.device_id.is_none() && a.app_id.is_none()) || !known(&a.preset_id) {
            return Err(bad("a mouse assignment in the backup is not valid"));
        }
    }
    if !known(&file.mouse_config.default_preset_id) {
        return Err(bad("the backup's default mouse preset is missing"));
    }
    Ok(())
}

/// Replaces the mouse data with what a backup holds. A backup from before Phase 2 has none, and leaves it alone.
pub(crate) fn restore_backup(tx: &Connection, file: &BackupFile) -> Result<(), CoreError> {
    if file.mouse_presets.is_empty() && file.mouse_assignments.is_empty() {
        return Ok(());
    }
    tx.execute("DELETE FROM mouse_assignments", [])?;
    tx.execute("DELETE FROM mouse_presets", [])?;
    for p in &file.mouse_presets {
        write_preset(tx, p)?;
    }
    ensure_default_preset(tx)?;
    for a in &file.mouse_assignments {
        tx.execute(
            "INSERT INTO mouse_assignments (id, device_id, app_id, preset_id) VALUES (?1, ?2, ?3, ?4)",
            params![a.id, a.device_id, a.app_id, a.preset_id],
        )?;
    }
    write_config(tx, &clean_config(&file.mouse_config))
}

// ---- connection-level helpers ------------------------------------------------------------------------------------------

fn ensure_default_preset(conn: &Connection) -> Result<(), CoreError> {
    let exists: Option<i64> = conn
        .query_row(
            "SELECT 1 FROM mouse_presets WHERE id = ?1",
            params![DEFAULT_PRESET_ID],
            |r| r.get(0),
        )
        .optional()?;
    if exists.is_none() {
        write_preset(conn, &MousePreset::factory_default())?;
    }
    Ok(())
}

/// The presets kept in the database: the default and the person's own.
fn db_presets(conn: &Connection) -> Result<Vec<MousePreset>, CoreError> {
    let mut stmt = conn.prepare(
        "SELECT id, name, settings_json FROM mouse_presets
         ORDER BY (id = 'default') DESC, sort_order, name COLLATE NOCASE",
    )?;
    let rows = stmt.query_map([], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, String>(2)?,
        ))
    })?;
    let mut out = Vec::new();
    for row in rows {
        let (id, name, json) = row?;
        let settings = serde_json::from_str::<MouseSettings>(&json)
            .unwrap_or_default()
            .sanitized();
        let is_builtin = id == DEFAULT_PRESET_ID;
        out.push(MousePreset {
            id,
            name,
            is_builtin,
            settings,
        });
    }
    Ok(out)
}

fn all_presets(conn: &Connection) -> Result<Vec<MousePreset>, CoreError> {
    ensure_default_preset(conn)?;
    let mut out = db_presets(conn)?;
    let at = out
        .iter()
        .position(|p| p.id == DEFAULT_PRESET_ID)
        .map_or(0, |i| i + 1);
    out.splice(at..at, builtin_templates());
    Ok(out)
}

fn check_preset(conn: &Connection, preset: &MousePreset) -> Result<(), CoreError> {
    if preset.id.trim().is_empty() {
        return Err(CoreError::invalid("a preset needs an id"));
    }
    if preset.id.starts_with(BUILTIN_PREFIX) {
        return Err(CoreError::invalid(
            "built-in presets cannot be changed; duplicate it first",
        ));
    }
    let name = preset.name.trim();
    if name.is_empty() || name.chars().count() > 100 {
        return Err(CoreError::invalid(
            "a preset needs a name of up to 100 characters",
        ));
    }
    let known: HashSet<String> = store::read_actions(conn)?
        .into_iter()
        .map(|a| a.id)
        .collect();
    if preset
        .settings
        .referenced_action_ids()
        .iter()
        .any(|id| !known.contains(id))
    {
        return Err(CoreError::invalid(
            "the preset uses an action that no longer exists",
        ));
    }
    Ok(())
}

fn write_preset(conn: &Connection, preset: &MousePreset) -> Result<(), CoreError> {
    let json = serde_json::to_string(&preset.settings.clone().sanitized())?;
    conn.execute(
        "INSERT INTO mouse_presets (id, name, settings_json, sort_order)
         VALUES (?1, ?2, ?3, COALESCE((SELECT MAX(sort_order) + 1 FROM mouse_presets), 0))
         ON CONFLICT(id) DO UPDATE SET name = excluded.name, settings_json = excluded.settings_json",
        params![preset.id, preset.name.trim(), json],
    )?;
    Ok(())
}

fn read_assignments(conn: &Connection) -> Result<Vec<MouseAssignment>, CoreError> {
    let mut stmt =
        conn.prepare("SELECT id, device_id, app_id, preset_id FROM mouse_assignments ORDER BY id")?;
    let rows = stmt.query_map([], |r| {
        Ok(MouseAssignment {
            id: r.get(0)?,
            device_id: r.get(1)?,
            app_id: r.get(2)?,
            preset_id: r.get(3)?,
        })
    })?;
    Ok(rows.collect::<Result<Vec<_>, _>>()?)
}

fn clean_config(config: &MouseConfig) -> MouseConfig {
    let mut seen = HashSet::new();
    let excluded = config
        .excluded_app_ids
        .iter()
        .map(|a| a.trim().to_string())
        .filter(|a| !a.is_empty() && seen.insert(a.clone()))
        .collect();
    MouseConfig {
        excluded_app_ids: excluded,
        default_preset_id: if config.default_preset_id.trim().is_empty() {
            DEFAULT_PRESET_ID.to_string()
        } else {
            config.default_preset_id.clone()
        },
    }
}

fn read_config(conn: &Connection) -> Result<MouseConfig, CoreError> {
    let json: Option<String> = conn
        .query_row(
            "SELECT value FROM settings WHERE key = 'mouse_config'",
            [],
            |r| r.get(0),
        )
        .optional()?;
    Ok(json
        .and_then(|j| serde_json::from_str::<MouseConfig>(&j).ok())
        .map(|c| clean_config(&c))
        .unwrap_or_default())
}

fn write_config(conn: &Connection, config: &MouseConfig) -> Result<(), CoreError> {
    let json = serde_json::to_string(config)?;
    conn.execute(
        "INSERT INTO settings (key, value) VALUES ('mouse_config', ?1)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![json],
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::actions::Action;
    use crate::mouse::{
        ButtonRule, ButtonTrigger, GestureBinding, GestureDirection, GestureSettings, ScrollAxis,
    };

    fn open() -> Store {
        Store::open_in_memory().unwrap()
    }

    fn action(id: &str) -> NamedAction {
        NamedAction {
            id: id.into(),
            name: format!("Action {id}"),
            action: Action::Noop,
        }
    }

    fn preset(id: &str, action_id: Option<&str>) -> MousePreset {
        let mut settings = MouseSettings::default();
        if let Some(a) = action_id {
            settings.buttons.push(ButtonRule {
                button: 3,
                modifiers: 0,
                action_id: a.into(),
                trigger: ButtonTrigger::Click,
            });
        }
        MousePreset {
            id: id.into(),
            name: format!("Preset {id}"),
            is_builtin: false,
            settings,
        }
    }

    fn assignment(
        id: &str,
        device: Option<&str>,
        app: Option<&str>,
        preset: &str,
    ) -> MouseAssignment {
        MouseAssignment {
            id: id.into(),
            device_id: device.map(str::to_string),
            app_id: app.map(str::to_string),
            preset_id: preset.into(),
        }
    }

    #[test]
    fn presets_list_default_then_templates_then_own() {
        let store = open();
        store.save_mouse_preset(&preset("mine", None)).unwrap();
        let ids: Vec<String> = store
            .mouse_presets()
            .unwrap()
            .into_iter()
            .map(|p| p.id)
            .collect();
        assert_eq!(ids[0], DEFAULT_PRESET_ID);
        assert!(ids[1].starts_with(BUILTIN_PREFIX));
        assert_eq!(ids.last().unwrap(), "mine");
    }

    #[test]
    fn built_in_presets_are_protected() {
        let store = open();
        let mut template = builtin_templates().remove(0);
        template.name = "Hacked".into();
        assert!(store.save_mouse_preset(&template).is_err());
        assert!(store.delete_mouse_preset(&template.id).is_err());
        assert!(store.delete_mouse_preset(DEFAULT_PRESET_ID).is_err());
    }

    #[test]
    fn the_default_preset_can_be_edited_and_restored() {
        let store = open();
        let mut default = store.mouse_presets().unwrap().remove(0);
        default.settings.vertical = ScrollAxis {
            reverse: true,
            ..ScrollAxis::default()
        };
        store.save_mouse_preset(&default).unwrap();
        assert!(store.mouse_presets().unwrap()[0].settings.vertical.reverse);
        store.restore_default_mouse_settings(false).unwrap();
        assert!(!store.mouse_presets().unwrap()[0].settings.vertical.reverse);
    }

    #[test]
    fn presets_need_their_actions_to_exist() {
        let store = open();
        assert!(store
            .save_mouse_preset(&preset("p", Some("missing")))
            .is_err());
        store.save_action(&action("a")).unwrap();
        store.save_mouse_preset(&preset("p", Some("a"))).unwrap();
        assert!(
            store.delete_action("a").is_err(),
            "an action a preset uses cannot be deleted"
        );
    }

    #[test]
    fn assignments_replace_one_another_for_the_same_target() {
        let store = open();
        store.save_mouse_preset(&preset("p", None)).unwrap();
        store
            .save_mouse_assignment(&assignment("1", Some("dev"), None, "p"))
            .unwrap();
        store
            .save_mouse_assignment(&assignment("2", Some("dev"), None, "builtin.fast"))
            .unwrap();
        let list = store.mouse_assignments().unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].preset_id, "builtin.fast");
        assert!(store
            .save_mouse_assignment(&assignment("3", None, None, "p"))
            .is_err());
        assert!(store
            .save_mouse_assignment(&assignment("4", Some("x"), None, "nope"))
            .is_err());
    }

    #[test]
    fn deleting_a_preset_removes_its_assignments_and_default_role() {
        let store = open();
        store.save_mouse_preset(&preset("p", None)).unwrap();
        store
            .save_mouse_assignment(&assignment("1", None, Some("app"), "p"))
            .unwrap();
        store
            .save_mouse_config(&MouseConfig {
                default_preset_id: "p".into(),
                ..MouseConfig::default()
            })
            .unwrap();
        store.delete_mouse_preset("p").unwrap();
        assert!(store.mouse_assignments().unwrap().is_empty());
        assert_eq!(
            store.mouse_config().unwrap().default_preset_id,
            DEFAULT_PRESET_ID
        );
    }

    #[test]
    fn config_cleans_the_exclusion_list() {
        let store = open();
        store
            .save_mouse_config(&MouseConfig {
                excluded_app_ids: vec![" a ".into(), "a".into(), "".into(), "b".into()],
                default_preset_id: String::new(),
            })
            .unwrap();
        let c = store.mouse_config().unwrap();
        assert_eq!(c.excluded_app_ids, vec!["a".to_string(), "b".to_string()]);
        assert_eq!(c.default_preset_id, DEFAULT_PRESET_ID);
    }

    #[test]
    fn restoring_everything_clears_presets_assignments_and_exclusions() {
        let store = open();
        store.save_mouse_preset(&preset("p", None)).unwrap();
        store
            .save_mouse_assignment(&assignment("1", Some("d"), None, "p"))
            .unwrap();
        store
            .save_mouse_config(&MouseConfig {
                excluded_app_ids: vec!["x".into()],
                ..MouseConfig::default()
            })
            .unwrap();
        store.restore_default_mouse_settings(true).unwrap();
        assert!(store.mouse_assignments().unwrap().is_empty());
        assert!(store.mouse_config().unwrap().excluded_app_ids.is_empty());
        assert!(!store.mouse_presets().unwrap().iter().any(|p| p.id == "p"));
    }

    #[test]
    fn export_and_import_move_a_preset_with_its_actions() {
        let source = open();
        source.save_action(&action("a")).unwrap();
        let mut p = preset("p", Some("a"));
        p.settings.gestures = GestureSettings {
            enabled: true,
            bindings: vec![GestureBinding {
                direction: GestureDirection::Left,
                action_id: "a".into(),
            }],
            ..GestureSettings::default()
        };
        source.save_mouse_preset(&p).unwrap();
        let json = source.export_mouse_preset("p").unwrap();

        let target = open();
        let imported = target.import_mouse_preset(&json, "new").unwrap();
        assert_eq!(imported.id, "new");
        assert_eq!(target.actions().unwrap().len(), 1);
        assert_eq!(imported.settings.buttons[0].action_id, "a");
    }

    #[test]
    fn importing_a_clashing_action_keeps_both_and_repoints_the_preset() {
        let source = open();
        source.save_action(&action("a")).unwrap();
        source.save_mouse_preset(&preset("p", Some("a"))).unwrap();
        let json = source.export_mouse_preset("p").unwrap();

        let target = open();
        target
            .save_action(&NamedAction {
                id: "a".into(),
                name: "Different".into(),
                action: Action::RunShortcut {
                    name: "Other".into(),
                },
            })
            .unwrap();
        let imported = target.import_mouse_preset(&json, "new").unwrap();
        assert_eq!(target.actions().unwrap().len(), 2);
        assert_eq!(imported.settings.buttons[0].action_id, "a-imported-1");
    }

    #[test]
    fn importing_the_same_name_does_not_overwrite() {
        let store = open();
        store.save_mouse_preset(&preset("p", None)).unwrap();
        let json = store.export_mouse_preset("p").unwrap();
        let imported = store.import_mouse_preset(&json, "copy").unwrap();
        assert_eq!(imported.name, "Preset p (imported)");
        assert!(store.import_mouse_preset("junk", "x").is_err());
        assert!(store.import_mouse_preset(&json, DEFAULT_PRESET_ID).is_err());
    }

    #[test]
    fn mouse_data_survives_a_backup_round_trip() {
        let source = open();
        source.save_action(&action("a")).unwrap();
        source.save_mouse_preset(&preset("p", Some("a"))).unwrap();
        source
            .save_mouse_assignment(&assignment("1", Some("dev"), Some("app"), "p"))
            .unwrap();
        source
            .save_mouse_config(&MouseConfig {
                excluded_app_ids: vec!["x".into()],
                default_preset_id: "p".into(),
            })
            .unwrap();
        let json = source.export_backup("0.2.0", 5).unwrap();

        let target = open();
        target.save_mouse_preset(&preset("old", None)).unwrap();
        target.import_backup(&json).unwrap();
        let ids: Vec<String> = target
            .mouse_presets()
            .unwrap()
            .into_iter()
            .map(|p| p.id)
            .collect();
        assert!(ids.contains(&"p".to_string()));
        assert!(!ids.contains(&"old".to_string()));
        assert_eq!(target.mouse_assignments().unwrap().len(), 1);
        assert_eq!(target.mouse_config().unwrap().default_preset_id, "p");
    }

    #[test]
    fn a_backup_from_before_mouse_support_leaves_mouse_data_alone() {
        let store = open();
        store.save_mouse_preset(&preset("mine", None)).unwrap();
        let json = open().export_backup("0.1.0", 1).unwrap();
        let mut value: serde_json::Value = serde_json::from_str(&json).unwrap();
        let object = value.as_object_mut().unwrap();
        object.remove("mouse_presets");
        object.remove("mouse_assignments");
        object.remove("mouse_config");
        store.import_backup(&value.to_string()).unwrap();
        assert!(store
            .mouse_presets()
            .unwrap()
            .iter()
            .any(|p| p.id == "mine"));
    }

    #[test]
    fn forgetting_a_device_removes_its_assignments() {
        let store = open();
        store
            .save_mouse_assignment(&assignment("1", Some("dev"), None, "builtin.fast"))
            .unwrap();
        store.forget_device("dev").unwrap();
        assert!(store.mouse_assignments().unwrap().is_empty());
    }
}
