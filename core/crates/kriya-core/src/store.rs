//! Local SQLite storage: settings, the shared device registry, profiles, saved actions and rules.
//! Everything lives in one file inside the folder the shell provides.

use std::collections::HashSet;
use std::path::Path;
use std::sync::{Mutex, MutexGuard};

use rusqlite::{params, Connection, OptionalExtension, Row};

use crate::actions::{self, NamedAction};
use crate::backup::{
    self, BackupFile, BackupSummary, DeviceChoices, BACKUP_APP_NAME, BACKUP_FORMAT_VERSION,
};
use crate::clipboard::ClipConfig;
use crate::error::CoreError;
use crate::model::{
    AppSettings, ConnectionKind, DeviceKind, DeviceRecord, FeatureOverride, Profile,
    DEFAULT_PROFILE_ID,
};
use crate::rules::{self, Rule, Trigger};

/// Index + 1 is the schema version stored in `PRAGMA user_version`. Add new entries at the end; never edit old ones.
const MIGRATIONS: &[&str] = &[
    r#"
    CREATE TABLE settings (
        key   TEXT PRIMARY KEY NOT NULL,
        value TEXT NOT NULL
    );
    CREATE TABLE devices (
        id                  TEXT PRIMARY KEY NOT NULL,
        name                TEXT NOT NULL,
        vendor_id           INTEGER NOT NULL,
        product_id          INTEGER NOT NULL,
        serial              TEXT,
        transport           TEXT NOT NULL,
        kind                TEXT NOT NULL,
        detected_connection TEXT NOT NULL,
        connection_override TEXT,
        nickname            TEXT,
        first_seen          INTEGER NOT NULL,
        last_seen           INTEGER NOT NULL
    );
    CREATE TABLE profiles (
        id             TEXT PRIMARY KEY NOT NULL,
        name           TEXT NOT NULL,
        app_id         TEXT UNIQUE,
        is_default     INTEGER NOT NULL DEFAULT 0,
        is_enabled     INTEGER NOT NULL DEFAULT 1,
        overrides_json TEXT NOT NULL DEFAULT '[]',
        sort_order     INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE actions (
        id          TEXT PRIMARY KEY NOT NULL,
        name        TEXT NOT NULL,
        action_json TEXT NOT NULL
    );
    CREATE TABLE rules (
        id         TEXT PRIMARY KEY NOT NULL,
        sort_order INTEGER NOT NULL DEFAULT 0,
        rule_json  TEXT NOT NULL
    );
"#,
    r#"
    CREATE TABLE mouse_presets (
        id            TEXT PRIMARY KEY NOT NULL,
        name          TEXT NOT NULL,
        settings_json TEXT NOT NULL,
        sort_order    INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE mouse_assignments (
        id        TEXT PRIMARY KEY NOT NULL,
        device_id TEXT,
        app_id    TEXT,
        preset_id TEXT NOT NULL
    );
"#,
    r#"
    CREATE TABLE window_layouts (
        id          TEXT PRIMARY KEY NOT NULL,
        display_key TEXT NOT NULL,
        is_auto     INTEGER NOT NULL DEFAULT 0,
        created_at  INTEGER NOT NULL,
        layout_json TEXT NOT NULL
    );
"#,
    r#"
    CREATE TABLE text_snippets (
        id           TEXT PRIMARY KEY NOT NULL,
        sort_order   INTEGER NOT NULL DEFAULT 0,
        snippet_json TEXT NOT NULL
    );
"#,
    r#"
    CREATE TABLE workflow_runs (
        id          TEXT PRIMARY KEY NOT NULL,
        workflow_id TEXT NOT NULL,
        started_at  INTEGER NOT NULL,
        run_json    TEXT NOT NULL
    );
    CREATE INDEX workflow_runs_started ON workflow_runs(started_at DESC);
"#,
    r#"
    CREATE TABLE workflow_versions (
        workflow_id   TEXT NOT NULL,
        revision      INTEGER NOT NULL,
        saved_at      INTEGER NOT NULL,
        workflow_json TEXT NOT NULL,
        PRIMARY KEY (workflow_id, revision)
    );
"#,
    r#"
    CREATE TABLE layout_versions (
        layout_id   TEXT NOT NULL,
        seq         INTEGER NOT NULL,
        saved_at    INTEGER NOT NULL,
        label       TEXT NOT NULL DEFAULT '',
        layout_json TEXT NOT NULL,
        PRIMARY KEY (layout_id, seq)
    );
"#,
];

pub struct Store {
    conn: Mutex<Connection>,
    /// The saved file was damaged. It was set aside and a fresh one started.
    pub recovered_from_corruption: bool,
    /// Not even a fresh file could be opened, so this run keeps data in memory only.
    pub ephemeral: bool,
}

impl Store {
    /// Opens `dir/kriya.sqlite`. A damaged file is renamed aside rather than deleted; a file from a newer app is an
    /// error and is left alone.
    pub fn open(dir: &Path, now: i64) -> Result<Store, CoreError> {
        std::fs::create_dir_all(dir)?;
        let path = dir.join("kriya.sqlite");
        match Self::open_file(&path) {
            Ok(conn) => Ok(Self::wrap(conn, false, false)),
            Err(CoreError::NewerDatabase) => Err(CoreError::NewerDatabase),
            Err(_) => {
                Self::set_aside(&path, dir, now);
                match Self::open_file(&path) {
                    Ok(conn) => Ok(Self::wrap(conn, true, false)),
                    Err(_) => {
                        let conn = Self::prepare(Connection::open_in_memory()?)?;
                        Ok(Self::wrap(conn, true, true))
                    }
                }
            }
        }
    }

    pub fn open_in_memory() -> Result<Store, CoreError> {
        Ok(Self::wrap(
            Self::prepare(Connection::open_in_memory()?)?,
            false,
            false,
        ))
    }

    fn wrap(conn: Connection, recovered: bool, ephemeral: bool) -> Store {
        Store {
            conn: Mutex::new(conn),
            recovered_from_corruption: recovered,
            ephemeral,
        }
    }

    fn open_file(path: &Path) -> Result<Connection, CoreError> {
        Self::prepare(Connection::open(path)?)
    }

    fn prepare(mut conn: Connection) -> Result<Connection, CoreError> {
        conn.busy_timeout(std::time::Duration::from_secs(3))?;
        conn.execute_batch(
            "PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON; PRAGMA synchronous = NORMAL;",
        )?;
        let check: String = conn.query_row("PRAGMA integrity_check", [], |r| r.get(0))?;
        if check != "ok" {
            return Err(CoreError::Storage {
                message: "the database failed its integrity check".into(),
            });
        }
        Self::migrate(&mut conn)?;
        Ok(conn)
    }

    fn migrate(conn: &mut Connection) -> Result<(), CoreError> {
        let current: i64 = conn.query_row("PRAGMA user_version", [], |r| r.get(0))?;
        let current = usize::try_from(current).unwrap_or(0);
        if current > MIGRATIONS.len() {
            return Err(CoreError::NewerDatabase);
        }
        for (index, sql) in MIGRATIONS.iter().enumerate().skip(current) {
            let tx = conn.transaction()?;
            tx.execute_batch(sql)?;
            tx.pragma_update(None, "user_version", (index + 1) as i64)?;
            tx.commit()?;
        }
        Ok(())
    }

    fn set_aside(path: &Path, dir: &Path, now: i64) {
        let aside = dir.join(format!("kriya.corrupt-{now}.sqlite"));
        let _ = std::fs::rename(path, aside);
        for suffix in ["-wal", "-shm"] {
            let mut name = path.as_os_str().to_owned();
            name.push(suffix);
            let _ = std::fs::remove_file(std::path::PathBuf::from(name));
        }
    }

    pub(crate) fn conn(&self) -> MutexGuard<'_, Connection> {
        self.conn.lock().unwrap_or_else(|e| e.into_inner())
    }

    // ---- settings -------------------------------------------------------------------------------------------

    pub fn settings(&self) -> Result<AppSettings, CoreError> {
        let conn = self.conn();
        read_settings(&conn)
    }

    pub fn save_settings(&self, settings: &AppSettings) -> Result<(), CoreError> {
        let conn = self.conn();
        write_settings(&conn, settings)
    }

    // ---- devices --------------------------------------------------------------------------------------------

    pub fn devices(&self) -> Result<Vec<DeviceRecord>, CoreError> {
        let conn = self.conn();
        let mut stmt = conn.prepare(
            "SELECT id, name, vendor_id, product_id, serial, transport, kind, detected_connection,
                    connection_override, nickname, first_seen, last_seen
             FROM devices ORDER BY last_seen DESC, name COLLATE NOCASE",
        )?;
        let rows = stmt.query_map([], device_from_row)?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    /// Adds a device or refreshes what the system reports about it. The person's nickname and connection choice
    /// and the first-seen time are kept.
    pub fn upsert_device(&self, d: &DeviceRecord) -> Result<(), CoreError> {
        if d.id.trim().is_empty() {
            return Err(CoreError::invalid("a device needs an id"));
        }
        let conn = self.conn();
        conn.execute(
            "INSERT INTO devices (id, name, vendor_id, product_id, serial, transport, kind, detected_connection,
                                  connection_override, nickname, first_seen, last_seen)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
             ON CONFLICT(id) DO UPDATE SET
                 name = excluded.name, vendor_id = excluded.vendor_id, product_id = excluded.product_id,
                 serial = excluded.serial, transport = excluded.transport, kind = excluded.kind,
                 detected_connection = excluded.detected_connection, last_seen = excluded.last_seen",
            params![
                d.id,
                d.name,
                d.vendor_id,
                d.product_id,
                d.serial,
                d.transport,
                d.kind.as_str(),
                d.detected_connection.as_str(),
                d.connection_override.map(ConnectionKind::as_str),
                d.nickname,
                d.first_seen,
                d.last_seen,
            ],
        )?;
        Ok(())
    }

    pub fn touch_device(&self, id: &str, last_seen: i64) -> Result<(), CoreError> {
        self.conn().execute(
            "UPDATE devices SET last_seen = ?2 WHERE id = ?1",
            params![id, last_seen],
        )?;
        Ok(())
    }

    pub fn set_device_nickname(&self, id: &str, nickname: Option<String>) -> Result<(), CoreError> {
        let nickname = nickname
            .map(|n| n.trim().to_string())
            .filter(|n| !n.is_empty());
        let changed = self.conn().execute(
            "UPDATE devices SET nickname = ?2 WHERE id = ?1",
            params![id, nickname],
        )?;
        if changed == 0 {
            return Err(CoreError::NotFound);
        }
        Ok(())
    }

    pub fn set_device_connection_override(
        &self,
        id: &str,
        value: Option<ConnectionKind>,
    ) -> Result<(), CoreError> {
        let changed = self.conn().execute(
            "UPDATE devices SET connection_override = ?2 WHERE id = ?1",
            params![id, value.map(ConnectionKind::as_str)],
        )?;
        if changed == 0 {
            return Err(CoreError::NotFound);
        }
        Ok(())
    }

    pub fn forget_device(&self, id: &str) -> Result<(), CoreError> {
        let conn = self.conn();
        conn.execute("DELETE FROM devices WHERE id = ?1", params![id])?;
        crate::mouse_store::forget_device_assignments(&conn, id)?;
        Ok(())
    }

    // ---- profiles -------------------------------------------------------------------------------------------

    /// All profiles, the default first. The default profile is created if it is missing.
    pub fn profiles(&self) -> Result<Vec<Profile>, CoreError> {
        let conn = self.conn();
        ensure_default_profile(&conn)?;
        read_profiles(&conn)
    }

    pub fn save_profile(&self, profile: &Profile) -> Result<(), CoreError> {
        let name = profile.name.trim();
        if name.is_empty() || name.chars().count() > 100 {
            return Err(CoreError::invalid(
                "a profile needs a name of up to 100 characters",
            ));
        }
        if profile.is_default != (profile.id == DEFAULT_PROFILE_ID) {
            return Err(CoreError::invalid(
                "only the built-in profile can be the default",
            ));
        }
        if !profile.is_default
            && profile
                .app_id
                .as_deref()
                .is_none_or(|a| a.trim().is_empty())
        {
            return Err(CoreError::invalid("an app profile needs an app"));
        }
        let conn = self.conn();
        if let Some(app) = &profile.app_id {
            let taken: Option<String> = conn
                .query_row(
                    "SELECT id FROM profiles WHERE app_id = ?1 AND id != ?2",
                    params![app, profile.id],
                    |r| r.get(0),
                )
                .optional()?;
            if taken.is_some() {
                return Err(CoreError::invalid("that app already has a profile"));
            }
        }
        upsert_profile(&conn, profile)
    }

    pub fn delete_profile(&self, id: &str) -> Result<(), CoreError> {
        if id == DEFAULT_PROFILE_ID {
            return Err(CoreError::invalid("the default profile cannot be deleted"));
        }
        self.conn()
            .execute("DELETE FROM profiles WHERE id = ?1", params![id])?;
        Ok(())
    }

    // ---- actions --------------------------------------------------------------------------------------------

    pub fn actions(&self) -> Result<Vec<NamedAction>, CoreError> {
        let conn = self.conn();
        read_actions(&conn)
    }

    pub fn save_action(&self, action: &NamedAction) -> Result<(), CoreError> {
        check_named_action(action)?;
        let conn = self.conn();
        upsert_action(&conn, action)
    }

    /// Refuses while a rule or a mouse preset still uses the action, so nothing is left pointing at nothing.
    pub fn delete_action(&self, id: &str) -> Result<(), CoreError> {
        let conn = self.conn();
        let rules = read_rules(&conn)?
            .iter()
            .filter(|r| r.action_id == id)
            .count();
        let presets = crate::mouse_store::preset_uses_of_action(&conn, id)?;
        let used = rules
            + presets
            + crate::traffic_store::uses_of_action(&conn, id)?
            + crate::keyboard_store::uses_of_action(&conn, id)?;
        if used > 0 {
            return Err(CoreError::invalid(format!(
                "this action is still used by {used} rule{}, preset{} or button{}",
                if used == 1 { "" } else { "s" },
                if used == 1 { "" } else { "s" },
                if used == 1 { "" } else { "s" }
            )));
        }
        conn.execute("DELETE FROM actions WHERE id = ?1", params![id])?;
        Ok(())
    }

    // ---- rules ----------------------------------------------------------------------------------------------

    pub fn rules(&self) -> Result<Vec<Rule>, CoreError> {
        let conn = self.conn();
        read_rules(&conn)
    }

    pub fn save_rule(&self, rule: &Rule) -> Result<(), CoreError> {
        check_rule(rule)?;
        let conn = self.conn();
        let exists: Option<i64> = conn
            .query_row(
                "SELECT 1 FROM actions WHERE id = ?1",
                params![rule.action_id],
                |r| r.get(0),
            )
            .optional()?;
        if exists.is_none() {
            return Err(CoreError::invalid("the rule's action no longer exists"));
        }
        upsert_rule(&conn, rule)
    }

    pub fn delete_rule(&self, id: &str) -> Result<(), CoreError> {
        self.conn()
            .execute("DELETE FROM rules WHERE id = ?1", params![id])?;
        Ok(())
    }

    pub fn matching_rules(
        &self,
        trigger: &Trigger,
        app_id: Option<&str>,
        device_id: Option<&str>,
    ) -> Result<Vec<Rule>, CoreError> {
        let all = self.rules()?;
        Ok(rules::matching(&all, trigger, app_id, device_id))
    }

    // ---- backup ---------------------------------------------------------------------------------------------

    pub fn export_backup(&self, app_version: &str, now: i64) -> Result<String, CoreError> {
        let conn = self.conn();
        ensure_default_profile(&conn)?;
        let mut stmt =
            conn.prepare("SELECT id, nickname, connection_override FROM devices ORDER BY id")?;
        let devices = stmt
            .query_map([], |r| {
                let over: Option<String> = r.get(2)?;
                Ok(DeviceChoices {
                    id: r.get(0)?,
                    nickname: r.get(1)?,
                    connection_override: over.as_deref().and_then(ConnectionKind::parse),
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        let (mouse_presets, mouse_assignments, mouse_config) =
            crate::mouse_store::backup_parts(&conn)?;
        let window = Some(crate::window_store::backup_part(&conn)?);
        let traffic = Some(crate::traffic_store::backup_part(&conn)?);
        let finder = Some(crate::finder_store::backup_part(&conn)?);
        let clipboard = Some(crate::clipboard_db::read_clip_config(&conn)?);
        let selection = Some(crate::selection_store::backup_part(&conn)?);
        let keyboard = Some(crate::keyboard_store::backup_part(&conn)?);
        let workflows = Some(crate::workflow_store::backup_part(&conn)?);
        let mut extras = std::collections::BTreeMap::new();
        for key in backup::EXTRA_KEYS {
            let value: Option<String> = conn
                .query_row(
                    "SELECT value FROM settings WHERE key = ?1",
                    params![key],
                    |r| r.get(0),
                )
                .optional()?;
            if let Some(value) = value {
                extras.insert(key.to_string(), value);
            }
        }
        let file = BackupFile {
            extras,
            window,
            traffic,
            finder,
            clipboard,
            selection,
            keyboard,
            workflows,
            mouse_presets,
            mouse_assignments,
            mouse_config,
            format_version: BACKUP_FORMAT_VERSION,
            app: BACKUP_APP_NAME.to_string(),
            app_version: app_version.to_string(),
            created_at: now,
            settings: read_settings(&conn)?,
            profiles: read_profiles(&conn)?,
            actions: read_actions(&conn)?,
            rules: read_rules(&conn)?,
            devices,
        };
        Ok(serde_json::to_string_pretty(&file)?)
    }

    /// Checks a backup completely first, then replaces settings, profiles, actions and rules in one transaction.
    /// If anything is wrong nothing changes. Devices are kept; only the person's choices for known ones are restored.
    pub fn import_backup(&self, json: &str) -> Result<BackupSummary, CoreError> {
        let file = backup::parse(json)?;
        let bad = |message: &str| CoreError::Backup {
            message: message.to_string(),
        };

        let mut action_ids = HashSet::new();
        for a in &file.actions {
            check_named_action(a).map_err(|e| CoreError::Backup {
                message: e.to_string(),
            })?;
            if !action_ids.insert(a.id.as_str()) {
                return Err(bad("two saved actions share an id"));
            }
        }
        let mut rule_ids = HashSet::new();
        for r in &file.rules {
            check_rule(r).map_err(|e| CoreError::Backup {
                message: e.to_string(),
            })?;
            if !action_ids.contains(r.action_id.as_str()) {
                return Err(bad("a rule refers to an action that is not in the backup"));
            }
            if !rule_ids.insert(r.id.as_str()) {
                return Err(bad("two rules share an id"));
            }
        }
        let mut profile_ids = HashSet::new();
        let mut app_ids = HashSet::new();
        for p in &file.profiles {
            if p.name.trim().is_empty() || p.is_default != (p.id == DEFAULT_PROFILE_ID) {
                return Err(bad("a profile in the backup is not valid"));
            }
            if !profile_ids.insert(p.id.as_str()) {
                return Err(bad("two profiles share an id"));
            }
            if let Some(app) = &p.app_id {
                if !app_ids.insert(app.as_str()) {
                    return Err(bad("two profiles are for the same app"));
                }
            }
        }

        crate::mouse_store::validate_backup(&file, &action_ids)?;
        crate::window_store::validate_backup(&file)?;
        crate::traffic_store::validate_backup(&file, &action_ids)?;
        crate::finder_store::validate_backup(&file)?;
        crate::selection_store::validate_backup(&file)?;
        crate::keyboard_store::validate_backup(&file, &action_ids)?;
        crate::workflow_store::validate_backup(&file)?;
        for (key, value) in &file.extras {
            if backup::EXTRA_KEYS.contains(&key.as_str())
                && (value.len() > 500_000
                    || serde_json::from_str::<serde_json::Value>(value).is_err())
            {
                return Err(bad("a setting in the backup is not valid"));
            }
        }
        if let Some(problem) = file
            .clipboard
            .as_ref()
            .and_then(ClipConfig::shortcut_problem)
        {
            return Err(CoreError::Backup { message: problem });
        }

        let conn = self.conn();
        let tx = conn.unchecked_transaction()?;
        write_settings(&tx, &file.settings)?;
        tx.execute("DELETE FROM rules", [])?;
        tx.execute("DELETE FROM actions", [])?;
        tx.execute("DELETE FROM profiles", [])?;
        for p in &file.profiles {
            upsert_profile(&tx, p)?;
        }
        ensure_default_profile(&tx)?;
        for a in &file.actions {
            upsert_action(&tx, a)?;
        }
        for r in &file.rules {
            upsert_rule(&tx, r)?;
        }
        crate::mouse_store::restore_backup(&tx, &file)?;
        crate::window_store::restore_backup(&tx, &file)?;
        crate::traffic_store::restore_backup(&tx, &file)?;
        crate::finder_store::restore_backup(&tx, &file)?;
        crate::selection_store::restore_backup(&tx, &file)?;
        crate::keyboard_store::restore_backup(&tx, &file)?;
        crate::workflow_store::restore_backup(&tx, &file)?;
        if let Some(config) = &file.clipboard {
            crate::clipboard_db::write_clip_config(&tx, &config.clone().sanitized())?;
        }
        for (key, value) in &file.extras {
            if backup::EXTRA_KEYS.contains(&key.as_str()) {
                tx.execute(
                    "INSERT INTO settings (key, value) VALUES (?1, ?2)
                     ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    params![key, value],
                )?;
            }
        }
        for d in &file.devices {
            tx.execute(
                "UPDATE devices SET nickname = ?2, connection_override = ?3 WHERE id = ?1",
                params![
                    d.id,
                    d.nickname,
                    d.connection_override.map(ConnectionKind::as_str)
                ],
            )?;
        }
        tx.commit()?;
        Ok(file.summary())
    }
}

// ---- helpers that work on any connection or transaction -----------------------------------------------------------

fn read_settings(conn: &Connection) -> Result<AppSettings, CoreError> {
    let json: Option<String> = conn
        .query_row(
            "SELECT value FROM settings WHERE key = 'settings'",
            [],
            |r| r.get(0),
        )
        .optional()?;
    Ok(json
        .and_then(|j| serde_json::from_str::<AppSettings>(&j).ok())
        .unwrap_or_default()
        .sanitized())
}

fn write_settings(conn: &Connection, settings: &AppSettings) -> Result<(), CoreError> {
    let json = serde_json::to_string(&settings.clone().sanitized())?;
    conn.execute(
        "INSERT INTO settings (key, value) VALUES ('settings', ?1)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![json],
    )?;
    Ok(())
}

fn device_from_row(r: &Row<'_>) -> rusqlite::Result<DeviceRecord> {
    let kind: String = r.get(6)?;
    let detected: String = r.get(7)?;
    let over: Option<String> = r.get(8)?;
    Ok(DeviceRecord {
        id: r.get(0)?,
        name: r.get(1)?,
        vendor_id: r.get(2)?,
        product_id: r.get(3)?,
        serial: r.get(4)?,
        transport: r.get(5)?,
        kind: DeviceKind::parse(&kind).unwrap_or(DeviceKind::Mouse),
        detected_connection: ConnectionKind::parse(&detected).unwrap_or(ConnectionKind::Wired),
        connection_override: over.as_deref().and_then(ConnectionKind::parse),
        nickname: r.get(9)?,
        first_seen: r.get(10)?,
        last_seen: r.get(11)?,
    })
}

fn ensure_default_profile(conn: &Connection) -> Result<(), CoreError> {
    let exists: Option<i64> = conn
        .query_row(
            "SELECT 1 FROM profiles WHERE id = ?1",
            params![DEFAULT_PROFILE_ID],
            |r| r.get(0),
        )
        .optional()?;
    if exists.is_none() {
        upsert_profile(conn, &Profile::default_profile())?;
    }
    Ok(())
}

fn read_profiles(conn: &Connection) -> Result<Vec<Profile>, CoreError> {
    let mut stmt = conn.prepare(
        "SELECT id, name, app_id, is_default, is_enabled, overrides_json, sort_order
         FROM profiles ORDER BY is_default DESC, sort_order, name COLLATE NOCASE",
    )?;
    let rows = stmt.query_map([], |r| {
        let overrides: String = r.get(5)?;
        Ok(Profile {
            id: r.get(0)?,
            name: r.get(1)?,
            app_id: r.get(2)?,
            is_default: r.get::<_, i64>(3)? != 0,
            is_enabled: r.get::<_, i64>(4)? != 0,
            feature_overrides: serde_json::from_str::<Vec<FeatureOverride>>(&overrides)
                .unwrap_or_default(),
            sort_order: r.get(6)?,
        })
    })?;
    Ok(rows.collect::<Result<Vec<_>, _>>()?)
}

fn upsert_profile(conn: &Connection, p: &Profile) -> Result<(), CoreError> {
    let overrides = serde_json::to_string(&p.feature_overrides)?;
    conn.execute(
        "INSERT INTO profiles (id, name, app_id, is_default, is_enabled, overrides_json, sort_order)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
         ON CONFLICT(id) DO UPDATE SET
             name = excluded.name, app_id = excluded.app_id, is_default = excluded.is_default,
             is_enabled = excluded.is_enabled, overrides_json = excluded.overrides_json,
             sort_order = excluded.sort_order",
        params![
            p.id,
            p.name.trim(),
            p.app_id,
            i64::from(p.is_default),
            i64::from(p.is_enabled),
            overrides,
            p.sort_order
        ],
    )?;
    Ok(())
}

pub(crate) fn check_named_action(a: &NamedAction) -> Result<(), CoreError> {
    if a.id.trim().is_empty() {
        return Err(CoreError::invalid("an action needs an id"));
    }
    if a.name.trim().is_empty() || a.name.chars().count() > 100 {
        return Err(CoreError::invalid(
            "an action needs a name of up to 100 characters",
        ));
    }
    actions::validate(&a.action)
}

pub(crate) fn read_actions(conn: &Connection) -> Result<Vec<NamedAction>, CoreError> {
    let mut stmt =
        conn.prepare("SELECT id, name, action_json FROM actions ORDER BY name COLLATE NOCASE")?;
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
        // An action this version cannot read is skipped rather than failing the whole list.
        if let Ok(action) = serde_json::from_str(&json) {
            out.push(NamedAction { id, name, action });
        }
    }
    Ok(out)
}

pub(crate) fn upsert_action(conn: &Connection, a: &NamedAction) -> Result<(), CoreError> {
    let json = serde_json::to_string(&a.action)?;
    conn.execute(
        "INSERT INTO actions (id, name, action_json) VALUES (?1, ?2, ?3)
         ON CONFLICT(id) DO UPDATE SET name = excluded.name, action_json = excluded.action_json",
        params![a.id, a.name.trim(), json],
    )?;
    Ok(())
}

fn check_rule(r: &Rule) -> Result<(), CoreError> {
    if r.id.trim().is_empty() || r.action_id.trim().is_empty() {
        return Err(CoreError::invalid("a rule needs an id and an action"));
    }
    if r.name.trim().is_empty() || r.name.chars().count() > 100 {
        return Err(CoreError::invalid(
            "a rule needs a name of up to 100 characters",
        ));
    }
    Ok(())
}

fn read_rules(conn: &Connection) -> Result<Vec<Rule>, CoreError> {
    let mut stmt = conn.prepare("SELECT rule_json FROM rules ORDER BY sort_order, id")?;
    let rows = stmt.query_map([], |r| r.get::<_, String>(0))?;
    let mut out = Vec::new();
    for row in rows {
        if let Ok(rule) = serde_json::from_str(&row?) {
            out.push(rule);
        }
    }
    Ok(out)
}

fn upsert_rule(conn: &Connection, r: &Rule) -> Result<(), CoreError> {
    let json = serde_json::to_string(r)?;
    conn.execute(
        "INSERT INTO rules (id, sort_order, rule_json) VALUES (?1, ?2, ?3)
         ON CONFLICT(id) DO UPDATE SET sort_order = excluded.sort_order, rule_json = excluded.rule_json",
        params![r.id, r.sort_order, json],
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::actions::Action;
    use crate::model::FeatureId;

    fn device(id: &str) -> DeviceRecord {
        DeviceRecord {
            id: id.into(),
            name: "Test Mouse".into(),
            vendor_id: 1,
            product_id: 2,
            serial: None,
            transport: "USB".into(),
            kind: DeviceKind::Mouse,
            detected_connection: ConnectionKind::Wired,
            connection_override: None,
            nickname: None,
            first_seen: 100,
            last_seen: 100,
        }
    }

    fn open() -> Store {
        Store::open_in_memory().unwrap()
    }

    fn action(id: &str) -> NamedAction {
        NamedAction {
            id: id.into(),
            name: format!("Action {id}"),
            action: Action::OpenUrl {
                url: "https://example.com".into(),
            },
        }
    }

    fn rule(id: &str, action_id: &str) -> Rule {
        Rule {
            id: id.into(),
            name: id.into(),
            enabled: true,
            trigger: Trigger::Manual,
            app_ids: vec![],
            device_ids: vec![],
            action_id: action_id.into(),
            sort_order: 0,
        }
    }

    #[test]
    fn settings_default_then_round_trip() {
        let store = open();
        assert_eq!(store.settings().unwrap(), AppSettings::default());
        let s = AppSettings {
            enabled_features: vec![FeatureId::Mouse, FeatureId::Mouse, FeatureId::TrafficLights],
            ..AppSettings::default()
        };
        store.save_settings(&s).unwrap();
        assert_eq!(
            store.settings().unwrap().enabled_features,
            vec![FeatureId::Mouse, FeatureId::TrafficLights]
        );
    }

    #[test]
    fn device_upsert_keeps_the_persons_choices() {
        let store = open();
        store.upsert_device(&device("d1")).unwrap();
        store
            .set_device_nickname("d1", Some("  Desk mouse ".into()))
            .unwrap();
        store
            .set_device_connection_override("d1", Some(ConnectionKind::Wireless))
            .unwrap();
        let mut seen_again = device("d1");
        seen_again.name = "Renamed By System".into();
        seen_again.first_seen = 999;
        seen_again.last_seen = 500;
        store.upsert_device(&seen_again).unwrap();
        let d = &store.devices().unwrap()[0];
        assert_eq!(d.name, "Renamed By System");
        assert_eq!(d.nickname.as_deref(), Some("Desk mouse"));
        assert_eq!(d.connection_override, Some(ConnectionKind::Wireless));
        assert_eq!(d.first_seen, 100);
        assert_eq!(d.last_seen, 500);
    }

    #[test]
    fn unknown_device_edits_report_not_found() {
        let store = open();
        assert!(matches!(
            store.set_device_nickname("nope", None),
            Err(CoreError::NotFound)
        ));
    }

    #[test]
    fn default_profile_always_exists_and_cannot_be_deleted() {
        let store = open();
        let profiles = store.profiles().unwrap();
        assert_eq!(profiles.len(), 1);
        assert!(profiles[0].is_default);
        assert!(store.delete_profile(DEFAULT_PROFILE_ID).is_err());
    }

    #[test]
    fn one_profile_per_app() {
        let store = open();
        let mut p = Profile::default_profile();
        p.id = "p1".into();
        p.is_default = false;
        p.app_id = Some("com.example.app".into());
        p.name = "Example".into();
        store.save_profile(&p).unwrap();
        let mut dup = p.clone();
        dup.id = "p2".into();
        assert!(store.save_profile(&dup).is_err());
        p.is_enabled = false;
        store.save_profile(&p).unwrap();
        assert!(
            !store
                .profiles()
                .unwrap()
                .iter()
                .find(|x| x.id == "p1")
                .unwrap()
                .is_enabled
        );
    }

    #[test]
    fn actions_are_validated_and_protected_by_rules() {
        let store = open();
        let mut bad = action("bad");
        bad.action = Action::OpenUrl {
            url: "javascript:1".into(),
        };
        assert!(store.save_action(&bad).is_err());
        store.save_action(&action("a1")).unwrap();
        store.save_rule(&rule("r1", "a1")).unwrap();
        assert!(store.delete_action("a1").is_err());
        assert!(store.save_rule(&rule("r2", "missing")).is_err());
        store.delete_rule("r1").unwrap();
        store.delete_action("a1").unwrap();
    }

    #[test]
    fn backup_round_trips() {
        let source = open();
        let s = AppSettings {
            has_completed_onboarding: true,
            ..AppSettings::default()
        };
        source.save_settings(&s).unwrap();
        source.upsert_device(&device("d1")).unwrap();
        source
            .set_device_nickname("d1", Some("Travel".into()))
            .unwrap();
        source.save_action(&action("a1")).unwrap();
        source.save_rule(&rule("r1", "a1")).unwrap();
        let json = source.export_backup("0.1.0", 42).unwrap();

        let target = open();
        target.upsert_device(&device("d1")).unwrap();
        target.save_action(&action("old")).unwrap();
        let summary = target.import_backup(&json).unwrap();
        assert_eq!(
            (summary.actions, summary.rules, summary.created_at),
            (1, 1, 42)
        );
        assert!(target.settings().unwrap().has_completed_onboarding);
        assert_eq!(target.actions().unwrap().len(), 1);
        assert_eq!(target.rules().unwrap().len(), 1);
        assert_eq!(
            target.devices().unwrap()[0].nickname.as_deref(),
            Some("Travel")
        );
    }

    #[test]
    fn newer_settings_travel_in_a_backup() {
        let source = open();
        source
            .save_workspace_config(&crate::workspace::WorkspaceConfig {
                focus_app_ids: vec!["com.x".into()],
                ..Default::default()
            })
            .unwrap();
        let json = source.export_backup("0.1.3", 1).unwrap();
        let target = open();
        target.import_backup(&json).unwrap();
        assert_eq!(
            target.workspace_config().unwrap().focus_app_ids,
            vec!["com.x".to_string()]
        );
        let mut value: serde_json::Value = serde_json::from_str(&json).unwrap();
        value["extras"]["workspaces"] = "{nope".into();
        let broken = value.to_string();
        assert!(target.import_backup(&broken).is_err());
    }

    #[test]
    fn app_preferences_travel_in_a_backup_and_must_be_an_object() {
        let source = open();
        assert!(source.save_app_prefs_json("[1]").is_err());
        assert!(source.save_app_prefs_json("nope").is_err());
        source
            .save_app_prefs_json(r#"{"windowLocks.v1":"eA=="}"#)
            .unwrap();
        let json = source.export_backup("0.1.3", 1).unwrap();
        let target = open();
        assert_eq!(target.app_prefs_json().unwrap(), None);
        target.import_backup(&json).unwrap();
        assert_eq!(
            target.app_prefs_json().unwrap().as_deref(),
            Some(r#"{"windowLocks.v1":"eA=="}"#)
        );
        let mut value: serde_json::Value = serde_json::from_str(&json).unwrap();
        value["extras"]["app_prefs"] = "{nope".into();
        assert!(target.import_backup(&value.to_string()).is_err());
    }

    #[test]
    fn bad_backup_changes_nothing() {
        let store = open();
        store.save_action(&action("keep")).unwrap();
        assert!(store.import_backup("not json").is_err());
        let json = open().export_backup("0.1.0", 1).unwrap();
        let broken = json.replace("\"kriya\"", "\"other\"");
        assert!(store.import_backup(&broken).is_err());
        let newer = json.replace("\"format_version\": 1", "\"format_version\": 99");
        assert!(store.import_backup(&newer).is_err());
        assert_eq!(store.actions().unwrap().len(), 1);
    }

    #[test]
    fn corrupt_file_is_set_aside_not_deleted() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            dir.path().join("kriya.sqlite"),
            b"this is not a database at all, just text",
        )
        .unwrap();
        let store = Store::open(dir.path(), 77).unwrap();
        assert!(store.recovered_from_corruption && !store.ephemeral);
        assert!(dir.path().join("kriya.corrupt-77.sqlite").exists());
        store.save_settings(&AppSettings::default()).unwrap();
    }

    #[test]
    fn data_persists_across_opens() {
        let dir = tempfile::tempdir().unwrap();
        {
            let store = Store::open(dir.path(), 1).unwrap();
            store.save_action(&action("a1")).unwrap();
        }
        let again = Store::open(dir.path(), 2).unwrap();
        assert!(!again.recovered_from_corruption);
        assert_eq!(again.actions().unwrap().len(), 1);
    }

    #[test]
    fn newer_database_is_refused_and_left_alone() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("kriya.sqlite");
        {
            let conn = Connection::open(&path).unwrap();
            conn.pragma_update(None, "user_version", 999_i64).unwrap();
        }
        assert!(matches!(
            Store::open(dir.path(), 1),
            Err(CoreError::NewerDatabase)
        ));
        assert!(path.exists());
    }
}
