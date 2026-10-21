//! The action model every trigger runs: a click, a gesture, a hotkey, a menu item or a rule all end in an `Action`.
//! The core decides what an action means and whether it is allowed; each platform shell carries out the plain steps.

use serde::{Deserialize, Serialize};

use crate::error::CoreError;

/// Modifier bits used in `Action::KeyPress`. They are the core's own, so a saved action means the same on every
/// platform; each shell maps its native flags to and from these.
pub mod modifiers {
    pub const SHIFT: u64 = 1;
    pub const CONTROL: u64 = 1 << 1;
    pub const OPTION: u64 = 1 << 2;
    pub const COMMAND: u64 = 1 << 3;
    pub const FUNCTION: u64 = 1 << 4;
    pub const ALL: u64 = SHIFT | CONTROL | OPTION | COMMAND | FUNCTION;
}

pub const MAX_SEQUENCE_STEPS: usize = 50;
pub const MAX_SEQUENCE_DEPTH: usize = 4;
pub const MAX_PLAN_STEPS: usize = 200;
pub const MAX_DELAY_MS: u32 = 60_000;
const MAX_SHELL_LEN: usize = 10_000;
const MAX_SCRIPT_LEN: usize = 100_000;
const BLOCKED_URL_SCHEMES: [&str; 3] = ["javascript", "data", "vbscript"];

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum ScriptLanguage {
    AppleScript,
    PowerShell,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Action {
    /// Does nothing. Lets a trigger be set to "no action", for example to disable a button.
    Noop,
    KeyPress {
        key_code: u16,
        modifiers: u64,
    },
    /// A bundle identifier or an absolute path on macOS, an executable path on Windows.
    OpenApplication {
        target: String,
    },
    OpenUrl {
        url: String,
    },
    RunShell {
        script: String,
    },
    RunScript {
        language: ScriptLanguage,
        source: String,
    },
    RunShortcut {
        name: String,
    },
    /// A command a feature registers with the shell, such as `window.left_half`.
    Builtin {
        command: String,
    },
    Sequence {
        steps: Vec<Action>,
        delay_ms: u32,
    },
}

/// A saved, named action the person can pick for any trigger.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct NamedAction {
    pub id: String,
    pub name: String,
    pub action: Action,
}

/// Ready-made actions for the things a mouse button or gesture is most often set to. They use the keyboard shortcuts
/// macOS and browsers already have, so they work wherever those shortcuts are switched on. Ids are fixed so adding
/// them twice does nothing.
pub fn suggested_actions() -> Vec<NamedAction> {
    use modifiers::{COMMAND, CONTROL, SHIFT};
    let key = |id: &str, name: &str, key_code: u16, modifiers: u64| NamedAction {
        id: format!("suggested.{id}"),
        name: name.to_string(),
        action: Action::KeyPress {
            key_code,
            modifiers,
        },
    };
    let command = |id: &str, name: &str, command: &str| NamedAction {
        id: format!("suggested.{id}"),
        name: name.to_string(),
        action: Action::Builtin {
            command: command.to_string(),
        },
    };
    vec![
        key("back", "Back", 33, COMMAND),
        key("forward", "Forward", 30, COMMAND),
        key("mission-control", "Mission Control", 126, CONTROL),
        key("app-expose", "App Exposé", 125, CONTROL),
        key("previous-space", "Previous desktop", 123, CONTROL),
        key("next-space", "Next desktop", 124, CONTROL),
        key("show-desktop", "Show desktop", 103, 0),
        key("switch-app", "Switch app", 48, COMMAND),
        key("next-tab", "Next tab", 48, CONTROL),
        key("previous-tab", "Previous tab", 48, CONTROL | SHIFT),
        key("new-tab", "New tab", 17, COMMAND),
        key("close-tab", "Close tab", 13, COMMAND),
        key("reload", "Reload", 15, COMMAND),
        key("lock-screen", "Lock screen", 12, CONTROL | COMMAND),
        command("window-left", "Window: left half", "window.left_half"),
        command("window-right", "Window: right half", "window.right_half"),
        command("window-maximize", "Window: maximize", "window.maximize"),
        command(
            "window-next-display",
            "Window: next display",
            "window.next_display",
        ),
        command(
            "pointer-next-display",
            "Pointer: next display",
            "mouse.next_display",
        ),
        command(
            "pointer-previous-display",
            "Pointer: previous display",
            "mouse.previous_display",
        ),
        command("pointer-locate", "Find the pointer", "pointer.locate"),
        command(
            "pointer-magnifier",
            "Magnify around the pointer",
            "pointer.magnifier",
        ),
        command(
            "pointer-presentation",
            "Presentation mode (highlight and click rings)",
            "pointer.presentation",
        ),
        command("app-previous", "Switch to the previous app", "app.previous"),
        command("app-hide-all", "Hide all apps", "app.hide_all"),
        command("app-hide-others", "Hide other apps", "app.hide_others"),
        command("app-quit-all", "Quit all apps (asks first)", "app.quit_all"),
        command("app-relaunch", "Relaunch the front app", "app.relaunch"),
        command("focus-mode", "Turn focus mode on or off", "focus.toggle"),
        command(
            "window-cycle-here",
            "Cycle the windows under the pointer",
            "window.cycle_here",
        ),
        command(
            "window-other-display",
            "Focus a window on the next display",
            "window.focus_other_display",
        ),
        command(
            "window-restore-minimized",
            "Bring back a minimized window",
            "window.restore_minimized",
        ),
        command("pointer-menu", "Open the pointer menu", "menu.pointer"),
        command(
            "link-clipboard",
            "Choose a browser for the copied link",
            "link.route_clipboard",
        ),
        command("app-menu", "Open the app's menu at the pointer", "menu.app"),
        command(
            "keep-awake",
            "Keep the Mac awake (on or off)",
            "power.keep_awake",
        ),
        command(
            "keep-awake-1h",
            "Keep the Mac awake for an hour",
            "power.keep_awake.60",
        ),
        command(
            "keep-awake-off",
            "Let the Mac sleep again",
            "power.keep_awake_off",
        ),
    ]
}

