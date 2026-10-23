//! Turning a workflow described by an AI into a real workflow, safely.
//!
//! The model is asked for a small JSON shape (see `schema`) that can only name steps which need no authorization: it can show a
//! message, wait, copy text, keep a value, ask the person, open an address, open or bring forward an app. It cannot name a
//! script, a shell line, a key press or any step that controls the system. The result is a workflow that is switched off, has no
//! authorization and starts only by hand, and it goes through the same checks as any workflow before it is returned.

use serde::Deserialize;

use crate::actions::Action;
use crate::error::CoreError;
use crate::workflow::{check_variable_name, StepKind, Workflow, WorkflowStep, WorkflowTrigger};

const MAX_STEPS: usize = 20;
const MAX_TEXT: usize = 2000;
const MAX_DELAY_SECONDS: f64 = 60.0;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Draft {
    name: String,
    #[serde(default)]
    notes: Option<String>,
    steps: Vec<DraftStep>,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
enum DraftStep {
    Notify { message: String },
    Delay { seconds: f64 },
    CopyText { text: String },
    SetVariable { name: String, value: String },
    Confirm { message: String },
    Ask { prompt: String, variable: String },
    OpenUrl { url: String },
    OpenApp { app: String },
    ActivateApp { app: String },
}

/// The JSON schema the model is asked to follow.
pub fn schema() -> String {
    serde_json::json!({
        "type": "object",
        "additionalProperties": false,
        "required": ["name", "steps"],
        "properties": {
            "name": {"type": "string", "maxLength": 80},
            "notes": {"type": "string", "maxLength": 500},
            "steps": {
                "type": "array",
                "maxItems": MAX_STEPS,
                "items": {
                    "type": "object",
                    "required": ["type"],
                    "properties": {
                        "type": {"type": "string", "enum": ["notify", "delay", "copy_text", "set_variable", "confirm", "ask", "open_url", "open_app", "activate_app"]},
                        "message": {"type": "string", "maxLength": MAX_TEXT},
                        "seconds": {"type": "number", "minimum": 0, "maximum": MAX_DELAY_SECONDS},
                        "text": {"type": "string", "maxLength": MAX_TEXT},
                        "name": {"type": "string", "maxLength": 40},
                        "value": {"type": "string", "maxLength": MAX_TEXT},
                        "prompt": {"type": "string", "maxLength": MAX_TEXT},
                        "variable": {"type": "string", "maxLength": 40},
                        "url": {"type": "string", "maxLength": 2000},
                        "app": {"type": "string", "maxLength": 200}
                    }
                }
            }
        }
    })
    .to_string()
}

fn text(s: &str, what: &str) -> Result<String, CoreError> {
    let t = s.trim();
    if t.is_empty() || t.chars().count() > MAX_TEXT || t.contains('\0') {
        return Err(CoreError::invalid(format!(
            "{what} is empty or too long in the draft"
        )));
    }
    Ok(t.to_string())
}

fn app(s: &str) -> Result<String, CoreError> {
    let t = s.trim();
    let bundle_id = t
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-')
        && t.contains('.');
    let path = t.starts_with('/') && t.ends_with(".app") && !t.contains("..") && !t.contains('\0');
    if t.len() > 200 || !(bundle_id || path) {
        return Err(CoreError::invalid(
            "an app in a draft must be a bundle identifier such as com.apple.Safari, or the full path of an .app",
        ));
    }
    Ok(t.to_string())
}

fn url(s: &str) -> Result<String, CoreError> {
    let t = s.trim();
    let lower = t.to_ascii_lowercase();
    if t.len() > 2000
        || !(lower.starts_with("https://") || lower.starts_with("http://"))
        || t.chars().any(|c| c.is_control() || c == ' ')
    {
        return Err(CoreError::invalid(
            "a draft may only open web addresses that start with http:// or https://",
        ));
    }
    Ok(t.to_string())
}

fn step(kind: StepKind, label: Option<String>) -> WorkflowStep {
    let mut s = WorkflowStep::new("", kind);
    s.label = label;
    s
}

/// Reads a draft and builds the workflow it describes: switched off, started by hand, and not authorized.
pub fn from_draft(json: &str, id: String, now: i64) -> Result<Workflow, CoreError> {
    if json.len() > 100_000 {
        return Err(CoreError::invalid("the draft is too large"));
    }
    let draft: Draft = serde_json::from_str(json)
        .map_err(|_| CoreError::invalid("the draft is not in the expected shape"))?;
    if draft.steps.is_empty() || draft.steps.len() > MAX_STEPS {
        return Err(CoreError::invalid(format!(
            "a draft needs between 1 and {MAX_STEPS} steps"
        )));
    }
    let mut steps = Vec::new();
    for (i, s) in draft.steps.iter().enumerate() {
        let mut built = match s {
            DraftStep::Notify { message } => step(
                StepKind::Notify {
                    message: text(message, "a message")?,
                },
                None,
            ),
            DraftStep::Delay { seconds } => {
                if !seconds.is_finite() || *seconds < 0.0 || *seconds > MAX_DELAY_SECONDS {
                    return Err(CoreError::invalid(
                        "a wait must be between 0 and 60 seconds",
                    ));
                }
                step(
                    StepKind::Delay {
                        ms: (seconds * 1000.0).round() as u32,
                    },
                    None,
                )
            }
            DraftStep::CopyText { text: t } => step(
                StepKind::CopyText {
                    template: text(t, "text to copy")?,
                },
                None,
            ),
            DraftStep::SetVariable { name, value } => {
                check_variable_name(name)?;
                step(
                    StepKind::SetVariable {
                        name: name.clone(),
                        template: text(value, "a value")?,
                    },
                    None,
                )
            }
            DraftStep::Confirm { message } => step(
                StepKind::Confirm {
                    message: text(message, "a question")?,
                },
                None,
            ),
            DraftStep::Ask { prompt, variable } => {
                check_variable_name(variable)?;
                step(
                    StepKind::Ask {
                        prompt: text(prompt, "a prompt")?,
                        variable: variable.clone(),
                    },
                    None,
                )
            }
            DraftStep::OpenUrl { url: u } => step(
                StepKind::Action {
                    action: Action::OpenUrl { url: url(u)? },
                },
                None,
            ),
            DraftStep::OpenApp { app: a } => step(
                StepKind::Action {
                    action: Action::OpenApplication { target: app(a)? },
                },
                None,
            ),
            DraftStep::ActivateApp { app: a } => {
                step(StepKind::ActivateApp { app_id: app(a)? }, None)
            }
        };
        built.id = format!("s{}", i + 1);
        steps.push(built);
    }
    let workflow = Workflow {
        id,
        name: text(&draft.name, "the name")?.chars().take(80).collect(),
        notes: draft.notes.map(|n| n.chars().take(500).collect()),
        enabled: false,
        trigger: WorkflowTrigger::Manual,
        steps,
        created_at: now,
        updated_at: now,
        ..Workflow::default()
    };
    workflow.check()?;
    Ok(workflow)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::workflow::{needs_authorization, StepRisk};

    fn build(json: &str) -> Result<Workflow, CoreError> {
        from_draft(json, "w1".into(), 1000)
    }

    #[test]
    fn a_good_draft_becomes_a_switched_off_workflow_needing_no_authorization() {
        let w = build(
            r#"{"name":"Morning","notes":"Start the day","steps":[
            {"type":"open_url","url":"https://example.com/news"},
            {"type":"activate_app","app":"com.apple.Safari"},
            {"type":"delay","seconds":1.5},
            {"type":"set_variable","name":"who","value":"world"},
            {"type":"notify","message":"Hello {{who}}"},
            {"type":"confirm","message":"Go on?"},
            {"type":"ask","prompt":"Name?","variable":"name"},
            {"type":"copy_text","text":"done"},
            {"type":"open_app","app":"/Applications/Notes.app"}]}"#,
        )
        .unwrap();
        assert!(!w.enabled);
        assert_eq!(w.trigger, WorkflowTrigger::Manual);
        assert!(w.authorized_fingerprint.is_none());
        assert_eq!(w.steps.len(), 9);
        assert_eq!(w.steps[2].kind, StepKind::Delay { ms: 1500 });
        assert!(w.steps.iter().all(|s| s.kind.risk() == StepRisk::Safe));
        assert!(
            !needs_authorization(&w),
            "nothing in a draft needs authorization"
        );
        let ids: Vec<_> = w.steps.iter().map(|s| s.id.clone()).collect();
        assert_eq!(ids[0], "s1");
        assert_eq!(ids[8], "s9");
    }

    #[test]
    fn steps_that_run_code_or_press_keys_cannot_be_drafted() {
        for bad in [
            r#"{"type":"run_shell","script":"rm -rf ~"}"#,
            r#"{"type":"script","source":"do shell script"}"#,
            r#"{"type":"key_press","key_code":0}"#,
            r#"{"type":"java_script","source":"1"}"#,
            r#"{"type":"quit_app","app":"com.apple.finder"}"#,
            r#"{"type":"notify","message":"hi","script":"x"}"#,
        ] {
            let json = format!(r#"{{"name":"x","steps":[{bad}]}}"#);
            assert!(build(&json).is_err(), "{bad}");
        }
        assert!(
            build(r#"{"name":"x","steps":[{"type":"notify","message":"hi"}],"trigger":"hotkey"}"#)
                .is_err(),
            "no trigger or other settings"
        );
    }

    #[test]
    fn addresses_apps_names_and_sizes_are_checked() {
        let wrap = |s: &str| build(&format!(r#"{{"name":"x","steps":[{s}]}}"#));
        assert!(wrap(r#"{"type":"open_url","url":"javascript:alert(1)"}"#).is_err());
        assert!(wrap(r#"{"type":"open_url","url":"file:///etc/passwd"}"#).is_err());
        assert!(wrap(r#"{"type":"open_url","url":"https://a.com/x y"}"#).is_err());
        assert!(wrap(r#"{"type":"open_app","app":"/bin/sh"}"#).is_err());
        assert!(wrap(r#"{"type":"open_app","app":"../../Evil.app"}"#).is_err());
        assert!(wrap(r#"{"type":"activate_app","app":"notabundle"}"#).is_err());
        assert!(wrap(r#"{"type":"set_variable","name":"loop","value":"x"}"#).is_err());
        assert!(wrap(r#"{"type":"set_variable","name":"1bad","value":"x"}"#).is_err());
        assert!(wrap(r#"{"type":"delay","seconds":61}"#).is_err());
        assert!(wrap(r#"{"type":"delay","seconds":-1}"#).is_err());
        assert!(wrap(r#"{"type":"notify","message":"   "}"#).is_err());
        assert!(build(r#"{"name":"","steps":[{"type":"notify","message":"hi"}]}"#).is_err());
        assert!(build(r#"{"name":"x","steps":[]}"#).is_err());
        let many = format!(
            r#"{{"name":"x","steps":[{}]}}"#,
            vec![r#"{"type":"notify","message":"a"}"#; 21].join(",")
        );
        assert!(build(&many).is_err());
        assert!(build("not json").is_err());
        assert!(build(&" ".repeat(100_001)).is_err());
    }

    #[test]
    fn the_schema_is_valid_json_and_names_only_the_allowed_steps() {
        let v: serde_json::Value = serde_json::from_str(&schema()).unwrap();
        let allowed = v["properties"]["steps"]["items"]["properties"]["type"]["enum"]
            .as_array()
            .unwrap();
        assert_eq!(allowed.len(), 9);
        assert!(!allowed
            .iter()
            .any(|s| s == "run_shell" || s == "script" || s == "key_press"));
    }
}
