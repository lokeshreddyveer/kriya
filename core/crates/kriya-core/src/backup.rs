//! The file written by "Back up settings" and read by "Restore". Plain JSON, so it can be read and diffed by hand.

use serde::{Deserialize, Serialize};

use crate::actions::NamedAction;
use crate::clipboard::ClipConfig;
use crate::error::CoreError;
use crate::finder_store::FinderBackup;
use crate::keyboard_store::KeyboardBackup;
use crate::model::{AppSettings, ConnectionKind, Profile};
use crate::mouse::{MouseAssignment, MouseConfig, MousePreset};
use crate::rules::Rule;
use crate::selection_store::SelectionBackup;
use crate::traffic_store::TrafficBackup;
use crate::window_store::WindowBackup;
use crate::workflow::Workflow;

pub const BACKUP_FORMAT_VERSION: u32 = 1;
pub const BACKUP_APP_NAME: &str = "kriya";
/// A backup is a few kilobytes; anything near this is not one of ours.
pub const MAX_BACKUP_BYTES: usize = 5 * 1024 * 1024;

/// What a restore keeps of a device: only the choices the person made. Whether a device is plugged in is not saved.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DeviceChoices {
    pub id: String,
    pub nickname: Option<String>,
    pub connection_override: Option<ConnectionKind>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BackupFile {
    pub format_version: u32,
    pub app: String,
    pub app_version: String,
    pub created_at: i64,
    pub settings: AppSettings,
    pub profiles: Vec<Profile>,
    pub actions: Vec<NamedAction>,
    pub rules: Vec<Rule>,
    pub devices: Vec<DeviceChoices>,
    /// Added in Phase 2. A backup from before then has none of these and leaves the mouse settings alone on restore.
    #[serde(default)]
    pub mouse_presets: Vec<MousePreset>,
    #[serde(default)]
    pub mouse_assignments: Vec<MouseAssignment>,
    #[serde(default)]
    pub mouse_config: MouseConfig,
    /// Added in Phase 3. A backup from before then has none and leaves window management alone on restore.
    #[serde(default)]
    pub window: Option<WindowBackup>,
    /// Added in Phase 4, with the same rule.
    #[serde(default)]
    pub traffic: Option<TrafficBackup>,
    /// Added in Phase 5, with the same rule.
    #[serde(default)]
    pub finder: Option<FinderBackup>,
    /// Added in Phase 6: the clipboard settings only. The history itself is never part of a backup.
    #[serde(default)]
    pub clipboard: Option<ClipConfig>,
    /// Added in Phase 7: selection bar settings and actions. Script approvals are never included.
    #[serde(default)]
    pub selection: Option<SelectionBackup>,
    /// Added in Phase 8: snippets, keyboard shortcuts and their settings.
    #[serde(default)]
    pub keyboard: Option<KeyboardBackup>,
    /// Added in Phase 9. Workflows come back switched as they were but must be authorized again.
    #[serde(default)]
    pub workflows: Option<Vec<Workflow>>,
    /// Added with pointer menu, link routing, workspaces, pointer effects and key remapping: each one's saved settings as
    /// JSON text, by settings key. Only the keys in `EXTRA_KEYS` are read back.
    #[serde(default)]
    pub extras: std::collections::BTreeMap<String, String>,
}

/// The settings that are saved as one JSON blob each and travel in a backup as they are.
pub const EXTRA_KEYS: [&str; 6] = [
    "pointer_menu",
    "link_routing",
    "workspaces",
    "pointer_effects",
    "key_remap",
    // Settings the app keeps in its own preferences (window locks, capture profiles, pins…), packed as one JSON object by
    // the shell so they travel with a backup. History and logs are never put in it.
    "app_prefs",
];

const APP_PREFS_KEY: &str = "app_prefs";

impl crate::store::Store {
    /// The shell's packed preferences as JSON text, if it has saved any.
    pub fn app_prefs_json(&self) -> Result<Option<String>, CoreError> {
        use rusqlite::OptionalExtension;
        Ok(self
            .conn()
            .query_row(
                "SELECT value FROM settings WHERE key = ?1",
                rusqlite::params![APP_PREFS_KEY],
                |r| r.get(0),
            )
            .optional()?)
    }

    /// Keeps the shell's packed preferences so the next backup carries them. Anything that is not a JSON object is refused.
    pub fn save_app_prefs_json(&self, json: &str) -> Result<(), CoreError> {
        if !serde_json::from_str::<serde_json::Value>(json).is_ok_and(|v| v.is_object()) {
            return Err(CoreError::Backup {
                message: "the preferences are not valid".into(),
            });
        }
        self.conn().execute(
            "INSERT INTO settings (key, value) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            rusqlite::params![APP_PREFS_KEY, json],
        )?;
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct BackupSummary {
    pub created_at: i64,
    pub app_version: String,
    pub profiles: u32,
    pub actions: u32,
    pub rules: u32,
    pub devices: u32,
    pub mouse_presets: u32,
    pub window_layouts: u32,
}

/// Parses and checks a backup without applying it.
pub fn parse(json: &str) -> Result<BackupFile, CoreError> {
    if json.len() > MAX_BACKUP_BYTES {
        return Err(CoreError::Backup {
            message: "the file is too large to be a Kriya backup".into(),
        });
    }
    let file: BackupFile = serde_json::from_str(json).map_err(|_| CoreError::Backup {
        message: "the file is not a Kriya backup".into(),
    })?;
    if file.app != BACKUP_APP_NAME {
        return Err(CoreError::Backup {
            message: "the file is not a Kriya backup".into(),
        });
    }
    if file.format_version > BACKUP_FORMAT_VERSION {
        return Err(CoreError::Backup {
            message: "the backup was made by a newer version of Kriya".into(),
        });
    }
    Ok(file)
}

impl BackupFile {
    pub fn summary(&self) -> BackupSummary {
        BackupSummary {
            created_at: self.created_at,
            app_version: self.app_version.clone(),
            profiles: self.profiles.len() as u32,
            actions: self.actions.len() as u32,
            rules: self.rules.len() as u32,
            devices: self.devices.len() as u32,
            mouse_presets: self.mouse_presets.len() as u32,
            window_layouts: self.window.as_ref().map_or(0, |w| w.layouts.len() as u32),
        }
    }
}
