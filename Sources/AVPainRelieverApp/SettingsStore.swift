import Foundation
import Combine
import AVPainReliever
import AVPainRelieverSharedConstants

/// User-tunable behavior toggles. Persisted to `UserDefaults` under the
/// app's domain so settings survive relaunches without us writing
/// anything to the canonical TOML config (which is reserved for
/// profiles).
///
/// Tests inject an `UserDefaults(suiteName:)` instance to keep
/// production defaults clean.
final class SettingsStore: ObservableObject {
    /// Stable keys, public so tests can assert on them.
    enum Key {
        static let notificationsEnabled = "notificationsEnabled"
        static let debounceInterval = "debounceInterval"
        static let showProfileNameInMenuBar = "showProfileNameInMenuBar"
        static let showProfileIconInMenuBar = "showProfileIconInMenuBar"
        static let menuBarIconSymbol = "menuBarIconSymbol"
        static let profileSwitchCount = "profileSwitchCount"
        static let suppressedWelcome = "suppressedWelcome"
        static let launchAtLogin = "launchAtLogin"
        static let virtualCameraEnabled = "virtualCameraEnabled"
        static let experimentalUpdates = "experimentalUpdates"
        static let devUpdates = "devUpdates"
        static let statsTrackingEnabled = "statsTrackingEnabled"
        static let statsStartDate = "statsStartDate"
        static let perProfileCounts = "perProfileCounts"
        static let lastSwitchSlug = "lastSwitchSlug"
        static let lastSwitchDate = "lastSwitchDate"
        static let manualOverrideCount = "manualOverrideCount"
        static let currentStreakDays = "currentStreakDays"
        static let longestStreakDays = "longestStreakDays"
        static let activeDaysCount = "activeDaysCount"
        static let uniqueDeviceFingerprints = "uniqueDeviceFingerprints"
        static let rememberedAudioInputs = "rememberedAudioInputs"
        static let rememberedAudioOutputs = "rememberedAudioOutputs"
        static let rememberedCameras = "rememberedCameras"
        static let ignoredLocations = "ignoredLocations"
        static let noSignalMode = "noSignalMode"
    }

    /// Toast on profile change?  Default on — the at-a-glance signal
    /// is the whole point. Users running back-to-back location changes
    /// or doing demos sometimes want to mute it.
    @Published var notificationsEnabled: Bool {
        didSet { write(notificationsEnabled, forKey: Key.notificationsEnabled) }
    }

    /// USB debounce window in seconds. 1.5s is the validated default
    /// (see docs/decisions.md → Validated decisions). Slider exposes
    /// a 0.5–5.0 range; persisted as Double for the UI.
    @Published var debounceInterval: Double {
        didSet { write(debounceInterval, forKey: Key.debounceInterval) }
    }

    /// Show the active profile name next to the menu bar pill icon.
    /// Default on — users get the at-a-glance "where am I" signal
    /// without opening the menu. Off renders just the icon for a
    /// minimal status item.
    @Published var showProfileNameInMenuBar: Bool {
        didSet { write(showProfileNameInMenuBar, forKey: Key.showProfileNameInMenuBar) }
    }

    /// Swap the menu bar's `pills.fill` glyph for the active profile's
    /// SF Symbol (resolved through `ProfileIcon.effectiveSymbol`).
    /// Default off — the pill icon is the product's identity at a
    /// glance, so opting in is what users do when they want the menu
    /// bar to track location instead.
    @Published var showProfileIconInMenuBar: Bool {
        didSet { write(showProfileIconInMenuBar, forKey: Key.showProfileIconInMenuBar) }
    }

    /// SF Symbol used in the menu bar when no per-profile icon is
    /// active (i.e. when `showProfileIconInMenuBar` is off, or it's
    /// on but no profile has been resolved yet). Default is
    /// `MenuBarIcon.defaultSymbol` so existing installs see no change.
    @Published var menuBarIconSymbol: String {
        didSet { write(menuBarIconSymbol, forKey: Key.menuBarIconSymbol) }
    }

    /// Lifetime count of profile applications. Surfaced as the
    /// "Auto-switches" row in the Stats settings tab. Bumped from
    /// `AppDelegate.handleProfileApplied` on every change-of-profile
    /// (the initial evaluation on launch is intentionally not counted;
    /// see `lastNotifiedName` gating there).
    @Published var profileSwitchCount: Int {
        didSet { write(profileSwitchCount, forKey: Key.profileSwitchCount) }
    }

    /// Set to true the first time the user dismisses the welcome
    /// window OR adds their first profile. Prevents the welcome from
    /// reappearing on subsequent launches.
    @Published var suppressedWelcome: Bool {
        didSet { write(suppressedWelcome, forKey: Key.suppressedWelcome) }
    }

