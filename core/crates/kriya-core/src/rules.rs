//! Rules connect a trigger to a saved action, optionally limited to certain apps or devices.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Trigger {
    /// Run only from a button, menu or another action; never fires by itself.
    Manual,
    MouseButton {
        button: u32,
        modifiers: u64,
    },
    Hotkey {
        key_code: u16,
        modifiers: u64,
    },
    Gesture {
        name: String,
    },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct Rule {
    pub id: String,
    pub name: String,
    pub enabled: bool,
    pub trigger: Trigger,
    /// Empty means every app.
    pub app_ids: Vec<String>,
    /// Empty means every device.
    pub device_ids: Vec<String>,
    pub action_id: String,
    pub sort_order: i64,
}

impl Rule {
    fn applies(&self, trigger: &Trigger, app_id: Option<&str>, device_id: Option<&str>) -> bool {
        if !self.enabled || &self.trigger != trigger {
            return false;
        }
        let app_ok =
            self.app_ids.is_empty() || app_id.is_some_and(|a| self.app_ids.iter().any(|x| x == a));
        let device_ok = self.device_ids.is_empty()
            || device_id.is_some_and(|d| self.device_ids.iter().any(|x| x == d));
        app_ok && device_ok
    }

    /// Rules limited to an app or a device win over general ones.
    fn specificity(&self) -> u8 {
        u8::from(!self.app_ids.is_empty()) + u8::from(!self.device_ids.is_empty())
    }
}

/// The rules that fire for a trigger, most specific first, then in the person's own order.
pub fn matching(
    rules: &[Rule],
    trigger: &Trigger,
    app_id: Option<&str>,
    device_id: Option<&str>,
) -> Vec<Rule> {
    let mut found: Vec<Rule> = rules
        .iter()
        .filter(|r| r.applies(trigger, app_id, device_id))
        .cloned()
        .collect();
    found.sort_by(|a, b| {
        b.specificity()
            .cmp(&a.specificity())
            .then(a.sort_order.cmp(&b.sort_order))
    });
    found
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rule(id: &str, apps: &[&str], devices: &[&str], order: i64) -> Rule {
        Rule {
            id: id.into(),
            name: id.into(),
            enabled: true,
            trigger: Trigger::MouseButton {
                button: 3,
                modifiers: 0,
            },
            app_ids: apps.iter().map(|s| s.to_string()).collect(),
            device_ids: devices.iter().map(|s| s.to_string()).collect(),
            action_id: "a".into(),
            sort_order: order,
        }
    }

    #[test]
    fn specific_rules_come_first() {
        let rules = vec![
            rule("general", &[], &[], 0),
            rule("app", &["com.apple.Safari"], &[], 5),
        ];
        let t = Trigger::MouseButton {
            button: 3,
            modifiers: 0,
        };
        let hit = matching(&rules, &t, Some("com.apple.Safari"), None);
        assert_eq!(
            hit.iter().map(|r| r.id.as_str()).collect::<Vec<_>>(),
            ["app", "general"]
        );
    }

    #[test]
    fn scoped_rules_skip_other_apps_and_devices() {
        let rules = vec![rule("app", &["a"], &[], 0), rule("dev", &[], &["d1"], 0)];
        let t = Trigger::MouseButton {
            button: 3,
            modifiers: 0,
        };
        assert!(matching(&rules, &t, Some("b"), Some("d2")).is_empty());
        assert_eq!(matching(&rules, &t, Some("a"), Some("d1")).len(), 2);
    }

    #[test]
    fn disabled_rules_and_other_triggers_never_match() {
        let mut off = rule("off", &[], &[], 0);
        off.enabled = false;
        let t = Trigger::MouseButton {
            button: 3,
            modifiers: 0,
        };
        assert!(matching(&[off], &t, None, None).is_empty());
        let other = Trigger::Gesture {
            name: "swipe-left".into(),
        };
        assert!(matching(&[rule("r", &[], &[], 0)], &other, None, None).is_empty());
    }
}
