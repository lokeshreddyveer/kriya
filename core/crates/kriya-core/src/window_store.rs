//! Storage for window management: settings, shortcuts, custom sizes, saved layouts and placement rules.

use std::collections::HashSet;

use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};

use crate::actions::modifiers as m;
use crate::backup::BackupFile;
use crate::error::CoreError;
use crate::store::Store;
use crate::windows::{
    added_default_shortcuts, check_shortcuts, default_shortcuts, CustomSize, LayoutEntry,
    PlacementRule, SavedLayout, ShortcutBinding, UnplacedPolicy, WindowConfig, CUSTOM_PREFIX,
    LAYOUT_PREFIX, SHORTCUT_LIST_VERSION,
};

const MAX_LAYOUT_ENTRIES: usize = 300;
const MAX_AUTO_LAYOUTS: i64 = 20;
const MAX_NAME: usize = 100;

/// Everything window management keeps, as written into a backup.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WindowBackup {
    pub config: WindowConfig,
    pub shortcuts: Vec<ShortcutBinding>,
    pub sizes: Vec<CustomSize>,
    pub layouts: Vec<SavedLayout>,
    pub rules: Vec<PlacementRule>,
}

impl Store {
    pub fn window_config(&self) -> Result<WindowConfig, CoreError> {
        read_config(&self.conn())
    }

    pub fn save_window_config(&self, config: &WindowConfig) -> Result<(), CoreError> {
        write_config(&self.conn(), &config.clone().sanitized())
    }

    pub fn window_shortcuts(&self) -> Result<Vec<ShortcutBinding>, CoreError> {
        read_shortcuts(&self.conn())
    }

    pub fn save_window_shortcuts(&self, list: &[ShortcutBinding]) -> Result<(), CoreError> {
        check_shortcuts(list).map_err(CoreError::invalid)?;
        write_shortcuts(&self.conn(), list)
    }

    pub fn custom_sizes(&self) -> Result<Vec<CustomSize>, CoreError> {
        read_sizes(&self.conn())
    }

    pub fn save_custom_size(&self, size: &CustomSize) -> Result<(), CoreError> {
        check_name(&size.id, &size.name, "a custom size")?;
        let clean = size.clone().sanitized();
        let conn = self.conn();
        let mut all = read_sizes(&conn)?;
        match all.iter_mut().find(|s| s.id == clean.id) {
            Some(existing) => *existing = clean,
            None => all.push(clean),
        }
        write_json(&conn, "window_sizes", &all)
    }

    /// Removes a custom size and the shortcuts and rules that pointed at it.
    pub fn delete_custom_size(&self, id: &str) -> Result<(), CoreError> {
        let conn = self.conn();
        let tx = conn.unchecked_transaction()?;
        let mut all = read_sizes(&tx)?;
        all.retain(|s| s.id != id);
        write_json(&tx, "window_sizes", &all)?;
        drop_shortcut(&tx, &format!("{CUSTOM_PREFIX}{}", id.to_lowercase()))?;
        let mut rules = read_rules(&tx)?;
        for rule in rules
            .iter_mut()
            .filter(|r| r.custom_size_id.as_deref() == Some(id))
        {
            rule.custom_size_id = None;
            rule.enabled = rule.enabled && rule.layout.is_some();
        }
        write_rules(&tx, &rules)?;
        tx.commit()?;
        Ok(())
    }

    pub fn saved_layouts(&self, include_auto: bool) -> Result<Vec<SavedLayout>, CoreError> {
        read_layouts(&self.conn(), include_auto)
    }

    pub fn save_layout(&self, layout: &SavedLayout) -> Result<(), CoreError> {
        check_layout(layout)?;
        let mut clean = layout.clone();
        clean.is_auto = false;
        write_layout(&self.conn(), &clean)
    }

    pub fn delete_layout(&self, id: &str) -> Result<(), CoreError> {
        let conn = self.conn();
        let tx = conn.unchecked_transaction()?;
        tx.execute("DELETE FROM window_layouts WHERE id = ?1", params![id])?;
        drop_shortcut(&tx, &format!("{LAYOUT_PREFIX}{}", id.to_lowercase()))?;
        tx.commit()?;
        Ok(())
    }

