import Foundation
import AppKit
import AVFoundation
import SwiftUI
import Combine
import AVPainReliever

/// Owns the engine and exposes its current profile to the SwiftUI
/// status item via `@Published`. Created by SwiftUI through
/// `@NSApplicationDelegateAdaptor` in `App.swift`.
/// Bundle of dependencies the Add-Profile wizard needs. Created
/// fresh per-window-open from `AppDelegate.addProfileDependencies()`
/// so the wizard isn't entangled with the engine's lifecycle.
struct AddProfileDependencies {
    let watcher: USBWatcher
    let audioController: AudioController
    let cameraController: CameraController
    let configURL: URL
    let editing: Profile?
    /// Slugs of profiles already saved in the user's config. The
    /// wizard's auto-suggest path consults this to suppress
    /// `ProfileIcon.suggestedName` when the proposed name is
    /// already taken — preventing the wizard from pre-loading a
    /// duplicate name that would collide at save time.
    let existingProfileSlugs: Set<String>
    /// Every saved profile, including the one being edited. The
    /// wizard's view model filters the editing slug out internally,
    /// so callers can pass `availableProfiles` directly without
    /// pre-filtering. Used to label USB rows that belong to a
    /// different location ("In Home Office") rather than letting the
    /// user assume the device is associated with this profile.
    let otherProfiles: [Profile]
    /// Whether the virtual camera is the active routing layer at
    /// wizard-open time. Drives the camera picker's filter (the
    /// virtual camera is hidden from the list) and the helper text
    /// that explains the per-profile camera setting under each mode.
    let virtualCameraEnabled: Bool
    /// Shared preferences store. The wizard appends every live audio
    /// + camera device name into the store's remembered-devices
    /// caches on each refresh, so the pickers can still show the
    /// dock's mic when the user edits the profile from a different
    /// location.
    let settings: SettingsStore
    let onSaved: (_ forceApplySlug: String?) -> Void
}

