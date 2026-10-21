//! The one error type that crosses into the native shells.

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    #[error("storage error: {message}")]
    Storage { message: String },
    #[error("{message}")]
    Invalid { message: String },
    #[error("backup could not be used: {message}")]
    Backup { message: String },
    #[error("not found")]
    NotFound,
    /// The database was written by a newer Kriya. It is left untouched so no data is lost by opening it with an older app.
    #[error("the saved data was created by a newer version of Kriya")]
    NewerDatabase,
}

impl CoreError {
    pub fn invalid(message: impl Into<String>) -> Self {
        CoreError::Invalid {
            message: message.into(),
        }
    }
}

impl From<rusqlite::Error> for CoreError {
    fn from(e: rusqlite::Error) -> Self {
        CoreError::Storage {
            message: e.to_string(),
        }
    }
}

impl From<serde_json::Error> for CoreError {
    fn from(e: serde_json::Error) -> Self {
        CoreError::Storage {
            message: e.to_string(),
        }
    }
}

impl From<std::io::Error> for CoreError {
    fn from(e: std::io::Error) -> Self {
        CoreError::Storage {
            message: e.to_string(),
        }
    }
}
