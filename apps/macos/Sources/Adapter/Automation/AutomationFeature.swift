import AppKit

/// Automation as a switchable feature: while it is on, enabled workflows watch for their triggers. In safe mode, or with
/// the feature off, no workflow starts by itself.
final class AutomationFeature: FeatureModule {
    let feature = FeatureId.automation
    private var context: ServiceContext?

    func start(context: ServiceContext) throws {
        self.context = context
        context.automation.start(context: context)
    }

    func stop() {
        context?.automation.stop()
        context = nil
    }
}
