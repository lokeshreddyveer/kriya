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
    /// A Sound mode (by its id) to turn on when the workspace opens. The sound is put back by the person's own
    /// "put the sound back". Added later, so a workspace saved before then has none.
    #[serde(default)]
    #[uniffi(default = None)]
    pub sound_mode_id: Option<String>,
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

const PACKAGE_FORMAT: &str = "kriya-workspaces";

#[derive(Serialize, Deserialize)]
struct PackageEntry {
    workspace: Workspace,
    /// The saved window layout the workspace uses, with the displays it was made for.
    layout: Option<crate::windows::SavedLayout>,
}

#[derive(Serialize, Deserialize)]
struct Package {
    format: String,
    version: u32,
    workspaces: Vec<PackageEntry>,
}

/// What an import did.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WorkspaceImportReport {
    pub added: Vec<Workspace>,
    pub layouts_added: u32,
    /// "name: why" for each one left out.
    pub skipped: Vec<String>,
}

impl Store {
    /// The chosen workspaces (all when `ids` is empty) with their layouts, as a file to share.
    pub fn export_workspaces(&self, ids: &[String]) -> Result<String, CoreError> {
        let config = self.workspace_config()?;
        let layouts = self.saved_layouts(false)?;
        let entries: Vec<PackageEntry> = config
            .workspaces
            .into_iter()
            .filter(|w| ids.is_empty() || ids.contains(&w.id))
            .map(|w| PackageEntry {
                layout: w
                    .layout_id
                    .as_ref()
                    .and_then(|id| layouts.iter().find(|l| &l.id == id).cloned()),
                workspace: w,
            })
            .collect();
        Ok(serde_json::to_string_pretty(&Package {
            format: PACKAGE_FORMAT.to_string(),
            version: 1,
            workspaces: entries,
        })?)
    }

    /// Adds the workspaces in a file under new ids, with their layouts. Anything invalid is left out with the reason.
    pub fn import_workspaces(
        &self,
        json: &str,
        now: i64,
    ) -> Result<WorkspaceImportReport, CoreError> {
        if json.len() > 2_000_000 {
            return Err(CoreError::invalid("that file is too large"));
        }
        let package: Package = serde_json::from_str(json)
            .map_err(|_| CoreError::invalid("that is not a Kriya workspace file"))?;
        if package.format != PACKAGE_FORMAT || package.version != 1 {
            return Err(CoreError::invalid("that is not a Kriya workspace file"));
        }
        let mut config = self.workspace_config()?;
        let mut report = WorkspaceImportReport {
            added: Vec::new(),
            layouts_added: 0,
            skipped: Vec::new(),
        };
        for (index, entry) in package.workspaces.into_iter().enumerate() {
            let label = if entry.workspace.name.trim().is_empty() {
                format!("workspace {}", index + 1)
            } else {
                entry.workspace.name.clone()
            };
            if config.workspaces.len() >= MAX_WORKSPACES {
                report
                    .skipped
                    .push(format!("{label}: there are too many workspaces"));
                continue;
            }
            let mut ws = entry.workspace;
            ws.id = format!("imported-{now}-{index}");
            ws.layout_id = None;
            if let Some(mut layout) = entry.layout {
                layout.id = format!("imported-layout-{now}-{index}");
                layout.is_auto = false;
                layout.created_at = now;
                if self.save_layout(&layout).is_ok() {
                    ws.layout_id = Some(layout.id.clone());
                    report.layouts_added += 1;
                }
            }
            let before = config.workspaces.len();
            config.workspaces.push(ws.clone());
            let cleaned = config.clone().sanitized();
            if cleaned.workspaces.len() == before {
                config.workspaces.pop();
                report.skipped.push(format!(
                    "{label}: it has no apps or addresses, or a name that is empty or too long"
                ));
                continue;
            }
            report.added.push(ws);
        }
        self.save_workspace_config(&config)?;
        Ok(report)
    }

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
            sound_mode_id: None,
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

    #[test]
    fn workspaces_round_trip_through_a_file_with_their_layouts_and_new_ids() {
        let store = Store::open_in_memory().unwrap();
        let layout = crate::windows::SavedLayout {
            id: "lay".into(),
            name: "Work".into(),
            display_key: "d".into(),
            is_auto: false,
            created_at: 1,
            entries: vec![],
            unplaced: Default::default(),
            launch_missing: false,
            is_group: false,
        };
        store.save_layout(&layout).unwrap();
        let mut w = ws("a", &["com.x"]);
        w.layout_id = Some("lay".into());
        w.sound_mode_id = Some("meeting".into());
        store
            .save_workspace_config(&WorkspaceConfig {
                workspaces: vec![w],
                ..WorkspaceConfig::default()
            })
            .unwrap();
        let json = store.export_workspaces(&[]).unwrap();
        let report = store.import_workspaces(&json, 9).unwrap();
        assert_eq!(report.added.len(), 1);
        assert_eq!(report.layouts_added, 1);
        assert_eq!(report.added[0].id, "imported-9-0");
        assert_eq!(
            report.added[0].layout_id.as_deref(),
            Some("imported-layout-9-0")
        );
        assert_eq!(report.added[0].sound_mode_id.as_deref(), Some("meeting"));
        assert_eq!(store.workspace_config().unwrap().workspaces.len(), 2);
        assert_eq!(store.saved_layouts(false).unwrap().len(), 2);
    }

    #[test]
    fn bad_files_are_refused_and_invalid_workspaces_are_skipped_with_a_reason() {
        let store = Store::open_in_memory().unwrap();
        assert!(store.import_workspaces("{}", 1).is_err());
        assert!(store
            .import_workspaces(r#"{"format":"x","version":1,"workspaces":[]}"#, 1)
            .is_err());
        let empty = Workspace {
            name: "Empty".into(),
            ..ws("e", &[])
        };
        let package = format!(
            r#"{{"format":"kriya-workspaces","version":1,"workspaces":[{{"workspace":{},"layout":null}}]}}"#,
            serde_json::to_string(&empty).unwrap()
        );
        let report = store.import_workspaces(&package, 2).unwrap();
        assert!(report.added.is_empty());
        assert!(report.skipped[0].starts_with("Empty:"));
        let older = r#"{"id":"x","name":"Old","app_ids":["a"],"layout_id":null,"hide_others":false,"urls":[]}"#;
        assert!(serde_json::from_str::<Workspace>(older)
            .unwrap()
            .sound_mode_id
            .is_none());
    }
}
