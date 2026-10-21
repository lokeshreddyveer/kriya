//! The pointer menu: a menu that opens at the pointer, from a shortcut, a mouse button or a gesture. It lists the
//! frontmost app's own menu bar (built by the app from the Accessibility API) and the person's own items, which can be
//! limited to chosen apps.

use std::collections::HashSet;

use rusqlite::{params, OptionalExtension};
use serde::{Deserialize, Serialize};

use crate::error::CoreError;
use crate::store::Store;

pub const MAX_ITEMS: usize = 60;
const SETTINGS_KEY: &str = "pointer_menu";

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct PointerMenuItem {
    pub id: String,
    pub title: String,
    /// A saved action to run. Either this or `workflow_id` is set.
    pub action_id: Option<String>,
    pub workflow_id: Option<String>,
    /// The apps this item shows for, by bundle id. Empty means every app.
    pub app_ids: Vec<String>,
    pub enabled: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
#[serde(default)]
pub struct PointerMenuConfig {
    pub items: Vec<PointerMenuItem>,
    /// Add the frontmost app's own menu bar to the menu.
    pub show_app_menu: bool,
    /// Holding ⌥ and right-clicking opens the menu instead of the app's own right-click menu.
    pub option_right_click: bool,
}

impl Default for PointerMenuConfig {
    fn default() -> Self {
        PointerMenuConfig {
            items: Vec::new(),
            show_app_menu: true,
            option_right_click: false,
        }
    }
}

impl PointerMenuConfig {
    /// Drops items that cannot work (no title, nothing to run, repeated ids) and tidies the rest.
    pub fn sanitized(mut self) -> Self {
        let mut seen = HashSet::new();
        let mut kept = Vec::new();
        for mut item in self.items {
            item.id = item.id.trim().to_string();
            item.title = item.title.trim().to_string();
            item.action_id = item
                .action_id
                .map(|a| a.trim().to_string())
                .filter(|a| !a.is_empty());
            item.workflow_id = item
                .workflow_id
                .map(|w| w.trim().to_string())
                .filter(|w| !w.is_empty());
            let mut apps = HashSet::new();
            item.app_ids = item
                .app_ids
                .iter()
                .map(|a| a.trim().to_string())
                .filter(|a| !a.is_empty() && apps.insert(a.clone()))
                .collect();
            let valid = !item.id.is_empty()
                && !item.title.is_empty()
                && item.title.chars().count() <= 60
                && (item.action_id.is_some() || item.workflow_id.is_some());
            if valid && seen.insert(item.id.clone()) {
                kept.push(item);
            }
        }
        kept.truncate(MAX_ITEMS);
        self.items = kept;
        self
    }
}

/// The items to show while `app_id` is in front: enabled ones for every app, and enabled ones limited to this app.
pub fn items_for_app(items: &[PointerMenuItem], app_id: Option<&str>) -> Vec<PointerMenuItem> {
    items
        .iter()
        .filter(|i| i.enabled)
        .filter(|i| {
            i.app_ids.is_empty() || app_id.is_some_and(|a| i.app_ids.iter().any(|x| x == a))
        })
        .cloned()
        .collect()
}

impl Store {
    pub fn pointer_menu_config(&self) -> Result<PointerMenuConfig, CoreError> {
        let conn = self.conn();
        let json: Option<String> = conn
            .query_row(
                "SELECT value FROM settings WHERE key = ?1",
                params![SETTINGS_KEY],
                |r| r.get(0),
            )
            .optional()?;
        Ok(json
            .and_then(|j| serde_json::from_str::<PointerMenuConfig>(&j).ok())
            .unwrap_or_default()
            .sanitized())
    }

    pub fn save_pointer_menu_config(&self, config: &PointerMenuConfig) -> Result<(), CoreError> {
        let clean = config.clone().sanitized();
        self.conn().execute(
            "INSERT INTO settings (key, value) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![SETTINGS_KEY, serde_json::to_string(&clean)?],
        )?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(id: &str, title: &str, apps: &[&str]) -> PointerMenuItem {
        PointerMenuItem {
            id: id.into(),
            title: title.into(),
            action_id: Some("act".into()),
            workflow_id: None,
            app_ids: apps.iter().map(|a| (*a).to_string()).collect(),
            enabled: true,
        }
    }

    #[test]
    fn items_that_cannot_work_are_dropped_and_the_rest_tidied() {
        let config = PointerMenuConfig {
            items: vec![
                item("a", "  First  ", &[" com.x ", "com.x", ""]),
                item("a", "Repeated id", &[]),
                item("b", "   ", &[]),
                PointerMenuItem {
                    action_id: None,
                    workflow_id: None,
                    ..item("c", "Nothing to run", &[])
                },
                PointerMenuItem {
                    action_id: None,
                    workflow_id: Some(" w1 ".into()),
                    ..item("d", "Workflow", &[])
                },
                item("e", &"x".repeat(61), &[]),
            ],
            show_app_menu: true,
            option_right_click: false,
        }
        .sanitized();
        let ids: Vec<&str> = config.items.iter().map(|i| i.id.as_str()).collect();
        assert_eq!(ids, vec!["a", "d"]);
        assert_eq!(config.items[0].title, "First");
        assert_eq!(config.items[0].app_ids, vec!["com.x".to_string()]);
        assert_eq!(config.items[1].workflow_id.as_deref(), Some("w1"));
    }

    #[test]
    fn the_list_is_capped() {
        let items = (0..80).map(|i| item(&format!("i{i}"), "T", &[])).collect();
        assert_eq!(
            PointerMenuConfig {
                items,
                show_app_menu: true,
                option_right_click: false
            }
            .sanitized()
            .items
            .len(),
            MAX_ITEMS
        );
    }

    #[test]
    fn items_show_for_every_app_or_only_the_chosen_ones() {
        let mut off = item("off", "Off", &[]);
        off.enabled = false;
        let items = vec![
            item("all", "Everywhere", &[]),
            item("safari", "Safari only", &["com.apple.Safari"]),
            off,
        ];
        let ids = |app: Option<&str>| {
            items_for_app(&items, app)
                .into_iter()
                .map(|i| i.id)
                .collect::<Vec<_>>()
        };
        assert_eq!(ids(Some("com.apple.Safari")), vec!["all", "safari"]);
        assert_eq!(ids(Some("com.apple.Notes")), vec!["all"]);
        assert_eq!(ids(None), vec!["all"]);
    }

    #[test]
    fn the_menu_is_stored_and_a_fresh_store_has_the_app_menu_on() {
        let store = Store::open_in_memory().unwrap();
        let fresh = store.pointer_menu_config().unwrap();
        assert!(fresh.show_app_menu && fresh.items.is_empty());
        store
            .save_pointer_menu_config(&PointerMenuConfig {
                items: vec![item("a", "One", &[])],
                show_app_menu: false,
                option_right_click: true,
            })
            .unwrap();
        let back = store.pointer_menu_config().unwrap();
        assert!(!back.show_app_menu);
        assert_eq!(back.items.len(), 1);
    }
}