    /// Whether the app should auto-launch at login. Default off so a
    /// fresh user has to opt in (per macOS background-task etiquette).
    /// The injected `applyLoginItem` mirrors this state into the
    /// system's launch services in production, and is a no-op in
    /// tests (otherwise `SMAppService.mainApp.register()` would run
    /// from `swiftpm-testing-helper` and register the test runner
    /// itself as a login item — see `LaunchAtLogin.swift`).
    @Published var launchAtLogin: Bool {
        didSet {
            write(launchAtLogin, forKey: Key.launchAtLogin)
            applyLoginItem(launchAtLogin)
        }
    }

    /// Opt-in toggle for the V2 virtual camera. Default off. When on,
    /// the app installs/activates its CMIO Camera Extension and the
    /// active profile drives the virtual camera's source. When off,
    /// the extension is deactivated and the host capture pipeline is
    /// torn down — keeping the camera light off and AVCapture clients
    /// like Zoom from seeing a stale "AV Pain Reliever" device.
    /// `VirtualCameraActivator` reads this on launch and observes
    /// changes; `AppDelegate.applyVirtualCameraEnabled(_:)` mediates
    /// the actual state transitions.
    @Published var virtualCameraEnabled: Bool {
        didSet { write(virtualCameraEnabled, forKey: Key.virtualCameraEnabled) }
    }

    /// What the virtual camera shows when the real camera has gone
    /// dry past the hold window (see `NoSignalPolicy`). Default is
    /// `.black` — a settled product decision (issue #125): on a live
    /// call it reads as "camera isn't on yet," and it puts no novelty
    /// graphic on a colleague's screen. Test pattern and static noise
    /// are opt-in, more diagnostic/fun than a sane default.
    ///
    /// The extension can't see `UserDefaults.standard` — it's a
    /// separate sandboxed process — so every change (and one pass at
    /// host startup, in `init` below) is mirrored into the shared App
    /// Group container via `publishNoSignalMode`, which also pings
    /// the extension to re-read it. See that property for why it's
    /// injected rather than called statically.
    @Published var noSignalMode: NoSignalMode {
        didSet {
            write(noSignalMode.rawValue, forKey: Key.noSignalMode)
            publishNoSignalMode(noSignalMode)
        }
    }

    /// Opt-in to updates from the `dev` Sparkle channel. Default off.
    /// When on, the Updater's `allowedChannels` delegate hook adds
    /// `"dev"` to the returned set, so feed items tagged
    /// `<sparkle:channel>dev</sparkle:channel>` become eligible.
    /// Project convention: dev releases carry small in-flight features
    /// that ship more frequently than the stable line. Independent of
    /// `experimentalUpdates`; users can opt in to either, both, or
    /// neither.
    @Published var devUpdates: Bool {
        didSet { write(devUpdates, forKey: Key.devUpdates) }
    }

    /// Opt-in to updates from the `experimental` Sparkle channel.
    /// Default off. When on, the Updater's `allowedChannels` delegate
    /// hook adds `"experimental"` to the returned set, so feed items
    /// tagged `<sparkle:channel>experimental</sparkle:channel>` become
    /// eligible. Project convention: experimental releases carry
    /// moonshot work that may break things. Independent of
    /// `devUpdates`; users can opt in to either, both, or neither.
    @Published var experimentalUpdates: Bool {
        didSet { write(experimentalUpdates, forKey: Key.experimentalUpdates) }
    }

    /// Master gate for usage-stats tracking. **Default: off.** With
    /// this false, every `record*` / `increment*` method early-returns
    /// — no fields update, no `UserDefaults` writes happen, no menu
    /// counters advance. Existing values stay frozen and visible (the
    /// user can flip the toggle off after some history without losing
    /// what was already collected). Surfaced in Settings → Advanced.
    @Published var statsTrackingEnabled: Bool {
        didSet {
            write(statsTrackingEnabled, forKey: Key.statsTrackingEnabled)
            // Stamp the start date the *first* time the user opts in.
            // Off → on → off → on must NOT reset it; the user's
            // intent is "I started keeping notes a while back" and
            // the streak / activeDays math relies on a stable origin.
            if statsTrackingEnabled, statsStartDate == nil {
                statsStartDate = Date()
            }
        }
    }

    /// Captured the first time the user enables `statsTrackingEnabled`.
    /// Drives the "Tracking since N days ago" line in Advanced.
    @Published var statsStartDate: Date? {
        didSet { write(statsStartDate, forKey: Key.statsStartDate) }
    }

    /// Count of how many times each profile (by slug) has been
    /// applied since tracking was enabled. Powers the "Switches by
    /// location" rankings in the Stats tab.
    @Published var perProfileCounts: [String: Int] {
        didSet { write(perProfileCounts, forKey: Key.perProfileCounts) }
    }