final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    /// Pretty-cased title shown in the menu bar. Defaults to the
    /// product name until the engine performs its first evaluation.
    @Published var currentProfileTitle: String = "AV Pain Reliever"

    /// Slug of the most-recently-applied profile. Used by the menu's
    /// "Switch to" submenu to put a checkmark next to the active
    /// entry. Differs from `currentProfileTitle` (pretty-cased,
    /// defaults to the product name) — this stays nil until the
    /// engine actually applies something.
    @Published var activeProfileSlug: String? = nil

    /// All profiles loaded from the canonical TOML config — drives
    /// the menu's "Switch to" submenu so the user can force a
    /// specific profile regardless of what's plugged in.
    @Published var availableProfiles: [Profile] = []

    /// True when the engine resolved to the empty-fingerprint fallback
    /// profile (e.g. "Laptop") AND the user has location-signal USB
    /// devices attached (transient plug-ins like flash drives don't
    /// count — see `NamedUSBDevice.isLocationSignal`). That state
    /// means the user is plugged into hardware we don't have a
    /// profile for — the menu should make this visible (the fallback
    /// profile name alone is misleading: it implies "I'm undocked"
    /// when the user is actually at a new dock).
    @Published var atUnknownLocation: Bool = false

    /// Snapshot of attached USB devices the last time the engine
    /// surfaced an unknown-location signal, filtered to
    /// location-signal devices (transient plug-ins like flash drives
    /// are excluded — see `NamedUSBDevice.isLocationSignal`). Used by
    /// the wizard's quick-add path so a user clicking "Set Up This
    /// Location" from the menu lands in the form with the right
    /// devices selected, and by "Not a Location" to persist the
    /// dismissed fingerprint.
    @Published var lastUnknownDevices: Set<USBDevice> = []

    /// Named-device snapshot taken at unknown-location signal time.
    /// Populated alongside `lastUnknownDevices` via a transient
    /// `IOKitUSBWatcher.currentDevicesNamed()` call so the
    /// "Not a Location" dismiss button can persist real product +
    /// vendor names instead of re-enumerating at click time (which
    /// would race against the user unplugging in the same instant).
    private var lastUnknownDevicesNamed: [NamedUSBDevice] = []

    private var engine: Engine?

    /// Watches `profiles.toml` for out-of-band edits and triggers a
    /// reload automatically. Replaces the old "Reload Config" menu
    /// item — users who hand-edit the TOML (or whose sync tools
    /// write to it) get the changes picked up without a click.
    private var configWatcher: ProfileConfigWatcher?

    /// Dedupe gate for the config watcher: tracks the mtime of
    /// `profiles.toml` at the last `bootEngine()` and decides whether
    /// a watcher callback represents an app-originated echo or a real
    /// external change. See `ConfigReloadGate` for semantics.
    private var configReloadGate = ConfigReloadGate()

    /// Owns the lifecycle of the embedded Camera Extension and the
    /// host capture pipeline. SwiftUI views observe this directly
    /// so the Settings UI can show a live status badge as the
    /// extension activates / fails / deactivates. Stable across
    /// `bootEngine()` calls — only `enable()` / `disable()` change
    /// its internal pipeline state.
    let virtualCameraActivator = VirtualCameraActivator()

    /// Pick the bundle-aware UserNotifications notifier when running
    /// inside the signed `.app` (clean icon, click-to-dismiss). Fall
    /// back to the AppleScript shim for `swift run` dev binaries that
    /// don't have a bundle identifier. The bundle-id check matches
    /// the gate used for Sparkle below — same "are we inside a real
    /// .app?" signal.
    private let notifier: Notifier = {
        if Bundle.main.bundleIdentifier == "com.ericwillis.avpainreliever" {
            return UserNotificationsNotifier()
        }
        return AppleScriptNotifier()
    }()

    /// Sparkle updater wrapper. Stored so the underlying
    /// `SPUStandardUpdaterController` outlives every "Check for
    /// Updates…" click and the background-check timer. Constructed
    /// lazily in `applicationDidFinishLaunching` so an SPM unit-test
    /// host that imports the app target doesn't pick up a Sparkle
    /// timer it never asked for.
    private var updater: Updater?

    /// Persistent UI preferences. Owned here so views can be passed a
    /// shared `@ObservedObject` reference; the SettingsView and the
    /// menu both read from this.
    let settings = SettingsStore()

    private let logger = ConsoleLogger(category: "app-delegate")

    /// Profile currently slated for editing. Set by
    /// `beginEditingProfile(_:)` before opening the wizard window;
    /// cleared once the wizard finishes. Reading this when building
    /// the wizard's `AddProfileDependencies` is what swaps it from
    /// "add new" mode to "edit existing".
    private(set) var profileBeingEdited: Profile?

    /// Bumped every time a wizard session begins (Add or Edit). The
    /// wizard window's content view applies this as a SwiftUI `.id`,
    /// which forces a fresh `@StateObject` view model on every open.
    /// Without this, SwiftUI reuses the prior session's view model —
    /// the wizard would appear with stale state from the previous
    /// open (empty Name field on Edit, or vice versa).
    @Published var wizardOpenToken: UUID = UUID()

    /// Bumped every time the About window is about to open. The About
    /// scene applies this as a SwiftUI `.id`, forcing the view tree to
    /// rebuild — which resets the confetti `@State` so the burst plays
    /// fresh on every open instead of just the first.
    @Published var aboutOpenToken: UUID = UUID()

    /// Same trick for the Welcome window. Bumped wherever
    /// `shouldShowWelcome` is flipped to true (first-launch + the
    /// "Show welcome again" link from About) so the welcome view tree
    /// rebuilds and the confetti burst replays on every open.
    @Published var welcomeOpenToken: UUID = UUID()

    private var cancellables: Set<AnyCancellable> = []

    override init() {
        super.init()
        // Drive the activator from the persisted toggle. Skips the
        // initial value (delivered synchronously when the sink
        // attaches) — `applicationDidFinishLaunching` handles the
        // first apply once `submitRequest` is safe to call. Runtime
        // changes (user flipping the toggle in Settings) come
        // through here, and we rebuild the engine afterwards so
        // `ProfileApplier`'s `virtualCameraSource` reference picks
        // up the activator's new lifecycle state.
        settings.$virtualCameraEnabled
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                self?.applyVirtualCameraToggle(enabled: enabled)
            }
            .store(in: &cancellables)
        // The activator's `preferredCameraOverride` flips with state.
        // When state crosses *out of* `.on`, the active profile's
        // camera should be re-applied so the system-wide preferred
        // camera flips back to the real device (and not stay pinned
        // at the now-unhealthy virtual camera). `removeDuplicates`
        // collapses no-op transitions so we don't reapply on every
        // internal `.activating` → `.needsApproval` shimmer.
        //
        // Crossing *into* `.on` is handled separately by
        // `onVisibilityConfirmed` below — firing reapply synchronously
        // on `state → .on` produces a stale-cache `camera not found`
        // error (AVFoundation's DiscoverySession hasn't refreshed yet
        // in this process), so we defer the apply until the
        // visibility check has confirmed the device is reachable.
        virtualCameraActivator.$state
            .map { state -> Bool in
                if case .on = state { return true }
                return false
            }
            .removeDuplicates()
            .dropFirst()
            .filter { !$0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.engine?.reapply()
            }
            .store(in: &cancellables)
        // Counterpart: re-apply once the post-activation visibility
        // check confirms AVFoundation can see "AV Pain Reliever" in
        // this process. See the comment above.
        virtualCameraActivator.onVisibilityConfirmed = { [weak self] in
            self?.engine?.reapply()
        }
        // The activator is about to quit the app to shake off a stale
        // CMIO context (issue #120). Tell the user first — an agent
        // that vanishes and reappears on its own otherwise reads as a
        // crash. Not gated by `notificationsEnabled`: that toggle
        // covers the friendly per-switch toast, not operational
        // notices (same rule as `notifyOfLoadOutcome`).
        virtualCameraActivator.onStaleDiscoveryRelaunch = { [weak self] in
            self?.notifier.notify(
                title: NotificationCopy.cameraSelfRestartTitle,
                body: NotificationCopy.cameraSelfRestartBody,
                iconSymbol: Theme.Symbol.cameraRecovery
            )
        }
        // User cancelled the macOS auth prompt for a deactivate.
        // Activator already restored its state to `.on`; sync the
        // persisted setting so the Settings toggle bounces back, and
        // re-apply the active profile so the system-wide preferred
        // camera flips from the real fallback (set by disable()'s
        // synchronous path) back to the virtual camera.
        virtualCameraActivator.onDeactivateAuthCancelled = { [weak self] in
            guard let self else { return }
            self.settings.virtualCameraEnabled = true
            self.engine?.reapply()
        }
    }

    /// The most recent profile name we surfaced through
    /// `onProfileApplied`. Used to suppress a notification for the
    /// initial evaluation on launch (the menu-bar title is already
    /// up-to-date) and for re-applies of the same profile.
    private var lastNotifiedName: String?

    /// One-shot gate: we only toast about an unknown location once
    /// per "stretch of unknown-ness". Reset to false when the engine
    /// resolves to a profile with a real fingerprint, so docking at a
    /// new unconfigured place after configuring one re-arms the
    /// notification.
    private var notifiedUnknownLocation = false

    /// Slug we're about to force-apply via `engine.applyManually`.
    /// Set right before `reloadConfig()` on the wizard's collision
    /// "Save as new" path; cleared once `handleProfileApplied` sees
    /// the matching name. While set, `handleProfileApplied` swallows
    /// firings that don't match — that suppresses the spurious
    /// resolver-pick toast/counter when the colliding sibling wins
    /// the alphabetical tiebreak. The user perceives one switch
    /// (resolver pick suppressed → force-apply fires through) instead
    /// of two.
    private var pendingForceApplyName: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide the Dock icon programmatically. The eventual signed
        // .app bundle will set LSUIElement = YES in Info.plist, which
        // is the same effect at launch time. For an SPM-built binary
        // we don't have an Info.plist, so we set the activation
        // policy at runtime.
        NSApp.setActivationPolicy(.accessory)
        // Set our brand icon as the app icon — visible in the About
        // window, in window title bars, and as the Dock-icon-on-
        // foreground for windows. Generated at runtime so a palette
        // tweak doesn't need a regenerated `.icns` asset.
        NSApp.applicationIconImage = AppIcon.image
        // Pre-grant camera TCC for the host process. Without this,
        // `AVCaptureDevice.DiscoverySession` from inside the wizard
        // hides the embedded Camera Extension even though Photo
        // Booth and other approved apps see it. Idempotent — once
        // the user has accepted, subsequent launches return
        // immediately without re-prompting.
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { _ in }
        }
        // V2: enable the virtual camera if (a) the user previously
        // turned the Settings toggle on, OR (b) the
        // `AVPR_ACTIVATE_VIRTUAL_CAMERA=1` debug override is set.
        // The override stays in the codebase as a developer
        // affordance — useful for re-activation after a
        // `systemextensionsctl uninstall` without touching the
        // persisted setting. Runs before `bootEngine()` so the
        // engine's first evaluate-and-apply finds a live source.
        let envOverride = ProcessInfo.processInfo
            .environment[VirtualCameraActivator.envVar] == "1"
        if VirtualCameraActivator.shouldAutoEnable(
            persistedToggle: settings.virtualCameraEnabled
        ) {
            virtualCameraActivator.enable(envOverride: envOverride)
        }
        bootEngine()
        applyLaunchAtLoginPreference()
        // Spin up Sparkle only inside a real .app bundle that has a
        // real EdDSA public key embedded. The full predicate (and
        // the reasoning behind each branch) lives on Updater itself
        // so tests can exercise the gate without needing a bundle.
        if Updater.shouldEnable(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            publicKey: Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        ) {
            updater = Updater(settings: settings)
        }
        // Auto-reload on out-of-band edits to profiles.toml. Starts
        // after `bootEngine()` has run inside the init/launch path
        // (via `maybeShowWelcomeWindow`'s upstream chain) so the file
        // is guaranteed to exist by the time the watcher opens it.
        configWatcher = ProfileConfigWatcher(
            url: ProfileBootstrapper.canonicalTOMLURL
        ) { [weak self] in
            self?.handleConfigFileChanged()
        }
        configWatcher?.start()
        maybeShowWelcomeWindow()
    }

    /// Menu-bar entry point — kick off a user-initiated Sparkle check.
    /// No-op when running as an SPM `swift run` binary (updater is nil).
    func checkForUpdates() {
        updater?.checkForUpdates()
    }

    /// Honour the persisted Launch-at-Login preference. Called at
    /// startup so a setting toggled in a previous session takes
    /// effect immediately. Failures (typically because the binary
    /// isn't a signed `.app` yet, so SMAppService can't register it)
    /// are logged but non-fatal — the toggle in Settings will surface
    /// the underlying issue.
    private func applyLaunchAtLoginPreference() {
        LaunchAtLogin.apply(enabled: settings.launchAtLogin)
    }

    /// Set true on first-launch when there are no real-fingerprint
    /// profiles AND the welcome has never been suppressed. App.swift
    /// observes this and opens the welcome window. The fresh-user
    /// starter config still writes (so the engine is operational),
    /// but a single empty-fingerprint laptop fallback doesn't count
    /// as "configured" — only a profile with a real fingerprint does.
    @Published var shouldShowWelcome: Bool = false

    /// Bridge published by the unknown-location notification's
    /// "Open Wizard" action. App.swift's `AddProfileOpener` view
    /// observes this and routes through `openWindow(id:)` — the
    /// SwiftUI environment value isn't reachable from AppDelegate
    /// directly, so we hop via an `@Published` flag the same way
    /// `shouldShowWelcome` does.
    @Published var shouldOpenAddProfileWindow: Bool = false

    /// Initial tab when the Settings window opens. Mutated by the
    /// menu's "Edit Profiles…" item before opening so the user lands
    /// directly on the Profiles list. Reset to `.general` on every
    /// Settings window close (in `SettingsView.onDisappear`) so a
    /// fresh open always starts at the first tab — matches Apple's
    /// own System Settings behavior.
    @Published var settingsTab: SettingsTab = .general

    private func maybeShowWelcomeWindow() {
        guard !settings.suppressedWelcome else { return }
        let configured = availableProfiles.contains { !$0.fingerprint.isEmpty }
        guard !configured else { return }
        // Defer to the next runloop turn so SwiftUI's window graph is
        // ready to receive the openWindow request.
        DispatchQueue.main.async { [weak self] in
            self?.welcomeOpenToken = UUID()
            self?.shouldShowWelcome = true
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Suppress the first-run welcome from this point forward. Called
    /// from both `WelcomeView` callbacks (Skip and Add-Your-First).
    func dismissWelcome() {
        settings.suppressedWelcome = true
        shouldShowWelcome = false
    }

    /// Manual entry point — re-show the welcome window even if it
    /// was previously dismissed. Wired to a "Show Welcome Again"
    /// link in the About scene for users who clicked through too
    /// fast and want another look at the explainer.
    func showWelcomeAgain() {
        // Toggling false→true is what `WelcomeOpener` watches for.
        shouldShowWelcome = false
        DispatchQueue.main.async { [weak self] in
            self?.welcomeOpenToken = UUID()
            self?.shouldShowWelcome = true
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Tear down any existing engine, re-read the config from disk,
    /// and start a fresh engine. Called on launch, from the wizard's
    /// save flow, and indirectly (via `reloadConfig()` from the
    /// mtime-gated `handleConfigFileChanged()`) when the config
    /// watcher detects an out-of-band edit. New callers that
    /// originate from a file event should route through
    /// `handleConfigFileChanged()` so the dedupe gate isn't
    /// bypassed. Notification state
    /// (lastNotifiedName, notifiedUnknownLocation) is intentionally
    /// preserved across reloads — a reload that lands on the same
    /// profile is silent, while one that lands on a different profile
    /// toasts (the user's edit took effect).
    private func bootEngine() {
        engine?.stop()

        let logger = ConsoleLogger()
        let loadOutcome = ProfileBootstrapper().loadOrBootstrap(logger: logger)
        let profiles = loadOutcome.profiles
        // Stamp the mtime as the first thing after bootstrap returns,
        // before any user-visible work. The quarantine + starter-write
        // path produces several FS events that the watcher will see;
        // stamping early ensures its debounced callback finds the new
        // mtime and treats it as an echo.
        configReloadGate.stamp(configMTime())
        availableProfiles = ProfileDisplayOrder.displayOrder(profiles)
        notifyOfLoadOutcome(loadOutcome)
        // Self-heal stats orphaned by anything that bypassed
        // `forgetProfile` (hand-edits to profiles.toml, or migration
        // from a build that predates the delete-time hook).
        settings.reconcileProfiles(currentSlugs: Set(profiles.map(\.name)))
        let engine = buildEngine(profiles: profiles, logger: logger)
        engine.onProfileApplied = { [weak self] profile in
            // Engine fires onProfileApplied on the same thread the
            // debouncer/initial-start ran on (main, in production).
            // SwiftUI requires @Published mutations from the main
            // thread, which is satisfied here.
            self?.handleProfileApplied(profile)
        }
        engine.onUnknownLocation = { [weak self] devices in
            self?.handleUnknownLocation(devices: devices)
        }
        engine.onDevicesEvaluated = { [weak self] devices in
            // Stats: feed the unique-devices set. SettingsStore
            // gates on `statsTrackingEnabled` internally — when the
            // user has tracking off, this is a no-op.
            self?.settings.recordDevicesSeen(devices)

            // Leaving the unknown-location state when the user
            // unplugs everything. The engine's `onUnknownLocation`
            // only fires the entering edge; without this, the
            // fallback profile + empty attached set keeps the flag
            // stuck because `handleProfileApplied`'s clear branch
            // only runs for non-empty-fingerprint profiles.
            if devices.isEmpty {
                self?.clearUnknownLocationState()
            }
        }
        engine.start()
        self.engine = engine
    }

    /// Surface bootstrap outcomes that need user attention. Clean
    /// loads are silent; corruption and unrecoverable cases always
    /// fire (the `notificationsEnabled` toggle gates the friendly
    /// per-switch toast, not operational data-loss alerts). The
    /// corruption toast carries an action that reveals the moved-
    /// aside file in Finder so recovery is one click.
    private func notifyOfLoadOutcome(_ outcome: LoadOutcome) {
        switch outcome {
        case .loaded, .bootstrapped:
            return
        case .quarantinedAndReset(_, let quarantinedAs):
            notifier.notify(
                title: NotificationCopy.configCorruptedTitle,
                body: NotificationCopy.configCorruptedBody(
                    filename: quarantinedAs.lastPathComponent
                ),
                iconSymbol: Theme.Symbol.warning,
                action: .showInFinder,
                onAction: {
                    NSWorkspace.shared.activateFileViewerSelecting([quarantinedAs])
                }
            )
        case .unrecoverable:
            notifier.notify(
                title: NotificationCopy.configUnrecoverableTitle,
                body: NotificationCopy.configUnrecoverableBody,
                iconSymbol: Theme.Symbol.warning
            )
        }
    }

    private func handleProfileApplied(_ profile: Profile) {
        logger.debug("handleProfileApplied: profile=\(profile.name) lastNotified=\(lastNotifiedName ?? "<nil>") pendingForceApply=\(pendingForceApplyName ?? "<nil>")")
        // If a `Save as new` is in flight, `reloadConfig()` will fire
        // this once with the resolver's pick (which loses to the
        // colliding sibling on alphabetical tiebreak). Swallow that
        // fire entirely so the user only sees the force-applied
        // profile land — one toast, one switch counter increment,
        // one menu-bar title update.
        if let pending = pendingForceApplyName {
            if profile.name != pending {
                logger.debug("handleProfileApplied: swallowed (resolver picked \(profile.name), waiting for \(pending))")
                return
            }
            pendingForceApplyName = nil
        }
        let pretty = PrettyName.format(profile.name)
        currentProfileTitle = pretty
        activeProfileSlug = profile.name

        // Toast only on actual changes (different profile name from
        // the previous evaluation). The initial evaluation on launch
        // is intentionally silent — the menu-bar title is already
        // showing the correct profile, so a duplicate toast would
        // just be noise. Settings.notificationsEnabled gates the
        // toast (default on; users can mute from Preferences).
        if let last = lastNotifiedName, last != profile.name {
            logger.debug("handleProfileApplied: real switch \(last) → \(profile.name); recording stats + maybe toasting")
            settings.incrementSwitchCount()
            settings.recordSwitch(toSlug: profile.name)
            if settings.notificationsEnabled {
                notifier.notify(
                    title: NotificationCopy.title(forSlug: profile.name),
                    body: "Audio + camera switched",
                    iconSymbol: ProfileIcon.effectiveSymbol(
                        for: profile.name,
                        override: profile.icon
                    )
                )
            }
        }
        lastNotifiedName = profile.name

        // Re-arm the unknown-location toast if the user just resolved
        // to a profile with a real fingerprint (i.e., they configured
        // the location they were at, or moved to a known one). Also
        // clear the unknown-location menu indicator — it was set by
        // the fallback path; getting back to a real-fingerprint
        // resolution means we're at a known place again.
        if !profile.fingerprint.isEmpty {
            clearUnknownLocationState()
        }
    }

    private func handleUnknownLocation(devices: Set<USBDevice>) {
        // Enumerate names + USB classes *now* so a later
        // "Not a Location" click doesn't race with the user
        // unplugging — see `lastUnknownDevicesNamed` doc comment.
        // Filter to the engine-reported set so we don't accidentally
        // persist devices that weren't part of the unknown
        // fingerprint (the IOKit re-enumeration runs against the
        // live system, which is a superset only on race conditions
        // but cheap to guard against).
        let nameWatcher = IOKitUSBWatcher(logger: ConsoleLogger(category: "unknown-location-watcher"))
        let named = nameWatcher.currentDevicesNamed().filter { devices.contains($0.device) }

        // Transient devices (flash drives, phones — see
        // `NamedUSBDevice.isLocationSignal`) don't count as evidence
        // of a new location. If nothing signal-worthy remains, the
        // user just plugged in a USB stick, not moved desks — stay
        // quiet.
        let signalNamed = named.filter(\.isLocationSignal)
        if signalNamed.isEmpty {
            logger.debug("handleUnknownLocation: \(devices.count) device(s), none location-signal — suppressing UI")
            clearUnknownLocationState()
            return
        }
        let signalDevices = Set(signalNamed.map(\.device))

        // Honor the user's prior dismissal. Pre-existing entries on
        // the ignored list short-circuit before we touch any UI
        // state, so a known-uninteresting device set never
        // resurrects the menu prompt or the toast on subsequent
        // plug-ins. Keyed on the signal subset so "dock" and
        // "dock + USB stick left in the port" dismiss as one
        // location; the full-set key is also checked so entries
        // persisted before transient filtering existed keep working.
        let key = LocationFingerprint.canonical(for: signalDevices)
        let legacyKey = LocationFingerprint.canonical(for: devices)
        if settings.isLocationIgnored(key: key) || settings.isLocationIgnored(key: legacyKey) {
            logger.debug("handleUnknownLocation: ignored fingerprint \(key) — suppressing UI")
            clearUnknownLocationState()
            return
        }

        // Always update the status so the menu reflects the new
        // location even if we've already toasted about it. Setting
        // these every time is cheap and keeps the menu accurate.
        atUnknownLocation = true
        lastUnknownDevices = signalDevices
        lastUnknownDevicesNamed = signalNamed

        // One toast per "stretch of unknown-ness" — re-armed when the
        // user resolves to a specific profile. Avoids spamming when
        // multiple USB events fire at the same unconfigured location.
        guard !notifiedUnknownLocation else { return }
        notifiedUnknownLocation = true
        guard settings.notificationsEnabled else { return }

        notifier.notify(
            title: "New location detected",
            body: NotificationCopy.unknownLocationBody(deviceCount: signalDevices.count),
            iconSymbol: "questionmark.circle",
            action: .openWizard,
            onAction: { [weak self] in
                // UN delivers the action callback on the main queue
                // already, so no extra hop is needed. Toggle the
                // bridge flag and let `AddProfileOpener` route
                // through SwiftUI's `openWindow`.
                self?.shouldOpenAddProfileWindow = true
                NSApp.activate(ignoringOtherApps: true)
            }
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        configWatcher?.stop()
        engine?.stop()
    }

    /// Re-read the config file from disk and rebuild the engine with
    /// the new profile list. Drives the post-wizard refresh and the
    /// post-delete refresh; the config watcher calls this when
    /// `profiles.toml` changes out-of-band.
    func reloadConfig() {
        logger.debug("reloadConfig")
        bootEngine()
    }

    /// Called by `ProfileConfigWatcher` after debouncing a file
    /// event. Routes through `ConfigReloadGate` so an app-originated
    /// write (already loaded by `bootEngine()`) doesn't echo back as
    /// a redundant reload that would stomp on transient state like
    /// `pendingForceApplyName`.
    private func handleConfigFileChanged() {
        let current = configMTime()
        guard configReloadGate.shouldReload(currentMTime: current) else {
            logger.debug("config-watcher: ignoring echo (mtime \(current as Any))")
            return
        }
        logger.info("config-watcher: external change detected, reloading")
        reloadConfig()
    }

    private func configMTime() -> Date? {
        let path = ProfileBootstrapper.canonicalTOMLURL.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        return attrs[.modificationDate] as? Date
    }

    /// Menu-bar entry point — force-apply a specific profile,
    /// bypassing the resolver. The override is one-shot: the next
    /// genuine USB event re-runs the resolver normally and may pick
    /// a different profile. Useful when the user wants to test a
    /// configuration or apply a "wrong-for-now" profile (e.g. set
    /// home-office audio defaults while undocked).
    func applyManually(_ profile: Profile) {
        logger.debug("applyManually \(profile.name)")
        // Stats: every menu-driven force-apply increments the
        // manual-override counter. The engine still goes on to fire
        // `onProfileApplied`, which counts this as a regular switch
        // too — that's correct: it IS a switch, just one the user
        // forced. Both counters are gated on `statsTrackingEnabled`.
        settings.incrementManualOverrideCount()
        engine?.applyManually(profile)
    }

    /// Build a fresh dependency bundle for the Add-Profile wizard.
    /// We hand the wizard its own `IOKitUSBWatcher` /
    /// `CoreAudioController` instances rather than reaching into
    /// the engine's internals — both are cheap to construct and the
    /// wizard's snapshot calls don't compete with the engine's
    /// long-lived watcher.
    ///
    /// `editing` is consumed once per wizard window: the next call
    /// returns the edit target, and clearing it after the bundle is
    /// built ensures a subsequent "Add Profile…" doesn't accidentally
    /// reopen in edit mode.
    func addProfileDependencies() -> AddProfileDependencies {
        let editing = profileBeingEdited
        profileBeingEdited = nil
        // Snapshot the current profile slugs at wizard-open time so
        // the auto-suggest can avoid proposing a name the user
        // already has. When editing, exclude the editing profile's
        // own slug so its name doesn't suppress its own suggestion
        // (the wizard's name field is pre-populated from the
        // editing profile separately).
        let existing = Set(availableProfiles.map(\.name))
            .subtracting([editing?.name].compactMap { $0 })
        return AddProfileDependencies(
            watcher: IOKitUSBWatcher(),
            audioController: CoreAudioController(),
            cameraController: AVFoundationCameraController(),
            configURL: ProfileBootstrapper.canonicalTOMLURL,
            editing: editing,
            existingProfileSlugs: existing,
            otherProfiles: availableProfiles,
            virtualCameraEnabled: virtualCameraActivator.state == .on,
            settings: settings,
            onSaved: { [weak self] forceApplySlug in
                // Saving any profile is taken as the user being
                // committed — no need to keep showing the welcome
                // window if it was queued.
                guard let self else { return }
                self.dismissWelcome()

                // For the wizard's collision "Save as new" path,
                // the new profile shares its fingerprint with the
                // colliding sibling, so `ProfileResolver`'s
                // alphabetical tiebreak would pick the older sibling
                // and the user-visible audio/camera state wouldn't
                // change. Set the suppression flag, reload (which
                // fires the resolver's wrong pick — swallowed), then
                // explicitly apply the new profile.
                if let slug = forceApplySlug {
                    self.pendingForceApplyName = slug
                    self.reloadConfig()
                    if let profile = self.availableProfiles.first(where: { $0.name == slug }) {
                        self.engine?.applyManually(profile)
                    } else {
                        // Lookup failed (config race / disk error).
                        // Clear the gate so future evaluations aren't
                        // dropped.
                        self.pendingForceApplyName = nil
                    }
                } else {
                    self.reloadConfig()
                }
            }
        )
    }

    /// Stash the profile to edit + bump the wizard-session token so
    /// SwiftUI tears down any prior wizard view model and rebuilds
    /// it with this profile pre-filled. Call this immediately before
    /// `openWindow(id: addProfileWindowID)`.
    func beginEditingProfile(_ profile: Profile) {
        profileBeingEdited = profile
        wizardOpenToken = UUID()
    }

    /// Prep the wizard for a fresh "add new profile" session — clears
    /// any pending edit and bumps the session token. Mirror of
    /// `beginEditingProfile(_:)`; both should be called immediately
    /// before `openWindow(id: addProfileWindowID)`.
    func beginAddingProfile() {
        profileBeingEdited = nil
        wizardOpenToken = UUID()
    }

    /// Bump the About-scene token so SwiftUI rebuilds the view tree
    /// next time the window is shown. Call immediately before
    /// `openWindow(id: aboutWindowID)`.
    func willOpenAbout() {
        aboutOpenToken = UUID()
    }

    /// Delete a profile from the on-disk config and reload the engine.
    /// Caller (the SwiftUI Profiles tab) owns the confirmation alert
    /// — keeping the confirmation in SwiftUI lets it render with
    /// native `.alert()` chrome (no app-icon badge) matching the
    /// other destructive prompts in Settings (Reset stats, etc.).
    /// On failure, surfaces an NSAlert because the error path is
    /// rare and doesn't have a sensible SwiftUI escape hatch from
    /// here.
    func deleteProfile(_ profile: Profile) {
        let pretty = PrettyName.format(profile.name)
        logger.debug("deleteProfile \(profile.name)")
        do {
            try ProfileWriter().delete(named: profile.name, in: ProfileBootstrapper.canonicalTOMLURL)
            settings.forgetProfile(slug: profile.name)
            reloadConfig()
        } catch {
            let failure = NSAlert()
            failure.messageText = "Couldn't delete “\(pretty)”"
            failure.informativeText = "\(error)"
            failure.alertStyle = .critical
            failure.icon = AppIcon.image
            failure.runModal()
        }
    }

    /// Dismiss the current "new location" suggestion. Persists the
    /// fingerprint of the attached device set so subsequent plug-ins
    /// of the same combination don't re-toast or re-show the
    /// "Set Up Location…" menu item. Reachable from the menu when
    /// `atUnknownLocation` is true.
    ///
    /// Reads names from `lastUnknownDevicesNamed`, populated at
    /// signal time, so dismissing in the middle of an unplug doesn't
    /// lose the names — same fingerprint key, names captured when
    /// devices were still attached.
    func ignoreCurrentUnknownLocation() {
        let devices = lastUnknownDevices
        guard !devices.isEmpty else { return }
        let key = LocationFingerprint.canonical(for: devices)
        logger.debug("ignoreCurrentUnknownLocation: key=\(key) devices=\(devices.count)")

        let namesByDevice = Dictionary(uniqueKeysWithValues: lastUnknownDevicesNamed.map { ($0.device, $0) })
        let entries: [IgnoredLocation.Device] = devices.map { device in
            let lookup = namesByDevice[device]
            return IgnoredLocation.Device(
                vendorID: device.vendorID,
                productID: device.productID,
                serialNumber: device.serialNumber,
                name: lookup?.name,
                vendorName: lookup?.vendorName
            )
        }

        settings.ignoreLocation(IgnoredLocation(
            key: key,
            devices: entries,
            dismissedAt: Date()
        ))

        // Hide the affordance immediately without waiting for the
        // next engine evaluation.
        clearUnknownLocationState()
    }

    /// Reset every field that participates in the unknown-location
    /// UI. Called from each exit edge (profile match resolves, all
    /// devices unplugged, user dismisses, fingerprint is ignored)
    /// so the four exit sites stay in lockstep — forgetting one
    /// field at one site is how wedge states sneak in.
    private func clearUnknownLocationState() {
        atUnknownLocation = false
        lastUnknownDevices = []
        lastUnknownDevicesNamed = []
        notifiedUnknownLocation = false
    }

    /// Remove a previously-dismissed fingerprint from the ignored
    /// list. Wired to the "Un-ignore" button on each row of the
    /// Settings → Profiles "Ignored locations" section. Subsequent
    /// plug-ins of the matching device set will re-prompt as usual.
    func unignoreLocation(key: String) {
        logger.debug("unignoreLocation: key=\(key)")
        settings.unignoreLocation(key: key)
        // Force a fresh engine evaluation so a currently-attached
        // device set that just got un-ignored re-triggers the
        // unknown-location prompt without the user having to
        // unplug/replug. `engine?.evaluate()` runs synchronously and
        // bypasses the debounce window.
        engine?.evaluate()
    }

    // MARK: - Bootstrap

    private func buildEngine(profiles: [Profile], logger: ApplierLogger) -> Engine {
        let watcher = IOKitUSBWatcher(logger: ConsoleLogger(category: "usb-watcher"))
        let resolver = ProfileResolver(profiles: profiles)
        let audio = CoreAudioController()
        let camera = AVFoundationCameraController()
        // The activator is itself a `VirtualCameraSourceController` —
        // it forwards `setSource` to the running capture session
        // when enabled, and silently no-ops when disabled. Always
        // injected so toggle flips at runtime are picked up
        // without rebuilding the engine.
        let applier = ProfileApplier(
            audio: audio,
            camera: camera,
            virtualCameraSource: virtualCameraActivator,
            logger: logger
        )
        return Engine(
            watcher: watcher,
            resolver: resolver,
            applier: applier,
            logger: logger,
            debounceInterval: settings.debounceInterval,
            clock: DispatchClock()
        )
    }

    /// User flipped the Settings toggle. The activator handles
    /// idempotency for repeats; this method is a thin dispatcher.
    /// Engine rebuild is unnecessary because the activator is the
    /// `VirtualCameraSourceController` plumbed into `ProfileApplier`
    /// — its forwarding behavior changes with state, no engine
    /// reconfiguration needed.
    private func applyVirtualCameraToggle(enabled: Bool) {
        if enabled {
            virtualCameraActivator.enable(envOverride: false)
            // The post-activation visibility check (deferred ~1.5s
            // after `state → .on`) fires `onVisibilityConfirmed`,
            // which calls `engine.reapply()` once AVFoundation's
            // cache has refreshed. Nothing to do here.
        } else {
            virtualCameraActivator.disable()
            // Disable is synchronous — state goes to `.off`
            // immediately. Re-apply the active profile so its
            // camera setting flows back to the real device, not
            // the virtual one we just torn down. (`disable` itself
            // already cleared a stale `userPreferredCamera`; this
            // gives the profile applier a chance to set it
            // explicitly to the profile's real camera.)
            engine?.reapply()
        }
    }

}