/// One plain step a shell carries out, in order. Sequences are already flattened.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum ActionStep {
    Run { action: Action },
    Delay { ms: u32 },
}

/// Returns why an action cannot be run, or `Ok` when it is safe and complete.
pub fn validate(action: &Action) -> Result<(), CoreError> {
    validate_at(action, 0)
}

fn validate_at(action: &Action, depth: usize) -> Result<(), CoreError> {
    match action {
        Action::Noop => Ok(()),
        Action::KeyPress { modifiers, .. } => {
            if modifiers & !modifiers::ALL != 0 {
                return Err(CoreError::invalid(
                    "the key combination has unknown modifiers",
                ));
            }
            Ok(())
        }
        Action::OpenApplication { target } => require_text(target, "choose an app to open"),
        Action::OpenUrl { url } => {
            let parsed = url::Url::parse(url.trim())
                .map_err(|_| CoreError::invalid("the web address is not valid"))?;
            if BLOCKED_URL_SCHEMES.contains(&parsed.scheme()) {
                return Err(CoreError::invalid(format!(
                    "{} addresses are not allowed",
                    parsed.scheme()
                )));
            }
            Ok(())
        }
        Action::RunShell { script } => {
            require_text(script, "the shell command is empty")?;
            if script.len() > MAX_SHELL_LEN {
                return Err(CoreError::invalid("the shell command is too long"));
            }
            Ok(())
        }
        Action::RunScript { source, .. } => {
            require_text(source, "the script is empty")?;
            if source.len() > MAX_SCRIPT_LEN {
                return Err(CoreError::invalid("the script is too long"));
            }
            Ok(())
        }
        Action::RunShortcut { name } => require_text(name, "choose a shortcut to run"),
        Action::Builtin { command } => {
            let ok = !command.is_empty()
                && command.chars().all(|c| {
                    c.is_ascii_lowercase() || c.is_ascii_digit() || c == '.' || c == '_' || c == '-'
                });
            if ok {
                Ok(())
            } else {
                Err(CoreError::invalid("the built-in command name is not valid"))
            }
        }
        Action::Sequence { steps, delay_ms } => {
            if depth >= MAX_SEQUENCE_DEPTH {
                return Err(CoreError::invalid("sequences are nested too deeply"));
            }
            if steps.is_empty() {
                return Err(CoreError::invalid("the sequence has no steps"));
            }
            if steps.len() > MAX_SEQUENCE_STEPS {
                return Err(CoreError::invalid("the sequence has too many steps"));
            }
            if *delay_ms > MAX_DELAY_MS {
                return Err(CoreError::invalid("the delay between steps is too long"));
            }
            steps.iter().try_for_each(|s| validate_at(s, depth + 1))
        }
    }
}