    /// Slug of the most recently applied profile (set alongside
    /// `lastSwitchDate`). Renders as "Last switched 2h ago to Home
    /// Office" in Advanced.
    @Published var lastSwitchSlug: String? {
        didSet { write(lastSwitchSlug, forKey: Key.lastSwitchSlug) }
    }

    /// Wall-clock time of the most recent recorded switch. Used to
    /// drive the relative-time rendering AND the streak / activeDays
    /// day-bucket math.
    @Published var lastSwitchDate: Date? {
        didSet { write(lastSwitchDate, forKey: Key.lastSwitchDate) }
    }

    /// How many times the user has forced a profile from the menu's
    /// "Switch to …" submenu (vs. the resolver auto-picking one in
    /// response to a USB event). A high count is a soft signal that
    /// the user's profiles aren't quite matching reality and might
    /// want adjustment.
    @Published var manualOverrideCount: Int {
        didSet { write(manualOverrideCount, forKey: Key.manualOverrideCount) }
    }

    /// Consecutive calendar days with at least one recorded switch,
    /// counting today (or the day of the most recent switch).
    @Published var currentStreakDays: Int {
        didSet { write(currentStreakDays, forKey: Key.currentStreakDays) }
    }

    /// All-time maximum value `currentStreakDays` has reached. Never
    /// decreases except via `resetStats()`.
    @Published var longestStreakDays: Int {
        didSet { write(longestStreakDays, forKey: Key.longestStreakDays) }
    }

    /// Total count of distinct calendar days on which at least one
    /// switch was recorded. Diverges from `currentStreakDays` once
    /// any gap appears — a 50-active-day user with an interrupted
    /// streak still has activeDays = 50 even if the current streak
    /// is back to 1.
    @Published var activeDaysCount: Int {
        didSet { write(activeDaysCount, forKey: Key.activeDaysCount) }
    }

    /// Backing storage for the unique-device set. Each entry is the
    /// `(vendorID, productID)` pair as `"<vid>:<pid>"` lowercase hex.
    /// `[String]` so it round-trips cleanly through UserDefaults
    /// without custom encoding. Surfaced as
    /// `uniqueDevicesSeenCount` for the UI.
    @Published var uniqueDeviceFingerprints: [String] {
        didSet { write(uniqueDeviceFingerprints, forKey: Key.uniqueDeviceFingerprints) }
    }

    /// Convenience for the Advanced view — the count is what the UI
    /// actually wants. Computed so it tracks the array without an
    /// extra published field.
    var uniqueDevicesSeenCount: Int { uniqueDeviceFingerprints.count }

    /// Per-profile cache of audio input device names the wizard has
    /// seen referenced by each profile's `audioInput` value over time.
    /// Keyed by profile slug, value is the list of remembered names
    /// (append-only, insertion-order preserved). The Add-Profile
    /// wizard's input picker merges the live CoreAudio snapshot with
    /// `rememberedAudioInputs[editingSlug] ?? []`, so a user editing
    /// Conference Room from home still sees the dock's Yeti in the
    /// dropdown without leaking Home Office's CalDigit into the same
    /// picker.
    ///
    /// Entries persist until the user clicks "Forget unused devices"
    /// in Settings → General, which trims each profile's cache to
    /// only the names that profile currently references.
    @Published var rememberedAudioInputs: [String: [String]] {
        didSet { write(rememberedAudioInputs, forKey: Key.rememberedAudioInputs) }
    }

    /// Per-profile cache of audio output device names. Same shape +
    /// semantics as `rememberedAudioInputs` but segregated because
    /// CoreAudio's device list splits into input-only / output-only
    /// subsets and the wizard's two pickers each consult one half.
    @Published var rememberedAudioOutputs: [String: [String]] {
        didSet { write(rememberedAudioOutputs, forKey: Key.rememberedAudioOutputs) }
    }

    /// Per-profile cache of camera display names. Same shape as the
    /// audio caches.
    @Published var rememberedCameras: [String: [String]] {
        didSet { write(rememberedCameras, forKey: Key.rememberedCameras) }
    }

    /// Device fingerprints the user has dismissed as "not a location"
    /// — e.g. plugging their phone into the laptop on the couch isn't
    /// a real place to capture, just a passing thing. The menu's "Not
    /// a location" button writes here; the engine consults
    /// `isLocationIgnored` and suppresses both the toast and the
    /// "Set Up Location…" affordance for any matching key.
    ///
    /// Persisted as a JSON blob (Codable→Data) because the entries
    /// carry nested structs + a Date; the dict-of-plist approach the
    /// other caches use would force the same fields through
    /// stringly-typed indirection on every read.
    @Published var ignoredLocations: [IgnoredLocation] {
        didSet { writeIgnoredLocations(ignoredLocations) }
    }

