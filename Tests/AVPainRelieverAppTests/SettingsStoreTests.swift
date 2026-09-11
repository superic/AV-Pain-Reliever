import Testing
import Foundation
@testable import AVPainReliever
@testable import AVPainRelieverApp
import AVPainRelieverSharedConstants

@Suite("SettingsStore")
struct SettingsStoreTests {
    /// A throwaway UserDefaults suite so each test starts clean.
    /// Built fresh per test to avoid cross-test interference.
    private func makeSuite() -> UserDefaults {
        let suiteName = "AVPainRelieverTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    /// Constructs a `SettingsStore` with its out-of-process side
    /// effects defaulted to no-ops: `applyLoginItem` (so `swift test`
    /// never registers `swiftpm-testing-helper` as a login item) and
    /// `publishNoSignalMode` (so `swift test` never writes into the
    /// real App Group container or posts a real Darwin notification
    /// that a Camera Extension running on the developer's machine
    /// might act on). Construction itself publishes nothing —
    /// the startup mirror is `AppDelegate`'s job, precisely so a bare
    /// `SettingsStore(...)` in a test can't reach outside the process
    /// — but any test that *mutates* a seamed property would, so this
    /// helper is how every test in this file builds one. Tests that
    /// need to observe a side effect pass their own closure through
    /// the matching parameter.
    private func makeStore(
        defaults: UserDefaults,
        applyLoginItem: @escaping LoginItemApplier = { _ in },
        publishNoSignalMode: @escaping NoSignalModePublishing = { _ in }
    ) -> SettingsStore {
        SettingsStore(
            defaults: defaults,
            applyLoginItem: applyLoginItem,
            publishNoSignalMode: publishNoSignalMode
        )
    }

    @Test("defaults match the locked product behavior")
    func defaultsAreCorrect() {
        let store = makeStore(defaults: makeSuite())
        #expect(store.notificationsEnabled == true)
        #expect(store.showProfileNameInMenuBar == true)
        #expect(store.debounceInterval == 1.5)
        #expect(store.profileSwitchCount == 0)
        #expect(store.suppressedWelcome == false)
        // Launch-at-login defaults off — fresh users opt in, per
        // macOS background-task etiquette.
        #expect(store.launchAtLogin == false)
        // Virtual camera defaults off — installs a system extension,
        // so opt-in is mandatory both for principle and for
        // notarization etiquette.
        #expect(store.virtualCameraEnabled == false)
        // Experimental updates default off — only the stable channel
        // is consumed unless the user explicitly opts in.
        #expect(store.experimentalUpdates == false)
        // Stats tracking ships off — privacy-first default. All
        // counter / dictionary fields stay empty until the user opts in.
        #expect(store.statsTrackingEnabled == false)
        #expect(store.statsStartDate == nil)
        #expect(store.perProfileCounts.isEmpty)
        #expect(store.lastSwitchSlug == nil)
        #expect(store.lastSwitchDate == nil)
        #expect(store.manualOverrideCount == 0)
        #expect(store.currentStreakDays == 0)
        #expect(store.longestStreakDays == 0)
        #expect(store.activeDaysCount == 0)
        #expect(store.uniqueDevicesSeenCount == 0)
        // No-signal placeholder defaults to black — a settled product
        // decision (issue #125), not something to revisit here.
        #expect(store.noSignalMode == .black)
    }

    @Test("launchAtLogin persists across reloads")
    func launchAtLoginPersists() {
        let defaults = makeSuite()
        do {
            // Pass an explicit no-op `applyLoginItem` so the didSet
            // doesn't reach `SMAppService.mainApp.register()`. Under
            // `swift test` the main app resolves to
            // `swiftpm-testing-helper`, and macOS would register the
            // test runner as a login item every time this test ran.
            let store = makeStore(defaults: defaults, applyLoginItem: { _ in })
            store.launchAtLogin = true
        }
        let reopened = makeStore(defaults: defaults, applyLoginItem: { _ in })
        #expect(reopened.launchAtLogin == true)
    }

    @Test("flipping a default-on toggle to false survives a reload")
    func togglePersists() {
        let defaults = makeSuite()
        do {
            let store = makeStore(defaults: defaults)
            store.notificationsEnabled = false
        }
        // Re-create against the same UserDefaults to simulate restart.
        let reopened = makeStore(defaults: defaults)
        #expect(reopened.notificationsEnabled == false)
    }

    @Test("debounce interval persists across reloads")
    func debouncePersists() {
        let defaults = makeSuite()
        do {
            let store = makeStore(defaults: defaults)
            store.debounceInterval = 2.5
        }
        let reopened = makeStore(defaults: defaults)
        #expect(reopened.debounceInterval == 2.5)
    }

    @Test("incrementSwitchCount persists across reloads when tracking is enabled")
    func switchCountIncrements() {
        let defaults = makeSuite()
        do {
            let store = makeStore(defaults: defaults)
            store.statsTrackingEnabled = true
            store.incrementSwitchCount()
            store.incrementSwitchCount()
            store.incrementSwitchCount()
            #expect(store.profileSwitchCount == 3)
        }
        let reopened = makeStore(defaults: defaults)
        #expect(reopened.profileSwitchCount == 3)
    }

    @Test("suppressedWelcome persists once flipped")
    func welcomeSuppressionPersists() {
        let defaults = makeSuite()
        do {
            let store = makeStore(defaults: defaults)
            store.suppressedWelcome = true
        }
        let reopened = makeStore(defaults: defaults)
        #expect(reopened.suppressedWelcome == true)
    }

    @Test("virtualCameraEnabled persists across reloads")
    func virtualCameraEnabledPersists() {
        let defaults = makeSuite()
        do {
            let store = makeStore(defaults: defaults)
            store.virtualCameraEnabled = true
        }
        let reopened = makeStore(defaults: defaults)
        #expect(reopened.virtualCameraEnabled == true)
    }

    @Test("experimentalUpdates persists across reloads")
    func experimentalUpdatesPersists() {
        let defaults = makeSuite()
        do {
            let store = makeStore(defaults: defaults)
            store.experimentalUpdates = true
        }
        let reopened = makeStore(defaults: defaults)
        #expect(reopened.experimentalUpdates == true)
    }

    // MARK: - No-signal placeholder (issue #125)

    @Test("constructing a fresh SettingsStore does not persist the noSignalMode default")
    func freshStoreDoesNotPersistNoSignalMode() {
        let defaults = makeSuite()
        _ = makeStore(defaults: defaults)
        // Lazy-default rule (CLAUDE.md): a construction-only pass
        // must not write `.black`'s rawValue to disk, or we'd lock in
        // the default and break future evolution of it.
        #expect(defaults.object(forKey: SettingsStore.Key.noSignalMode) == nil)
    }

    @Test("noSignalMode round-trips across two store instances over the same defaults")
    func noSignalModeRoundTrips() {
        let defaults = makeSuite()
        do {
            let store = makeStore(defaults: defaults)
            store.noSignalMode = .testPattern
        }
        let reopened = makeStore(defaults: defaults)
        #expect(reopened.noSignalMode == .testPattern)

        reopened.noSignalMode = .staticNoise
        let reopenedAgain = makeStore(defaults: defaults)
        #expect(reopenedAgain.noSignalMode == .staticNoise)
    }

    @Test("an unparsable stored noSignalMode string falls back to black")
    func noSignalModeUnparsableFallsBackToBlack() {
        let defaults = makeSuite()
        // Could happen if a future build removes a case, or via a
        // hand-edited `defaults write`. Production says fall back to
        // the quietest option rather than crash.
        defaults.set("neon-rainbow", forKey: SettingsStore.Key.noSignalMode)
        let store = makeStore(defaults: defaults)
        #expect(store.noSignalMode == .black)
    }

    @Test("publishNoSignalMode fires on every change, but not on construction")
    func noSignalModePublishesOnChange() {
        var published: [NoSignalMode] = []
        let store = makeStore(
            defaults: makeSuite(),
            publishNoSignalMode: { mode in published.append(mode) }
        )
        // Constructing a store is not an event. If it published here,
        // every test in the suite that builds a store — most of them,
        // with no interest in this setting — would write to the real
        // App Group container and post a live Darwin notification.
        #expect(published.isEmpty)

        store.noSignalMode = .testPattern
        #expect(published == [.testPattern])

        store.noSignalMode = .staticNoise
        #expect(published == [.testPattern, .staticNoise])
    }

    @Test("the startup mirror publishes the current mode on demand")
    func noSignalModeStartupMirrorPublishes() {
        var published: [NoSignalMode] = []
        let defaults = makeSuite()
        defaults.set(NoSignalMode.testPattern.rawValue, forKey: "noSignalMode")
        let store = makeStore(
            defaults: defaults,
            publishNoSignalMode: { mode in published.append(mode) }
        )
        #expect(published.isEmpty)

        // What `AppDelegate` calls at launch, so a host that never
        // touches the picker still seeds the extension's container.
        store.publishNoSignalModeToExtension()
        #expect(published == [.testPattern])
    }

    // MARK: - Stats tracking

    @Test("with tracking off, every record/increment method is a no-op")
    func gatedMethodsNoOpWhenDisabled() {
        let store = makeStore(defaults: makeSuite())
        // Default state: tracking off.
        #expect(store.statsTrackingEnabled == false)

        store.incrementSwitchCount()
        store.incrementManualOverrideCount()
        store.recordSwitch(toSlug: "home-office")
        store.recordDevicesSeen([USBDevice(vendorID: 0x2188, productID: 0x6533)])

        #expect(store.profileSwitchCount == 0)
        #expect(store.manualOverrideCount == 0)
        #expect(store.perProfileCounts.isEmpty)
        #expect(store.lastSwitchSlug == nil)
        #expect(store.lastSwitchDate == nil)
        #expect(store.currentStreakDays == 0)
        #expect(store.longestStreakDays == 0)
        #expect(store.activeDaysCount == 0)
        #expect(store.uniqueDevicesSeenCount == 0)
    }

    @Test("first opt-in stamps statsStartDate; toggling off-on does not re-stamp")
    func optInStampsStartDateOnce() {
        let store = makeStore(defaults: makeSuite())
        #expect(store.statsStartDate == nil)

        let beforeFirst = Date()
        store.statsTrackingEnabled = true
        let stampedFirst = store.statsStartDate
        #expect(stampedFirst != nil)
        // Stamp must be at-or-after the pre-flip moment.
        #expect((stampedFirst ?? .distantPast) >= beforeFirst)

        // Off → on again: should NOT re-stamp.
        store.statsTrackingEnabled = false
        store.statsTrackingEnabled = true
        #expect(store.statsStartDate == stampedFirst)
    }

    @Test("recordSwitch updates per-profile counts and last-switch fields")
    func recordSwitchUpdatesBasics() {
        let store = makeStore(defaults: makeSuite())
        store.statsTrackingEnabled = true

        let t = Date()
        store.recordSwitch(toSlug: "home-office", at: t)
        store.recordSwitch(toSlug: "home-office", at: t)
        store.recordSwitch(toSlug: "conference-room", at: t)

        #expect(store.perProfileCounts["home-office"] == 2)
        #expect(store.perProfileCounts["conference-room"] == 1)
        #expect(store.lastSwitchSlug == "conference-room")
        #expect(store.lastSwitchDate == t)
    }

    @Test("streak: same calendar day does not advance currentStreak or activeDays")
    func streakSameDayNoOp() {
        let store = makeStore(defaults: makeSuite())
        store.statsTrackingEnabled = true
        let morning = Calendar.current.startOfDay(for: Date()).addingTimeInterval(9 * 3600)
        let afternoon = morning.addingTimeInterval(5 * 3600)

        store.recordSwitch(toSlug: "a", at: morning)
        #expect(store.currentStreakDays == 1)
        #expect(store.activeDaysCount == 1)

        store.recordSwitch(toSlug: "b", at: afternoon)
        // Same day — no streak advance, no activeDays increment.
        #expect(store.currentStreakDays == 1)
        #expect(store.activeDaysCount == 1)
    }

    @Test("streak: consecutive days advance; gap resets; longest tracks max")
    func streakAdvanceGapAndLongest() {
        let store = makeStore(defaults: makeSuite())
        store.statsTrackingEnabled = true
        let cal = Calendar.current
        let day0 = cal.startOfDay(for: Date())
        let day1 = cal.date(byAdding: .day, value: 1, to: day0)!
        let day2 = cal.date(byAdding: .day, value: 2, to: day0)!
        let day5 = cal.date(byAdding: .day, value: 5, to: day0)!

        store.recordSwitch(toSlug: "a", at: day0)
        store.recordSwitch(toSlug: "a", at: day1)
        store.recordSwitch(toSlug: "a", at: day2)
        #expect(store.currentStreakDays == 3)
        #expect(store.longestStreakDays == 3)
        #expect(store.activeDaysCount == 3)

        // Gap of 2 days resets the streak; longest is preserved.
        store.recordSwitch(toSlug: "a", at: day5)
        #expect(store.currentStreakDays == 1)
        #expect(store.longestStreakDays == 3)
        #expect(store.activeDaysCount == 4)
    }

    @Test("recordDevicesSeen deduplicates and only writes when set grows")
    func uniqueDevicesDedup() {
        let store = makeStore(defaults: makeSuite())
        store.statsTrackingEnabled = true

        let dock = USBDevice(vendorID: 0x2188, productID: 0x6533)
        let cam = USBDevice(vendorID: 0x046d, productID: 0x085e)

        store.recordDevicesSeen([dock])
        #expect(store.uniqueDevicesSeenCount == 1)

        // Re-seeing the same device shouldn't grow the set.
        store.recordDevicesSeen([dock])
        #expect(store.uniqueDevicesSeenCount == 1)

        store.recordDevicesSeen([dock, cam])
        #expect(store.uniqueDevicesSeenCount == 2)
    }

    @Test("forgetProfile drops per-slug count and clears last-switch fields if they match")
    func forgetProfileClearsPerSlugData() {
        let store = makeStore(defaults: makeSuite())
        store.statsTrackingEnabled = true
        store.recordSwitch(toSlug: "home-office")
        store.recordSwitch(toSlug: "home-office")
        store.recordSwitch(toSlug: "conference-room")

        // Aggregates that should NOT be touched by a per-profile delete.
        let totalBefore = store.profileSwitchCount
        let activeDaysBefore = store.activeDaysCount
        let streakBefore = store.currentStreakDays

        store.forgetProfile(slug: "home-office")

        #expect(store.perProfileCounts["home-office"] == nil)
        #expect(store.perProfileCounts["conference-room"] == 1)
        #expect(store.profileSwitchCount == totalBefore)
        #expect(store.activeDaysCount == activeDaysBefore)
        #expect(store.currentStreakDays == streakBefore)
    }

    @Test("forgetProfile clears lastSwitchSlug only when it matches the deleted slug")
    func forgetProfilePreservesUnrelatedLastSwitch() {
        let store = makeStore(defaults: makeSuite())
        store.statsTrackingEnabled = true
        store.recordSwitch(toSlug: "home-office")
        store.recordSwitch(toSlug: "conference-room")
        // conference-room was the most recent switch.
        #expect(store.lastSwitchSlug == "conference-room")

        store.forgetProfile(slug: "home-office")
        // Unrelated last-switch is untouched.
        #expect(store.lastSwitchSlug == "conference-room")
        #expect(store.lastSwitchDate != nil)

        store.forgetProfile(slug: "conference-room")
        #expect(store.lastSwitchSlug == nil)
        #expect(store.lastSwitchDate == nil)
    }

    @Test("forgetProfile is a no-op for an unknown slug")
    func forgetProfileUnknownSlug() {
        let store = makeStore(defaults: makeSuite())
        store.statsTrackingEnabled = true
        store.recordSwitch(toSlug: "home-office")
        store.forgetProfile(slug: "never-existed")
        #expect(store.perProfileCounts["home-office"] == 1)
        #expect(store.lastSwitchSlug == "home-office")
    }

    @Test("reconcileProfiles drops stats for slugs not in the current set")
    func reconcileProfilesDropsOrphans() {
        let store = makeStore(defaults: makeSuite())
        store.statsTrackingEnabled = true
        store.recordSwitch(toSlug: "home-office")
        store.recordSwitch(toSlug: "conference-room")
        store.recordSwitch(toSlug: "ghost-from-old-build")

        let aggregateBefore = store.profileSwitchCount
        store.reconcileProfiles(currentSlugs: ["home-office", "conference-room"])

        #expect(store.perProfileCounts["home-office"] == 1)
        #expect(store.perProfileCounts["conference-room"] == 1)
        #expect(store.perProfileCounts["ghost-from-old-build"] == nil)
        // Aggregates untouched by reconcile, just like forgetProfile.
        #expect(store.profileSwitchCount == aggregateBefore)
    }

    @Test("reconcileProfiles clears lastSwitch fields when the slug is orphaned")
    func reconcileProfilesClearsOrphanedLastSwitch() {
        let store = makeStore(defaults: makeSuite())
        store.statsTrackingEnabled = true
        store.recordSwitch(toSlug: "home-office")
        store.recordSwitch(toSlug: "ghost")
        // ghost is the most recent.
        #expect(store.lastSwitchSlug == "ghost")

        store.reconcileProfiles(currentSlugs: ["home-office"])
        #expect(store.lastSwitchSlug == nil)
        #expect(store.lastSwitchDate == nil)
    }

    @Test("reconcileProfiles preserves lastSwitch fields when the slug is still present")
    func reconcileProfilesPreservesLiveLastSwitch() {
        let store = makeStore(defaults: makeSuite())
        store.statsTrackingEnabled = true
        store.recordSwitch(toSlug: "ghost")
        store.recordSwitch(toSlug: "home-office")
        #expect(store.lastSwitchSlug == "home-office")

        store.reconcileProfiles(currentSlugs: ["home-office"])
        #expect(store.lastSwitchSlug == "home-office")
        #expect(store.lastSwitchDate != nil)
    }

    @Test("reconcileProfiles is a no-op when every slug is still present")
    func reconcileProfilesAllPresent() {
        let store = makeStore(defaults: makeSuite())
        store.statsTrackingEnabled = true
        store.recordSwitch(toSlug: "home-office")
        store.recordSwitch(toSlug: "conference-room")
        let snapshot = store.perProfileCounts

        store.reconcileProfiles(currentSlugs: ["home-office", "conference-room", "unused-extra"])
        #expect(store.perProfileCounts == snapshot)
        #expect(store.lastSwitchSlug == "conference-room")
    }

    @Test("reconcileProfiles with an empty set drops everything per-slug, leaves aggregates")
    func reconcileProfilesEmptySet() {
        let store = makeStore(defaults: makeSuite())
        store.statsTrackingEnabled = true
        store.recordSwitch(toSlug: "home-office")
        store.recordSwitch(toSlug: "conference-room")
        let aggregateBefore = store.profileSwitchCount
        let streakBefore = store.currentStreakDays

        store.reconcileProfiles(currentSlugs: [])
        #expect(store.perProfileCounts.isEmpty)
        #expect(store.lastSwitchSlug == nil)
        #expect(store.lastSwitchDate == nil)
        #expect(store.profileSwitchCount == aggregateBefore)
        #expect(store.currentStreakDays == streakBefore)
    }

    @Test("resetStats wipes counters; tracking flag is preserved")
    func resetStatsWipes() {
        let defaults = makeSuite()
        let store = makeStore(defaults: defaults)
        store.statsTrackingEnabled = true
        store.incrementSwitchCount()
        store.recordSwitch(toSlug: "home-office")
        store.incrementManualOverrideCount()
        store.recordDevicesSeen([USBDevice(vendorID: 0x2188, productID: 0x6533)])

        let stampBeforeReset = store.statsStartDate
        store.resetStats()

        #expect(store.profileSwitchCount == 0)
        #expect(store.perProfileCounts.isEmpty)
        #expect(store.lastSwitchSlug == nil)
        #expect(store.lastSwitchDate == nil)
        #expect(store.manualOverrideCount == 0)
        #expect(store.currentStreakDays == 0)
        #expect(store.longestStreakDays == 0)
        #expect(store.activeDaysCount == 0)
        #expect(store.uniqueDevicesSeenCount == 0)
        // Tracking stays on; statsStartDate gets re-stamped to "now"
        // (>= the stamp the original opt-in produced).
        #expect(store.statsTrackingEnabled == true)
        #expect((store.statsStartDate ?? .distantPast) >= (stampBeforeReset ?? .distantPast))
    }

    @Test("hasRecordedStats reflects user-meaningful data, not bookkeeping")
    func hasRecordedStatsIgnoresStartDate() {
        let store = makeStore(defaults: makeSuite())
        // Fresh store: nothing.
        #expect(store.hasRecordedStats == false)

        // Pure opt-in stamps statsStartDate but doesn't count as
        // recorded data. Off → on → off should NOT trigger the
        // disable-reset prompt for a user who never actually used
        // the feature.
        store.statsTrackingEnabled = true
        #expect(store.statsStartDate != nil)
        #expect(store.hasRecordedStats == false)

        // Toggling off doesn't change the picture.
        store.statsTrackingEnabled = false
        #expect(store.hasRecordedStats == false)
    }

    @Test("post-reset state is not considered recorded data")
    func hasRecordedStatsAfterReset() {
        let store = makeStore(defaults: makeSuite())
        store.statsTrackingEnabled = true
        store.recordSwitch(toSlug: "home-office")
        #expect(store.hasRecordedStats == true)

        store.resetStats()
        // resetStats stamps statsStartDate to "now" while tracking
        // is on, but every counter / collection is back to zero.
        // The disable-reset prompt MUST not fire just because the
        // start date is set.
        #expect(store.hasRecordedStats == false)
    }

    @Test("recordSwitch and recordDevicesSeen both flip hasRecordedStats true")
    func hasRecordedStatsTrueOnRealActivity() {
        let store = makeStore(defaults: makeSuite())
        store.statsTrackingEnabled = true

        store.recordSwitch(toSlug: "home-office")
        #expect(store.hasRecordedStats == true)

        store.resetStats()
        #expect(store.hasRecordedStats == false)

        store.recordDevicesSeen([USBDevice(vendorID: 0x2188, productID: 0x6533)])
        #expect(store.hasRecordedStats == true)
    }

    // MARK: - Per-profile state migration (delete / rename / reconcile)

    @Test("forgetProfile clears the deleted profile's remembered-device caches")
    func forgetProfileClearsRememberedDeviceCaches() {
        // Regression for the orphan-on-delete bug surfaced by slop
        // review: deleting a profile used to leave its three
        // remembered-* dict entries dangling in UserDefaults until
        // the user found the Forget Unused Devices button.
        let store = makeStore(defaults: makeSuite())
        store.rememberDevices(
            forProfile: "conference-room",
            audioInputs: ["Yeti"],
            audioOutputs: ["Conference Speakers"],
            cameras: ["Conference Cam"]
        )
        // Sanity: the entries exist before the delete.
        #expect(store.rememberedAudioInputs["conference-room"] == ["Yeti"])

        store.forgetProfile(slug: "conference-room")

        #expect(store.rememberedAudioInputs["conference-room"] == nil)
        #expect(store.rememberedAudioOutputs["conference-room"] == nil)
        #expect(store.rememberedCameras["conference-room"] == nil)
    }

    @Test("forgetProfile leaves other profiles' caches intact")
    func forgetProfileSpared() {
        let store = makeStore(defaults: makeSuite())
        store.rememberDevices(
            forProfile: "conference-room",
            audioInputs: ["Yeti"], audioOutputs: [], cameras: []
        )
        store.rememberDevices(
            forProfile: "home-office",
            audioInputs: ["CalDigit"], audioOutputs: [], cameras: []
        )
        store.forgetProfile(slug: "conference-room")
        #expect(store.rememberedAudioInputs["home-office"] == ["CalDigit"])
    }

    @Test("reconcileProfiles drops cache entries for slugs not in the current set")
    func reconcileProfilesDropsCacheOrphans() {
        // Regression for the orphan-survives-reboot path: a profile
        // deleted out-of-band (hand-edit of profiles.toml, missed
        // forgetProfile call) should have its cache cleaned up at
        // the next bootEngine via reconcileProfiles.
        let store = makeStore(defaults: makeSuite())
        store.rememberDevices(
            forProfile: "ghost-from-old-build",
            audioInputs: ["Old Mic"], audioOutputs: [], cameras: []
        )
        store.rememberDevices(
            forProfile: "home-office",
            audioInputs: ["CalDigit"],
            audioOutputs: ["CalDigit"],
            cameras: ["BRIO"]
        )

        store.reconcileProfiles(currentSlugs: ["home-office"])

        #expect(store.rememberedAudioInputs["ghost-from-old-build"] == nil)
        #expect(store.rememberedAudioInputs["home-office"] == ["CalDigit"])
        #expect(store.rememberedCameras["home-office"] == ["BRIO"])
    }

    @Test("renameProfile moves stats and remembered-device caches to the new slug")
    func renameProfileMovesAllPerSlugState() {
        // Regression for the orphan-on-rename bug: renaming Home
        // Office to Apartment should carry the per-profile cache so
        // the wizard's dropdowns keep showing the saved selections
        // under the new identity.
        let store = makeStore(defaults: makeSuite())
        store.statsTrackingEnabled = true
        store.recordSwitch(toSlug: "home-office")
        store.rememberDevices(
            forProfile: "home-office",
            audioInputs: ["Yeti", "AT2020"],
            audioOutputs: ["CalDigit"],
            cameras: ["BRIO"]
        )

        store.renameProfile(from: "home-office", to: "apartment")

        // Old slug is gone.
        #expect(store.perProfileCounts["home-office"] == nil)
        #expect(store.rememberedAudioInputs["home-office"] == nil)
        #expect(store.rememberedAudioOutputs["home-office"] == nil)
        #expect(store.rememberedCameras["home-office"] == nil)
        // New slug carries the migrated state.
        #expect(store.perProfileCounts["apartment"] == 1)
        #expect(store.rememberedAudioInputs["apartment"] == ["Yeti", "AT2020"])
        #expect(store.rememberedAudioOutputs["apartment"] == ["CalDigit"])
        #expect(store.rememberedCameras["apartment"] == ["BRIO"])
        // lastSwitchSlug follows the rename.
        #expect(store.lastSwitchSlug == "apartment")
    }

    @Test("renameProfile is a no-op when old and new slugs match")
    func renameProfileNoOpForSameSlug() {
        let store = makeStore(defaults: makeSuite())
        store.rememberDevices(
            forProfile: "home-office",
            audioInputs: ["Yeti"], audioOutputs: [], cameras: []
        )
        store.renameProfile(from: "home-office", to: "home-office")
        #expect(store.rememberedAudioInputs["home-office"] == ["Yeti"])
    }

    @Test("renameProfile leaves lastSwitchSlug alone when it doesn't point at the renamed profile")
    func renameProfileLeavesUnrelatedLastSwitchAlone() {
        let store = makeStore(defaults: makeSuite())
        store.statsTrackingEnabled = true
        store.recordSwitch(toSlug: "conference-room")
        store.rememberDevices(
            forProfile: "home-office",
            audioInputs: ["Yeti"], audioOutputs: [], cameras: []
        )
        store.renameProfile(from: "home-office", to: "apartment")
        #expect(store.lastSwitchSlug == "conference-room")
    }

    // MARK: - Remembered devices (wizard pickers, per-profile cache)

    @Test("remembered-device caches default to empty dicts")
    func rememberedDevicesDefaultEmpty() {
        let store = makeStore(defaults: makeSuite())
        #expect(store.rememberedAudioInputs.isEmpty)
        #expect(store.rememberedAudioOutputs.isEmpty)
        #expect(store.rememberedCameras.isEmpty)
        #expect(store.hasRememberedDevices == false)
    }

    @Test("rememberDevices appends new names under the profile's slug and dedupes")
    func rememberDevicesAppendsAndDedupes() {
        let store = makeStore(defaults: makeSuite())
        store.rememberDevices(
            forProfile: "home-office",
            audioInputs: ["Yeti", "MacBook Pro Microphone"],
            audioOutputs: ["MacBook Pro Speakers"],
            cameras: ["Built-in", "Logitech BRIO"]
        )
        #expect(store.rememberedAudioInputs["home-office"] == ["Yeti", "MacBook Pro Microphone"])
        #expect(store.rememberedAudioOutputs["home-office"] == ["MacBook Pro Speakers"])
        #expect(store.rememberedCameras["home-office"] == ["Built-in", "Logitech BRIO"])
        #expect(store.hasRememberedDevices == true)

        // Second call for the same profile with overlap + a new entry
        // only appends the new one.
        store.rememberDevices(
            forProfile: "home-office",
            audioInputs: ["Yeti", "Shure MV7"],
            audioOutputs: ["MacBook Pro Speakers"],
            cameras: ["Logitech BRIO"]
        )
        #expect(store.rememberedAudioInputs["home-office"] == ["Yeti", "MacBook Pro Microphone", "Shure MV7"])
        #expect(store.rememberedAudioOutputs["home-office"] == ["MacBook Pro Speakers"])
        #expect(store.rememberedCameras["home-office"] == ["Built-in", "Logitech BRIO"])
    }

    @Test("rememberDevices keeps profiles' caches isolated from each other")
    func rememberDevicesIsolatesProfiles() {
        // The headline behavior for the per-profile redesign: Home
        // Office's CalDigit must NEVER leak into Conference Room's
        // dropdown when the user opens Conference Room's wizard.
        let store = makeStore(defaults: makeSuite())
        store.rememberDevices(
            forProfile: "home-office",
            audioInputs: ["CalDigit TS3 Audio"],
            audioOutputs: ["CalDigit TS3 Audio"],
            cameras: ["Logitech BRIO"]
        )
        store.rememberDevices(
            forProfile: "conference-room",
            audioInputs: ["Yeti Stereo Microphone"],
            audioOutputs: ["Conference Room Speakers"],
            cameras: ["Conference Cam"]
        )
        // Each profile only sees its own entries.
        #expect(store.rememberedAudioInputs["home-office"] == ["CalDigit TS3 Audio"])
        #expect(store.rememberedAudioInputs["conference-room"] == ["Yeti Stereo Microphone"])
        #expect(store.rememberedCameras["home-office"] == ["Logitech BRIO"])
        #expect(store.rememberedCameras["conference-room"] == ["Conference Cam"])
    }

    @Test("rememberDevices drops empty-string inputs defensively")
    func rememberDevicesIgnoresEmptyNames() {
        let store = makeStore(defaults: makeSuite())
        store.rememberDevices(
            forProfile: "home-office",
            audioInputs: ["", "Yeti"],
            audioOutputs: [""],
            cameras: ["", "Built-in"]
        )
        #expect(store.rememberedAudioInputs["home-office"] == ["Yeti"])
        #expect(store.rememberedAudioOutputs["home-office"] == nil)
        #expect(store.rememberedCameras["home-office"] == ["Built-in"])
    }

    @Test("remembered-device caches persist across reloads")
    func rememberedDevicesPersist() {
        let defaults = makeSuite()
        do {
            let store = makeStore(defaults: defaults)
            store.rememberDevices(
                forProfile: "home-office",
                audioInputs: ["Yeti"],
                audioOutputs: ["Studio Display Speakers"],
                cameras: ["Logitech BRIO"]
            )
        }
        let reopened = makeStore(defaults: defaults)
        #expect(reopened.rememberedAudioInputs["home-office"] == ["Yeti"])
        #expect(reopened.rememberedAudioOutputs["home-office"] == ["Studio Display Speakers"])
        #expect(reopened.rememberedCameras["home-office"] == ["Logitech BRIO"])
        #expect(reopened.hasRememberedDevices == true)
    }

    @Test("forget with an empty profiles list wipes every cache entry")
    func forgetWithEmptyProfilesWipes() {
        let store = makeStore(defaults: makeSuite())
        store.rememberDevices(
            forProfile: "home-office",
            audioInputs: ["Yeti"],
            audioOutputs: ["Speakers"],
            cameras: ["BRIO"]
        )
        store.forgetRememberedDevices(currentProfiles: [])
        #expect(store.rememberedAudioInputs.isEmpty)
        #expect(store.rememberedAudioOutputs.isEmpty)
        #expect(store.rememberedCameras.isEmpty)
        #expect(store.hasRememberedDevices == false)
    }

    @Test("forget trims each profile's cache to its current selections")
    func forgetTrimsToCurrentSelections() {
        // Models the journal a profile builds up: Yeti was originally
        // saved, later swapped for AT2020. Both are in the cache
        // (history), but only AT2020 is the current saved value.
        // Forget should drop Yeti and keep AT2020.
        let store = makeStore(defaults: makeSuite())
        store.rememberDevices(
            forProfile: "home-office",
            audioInputs: ["Yeti", "AT2020"],
            audioOutputs: ["Studio Display Speakers", "MacBook Pro Speakers"],
            cameras: ["Logitech BRIO", "Built-in"]
        )
        let homeOffice = Profile(
            name: "home-office",
            fingerprint: [],
            audioInput: "AT2020",
            audioOutput: "MacBook Pro Speakers",
            camera: "Built-in"
        )
        store.forgetRememberedDevices(currentProfiles: [homeOffice])

        #expect(store.rememberedAudioInputs["home-office"] == ["AT2020"])
        #expect(store.rememberedAudioOutputs["home-office"] == ["MacBook Pro Speakers"])
        #expect(store.rememberedCameras["home-office"] == ["Built-in"])
    }

    @Test("forget drops cache entries for profiles that no longer exist")
    func forgetDropsOrphanProfileCaches() {
        let store = makeStore(defaults: makeSuite())
        store.rememberDevices(
            forProfile: "deleted-profile",
            audioInputs: ["Old Mic"],
            audioOutputs: [],
            cameras: []
        )
        store.rememberDevices(
            forProfile: "home-office",
            audioInputs: ["Yeti"],
            audioOutputs: [],
            cameras: []
        )
        let homeOffice = Profile(
            name: "home-office",
            fingerprint: [],
            audioInput: "Yeti"
        )
        store.forgetRememberedDevices(currentProfiles: [homeOffice])

        // Deleted profile's entry is gone; live profile is preserved.
        #expect(store.rememberedAudioInputs["deleted-profile"] == nil)
        #expect(store.rememberedAudioInputs["home-office"] == ["Yeti"])
    }

    @Test("forget keeps profiles' caches with empty saved selections by dropping them entirely")
    func forgetEmptyProfileSelectionWipesProfileEntry() {
        // Profile with nil audioInput etc. has nothing to preserve.
        // The trimming function should drop the cache entry entirely
        // (empty arrays produce nothing meaningful to keep).
        let store = makeStore(defaults: makeSuite())
        store.rememberDevices(
            forProfile: "minimal",
            audioInputs: ["Yeti"],
            audioOutputs: ["Speakers"],
            cameras: ["BRIO"]
        )
        let minimal = Profile(name: "minimal", fingerprint: []) // all selections nil
        store.forgetRememberedDevices(currentProfiles: [minimal])

        #expect(store.rememberedAudioInputs["minimal"] == nil)
        #expect(store.rememberedAudioOutputs["minimal"] == nil)
        #expect(store.rememberedCameras["minimal"] == nil)
        #expect(store.hasRememberedDevices == false)
    }

    @Test("forget is a no-op when every profile's cache already matches its current selections")
    func forgetNoOpWhenEverythingInUse() {
        let store = makeStore(defaults: makeSuite())
        store.rememberDevices(
            forProfile: "home-office",
            audioInputs: ["Yeti"],
            audioOutputs: ["MacBook Pro Speakers"],
            cameras: ["Built-in"]
        )
        let homeOffice = Profile(
            name: "home-office",
            fingerprint: [],
            audioInput: "Yeti",
            audioOutput: "MacBook Pro Speakers",
            camera: "Built-in"
        )
        store.forgetRememberedDevices(currentProfiles: [homeOffice])
        // Nothing changed.
        #expect(store.rememberedAudioInputs["home-office"] == ["Yeti"])
        #expect(store.rememberedAudioOutputs["home-office"] == ["MacBook Pro Speakers"])
        #expect(store.rememberedCameras["home-office"] == ["Built-in"])
    }

    @Test("constructing a fresh SettingsStore does not write defaults to disk")
    func freshStoreDoesNotPersistDefaults() {
        let defaults = makeSuite()
        _ = makeStore(defaults: defaults)
        // The remembered-device caches use the lazy-default-on-read
        // pattern (locked behavior per CLAUDE.md). A construction-only
        // pass must NOT write `[:]` to disk — that would lock in the
        // default and break future evolution of the schema.
        #expect(defaults.object(forKey: SettingsStore.Key.rememberedAudioInputs) == nil)
        #expect(defaults.object(forKey: SettingsStore.Key.rememberedAudioOutputs) == nil)
        #expect(defaults.object(forKey: SettingsStore.Key.rememberedCameras) == nil)
    }

    @Test("ignoreLocation persists across reloads")
    func ignoreLocationRoundTrip() {
        let defaults = makeSuite()
        let entry = IgnoredLocation(
            key: "05ac:12a8",
            devices: [
                IgnoredLocation.Device(
                    vendorID: 0x05ac,
                    productID: 0x12a8,
                    serialNumber: nil,
                    name: "iPhone",
                    vendorName: "Apple Inc."
                )
            ],
            dismissedAt: Date()
        )
        do {
            let store = makeStore(defaults: defaults)
            #expect(store.ignoredLocations.isEmpty)
            #expect(!store.isLocationIgnored(key: entry.key))
            store.ignoreLocation(entry)
            #expect(store.isLocationIgnored(key: entry.key))
        }
        let reopened = makeStore(defaults: defaults)
        #expect(reopened.ignoredLocations.count == 1)
        #expect(reopened.isLocationIgnored(key: entry.key))
        #expect(reopened.ignoredLocations.first?.devices.first?.displayName == "Apple Inc. — iPhone")
    }

    @Test("ignoreLocation replaces an existing entry with the same key")
    func ignoreLocationReplacesDuplicates() {
        let store = makeStore(defaults: makeSuite())
        let first = IgnoredLocation(
            key: "05ac:12a8",
            devices: [],
            dismissedAt: Date(timeIntervalSince1970: 1)
        )
        let second = IgnoredLocation(
            key: "05ac:12a8",
            devices: [
                IgnoredLocation.Device(
                    vendorID: 0x05ac, productID: 0x12a8,
                    serialNumber: nil, name: "iPhone", vendorName: "Apple"
                )
            ],
            dismissedAt: Date(timeIntervalSince1970: 2)
        )
        store.ignoreLocation(first)
        store.ignoreLocation(second)
        #expect(store.ignoredLocations.count == 1)
        // The second write wins (newer dismissedAt + populated device
        // list) — so a user who un-ignores then re-ignores gets the
        // fresher snapshot of names, not the stale one.
        #expect(store.ignoredLocations.first?.devices.count == 1)
        #expect(store.ignoredLocations.first?.dismissedAt.timeIntervalSince1970 == 2)
    }

    @Test("unignoreLocation removes the matching entry and clears storage when empty")
    func unignoreLocationClears() {
        let defaults = makeSuite()
        let entry = IgnoredLocation(
            key: "05ac:12a8",
            devices: [],
            dismissedAt: Date()
        )
        let store = makeStore(defaults: defaults)
        store.ignoreLocation(entry)
        #expect(defaults.data(forKey: SettingsStore.Key.ignoredLocations) != nil)
        store.unignoreLocation(key: entry.key)
        #expect(store.ignoredLocations.isEmpty)
        // Empty list clears the key entirely so a re-installation
        // under the same defaults domain doesn't see ghost entries.
        #expect(defaults.object(forKey: SettingsStore.Key.ignoredLocations) == nil)
    }

    @Test("constructing a fresh SettingsStore does not seed ignoredLocations on disk")
    func freshStoreDoesNotWriteIgnoredLocations() {
        let defaults = makeSuite()
        _ = makeStore(defaults: defaults)
        #expect(defaults.object(forKey: SettingsStore.Key.ignoredLocations) == nil)
    }

    @Test("garbage JSON in ignoredLocations is recovered to an empty list, not a crash")
    func ignoredLocationsDecodeFailureRecovers() {
        let defaults = makeSuite()
        // Plant malformed bytes under the key — could happen after a
        // future schema change, a UserDefaults corruption, or a buggy
        // hand-edit via `defaults write`. Production says we'd rather
        // drop the ignores than crash on launch.
        defaults.set(Data("not valid json".utf8), forKey: SettingsStore.Key.ignoredLocations)

        let store = makeStore(defaults: defaults)
        #expect(store.ignoredLocations.isEmpty)
        #expect(!store.isLocationIgnored(key: "any-key"))

        // Subsequent writes must still work — a wedged read path must
        // not poison the write path. Adding an entry should overwrite
        // the malformed blob with a clean JSON document, and a fresh
        // store opened against the same defaults should now see it.
        let entry = IgnoredLocation(
            key: "05ac:12a8",
            devices: [],
            dismissedAt: Date()
        )
        store.ignoreLocation(entry)
        let reopened = makeStore(defaults: defaults)
        #expect(reopened.ignoredLocations.count == 1)
        #expect(reopened.isLocationIgnored(key: entry.key))
    }

    @Test("LocationFingerprint.canonical is stable regardless of insertion order")
    func locationFingerprintIsOrderStable() {
        let a = USBDevice(vendorID: 0x05ac, productID: 0x12a8)
        let b = USBDevice(vendorID: 0x2188, productID: 0x6533)
        let c = USBDevice(vendorID: 0x043e, productID: 0x9a68, serialNumber: "ABC123")
        let s1: Set<USBDevice> = [a, b, c]
        let s2: Set<USBDevice> = [c, a, b]
        #expect(LocationFingerprint.canonical(for: s1) == LocationFingerprint.canonical(for: s2))
        // Empty set produces empty string — handy for the AppDelegate
        // short-circuit when no devices are attached.
        #expect(LocationFingerprint.canonical(for: []) == "")
    }

    @Test("LocationFingerprint.canonical distinguishes different serials of the same vid/pid")
    func locationFingerprintIncludesSerial() {
        let withSerial = USBDevice(vendorID: 0x043e, productID: 0x9a68, serialNumber: "HOME")
        let otherSerial = USBDevice(vendorID: 0x043e, productID: 0x9a68, serialNumber: "WORK")
        let noSerial = USBDevice(vendorID: 0x043e, productID: 0x9a68, serialNumber: nil)
        let k1 = LocationFingerprint.canonical(for: [withSerial])
        let k2 = LocationFingerprint.canonical(for: [otherSerial])
        let k3 = LocationFingerprint.canonical(for: [noSerial])
        #expect(k1 != k2)
        #expect(k1 != k3)
        #expect(k2 != k3)
    }

    @Test("stats fields persist across reloads")
    func statsFieldsRoundTrip() {
        let defaults = makeSuite()
        let date = Date()
        do {
            let store = makeStore(defaults: defaults)
            store.statsTrackingEnabled = true
            store.recordSwitch(toSlug: "home-office", at: date)
            store.recordSwitch(toSlug: "conference-room", at: date)
            store.incrementManualOverrideCount()
            store.recordDevicesSeen([USBDevice(vendorID: 0x2188, productID: 0x6533)])
        }
        let reopened = makeStore(defaults: defaults)
        #expect(reopened.statsTrackingEnabled == true)
        #expect(reopened.statsStartDate != nil)
        #expect(reopened.perProfileCounts["home-office"] == 1)
        #expect(reopened.perProfileCounts["conference-room"] == 1)
        #expect(reopened.lastSwitchSlug == "conference-room")
        #expect(reopened.manualOverrideCount == 1)
        #expect(reopened.uniqueDevicesSeenCount == 1)
    }
}
