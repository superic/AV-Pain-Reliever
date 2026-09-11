import Testing
import Foundation
import AVPainRelieverSharedConstants

/// `NoSignalPolicy.decide` governs what the virtual camera shows when no
/// frames are arriving. The failure it replaces was privacy-relevant — an
/// unbounded hold could leave a frame from a *previous* call on screen
/// indefinitely — so this suite leans hard on precedence and the
/// threshold boundary rather than just sampling the matrix.
@Suite("NoSignalPolicy.decide")
struct NoSignalPolicyTests {
    private let window = NoSignalPolicy.holdWindowNs

    // MARK: - Full boolean matrix

    @Test("no watchers means idle regardless of held frame or duration")
    func noWatchersIsAlwaysIdle() {
        #expect(NoSignalPolicy.decide(hasWatchers: false, hasHeldFrame: false, dryDurationNs: 0) == .idle)
        #expect(NoSignalPolicy.decide(hasWatchers: false, hasHeldFrame: false, dryDurationNs: .max) == .idle)
        #expect(NoSignalPolicy.decide(hasWatchers: false, hasHeldFrame: true, dryDurationNs: 0) == .idle)
        #expect(NoSignalPolicy.decide(hasWatchers: false, hasHeldFrame: true, dryDurationNs: .max) == .idle)
    }

    @Test("watchers present, no held frame, fresh dry duration: placeholder")
    func watchersNoHeldFrameFreshIsPlaceholder() {
        #expect(NoSignalPolicy.decide(hasWatchers: true, hasHeldFrame: false, dryDurationNs: 0) == .placeholder)
    }

    @Test("watchers present, held frame, fresh dry duration: holdLastFrame")
    func watchersHeldFrameFreshIsHold() {
        #expect(NoSignalPolicy.decide(hasWatchers: true, hasHeldFrame: true, dryDurationNs: 0) == .holdLastFrame)
    }

    @Test("watchers present, held frame, stale dry duration: placeholder")
    func watchersHeldFrameStaleIsPlaceholder() {
        #expect(NoSignalPolicy.decide(hasWatchers: true, hasHeldFrame: true, dryDurationNs: .max) == .placeholder)
    }

    // MARK: - "No held frame" short-circuits the timer

    @Test("no held frame is placeholder at zero duration")
    func noHeldFramePlaceholderAtZero() {
        #expect(NoSignalPolicy.decide(hasWatchers: true, hasHeldFrame: false, dryDurationNs: 0) == .placeholder)
    }

    @Test("no held frame is placeholder even at a huge duration — the timer never gets consulted")
    func noHeldFramePlaceholderAtHugeDuration() {
        #expect(NoSignalPolicy.decide(hasWatchers: true, hasHeldFrame: false, dryDurationNs: .max) == .placeholder)
    }

    // MARK: - Precedence

    @Test("hasWatchers == false wins over a held frame and a fresh duration")
    func noWatchersWinsOverHeldFrameFresh() {
        #expect(NoSignalPolicy.decide(hasWatchers: false, hasHeldFrame: true, dryDurationNs: 0) == .idle)
    }

    @Test("hasWatchers == false wins over a missing held frame")
    func noWatchersWinsOverMissingHeldFrame() {
        #expect(NoSignalPolicy.decide(hasWatchers: false, hasHeldFrame: false, dryDurationNs: 0) == .idle)
    }

    @Test("hasWatchers == false wins over a long dry duration with a held frame")
    func noWatchersWinsOverLongDryDuration() {
        #expect(NoSignalPolicy.decide(hasWatchers: false, hasHeldFrame: true, dryDurationNs: .max) == .idle)
    }

    // MARK: - Threshold boundary, derived from the constant