    /// True when any profile's remembered-device cache has at least
    /// one entry. Drives the Settings → General "Forget unused
    /// devices" affordance, which only renders when there's
    /// something to wipe.
    var hasRememberedDevices: Bool {
        rememberedAudioInputs.values.contains { !$0.isEmpty }
            || rememberedAudioOutputs.values.contains { !$0.isEmpty }
            || rememberedCameras.values.contains { !$0.isEmpty }
    }

    /// True iff there's user-meaningful stats data (counters
    /// non-zero, dictionaries / arrays non-empty, a last-switch
    /// recorded). Drives both the Reset Stats section's visibility
    /// AND the on-disable "also reset?" prompt.
    ///
    /// `statsStartDate` is intentionally NOT counted here — it's
    /// internal bookkeeping (set on first opt-in, re-stamped on
    /// reset) and a fresh opt-in / opt-out cycle leaves it set
    /// without any data the user would recognize as "stats."
    var hasRecordedStats: Bool {
        profileSwitchCount > 0
            || !perProfileCounts.isEmpty
            || lastSwitchSlug != nil
            || manualOverrideCount > 0
            || activeDaysCount > 0
            || !uniqueDeviceFingerprints.isEmpty
    }

    private let defaults: UserDefaults

    /// Static `ConsoleLogger` for SettingsStore writes. Static so the
    /// init signature stays unchanged (tests still pass a bare
    /// `UserDefaults`). Routes through the same seam as every other
    /// production logger so categories stay filterable in
    /// `log stream`. All writes go via `write(_:forKey:)`.
    private static let logger = ConsoleLogger(category: "settings")

    /// Persist `value` for `key` and emit a debug log line. Centralizes
    /// the `defaults.set` + `.debug` pattern so each `@Published`
    /// `didSet` body stays a single line. Unwraps optionals when
    /// rendering the value so the log line reads `value=2026-05-09`
    /// instead of `value=Optional(2026-05-09)`.
    private func write(_ value: Any?, forKey key: String) {
        defaults.set(value, forKey: key)
        let rendered = value.map { String(describing: $0) } ?? "nil"
        Self.logger.debug("wrote key=\(key) value=\(rendered)")
    }

    /// Closure invoked from `launchAtLogin.didSet` to mirror the
    /// toggle into `SMAppService.mainApp`. Production passes
    /// `LaunchAtLogin.apply(enabled:)`; tests pass a no-op so
    /// `swiftpm-testing-helper` never registers itself as a login
    /// item. Held as an `@MainActor`-isolated property because the
    /// enclosing class is `@MainActor` and the closure may touch
    /// main-actor state.
    private let applyLoginItem: LoginItemApplier

    /// Closure invoked from `noSignalMode.didSet` (and once at
    /// startup, in `init`) to mirror the value into the App Group
    /// container and ping the Camera Extension. Production passes
    /// `NoSignalModePublisher.publish`; tests pass a no-op so
    /// `swift test` never writes into the real shared container or
    /// posts a real Darwin notification a live extension might act
    /// on. Same seam, same rationale as `applyLoginItem` above.
    private let publishNoSignalMode: NoSignalModePublishing

