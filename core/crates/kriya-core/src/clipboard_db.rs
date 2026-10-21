//! The clipboard history database. It is its own file (`clipboard.sqlite`), apart from the settings, so a settings backup
//! never carries what was copied. Deleted content is overwritten on disk. Nothing in here uses the network.

use std::path::Path;
use std::sync::{Mutex, MutexGuard};

use rusqlite::{params, params_from_iter, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};

use crate::clipboard::{
    clean_tags, content_hash, make_preview, make_search_text, should_skip, ClipConfig, ClipKind,
    ClipSkipReason, NewClip,
};
use crate::error::CoreError;
use crate::store::Store;

const MAX_SNIPPET_BYTES: usize = 1024 * 1024;
const MAX_TITLE_CHARS: usize = 100;
const MAX_IMPORT_BYTES: usize = 5 * 1024 * 1024;
const MAX_IMPORT_SNIPPETS: usize = 5000;
pub const SNIPPET_FILE_KIND: &str = "clip_snippets";

const MIGRATIONS: &[&str] = &[r#"
    CREATE TABLE collections (
        id         TEXT PRIMARY KEY NOT NULL,
        name       TEXT NOT NULL UNIQUE COLLATE NOCASE,
        sort_order INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE clips (
        id            TEXT PRIMARY KEY NOT NULL,
        kind          TEXT NOT NULL,
        preview       TEXT NOT NULL,
        title         TEXT,
        source_app    TEXT,
        created_at    INTEGER NOT NULL,
        last_used_at  INTEGER NOT NULL,
        use_count     INTEGER NOT NULL DEFAULT 1,
        pinned        INTEGER NOT NULL DEFAULT 0,
        favorite      INTEGER NOT NULL DEFAULT 0,
        collection_id TEXT REFERENCES collections(id) ON DELETE SET NULL,
        byte_size     INTEGER NOT NULL DEFAULT 0,
        image_w       INTEGER,
        image_h       INTEGER,
        files_json    TEXT NOT NULL DEFAULT '[]',
        has_rich      INTEGER NOT NULL DEFAULT 0,
        hash          TEXT NOT NULL UNIQUE,
        search_text   TEXT NOT NULL
    );
    CREATE INDEX clips_used ON clips(pinned DESC, last_used_at DESC);
    CREATE TABLE clip_blobs (
        id           TEXT PRIMARY KEY NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
        plain        TEXT,
        rich         BLOB,
        rich_format  TEXT,
        image        BLOB,
        image_format TEXT
    );
    CREATE TABLE clip_tags (
        clip_id TEXT NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
        tag     TEXT NOT NULL,
        PRIMARY KEY (clip_id, tag)
    );
"#];

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct ClipItem {
    pub id: String,
    pub kind: ClipKind,
    pub preview: String,
    /// A snippet's name.
    pub title: Option<String>,
    pub source_app: Option<String>,
    pub created_at: i64,
    pub last_used_at: i64,
    pub use_count: u32,
    pub pinned: bool,
    /// Favorites are snippets: kept for ever and listed under Snippets.
    pub favorite: bool,
    pub collection_id: Option<String>,
    pub tags: Vec<String>,
    pub byte_size: u64,
    pub image_width: Option<u32>,
    pub image_height: Option<u32>,
    pub files: Vec<String>,
    pub has_rich: bool,
}

/// The full content of an item, fetched only when it is needed (an image can be large).
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ClipBlob {
    pub plain: Option<String>,
    pub rich: Option<Vec<u8>>,
    pub rich_format: Option<String>,
    pub image: Option<Vec<u8>>,
    pub image_format: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Default, uniffi::Record)]
pub struct ClipFilter {
    /// Empty means every kind.
    pub kinds: Vec<ClipKind>,
    pub pinned_only: bool,
    pub favorites_only: bool,
    pub collection_id: Option<String>,
    pub tag: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct ClipCollection {
    pub id: String,
    pub name: String,
    pub count: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ClipRecordStatus {
    Stored,
    /// The same thing was copied before; that item moved back to the top.
    Duplicate,
    Skipped,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ClipRecordOutcome {
    pub status: ClipRecordStatus,
    pub id: Option<String>,
    pub skipped: Option<ClipSkipReason>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ClipStats {
    pub items: u32,
    pub bytes: u64,
    pub pinned: u32,
    pub snippets: u32,
    pub oldest: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SnippetImportSummary {
    pub added: u32,
    pub updated: u32,
    pub skipped: u32,
}

#[derive(Debug, Serialize, Deserialize)]
struct SnippetFile {
    format_version: u32,
    app: String,
    kind: String,
    collections: Vec<String>,
    snippets: Vec<SnippetEntry>,
}

#[derive(Debug, Serialize, Deserialize)]
struct SnippetEntry {
    title: Option<String>,
    text: String,
    tags: Vec<String>,
    collection: Option<String>,
}

type SnippetRow = (
    Option<String>,
    Option<String>,
    Option<String>,
    Option<String>,
);

pub struct ClipStore {
    conn: Mutex<Connection>,
    pub recovered_from_corruption: bool,
    pub ephemeral: bool,
}

const ITEM_COLUMNS: &str = "c.id, c.kind, c.preview, c.title, c.source_app, c.created_at, c.last_used_at, c.use_count, c.pinned, \
                            c.favorite, c.collection_id, c.byte_size, c.image_w, c.image_h, c.files_json, c.has_rich";

impl ClipStore {
    /// Opens `dir/clipboard.sqlite`. A damaged file is set aside, not deleted.
    pub fn open(dir: &Path, now: i64) -> Result<ClipStore, CoreError> {
        std::fs::create_dir_all(dir)?;
        let path = dir.join("clipboard.sqlite");
        match Self::open_file(&path) {
            Ok(conn) => Ok(Self::wrap(conn, false, false)),
            Err(CoreError::NewerDatabase) => Err(CoreError::NewerDatabase),
            Err(_) => {
                let _ = std::fs::rename(&path, dir.join(format!("clipboard.corrupt-{now}.sqlite")));
                for suffix in ["-wal", "-shm"] {
                    let mut name = path.as_os_str().to_owned();
                    name.push(suffix);
                    let _ = std::fs::remove_file(std::path::PathBuf::from(name));
                }
                match Self::open_file(&path) {
                    Ok(conn) => Ok(Self::wrap(conn, true, false)),
                    Err(_) => Ok(Self::wrap(
                        Self::prepare(Connection::open_in_memory()?)?,
                        true,
                        true,
                    )),
                }
            }
        }
    }

    pub fn open_in_memory() -> Result<ClipStore, CoreError> {
        Ok(Self::wrap(
            Self::prepare(Connection::open_in_memory()?)?,
            false,
            false,
        ))
    }

    fn wrap(conn: Connection, recovered: bool, ephemeral: bool) -> ClipStore {
        ClipStore {
            conn: Mutex::new(conn),
            recovered_from_corruption: recovered,
            ephemeral,
        }
    }

    fn open_file(path: &Path) -> Result<Connection, CoreError> {
        let conn = Self::prepare(Connection::open(path)?)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
        }
        Ok(conn)
    }

    fn prepare(mut conn: Connection) -> Result<Connection, CoreError> {
        conn.busy_timeout(std::time::Duration::from_secs(3))?;
        // `secure_delete` overwrites removed content, so clearing the history really removes it from the disk.
        conn.execute_batch("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON; PRAGMA synchronous = NORMAL; PRAGMA secure_delete = ON;")?;
        let check: String = conn.query_row("PRAGMA integrity_check", [], |r| r.get(0))?;
        if check != "ok" {
            return Err(CoreError::Storage {
                message: "the clipboard database failed its integrity check".into(),
            });
        }
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
        Ok(conn)
    }

    fn conn(&self) -> MutexGuard<'_, Connection> {
        self.conn.lock().unwrap_or_else(|e| e.into_inner())
    }

    // ---- recording ------------------------------------------------------------------------------------------

    /// Records a copy, unless the rules say to leave it out. The same copy twice becomes one item moved to the top.
    pub fn record(
        &self,
        new: NewClip,
        now: i64,
        config: &ClipConfig,
    ) -> Result<ClipRecordOutcome, CoreError> {
        let mut new = new;
        if !config.capture_rich_text {
            new.rich = None;
            new.rich_format = None;
        }
        if let Some(reason) = should_skip(&new, config) {
            return Ok(ClipRecordOutcome {
                status: ClipRecordStatus::Skipped,
                id: None,
                skipped: Some(reason),
            });
        }
        let Some(kind) = new.kind() else {
            return Ok(ClipRecordOutcome {
                status: ClipRecordStatus::Skipped,
                id: None,
                skipped: Some(ClipSkipReason::Empty),
            });
        };
        let hash = content_hash(&new);
        let conn = self.conn();
        let existing: Option<String> = conn
            .query_row("SELECT id FROM clips WHERE hash = ?1", params![hash], |r| {
                r.get(0)
            })
            .optional()?;
        if let Some(id) = existing {
            conn.execute(
                "UPDATE clips SET last_used_at = ?2, use_count = use_count + 1 WHERE id = ?1",
                params![id, now],
            )?;
            return Ok(ClipRecordOutcome {
                status: ClipRecordStatus::Duplicate,
                id: Some(id),
                skipped: None,
            });
        }
        let id = new_id(&hash, now);
        let tx = conn.unchecked_transaction()?;
        tx.execute(
            "INSERT INTO clips (id, kind, preview, source_app, created_at, last_used_at, byte_size, image_w, image_h, files_json, has_rich, hash, search_text)
             VALUES (?1, ?2, ?3, ?4, ?5, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
            params![
                id,
                kind.as_str(),
                make_preview(&new),
                new.source_app,
                now,
                new.byte_size() as i64,
                new.image_width,
                new.image_height,
                serde_json::to_string(&new.files)?,
                i64::from(new.rich.is_some()),
                hash,
                make_search_text(&new, None),
            ],
        )?;
        let plain = if matches!(kind, ClipKind::Image | ClipKind::Files) {
            None
        } else {
            new.text.clone()
        };
        tx.execute(
            "INSERT INTO clip_blobs (id, plain, rich, rich_format, image, image_format) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![id, plain, new.rich, new.rich_format, new.image, new.image_format],
        )?;
        tx.commit()?;
        drop(conn);
        self.cleanup(config, now)?;
        Ok(ClipRecordOutcome {
            status: ClipRecordStatus::Stored,
            id: Some(id),
            skipped: None,
        })
    }

    // ---- reading ----------------------------------------------------------------------------------------------

    /// Items matching the words in `query` (all of them, in the text, title, tags or source app) and the filter,
    /// pinned first, then most recently used.
    pub fn search(
        &self,
        query: &str,
        filter: &ClipFilter,
        limit: u32,
    ) -> Result<Vec<ClipItem>, CoreError> {
        let mut clauses: Vec<String> = Vec::new();
        let mut args: Vec<String> = Vec::new();
        for word in query.split_whitespace().take(12) {
            let pattern = format!("%{}%", escape_like(&word.to_lowercase()));
            clauses.push(
                "(c.search_text LIKE ? ESCAPE '\\' OR lower(COALESCE(c.title, '')) LIKE ? ESCAPE '\\' \
                 OR EXISTS (SELECT 1 FROM clip_tags t WHERE t.clip_id = c.id AND t.tag LIKE ? ESCAPE '\\'))"
                    .to_string(),
            );
            args.extend([pattern.clone(), pattern.clone(), pattern]);
        }
        if !filter.kinds.is_empty() {
            clauses.push(format!(
                "c.kind IN ({})",
                vec!["?"; filter.kinds.len()].join(", ")
            ));
            args.extend(filter.kinds.iter().map(|k| k.as_str().to_string()));
        }
        if filter.pinned_only {
            clauses.push("c.pinned = 1".into());
        }
        if filter.favorites_only {
            clauses.push("c.favorite = 1".into());
        }
        if let Some(collection) = &filter.collection_id {
            clauses.push("c.collection_id = ?".into());
            args.push(collection.clone());
        }
        if let Some(tag) = &filter.tag {
            clauses.push(
                "EXISTS (SELECT 1 FROM clip_tags t WHERE t.clip_id = c.id AND t.tag = ?)".into(),
            );
            args.push(tag.to_lowercase());
        }
        let where_sql = if clauses.is_empty() {
            String::new()
        } else {
            format!("WHERE {}", clauses.join(" AND "))
        };
        let sql = format!(
            "SELECT {ITEM_COLUMNS} FROM clips c {where_sql} ORDER BY c.pinned DESC, c.last_used_at DESC, c.id LIMIT {}",
            limit.clamp(1, 5000)
        );
        let conn = self.conn();
        let mut stmt = conn.prepare(&sql)?;
        let rows = stmt.query_map(params_from_iter(args.iter()), item_from_row)?;
        let mut items = rows.collect::<Result<Vec<_>, _>>()?;
        attach_tags(&conn, &mut items)?;
        Ok(items)
    }

    pub fn item(&self, id: &str) -> Result<Option<ClipItem>, CoreError> {
        let conn = self.conn();
        let sql = format!("SELECT {ITEM_COLUMNS} FROM clips c WHERE c.id = ?1");
        let found = conn
            .query_row(&sql, params![id], item_from_row)
            .optional()?;
        match found {
            Some(item) => {
                let mut one = vec![item];
                attach_tags(&conn, &mut one)?;
                Ok(one.pop())
            }
            None => Ok(None),
        }
    }

    pub fn blob(&self, id: &str) -> Result<Option<ClipBlob>, CoreError> {
        Ok(self
            .conn()
            .query_row("SELECT plain, rich, rich_format, image, image_format FROM clip_blobs WHERE id = ?1", params![id], |r| {
                Ok(ClipBlob { plain: r.get(0)?, rich: r.get(1)?, rich_format: r.get(2)?, image: r.get(3)?, image_format: r.get(4)? })
            })
            .optional()?)
    }

    pub fn stats(&self) -> Result<ClipStats, CoreError> {
        Ok(self.conn().query_row(
            "SELECT COUNT(*), COALESCE(SUM(byte_size), 0), COALESCE(SUM(pinned), 0), COALESCE(SUM(favorite), 0), MIN(created_at) FROM clips",
            [],
            |r| {
                Ok(ClipStats {
                    items: r.get::<_, i64>(0)? as u32,
                    bytes: r.get::<_, i64>(1)? as u64,
                    pinned: r.get::<_, i64>(2)? as u32,
                    snippets: r.get::<_, i64>(3)? as u32,
                    oldest: r.get(4)?,
                })
            },
        )?)
    }

    // ---- changing an item -------------------------------------------------------------------------------------

    pub fn mark_used(&self, id: &str, now: i64) -> Result<(), CoreError> {
        self.conn().execute(
            "UPDATE clips SET last_used_at = ?2, use_count = use_count + 1 WHERE id = ?1",
            params![id, now],
        )?;
        Ok(())
    }

    pub fn set_pinned(&self, id: &str, pinned: bool) -> Result<(), CoreError> {
        self.change(
            id,
            "UPDATE clips SET pinned = ?2 WHERE id = ?1",
            params![id, i64::from(pinned)],
        )
    }

    /// Turns an item into a snippet (or back). A snippet is kept for ever and can have a name.
    pub fn set_favorite(
        &self,
        id: &str,
        favorite: bool,
        title: Option<String>,
    ) -> Result<(), CoreError> {
        let title = clean_title(title)?;
        self.change(
            id,
            "UPDATE clips SET favorite = ?2, title = ?3 WHERE id = ?1",
            params![id, i64::from(favorite), title],
        )
    }

    pub fn set_title(&self, id: &str, title: Option<String>) -> Result<(), CoreError> {
        let title = clean_title(title)?;
        self.change(
            id,
            "UPDATE clips SET title = ?2 WHERE id = ?1",
            params![id, title],
        )
    }

    pub fn set_tags(&self, id: &str, tags: &[String]) -> Result<(), CoreError> {
        let conn = self.conn();
        let exists: Option<i64> = conn
            .query_row("SELECT 1 FROM clips WHERE id = ?1", params![id], |r| {
                r.get(0)
            })
            .optional()?;
        if exists.is_none() {
            return Err(CoreError::NotFound);
        }
        let tx = conn.unchecked_transaction()?;
        tx.execute("DELETE FROM clip_tags WHERE clip_id = ?1", params![id])?;
        for tag in clean_tags(tags) {
            tx.execute(
                "INSERT INTO clip_tags (clip_id, tag) VALUES (?1, ?2)",
                params![id, tag],
            )?;
        }
        tx.commit()?;
        Ok(())
    }

    pub fn all_tags(&self) -> Result<Vec<String>, CoreError> {
        let conn = self.conn();
        let mut stmt = conn.prepare("SELECT DISTINCT tag FROM clip_tags ORDER BY tag")?;
        let rows = stmt.query_map([], |r| r.get::<_, String>(0))?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    pub fn set_collection(&self, id: &str, collection: Option<String>) -> Result<(), CoreError> {
        if let Some(c) = &collection {
            let exists: Option<i64> = self
                .conn()
                .query_row("SELECT 1 FROM collections WHERE id = ?1", params![c], |r| {
                    r.get(0)
                })
                .optional()?;
            if exists.is_none() {
                return Err(CoreError::invalid("that collection no longer exists"));
            }
        }
        self.change(
            id,
            "UPDATE clips SET collection_id = ?2 WHERE id = ?1",
            params![id, collection],
        )
    }

    pub fn delete(&self, id: &str) -> Result<(), CoreError> {
        self.conn()
            .execute("DELETE FROM clips WHERE id = ?1", params![id])?;
        Ok(())
    }

    /// Removes the history. Pinned items and snippets can be kept. Removed content is overwritten on disk.
    pub fn clear(&self, keep_pinned: bool, keep_snippets: bool) -> Result<u32, CoreError> {
        let conn = self.conn();
        let removed = conn.execute(
            "DELETE FROM clips WHERE (pinned = 0 OR ?1 = 0) AND (favorite = 0 OR ?2 = 0)",
            params![i64::from(keep_pinned), i64::from(keep_snippets)],
        )?;
        let _ = conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE); VACUUM;");
        Ok(removed as u32)
    }

    fn change(&self, _id: &str, sql: &str, args: impl rusqlite::Params) -> Result<(), CoreError> {
        if self.conn().execute(sql, args)? == 0 {
            return Err(CoreError::NotFound);
        }
        Ok(())
    }

    // ---- snippets ---------------------------------------------------------------------------------------------

    /// Creates a snippet from text. If the same text is already in the history it becomes the snippet.
    pub fn add_snippet(
        &self,
        title: Option<String>,
        text: &str,
        collection: Option<String>,
        now: i64,
    ) -> Result<String, CoreError> {
        let title = clean_title(title)?;
        if text.trim().is_empty() {
            return Err(CoreError::invalid("a snippet needs some text"));
        }
        if text.len() > MAX_SNIPPET_BYTES {
            return Err(CoreError::invalid("the snippet is too long"));
        }
        let new = NewClip {
            text: Some(text.to_string()),
            ..NewClip::default()
        };
        let hash = content_hash(&new);
        let conn = self.conn();
        if let Some(c) = &collection {
            let exists: Option<i64> = conn
                .query_row("SELECT 1 FROM collections WHERE id = ?1", params![c], |r| {
                    r.get(0)
                })
                .optional()?;
            if exists.is_none() {
                return Err(CoreError::invalid("that collection no longer exists"));
            }
        }
        let existing: Option<String> = conn
            .query_row("SELECT id FROM clips WHERE hash = ?1", params![hash], |r| {
                r.get(0)
            })
            .optional()?;
        if let Some(id) = existing {
            conn.execute("UPDATE clips SET favorite = 1, title = COALESCE(?2, title), collection_id = COALESCE(?3, collection_id) WHERE id = ?1", params![id, title, collection])?;
            return Ok(id);
        }
        let kind = new.kind().unwrap_or(ClipKind::Text);
        let id = new_id(&hash, now);
        let tx = conn.unchecked_transaction()?;
        tx.execute(
            "INSERT INTO clips (id, kind, preview, title, source_app, created_at, last_used_at, byte_size, files_json, has_rich, hash, search_text, favorite, collection_id)
             VALUES (?1, ?2, ?3, ?4, NULL, ?5, ?5, ?6, '[]', 0, ?7, ?8, 1, ?9)",
            params![id, kind.as_str(), make_preview(&new), title, now, text.len() as i64, hash, make_search_text(&new, None), collection],
        )?;
        tx.execute(
            "INSERT INTO clip_blobs (id, plain) VALUES (?1, ?2)",
            params![id, text],
        )?;
        tx.commit()?;
        Ok(id)
    }

    /// Edits a snippet's name and, for plain text, its text.
    pub fn update_snippet(
        &self,
        id: &str,
        title: Option<String>,
        text: Option<String>,
    ) -> Result<(), CoreError> {
        let title = clean_title(title)?;
        let conn = self.conn();
        let kind: Option<String> = conn
            .query_row("SELECT kind FROM clips WHERE id = ?1", params![id], |r| {
                r.get(0)
            })
            .optional()?;
        let Some(kind) = kind else {
            return Err(CoreError::NotFound);
        };
        let tx = conn.unchecked_transaction()?;
        tx.execute(
            "UPDATE clips SET title = ?2 WHERE id = ?1",
            params![id, title],
        )?;
        if let Some(text) = text {
            if !matches!(ClipKind::parse(&kind), Some(ClipKind::Text | ClipKind::Url)) {
                return Err(CoreError::invalid("only plain text can be edited"));
            }
            if text.trim().is_empty() || text.len() > MAX_SNIPPET_BYTES {
                return Err(CoreError::invalid(
                    "a snippet needs some text, and not too much",
                ));
            }
            let new = NewClip {
                text: Some(text.clone()),
                ..NewClip::default()
            };
            let hash = content_hash(&new);
            let clash: Option<String> = tx
                .query_row(
                    "SELECT id FROM clips WHERE hash = ?1 AND id != ?2",
                    params![hash, id],
                    |r| r.get(0),
                )
                .optional()?;
            if clash.is_some() {
                return Err(CoreError::invalid(
                    "another item already has exactly that text",
                ));
            }
            tx.execute(
                "UPDATE clips SET kind = ?2, preview = ?3, hash = ?4, search_text = ?5, byte_size = ?6 WHERE id = ?1",
                params![id, new.kind().unwrap_or(ClipKind::Text).as_str(), make_preview(&new), hash, make_search_text(&new, None), text.len() as i64],
            )?;
            tx.execute(
                "UPDATE clip_blobs SET plain = ?2 WHERE id = ?1",
                params![id, text],
            )?;
        }
        tx.commit()?;
        Ok(())
    }

    // ---- collections ------------------------------------------------------------------------------------------

    pub fn collections(&self) -> Result<Vec<ClipCollection>, CoreError> {
        let conn = self.conn();
        let mut stmt = conn.prepare(
            "SELECT c.id, c.name, (SELECT COUNT(*) FROM clips WHERE collection_id = c.id) FROM collections c ORDER BY c.sort_order, c.name COLLATE NOCASE",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok(ClipCollection {
                id: r.get(0)?,
                name: r.get(1)?,
                count: r.get::<_, i64>(2)? as u32,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    pub fn save_collection(&self, id: &str, name: &str) -> Result<(), CoreError> {
        let name = name.trim();
        if id.trim().is_empty() || name.is_empty() || name.chars().count() > 60 {
            return Err(CoreError::invalid(
                "a collection needs a name of up to 60 characters",
            ));
        }
        let conn = self.conn();
        let clash: Option<String> = conn
            .query_row(
                "SELECT id FROM collections WHERE name = ?1 AND id != ?2",
                params![name, id],
                |r| r.get(0),
            )
            .optional()?;
        if clash.is_some() {
            return Err(CoreError::invalid(
                "a collection with that name already exists",
            ));
        }
        conn.execute(
            "INSERT INTO collections (id, name, sort_order) VALUES (?1, ?2, COALESCE((SELECT MAX(sort_order) + 1 FROM collections), 0))
             ON CONFLICT(id) DO UPDATE SET name = excluded.name",
            params![id, name],
        )?;
        Ok(())
    }

    /// Removes a collection. Its items stay, just no longer in it.
    pub fn delete_collection(&self, id: &str) -> Result<(), CoreError> {
        self.conn()
            .execute("DELETE FROM collections WHERE id = ?1", params![id])?;
        Ok(())
    }

    // ---- cleanup ----------------------------------------------------------------------------------------------

    /// Applies the retention period, the item limit and the size limit. Pinned items and snippets are never removed.
    pub fn cleanup(&self, config: &ClipConfig, now: i64) -> Result<u32, CoreError> {
        let conn = self.conn();
        let mut removed = 0usize;
        if config.retention_days > 0 {
            let cutoff = now - i64::from(config.retention_days) * 86_400;
            removed += conn.execute(
                "DELETE FROM clips WHERE pinned = 0 AND favorite = 0 AND last_used_at < ?1",
                params![cutoff],
            )?;
        }
        removed += conn.execute(
            "DELETE FROM clips WHERE id IN (SELECT id FROM clips WHERE pinned = 0 AND favorite = 0 ORDER BY last_used_at DESC, id LIMIT -1 OFFSET ?1)",
            params![i64::from(config.max_items)],
        )?;
        let cap = config.max_total_bytes() as i64;
        loop {
            let total: i64 =
                conn.query_row("SELECT COALESCE(SUM(byte_size), 0) FROM clips", [], |r| {
                    r.get(0)
                })?;
            if total <= cap {
                break;
            }
            let dropped = conn.execute(
                "DELETE FROM clips WHERE id IN (SELECT id FROM clips WHERE pinned = 0 AND favorite = 0 ORDER BY last_used_at ASC, id LIMIT 10)",
                [],
            )?;
            if dropped == 0 {
                break;
            }
            removed += dropped;
        }
        Ok(removed as u32)
    }

    // ---- sharing snippets -------------------------------------------------------------------------------------

    /// The chosen snippets as a file's text. Only plain text is exported; images and files stay on this Mac.
    pub fn export_snippets(&self, ids: &[String]) -> Result<String, CoreError> {
        let conn = self.conn();
        let mut snippets = Vec::new();
        let mut collection_names: Vec<String> = Vec::new();
        for id in ids {
            let row: Option<SnippetRow> = conn
                .query_row(
                    "SELECT c.title, b.plain, (SELECT name FROM collections WHERE id = c.collection_id), c.kind FROM clips c JOIN clip_blobs b ON b.id = c.id WHERE c.id = ?1",
                    params![id],
                    |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
                )
                .optional()?;
            let Some((title, Some(text), collection, _)) = row else {
                continue;
            };
            let mut stmt =
                conn.prepare("SELECT tag FROM clip_tags WHERE clip_id = ?1 ORDER BY tag")?;
            let tags = stmt
                .query_map(params![id], |r| r.get::<_, String>(0))?
                .collect::<Result<Vec<_>, _>>()?;
            if let Some(name) = &collection {
                if !collection_names.contains(name) {
                    collection_names.push(name.clone());
                }
            }
            snippets.push(SnippetEntry {
                title,
                text,
                tags,
                collection,
            });
        }
        let file = SnippetFile {
            format_version: 1,
            app: crate::backup::BACKUP_APP_NAME.to_string(),
            kind: SNIPPET_FILE_KIND.to_string(),
            collections: collection_names,
            snippets,
        };
        Ok(serde_json::to_string_pretty(&file)?)
    }

    /// Adds snippets from a file. Text already saved is not duplicated; collections are created by name when missing.
    pub fn import_snippets(&self, json: &str, now: i64) -> Result<SnippetImportSummary, CoreError> {
        let not_ours = || CoreError::Backup {
            message: "the file is not a Kriya snippet file".into(),
        };
        if json.len() > MAX_IMPORT_BYTES {
            return Err(not_ours());
        }
        let file: SnippetFile = serde_json::from_str(json).map_err(|_| not_ours())?;
        if file.app != crate::backup::BACKUP_APP_NAME || file.kind != SNIPPET_FILE_KIND {
            return Err(not_ours());
        }
        if file.format_version > 1 {
            return Err(CoreError::Backup {
                message: "the file was made by a newer version of Kriya".into(),
            });
        }
        if file.snippets.len() > MAX_IMPORT_SNIPPETS {
            return Err(CoreError::Backup {
                message: "the file holds too many snippets".into(),
            });
        }
        let mut summary = SnippetImportSummary {
            added: 0,
            updated: 0,
            skipped: 0,
        };
        for (i, entry) in file.snippets.iter().enumerate() {
            if entry.text.trim().is_empty() || entry.text.len() > MAX_SNIPPET_BYTES {
                summary.skipped += 1;
                continue;
            }
            let collection_id = match entry
                .collection
                .as_deref()
                .map(str::trim)
                .filter(|n| !n.is_empty())
            {
                Some(name) => {
                    let existing = self
                        .collections()?
                        .into_iter()
                        .find(|c| c.name.eq_ignore_ascii_case(name));
                    match existing {
                        Some(c) => Some(c.id),
                        None => {
                            let id = format!("col-{now}-{i}");
                            self.save_collection(&id, name)?;
                            Some(id)
                        }
                    }
                }
                None => None,
            };
            let hash = content_hash(&NewClip {
                text: Some(entry.text.clone()),
                ..NewClip::default()
            });
            let was_there: Option<i64> = self
                .conn()
                .query_row(
                    "SELECT favorite FROM clips WHERE hash = ?1",
                    params![hash],
                    |r| r.get(0),
                )
                .optional()?;
            let id = self.add_snippet(entry.title.clone(), &entry.text, collection_id, now)?;
            self.set_tags(&id, &entry.tags)?;
            match was_there {
                None => summary.added += 1,
                Some(_) => summary.updated += 1,
            }
        }
        Ok(summary)
    }
}

// ---- helpers ------------------------------------------------------------------------------------------------------

fn new_id(hash: &str, now: i64) -> String {
    format!("{now:x}-{}", &hash[..16])
}

fn escape_like(word: &str) -> String {
    word.replace('\\', "\\\\")
        .replace('%', "\\%")
        .replace('_', "\\_")
}

fn clean_title(title: Option<String>) -> Result<Option<String>, CoreError> {
    let Some(t) = title else { return Ok(None) };
    let t = t.trim();
    if t.is_empty() {
        return Ok(None);
    }
    if t.chars().count() > MAX_TITLE_CHARS {
        return Err(CoreError::invalid(format!(
            "a name can be up to {MAX_TITLE_CHARS} characters"
        )));
    }
    Ok(Some(t.to_string()))
}

fn item_from_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<ClipItem> {
    let kind: String = r.get(1)?;
    let files_json: String = r.get(14)?;
    Ok(ClipItem {
        id: r.get(0)?,
        kind: ClipKind::parse(&kind).unwrap_or(ClipKind::Text),
        preview: r.get(2)?,
        title: r.get(3)?,
        source_app: r.get(4)?,
        created_at: r.get(5)?,
        last_used_at: r.get(6)?,
        use_count: r.get::<_, i64>(7)?.max(0) as u32,
        pinned: r.get::<_, i64>(8)? != 0,
        favorite: r.get::<_, i64>(9)? != 0,
        collection_id: r.get(10)?,
        tags: Vec::new(),
        byte_size: r.get::<_, i64>(11)?.max(0) as u64,
        image_width: r.get(12)?,
        image_height: r.get(13)?,
        files: serde_json::from_str(&files_json).unwrap_or_default(),
        has_rich: r.get::<_, i64>(15)? != 0,
    })
}

fn attach_tags(conn: &Connection, items: &mut [ClipItem]) -> Result<(), CoreError> {
    if items.is_empty() {
        return Ok(());
    }
    let sql = format!(
        "SELECT clip_id, tag FROM clip_tags WHERE clip_id IN ({}) ORDER BY tag",
        vec!["?"; items.len()].join(", ")
    );
    let mut stmt = conn.prepare(&sql)?;
    let ids: Vec<&String> = items.iter().map(|i| &i.id).collect();
    let rows = stmt.query_map(params_from_iter(ids), |r| {
        Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
    })?;
    let mut by_id: std::collections::HashMap<String, Vec<String>> =
        std::collections::HashMap::new();
    for row in rows {
        let (id, tag) = row?;
        by_id.entry(id).or_default().push(tag);
    }
    for item in items {
        item.tags = by_id.remove(&item.id).unwrap_or_default();
    }
    Ok(())
}

// ---- the clipboard settings live with the other settings ----------------------------------------------------------------

impl Store {
    pub fn clip_config(&self) -> Result<ClipConfig, CoreError> {
        read_clip_config(&self.conn())
    }

    pub fn save_clip_config(&self, config: &ClipConfig) -> Result<(), CoreError> {
        if let Some(problem) = config.shortcut_problem() {
            return Err(CoreError::invalid(problem));
        }
        write_clip_config(&self.conn(), &config.clone().sanitized())
    }
}

pub(crate) fn write_clip_config(conn: &Connection, config: &ClipConfig) -> Result<(), CoreError> {
    conn.execute(
        "INSERT INTO settings (key, value) VALUES ('clip_config', ?1) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![serde_json::to_string(config)?],
    )?;
    Ok(())
}

pub(crate) fn read_clip_config(conn: &Connection) -> Result<ClipConfig, CoreError> {
    let json: Option<String> = conn
        .query_row(
            "SELECT value FROM settings WHERE key = 'clip_config'",
            [],
            |r| r.get(0),
        )
        .optional()?;
    Ok(json
        .and_then(|j| serde_json::from_str::<ClipConfig>(&j).ok())
        .unwrap_or_default()
        .sanitized())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store() -> ClipStore {
        ClipStore::open_in_memory().unwrap()
    }

    fn text(s: &str) -> NewClip {
        NewClip {
            text: Some(s.to_string()),
            source_app: Some("com.apple.TextEdit".into()),
            ..NewClip::default()
        }
    }

    fn cfg() -> ClipConfig {
        ClipConfig::default()
    }

    fn all(store: &ClipStore) -> Vec<ClipItem> {
        store.search("", &ClipFilter::default(), 1000).unwrap()
    }

    #[test]
    fn copies_are_recorded_and_duplicates_move_to_the_top() {
        let s = store();
        let a = s.record(text("first"), 100, &cfg()).unwrap();
        s.record(text("second"), 200, &cfg()).unwrap();
        assert_eq!(a.status, ClipRecordStatus::Stored);
        assert_eq!(all(&s)[0].preview, "second");
        let again = s.record(text("first"), 300, &cfg()).unwrap();
        assert_eq!(again.status, ClipRecordStatus::Duplicate);
        assert_eq!(again.id, a.id);
        let items = all(&s);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].preview, "first");
        assert_eq!(items[0].use_count, 2);
    }

    #[test]
    fn skipped_copies_leave_no_trace() {
        let s = store();
        let secret = s.record(text("4111111111111111"), 1, &cfg()).unwrap();
        assert_eq!(secret.skipped, Some(ClipSkipReason::LooksSensitive));
        let hidden = s
            .record(
                NewClip {
                    concealed: true,
                    ..text("hunter2!")
                },
                2,
                &cfg(),
            )
            .unwrap();
        assert_eq!(hidden.skipped, Some(ClipSkipReason::Concealed));
        let paused = s
            .record(
                text("hello"),
                3,
                &ClipConfig {
                    paused: true,
                    ..cfg()
                },
            )
            .unwrap();
        assert_eq!(paused.status, ClipRecordStatus::Skipped);
        assert!(all(&s).is_empty());
        let conn = s.conn();
        let blobs: i64 = conn
            .query_row("SELECT COUNT(*) FROM clip_blobs", [], |r| r.get(0))
            .unwrap();
        assert_eq!(blobs, 0);
    }

    #[test]
    fn every_kind_is_stored_and_read_back() {
        let s = store();
        let rich = NewClip {
            rich: Some(b"{\\rtf1 hi}".to_vec()),
            rich_format: Some("rtf".into()),
            ..text("hi")
        };
        let rich_id = s.record(rich, 1, &cfg()).unwrap().id.unwrap();
        let image = NewClip {
            image: Some(vec![1, 2, 3]),
            image_format: Some("png".into()),
            image_width: Some(10),
            image_height: Some(20),
            ..NewClip::default()
        };
        let image_id = s.record(image, 2, &cfg()).unwrap().id.unwrap();
        let files = NewClip {
            files: vec!["/a/x.pdf".into(), "/a/y.txt".into()],
            ..NewClip::default()
        };
        let files_id = s.record(files, 3, &cfg()).unwrap().id.unwrap();
        let url_id = s
            .record(text("https://example.com"), 4, &cfg())
            .unwrap()
            .id
            .unwrap();

        let rich_item = s.item(&rich_id).unwrap().unwrap();
        assert_eq!(
            (rich_item.kind, rich_item.has_rich),
            (ClipKind::RichText, true)
        );
        assert_eq!(
            s.blob(&rich_id).unwrap().unwrap().rich_format.as_deref(),
            Some("rtf")
        );
        let image_item = s.item(&image_id).unwrap().unwrap();
        assert_eq!(
            (
                image_item.kind,
                image_item.image_width,
                image_item.image_height
            ),
            (ClipKind::Image, Some(10), Some(20))
        );
        assert_eq!(
            s.blob(&image_id).unwrap().unwrap().image,
            Some(vec![1, 2, 3])
        );
        assert_eq!(s.item(&files_id).unwrap().unwrap().files.len(), 2);
        assert_eq!(s.item(&url_id).unwrap().unwrap().kind, ClipKind::Url);
        assert_eq!(
            s.blob(&url_id).unwrap().unwrap().plain.as_deref(),
            Some("https://example.com")
        );
    }

    #[test]
    fn rich_formatting_can_be_turned_off_and_the_text_is_kept() {
        let s = store();
        let rich = NewClip {
            rich: Some(vec![1]),
            rich_format: Some("rtf".into()),
            ..text("plain words")
        };
        let id = s
            .record(
                rich,
                1,
                &ClipConfig {
                    capture_rich_text: false,
                    ..cfg()
                },
            )
            .unwrap()
            .id
            .unwrap();
        let item = s.item(&id).unwrap().unwrap();
        assert_eq!((item.kind, item.has_rich), (ClipKind::Text, false));
    }

    #[test]
    fn search_finds_words_anywhere_and_respects_filters() {
        let s = store();
        s.record(text("Quarterly budget report"), 1, &cfg())
            .unwrap();
        s.record(text("Holiday photos list"), 2, &cfg()).unwrap();
        let url = s
            .record(text("https://example.com/budget"), 3, &cfg())
            .unwrap()
            .id
            .unwrap();
        let hits = |q: &str, f: &ClipFilter| s.search(q, f, 50).unwrap().len();
        assert_eq!(hits("budget", &ClipFilter::default()), 2);
        assert_eq!(
            hits("BUDGET report", &ClipFilter::default()),
            1,
            "all words must match, in any case"
        );
        assert_eq!(
            hits(
                "budget",
                &ClipFilter {
                    kinds: vec![ClipKind::Url],
                    ..ClipFilter::default()
                }
            ),
            1
        );
        assert_eq!(
            hits("100%", &ClipFilter::default()),
            0,
            "wildcards in a search are plain characters"
        );
        assert_eq!(hits("under_score", &ClipFilter::default()), 0);
        s.set_tags(&url, &["Work".into()]).unwrap();
        assert_eq!(hits("work", &ClipFilter::default()), 1, "tags are searched");
        assert_eq!(
            hits(
                "",
                &ClipFilter {
                    tag: Some("work".into()),
                    ..ClipFilter::default()
                }
            ),
            1
        );
        assert_eq!(
            s.item(&url).unwrap().unwrap().tags,
            vec!["work".to_string()]
        );
        assert_eq!(s.all_tags().unwrap(), vec!["work".to_string()]);
    }

    #[test]
    fn pinned_items_sort_first_and_survive_cleanup_and_clearing() {
        let s = store();
        let old = s
            .record(text("old but pinned"), 1, &cfg())
            .unwrap()
            .id
            .unwrap();
        s.record(text("newer"), 1_000_000, &cfg()).unwrap();
        s.set_pinned(&old, true).unwrap();
        assert_eq!(all(&s)[0].id, old);
        let config = ClipConfig {
            retention_days: 1,
            ..cfg()
        };
        s.cleanup(&config, 1_000_000 + 10 * 86_400).unwrap();
        assert_eq!(
            all(&s)
                .iter()
                .map(|i| i.preview.as_str())
                .collect::<Vec<_>>(),
            ["old but pinned"]
        );
        assert_eq!(s.clear(true, true).unwrap(), 0);
        assert_eq!(s.clear(false, true).unwrap(), 1);
        assert!(all(&s).is_empty());
    }

    #[test]
    fn retention_and_item_limits_remove_the_oldest_first() {
        let s = store();
        for i in 0..30 {
            s.record(text(&format!("item number {i}")), 1000 + i, &cfg())
                .unwrap();
        }
        let tight = ClipConfig {
            max_items: 20,
            ..cfg()
        };
        s.cleanup(&tight, 2000).unwrap();
        let items = all(&s);
        assert_eq!(items.len(), 20);
        assert_eq!(items[0].preview, "item number 29");
        assert!(!items.iter().any(|i| i.preview == "item number 0"));
        let expired = ClipConfig {
            retention_days: 1,
            ..cfg()
        };
        assert_eq!(s.cleanup(&expired, 1000 + 5 * 86_400).unwrap(), 20);
    }

    #[test]
    fn the_size_limit_drops_old_unprotected_items_only() {
        let s = store();
        let keep = s
            .record(
                NewClip {
                    image: Some(vec![200; 600_000]),
                    ..NewClip::default()
                },
                1,
                &cfg(),
            )
            .unwrap()
            .id
            .unwrap();
        s.set_pinned(&keep, true).unwrap();
        for i in 0..40u8 {
            s.record(
                NewClip {
                    image: Some(vec![i; 600_000]),
                    ..NewClip::default()
                },
                10 + i64::from(i),
                &cfg(),
            )
            .unwrap();
        }
        assert!(s.stats().unwrap().bytes > 16 * 1024 * 1024);
        let tight = ClipConfig {
            max_total_mb: 16,
            ..cfg()
        }
        .sanitized();
        s.cleanup(&tight, 100).unwrap();
        assert!(s.stats().unwrap().bytes <= 16 * 1024 * 1024);
        assert!(
            s.item(&keep).unwrap().is_some(),
            "a pinned item is never dropped for space"
        );
        let newest = s.search("", &ClipFilter::default(), 3).unwrap();
        assert_eq!(newest.len(), 3, "the newest are what remains");
    }

    #[test]
    fn snippets_are_kept_named_and_editable() {
        let s = store();
        let id = s
            .add_snippet(Some("Signature".into()), "Best regards,\nMe", None, 5)
            .unwrap();
        let item = s.item(&id).unwrap().unwrap();
        assert!(item.favorite);
        assert_eq!(item.title.as_deref(), Some("Signature"));
        assert_eq!(
            s.search("signature", &ClipFilter::default(), 5)
                .unwrap()
                .len(),
            1,
            "found by its name"
        );
        assert_eq!(
            s.search(
                "",
                &ClipFilter {
                    favorites_only: true,
                    ..ClipFilter::default()
                },
                5
            )
            .unwrap()
            .len(),
            1
        );
        s.update_snippet(
            &id,
            Some("Sign-off".into()),
            Some("Kind regards,\nMe".into()),
        )
        .unwrap();
        assert_eq!(
            s.blob(&id).unwrap().unwrap().plain.as_deref(),
            Some("Kind regards,\nMe")
        );
        assert!(s.add_snippet(None, "  ", None, 6).is_err());
        s.cleanup(
            &ClipConfig {
                retention_days: 1,
                ..cfg()
            },
            5 + 100 * 86_400,
        )
        .unwrap();
        assert!(
            s.item(&id).unwrap().is_some(),
            "snippets are never cleaned up"
        );
    }

    #[test]
    fn an_existing_copy_can_become_a_snippet_and_clashes_are_refused() {
        let s = store();
        let id = s.record(text("keep me"), 1, &cfg()).unwrap().id.unwrap();
        s.set_favorite(&id, true, Some("Keeper".into())).unwrap();
        assert!(s.item(&id).unwrap().unwrap().favorite);
        assert_eq!(
            s.add_snippet(None, "keep me", None, 2).unwrap(),
            id,
            "the same text is not stored twice"
        );
        let other = s.add_snippet(None, "other text", None, 3).unwrap();
        assert!(s
            .update_snippet(&other, None, Some("keep me".into()))
            .is_err());
        assert!(s.set_favorite("missing", true, None).is_err());
    }

    #[test]
    fn collections_hold_items_and_deleting_one_keeps_them() {
        let s = store();
        s.save_collection("c1", "Work").unwrap();
        assert!(
            s.save_collection("c2", "work").is_err(),
            "names are unique, ignoring case"
        );
        let id = s
            .record(text("in a collection"), 1, &cfg())
            .unwrap()
            .id
            .unwrap();
        s.set_collection(&id, Some("c1".into())).unwrap();
        assert_eq!(s.collections().unwrap()[0].count, 1);
        let filter = ClipFilter {
            collection_id: Some("c1".into()),
            ..ClipFilter::default()
        };
        assert_eq!(s.search("", &filter, 10).unwrap().len(), 1);
        assert!(s.set_collection(&id, Some("nope".into())).is_err());
        s.delete_collection("c1").unwrap();
        assert!(s.item(&id).unwrap().unwrap().collection_id.is_none());
    }

    #[test]
    fn deleting_an_item_removes_its_content_and_tags() {
        let s = store();
        let id = s
            .record(text("to be removed"), 1, &cfg())
            .unwrap()
            .id
            .unwrap();
        s.set_tags(&id, &["a".into()]).unwrap();
        s.delete(&id).unwrap();
        let conn = s.conn();
        for table in ["clips", "clip_blobs", "clip_tags"] {
            let n: i64 = conn
                .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get(0))
                .unwrap();
            assert_eq!(n, 0, "{table} should be empty");
        }
    }

    #[test]
    fn snippets_export_and_import_without_duplicates() {
        let source = store();
        source.save_collection("c", "Email").unwrap();
        let a = source
            .add_snippet(Some("Greeting".into()), "Hello there", Some("c".into()), 1)
            .unwrap();
        source.set_tags(&a, &["mail".into()]).unwrap();
        let image = source
            .record(
                NewClip {
                    image: Some(vec![1]),
                    ..NewClip::default()
                },
                2,
                &cfg(),
            )
            .unwrap()
            .id
            .unwrap();
        let json = source.export_snippets(&[a.clone(), image]).unwrap();
        assert!(!json.contains("\"image\""), "images are not exported");

        let target = store();
        let summary = target.import_snippets(&json, 10).unwrap();
        assert_eq!((summary.added, summary.updated, summary.skipped), (1, 0, 0));
        let imported = target.search("hello", &ClipFilter::default(), 5).unwrap();
        assert_eq!(imported.len(), 1);
        assert!(imported[0].favorite && imported[0].tags == vec!["mail".to_string()]);
        assert_eq!(target.collections().unwrap()[0].name, "Email");
        let again = target.import_snippets(&json, 11).unwrap();
        assert_eq!((again.added, again.updated), (0, 1));
        assert_eq!(
            target.search("", &ClipFilter::default(), 50).unwrap().len(),
            1
        );
        assert!(target.import_snippets("{}", 12).is_err());
        assert!(target
            .import_snippets(&json.replace("clip_snippets", "other"), 12)
            .is_err());
    }

    #[test]
    fn a_damaged_file_is_set_aside_and_a_fresh_one_started() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            dir.path().join("clipboard.sqlite"),
            b"definitely not a database, just some text here",
        )
        .unwrap();
        let s = ClipStore::open(dir.path(), 9).unwrap();
        assert!(s.recovered_from_corruption && !s.ephemeral);
        assert!(dir.path().join("clipboard.corrupt-9.sqlite").exists());
        s.record(text("works"), 1, &cfg()).unwrap();
    }

    #[test]
    fn history_persists_between_opens_in_a_private_file() {
        let dir = tempfile::tempdir().unwrap();
        {
            let s = ClipStore::open(dir.path(), 1).unwrap();
            s.record(text("remember me"), 1, &cfg()).unwrap();
        }
        let s = ClipStore::open(dir.path(), 2).unwrap();
        assert_eq!(all(&s).len(), 1);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(dir.path().join("clipboard.sqlite"))
                .unwrap()
                .permissions()
                .mode();
            assert_eq!(mode & 0o077, 0, "only the owner can read the history");
        }
    }

    #[test]
    fn settings_persist_and_clashing_shortcuts_are_refused() {
        let main = Store::open_in_memory().unwrap();
        assert_eq!(main.clip_config().unwrap(), ClipConfig::default());
        main.save_clip_config(&ClipConfig {
            max_items: 100,
            paused: true,
            ..ClipConfig::default()
        })
        .unwrap();
        let c = main.clip_config().unwrap();
        assert_eq!((c.max_items, c.paused), (100, true));
        let clash = ClipConfig {
            plain_key: Some(9),
            plain_modifiers: crate::actions::modifiers::CONTROL | crate::actions::modifiers::OPTION,
            ..ClipConfig::default()
        };
        assert!(main.save_clip_config(&clash).is_err());
    }

    #[test]
    fn stats_describe_the_history() {
        let s = store();
        assert_eq!(s.stats().unwrap().items, 0);
        let id = s.record(text("abc"), 5, &cfg()).unwrap().id.unwrap();
        s.set_pinned(&id, true).unwrap();
        let st = s.stats().unwrap();
        assert_eq!((st.items, st.pinned, st.oldest), (1, 1, Some(5)));
        assert_eq!(st.bytes, 3);
    }
}