fn require_text(value: &str, message: &str) -> Result<(), CoreError> {
    if value.trim().is_empty() {
        Err(CoreError::invalid(message))
    } else {
        Ok(())
    }
}

/// Checks an action and flattens it into the ordered steps a shell runs. A `Noop` produces no steps.
pub fn plan(action: &Action) -> Result<Vec<ActionStep>, CoreError> {
    validate(action)?;
    let mut out = Vec::new();
    push_steps(action, &mut out);
    if out.len() > MAX_PLAN_STEPS {
        return Err(CoreError::invalid("the action expands to too many steps"));
    }
    Ok(out)
}

fn push_steps(action: &Action, out: &mut Vec<ActionStep>) {
    match action {
        Action::Noop => {}
        Action::Sequence { steps, delay_ms } => {
            let mut first = true;
            for step in steps {
                let mut part = Vec::new();
                push_steps(step, &mut part);
                if part.is_empty() {
                    continue;
                }
                if !first && *delay_ms > 0 {
                    out.push(ActionStep::Delay { ms: *delay_ms });
                }
                first = false;
                out.append(&mut part);
            }
        }
        other => out.push(ActionStep::Run {
            action: other.clone(),
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn url_scheme_is_checked() {
        assert!(validate(&Action::OpenUrl {
            url: "https://example.com".into()
        })
        .is_ok());
        assert!(validate(&Action::OpenUrl {
            url: "javascript:alert(1)".into()
        })
        .is_err());
        assert!(validate(&Action::OpenUrl {
            url: "not a url".into()
        })
        .is_err());
    }

    #[test]
    fn empty_values_are_rejected() {
        assert!(validate(&Action::RunShell {
            script: "  ".into()
        })
        .is_err());
        assert!(validate(&Action::OpenApplication {
            target: String::new()
        })
        .is_err());
        assert!(validate(&Action::Builtin {
            command: "Window Left".into()
        })
        .is_err());
        assert!(validate(&Action::Builtin {
            command: "window.left_half".into()
        })
        .is_ok());
        assert!(validate(&Action::Builtin {
            command: "window.layout.1b2c-3d4e".into()
        })
        .is_ok());
    }

    #[test]
    fn unknown_modifier_bits_are_rejected() {
        let bad = Action::KeyPress {
            key_code: 0,
            modifiers: 1 << 40,
        };
        assert!(validate(&bad).is_err());
        let good = Action::KeyPress {
            key_code: 0,
            modifiers: modifiers::COMMAND | modifiers::SHIFT,
        };
        assert!(validate(&good).is_ok());
    }

    #[test]
    fn sequences_flatten_with_delays() {
        let seq = Action::Sequence {
            steps: vec![
                Action::OpenUrl {
                    url: "https://example.com".into(),
                },
                Action::Noop,
                Action::RunShortcut {
                    name: "Focus".into(),
                },
            ],
            delay_ms: 100,
        };
        let steps = plan(&seq).unwrap();
        assert_eq!(steps.len(), 3, "a step that does nothing adds no pause");
        assert_eq!(steps[1], ActionStep::Delay { ms: 100 });
    }

    #[test]
    fn deep_nesting_is_rejected() {
        let mut action = Action::Noop;
        for _ in 0..(MAX_SEQUENCE_DEPTH + 1) {
            action = Action::Sequence {
                steps: vec![action],
                delay_ms: 0,
            };
        }
        assert!(validate(&action).is_err());
    }

    #[test]
    fn actions_round_trip_through_json() {
        let action = Action::Sequence {
            steps: vec![Action::KeyPress {
                key_code: 12,
                modifiers: modifiers::COMMAND,
            }],
            delay_ms: 5,
        };
        let json = serde_json::to_string(&action).unwrap();
        assert_eq!(serde_json::from_str::<Action>(&json).unwrap(), action);
    }

    #[test]
    fn suggested_actions_are_valid_unique_and_stable() {
        let list = suggested_actions();
        let mut ids: Vec<&str> = list.iter().map(|a| a.id.as_str()).collect();
        ids.sort_unstable();
        let count = ids.len();
        ids.dedup();
        assert_eq!(ids.len(), count, "ids are unique");
        for named in &list {
            assert!(named.id.starts_with("suggested."));
            assert!(plan(&named.action).is_ok(), "{} can run", named.name);
        }
        assert!(list.iter().any(|a| a.name == "Back"));
        assert!(list.iter().any(|a| a.name == "Mission Control"));
        assert_eq!(suggested_actions(), list, "the same every time");
    }
}