    init(
        defaults: UserDefaults = .standard,
        applyLoginItem: @escaping LoginItemApplier = LaunchAtLogin.apply(enabled:),
        publishNoSignalMode: @escaping NoSignalModePublishing = NoSignalModePublisher.publish
    ) {
        self.defaults = defaults
        self.applyLoginItem = applyLoginItem
        self.publishNoSignalMode = publishNoSignalMode
        // Default-on toggles use `object(forKey:) == nil` to distinguish
        // "never set" (use default) from "set to false" (respect
        // user's choice). `bool(forKey:)` returns false for missing
        // keys, which would silently flip our defaults.
        self.notificationsEnabled = (defaults.object(forKey: Key.notificationsEnabled) as? Bool) ?? true
        self.debounceInterval = (defaults.object(forKey: Key.debounceInterval) as? Double) ?? 1.5
        self.showProfileNameInMenuBar = (defaults.object(forKey: Key.showProfileNameInMenuBar) as? Bool) ?? true
        self.showProfileIconInMenuBar = (defaults.object(forKey: Key.showProfileIconInMenuBar) as? Bool) ?? false
        self.menuBarIconSymbol = (defaults.object(forKey: Key.menuBarIconSymbol) as? String) ?? MenuBarIcon.defaultSymbol
        self.profileSwitchCount = (defaults.object(forKey: Key.profileSwitchCount) as? Int) ?? 0
        self.suppressedWelcome = (defaults.object(forKey: Key.suppressedWelcome) as? Bool) ?? false
        self.launchAtLogin = (defaults.object(forKey: Key.launchAtLogin) as? Bool) ?? false
        self.virtualCameraEnabled = (defaults.object(forKey: Key.virtualCameraEnabled) as? Bool) ?? false
        // Lazy-default rule (CLAUDE.md): read with `object(forKey:) as?
        // String` and parse, never `string(forKey:)`, and never write
        // the default here. An unparsable stored string (a future
        // build removes a case, a hand-edited `defaults write`) falls
        // back to `.black` rather than crashing.
        self.noSignalMode = (defaults.object(forKey: Key.noSignalMode) as? String)
            .flatMap(NoSignalMode.init(rawValue:)) ?? .black
        self.experimentalUpdates = (defaults.object(forKey: Key.experimentalUpdates) as? Bool) ?? false
        self.devUpdates = (defaults.object(forKey: Key.devUpdates) as? Bool) ?? false
        // Stats tracking ships off by default for privacy. Every
        // record / increment method early-returns when this is false.
        self.statsTrackingEnabled = (defaults.object(forKey: Key.statsTrackingEnabled) as? Bool) ?? false
        self.statsStartDate = defaults.object(forKey: Key.statsStartDate) as? Date
        self.perProfileCounts = (defaults.object(forKey: Key.perProfileCounts) as? [String: Int]) ?? [:]
        self.lastSwitchSlug = defaults.object(forKey: Key.lastSwitchSlug) as? String
        self.lastSwitchDate = defaults.object(forKey: Key.lastSwitchDate) as? Date
        self.manualOverrideCount = (defaults.object(forKey: Key.manualOverrideCount) as? Int) ?? 0
        self.currentStreakDays = (defaults.object(forKey: Key.currentStreakDays) as? Int) ?? 0
        self.longestStreakDays = (defaults.object(forKey: Key.longestStreakDays) as? Int) ?? 0
        self.activeDaysCount = (defaults.object(forKey: Key.activeDaysCount) as? Int) ?? 0
        self.uniqueDeviceFingerprints = (defaults.object(forKey: Key.uniqueDeviceFingerprints) as? [String]) ?? []
        self.rememberedAudioInputs = (defaults.object(forKey: Key.rememberedAudioInputs) as? [String: [String]]) ?? [:]
        self.rememberedAudioOutputs = (defaults.object(forKey: Key.rememberedAudioOutputs) as? [String: [String]]) ?? [:]
        self.rememberedCameras = (defaults.object(forKey: Key.rememberedCameras) as? [String: [String]]) ?? [:]
        self.ignoredLocations = Self.readIgnoredLocations(from: defaults)
    }

    /// Mirror the current mode into the shared container without
    /// changing it.
    ///
    /// `noSignalMode`'s `didSet` doesn't fire for its own initial
    /// assignment inside `init` (Swift never calls property observers
    /// there), so a host that starts up and never touches the setting
    /// would leave the extension reading whatever the container last
    /// held. `AppDelegate` calls this once at launch to close that
    /// gap.
    ///
    /// Deliberately NOT called from `init`: constructing a store is
    /// not an event, and a constructor that reaches outside the
    /// process makes every test that builds a store — including ones
    /// with no interest in this setting — write to the real App Group
    /// container and post a live Darwin notification.
    func publishNoSignalModeToExtension() {
        publishNoSignalMode(noSignalMode)
    }

    /// Look up whether a canonical location fingerprint is on the
    /// ignored list. Returns false for the empty list, which is the
    /// install-default state.
    func isLocationIgnored(key: String) -> Bool {
        ignoredLocations.contains(where: { $0.key == key })
    }

    /// Add `entry` to the ignored list. Replaces any existing entry
    /// with the same key (re-ignoring an un-ignored location updates
    /// the captured device names + dismiss time without leaving a
    /// stale duplicate). No-op if `key` is empty.
    func ignoreLocation(_ entry: IgnoredLocation) {
        guard !entry.key.isEmpty else { return }
        var updated = ignoredLocations.filter { $0.key != entry.key }
        updated.append(entry)
        ignoredLocations = updated
    }

    /// Remove the entry with the given canonical key. No-op if no
    /// matching entry exists.
    func unignoreLocation(key: String) {
        let filtered = ignoredLocations.filter { $0.key != key }
        guard filtered.count != ignoredLocations.count else { return }
        ignoredLocations = filtered
    }

