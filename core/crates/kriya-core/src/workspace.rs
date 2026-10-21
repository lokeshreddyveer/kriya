//! Workspaces and app control: named sets of apps that launch together, focus mode, which apps "quit all" leaves alone
//! and favourite windows. The decisions about which apps to hide or quit are plain functions over bundle ids; the app
//! does the hiding, quitting and launching.

use std::collections::HashSet;

use rusqlite::{params, OptionalExtension};
use serde::{Deserialize, Serialize};

use crate::error::CoreError;
use crate::store::Store;

pub const MAX_WORKSPACES: usize = 30;
pub const MAX_FAVORITE_SLOTS: u32 = 9;
const SETTINGS_KEY: &str = "workspaces";

/// Apps that "hide" and "quit" never touch, whatever the lists say.
const ALWAYS_KEEP: [&str; 3] = [
    "com.apple.finder",
    "com.apple.dock",
    "com.apple.loginwindow",
];

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct Workspace {
    pub id: String,
    pub name: String,
    /// The apps to open, by bundle id.
    pub app_ids: Vec<String>,
    /// A saved window layout to put the windows in once the apps are up.
    pub layout_id: Option<String>,
    /// Hide every app that is not in the workspace.
    pub hide_others: bool,
    /// Web addresses to open.
    pub urls: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct FavoriteWindow {
    /// 1 to 9: the number in the shortcut that brings the window back.
    pub slot: u32,
    pub app_id: String,
    pub title: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
#[serde(default)]
pub struct WorkspaceConfig {
    pub workspaces: Vec<Workspace>,
    /// The apps focus mode leaves visible.
    pub focus_app_ids: Vec<String>,
    /// Apps "quit all" leaves running.
    pub quit_keep_app_ids: Vec<String>,
    pub favorites: Vec<FavoriteWindow>,
    pub confirm_quit_all: bool,
}

impl Default for WorkspaceConfig {
    fn default() -> Self {
        WorkspaceConfig {
            workspaces: Vec::new(),
            focus_app_ids: Vec::new(),
            quit_keep_app_ids: Vec::new(),
            favorites: Vec::new(),
            confirm_quit_all: true,
        }
    }
}

fn clean_ids(list: &[String], limit: usize) -> Vec<String> {
    let mut seen = HashSet::new();
    list.iter()
        .map(|a| a.trim().to_string())
        .filter(|a| !a.is_empty() && seen.insert(a.clone()))
        .take(limit)
        .collect()
}

impl WorkspaceConfig {
    /// Drops what cannot work and tidies the rest.
    pub fn sanitized(mut self) -> Self {
        let mut seen = HashSet::new();
        let mut kept = Vec::new();
        for mut ws in self.workspaces {
            ws.id = ws.id.trim().to_string();
            ws.name = ws.name.trim().to_string();
            ws.app_ids = clean_ids(&ws.app_ids, 30);
            ws.layout_id = ws
                .layout_id
                .map(|l| l.trim().to_string())
                .filter(|l| !l.is_empty());
            ws.urls = ws
                .urls
                .iter()
                .map(|u| u.trim().to_string())
                .filter(|u| {
                    u.len() <= 500
                        && url::Url::parse(u).is_ok_and(|p| matches!(p.scheme(), "http" | "https"))
                })
                .take(10)
                .collect();
            let valid = !ws.id.is_empty()
                && !ws.name.is_empty()
                && ws.name.chars().count() <= 60
                && (!ws.app_ids.is_empty() || !ws.urls.is_empty());
            if valid && seen.insert(ws.id.clone()) {
                kept.push(ws);
            }
        }
        kept.truncate(MAX_WORKSPACES);
        self.workspaces = kept;
        self.focus_app_ids = clean_ids(&self.focus_app_ids, 50);
        self.quit_keep_app_ids = clean_ids(&self.quit_keep_app_ids, 50);
        // One window per slot, the last one set wins.
        let mut favorites: Vec<FavoriteWindow> = Vec::new();
        for mut fav in self.favorites {
            fav.app_id = fav.app_id.trim().to_string();
            fav.title = fav.title.trim().chars().take(200).collect();
            if (1..=MAX_FAVORITE_SLOTS).contains(&fav.slot) && !fav.app_id.is_empty() {
                favorites.retain(|f| f.slot != fav.slot);
                favorites.push(fav);
            }
        }
        favorites.sort_by_key(|f| f.slot);
        self.favorites = favorites;
        self
    }
}

pub fn workspace_command(id: &str) -> String {
    format!("workspace.{}", id.to_lowercase())
}

/// The apps to hide: every running one that is not in `keep`, not the app itself, and not one that is never touched.
pub fn apps_to_hide(running: &[String], keep: &[String], self_id: &str) -> Vec<String> {
    running
        .iter()
        .filter(|id| {
            id.as_str() != self_id
                && !ALWAYS_KEEP.contains(&id.as_str())
                && !keep.iter().any(|k| k == *id)
        })
        .cloned()
        .collect()
}

/// The apps "quit all" would close: the same rule as hiding, with the person's keep list.
pub fn quit_candidates(running: &[String], keep: &[String], self_id: &str) -> Vec<String> {
    apps_to_hide(running, keep, self_id)
}

impl Store {
    pub fn workspace_config(&self) -> Result<WorkspaceConfig, CoreError> {
        let conn = self.conn();
        let json: Option<String> = conn
            .query_row(
                "SELECT value FROM settings WHERE key = ?1",
                params![SETTINGS_KEY],
                |r| r.get(0),
            )
            .optional()?;
        Ok(json
            .and_then(|j| serde_json::from_str::<WorkspaceConfig>(&j).ok())
            .unwrap_or_default()
            .sanitized())
    }

    pub fn save_workspace_config(&self, config: &WorkspaceConfig) -> Result<(), CoreError> {
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

    fn ws(id: &str, apps: &[&str]) -> Workspace {
        Workspace {
            id: id.into(),
            name: format!("Work {id}"),
            app_ids: apps.iter().map(|a| (*a).to_string()).collect(),
            layout_id: None,
            hide_others: false,
            urls: vec![],
        }
    }

    fn strings(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| (*s).to_string()).collect()
    }

    #[test]
    fn workspaces_that_cannot_work_are_dropped_and_the_rest_tidied() {
        let mut messy = ws("a", &[" com.x ", "com.x", ""]);
        messy.layout_id = Some("  ".into());
        messy.urls = strings(&[
            "https://ok.example/a",
            "javascript:alert(1)",
            "not a url",
            " http://also.ok ",
        ]);
        let config = WorkspaceConfig {
            workspaces: vec![
                messy,
                ws("a", &["com.dup"]),
                ws("empty", &[]),
                Workspace {
                    name: "  ".into(),
                    ..ws("nameless", &["com.y"])
                },
                Workspace {
                    urls: strings(&["https://only-a-link.example"]),
                    ..ws("links", &[])
                },
            ],
            ..WorkspaceConfig::default()
        }
        .sanitized();
        let ids: Vec<&str> = config.workspaces.iter().map(|w| w.id.as_str()).collect();
        assert_eq!(ids, vec!["a", "links"]);
        assert_eq!(config.workspaces[0].app_ids, strings(&["com.x"]));
        assert_eq!(config.workspaces[0].layout_id, None);
        assert_eq!(
            config.workspaces[0].urls,
            strings(&["https://ok.example/a", "http://also.ok"])
        );
    }

    #[test]
    fn favorites_keep_one_window_per_slot_in_range() {
        let fav = |slot, app: &str, title: &str| FavoriteWindow {
            slot,
            app_id: app.into(),
            title: title.into(),
        };
        let config = WorkspaceConfig {
            favorites: vec![
                fav(2, "com.a", "First"),
                fav(1, "com.b", " Notes "),
                fav(2, "com.c", "Replaces"),
                fav(0, "com.d", "x"),
                fav(10, "com.e", "x"),
                fav(3, " ", "x"),
            ],
            ..WorkspaceConfig::default()
        }
        .sanitized();
        let summary: Vec<(u32, &str, &str)> = config
            .favorites
            .iter()
            .map(|f| (f.slot, f.app_id.as_str(), f.title.as_str()))
            .collect();
        assert_eq!(
            summary,
            vec![(1, "com.b", "Notes"), (2, "com.c", "Replaces")]
        );
    }

    #[test]
    fn hiding_and_quitting_spare_the_finder_this_app_and_the_keep_list() {
        let running = strings(&[
            "com.apple.finder",
            "com.me.kriya",
            "com.apple.Safari",
            "com.apple.Notes",
            "com.apple.dock",
            "com.x.Editor",
        ]);
        let keep = strings(&["com.apple.Notes"]);
        assert_eq!(
            apps_to_hide(&running, &keep, "com.me.kriya"),
            strings(&["com.apple.Safari", "com.x.Editor"])
        );
        assert_eq!(
            quit_candidates(&running, &[], "com.me.kriya"),
            strings(&["com.apple.Safari", "com.apple.Notes", "com.x.Editor"])
        );
        assert!(apps_to_hide(&[], &keep, "x").is_empty());
    }

    #[test]
    fn commands_and_limits() {
        assert_eq!(workspace_command("AbC-1"), "workspace.abc-1");
        let many = (0..40).map(|i| ws(&format!("w{i}"), &["com.x"])).collect();
        assert_eq!(
            WorkspaceConfig {
                workspaces: many,
                ..WorkspaceConfig::default()
            }
            .sanitized()
            .workspaces
            .len(),
            MAX_WORKSPACES
        );
        assert!(
            WorkspaceConfig::default().confirm_quit_all,
            "quit all asks first"
        );
    }

    #[test]
    fn the_configuration_is_stored() {
        let store = Store::open_in_memory().unwrap();
        assert!(store.workspace_config().unwrap().workspaces.is_empty());
        let config = WorkspaceConfig {
            workspaces: vec![ws("a", &["com.x"])],
            focus_app_ids: strings(&["com.x"]),
            ..WorkspaceConfig::default()
        };
        store.save_workspace_config(&config).unwrap();
        let back = store.workspace_config().unwrap();
        assert_eq!(back.workspaces.len(), 1);
        assert_eq!(back.focus_app_ids, strings(&["com.x"]));
    }
}
