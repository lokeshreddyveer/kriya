//! Storage for the traffic-light controls: general settings and per-app profiles.

use std::collections::HashSet;

use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};

use crate::backup::BackupFile;
use crate::error::CoreError;
use crate::store::{self, Store};
use crate::traffic::{missing_actions, TrafficConfig, TrafficProfile};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TrafficBackup {
    pub config: TrafficConfig,
    pub profiles: Vec<TrafficProfile>,
}

impl Store {
    pub fn traffic_config(&self) -> Result<TrafficConfig, CoreError> {
        read_config(&self.conn())
    }

    pub fn save_traffic_config(&self, config: &TrafficConfig) -> Result<(), CoreError> {
        let conn = self.conn();
        let clean = config.clone().sanitized();
        check_references(&conn, &clean.referenced_actions())?;
        write_json(&conn, "traffic_config", &clean)
    }

    pub fn traffic_profiles(&self) -> Result<Vec<TrafficProfile>, CoreError> {
        read_profiles(&self.conn())
    }

    /// One profile per app: saving another for the same app replaces it.
    pub fn save_traffic_profile(&self, profile: &TrafficProfile) -> Result<(), CoreError> {
        if profile.id.trim().is_empty() || profile.app_id.trim().is_empty() {
            return Err(CoreError::invalid("a profile needs an app"));
        }
        let conn = self.conn();
        let clean = profile.clone().sanitized();
        let refs: Vec<String> = clean
            .bindings
            .iter()
            .filter_map(|b| b.action.referenced_action().map(str::to_string))
            .collect();
        check_references(&conn, &refs)?;
        let mut all = read_profiles(&conn)?;
        all.retain(|p| p.id != clean.id && p.app_id != clean.app_id);
        all.push(clean);
        write_json(&conn, "traffic_profiles", &all)
    }

    pub fn delete_traffic_profile(&self, id: &str) -> Result<(), CoreError> {
        let conn = self.conn();
        let mut all = read_profiles(&conn)?;
        all.retain(|p| p.id != id);
        write_json(&conn, "traffic_profiles", &all)
    }

    /// Puts every button back to normal. With `everything`, also removes app profiles, hover menus and exclusions.
    pub fn restore_default_traffic_settings(&self, everything: bool) -> Result<(), CoreError> {
        let conn = self.conn();
        let tx = conn.unchecked_transaction()?;
        let mut config = read_config(&tx)?;
        config.bindings.clear();
        if everything {
            config = TrafficConfig::default();
            write_json::<Vec<TrafficProfile>>(&tx, "traffic_profiles", &Vec::new())?;
        }
        write_json(&tx, "traffic_config", &config)?;
        tx.commit()?;
        Ok(())
    }
}

/// How many places use a saved action, so it is not deleted from under them.
pub(crate) fn uses_of_action(conn: &Connection, action_id: &str) -> Result<usize, CoreError> {
    let in_config = read_config(conn)?
        .referenced_actions()
        .iter()
        .filter(|id| *id == action_id)
        .count();
    let in_profiles = read_profiles(conn)?
        .iter()
        .flat_map(|p| p.bindings.iter())
        .filter(|b| b.action.referenced_action() == Some(action_id))
        .count();
    Ok(in_config + in_profiles)
}

pub(crate) fn backup_part(conn: &Connection) -> Result<TrafficBackup, CoreError> {
    Ok(TrafficBackup {
        config: read_config(conn)?,
        profiles: read_profiles(conn)?,
    })
}

