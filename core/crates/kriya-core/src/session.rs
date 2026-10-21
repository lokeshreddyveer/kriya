//! Crash recovery and safe mode. The shell reports when it starts, starts a feature, and quits cleanly; the next
//! launch can tell that a run ended unexpectedly, which feature it was starting, and whether crashes are repeating.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

use crate::model::FeatureId;

/// Three unexpected exits inside half an hour put the app in safe mode.
pub const CRASH_WINDOW_SECS: i64 = 30 * 60;
pub const CRASH_THRESHOLD: usize = 3;

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct SessionRecord {
    pub launched_at: i64,
    pub clean_exit: bool,
    pub was_debugged: bool,
    pub starting_feature: Option<FeatureId>,
    pub recent_crashes: Vec<i64>,
    pub safe_mode: bool,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SessionOutcome {
    pub safe_mode: bool,
    pub safe_mode_reason: Option<String>,
    /// The feature that was starting when the previous run ended unexpectedly.
    pub suspect_feature: Option<FeatureId>,
    pub previous_session_crashed: bool,
}

/// Decides the outcome of a launch from the previous run's record. Pure, so it is easy to test.
pub fn begin_session(
    previous: Option<&SessionRecord>,
    now: i64,
    debugger_attached: bool,
    force_safe_mode: bool,
) -> (SessionRecord, SessionOutcome) {
    // A run stopped from a debugger is not a crash.
    let crashed = previous.is_some_and(|p| !p.clean_exit && !p.was_debugged);
    let mut crashes: Vec<i64> = previous
        .map(|p| {
            p.recent_crashes
                .iter()
                .copied()
                .filter(|t| now - *t < CRASH_WINDOW_SECS)
                .collect()
        })
        .unwrap_or_default();
    if crashed {
        crashes.push(now);
    }
    let suspect = if crashed {
        previous.and_then(|p| p.starting_feature)
    } else {
        None
    };

    let repeated = crashes.len() >= CRASH_THRESHOLD;
    let safe_mode = force_safe_mode || repeated;
    let reason = if force_safe_mode {
        Some("Started in safe mode on request.".to_string())
    } else if repeated {
        Some(format!(
            "Kriya quit unexpectedly {} times in a short time, so features were switched off.",
            crashes.len()
        ))
    } else {
        None
    };
    if safe_mode {
        crashes.clear();
    }

    let record = SessionRecord {
        launched_at: now,
        clean_exit: false,
        was_debugged: debugger_attached,
        starting_feature: None,
        recent_crashes: crashes,
        safe_mode,
    };
    let outcome = SessionOutcome {
        safe_mode,
        safe_mode_reason: reason,
        suspect_feature: suspect,
        previous_session_crashed: crashed,
    };
    (record, outcome)
}

/// Keeps the session record in a small file, rewritten whenever it changes.
pub struct SessionGuard {
    path: PathBuf,
    record: Mutex<SessionRecord>,
}

impl SessionGuard {
    pub fn new(path: PathBuf) -> Self {
        SessionGuard {
            path,
            record: Mutex::new(SessionRecord::default()),
        }
    }

    pub fn begin(
        &self,
        now: i64,
        debugger_attached: bool,
        force_safe_mode: bool,
    ) -> SessionOutcome {
        let previous = read_record(&self.path);
        let (record, outcome) =
            begin_session(previous.as_ref(), now, debugger_attached, force_safe_mode);
        self.update(|r| *r = record);
        outcome
    }

    pub fn mark_starting(&self, feature: FeatureId) {
        self.update(|r| r.starting_feature = Some(feature));
    }

    pub fn mark_started(&self) {
        self.update(|r| r.starting_feature = None);
    }

    pub fn end(&self) {
        self.update(|r| {
            r.clean_exit = true;
            r.starting_feature = None;
        });
    }

    pub fn leave_safe_mode(&self) {
        self.update(|r| {
            r.safe_mode = false;
            r.recent_crashes.clear();
        });
    }

    fn update(&self, change: impl FnOnce(&mut SessionRecord)) {
        let mut guard = self.record.lock().unwrap_or_else(|e| e.into_inner());
        change(&mut guard);
        write_record(&self.path, &guard);
    }
}

fn read_record(path: &Path) -> Option<SessionRecord> {
    let text = fs::read_to_string(path).ok()?;
    serde_json::from_str(&text).ok()
}

/// Best effort: a failed write only means the next launch cannot tell this run crashed.
fn write_record(path: &Path, record: &SessionRecord) {
    let Ok(json) = serde_json::to_string(record) else {
        return;
    };
    let tmp = path.with_extension("tmp");
    if fs::write(&tmp, json).is_ok() && fs::rename(&tmp, path).is_err() {
        let _ = fs::remove_file(&tmp);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn crashed_record(now: i64, feature: Option<FeatureId>, crashes: Vec<i64>) -> SessionRecord {
        SessionRecord {
            launched_at: now - 10,
            clean_exit: false,
            was_debugged: false,
            starting_feature: feature,
            recent_crashes: crashes,
            safe_mode: false,
        }
    }

    #[test]
    fn first_launch_is_normal() {
        let (record, outcome) = begin_session(None, 1000, false, false);
        assert!(!outcome.safe_mode && !outcome.previous_session_crashed);
        assert!(!record.clean_exit);
    }

    #[test]
    fn clean_exit_is_not_a_crash() {
        let mut prev = crashed_record(1000, None, vec![]);
        prev.clean_exit = true;
        let (_, outcome) = begin_session(Some(&prev), 1000, false, false);
        assert!(!outcome.previous_session_crashed);
    }

    #[test]
    fn crash_names_the_feature_that_was_starting() {
        let prev = crashed_record(1000, Some(FeatureId::Mouse), vec![]);
        let (record, outcome) = begin_session(Some(&prev), 1000, false, false);
        assert_eq!(outcome.suspect_feature, Some(FeatureId::Mouse));
        assert_eq!(record.recent_crashes.len(), 1);
        assert!(!outcome.safe_mode);
    }

    #[test]
    fn repeated_crashes_enter_safe_mode_and_reset_the_count() {
        let prev = crashed_record(5000, None, vec![4000, 4500]);
        let (record, outcome) = begin_session(Some(&prev), 5000, false, false);
        assert!(outcome.safe_mode);
        assert!(record.safe_mode && record.recent_crashes.is_empty());
    }

    #[test]
    fn old_crashes_expire() {
        let prev = crashed_record(10_000, None, vec![1, 2]);
        let (_, outcome) = begin_session(Some(&prev), 10_000, false, false);
        assert!(!outcome.safe_mode);
    }

    #[test]
    fn debugger_stop_is_not_a_crash() {
        let mut prev = crashed_record(1000, Some(FeatureId::Mouse), vec![]);
        prev.was_debugged = true;
        let (_, outcome) = begin_session(Some(&prev), 1000, false, false);
        assert!(!outcome.previous_session_crashed && outcome.suspect_feature.is_none());
    }

    #[test]
    fn forced_safe_mode_is_honoured() {
        let (_, outcome) = begin_session(None, 1000, false, true);
        assert!(outcome.safe_mode);
    }

    #[test]
    fn guard_persists_between_runs() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let first = SessionGuard::new(path.clone());
        first.begin(100, false, false);
        first.mark_starting(FeatureId::WindowManagement);
        // No `end()`: the run is treated as a crash.
        let second = SessionGuard::new(path);
        let outcome = second.begin(200, false, false);
        assert_eq!(outcome.suspect_feature, Some(FeatureId::WindowManagement));
    }
}