    /// Keeps the latest arrangement for a set of displays, replacing the one before it. Only the newest few sets are kept.
    pub fn save_auto_layout(
        &self,
        display_key: &str,
        entries: Vec<LayoutEntry>,
        now: i64,
    ) -> Result<(), CoreError> {
        if display_key.is_empty() || entries.is_empty() {
            return Ok(());
        }
        let layout = SavedLayout {
            id: format!("auto:{display_key}"),
            name: "Automatic snapshot".to_string(),
            display_key: display_key.to_string(),
            is_auto: true,
            created_at: now,
            entries: entries.into_iter().take(MAX_LAYOUT_ENTRIES).collect(),
            unplaced: UnplacedPolicy::Leave,
            launch_missing: false,
            is_group: false,
        };
        let conn = self.conn();
        let tx = conn.unchecked_transaction()?;
        write_layout(&tx, &layout)?;
        tx.execute(
            "DELETE FROM window_layouts WHERE is_auto = 1 AND id NOT IN
             (SELECT id FROM window_layouts WHERE is_auto = 1 ORDER BY created_at DESC LIMIT ?1)",
            params![MAX_AUTO_LAYOUTS],
        )?;
        tx.commit()?;
        Ok(())
    }

    pub fn auto_layout_for(&self, display_key: &str) -> Result<Option<SavedLayout>, CoreError> {
        let id = format!("auto:{display_key}");
        Ok(read_layouts(&self.conn(), true)?
            .into_iter()
            .find(|l| l.id == id))
    }

    pub fn window_rules(&self) -> Result<Vec<PlacementRule>, CoreError> {
        read_rules(&self.conn())
    }

    pub fn save_window_rule(&self, rule: &PlacementRule) -> Result<(), CoreError> {
        let conn = self.conn();
        check_rule(&conn, rule)?;
        let mut rules = read_rules(&conn)?;
        // One rule per app: saving another replaces it.
        rules.retain(|r| r.id != rule.id && r.app_id != rule.app_id);
        rules.push(rule.clone());
        write_rules(&conn, &rules)
    }

    pub fn delete_window_rule(&self, id: &str) -> Result<(), CoreError> {
        let conn = self.conn();
        let mut rules = read_rules(&conn)?;
        rules.retain(|r| r.id != id);
        write_rules(&conn, &rules)
    }

    /// Puts the settings and shortcuts back to how they shipped. With `everything`, also removes custom sizes,
    /// saved layouts and rules.
    pub fn restore_default_window_settings(&self, everything: bool) -> Result<(), CoreError> {
        let conn = self.conn();
        let tx = conn.unchecked_transaction()?;
        write_config(&tx, &WindowConfig::default())?;
        write_shortcuts(&tx, &default_shortcuts())?;
        if everything {
            write_json::<Vec<CustomSize>>(&tx, "window_sizes", &Vec::new())?;
            write_rules(&tx, &[])?;
            tx.execute("DELETE FROM window_layouts", [])?;
        }
        tx.commit()?;
        Ok(())
    }
}

// ---- backup ------------------------------------------------------------------------------------------------------------

pub(crate) fn backup_part(conn: &Connection) -> Result<WindowBackup, CoreError> {
    Ok(WindowBackup {
        config: read_config(conn)?,
        shortcuts: read_shortcuts(conn)?,
        sizes: read_sizes(conn)?,
        layouts: read_layouts(conn, false)?,
        rules: read_rules(conn)?,
    })
}

pub(crate) fn validate_backup(file: &BackupFile) -> Result<(), CoreError> {
    let Some(w) = &file.window else { return Ok(()) };
    let bad = |message: &str| CoreError::Backup {
        message: message.to_string(),
    };
    check_shortcuts(&w.shortcuts).map_err(|e| CoreError::Backup { message: e })?;
    let mut ids = HashSet::new();
    for s in &w.sizes {
        if s.id.trim().is_empty() || !ids.insert(s.id.as_str()) {
            return Err(bad("a custom window size in the backup is not valid"));
        }
    }
    let mut layout_ids = HashSet::new();
    for l in &w.layouts {
        check_layout(l).map_err(|e| CoreError::Backup {
            message: e.to_string(),
        })?;
        if !layout_ids.insert(l.id.as_str()) {
            return Err(bad("two saved layouts share an id"));
        }
    }
    let mut apps = HashSet::new();
    for r in &w.rules {
        if r.id.trim().is_empty() || r.app_id.trim().is_empty() || !apps.insert(r.app_id.as_str()) {
            return Err(bad("a placement rule in the backup is not valid"));
        }
        if r.custom_size_id
            .as_ref()
            .is_some_and(|id| !ids.contains(id.as_str()))
        {
            return Err(bad(
                "a placement rule uses a window size that is not in the backup",
            ));
        }
    }
    Ok(())
}