    @Test("just below the hold window: still holding")
    func justBelowWindowHolds() {
        #expect(
            NoSignalPolicy.decide(hasWatchers: true, hasHeldFrame: true, dryDurationNs: window - 1)
                == .holdLastFrame
        )
    }

    @Test("exactly at the hold window: placeholder, not holding")
    func exactlyAtWindowIsPlaceholder() {
        #expect(
            NoSignalPolicy.decide(hasWatchers: true, hasHeldFrame: true, dryDurationNs: window)
                == .placeholder
        )
    }

    @Test("just above the hold window: placeholder")
    func justAboveWindowIsPlaceholder() {
        #expect(
            NoSignalPolicy.decide(hasWatchers: true, hasHeldFrame: true, dryDurationNs: window + 1)
                == .placeholder
        )
    }

    // MARK: - Extreme dryDurationNs values

    @Test("dryDurationNs of zero with a held frame holds")
    func zeroDurationHolds() {
        #expect(NoSignalPolicy.decide(hasWatchers: true, hasHeldFrame: true, dryDurationNs: 0) == .holdLastFrame)
    }

    @Test("dryDurationNs of UInt64.max with a held frame is placeholder, no overflow")
    func maxDurationIsPlaceholderNoOverflow() {
        #expect(NoSignalPolicy.decide(hasWatchers: true, hasHeldFrame: true, dryDurationNs: .max) == .placeholder)
    }
}

/// `NoSignalMode`'s raw values are a cross-process wire format: the host
/// writes them into the shared App Group container and the camera
/// extension parses them back. A rename here would silently break the
/// extension's `NoSignalMode(rawValue:)` parse rather than fail to build,
/// so the exact strings are pinned rather than just round-tripped.
@Suite("NoSignalMode")
struct NoSignalModeTests {
    @Test("fallback is black")
    func fallbackIsBlack() {
        #expect(NoSignalMode.fallback == .black)
    }

    @Test("raw values are pinned wire-format strings")
    func rawValuesArePinned() {
        #expect(NoSignalMode.black.rawValue == "black")
        #expect(NoSignalMode.testPattern.rawValue == "testPattern")
        #expect(NoSignalMode.staticNoise.rawValue == "staticNoise")
    }

    @Test("every case round-trips through its rawValue")
    func everyCaseRoundTrips() {
        for mode in NoSignalMode.allCases {
            #expect(NoSignalMode(rawValue: mode.rawValue) == mode)
        }
    }
}

/// `NoSignalSharedStore` is the App-Group-backed transport for the
/// setting: the host writes, the extension only reads. Every test here
/// injects a throwaway `UserDefaults` suite so the real App Group
/// container and `UserDefaults.standard` are never touched.
@Suite("NoSignalSharedStore")
struct NoSignalSharedStoreTests {
    /// A throwaway UserDefaults suite so each test starts clean.
    private func makeSuite() -> UserDefaults {
        let suiteName = "AVPainRelieverTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("readMode falls back to .fallback when given a nil container")
    func readModeNilContainerFallsBack() {
        #expect(NoSignalSharedStore.readMode(from: nil) == .fallback)
    }

    @Test("readMode falls back to .fallback when the key is missing")
    func readModeMissingKeyFallsBack() {
        let defaults = makeSuite()
        #expect(NoSignalSharedStore.readMode(from: defaults) == .fallback)
    }

    @Test("readMode falls back to .fallback when the stored string doesn't parse")
    func readModeUnparsableStringFallsBack() {
        let defaults = makeSuite()
        defaults.set("not-a-real-mode", forKey: NoSignalSharedStore.modeKey)
        #expect(NoSignalSharedStore.readMode(from: defaults) == .fallback)
    }

    @Test("readMode returns the stored mode when it parses")
    func readModeReturnsStoredMode() {
        let defaults = makeSuite()
        defaults.set(NoSignalMode.testPattern.rawValue, forKey: NoSignalSharedStore.modeKey)
        #expect(NoSignalSharedStore.readMode(from: defaults) == .testPattern)
    }

    @Test("readMode never writes — the key stays absent after a read on an empty container")
    func readModeDoesNotWrite() {
        let defaults = makeSuite()
        _ = NoSignalSharedStore.readMode(from: defaults)
        #expect(defaults.object(forKey: NoSignalSharedStore.modeKey) == nil)
    }

    @Test("writeMode then readMode round-trips through the shared container")
    func writeThenReadRoundTrips() {
        let defaults = makeSuite()
        NoSignalSharedStore.writeMode(.staticNoise, to: defaults)
        #expect(NoSignalSharedStore.readMode(from: defaults) == .staticNoise)
    }
}
