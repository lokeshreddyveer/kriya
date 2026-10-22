//! Link routing: deciding which browser (or profile) opens a link, cleaning tracking parameters out of it, and unwrapping
//! the redirect addresses some sites put around real links. All plain logic over text; the app receives the links and
//! opens them.

use std::collections::HashSet;

use regex::Regex;
use rusqlite::{params, OptionalExtension};
use serde::{Deserialize, Serialize};
use url::Url;

use crate::actions::modifiers as m;
use crate::error::CoreError;
use crate::store::Store;

pub const MAX_RULES: usize = 200;
const SETTINGS_KEY: &str = "link_routing";
const DEFAULT_BROWSER: &str = "com.apple.Safari";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum MatchKind {
    /// The site: `example.com` matches `example.com` and every subdomain of it.
    Domain,
    /// The address starts with this text, with or without `https://`.
    Prefix,
    /// The address contains this text anywhere.
    Contains,
    /// The address matches this regular expression.
    Regex,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum LinkTarget {
    /// Open in this app, in a browser profile where the browser supports choosing one.
    Open {
        app_id: String,
        profile: Option<String>,
    },
    /// Show a small menu of browsers to choose from.
    Ask,
    /// Copy the link instead of opening it.
    Copy,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct LinkRule {
    pub id: String,
    pub name: String,
    pub enabled: bool,
    pub match_kind: MatchKind,
    pub pattern: String,
    /// Only for links that come from these apps (bundle ids). Empty means any app.
    pub source_app_ids: Vec<String>,
    /// Only while these keys are held when the link is clicked. 0 means no keys are needed.
    pub modifiers: u64,
    pub target: LinkTarget,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
#[serde(default)]
pub struct LinkRoutingConfig {
    /// Off by default: until turned on, links go to the fallback untouched.
    pub enabled: bool,
    /// The first enabled rule that matches wins, so order is priority.
    pub rules: Vec<LinkRule>,
    /// Where a link goes when no rule matches.
    pub fallback: LinkTarget,
    pub strip_tracking: bool,
    /// Extra query parameter names to remove, besides the usual ones.
    pub extra_tracking_params: Vec<String>,
    /// Replace known redirect wrappers (a search engine's or a mail scanner's) with the real address.
    pub expand_redirects: bool,
    /// Hold these keys while clicking a link to be asked which browser. 0 turns it off.
    pub ask_modifier: u64,
    /// Keep a short list of what was done with each link.
    pub log_enabled: bool,
}

impl Default for LinkRoutingConfig {
    fn default() -> Self {
        LinkRoutingConfig {
            enabled: false,
            rules: Vec::new(),
            fallback: LinkTarget::Open {
                app_id: DEFAULT_BROWSER.to_string(),
                profile: None,
            },
            strip_tracking: true,
            extra_tracking_params: Vec::new(),
            expand_redirects: true,
            ask_modifier: m::OPTION,
            log_enabled: true,
        }
    }
}

impl LinkRoutingConfig {
    /// Drops rules that cannot work (nothing to match, a pattern that is not a valid expression, no app to open) and
    /// tidies the rest.
    pub fn sanitized(mut self) -> Self {
        let mut seen = HashSet::new();
        let mut kept = Vec::new();
        for mut rule in self.rules {
            rule.id = rule.id.trim().to_string();
            rule.name = rule.name.trim().to_string();
            rule.pattern = rule.pattern.trim().to_string();
            rule.modifiers &= m::ALL;
            let mut apps = HashSet::new();
            rule.source_app_ids = rule
                .source_app_ids
                .iter()
                .map(|a| a.trim().to_string())
                .filter(|a| !a.is_empty() && apps.insert(a.clone()))
                .collect();
            rule.target = clean_target(rule.target);
            let target_ok =
                !matches!(&rule.target, LinkTarget::Open { app_id, .. } if app_id.is_empty());
            let pattern_ok = !rule.pattern.is_empty()
                && rule.pattern.chars().count() <= 300
                && (rule.match_kind != MatchKind::Regex || regex_for(&rule.pattern).is_some());
            let valid = !rule.id.is_empty()
                && !rule.name.is_empty()
                && rule.name.chars().count() <= 60
                && pattern_ok
                && target_ok;
            if valid && seen.insert(rule.id.clone()) {
                kept.push(rule);
            }
        }
        kept.truncate(MAX_RULES);
        self.rules = kept;
        self.fallback = match clean_target(self.fallback) {
            LinkTarget::Open { app_id, .. } if app_id.is_empty() => LinkTarget::Open {
                app_id: DEFAULT_BROWSER.to_string(),
                profile: None,
            },
            other => other,
        };
        let mut names = HashSet::new();
        self.extra_tracking_params = self
            .extra_tracking_params
            .iter()
            .map(|p| p.trim().to_lowercase())
            .filter(|p| {
                !p.is_empty()
                    && p.len() <= 40
                    && !p.contains(['&', '=', ' ', '#'])
                    && names.insert(p.clone())
            })
            .take(100)
            .collect();
        self.ask_modifier &= m::ALL;
        self
    }
}

fn clean_target(target: LinkTarget) -> LinkTarget {
    match target {
        LinkTarget::Open { app_id, profile } => LinkTarget::Open {
            app_id: app_id.trim().to_string(),
            profile: profile
                .map(|p| p.trim().to_string())
                .filter(|p| !p.is_empty()),
        },
        other => other,
    }
}

fn regex_for(pattern: &str) -> Option<Regex> {
    regex::RegexBuilder::new(pattern)
        .case_insensitive(true)
        .size_limit(1 << 20)
        .build()
        .ok()
}

// ---- what to do with one link ---------------------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct LinkDecision {
    /// The address to open, after cleaning.
    pub url: String,
    pub original: String,
    pub target: LinkTarget,
    pub rule_id: Option<String>,
    pub rule_name: Option<String>,
    /// What was changed, in plain words, for the log.
    pub changes: Vec<String>,
}

/// Decides what happens to a link. `source_app_id` is the app the link came from, when it is known; `modifiers` are the
/// keys held at the click.
pub fn resolve_link(
    config: &LinkRoutingConfig,
    original: &str,
    source_app_id: Option<&str>,
    modifiers: u64,
) -> LinkDecision {
    let mut url = original.to_string();
    let mut changes = Vec::new();
    if !config.enabled {
        return LinkDecision {
            url,
            original: original.to_string(),
            target: config.fallback.clone(),
            rule_id: None,
            rule_name: None,
            changes,
        };
    }
    if config.expand_redirects {
        for _ in 0..3 {
            match unwrap_redirect(&url) {
                Some(inner) => {
                    url = inner;
                    changes.push("Replaced a redirect with the real address".to_string());
                }
                None => break,
            }
        }
    }
    if config.strip_tracking {
        let (clean, removed) = strip_tracking(&url, &config.extra_tracking_params);
        if removed > 0 {
            changes.push(format!(
                "Removed {removed} tracking parameter{}",
                if removed == 1 { "" } else { "s" }
            ));
            url = clean;
        }
    }
    let held_all = |bits: u64| bits != 0 && modifiers & bits == bits;
    let (target, rule) = if held_all(config.ask_modifier) {
        (LinkTarget::Ask, None)
    } else {
        match config
            .rules
            .iter()
            .find(|r| rule_matches(r, &url, source_app_id, modifiers))
        {
            Some(rule) => (rule.target.clone(), Some(rule)),
            None => (config.fallback.clone(), None),
        }
    };
    LinkDecision {
        url,
        original: original.to_string(),
        target,
        rule_id: rule.map(|r| r.id.clone()),
        rule_name: rule.map(|r| r.name.clone()),
        changes,
    }
}

fn rule_matches(rule: &LinkRule, url: &str, source: Option<&str>, modifiers: u64) -> bool {
    if !rule.enabled {
        return false;
    }
    if rule.modifiers != 0 && modifiers & rule.modifiers != rule.modifiers {
        return false;
    }
    if !rule.source_app_ids.is_empty()
        && !source.is_some_and(|s| rule.source_app_ids.iter().any(|a| a == s))
    {
        return false;
    }
    pattern_matches(rule.match_kind, &rule.pattern, url)
}

pub fn pattern_matches(kind: MatchKind, pattern: &str, url: &str) -> bool {
    let pattern = pattern.trim();
    if pattern.is_empty() {
        return false;
    }
    match kind {
        MatchKind::Domain => {
            let wanted = pattern
                .trim_start_matches("*.")
                .trim_start_matches("www.")
                .to_lowercase();
            let Some(host) = Url::parse(url)
                .ok()
                .and_then(|u| u.host_str().map(str::to_lowercase))
            else {
                return false;
            };
            let host = host.trim_start_matches("www.");
            host == wanted || host.ends_with(&format!(".{wanted}"))
        }
        MatchKind::Prefix => {
            let strip = |s: &str| {
                s.trim_start_matches("https://")
                    .trim_start_matches("http://")
                    .trim_start_matches("www.")
                    .to_lowercase()
            };
            strip(url).starts_with(&strip(pattern))
        }
        MatchKind::Contains => url.to_lowercase().contains(&pattern.to_lowercase()),
        MatchKind::Regex => regex_for(pattern).is_some_and(|re| re.is_match(url)),
    }
}

// ---- cleaning ------------------------------------------------------------------------------------------------------------

const TRACKING_PARAMS: [&str; 20] = [
    "fbclid",
    "gclid",
    "dclid",
    "gbraid",
    "wbraid",
    "msclkid",
    "yclid",
    "mc_cid",
    "mc_eid",
    "igshid",
    "_hsenc",
    "_hsmi",
    "mkt_tok",
    "ref_src",
    "ref_url",
    "twclid",
    "li_fat_id",
    "vero_id",
    "oly_enc_id",
    "oly_anon_id",
];

fn is_tracking(key: &str, extra: &[String]) -> bool {
    key.starts_with("utm_") || TRACKING_PARAMS.contains(&key) || extra.iter().any(|e| e == key)
}

/// Removes tracking parameters from an address, leaving every other part exactly as it was. Returns the address and how
/// many parameters were taken out.
/// Ready-made rules that try to open a site's links in its own app. They are only a starting point: whether an app takes a
/// web address depends on the app, so each is worth trying once. They are added switched on, next to the person's own.
pub fn suggested_rules() -> Vec<LinkRule> {
    let app = |id: &str, name: &str, domain: &str, app_id: &str| LinkRule {
        id: format!("app-{id}"),
        name: name.to_string(),
        enabled: true,
        match_kind: MatchKind::Domain,
        pattern: domain.to_string(),
        source_app_ids: Vec::new(),
        modifiers: 0,
        target: LinkTarget::Open {
            app_id: app_id.to_string(),
            profile: None,
        },
    };
    vec![
        app("zoom", "Zoom links in Zoom", "zoom.us", "us.zoom.xos"),
        app(
            "figma",
            "Figma links in Figma",
            "figma.com",
            "com.figma.Desktop",
        ),
        app("notion", "Notion links in Notion", "notion.so", "notion.id"),
        app(
            "spotify",
            "Spotify links in Spotify",
            "open.spotify.com",
            "com.spotify.client",
        ),
        app(
            "slack",
            "Slack links in Slack",
            "slack.com",
            "com.tinyspeck.slackmacgap",
        ),
        app(
            "discord",
            "Discord links in Discord",
            "discord.com",
            "com.hnc.Discord",
        ),
        app(
            "linear",
            "Linear links in Linear",
            "linear.app",
            "com.linear",
        ),
        LinkRule {
            id: "dev-localhost".to_string(),
            name: "Ask for localhost links".to_string(),
            enabled: true,
            match_kind: MatchKind::Domain,
            pattern: "localhost".to_string(),
            source_app_ids: Vec::new(),
            modifiers: 0,
            target: LinkTarget::Ask,
        },
    ]
}

pub fn strip_tracking(url: &str, extra: &[String]) -> (String, usize) {
    let hash = url.find('#');
    let question = url.find('?').filter(|q| match hash {
        Some(h) => *q < h,
        None => true,
    });
    let Some(q) = question else {
        return (url.to_string(), 0);
    };
    let end = hash.unwrap_or(url.len());
    let (base, query, fragment) = (&url[..q], &url[q + 1..end], &url[end..]);
    let pairs: Vec<&str> = query.split('&').filter(|p| !p.is_empty()).collect();
    let kept: Vec<&str> = pairs
        .iter()
        .copied()
        .filter(|pair| {
            let key = pair.split('=').next().unwrap_or("").to_lowercase();
            !is_tracking(&key, extra)
        })
        .collect();
    let removed = pairs.len() - kept.len();
    if removed == 0 {
        return (url.to_string(), 0);
    }
    let rebuilt = if kept.is_empty() {
        format!("{base}{fragment}")
    } else {
        format!("{base}?{}{fragment}", kept.join("&"))
    };
    (rebuilt, removed)
}

/// (host, path prefix, parameter that holds the real address)
const REDIRECTS: [(&str, &str, &str); 9] = [
    ("google.com", "/url", "q"),
    ("google.com", "/url", "url"),
    ("facebook.com", "/l.php", "u"),
    ("youtube.com", "/redirect", "q"),
    ("slack-redir.net", "/link", "url"),
    ("safelinks.protection.outlook.com", "/", "url"),
    ("linkedin.com", "/redir/redirect", "url"),
    ("duckduckgo.com", "/l/", "uddg"),
    ("t.umblr.com", "/redirect", "z"),
];

/// The real address inside a known redirect wrapper, or `None` when the address is not one. Nothing is fetched.
pub fn unwrap_redirect(url: &str) -> Option<String> {
    let parsed = Url::parse(url).ok()?;
    let host = parsed.host_str()?.to_lowercase();
    for (suffix, path, param) in REDIRECTS {
        let host_ok = host == suffix || host.ends_with(&format!(".{suffix}"));
        if !host_ok || !parsed.path().starts_with(path) {
            continue;
        }
        let Some(inner) = parsed
            .query_pairs()
            .find(|(k, _)| k == param)
            .map(|(_, v)| v.into_owned())
        else {
            continue;
        };
        let Ok(inner_url) = Url::parse(&inner) else {
            continue;
        };
        if matches!(inner_url.scheme(), "http" | "https") {
            return Some(inner);
        }
    }
    None
}

// ---- storage -----------------------------------------------------------------------------------------------------------------

impl Store {
    pub fn link_routing_config(&self) -> Result<LinkRoutingConfig, CoreError> {
        let conn = self.conn();
        let json: Option<String> = conn
            .query_row(
                "SELECT value FROM settings WHERE key = ?1",
                params![SETTINGS_KEY],
                |r| r.get(0),
            )
            .optional()?;
        Ok(json
            .and_then(|j| serde_json::from_str::<LinkRoutingConfig>(&j).ok())
            .unwrap_or_default()
            .sanitized())
    }

    pub fn save_link_routing_config(&self, config: &LinkRoutingConfig) -> Result<(), CoreError> {
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

    fn open(app: &str) -> LinkTarget {
        LinkTarget::Open {
            app_id: app.into(),
            profile: None,
        }
    }

    fn rule(id: &str, kind: MatchKind, pattern: &str, target: LinkTarget) -> LinkRule {
        LinkRule {
            id: id.into(),
            name: id.into(),
            enabled: true,
            match_kind: kind,
            pattern: pattern.into(),
            source_app_ids: vec![],
            modifiers: 0,
            target,
        }
    }

    fn config(rules: Vec<LinkRule>) -> LinkRoutingConfig {
        LinkRoutingConfig {
            enabled: true,
            rules,
            ..LinkRoutingConfig::default()
        }
    }

    #[test]
    fn suggested_rules_are_valid_unique_and_match_their_sites() {
        let rules = suggested_rules();
        let ids: std::collections::HashSet<_> = rules.iter().map(|r| r.id.clone()).collect();
        assert_eq!(ids.len(), rules.len());
        let config = LinkRoutingConfig {
            enabled: true,
            rules: rules.clone(),
            ..LinkRoutingConfig::default()
        }
        .sanitized();
        assert_eq!(
            config.rules.len(),
            rules.len(),
            "none is thrown out as invalid"
        );
        let decision = resolve_link(&config, "https://us02web.zoom.us/j/123", None, 0);
        assert_eq!(
            decision.target,
            LinkTarget::Open {
                app_id: "us.zoom.xos".into(),
                profile: None
            }
        );
        let local = resolve_link(&config, "http://localhost:3000/x", None, 0);
        assert_eq!(local.target, LinkTarget::Ask);
    }

    #[test]
    fn domain_rules_match_the_site_and_its_subdomains_but_not_look_alikes() {
        let url = |u| pattern_matches(MatchKind::Domain, "example.com", u);
        assert!(url("https://example.com/a"));
        assert!(url("https://www.example.com/a"));
        assert!(url("https://docs.example.com/a?b=1"));
        assert!(!url("https://notexample.com/a"));
        assert!(!url("https://example.com.evil.net/a"));
        assert!(!url("not a url"));
        assert!(pattern_matches(
            MatchKind::Domain,
            "*.example.com",
            "https://a.example.com"
        ));
    }

    #[test]
    fn prefix_contains_and_regex_rules() {
        assert!(pattern_matches(
            MatchKind::Prefix,
            "github.com/acme",
            "https://www.github.com/Acme/repo"
        ));
        assert!(!pattern_matches(
            MatchKind::Prefix,
            "github.com/acme",
            "https://github.com/other/acme"
        ));
        assert!(pattern_matches(
            MatchKind::Contains,
            "/pull/",
            "https://github.com/a/b/pull/12"
        ));
        assert!(pattern_matches(
            MatchKind::Regex,
            r"^https://[a-z]+\.zoom\.us/j/\d+",
            "https://acme.zoom.us/j/123"
        ));
        assert!(
            !pattern_matches(MatchKind::Regex, "([", "anything"),
            "an invalid expression never matches"
        );
        assert!(!pattern_matches(MatchKind::Contains, "  ", "https://x.com"));
    }

    #[test]
    fn the_first_matching_rule_wins_and_a_fallback_catches_the_rest() {
        let cfg = config(vec![
            rule(
                "work",
                MatchKind::Domain,
                "acme.com",
                open("com.google.Chrome"),
            ),
            rule(
                "all-acme-docs",
                MatchKind::Contains,
                "acme",
                open("org.mozilla.firefox"),
            ),
        ]);
        let work = resolve_link(&cfg, "https://acme.com/x", None, 0);
        assert_eq!(work.target, open("com.google.Chrome"));
        assert_eq!(work.rule_id.as_deref(), Some("work"));
        let other = resolve_link(&cfg, "https://news.example.org", None, 0);
        assert_eq!(other.target, open("com.apple.Safari"));
        assert_eq!(other.rule_id, None);
    }

    #[test]
    fn rules_can_depend_on_the_source_app_and_held_keys() {
        let mut from_slack = rule(
            "slack",
            MatchKind::Contains,
            "http",
            open("com.google.Chrome"),
        );
        from_slack.source_app_ids = vec!["com.tinyspeck.slackmacgap".into()];
        let mut with_shift = rule(
            "shift",
            MatchKind::Contains,
            "http",
            open("org.mozilla.firefox"),
        );
        with_shift.modifiers = m::SHIFT;
        let cfg = LinkRoutingConfig {
            ask_modifier: 0,
            ..config(vec![from_slack, with_shift])
        };
        let go =
            |source: Option<&str>, mods| resolve_link(&cfg, "https://x.com", source, mods).target;
        assert_eq!(
            go(Some("com.tinyspeck.slackmacgap"), 0),
            open("com.google.Chrome")
        );
        assert_eq!(go(Some("com.apple.mail"), 0), open("com.apple.Safari"));
        assert_eq!(
            go(None, 0),
            open("com.apple.Safari"),
            "an unknown source matches no source rule"
        );
        assert_eq!(
            go(Some("com.apple.mail"), m::SHIFT),
            open("org.mozilla.firefox")
        );
        assert_eq!(
            go(Some("com.apple.mail"), m::SHIFT | m::COMMAND),
            open("org.mozilla.firefox"),
            "extra keys do not stop it"
        );
    }

    #[test]
    fn the_ask_keys_show_the_chooser_whatever_the_rules_say() {
        let cfg = config(vec![rule(
            "a",
            MatchKind::Contains,
            "x",
            open("com.google.Chrome"),
        )]);
        assert_eq!(
            resolve_link(&cfg, "https://x.com", None, m::OPTION).target,
            LinkTarget::Ask
        );
        let off = LinkRoutingConfig {
            ask_modifier: 0,
            ..cfg
        };
        assert_eq!(
            resolve_link(&off, "https://x.com", None, m::OPTION).target,
            open("com.google.Chrome")
        );
    }

    #[test]
    fn turned_off_links_go_straight_to_the_fallback_untouched() {
        let cfg = LinkRoutingConfig {
            enabled: false,
            ..config(vec![rule("a", MatchKind::Contains, "x", LinkTarget::Copy)])
        };
        let d = resolve_link(&cfg, "https://x.com/?utm_source=a", None, 0);
        assert_eq!(d.url, "https://x.com/?utm_source=a");
        assert_eq!(d.target, open("com.apple.Safari"));
        assert!(d.changes.is_empty());
    }

    #[test]
    fn tracking_parameters_go_and_everything_else_stays_exactly_as_it_was() {
        let (clean, n) = strip_tracking(
            "https://a.com/p?id=7&utm_source=x&q=a%20b&fbclid=Z&utm_medium=m#frag",
            &[],
        );
        assert_eq!(
            (clean.as_str(), n),
            ("https://a.com/p?id=7&q=a%20b#frag", 3)
        );
        assert_eq!(
            strip_tracking("https://a.com/p?utm_source=x", &[]),
            ("https://a.com/p".to_string(), 1)
        );
        assert_eq!(strip_tracking("https://a.com/p?id=1", &[]).1, 0);
        assert_eq!(
            strip_tracking("https://a.com/p#/route?utm_source=x", &[]).1,
            0,
            "a question mark inside the fragment is not a query"
        );
        assert_eq!(
            strip_tracking("https://a.com/?UTM_Source=x&ref=keep", &[]).0,
            "https://a.com/?ref=keep"
        );
        let extra = vec!["spm".to_string()];
        assert_eq!(
            strip_tracking("https://a.com/?spm=1&b=2", &extra).0,
            "https://a.com/?b=2"
        );
    }

    #[test]
    fn known_redirect_wrappers_are_unwrapped() {
        assert_eq!(
            unwrap_redirect(
                "https://www.google.com/url?sa=t&url=https%3A%2F%2Fexample.com%2Fa%3Fb%3D1&usg=x"
            )
            .as_deref(),
            Some("https://example.com/a?b=1")
        );
        assert_eq!(
            unwrap_redirect("https://l.facebook.com/l.php?u=https%3A%2F%2Fexample.com%2F&h=abc")
                .as_deref(),
            Some("https://example.com/")
        );
        assert_eq!(
            unwrap_redirect("https://www.google.com/search?q=cats"),
            None
        );
        assert_eq!(
            unwrap_redirect("https://www.google.com/url?q=javascript%3Aalert(1)"),
            None,
            "only web addresses come out"
        );
        assert_eq!(
            unwrap_redirect("https://example.com/redirect?q=https://evil.com"),
            None,
            "only listed sites are unwrapped"
        );
        assert_eq!(unwrap_redirect("not a url"), None);
    }

    #[test]
    fn resolving_cleans_then_matches_and_describes_what_it_did() {
        let cfg = config(vec![rule(
            "acme",
            MatchKind::Domain,
            "acme.com",
            open("com.google.Chrome"),
        )]);
        let d = resolve_link(
            &cfg,
            "https://www.google.com/url?q=https%3A%2F%2Facme.com%2Fp%3Futm_source%3Dnews%26id%3D4",
            None,
            0,
        );
        assert_eq!(d.url, "https://acme.com/p?id=4");
        assert_eq!(
            d.target,
            open("com.google.Chrome"),
            "the rule sees the real address, not the wrapper"
        );
        assert_eq!(d.changes.len(), 2);
        assert!(d.original.contains("google.com/url"));
    }

    #[test]
    fn rules_that_cannot_work_are_dropped_and_the_rest_tidied() {
        let mut spaced = rule("a", MatchKind::Domain, "  example.com ", open(" com.x "));
        spaced.source_app_ids = vec![" s ".into(), "s".into(), "".into()];
        spaced.modifiers = m::SHIFT | (1 << 40);
        let cfg = LinkRoutingConfig {
            rules: vec![
                spaced,
                rule("a", MatchKind::Domain, "dup-id.com", LinkTarget::Ask),
                rule("bad-regex", MatchKind::Regex, "([", LinkTarget::Ask),
                rule("no-pattern", MatchKind::Contains, "   ", LinkTarget::Ask),
                rule("no-app", MatchKind::Domain, "x.com", open("  ")),
                rule("ask", MatchKind::Domain, "y.com", LinkTarget::Ask),
            ],
            fallback: open(""),
            extra_tracking_params: vec![" SPM ".into(), "spm".into(), "a=b".into(), "".into()],
            ..LinkRoutingConfig::default()
        }
        .sanitized();
        let ids: Vec<&str> = cfg.rules.iter().map(|r| r.id.as_str()).collect();
        assert_eq!(ids, vec!["a", "ask"]);
        assert_eq!(cfg.rules[0].pattern, "example.com");
        assert_eq!(cfg.rules[0].target, open("com.x"));
        assert_eq!(cfg.rules[0].source_app_ids, vec!["s".to_string()]);
        assert_eq!(cfg.rules[0].modifiers, m::SHIFT);
        assert_eq!(
            cfg.fallback,
            open("com.apple.Safari"),
            "an empty browser falls back to Safari"
        );
        assert_eq!(cfg.extra_tracking_params, vec!["spm".to_string()]);
    }

    #[test]
    fn the_configuration_is_stored_and_starts_switched_off() {
        let store = Store::open_in_memory().unwrap();
        assert!(!store.link_routing_config().unwrap().enabled);
        let cfg = LinkRoutingConfig {
            enabled: true,
            rules: vec![rule("a", MatchKind::Domain, "x.com", LinkTarget::Copy)],
            ..LinkRoutingConfig::default()
        };
        store.save_link_routing_config(&cfg).unwrap();
        let back = store.link_routing_config().unwrap();
        assert!(back.enabled);
        assert_eq!(back.rules.len(), 1);
    }
}
