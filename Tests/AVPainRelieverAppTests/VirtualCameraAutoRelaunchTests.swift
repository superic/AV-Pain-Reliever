import Testing
@testable import AVPainRelieverApp

/// The gate on #120's automatic stale-discovery relaunch. Pure inputs,
/// so the whole decline matrix is testable without AVFoundation, CMIO,
/// or a host process that can actually quit.
@Suite("VirtualCameraActivator.autoRelaunchDecision")
struct VirtualCameraAutoRelaunchTests {
    private func decide(
        state: VirtualCameraActivator.State = .requiresRelaunch,
        refinement: VirtualCameraActivator.RebootRefinement = .clean,
        latchAvailable: Bool = true
    ) -> VirtualCameraActivator.AutoRelaunchDecision {
        VirtualCameraActivator.autoRelaunchDecision(
            state: state,
            rebootRefinement: refinement,
            latchAvailable: latchAvailable
        )
    }

    @Test("a clean reboot query plus an unspent latch relaunches")
    func happyPath() {
        #expect(decide() == .relaunch)
    }

    @Test("requiresReboot never auto-relaunches — a bare relaunch loops there")
    func rebootRequiredDeclines() {
        #expect(decide(state: .requiresReboot) == .declineWrongState)
    }

    @Test("only requiresRelaunch is eligible")
    func otherStatesDecline() {
        for state: VirtualCameraActivator.State in [
            .off, .activating, .needsApproval, .on, .failed("boom"),
        ] {
            #expect(decide(state: state) == .declineWrongState)
        }
    }

    @Test("an unanswered reboot query declines rather than guessing")
    func unresolvedRebootQueryDeclines() {
        // Query never came back, and a failed query: either way we
        // can't tell a stale-discovery machine from a #110
        // reboot-required one, and only one of those is helped by a
        // relaunch.
        #expect(decide(refinement: .pending) == .declineRebootUnresolved)
        #expect(decide(refinement: .unavailable) == .declineRebootUnresolved)
    }

    @Test("a spent latch declines — this is the no-loop guarantee")
    func spentLatchDeclines() {
        #expect(decide(latchAvailable: false) == .declineLatchSpent)
    }

    @Test("state is checked before the reboot query and the latch")
    func declinePrecedence() {
        // Ordering matters only for which log line the user's support
        // bundle gets, but the state is the most specific fact so it
        // wins.
        #expect(
            decide(state: .requiresReboot, refinement: .unavailable, latchAvailable: false)
                == .declineWrongState
        )
        #expect(
            decide(refinement: .unavailable, latchAvailable: false)
                == .declineRebootUnresolved
        )
    }
}