/// Replaces window management data with what a backup holds. A backup from before this existed leaves it alone.
pub(crate) fn restore_backup(tx: &Connection, file: &BackupFile) -> Result<(), CoreError> {
    let Some(w) = &file.window else { return Ok(()) };
    write_config(tx, &w.config.clone().sanitized())?;
    write_shortcuts(tx, &w.shortcuts)?;
    let sizes: Vec<CustomSize> = w.sizes.iter().cloned().map(CustomSize::sanitized).collect();
    write_json(tx, "window_sizes", &sizes)?;
    write_rules(tx, &w.rules)?;
    tx.execute("DELETE FROM window_layouts WHERE is_auto = 0", [])?;
    for l in &w.layouts {
        let mut layout = l.clone();
        layout.is_auto = false;
        write_layout(tx, &layout)?;
    }
    Ok(())
}

// ---- connection-level helpers ------------------------------------------------------------------------------------------

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

fn read_config(conn: &Connection) -> Result<WindowConfig, CoreError> {
    Ok(read_json::<WindowConfig>(conn, "window_config")?
        .unwrap_or_default()
        .sanitized())
}

fn write_config(conn: &Connection, config: &WindowConfig) -> Result<(), CoreError> {
    write_json(conn, "window_config", config)
}

/// Shortcuts the person has not changed are the shipped ones, including ones added in a later version.
fn read_shortcuts(conn: &Connection) -> Result<Vec<ShortcutBinding>, CoreError> {
    let saved = read_json::<Vec<ShortcutBinding>>(conn, "window_shortcuts")?;
    let Some(mut list) = saved.filter(|list| check_shortcuts(list).is_ok()) else {
        return Ok(default_shortcuts());
    };
    // Shortcuts for features added later are offered once per version of the list. A key the person already uses is
    // left alone, and once offered they are not added again if the person removes them.
    let had = read_json::<u32>(conn, "window_shortcut_version")?
        .or_else(|| {
            read_json::<bool>(conn, "window_defaults_v2")
                .ok()
                .flatten()
                .map(|_| 2)
        })
        .unwrap_or(1);
    if had < SHORTCUT_LIST_VERSION {
        // The window switcher moves from ⌃⌥Space to ⌥Tab, unless the person changed it or ⌥Tab is already theirs.
        if had < 4 {
            let tab_taken = list
                .iter()
                .any(|b| b.key_code == 48 && b.modifiers == m::OPTION);
            if !tab_taken {
                if let Some(old) = list.iter_mut().find(|b| {
                    b.command == "window.switcher"
                        && b.key_code == 49
                        && b.modifiers == (m::CONTROL | m::OPTION)
                }) {
                    old.key_code = 48;
                    old.modifiers = m::OPTION;
                }
            }
            // And it now works like ⌘Tab: let go of the keys to go to the chosen window.
            let mut config = read_config(conn)?;
            config.switcher_hold_release = true;
            write_config(conn, &config)?;
        }
        for added in added_default_shortcuts(had) {
            let taken = list.iter().any(|b| {
                b.command == added.command
                    || (b.key_code == added.key_code && b.modifiers == added.modifiers)
            });
            if !taken {
                list.push(added);
            }
        }
        write_shortcuts(conn, &list)?;
        write_json(conn, "window_shortcut_version", &SHORTCUT_LIST_VERSION)?;
    }
    Ok(list)
}

fn write_shortcuts(conn: &Connection, list: &[ShortcutBinding]) -> Result<(), CoreError> {
    write_json(conn, "window_shortcuts", &list)
}