pub(crate) fn validate_backup(
    file: &BackupFile,
    action_ids: &HashSet<&str>,
) -> Result<(), CoreError> {
    let Some(t) = &file.traffic else {
        return Ok(());
    };
    let bad = |message: &str| CoreError::Backup {
        message: message.to_string(),
    };
    let known: HashSet<String> = action_ids.iter().map(|s| (*s).to_string()).collect();
    let mut refs = t.config.referenced_actions();
    let mut apps = HashSet::new();
    let mut ids = HashSet::new();
    for p in &t.profiles {
        if p.id.trim().is_empty()
            || p.app_id.trim().is_empty()
            || !apps.insert(p.app_id.as_str())
            || !ids.insert(p.id.as_str())
        {
            return Err(bad("a window-button profile in the backup is not valid"));
        }
        refs.extend(
            p.bindings
                .iter()
                .filter_map(|b| b.action.referenced_action().map(str::to_string)),
        );
    }
    if missing_actions(&refs, &known).is_some() {
        return Err(bad(
            "the window-button settings use an action that is not in the backup",
        ));
    }
    Ok(())
}

pub(crate) fn restore_backup(tx: &Connection, file: &BackupFile) -> Result<(), CoreError> {
    let Some(t) = &file.traffic else {
        return Ok(());
    };
    write_json(tx, "traffic_config", &t.config.clone().sanitized())?;
    let profiles: Vec<TrafficProfile> = t
        .profiles
        .iter()
        .cloned()
        .map(TrafficProfile::sanitized)
        .collect();
    write_json(tx, "traffic_profiles", &profiles)
}

