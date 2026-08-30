import Testing
import Foundation
@testable import AVPainRelieverApp

@Suite("VirtualCameraRelaunchGuard")
struct VirtualCameraRelaunchGuardTests {
    /// A throwaway UserDefaults suite so each test starts clean, same
    /// pattern as SettingsStoreTests.
    private func makeSuite() -> UserDefaults {
        let suiteName = "AVPainRelieverTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("a fresh install has its one automatic relaunch available")
    func freshInstallCanRelaunch() {
        let guardState = VirtualCameraRelaunchGuard(defaults: makeSuite())
        #expect(guardState.canRelaunch)
    }

    @Test("reading the latch never writes it (lazy-default rule)")
    func readDoesNotPersist() {
        let defaults = makeSuite()
        let guardState = VirtualCameraRelaunchGuard(defaults: defaults)
        _ = guardState.canRelaunch
        #expect(defaults.object(forKey: VirtualCameraRelaunchGuard.markerKey) == nil)
    }

    @Test("the marker survives into the process that comes back up")
    func markerPersistsAcrossInstances() {
        let defaults = makeSuite()
        VirtualCameraRelaunchGuard(defaults: defaults).markRelaunched()
        // Separate instance stands in for the relaunched process
        // reading the same defaults domain.
        let afterRelaunch = VirtualCameraRelaunchGuard(defaults: defaults)
        #expect(afterRelaunch.canRelaunch == false)
    }

    @Test("a second failure after the automatic relaunch does not relaunch again")
    func noRelaunchLoop() {
        let defaults = makeSuite()
        let first = VirtualCameraRelaunchGuard(defaults: defaults)
        #expect(first.canRelaunch)
        first.markRelaunched()
        // Fresh process, poll + re-check failed again: the latch is
        // the only thing standing between us and a quit/launch loop.
        #expect(VirtualCameraRelaunchGuard(defaults: defaults).canRelaunch == false)
        // And it stays declined for every later escalation in that
        // process too — nothing clears it but confirmed visibility.
        #expect(VirtualCameraRelaunchGuard(defaults: defaults).canRelaunch == false)
    }

    @Test("confirmed visibility re-arms the automatic relaunch")
    func clearingReArms() {
        let defaults = makeSuite()
        let guardState = VirtualCameraRelaunchGuard(defaults: defaults)
        guardState.markRelaunched()
        guardState.clearRelaunchMarker()
        #expect(guardState.canRelaunch)
        #expect(defaults.object(forKey: VirtualCameraRelaunchGuard.markerKey) == nil)
    }

    @Test("clearing an unset latch touches nothing")
    func clearingUnsetIsNoOp() {
        let defaults = makeSuite()
        let guardState = VirtualCameraRelaunchGuard(defaults: defaults)
        guardState.clearRelaunchMarker()
        #expect(defaults.object(forKey: VirtualCameraRelaunchGuard.markerKey) == nil)
        #expect(guardState.canRelaunch)
    }
}