fn drop_shortcut(conn: &Connection, command: &str) -> Result<(), CoreError> {
    let mut list = read_shortcuts(conn)?;
    let before = list.len();
    list.retain(|b| b.command != command);
    if list.len() != before {
        write_shortcuts(conn, &list)?;
    }
    Ok(())
}

fn read_sizes(conn: &Connection) -> Result<Vec<CustomSize>, CoreError> {
    Ok(read_json::<Vec<CustomSize>>(conn, "window_sizes")?.unwrap_or_default())
}

fn read_rules(conn: &Connection) -> Result<Vec<PlacementRule>, CoreError> {
    Ok(read_json::<Vec<PlacementRule>>(conn, "window_rules")?.unwrap_or_default())
}

fn write_rules(conn: &Connection, rules: &[PlacementRule]) -> Result<(), CoreError> {
    write_json(conn, "window_rules", &rules)
}

fn check_name(id: &str, name: &str, what: &str) -> Result<(), CoreError> {
    if id.trim().is_empty() {
        return Err(CoreError::invalid(format!("{what} needs an id")));
    }
    if name.trim().is_empty() || name.chars().count() > MAX_NAME {
        return Err(CoreError::invalid(format!(
            "{what} needs a name of up to {MAX_NAME} characters"
        )));
    }
    Ok(())
}

fn check_layout(layout: &SavedLayout) -> Result<(), CoreError> {
    check_name(&layout.id, &layout.name, "a layout")?;
    if layout.entries.len() > MAX_LAYOUT_ENTRIES {
        return Err(CoreError::invalid("the layout has too many windows"));
    }
    if layout
        .entries
        .iter()
        .any(|e| !e.frame.is_valid() || e.app_id.trim().is_empty())
    {
        return Err(CoreError::invalid(
            "the layout holds a window that cannot be placed",
        ));
    }
    Ok(())
}

fn check_rule(conn: &Connection, rule: &PlacementRule) -> Result<(), CoreError> {
    if rule.id.trim().is_empty() || rule.app_id.trim().is_empty() {
        return Err(CoreError::invalid("a rule needs an app"));
    }
    if rule.layout.is_none() && rule.custom_size_id.is_none() {
        return Err(CoreError::invalid("choose where the window should go"));
    }
    if let Some(id) = &rule.custom_size_id {
        if !read_sizes(conn)?.iter().any(|s| &s.id == id) {
            return Err(CoreError::invalid("that window size no longer exists"));
        }
    }
    Ok(())
}

fn read_layouts(conn: &Connection, include_auto: bool) -> Result<Vec<SavedLayout>, CoreError> {
    let sql = if include_auto {
        "SELECT layout_json FROM window_layouts ORDER BY is_auto, created_at DESC, id"
    } else {
        "SELECT layout_json FROM window_layouts WHERE is_auto = 0 ORDER BY created_at DESC, id"
    };
    let mut stmt = conn.prepare(sql)?;
    let rows = stmt.query_map([], |r| r.get::<_, String>(0))?;
    let mut out = Vec::new();
    for row in rows {
        if let Ok(layout) = serde_json::from_str::<SavedLayout>(&row?) {
            out.push(layout);
        }
    }
    Ok(out)
}

