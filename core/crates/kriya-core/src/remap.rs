//! Key remapping: one key doing something else, doing different things when tapped, held or tapped twice, several keys
//! pressed together acting as one, and keys that turn into modifiers (a Hyper key). The engine is a state machine over
//! key events with times; the app feeds it what the keyboard does and carries out what it answers with.

use std::collections::{HashMap, HashSet};
use std::sync::Mutex;

use rusqlite::{params, OptionalExtension};
use serde::{Deserialize, Serialize};

use crate::actions::modifiers as m;
use crate::error::CoreError;
use crate::store::Store;

/// Media keys (play, volume, brightness) have no key codes of their own; they are given one above this, plus the number
/// macOS gives the key.
pub const MEDIA_BASE: u16 = 1000;
/// Caps Lock is turned into this key (F18) by the app so that it can be remapped like any other.
pub const CAPS_LOCK_KEY: u16 = 79;
const MAX_RULES: usize = 100;
const MAX_KEY: u16 = MEDIA_BASE + 127;
const SETTINGS_KEY: &str = "key_remap";

/// The modifier a modifier key stands for, or 0 for any other key.
pub fn modifier_bit(key_code: u16) -> u64 {
    match key_code {
        54 | 55 => m::COMMAND,
        56 | 60 => m::SHIFT,
        58 | 61 => m::OPTION,
        59 | 62 => m::CONTROL,
        63 => m::FUNCTION,
        _ => 0,
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum RemapOutput {
    /// Press this key, with these modifiers.
    Key { key_code: u16, modifiers: u64 },
    /// Act as these modifier keys for as long as the key is held.
    Modifiers { modifiers: u64 },
    /// Run a saved action.
    Action { action_id: String },
    /// Do nothing: the key is swallowed.
    Nothing,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct RemapRule {
    pub id: String,
    pub name: String,
    pub enabled: bool,
    /// The key this rule is about.
    pub key_code: u16,
    /// Modifiers that must be held for the rule to apply. 0 means none are needed.
    pub modifiers: u64,
    /// Only in these apps (bundle ids). Empty means every app.
    pub app_ids: Vec<String>,
    /// What a quick press does. With no hold or double-tap, this is a plain remap: the key becomes the output.
    pub tap: Option<RemapOutput>,
    /// What happens while the key is held (after the hold time, or as soon as another key is pressed).
    pub hold: Option<RemapOutput>,
    pub double_tap: Option<RemapOutput>,
    /// Other keys that must be pressed together with this one for the rule to apply (up to two). The tap output is what
    /// the combination does; a rule with chord keys has no hold or double-tap.
    pub chord_with: Vec<u16>,
    /// Only while a keyboard with this name is connected. `None` means any keyboard.
    #[uniffi(default = None)]
    pub keyboard: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
#[serde(default)]
pub struct RemapConfig {
    pub enabled: bool,
    pub rules: Vec<RemapRule>,
    /// How long a key is held before it counts as held, in milliseconds.
    pub hold_ms: u32,
    /// How soon a second tap must follow the first.
    pub double_tap_ms: u32,
    /// How close together the keys of a combination must be pressed.
    pub chord_ms: u32,
}

impl Default for RemapConfig {
    fn default() -> Self {
        RemapConfig {
            enabled: false,
            rules: Vec::new(),
            hold_ms: 200,
            double_tap_ms: 250,
            chord_ms: 50,
        }
    }
}

fn clean_output(output: Option<RemapOutput>) -> Option<RemapOutput> {
    match output? {
        RemapOutput::Key {
            key_code,
            modifiers,
        } if key_code <= MAX_KEY => Some(RemapOutput::Key {
            key_code,
            modifiers: modifiers & m::ALL,
        }),
        RemapOutput::Modifiers { modifiers } if modifiers & m::ALL != 0 => {
            Some(RemapOutput::Modifiers {
                modifiers: modifiers & m::ALL,
            })
        }
        RemapOutput::Action { action_id } if !action_id.trim().is_empty() => {
            Some(RemapOutput::Action {
                action_id: action_id.trim().to_string(),
            })
        }
        RemapOutput::Nothing => Some(RemapOutput::Nothing),
        _ => None,
    }
}

impl RemapConfig {
    pub fn sanitized(mut self) -> Self {
        self.hold_ms = self.hold_ms.clamp(100, 1000);
        self.double_tap_ms = self.double_tap_ms.clamp(100, 600);
        self.chord_ms = self.chord_ms.clamp(20, 150);
        let mut seen = HashSet::new();
        let mut kept = Vec::new();
        for mut rule in self.rules {
            rule.id = rule.id.trim().to_string();
            rule.name = rule.name.trim().to_string();
            rule.modifiers &= m::ALL;
            let mut apps = HashSet::new();
            rule.app_ids = rule
                .app_ids
                .iter()
                .map(|a| a.trim().to_string())
                .filter(|a| !a.is_empty() && apps.insert(a.clone()))
                .collect();
            rule.keyboard = rule
                .keyboard
                .map(|k| k.trim().to_string())
                .filter(|k| !k.is_empty());
            rule.tap = clean_output(rule.tap);
            rule.hold = clean_output(rule.hold);
            rule.double_tap = clean_output(rule.double_tap);
            let mut chord = HashSet::new();
            rule.chord_with = rule
                .chord_with
                .iter()
                .copied()
                .filter(|k| *k != rule.key_code && *k <= MAX_KEY && chord.insert(*k))
                .take(2)
                .collect();
            if !rule.chord_with.is_empty() {
                rule.hold = None;
                rule.double_tap = None;
            }
            let has_output = rule.tap.is_some() || rule.hold.is_some() || rule.double_tap.is_some();
            let valid = !rule.id.is_empty()
                && !rule.name.is_empty()
                && rule.name.chars().count() <= 60
                && rule.key_code <= MAX_KEY
                && has_output;
            if valid && seen.insert(rule.id.clone()) {
                kept.push(rule);
            }
        }
        kept.truncate(MAX_RULES);
        self.rules = kept;
        self
    }

    /// Whether any enabled rule needs Caps Lock turned into an ordinary key.
    pub fn uses_caps_lock(&self) -> bool {
        self.enabled
            && self.rules.iter().any(|r| {
                r.enabled && (r.key_code == CAPS_LOCK_KEY || r.chord_with.contains(&CAPS_LOCK_KEY))
            })
    }
}

// ---- the engine -------------------------------------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum EngineEffect {
    /// Press and release this key combination.
    Press {
        key_code: u16,
        modifiers: u64,
    },
    KeyDown {
        key_code: u16,
        modifiers: u64,
    },
    KeyUp {
        key_code: u16,
        modifiers: u64,
    },
    RunAction {
        action_id: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct EngineResult {
    /// Do not pass the original event on.
    pub swallow: bool,
    /// What to do, in order, before anything else.
    pub effects: Vec<EngineEffect>,
    /// Modifiers to add to this event and any other: keys that currently act as modifiers.
    pub add_modifiers: u64,
    /// Real modifiers to take off this event: modifier keys that have been remapped to something else.
    pub strip_modifiers: u64,
}

#[derive(Debug, Clone)]
enum KeyState {
    /// Pressed, and not yet known to be a tap or a hold.
    Pending { rule: usize, since: u64 },
    /// An output is in effect until the key comes up.
    Active {
        repeat: Vec<EngineEffect>,
        up: Vec<EngineEffect>,
        mods: u64,
    },
    /// The key's events are swallowed until it comes up.
    Swallow,
    /// Held back for a combination that did not happen; the key was replayed and now passes through.
    Replayed,
    /// Held back while waiting to see if a combination follows.
    ChordHeld,
}

#[derive(Debug, Clone)]
struct Waiting {
    key: u16,
    rule: usize,
    until: u64,
}

#[derive(Debug, Clone)]
struct Chord {
    pressed: Vec<(u16, u64)>,
    since: u64,
}

struct State {
    config: RemapConfig,
    keys: HashMap<u16, KeyState>,
    waiting: Option<Waiting>,
    chord: Option<Chord>,
}

#[derive(uniffi::Object)]
pub struct RemapEngine {
    state: Mutex<State>,
}

fn is_plain(rule: &RemapRule) -> bool {
    rule.chord_with.is_empty() && rule.hold.is_none() && rule.double_tap.is_none()
}

fn tap_effects(output: &RemapOutput) -> Vec<EngineEffect> {
    match output {
        RemapOutput::Key {
            key_code,
            modifiers,
        } => vec![EngineEffect::Press {
            key_code: *key_code,
            modifiers: *modifiers,
        }],
        RemapOutput::Action { action_id } => vec![EngineEffect::RunAction {
            action_id: action_id.clone(),
        }],
        RemapOutput::Modifiers { .. } | RemapOutput::Nothing => Vec::new(),
    }
}

/// The effects to run when an output starts, to repeat while the key repeats, and to run when it ends, and the modifiers
/// it adds meanwhile.
fn start_output(
    output: &RemapOutput,
) -> (Vec<EngineEffect>, Vec<EngineEffect>, Vec<EngineEffect>, u64) {
    match output {
        RemapOutput::Key {
            key_code,
            modifiers,
        } => {
            let down = EngineEffect::KeyDown {
                key_code: *key_code,
                modifiers: *modifiers,
            };
            (
                vec![down.clone()],
                vec![down],
                vec![EngineEffect::KeyUp {
                    key_code: *key_code,
                    modifiers: *modifiers,
                }],
                0,
            )
        }
        RemapOutput::Modifiers { modifiers } => (Vec::new(), Vec::new(), Vec::new(), *modifiers),
        RemapOutput::Action { action_id } => (
            vec![EngineEffect::RunAction {
                action_id: action_id.clone(),
            }],
            Vec::new(),
            Vec::new(),
            0,
        ),
        RemapOutput::Nothing => (Vec::new(), Vec::new(), Vec::new(), 0),
    }
}

fn key_set(rule: &RemapRule) -> HashSet<u16> {
    let mut set: HashSet<u16> = rule.chord_with.iter().copied().collect();
    set.insert(rule.key_code);
    set
}

impl State {
    fn rule_applies(&self, index: usize, mods: u64, app: Option<&str>) -> bool {
        let rule = &self.config.rules[index];
        rule.enabled
            && (rule.modifiers == 0 || mods & rule.modifiers == rule.modifiers)
            && (rule.app_ids.is_empty() || app.is_some_and(|a| rule.app_ids.iter().any(|x| x == a)))
    }

    fn virtual_mods(&self) -> u64 {
        self.keys.values().fold(0, |acc, s| {
            if let KeyState::Active { mods, .. } = s {
                acc | mods
            } else {
                acc
            }
        })
    }

    fn strip_mods(&self) -> u64 {
        self.keys.iter().fold(0, |acc, (key, s)| {
            if matches!(
                s,
                KeyState::Pending { .. }
                    | KeyState::Active { .. }
                    | KeyState::Swallow
                    | KeyState::ChordHeld
            ) {
                acc | modifier_bit(*key)
            } else {
                acc
            }
        })
    }

    fn result(&self, swallow: bool, effects: Vec<EngineEffect>) -> EngineResult {
        EngineResult {
            swallow,
            effects,
            add_modifiers: self.virtual_mods(),
            strip_modifiers: self.strip_mods(),
        }
    }

    fn start_hold(&mut self, key: u16, rule: usize, effects: &mut Vec<EngineEffect>) {
        let Some(output) = self.config.rules[rule].hold.clone() else {
            return;
        };
        let (down, repeat, up, mods) = start_output(&output);
        effects.extend(down);
        self.keys.insert(key, KeyState::Active { repeat, up, mods });
    }

    fn flush_chord(&mut self, effects: &mut Vec<EngineEffect>) {
        if let Some(chord) = self.chord.take() {
            for (key, modifiers) in chord.pressed {
                effects.push(EngineEffect::KeyDown {
                    key_code: key,
                    modifiers,
                });
                self.keys.insert(key, KeyState::Replayed);
            }
        }
    }

    /// Settles whatever was waiting on time.
    fn expire(&mut self, now: u64, effects: &mut Vec<EngineEffect>) {
        let hold_ms = u64::from(self.config.hold_ms);
        let due: Vec<(u16, usize)> = self
            .keys
            .iter()
            .filter_map(|(key, s)| match s {
                KeyState::Pending { rule, since }
                    if self.config.rules[*rule].hold.is_some()
                        && now.saturating_sub(*since) >= hold_ms =>
                {
                    Some((*key, *rule))
                }
                _ => None,
            })
            .collect();
        for (key, rule) in due {
            self.start_hold(key, rule, effects);
        }
        if let Some(w) = self.waiting.clone() {
            if now > w.until {
                if let Some(tap) = &self.config.rules[w.rule].tap {
                    effects.extend(tap_effects(tap));
                }
                self.waiting = None;
            }
        }
        if let Some(chord) = &self.chord {
            if now.saturating_sub(chord.since) >= u64::from(self.config.chord_ms) {
                self.flush_chord(effects);
            }
        }
    }

    /// A different key was pressed: what was undecided is decided now.
    fn interrupt(&mut self, current: u16, effects: &mut Vec<EngineEffect>) {
        let pending: Vec<(u16, usize)> = self
            .keys
            .iter()
            .filter_map(|(key, s)| match s {
                KeyState::Pending { rule, .. } if *key != current => Some((*key, *rule)),
                _ => None,
            })
            .collect();
        for (key, rule) in pending {
            if self.config.rules[rule].hold.is_some() {
                self.start_hold(key, rule, effects);
            } else {
                if let Some(tap) = self.config.rules[rule].tap.clone() {
                    effects.extend(tap_effects(&tap));
                }
                self.keys.insert(key, KeyState::Swallow);
            }
        }
        if let Some(w) = self.waiting.clone() {
            if w.key != current {
                if let Some(tap) = &self.config.rules[w.rule].tap {
                    effects.extend(tap_effects(tap));
                }
                self.waiting = None;
            }
        }
    }

    /// Handles a key going down as part of a combination. `Some` means the event is dealt with.
    fn chord_key_down(
        &mut self,
        key: u16,
        mods: u64,
        app: Option<&str>,
        now: u64,
        effects: &mut Vec<EngineEffect>,
    ) -> Option<EngineResult> {
        let mut pressed: Vec<u16> = self
            .chord
            .as_ref()
            .map(|c| c.pressed.iter().map(|(k, _)| *k).collect())
            .unwrap_or_default();
        pressed.push(key);
        let wanted: HashSet<u16> = pressed.iter().copied().collect();
        let candidates: Vec<usize> = (0..self.config.rules.len())
            .filter(|&i| {
                let rule = &self.config.rules[i];
                !rule.chord_with.is_empty()
                    && self.rule_applies(i, mods, app)
                    && wanted.is_subset(&key_set(rule))
            })
            .collect();
        if candidates.is_empty() {
            // Not part of any combination that fits: whatever was waiting is let go, and this key is ordinary.
            self.flush_chord(effects);
            return None;
        }
        let mut chord = self.chord.take().unwrap_or(Chord {
            pressed: Vec::new(),
            since: now,
        });
        chord.pressed.push((key, mods));
        if let Some(&done) = candidates
            .iter()
            .find(|&&i| key_set(&self.config.rules[i]) == wanted)
        {
            if let Some(tap) = self.config.rules[done].tap.clone() {
                effects.extend(tap_effects(&tap));
            }
            for (k, _) in &chord.pressed {
                self.keys.insert(*k, KeyState::Swallow);
            }
            return Some(self.result(true, std::mem::take(effects)));
        }
        self.keys.insert(key, KeyState::ChordHeld);
        self.chord = Some(chord);
        Some(self.result(true, std::mem::take(effects)))
    }
}

#[uniffi::export]
impl RemapEngine {
    #[uniffi::constructor]
    pub fn new(config: RemapConfig) -> Self {
        RemapEngine {
            state: Mutex::new(State {
                config: config.sanitized(),
                keys: HashMap::new(),
                waiting: None,
                chord: None,
            }),
        }
    }

    /// Replaces the settings and forgets any key in progress.
    pub fn set_config(&self, config: RemapConfig) {
        let mut state = self.lock();
        state.config = config.sanitized();
        state.keys.clear();
        state.waiting = None;
        state.chord = None;
    }

    pub fn reset(&self) {
        let mut state = self.lock();
        state.keys.clear();
        state.waiting = None;
        state.chord = None;
    }

    /// True while something is waiting on time, so the app knows to call `tick`.
    pub fn is_busy(&self) -> bool {
        let state = self.lock();
        state.waiting.is_some()
            || state.chord.is_some()
            || state.keys.values().any(|s| matches!(s, KeyState::Pending { rule, .. } if state.config.rules[*rule].hold.is_some()))
    }

    /// The modifiers keys currently act as, for events that are not key events (mouse clicks).
    pub fn virtual_modifiers(&self) -> u64 {
        self.lock().virtual_mods()
    }

    /// A key went down or up. `modifiers` are the modifiers really held; `now_ms` is any steadily increasing clock.
    pub fn handle_key(
        &self,
        key_code: u16,
        is_down: bool,
        modifiers: u64,
        app_id: Option<String>,
        now_ms: u64,
    ) -> EngineResult {
        let mut state = self.lock();
        if !state.config.enabled {
            return EngineResult {
                swallow: false,
                effects: Vec::new(),
                add_modifiers: 0,
                strip_modifiers: 0,
            };
        }
        let app = app_id.as_deref();
        let mut effects = Vec::new();
        state.expire(now_ms, &mut effects);
        if is_down {
            state.key_down(key_code, modifiers, app, now_ms, effects)
        } else {
            state.key_up(key_code, now_ms, effects)
        }
    }

    /// Lets time pass: a held key becomes held, a lone tap waiting for a second one is let go.
    pub fn tick(&self, now_ms: u64) -> EngineResult {
        let mut state = self.lock();
        let mut effects = Vec::new();
        if state.config.enabled {
            state.expire(now_ms, &mut effects);
        }
        state.result(false, effects)
    }
}

impl RemapEngine {
    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

impl State {
    fn key_down(
        &mut self,
        key: u16,
        mods: u64,
        app: Option<&str>,
        now: u64,
        mut effects: Vec<EngineEffect>,
    ) -> EngineResult {
        if let Some(existing) = self.keys.get(&key).cloned() {
            // The keyboard repeating a held key.
            return match existing {
                KeyState::Replayed => self.result(false, effects),
                KeyState::Active { repeat, .. } => {
                    effects.extend(repeat);
                    self.result(true, effects)
                }
                _ => self.result(true, effects),
            };
        }
        self.interrupt(key, &mut effects);
        if let Some(done) = self.chord_key_down(key, mods, app, now, &mut effects) {
            return done;
        }
        let found = (0..self.config.rules.len()).find(|&i| {
            let rule = &self.config.rules[i];
            rule.key_code == key && rule.chord_with.is_empty() && self.rule_applies(i, mods, app)
        });
        let Some(index) = found else {
            return self.result(false, effects);
        };
        let rule = self.config.rules[index].clone();
        if is_plain(&rule) {
            let output = rule.tap.unwrap_or(RemapOutput::Nothing);
            let (down, repeat, up, virtual_mods) = start_output(&output);
            effects.extend(down);
            self.keys.insert(
                key,
                KeyState::Active {
                    repeat,
                    up,
                    mods: virtual_mods,
                },
            );
            return self.result(true, effects);
        }
        if let (Some(w), Some(double)) = (self.waiting.clone(), rule.double_tap.as_ref()) {
            if w.key == key && now <= w.until {
                self.waiting = None;
                effects.extend(tap_effects(double));
                self.keys.insert(key, KeyState::Swallow);
                return self.result(true, effects);
            }
        }
        self.keys.insert(
            key,
            KeyState::Pending {
                rule: index,
                since: now,
            },
        );
        self.result(true, effects)
    }

    fn key_up(&mut self, key: u16, now: u64, mut effects: Vec<EngineEffect>) -> EngineResult {
        if matches!(self.keys.get(&key), Some(KeyState::ChordHeld)) {
            // Let go before the combination was complete: it was not one.
            self.flush_chord(&mut effects);
        }
        match self.keys.remove(&key) {
            Some(KeyState::Pending { rule, .. }) => {
                let r = &self.config.rules[rule];
                if r.double_tap.is_some() {
                    self.waiting = Some(Waiting {
                        key,
                        rule,
                        until: now + u64::from(self.config.double_tap_ms),
                    });
                } else if let Some(tap) = r.tap.clone() {
                    effects.extend(tap_effects(&tap));
                }
                self.result(true, effects)
            }
            Some(KeyState::Active { up, .. }) => {
                effects.extend(up);
                self.result(true, effects)
            }
            Some(KeyState::Swallow | KeyState::ChordHeld) => self.result(true, effects),
            Some(KeyState::Replayed) | None => self.result(false, effects),
        }
    }
}

// ---- storage ----------------------------------------------------------------------------------------------------------

impl Store {
    pub fn remap_config(&self) -> Result<RemapConfig, CoreError> {
        let conn = self.conn();
        let json: Option<String> = conn
            .query_row(
                "SELECT value FROM settings WHERE key = ?1",
                params![SETTINGS_KEY],
                |r| r.get(0),
            )
            .optional()?;
        Ok(json
            .and_then(|j| serde_json::from_str::<RemapConfig>(&j).ok())
            .unwrap_or_default()
            .sanitized())
    }

    pub fn save_remap_config(&self, config: &RemapConfig) -> Result<(), CoreError> {
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

    const ALL: u64 = m::CONTROL | m::OPTION | m::SHIFT | m::COMMAND;

    fn key(k: u16, mods: u64) -> RemapOutput {
        RemapOutput::Key {
            key_code: k,
            modifiers: mods,
        }
    }

    fn rule(id: &str, key_code: u16) -> RemapRule {
        RemapRule {
            id: id.into(),
            name: id.into(),
            enabled: true,
            key_code,
            modifiers: 0,
            app_ids: vec![],
            tap: None,
            hold: None,
            double_tap: None,
            chord_with: vec![],
            keyboard: None,
        }
    }

    fn engine(rules: Vec<RemapRule>) -> RemapEngine {
        RemapEngine::new(RemapConfig {
            enabled: true,
            rules,
            ..RemapConfig::default()
        })
    }

    fn press(k: u16, mods: u64) -> EngineEffect {
        EngineEffect::Press {
            key_code: k,
            modifiers: mods,
        }
    }

    #[test]
    fn a_plain_remap_turns_one_key_into_another_and_keeps_repeating() {
        let e = engine(vec![RemapRule {
            tap: Some(key(53, 0)),
            ..rule("esc", 12)
        }]);
        let down = e.handle_key(12, true, 0, None, 0);
        assert!(down.swallow);
        assert_eq!(
            down.effects,
            vec![EngineEffect::KeyDown {
                key_code: 53,
                modifiers: 0
            }]
        );
        let repeat = e.handle_key(12, true, 0, None, 400);
        assert!(repeat.swallow);
        assert_eq!(
            repeat.effects,
            vec![EngineEffect::KeyDown {
                key_code: 53,
                modifiers: 0
            }],
            "a held key keeps repeating"
        );
        let up = e.handle_key(12, false, 0, None, 500);
        assert!(up.swallow);
        assert_eq!(
            up.effects,
            vec![EngineEffect::KeyUp {
                key_code: 53,
                modifiers: 0
            }]
        );
        assert!(
            !e.handle_key(13, true, 0, None, 600).swallow,
            "other keys are untouched"
        );
    }

    #[test]
    fn a_hyper_key_taps_as_escape_and_holds_as_all_four_modifiers() {
        let hyper = RemapRule {
            tap: Some(key(53, 0)),
            hold: Some(RemapOutput::Modifiers { modifiers: ALL }),
            ..rule("hyper", CAPS_LOCK_KEY)
        };
        // A quick tap.
        let e = engine(vec![hyper.clone()]);
        assert!(e.handle_key(CAPS_LOCK_KEY, true, 0, None, 0).swallow);
        assert!(e.is_busy());
        let up = e.handle_key(CAPS_LOCK_KEY, false, 0, None, 80);
        assert_eq!(up.effects, vec![press(53, 0)]);
        assert!(!e.is_busy());
        // Held past the hold time: the modifiers come on, and another key carries them.
        let e = engine(vec![hyper.clone()]);
        e.handle_key(CAPS_LOCK_KEY, true, 0, None, 0);
        assert_eq!(e.tick(100).add_modifiers, 0, "not held long enough yet");
        assert_eq!(e.tick(250).add_modifiers, ALL);
        let other = e.handle_key(0, true, 0, None, 300);
        assert!(!other.swallow);
        assert_eq!(other.add_modifiers, ALL);
        assert_eq!(e.virtual_modifiers(), ALL);
        let release = e.handle_key(CAPS_LOCK_KEY, false, 0, None, 400);
        assert!(release.swallow && release.effects.is_empty());
        assert_eq!(e.virtual_modifiers(), 0);
        // Another key pressed while it is still undecided makes it a hold at once.
        let e = engine(vec![hyper]);
        e.handle_key(CAPS_LOCK_KEY, true, 0, None, 0);
        let quick = e.handle_key(4, true, 0, None, 40);
        assert_eq!(quick.add_modifiers, ALL);
        assert!(!quick.swallow);
    }

    #[test]
    fn a_held_key_can_become_another_key_or_run_an_action() {
        let e = engine(vec![RemapRule {
            tap: Some(key(0, 0)),
            hold: Some(RemapOutput::Action {
                action_id: "go".into(),
            }),
            ..rule("a", 0)
        }]);
        e.handle_key(0, true, 0, None, 0);
        let held = e.tick(300);
        assert_eq!(
            held.effects,
            vec![EngineEffect::RunAction {
                action_id: "go".into()
            }]
        );
        assert!(e.handle_key(0, false, 0, None, 400).swallow);
        let e = engine(vec![RemapRule {
            hold: Some(key(53, 0)),
            ..rule("hold-key", 0)
        }]);
        e.handle_key(0, true, 0, None, 0);
        assert_eq!(
            e.tick(300).effects,
            vec![EngineEffect::KeyDown {
                key_code: 53,
                modifiers: 0
            }]
        );
        assert_eq!(
            e.handle_key(0, false, 0, None, 400).effects,
            vec![EngineEffect::KeyUp {
                key_code: 53,
                modifiers: 0
            }]
        );
    }

    #[test]
    fn a_double_tap_does_one_thing_and_a_single_tap_another() {
        let rules = vec![RemapRule {
            tap: Some(key(0, 0)),
            double_tap: Some(key(11, m::COMMAND)),
            ..rule("dt", 38)
        }];
        let e = engine(rules.clone());
        e.handle_key(38, true, 0, None, 0);
        assert!(
            e.handle_key(38, false, 0, None, 50).effects.is_empty(),
            "the tap waits to see if a second follows"
        );
        assert!(e.is_busy());
        e.handle_key(38, true, 0, None, 150);
        let second = e.handle_key(38, false, 0, None, 190);
        assert!(second.swallow);
        // The double tap fired on the second press.
        let e = engine(rules.clone());
        e.handle_key(38, true, 0, None, 0);
        e.handle_key(38, false, 0, None, 50);
        let double = e.handle_key(38, true, 0, None, 150);
        assert_eq!(double.effects, vec![press(11, m::COMMAND)]);
        // A single tap is let go once the window has passed.
        let e = engine(rules.clone());
        e.handle_key(38, true, 0, None, 0);
        e.handle_key(38, false, 0, None, 50);
        assert!(e.tick(200).effects.is_empty());
        assert_eq!(e.tick(400).effects, vec![press(0, 0)]);
        assert!(!e.is_busy());
        // Another key in between settles it as a single tap straight away.
        let e = engine(rules);
        e.handle_key(38, true, 0, None, 0);
        e.handle_key(38, false, 0, None, 50);
        let next = e.handle_key(5, true, 0, None, 100);
        assert_eq!(next.effects, vec![press(0, 0)]);
        assert!(!next.swallow);
    }

    #[test]
    fn two_keys_pressed_together_act_as_one() {
        let combo = RemapRule {
            tap: Some(key(53, 0)),
            chord_with: vec![40],
            ..rule("jk", 38)
        };
        let e = engine(vec![combo.clone()]);
        let first = e.handle_key(38, true, 0, None, 0);
        assert!(first.swallow && first.effects.is_empty());
        let second = e.handle_key(40, true, 0, None, 30);
        assert!(second.swallow);
        assert_eq!(second.effects, vec![press(53, 0)]);
        assert!(e.handle_key(38, false, 0, None, 80).swallow);
        assert!(e.handle_key(40, false, 0, None, 90).swallow);
        // The other order works too.
        let e = engine(vec![combo.clone()]);
        e.handle_key(40, true, 0, None, 0);
        assert_eq!(
            e.handle_key(38, true, 0, None, 10).effects,
            vec![press(53, 0)]
        );
        // Only one of them: after the window it is typed as normal.
        let e = engine(vec![combo.clone()]);
        e.handle_key(38, true, 0, None, 0);
        let late = e.tick(80);
        assert_eq!(
            late.effects,
            vec![EngineEffect::KeyDown {
                key_code: 38,
                modifiers: 0
            }]
        );
        assert!(
            !e.handle_key(38, false, 0, None, 120).swallow,
            "its release passes through"
        );
        // Let go before the second arrives: replayed, then released as normal.
        let e = engine(vec![combo.clone()]);
        e.handle_key(38, true, 0, None, 0);
        let quick = e.handle_key(38, false, 0, None, 20);
        assert_eq!(
            quick.effects,
            vec![EngineEffect::KeyDown {
                key_code: 38,
                modifiers: 0
            }]
        );
        assert!(!quick.swallow);
        // A key that is no part of it flushes the first.
        let e = engine(vec![combo]);
        e.handle_key(38, true, 0, None, 0);
        let other = e.handle_key(7, true, 0, None, 10);
        assert_eq!(
            other.effects,
            vec![EngineEffect::KeyDown {
                key_code: 38,
                modifiers: 0
            }]
        );
        assert!(!other.swallow);
    }

    #[test]
    fn a_modifier_key_can_be_remapped_to_another_modifier() {
        // Right Command acts as Control.
        let e = engine(vec![RemapRule {
            tap: Some(RemapOutput::Modifiers {
                modifiers: m::CONTROL,
            }),
            ..rule("rcmd", 54)
        }]);
        let down = e.handle_key(54, true, m::COMMAND, None, 0);
        assert!(down.swallow);
        assert_eq!(down.add_modifiers, m::CONTROL);
        assert_eq!(
            down.strip_modifiers,
            m::COMMAND,
            "the real Command is taken off other events"
        );
        let letter = e.handle_key(8, true, m::COMMAND, None, 50);
        assert!(!letter.swallow);
        assert_eq!(
            (letter.add_modifiers, letter.strip_modifiers),
            (m::CONTROL, m::COMMAND)
        );
        let up = e.handle_key(54, false, 0, None, 100);
        assert!(up.swallow);
        assert_eq!((up.add_modifiers, up.strip_modifiers), (0, 0));
        assert_eq!(modifier_bit(54), m::COMMAND);
        assert_eq!(modifier_bit(0), 0);
    }

    #[test]
    fn rules_can_depend_on_the_app_and_on_held_modifiers() {
        let mut only_in_editor = RemapRule {
            tap: Some(key(53, 0)),
            ..rule("a", 12)
        };
        only_in_editor.app_ids = vec!["com.editor".into()];
        let with_shift = RemapRule {
            modifiers: m::SHIFT,
            tap: Some(key(53, 0)),
            ..rule("b", 13)
        };
        let e = engine(vec![only_in_editor, with_shift]);
        assert!(
            e.handle_key(12, true, 0, Some("com.editor".into()), 0)
                .swallow
        );
        e.handle_key(12, false, 0, Some("com.editor".into()), 1);
        assert!(
            !e.handle_key(12, true, 0, Some("com.other".into()), 2)
                .swallow
        );
        e.handle_key(12, false, 0, Some("com.other".into()), 3);
        assert!(!e.handle_key(13, true, 0, None, 4).swallow);
        e.handle_key(13, false, 0, None, 5);
        assert!(e.handle_key(13, true, m::SHIFT, None, 6).swallow);
    }

    #[test]
    fn media_keys_and_nothing_and_disabled_engines() {
        let play = MEDIA_BASE + 16;
        let e = engine(vec![RemapRule {
            tap: Some(RemapOutput::Nothing),
            ..rule("mute-play", play)
        }]);
        let down = e.handle_key(play, true, 0, None, 0);
        assert!(down.swallow && down.effects.is_empty());
        let off = RemapEngine::new(RemapConfig {
            enabled: false,
            rules: vec![rule("x", 1)],
            ..RemapConfig::default()
        });
        assert!(!off.handle_key(1, true, 0, None, 0).swallow);
    }

    #[test]
    fn settings_are_tidied() {
        let config = RemapConfig {
            enabled: true,
            hold_ms: 5,
            double_tap_ms: 99999,
            chord_ms: 0,
            rules: vec![
                RemapRule {
                    tap: Some(key(53, 1 << 40)),
                    chord_with: vec![1, 1, 2, 3, 12],
                    hold: Some(key(1, 0)),
                    ..rule(" a ", 12)
                },
                rule("no-output", 3),
                RemapRule {
                    name: " ".into(),
                    tap: Some(key(1, 0)),
                    ..rule("no-name", 4)
                },
                RemapRule {
                    tap: Some(key(1, 0)),
                    ..rule("a", 5)
                },
                RemapRule {
                    tap: Some(RemapOutput::Modifiers { modifiers: 0 }),
                    ..rule("empty-mods", 6)
                },
                RemapRule {
                    tap: Some(key(5000, 0)),
                    ..rule("bad-key", 7)
                },
            ],
        }
        .sanitized();
        assert_eq!(
            (config.hold_ms, config.double_tap_ms, config.chord_ms),
            (100, 600, 20)
        );
        let ids: Vec<&str> = config.rules.iter().map(|r| r.id.as_str()).collect();
        assert_eq!(ids, vec!["a"]);
        let kept = &config.rules[0];
        assert_eq!(
            kept.chord_with,
            vec![1, 2],
            "no repeats, not itself, at most two"
        );
        assert!(kept.hold.is_none(), "a combination has no hold");
        assert_eq!(
            kept.tap,
            Some(key(53, 0)),
            "unknown modifier bits are dropped"
        );
        assert!(RemapConfig::default().sanitized().rules.is_empty());
    }

    #[test]
    fn a_keyboard_name_is_tidied() {
        let config = RemapConfig {
            enabled: true,
            rules: vec![
                RemapRule {
                    tap: Some(key(53, 0)),
                    keyboard: Some("  Keychron K2 ".into()),
                    ..rule("a", 12)
                },
                RemapRule {
                    tap: Some(key(53, 0)),
                    keyboard: Some("   ".into()),
                    ..rule("b", 13)
                },
            ],
            ..RemapConfig::default()
        }
        .sanitized();
        assert_eq!(config.rules[0].keyboard.as_deref(), Some("Keychron K2"));
        assert_eq!(config.rules[1].keyboard, None);
    }

    #[test]
    fn caps_lock_use_is_noticed_and_the_configuration_is_stored() {
        let config = RemapConfig {
            enabled: true,
            rules: vec![RemapRule {
                tap: Some(key(53, 0)),
                ..rule("caps", CAPS_LOCK_KEY)
            }],
            ..RemapConfig::default()
        };
        assert!(config.uses_caps_lock());
        let mut off = config.clone();
        off.rules[0].enabled = false;
        assert!(!off.uses_caps_lock());
        let store = Store::open_in_memory().unwrap();
        assert!(!store.remap_config().unwrap().enabled);
        store.save_remap_config(&config).unwrap();
        assert_eq!(store.remap_config().unwrap().rules.len(), 1);
    }
}