fn check_references(conn: &Connection, refs: &[String]) -> Result<(), CoreError> {
    let known: HashSet<String> = store::read_actions(conn)?
        .into_iter()
        .map(|a| a.id)
        .collect();
    if missing_actions(refs, &known).is_some() {
        return Err(CoreError::invalid(
            "a button uses a saved action that no longer exists",
        ));
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

fn read_config(conn: &Connection) -> Result<TrafficConfig, CoreError> {
    Ok(read_json::<TrafficConfig>(conn, "traffic_config")?
        .unwrap_or_default()
        .sanitized())
}

fn read_profiles(conn: &Connection) -> Result<Vec<TrafficProfile>, CoreError> {
    Ok(read_json::<Vec<TrafficProfile>>(conn, "traffic_profiles")?.unwrap_or_default())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::actions::{modifiers as m, Action, NamedAction};
    use crate::traffic::{HoverSet, TrafficAction, TrafficBinding, TrafficButton};

    fn open() -> Store {
        Store::open_in_memory().unwrap()
    }

    fn bind(action: TrafficAction) -> TrafficBinding {
        TrafficBinding {
            button: TrafficButton::Close,
            modifiers: m::OPTION,
            action,
        }
    }

    fn saved(id: &str) -> NamedAction {
        NamedAction {
            id: id.into(),
            name: "A".into(),
            action: Action::Noop,
        }
    }

    #[test]
    fn config_persists_and_is_cleaned() {
        let store = open();
        assert_eq!(store.traffic_config().unwrap(), TrafficConfig::default());
        store
            .save_traffic_config(&TrafficConfig {
                bindings: vec![bind(TrafficAction::QuitApp)],
                hover_delay_ms: 1,
                ..TrafficConfig::default()
            })
            .unwrap();
        let c = store.traffic_config().unwrap();
        assert_eq!(c.bindings.len(), 1);
        assert_eq!(c.hover_delay_ms, 300);
    }

    #[test]
    fn saved_actions_must_exist_and_are_protected_while_used() {
        let store = open();
        let uses = TrafficConfig {
            bindings: vec![bind(TrafficAction::Run {
                action_id: "a".into(),
            })],
            ..TrafficConfig::default()
        };
        assert!(store.save_traffic_config(&uses).is_err());
        store.save_action(&saved("a")).unwrap();
        store.save_traffic_config(&uses).unwrap();
        assert!(store.delete_action("a").is_err());
        store.restore_default_traffic_settings(false).unwrap();
        store.delete_action("a").unwrap();
    }

    #[test]
    fn hover_actions_count_as_uses_too() {
        let store = open();
        store.save_action(&saved("a")).unwrap();
        let c = TrafficConfig {
            hover_sets: vec![HoverSet {
                button: TrafficButton::Zoom,
                actions: vec![TrafficAction::Run {
                    action_id: "a".into(),
                }],
            }],
            ..TrafficConfig::default()
        };
        store.save_traffic_config(&c).unwrap();
        assert!(store.delete_action("a").is_err());
    }

    #[test]
    fn profiles_are_one_per_app() {
        let store = open();
        let p = |id: &str, action| TrafficProfile {
            id: id.into(),
            app_id: "app".into(),
            enabled: true,
            bindings: vec![bind(action)],
        };
        store
            .save_traffic_profile(&p("1", TrafficAction::QuitApp))
            .unwrap();
        store
            .save_traffic_profile(&p("2", TrafficAction::HideApp))
            .unwrap();
        let all = store.traffic_profiles().unwrap();
        assert_eq!(all.len(), 1);
        assert_eq!(all[0].bindings[0].action, TrafficAction::HideApp);
        assert!(store
            .save_traffic_profile(&TrafficProfile {
                app_id: " ".into(),
                ..p("3", TrafficAction::Native)
            })
            .is_err());
        store.delete_traffic_profile("2").unwrap();
        assert!(store.traffic_profiles().unwrap().is_empty());
    }

    #[test]
    fn restoring_defaults_keeps_or_clears_the_rest() {
        let store = open();
        store
            .save_traffic_config(&TrafficConfig {
                bindings: vec![bind(TrafficAction::QuitApp)],
                excluded_app_ids: vec!["x".into()],
                ..TrafficConfig::default()
            })
            .unwrap();
        store
            .save_traffic_profile(&TrafficProfile {
                id: "p".into(),
                app_id: "a".into(),
                enabled: true,
                bindings: vec![],
            })
            .unwrap();
        store.restore_default_traffic_settings(false).unwrap();
        assert!(store.traffic_config().unwrap().bindings.is_empty());
        assert_eq!(store.traffic_config().unwrap().excluded_app_ids.len(), 1);
        assert_eq!(store.traffic_profiles().unwrap().len(), 1);
        store.restore_default_traffic_settings(true).unwrap();
        assert!(store.traffic_config().unwrap().excluded_app_ids.is_empty());
        assert!(store.traffic_profiles().unwrap().is_empty());
    }

    #[test]
    fn traffic_data_survives_a_backup_and_older_backups_leave_it_alone() {
        let source = open();
        source
            .save_traffic_config(&TrafficConfig {
                bindings: vec![bind(TrafficAction::QuitApp)],
                ..TrafficConfig::default()
            })
            .unwrap();
        let json = source.export_backup("0.4.0", 1).unwrap();
        let target = open();
        target.import_backup(&json).unwrap();
        assert_eq!(target.traffic_config().unwrap().bindings.len(), 1);

        let keeper = open();
        keeper
            .save_traffic_config(&TrafficConfig {
                bindings: vec![bind(TrafficAction::HideApp)],
                ..TrafficConfig::default()
            })
            .unwrap();
        let mut value: serde_json::Value = serde_json::from_str(&json).unwrap();
        value.as_object_mut().unwrap().remove("traffic");
        keeper.import_backup(&value.to_string()).unwrap();
        assert_eq!(
            keeper.traffic_config().unwrap().bindings[0].action,
            TrafficAction::HideApp
        );
    }

    #[test]
    fn a_backup_using_a_missing_action_changes_nothing() {
        let store = open();
        store
            .save_traffic_config(&TrafficConfig {
                bindings: vec![bind(TrafficAction::HideApp)],
                ..TrafficConfig::default()
            })
            .unwrap();
        let json = open().export_backup("0.4.0", 1).unwrap();
        let mut value: serde_json::Value = serde_json::from_str(&json).unwrap();
        value["traffic"]["config"]["bindings"] = serde_json::json!([
            {"button": "close", "modifiers": 4, "action": {"type": "run", "action_id": "ghost"}}
        ]);
        assert!(store.import_backup(&value.to_string()).is_err());
        assert_eq!(
            store.traffic_config().unwrap().bindings[0].action,
            TrafficAction::HideApp
        );
    }
}