fn write_layout(conn: &Connection, layout: &SavedLayout) -> Result<(), CoreError> {
    conn.execute(
        "INSERT INTO window_layouts (id, display_key, is_auto, created_at, layout_json) VALUES (?1, ?2, ?3, ?4, ?5)
         ON CONFLICT(id) DO UPDATE SET display_key = excluded.display_key, is_auto = excluded.is_auto,
                                       created_at = excluded.created_at, layout_json = excluded.layout_json",
        params![
            layout.id,
            layout.display_key,
            i64::from(layout.is_auto),
            layout.created_at,
            serde_json::to_string(layout)?
        ],
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::actions::modifiers as m;
    use crate::windows::{Rect, WindowLayout};

    fn open() -> Store {
        Store::open_in_memory().unwrap()
    }

    #[test]
    fn the_switcher_gets_a_backwards_and_a_same_app_shortcut_and_a_size() {
        let fresh = open();
        let list = fresh.window_shortcuts().unwrap();
        let find = |c: &str| list.iter().find(|b| b.command == c).cloned().unwrap();
        assert_eq!(
            (
                find("window.switcher_previous").key_code,
                find("window.switcher_previous").modifiers
            ),
            (48, m::OPTION | m::SHIFT)
        );
        assert_eq!(
            (
                find("window.switcher_app").key_code,
                find("window.switcher_app").modifiers
            ),
            (50, m::OPTION)
        );
        let config = fresh.window_config().unwrap();
        assert_eq!(config.switcher_scale, 1.0);
        assert!(config.switcher_follow_pointer);
        let wild = crate::windows::WindowConfig {
            switcher_scale: 9.0,
            ..config.clone()
        }
        .sanitized();
        assert_eq!(wild.switcher_scale, 1.5);
        let tiny = crate::windows::WindowConfig {
            switcher_scale: f64::NAN,
            ..config
        }
        .sanitized();
        assert_eq!(tiny.switcher_scale, 1.0);
        // An older list is offered the two new shortcuts once, and a key already in use is left alone.
        let older = open();
        let mut stored = older.window_shortcuts().unwrap();
        stored.retain(|b| {
            b.command != "window.switcher_previous" && b.command != "window.switcher_app"
        });
        // The person gave ⌥` to another command already.
        for b in stored.iter_mut().filter(|b| b.command == "window.grid") {
            b.key_code = 50;
            b.modifiers = m::OPTION;
        }
        older.save_window_shortcuts(&stored).unwrap();
        older
            .conn()
            .execute(
                "UPDATE settings SET value = '4' WHERE key = 'window_shortcut_version'",
                [],
            )
            .unwrap();
        let after = older.window_shortcuts().unwrap();
        assert!(after
            .iter()
            .any(|b| b.command == "window.switcher_previous"));
        assert!(
            !after.iter().any(|b| b.command == "window.switcher_app"),
            "⌥` was already theirs"
        );
    }

    #[test]
    fn the_switcher_moves_to_option_tab_unless_the_person_changed_it() {
        // Fresh installs get it.
        let fresh = open();
        let switcher = |s: &Store| {
            s.window_shortcuts()
                .unwrap()
                .into_iter()
                .find(|b| b.command == "window.switcher")
                .unwrap()
        };
        assert_eq!(
            (switcher(&fresh).key_code, switcher(&fresh).modifiers),
            (48, m::OPTION)
        );
        assert!(fresh.window_config().unwrap().switcher_hold_release);

        // An older list that still has the old default is moved once.
        let old = open();
        let mut list = old.window_shortcuts().unwrap();
        for b in list.iter_mut().filter(|b| b.command == "window.switcher") {
            b.key_code = 49;
            b.modifiers = m::CONTROL | m::OPTION;
        }
        old.save_window_shortcuts(&list).unwrap();
        old.conn()
            .execute(
                "UPDATE settings SET value = '3' WHERE key = 'window_shortcut_version'",
                [],
            )
            .unwrap();
        assert_eq!(
            (switcher(&old).key_code, switcher(&old).modifiers),
            (48, m::OPTION)
        );

        // A key the person chose themselves stays.
        let custom = open();
        let mut list = custom.window_shortcuts().unwrap();
        for b in list.iter_mut().filter(|b| b.command == "window.switcher") {
            b.key_code = 14;
            b.modifiers = m::COMMAND;
        }
        custom.save_window_shortcuts(&list).unwrap();
        custom
            .conn()
            .execute(
                "UPDATE settings SET value = '3' WHERE key = 'window_shortcut_version'",
                [],
            )
            .unwrap();
        assert_eq!(
            (switcher(&custom).key_code, switcher(&custom).modifiers),
            (14, m::COMMAND)
        );
    }

    fn entry(app: &str) -> LayoutEntry {
        LayoutEntry {
            app_id: app.into(),
            title: "t".into(),
            display_id: "d".into(),
            frame: Rect::new(0.0, 0.0, 0.5, 1.0),
        }
    }

    fn layout(id: &str, name: &str) -> SavedLayout {
        SavedLayout {
            id: id.into(),
            name: name.into(),
            display_key: "d".into(),
            is_auto: false,
            created_at: 1,
            entries: vec![entry("a")],
            unplaced: UnplacedPolicy::Leave,
            launch_missing: false,
            is_group: false,
        }
    }

    fn size(id: &str) -> CustomSize {
        CustomSize {
            id: id.into(),
            name: "Reading".into(),
            width: 0.5,
            height: 0.9,
            as_fraction: true,
            centered: true,
            x: 0.5,
            y: 0.5,
        }
    }

    fn rule(id: &str, app: &str) -> PlacementRule {
        PlacementRule {
            id: id.into(),
            app_id: app.into(),
            enabled: true,
            layout: Some(WindowLayout::LeftHalf),
            custom_size_id: None,
            display_id: None,
        }
    }

    #[test]
    fn config_and_shortcuts_default_then_persist() {
        let store = open();
        assert_eq!(store.window_config().unwrap(), WindowConfig::default());
        assert_eq!(store.window_shortcuts().unwrap(), default_shortcuts());
        store
            .save_window_config(&WindowConfig {
                gap: 8.0,
                ..WindowConfig::default()
            })
            .unwrap();
        assert_eq!(store.window_config().unwrap().gap, 8.0);
        let mut list = default_shortcuts();
        list[0].key_code = 99;
        store.save_window_shortcuts(&list).unwrap();
        assert_eq!(store.window_shortcuts().unwrap()[0].key_code, 99);
        let dup = vec![
            list[0].clone(),
            ShortcutBinding {
                command: "window.center".into(),
                ..list[0].clone()
            },
        ];
        assert!(store.save_window_shortcuts(&dup).is_err());
    }

    #[test]
    fn shortcuts_added_in_a_later_version_reach_existing_users_once() {
        let store = open();
        // An older install: the saved list has only the original shortcuts.
        let old: Vec<ShortcutBinding> = default_shortcuts()
            .into_iter()
            .filter(|b| {
                !added_default_shortcuts(1)
                    .iter()
                    .any(|a| a.command == b.command)
            })
            .collect();
        store.save_window_shortcuts(&old).unwrap();
        let first = store.window_shortcuts().unwrap();
        for added in added_default_shortcuts(1) {
            assert!(
                first.iter().any(|b| b.command == added.command),
                "{} is offered",
                added.command
            );
        }
        // Removing one is respected: it does not come back.
        let mut trimmed = first.clone();
        trimmed.retain(|b| b.command != "window.radial");
        store.save_window_shortcuts(&trimmed).unwrap();
        assert!(!store
            .window_shortcuts()
            .unwrap()
            .iter()
            .any(|b| b.command == "window.radial"));
    }

    #[test]
    fn a_key_the_person_already_uses_is_not_taken_by_a_new_shortcut() {
        let store = open();
        let radial = added_default_shortcuts(1)
            .into_iter()
            .find(|b| b.command == "window.radial")
            .unwrap();
        let mut old: Vec<ShortcutBinding> = default_shortcuts()
            .into_iter()
            .filter(|b| {
                !added_default_shortcuts(1)
                    .iter()
                    .any(|a| a.command == b.command)
            })
            .collect();
        old.retain(|b| b.command != "window.left_half");
        old.push(ShortcutBinding {
            command: "window.left_half".into(),
            key_code: radial.key_code,
            modifiers: radial.modifiers,
        });
        store.save_window_shortcuts(&old).unwrap();
        let list = store.window_shortcuts().unwrap();
        assert!(
            !list.iter().any(|b| b.command == "window.radial"),
            "their key stays theirs"
        );
        assert!(
            list.iter().any(|b| b.command == "window.stash"),
            "the others are still offered"
        );
    }

    #[test]
    fn custom_sizes_are_clamped_and_deleting_cleans_up_after_them() {
        let store = open();
        store
            .save_custom_size(&CustomSize {
                width: 9.0,
                ..size("s1")
            })
            .unwrap();
        assert_eq!(store.custom_sizes().unwrap()[0].width, 1.0);
        let mut shortcuts = store.window_shortcuts().unwrap();
        shortcuts.push(ShortcutBinding {
            command: "window.size.s1".into(),
            key_code: 12,
            modifiers: m::OPTION,
        });
        store.save_window_shortcuts(&shortcuts).unwrap();
        store
            .save_window_rule(&PlacementRule {
                layout: None,
                custom_size_id: Some("s1".into()),
                ..rule("r", "app")
            })
            .unwrap();
        store.delete_custom_size("s1").unwrap();
        assert!(store.custom_sizes().unwrap().is_empty());
        assert!(!store
            .window_shortcuts()
            .unwrap()
            .iter()
            .any(|b| b.command == "window.size.s1"));
        assert!(
            !store.window_rules().unwrap()[0].enabled,
            "a rule with nowhere to go is switched off"
        );
    }

    #[test]
    fn layouts_save_list_and_delete_with_their_shortcut() {
        let store = open();
        assert!(store.save_layout(&layout("", "x")).is_err());
        assert!(store.save_layout(&layout("L1", "  ")).is_err());
        store.save_layout(&layout("L1", "Writing")).unwrap();
        let mut shortcuts = store.window_shortcuts().unwrap();
        shortcuts.push(ShortcutBinding {
            command: "window.layout.l1".into(),
            key_code: 13,
            modifiers: m::OPTION,
        });
        store.save_window_shortcuts(&shortcuts).unwrap();
        assert_eq!(store.saved_layouts(false).unwrap().len(), 1);
        store.delete_layout("L1").unwrap();
        assert!(store.saved_layouts(false).unwrap().is_empty());
        assert!(!store
            .window_shortcuts()
            .unwrap()
            .iter()
            .any(|b| b.command == "window.layout.l1"));
    }

    #[test]
    fn a_layouts_policy_for_other_windows_is_kept_and_an_old_layout_reads_as_leave() {
        let store = open();
        store
            .save_layout(&SavedLayout {
                unplaced: UnplacedPolicy::Minimize,
                launch_missing: true,
                ..layout("L", "Focus")
            })
            .unwrap();
        let saved = store.saved_layouts(false).unwrap();
        assert_eq!(saved[0].unplaced, UnplacedPolicy::Minimize);
        assert!(saved[0].launch_missing);
        // A layout written before these existed has neither field.
        let old = r#"{"id":"O","name":"Old","display_key":"d","is_auto":false,"created_at":1,"entries":[]}"#;
        let read: SavedLayout = serde_json::from_str(old).unwrap();
        assert_eq!(read.unplaced, UnplacedPolicy::Leave);
        assert!(!read.launch_missing);
    }

    #[test]
    fn a_group_is_kept_apart_from_layouts_and_an_old_layout_is_not_one() {
        let store = open();
        store
            .save_layout(&SavedLayout {
                is_group: true,
                launch_missing: true,
                ..layout("G", "Development")
            })
            .unwrap();
        store.save_layout(&layout("L", "Plain")).unwrap();
        let saved = store.saved_layouts(false).unwrap();
        assert_eq!(saved.iter().filter(|l| l.is_group).count(), 1);
        assert!(saved.iter().find(|l| l.id == "G").unwrap().is_group);
        assert!(!saved.iter().find(|l| l.id == "L").unwrap().is_group);
        let old = r#"{"id":"O","name":"Old","display_key":"d","is_auto":false,"created_at":1,"entries":[]}"#;
        assert!(!serde_json::from_str::<SavedLayout>(old).unwrap().is_group);
        // A group has a shortcut command like a layout does.
        assert_eq!(
            saved.iter().find(|l| l.id == "G").unwrap().command(),
            "window.layout.g"
        );
    }

    #[test]
    fn a_saved_layout_cannot_claim_to_be_automatic() {
        let store = open();
        store
            .save_layout(&SavedLayout {
                is_auto: true,
                ..layout("L", "Mine")
            })
            .unwrap();
        assert_eq!(store.saved_layouts(false).unwrap().len(), 1);
    }

    #[test]
    fn automatic_snapshots_replace_the_one_for_the_same_displays_and_stay_few() {
        let store = open();
        store
            .save_auto_layout("a|b", vec![entry("one")], 10)
            .unwrap();
        store
            .save_auto_layout("a|b", vec![entry("two")], 20)
            .unwrap();
        assert_eq!(
            store.auto_layout_for("a|b").unwrap().unwrap().entries[0].app_id,
            "two"
        );
        assert!(
            store.saved_layouts(false).unwrap().is_empty(),
            "automatic ones are not in the person's list"
        );
        for i in 0..30 {
            store
                .save_auto_layout(&format!("set{i}"), vec![entry("x")], 100 + i)
                .unwrap();
        }
        assert_eq!(
            store.saved_layouts(true).unwrap().len() as i64,
            MAX_AUTO_LAYOUTS
        );
        store.save_auto_layout("", vec![entry("x")], 1).unwrap();
        store.save_auto_layout("k", vec![], 1).unwrap();
        assert!(store.auto_layout_for("k").unwrap().is_none());
    }

    #[test]
    fn rules_are_one_per_app_and_need_somewhere_to_go() {
        let store = open();
        store.save_window_rule(&rule("1", "app")).unwrap();
        store
            .save_window_rule(&PlacementRule {
                layout: Some(WindowLayout::Maximize),
                ..rule("2", "app")
            })
            .unwrap();
        let rules = store.window_rules().unwrap();
        assert_eq!(rules.len(), 1);
        assert_eq!(rules[0].layout, Some(WindowLayout::Maximize));
        assert!(store
            .save_window_rule(&PlacementRule {
                layout: None,
                ..rule("3", "other")
            })
            .is_err());
        assert!(store
            .save_window_rule(&PlacementRule {
                layout: None,
                custom_size_id: Some("nope".into()),
                ..rule("3", "other")
            })
            .is_err());
        store.delete_window_rule("2").unwrap();
        assert!(store.window_rules().unwrap().is_empty());
    }

    #[test]
    fn restoring_defaults_can_keep_or_clear_the_persons_data() {
        let store = open();
        store
            .save_window_config(&WindowConfig {
                gap: 20.0,
                ..WindowConfig::default()
            })
            .unwrap();
        store.save_layout(&layout("L", "Keep")).unwrap();
        store.restore_default_window_settings(false).unwrap();
        assert_eq!(store.window_config().unwrap().gap, 0.0);
        assert_eq!(store.saved_layouts(false).unwrap().len(), 1);
        store.restore_default_window_settings(true).unwrap();
        assert!(store.saved_layouts(false).unwrap().is_empty());
    }

    #[test]
    fn window_data_survives_a_backup_round_trip() {
        let source = open();
        source
            .save_window_config(&WindowConfig {
                gap: 12.0,
                ..WindowConfig::default()
            })
            .unwrap();
        source.save_custom_size(&size("s")).unwrap();
        source.save_layout(&layout("L", "Writing")).unwrap();
        source.save_window_rule(&rule("r", "app")).unwrap();
        source.save_auto_layout("a", vec![entry("x")], 5).unwrap();
        let json = source.export_backup("0.3.0", 9).unwrap();

        let target = open();
        target.save_layout(&layout("old", "Old")).unwrap();
        let summary = target.import_backup(&json).unwrap();
        assert_eq!(summary.window_layouts, 1);
        assert_eq!(target.window_config().unwrap().gap, 12.0);
        assert_eq!(target.custom_sizes().unwrap().len(), 1);
        assert_eq!(target.window_rules().unwrap().len(), 1);
        let names: Vec<String> = target
            .saved_layouts(false)
            .unwrap()
            .into_iter()
            .map(|l| l.name)
            .collect();
        assert_eq!(names, vec!["Writing".to_string()]);
    }

    #[test]
    fn an_older_backup_leaves_window_data_alone() {
        let store = open();
        store
            .save_window_config(&WindowConfig {
                gap: 7.0,
                ..WindowConfig::default()
            })
            .unwrap();
        let json = open().export_backup("0.2.0", 1).unwrap();
        let mut value: serde_json::Value = serde_json::from_str(&json).unwrap();
        value.as_object_mut().unwrap().remove("window");
        store.import_backup(&value.to_string()).unwrap();
        assert_eq!(store.window_config().unwrap().gap, 7.0);
    }

    #[test]
    fn a_bad_window_section_changes_nothing() {
        let store = open();
        store
            .save_window_config(&WindowConfig {
                gap: 3.0,
                ..WindowConfig::default()
            })
            .unwrap();
        let json = open().export_backup("0.3.0", 1).unwrap();
        let mut value: serde_json::Value = serde_json::from_str(&json).unwrap();
        value["window"]["shortcuts"][1] = value["window"]["shortcuts"][0].clone();
        assert!(store.import_backup(&value.to_string()).is_err());
        assert_eq!(store.window_config().unwrap().gap, 3.0);
    }
}
