//! Which features are switched off for the app in front.

use crate::model::{FeatureId, Profile};

/// A feature is off when the app's own profile says so, or, if that profile says nothing, when the default
/// profile does. With no matching profile only the default applies. The shells call this on every app switch,
/// so it does no I/O.
pub fn disabled_features(profiles: &[Profile], app_id: Option<&str>) -> Vec<FeatureId> {
    let default = profiles.iter().find(|p| p.is_default);
    let app = app_id.and_then(|id| {
        profiles
            .iter()
            .find(|p| !p.is_default && p.is_enabled && p.app_id.as_deref() == Some(id))
    });
    FeatureId::ALL
        .into_iter()
        .filter(|f| {
            let on = app
                .and_then(|p| p.override_for(*f))
                .or_else(|| default.and_then(|p| p.override_for(*f)))
                .unwrap_or(true);
            !on
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::FeatureOverride;

    fn profile(id: &str, app: Option<&str>, overrides: &[(FeatureId, bool)]) -> Profile {
        Profile {
            id: id.into(),
            name: id.into(),
            app_id: app.map(str::to_string),
            is_default: app.is_none(),
            is_enabled: true,
            feature_overrides: overrides
                .iter()
                .map(|(feature, enabled)| FeatureOverride {
                    feature: *feature,
                    enabled: *enabled,
                })
                .collect(),
            sort_order: 0,
        }
    }

    #[test]
    fn nothing_is_off_by_default() {
        assert!(disabled_features(&[profile("default", None, &[])], Some("x")).is_empty());
    }

    #[test]
    fn app_profile_overrides_default() {
        let profiles = vec![
            profile("default", None, &[(FeatureId::Mouse, false)]),
            profile(
                "game",
                Some("com.game"),
                &[
                    (FeatureId::Mouse, true),
                    (FeatureId::WindowManagement, false),
                ],
            ),
        ];
        assert_eq!(
            disabled_features(&profiles, Some("com.game")),
            vec![FeatureId::WindowManagement]
        );
        assert_eq!(
            disabled_features(&profiles, Some("other")),
            vec![FeatureId::Mouse]
        );
    }

    #[test]
    fn disabled_app_profile_is_ignored() {
        let mut p = profile("game", Some("com.game"), &[(FeatureId::Mouse, false)]);
        p.is_enabled = false;
        let profiles = vec![profile("default", None, &[]), p];
        assert!(disabled_features(&profiles, Some("com.game")).is_empty());
    }
}
