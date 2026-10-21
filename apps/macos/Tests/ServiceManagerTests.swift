import XCTest
@testable import Kriya

final class ServiceManagerTests: XCTestCase {
    private var world: TestWorld!
    private var module: FakeModule!
    private var services: ServiceManager!

    override func setUpWithError() throws {
        world = try TestWorld()
        module = FakeModule(.windowManagement)   // needs Accessibility
        let context = world.makeContext()
        services = ServiceManager(context: context, crashGuard: world.crashGuard, modules: [module])
    }

    override func tearDown() {
        world.cleanUp()
    }

    func testFeatureWaitsForPermissionThenStarts() {
        world.config.setEnabled(.windowManagement, true)
        services.reconcile()
        XCTAssertEqual(services.state(.windowManagement), .needsPermission([.accessibility]))
        XCTAssertEqual(module.starts, 0)

        world.probe.granted = [.accessibility]
        world.permissions.refresh()
        services.reconcile()
        XCTAssertEqual(services.state(.windowManagement), .running)
        XCTAssertEqual(module.starts, 1)
    }

    func testRevokingAPermissionStopsTheFeature() {
        world.probe.granted = [.accessibility]
        world.permissions.refresh()
        world.config.setEnabled(.windowManagement, true)
        services.reconcile()
        XCTAssertEqual(module.starts, 1)

        world.probe.granted = []
        world.permissions.refresh()
        services.reconcile()
        XCTAssertEqual(module.stops, 1)
        XCTAssertEqual(services.state(.windowManagement), .needsPermission([.accessibility]))
    }

    func testReconcilingTwiceDoesNotRestartARunningFeature() {
        world.probe.granted = [.accessibility]
        world.permissions.refresh()
        world.config.setEnabled(.windowManagement, true)
        services.reconcile()
        services.reconcile()
        XCTAssertEqual(module.starts, 1)
    }

    func testTurningAFeatureOffStopsIt() {
        world.probe.granted = [.accessibility]
        world.permissions.refresh()
        world.config.setEnabled(.windowManagement, true)
        services.reconcile()
        world.config.setEnabled(.windowManagement, false)
        services.reconcile()
        XCTAssertEqual(module.stops, 1)
        XCTAssertEqual(services.state(.windowManagement), .off)
    }

    func testSafeModeHoldsEverythingOff() {
        world.probe.granted = [.accessibility]
        world.permissions.refresh()
        world.config.setEnabled(.windowManagement, true)
        world.crashGuard.beginSession(forceSafeMode: true)
        services.reconcile()
        XCTAssertEqual(module.starts, 0)
        XCTAssertEqual(services.state(.windowManagement), .safeMode)

        world.crashGuard.leaveSafeMode()
        services.reconcile()
        XCTAssertEqual(module.starts, 1)
    }

    func testAFeatureThatFailsToStartReportsIt() {
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        module.failure = Boom()
        world.probe.granted = [.accessibility]
        world.permissions.refresh()
        world.config.setEnabled(.windowManagement, true)
        services.reconcile()
        XCTAssertEqual(services.state(.windowManagement), .failed("boom"))
    }

    func testEnablingAsksOnlyForTheFirstMissingPermission() {
        services.setFeature(.windowManagement, enabled: true)
        XCTAssertTrue(world.config.isEnabled(.windowManagement))
        XCTAssertEqual(world.probe.requested, [.accessibility])
    }

    func testNothingIsRequestedWhenTheFeatureIsSwitchedOff() {
        services.setFeature(.windowManagement, enabled: false)
        XCTAssertTrue(world.probe.requested.isEmpty)
    }
}