    /// JSON-decode the persisted blob. Returns an empty list when the
    /// key is absent OR when decoding fails (which would mean a
    /// schema migration ate the data — we'd rather drop ignores than
    /// crash on launch).
    private static func readIgnoredLocations(from defaults: UserDefaults) -> [IgnoredLocation] {
        guard let data = defaults.data(forKey: Key.ignoredLocations) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([IgnoredLocation].self, from: data)) ?? []
    }

    /// JSON-encode and write the list. Empty list clears the key
    /// entirely so a fresh install sees no leftover ignores from a
    /// prior re-installation under the same domain.
    private func writeIgnoredLocations(_ list: [IgnoredLocation]) {
        if list.isEmpty {
            defaults.removeObject(forKey: Key.ignoredLocations)
            Self.logger.debug("wrote key=\(Key.ignoredLocations) value=nil (cleared)")
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(list) else {
            // Silent data loss otherwise: the user's dismissals would
            // disappear with no diagnostic trail at .debug. Surface
            // it at .error so it appears in the support-log export.
            Self.logger.error("encode failed for key=\(Key.ignoredLocations); \(list.count) ignored-location entries NOT persisted")
            return
        }
        defaults.set(data, forKey: Key.ignoredLocations)
        Self.logger.debug("wrote key=\(Key.ignoredLocations) value=<\(list.count) entries>")
    }

    /// Bump the lifetime switch counter that drives the easter-egg
    /// menu line. Gated by `statsTrackingEnabled` — when off, the
    /// counter freezes at its current value (typically 0 on a fresh
    /// install).
    func incrementSwitchCount() {
        guard statsTrackingEnabled else { return }
        profileSwitchCount += 1
    }

    /// Bump the count of menu-driven manual overrides. Gated.
    func incrementManualOverrideCount() {
        guard statsTrackingEnabled else { return }
        manualOverrideCount += 1
    }

    /// Record one applied profile. Updates per-profile counts,
    /// last-switched fields, and the daily streak / activeDays math.
    /// Gated by `statsTrackingEnabled`.
    ///
    /// Streak rule, evaluated against `lastSwitchDate`'s calendar day
    /// (in the user's local timezone):
    ///
    /// - same day → no streak/activeDays change (just refresh
    ///   `lastSwitchDate` so the relative-time UI stays current)
    /// - exactly one day later → `currentStreakDays += 1`,
    ///   `activeDaysCount += 1`
    /// - older or never → `currentStreakDays = 1`,
    ///   `activeDaysCount += 1`
    ///
    /// `longestStreakDays` is `max(longestStreakDays, currentStreakDays)`
    /// after each update.
    func recordSwitch(toSlug slug: String, at date: Date = Date()) {
        guard statsTrackingEnabled else { return }
        perProfileCounts[slug, default: 0] += 1
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: date)
        if let last = lastSwitchDate {
            let lastDay = calendar.startOfDay(for: last)
            let delta = calendar.dateComponents([.day], from: lastDay, to: today).day ?? 0
            if delta == 0 {
                // Same calendar day — no streak change.
            } else if delta == 1 {
                currentStreakDays += 1
                activeDaysCount += 1
            } else {
                currentStreakDays = 1
                activeDaysCount += 1
            }
        } else {
            currentStreakDays = 1
            activeDaysCount = 1
        }
        if currentStreakDays > longestStreakDays {
            longestStreakDays = currentStreakDays
        }
        lastSwitchSlug = slug
        lastSwitchDate = date
    }

    /// Insert any never-seen `(vendorID, productID)` fingerprints into
    /// the unique-devices set. Gated. Writes back to UserDefaults
    /// only when the set actually grew, so a typical USB-quiet stretch
    /// doesn't touch defaults at all.
    func recordDevicesSeen(_ devices: Set<USBDevice>) {
        guard statsTrackingEnabled else { return }
        let existing = Set(uniqueDeviceFingerprints)
        var grown = existing
        for device in devices {
            grown.insert(Self.fingerprint(for: device))
        }
        if grown.count != existing.count {
            uniqueDeviceFingerprints = grown.sorted()
        }
    }

    /// Append any never-seen audio/camera names into a *specific*
    /// profile's remembered-devices cache. Insertion order is
    /// preserved (no sort here) so a stable "first time we saw it"
    /// record exists per profile. The wizard sorts at display time.
    /// Empty strings are dropped defensively. Only writes back to
    /// UserDefaults for caches that actually grew, so a refresh in a
    /// steady-state location doesn't touch defaults at all.
    ///
    /// Scoping per profile avoids cross-profile leakage: Conference
    /// Room's picker only sees Conference Room's history, never Home
    /// Office's CalDigit. The wizard calls this with its editing
    /// profile's slug.
    ///
    /// Not gated by `statsTrackingEnabled`. These names are
    /// remembered so the wizard's pickers stay useful when devices
    /// aren't currently attached. That's user-facing UI plumbing, not
    /// analytics, so the privacy toggle doesn't apply.
    func rememberDevices(
        forProfile slug: String,
        audioInputs: [String],
        audioOutputs: [String],
        cameras: [String]
    ) {
        let newInputs = Self.appendingNew(
            audioInputs, intoProfile: slug, in: rememberedAudioInputs
        )
        if newInputs != rememberedAudioInputs { rememberedAudioInputs = newInputs }
        let newOutputs = Self.appendingNew(
            audioOutputs, intoProfile: slug, in: rememberedAudioOutputs
        )
        if newOutputs != rememberedAudioOutputs { rememberedAudioOutputs = newOutputs }
        let newCameras = Self.appendingNew(
            cameras, intoProfile: slug, in: rememberedCameras
        )
        if newCameras != rememberedCameras { rememberedCameras = newCameras }
    }

    /// Append entries from `additions` into the per-profile list for
    /// `slug` in `existing`. Returns the unchanged dict when nothing
    /// new appeared (case-sensitive dedupe), so the caller can skip
    /// the assignment and avoid a UserDefaults write.
    private static func appendingNew(
        _ additions: [String],
        intoProfile slug: String,
        in existing: [String: [String]]
    ) -> [String: [String]] {
        let priorList = existing[slug] ?? []
        var seen = Set(priorList)
        var grown = priorList
        for name in additions where !name.isEmpty && !seen.contains(name) {
            grown.append(name)
            seen.insert(name)
        }
        if grown == priorList { return existing }
        var updated = existing
        updated[slug] = grown
        return updated
    }

    /// Trim each profile's remembered-devices cache to only the names
    /// that profile currently references in its audio/camera selections.
    /// Also drops cache entries for profiles that no longer exist
    /// (deleted profiles can't have current selections).
    ///
    /// Wired to the Settings → General "Forget unused devices" button:
    /// a user clicking Forget is asking to drop one-off devices from
    /// the dropdown history without losing names their saved profiles
    /// still depend on. The Settings UI passes in the current profile
    /// list so we can compute the keep-sets per profile.
    ///
    /// Calling with an empty array wipes every profile's cache (no
    /// profile maps to a non-empty keep set), which keeps the test
    /// surface simple.
    ///
    /// Only writes back to UserDefaults for caches that actually
    /// shrank, so a no-op call (everything is in-use, no orphans)
    /// doesn't touch disk.
    func forgetRememberedDevices(currentProfiles profiles: [Profile]) {
        let keepInputs: [String: Set<String>] = Dictionary(
            uniqueKeysWithValues: profiles.map { ($0.name, Set([$0.audioInput].compactMap { $0 })) }
        )
        let keepOutputs: [String: Set<String>] = Dictionary(
            uniqueKeysWithValues: profiles.map { ($0.name, Set([$0.audioOutput].compactMap { $0 })) }
        )
        let keepCameras: [String: Set<String>] = Dictionary(
            uniqueKeysWithValues: profiles.map { ($0.name, Set([$0.camera].compactMap { $0 })) }
        )

        let trimmedInputs = Self.trimming(rememberedAudioInputs, keeping: keepInputs)
        if trimmedInputs != rememberedAudioInputs { rememberedAudioInputs = trimmedInputs }
        let trimmedOutputs = Self.trimming(rememberedAudioOutputs, keeping: keepOutputs)
        if trimmedOutputs != rememberedAudioOutputs { rememberedAudioOutputs = trimmedOutputs }
        let trimmedCameras = Self.trimming(rememberedCameras, keeping: keepCameras)
        if trimmedCameras != rememberedCameras { rememberedCameras = trimmedCameras }
    }

    /// Filter each profile's remembered list to only the names listed
    /// in the corresponding keep set, dropping profiles whose slug
    /// isn't a key in `keeping` (= profile no longer exists). Empty
    /// per-profile lists are removed entirely so `hasRememberedDevices`
    /// flips false when nothing meaningful is left.
    private static func trimming(
        _ cache: [String: [String]],
        keeping: [String: Set<String>]
    ) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for (slug, names) in cache {
            guard let keep = keeping[slug] else { continue }
            let trimmed = names.filter { keep.contains($0) }
            if !trimmed.isEmpty {
                result[slug] = trimmed
            }
        }
        return result
    }

    /// Drop a profile's per-slug stats when the profile itself is
    /// deleted. Removes its `perProfileCounts` entry, and clears
    /// `lastSwitchSlug` / `lastSwitchDate` if the deleted profile was
    /// the most recent one applied. Without that, the Stats tab would
    /// keep rendering "Last switched 3h ago to <ghost>".
    ///
    /// Aggregate counters (`profileSwitchCount`, streaks, active
    /// days, unique devices) are intentionally left alone: they
    /// reflect overall app usage, not which profile happened to win
    /// each switch.
    func forgetProfile(slug: String) {
        if perProfileCounts[slug] != nil {
            perProfileCounts.removeValue(forKey: slug)
        }
        if lastSwitchSlug == slug {
            lastSwitchSlug = nil
            lastSwitchDate = nil
        }
        if rememberedAudioInputs[slug] != nil {
            rememberedAudioInputs.removeValue(forKey: slug)
        }
        if rememberedAudioOutputs[slug] != nil {
            rememberedAudioOutputs.removeValue(forKey: slug)
        }
        if rememberedCameras[slug] != nil {
            rememberedCameras.removeValue(forKey: slug)
        }
    }

    /// Move every piece of per-slug state from `oldSlug` to `newSlug`:
    /// stats counts, the last-switch fields if they pointed at the
    /// old slug, and the three remembered-device caches. Used by the
    /// wizard's rename path so a renamed profile keeps its history
    /// (counters, remembered audio/camera selections) instead of
    /// silently dropping it on save. No-op when `oldSlug == newSlug`
    /// or when neither slug has any data.
    ///
    /// Move-with-overwrite semantics: if `newSlug` already has data,
    /// the move clobbers it. In practice this only matters in the
    /// "Save as new" collision path, where `newSlug` is a suffix the
    /// writer just confirmed is free; for regular rename `newSlug`
    /// is also fresh by construction.
    func renameProfile(from oldSlug: String, to newSlug: String) {
        guard oldSlug != newSlug else { return }
        if let count = perProfileCounts[oldSlug] {
            var updated = perProfileCounts
            updated[oldSlug] = nil
            updated[newSlug] = count
            perProfileCounts = updated
        }
        if lastSwitchSlug == oldSlug {
            lastSwitchSlug = newSlug
        }
        rememberedAudioInputs = Self.movingProfile(from: oldSlug, to: newSlug, in: rememberedAudioInputs)
        rememberedAudioOutputs = Self.movingProfile(from: oldSlug, to: newSlug, in: rememberedAudioOutputs)
        rememberedCameras = Self.movingProfile(from: oldSlug, to: newSlug, in: rememberedCameras)
    }

    private static func movingProfile(
        from oldSlug: String,
        to newSlug: String,
        in cache: [String: [String]]
    ) -> [String: [String]] {
        guard let entries = cache[oldSlug] else { return cache }
        var updated = cache
        updated[oldSlug] = nil
        updated[newSlug] = entries
        return updated
    }

    /// Drop per-slug data (stats + remembered-device caches) whose
    /// profile no longer exists. Called on every config load so any
    /// orphans from an out-of-band path (a hand-edit of profiles.toml,
    /// a migration from a build before this hook covered the cache,
    /// a crash mid-rename) self-heal on next launch. Aggregates
    /// (`profileSwitchCount`, streaks, active days, unique devices)
    /// are intentionally left alone. No-op (no disk write) when
    /// nothing is orphaned.
    func reconcileProfiles(currentSlugs: Set<String>) {
        let staleStatsKeys = perProfileCounts.keys.filter { !currentSlugs.contains($0) }
        if !staleStatsKeys.isEmpty {
            var trimmed = perProfileCounts
            for key in staleStatsKeys { trimmed.removeValue(forKey: key) }
            perProfileCounts = trimmed
        }
        if let last = lastSwitchSlug, !currentSlugs.contains(last) {
            lastSwitchSlug = nil
            lastSwitchDate = nil
        }
        rememberedAudioInputs = Self.dropping(slugsNotIn: currentSlugs, from: rememberedAudioInputs)
        rememberedAudioOutputs = Self.dropping(slugsNotIn: currentSlugs, from: rememberedAudioOutputs)
        rememberedCameras = Self.dropping(slugsNotIn: currentSlugs, from: rememberedCameras)
    }

    private static func dropping(
        slugsNotIn currentSlugs: Set<String>,
        from cache: [String: [String]]
    ) -> [String: [String]] {
        let staleKeys = cache.keys.filter { !currentSlugs.contains($0) }
        guard !staleKeys.isEmpty else { return cache }
        var trimmed = cache
        for key in staleKeys { trimmed.removeValue(forKey: key) }
        return trimmed
    }

    /// Wipe every stats counter / dictionary / last-switched field.
    /// Does NOT touch `statsTrackingEnabled` — that's a separate
    /// privacy choice. If tracking is currently on, `statsStartDate`
    /// is reset to "now" so future records have a fresh origin; if
    /// tracking is off, it's set to nil (it'll re-stamp on next
    /// opt-in). Wired to the Advanced tab's "Reset stats…" button.
    func resetStats() {
        profileSwitchCount = 0
        perProfileCounts = [:]
        lastSwitchSlug = nil
        lastSwitchDate = nil
        manualOverrideCount = 0
        currentStreakDays = 0
        longestStreakDays = 0
        activeDaysCount = 0
        uniqueDeviceFingerprints = []
        statsStartDate = statsTrackingEnabled ? Date() : nil
    }

    /// Stable string fingerprint for a USB device — `"<vid>:<pid>"`
    /// in lowercase 4-char hex. Used as the entry value in
    /// `uniqueDeviceFingerprints`.
    static func fingerprint(for device: USBDevice) -> String {
        String(format: "%04x:%04x", device.vendorID, device.productID)
    }
}
