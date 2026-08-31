import Foundation
import AppKit
import AVFoundation
import SystemExtensions
import AVPainReliever
import AVPainRelieverSharedConstants
import os.log

private let logger = Logger(
    subsystem: "com.ericwillis.avpainreliever",
    category: "Activator"
)

/// Owns the lifecycle of the embedded Camera Extension AND the
/// host-side capture pipeline that feeds it. Driven by the
/// `SettingsStore.virtualCameraEnabled` toggle, with
/// `AVPR_ACTIVATE_VIRTUAL_CAMERA=1` as a debug-only override that
/// forces enable on launch regardless of the persisted setting.
///
/// State machine:
///
/// ```
/// .off ──enable()──▶ .activating ──didFinishWithResult──▶ .on
///   ▲                       │                              │
///   │                       └─didFailWithError──▶ .failed   │
///   │                                                       │
///   └────────────────disable()──────────────────────────────┘
/// ```
///
/// `.activating` covers both submitted-and-waiting and
/// needs-user-approval — they're indistinguishable from the host's
/// perspective until macOS fires didFinishWithResult.
///
/// SwiftUI surfaces the state via the `@Published state` property;
/// the Settings view shows a status row that mirrors it.
final class VirtualCameraActivator: NSObject, ObservableObject,
    OSSystemExtensionRequestDelegate, VirtualCameraSourceController
{
    enum State: Equatable {
        case off
        case activating
        case needsApproval
        case on
        case failed(String)
        /// Special "the user toggled off then back on in the same
        /// process" state. macOS marks the extension
        /// `[terminated waiting to uninstall on reboot]` after
        /// deactivation; re-enabling without a host-process restart
        /// hands the host a stale CMIO device registration that
        /// can't be queried successfully. Detected by tracking the
        /// in-session deactivation; resolved by relaunching the
        /// app from a fresh process.
        ///
        /// Also the terminus of a visibility-check timeout, where the
        /// same fresh-process cure applies for a different reason (a
        /// stale CMIO context after an in-place extension replace).
        /// That path relaunches itself once — see
        /// `relaunchForStaleDiscovery` — and only sits here waiting on
        /// the user if the automatic attempt already failed.
        case requiresRelaunch
        /// A stale copy of the extension (usually the pre-upgrade
        /// version after an in-place app update) is queued for
        /// uninstall-on-reboot, and CMIO won't publish the new one
        /// until the queue flushes. A bare app relaunch can't fix
        /// this (activation succeeds, the visibility check fails,
        /// repeat), so the relaunch button isn't offered. A toggle
        /// off/on cycle can, though: the fresh deactivate + activate
        /// re-registers the new copy, and recovery completes through
        /// the normal `.requiresRelaunch` app restart (verified in
        /// the field 2026-08-28). Settings copy leads with the
        /// toggle cycle and keeps the Mac restart as the fallback.
        /// Detected by a properties request finding an
        /// `isUninstalling` copy after a visibility-check failure
        /// (see issue #110).
        case requiresReboot
    }

    static let extensionBundleID = "com.ericwillis.avpainreliever.CameraExtension"
    static let envVar = "AVPR_ACTIVATE_VIRTUAL_CAMERA"

    /// Re-exports of `VirtualCameraIdentity` so existing call sites
    /// (`AddProfileViewModel`, internal references below) keep their
    /// `VirtualCameraActivator.virtualCameraUID` /
    /// `VirtualCameraActivator.virtualCameraDisplayName` spellings.
    /// The single source of truth lives in the engine library
    /// alongside the host-side capture adapters that need to compare
    /// against it without depending on the app target.
    static let virtualCameraUID = VirtualCameraIdentity.deviceUID
    static let virtualCameraDisplayName = VirtualCameraIdentity.displayName

    /// Re-exports of the shared notification names so the rest of
    /// this file can keep its `Self.consumerActiveNotification`
    /// spellings while the canonical strings live in
    /// `AVPainRelieverSharedConstants` (a tiny target both this
    /// host code and the Camera Extension link statically — no
    /// more hand-mirroring across the two binaries).
    private static let consumerActiveNotification =
        CameraExtensionNotifications.consumerActive
    private static let consumerInactiveNotification =
        CameraExtensionNotifications.consumerInactive
    private static let queryConsumerStateNotification =
        CameraExtensionNotifications.queryConsumerState

    /// Time we keep the host capture pipeline warm after the last
    /// AVCapture client disconnects. Bridges back-to-back Zoom calls
    /// without re-paying the ~300-500 ms AVCaptureSession warmup, and
    /// avoids the green light flickering off-then-on between every
    /// hangup and the next ring.
    private static let stopGraceSeconds: TimeInterval = 30

    /// Total wall-clock budget for the post-activation visibility
    /// poll. Was 8s until macOS was observed taking 11s to spawn a
    /// replaced extension process after an in-place update (issue
    /// #114) — the poll expired first and produced a false "restart
    /// your Mac". 30s covers the slow spawn with room to spare; the
    /// poll exits early the moment the device shows up, so a generous
    /// budget only costs anything in the genuinely-broken case.
    private static let visibilityPollBudgetSeconds: TimeInterval = 30

    /// Cadence and budget for the slow re-check that keeps running
    /// after a visibility timeout escalated to `.requiresRelaunch` /
    /// `.requiresReboot`. Catches a spawn so late it outran even the
    /// 30s poll and heals the state in place instead of making the
    /// user act on advice that's no longer true.
    private static let visibilityRecheckIntervalSeconds: TimeInterval = 5

    /// Re-check budget, counted in *ticks actually fired* rather than
    /// wall-clock seconds. A `DispatchSourceTimer` scheduled off
    /// `.now()` runs on the monotonic clock and doesn't fire while the
    /// Mac is asleep, but `Date()` keeps advancing — so a wall-clock
    /// deadline turned a lid-close inside the window into an instant
    /// "budget expired" at wake, which is the worst moment to spend
    /// the one-shot relaunch (cameras take seconds to re-enumerate
    /// after wake). Ticks measure elapsed *active* time, and
    /// `NSWorkspace.didWakeNotification` resets the count so a wake
    /// always gets a full fresh window.
    private static let visibilityRecheckIntervalTickBudget = 24
    private static var visibilityRecheckBudgetSeconds: TimeInterval {
        Double(visibilityRecheckIntervalTickBudget) * visibilityRecheckIntervalSeconds
    }

    /// Upper bound on how long the automatic stale-discovery relaunch
    /// waits for its user-visible notice to reach the system before
    /// quitting anyway. Normally the host's notifier reports back in
    /// milliseconds and the relaunch happens then; this only covers a
    /// notifier that never calls back at all.
    private static let relaunchNoticeCapSeconds: TimeInterval = 1.5

    @Published private(set) var state: State = .off {
        didSet {
            // Skip logging the no-change case. Many call sites
            // re-assign the same value to trigger downstream sinks.
            guard oldValue != state else { return }
            logger.debug("state: \(String(describing: oldValue), privacy: .public) → \(String(describing: self.state), privacy: .public)")
        }
    }

    /// Camera the capture pipeline actually has open as the virtual
    /// camera's source right now, or nil when nothing is on air (no
    /// consumer, install failed, source unplugged). Pushed from
    /// `CameraCaptureSession.onSourceChange` — deliberately *not*
    /// derived from the profile's requested camera, which would let
    /// the Settings status row claim a relay from a camera that never
    /// opened while the extension replays its cached frame.
    @Published private(set) var routedSourceName: String?

    /// Fires on the main thread when `scheduleHostVisibilityCheck`
    /// confirms `AVCaptureDevice.DiscoverySession` sees the virtual
    /// camera. Set once during host setup; the rationale lives at
    /// the consumer's wiring site.
    var onVisibilityConfirmed: (() -> Void)?

    /// Fires on the main thread when the automatic stale-discovery
    /// relaunch (issue #120) needs the user told before it quits — an
    /// agent that vanishes and reappears on its own otherwise reads as
    /// a crash. The host posts its notice and calls the supplied
    /// continuation once the system has the request (or immediately
    /// when it can't post at all); the relaunch happens from there,
    /// capped by `relaunchNoticeCapSeconds`. Set once during host
    /// setup.
    var onStaleDiscoveryRelaunch: ((@escaping () -> Void) -> Void)?

    /// Fires on the main thread when the user cancels the macOS auth
    /// prompt that gates a deactivate request. The OS-level deactivate
    /// never happened so the extension is still alive — the activator
    /// has already restored its own state to `.on`. The host wires this
    /// to roll the persisted Settings toggle back to `true` and re-apply
    /// the active profile so the system-wide preferred camera flips
    /// back to the virtual camera. Set once during host setup.
    var onDeactivateAuthCancelled: (() -> Void)?

    /// True when the env var override forced enable on launch.
    /// Settings UI hides the toggle's persistence-driven semantics
    /// and shows a "debug override active" badge instead so the
    /// user understands why disabling doesn't seem to stick.
    private(set) var isEnvOverride: Bool = false

    private var sinkWriter: CMIOSinkWriter?
    private var captureSession: CameraCaptureSession?

    /// Most recent source-camera name a profile asked us to route.
    /// Held across the "no consumer yet" window so that when lazy
    /// capture finally spins up (consumer connects after a profile
    /// applied), the new `CameraCaptureSession` opens the camera
    /// the profile actually wants — not the system-preferred one,
    /// which post-override is the virtual camera itself and would
    /// close a self-source feedback loop.
    private var pendingSourceName: String?

    /// True after a successful `disable()` until the host process
    /// is relaunched. Re-enabling within the same process hits the
    /// macOS "queued for uninstall on reboot" CMIO quirk where the
    /// host can't find the device even though System Settings shows
    /// it as active. Tracked here so `enable()` can surface the
    /// `.requiresRelaunch` state instead of silently producing a
    /// black feed.
    private var deactivatedThisSession = false

    /// True iff at least one AVCapture client (Zoom, FaceTime, …) is
    /// currently reading the virtual camera's source stream.
    /// Maintained from Darwin notifications posted by the extension.
    private var consumerActive: Bool = false

    /// Set when `endConsumerWatch` would otherwise be called twice
    /// (Sparkle replace re-fires `.completed` while state is already
    /// `.on`). Idempotency flag.
    private var consumerWatchActive: Bool = false

    /// Pending pipeline teardown from the last `consumerInactive`
    /// notification. Cancelled when a new consumer connects within
    /// the grace window so we don't tear down then immediately rebuild.
    private var stopGraceTimer: DispatchSourceTimer?

    /// Slow re-check armed after a *visibility timeout* escalated to
    /// `.requiresRelaunch` / `.requiresReboot`. Only that escalation
    /// arms it: the `deactivatedThisSession` path genuinely needs a
    /// fresh process no matter what CMIO later publishes, so it must
    /// not self-heal. Cancelled on disable(), on a fresh activation,
    /// and by the timer itself once the state moves on.
    private var visibilityRecheckTimer: DispatchSourceTimer?

    /// Re-check ticks fired since the window was armed (or since the
    /// last wake). See `visibilityRecheckIntervalTickBudget`.
    private var visibilityRecheckTicks = 0

    /// Wake observer live only while the re-check window is armed.
    /// Resets the tick count so a sleep/wake inside the window can't
    /// hand us an escalation the moment the Mac comes back.
    private var wakeObserver: NSObjectProtocol?

    /// Cross-process latch that keeps the automatic stale-discovery
    /// relaunch to one attempt per broken episode. See
    /// `VirtualCameraRelaunchGuard`.
    private let relaunchGuard = VirtualCameraRelaunchGuard()

    /// Pending automatic relaunch, held so it can be cancelled. Both
    /// `disable()` (user turned the camera off inside the window) and
    /// `relaunch()` (the Settings button got there first) tear it down
    /// — `open -n` unconditionally spawns a fresh instance, so a stray
    /// second call means two live copies of the app.
    private var pendingRelaunchWorkItem: DispatchWorkItem?

    /// True once `open -n` has actually spawned a replacement. Guards
    /// the same double-launch, for callers that reach `relaunch()`
    /// directly rather than through the pending work item.
    private var relaunchInFlight = false

    /// Whether the relaunch-vs-reboot properties query has answered
    /// for the current escalation. Only `.clean` — query returned and
    /// found no copy queued for uninstall-on-reboot — licenses the
    /// automatic relaunch: on a reboot-required machine a bare
    /// relaunch provably loops (#110/#112), and an unanswered query
    /// can't tell us which machine we're on.
    /// Internal rather than private so `autoRelaunchDecision` can take
    /// it as a parameter and be tested directly.
    enum RebootRefinement {
        case pending
        case clean
        case unavailable
    }
    private var rebootRefinement: RebootRefinement = .pending

    /// Returns true if launch should auto-enable: env-var debug
    /// override OR the user's persisted toggle is on. The env var
    /// is checked first so a developer can force-enable without
    /// touching the persisted setting.
    static func shouldAutoEnable(persistedToggle: Bool) -> Bool {
        if ProcessInfo.processInfo.environment[envVar] == "1" { return true }
        return persistedToggle
    }

    /// Begin activation. Idempotent: subsequent calls while in any
    /// non-`.off`/`.failed` state are silent no-ops.
    func enable(envOverride: Bool = false) {
        switch state {
        case .activating, .needsApproval, .on:
            logger.notice("enable() called while already \(String(describing: self.state), privacy: .public) — no-op")
            return
        case .requiresRelaunch, .requiresReboot:
            logger.notice("enable() called while \(String(describing: self.state), privacy: .public) — keeping that state until the host/Mac restarts")
            return
        case .off, .failed:
            break
        }
        if deactivatedThisSession {
            logger.notice("enable() blocked: in-session deactivation requires a host relaunch")
            state = .requiresRelaunch
            return
        }
        isEnvOverride = envOverride
        state = .activating
        logger.notice("Submitting Camera Extension activation request (envOverride=\(envOverride, privacy: .public))")

        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.extensionBundleID,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)

        // Capture pipeline is no longer started eagerly here. It
        // spins up only when `beginConsumerWatch` (called after the
        // extension reaches `.on`) sees a `consumerActive`
        // notification — i.e. when an AVCapture client actually
        // selects the virtual camera. Keeps the macOS green camera
        // light off while the app is idle.
    }

    /// Tear down the capture pipeline and submit a deactivation
    /// request. Idempotent: a call while `.off` is a no-op.
    func disable() {
        switch state {
        case .off:
            logger.notice("disable() called while already off — no-op")
            return
        default:
            break
        }
        logger.notice("Disabling: stopping capture pipeline + deactivating extension")
        endConsumerWatch()
        endVisibilityRecheck()
        // A pending automatic relaunch is now unwanted: the user has
        // said they don't want the virtual camera, and quitting the app
        // out from under that click would be indefensible.
        pendingRelaunchWorkItem?.cancel()
        pendingRelaunchWorkItem = nil
        // Turning the feature off ends the broken episode as
        // decisively as a confirmed sighting does, so give the
        // one-shot relaunch back. A user who hits this while the
        // camera is stuck would otherwise carry a spent latch into a
        // genuinely new episode weeks later.
        relaunchGuard.clearRelaunchMarker()
        stopGraceTimer?.cancel()
        stopGraceTimer = nil
        consumerActive = false
        pendingSourceName = nil
        stopCapturePipeline()
        Self.restoreUserPreferredCameraIfVirtual()

        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: Self.extensionBundleID,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)

        state = .off
        isEnvOverride = false
        deactivatedThisSession = true
    }

    /// Quit + relaunch the host. The fresh process auto-enables
    /// from the persisted toggle and gets a clean CMIO context that
    /// finds the activated extension immediately. Wired to the
    /// "Restart" button on the Settings UI's `.requiresRelaunch`
    /// state, and to the automatic stale-discovery escalation in
    /// `relaunchForStaleDiscovery`.
    ///
    /// Returns true once a replacement instance has been handed to
    /// Launch Services and termination is queued. False means nothing
    /// happened and this process is still the only one — the automatic
    /// escalation reads that to keep its manual advice standing.
    @discardableResult
    func relaunch() -> Bool {
        // Two callers can arrive within milliseconds of each other
        // (the Settings button and the automatic escalation's timer),
        // and `open -n` would happily give us two live apps.
        guard !relaunchInFlight else {
            logger.notice("relaunch() ignored: a replacement instance is already launching")
            return false
        }
        pendingRelaunchWorkItem?.cancel()
        pendingRelaunchWorkItem = nil
        let bundleURL = Bundle.main.bundleURL
        logger.notice("Relaunching host: \(bundleURL.path, privacy: .public)")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // -n forces a brand-new instance. Without it, Launch Services
        // races our pending `terminate` and sometimes resolves the
        // bundle to the still-alive PID, activating the about-to-die
        // process instead of launching a fresh one. Net effect: the
        // app quits and nothing comes back up.
        task.arguments = ["-n", bundleURL.path]
        do {
            try task.run()
        } catch {
            logger.error("relaunch open failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        relaunchInFlight = true
        DispatchQueue.main.async {
            NSApplication.shared.terminate(nil)
        }
        return true
    }

    private func startCapturePipeline() {
        guard captureSession == nil else { return }
        // Per-adapter ConsoleLogger instances so `os.log`'s category
        // filter (`log stream --predicate 'category == "CMIOSinkWriter"'`)
        // still works even though both adapters now go through the
        // engine library's `ApplierLogger` protocol seam.
        let writer = CMIOSinkWriter(
            deviceUID: Self.virtualCameraUID,
            logger: ConsoleLogger(category: "CMIOSinkWriter")
        )
        let session = CameraCaptureSession(
            sink: writer,
            logger: ConsoleLogger(category: "CameraCaptureSession"),
            initialSourceName: pendingSourceName
        )
        // Fires on the capture queue; mirror onto main because
        // `routedSourceName` is @Published and SwiftUI reads it.
        session.onSourceChange = { [weak self] name in
            DispatchQueue.main.async {
                self?.routedSourceName = name
            }
        }
        session.start()
        sinkWriter = writer
        captureSession = session
        logger.notice("Started host-side capture + CMIO sink writer (initialSource=\(self.pendingSourceName ?? "<system-default>", privacy: .public))")
    }

    private func stopCapturePipeline() {
        captureSession?.stop()
        captureSession = nil
        sinkWriter = nil
        // Pipeline gone means no camera on air, whatever the last
        // install reported. Every caller of this method is already on
        // the main thread (disable, the consumer-inactive grace timer,
        // the visibility-poll escalation), so this is a direct write.
        routedSourceName = nil
        logger.notice("Stopped host-side capture pipeline")
    }

    // MARK: - VirtualCameraSourceController

    var preferredCameraOverride: String? {
        // Only direct AVFoundation-modern apps at the virtual camera
        // when it's actually live and we've confirmed the host can
        // see it. During `.activating` / `.needsApproval` we don't
        // know whether the device is reachable yet; during
        // `.requiresRelaunch` it's known broken; `.failed` /
        // `.off` — same. In every non-`.on` case, fall back to the
        // profile's literal camera so AVFoundation-modern apps
        // don't hop to a virtual camera that can't deliver frames.
        state == .on ? Self.virtualCameraDisplayName : nil
    }

    func setSource(named: String) -> CameraApplyResult {
        logger.debug("setSource(named: \(named, privacy: .public)) state=\(String(describing: self.state), privacy: .public) captureSession=\(self.captureSession == nil ? "nil" : "live", privacy: .public)")
        // Always remember — even when the capture pipeline isn't
        // running yet — so a consumer that connects later opens the
        // right camera as its initial source instead of falling
        // through to userPreferredCamera (which is the virtual
        // camera itself under the override semantics).
        pendingSourceName = named
        guard let captureSession else {
            // Toggle off OR mid-activation with capture not yet
            // running. Treat as silent no-op (.ok) so the engine's
            // per-profile log line doesn't claim a failure for what
            // is just "user has the virtual camera disabled."
            return .ok
        }
        return captureSession.setSource(named: named)
    }

    // MARK: - Host-process visibility check

    /// After activation flips to `.on`, AVFoundation in the host
    /// process sometimes doesn't see the newly-published CMIO
    /// device — the discovery cache was warmed before the extension
    /// registered, and stays stale until a fresh process reads CMIO
    /// for the first time. Other apps (Photo Booth, FaceTime) see
    /// the device fine; only this host is blind to it. Detected by
    /// running `AVCaptureDevice.DiscoverySession` and looking for
    /// our extension's UID. If absent, escalate to
    /// `.requiresRelaunch` so Settings can offer the same Restart
    /// affordance the disable→enable path uses — and hand off to
    /// `beginVisibilityRecheck`, because a spawn slow enough to blow
    /// the poll budget can still land afterwards.
    private func scheduleHostVisibilityCheck() {
        // A Sparkle-driven replace can re-fire `.completed` and land
        // here while a previous escalation's re-check is still ticking.
        // The fresh poll supersedes it.
        endVisibilityRecheck()
        // First check at 1.5s (the calibrated minimum for fresh-launch
        // where CMIO has published and AVFoundation's DiscoverySession
        // cache has refreshed). On failure, poll every 1s up to the
        // full budget. The auto-relaunch path (host restarted after a
        // toggle-off-then-on cycle) often needs 3-5s for the OS to
        // fully republish the extension; a one-shot 1.5s check
        // escalates to `.requiresRelaunch` every time and forces a
        // second relaunch.
        let deadline = Date().addingTimeInterval(Self.visibilityPollBudgetSeconds)
        pollHostVisibility(deadline: deadline, nextAttemptIn: 1.5)
    }

    private func pollHostVisibility(deadline: Date, nextAttemptIn delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.state == .on else { return }
            if Self.hostCanSeeVirtualCamera() {
                logger.notice("Visibility check: host sees the virtual camera in DiscoverySession")
                self.noteVisibilityConfirmed()
                return
            }
            if Date() >= deadline {
                logger.error("Visibility check: host process can't see its own Camera Extension within budget; escalating to .requiresRelaunch")
                Self.logCMIOCrossCheck(phase: "poll")
                self.endConsumerWatch()
                self.stopGraceTimer?.cancel()
                self.stopGraceTimer = nil
                self.consumerActive = false
                self.pendingSourceName = nil
                self.stopCapturePipeline()
                self.state = .requiresRelaunch
                // Relaunch might not be enough: if a stale extension
                // copy is queued for uninstall-on-reboot, only a Mac
                // restart helps. Ask the OS and upgrade the state to
                // `.requiresReboot` if so — starting from
                // `.requiresRelaunch` keeps today's behavior as the
                // fallback when the query fails or comes back clean.
                self.refineRelaunchEscalation()
                // Either escalation can turn out to be wrong: macOS
                // sometimes publishes the device long after the poll
                // gave up. Keep watching so a late spawn heals itself.
                self.beginVisibilityRecheck()
                return
            }
            logger.debug("Visibility check: not yet visible, retrying in 1s")
            self.pollHostVisibility(deadline: deadline, nextAttemptIn: 1.0)
        }
    }

    /// Keep looking for the camera after a visibility timeout sent us
    /// to `.requiresRelaunch` / `.requiresReboot`. If the extension
    /// finally shows up, walk the same success path a timely poll
    /// would have taken — back to `.on`, consumer watch re-armed (the
    /// escalation tore it down), profile re-applied via
    /// `onVisibilityConfirmed` — so the stale restart advice
    /// disappears on its own. If the budget expires instead, the host
    /// process itself is the problem — hand off to
    /// `relaunchForStaleDiscovery`.
    private func beginVisibilityRecheck() {
        visibilityRecheckTicks = 0
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            logger.notice("Visibility re-check: woke from sleep, restarting the budget (cameras re-enumerate late after wake)")
            self.visibilityRecheckTicks = 0
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + Self.visibilityRecheckIntervalSeconds,
            repeating: Self.visibilityRecheckIntervalSeconds
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // Anything that moved the state elsewhere (disable(), a
            // re-activation) owns it now — stand down.
            guard self.state == .requiresRelaunch || self.state == .requiresReboot else {
                self.endVisibilityRecheck()
                return
            }
            self.visibilityRecheckTicks += 1
            if Self.hostCanSeeVirtualCamera() {
                logger.notice("Visibility re-check: host can see the virtual camera now — recovering to .on, no restart needed")
                self.endVisibilityRecheck()
                self.state = .on
                self.beginConsumerWatch()
                self.noteVisibilityConfirmed()
                return
            }
            if self.visibilityRecheckTicks >= Self.visibilityRecheckIntervalTickBudget {
                // State-neutral line: the diagnosis differs per state
                // and `relaunchForStaleDiscovery` logs the one that
                // actually applies.
                logger.notice("Visibility re-check: budget spent (\(self.visibilityRecheckTicks, privacy: .public) checks over \(Int(Self.visibilityRecheckBudgetSeconds), privacy: .public)s awake) and the camera is still invisible to this process")
                self.endVisibilityRecheck()
                // Delete this one line to downgrade the escalation to
                // offer-only: the state already routes Settings to its
                // "Restart AV Pain Reliever" button, so the user keeps
                // the manual path and nothing else changes.
                self.relaunchForStaleDiscovery()
            }
        }
        visibilityRecheckTimer?.cancel()
        visibilityRecheckTimer = timer
        timer.resume()
        logger.notice("Visibility re-check armed: every \(Int(Self.visibilityRecheckIntervalSeconds), privacy: .public)s for up to \(Int(Self.visibilityRecheckBudgetSeconds), privacy: .public)s")
    }

    private func endVisibilityRecheck() {
        visibilityRecheckTimer?.cancel()
        visibilityRecheckTimer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    /// Visibility is proven in this process. Spend-once latch for the
    /// automatic relaunch resets here so a future stale-context
    /// episode gets its own attempt.
    private func noteVisibilityConfirmed() {
        relaunchGuard.clearRelaunchMarker()
        onVisibilityConfirmed?()
    }

    /// The re-check budget expired with the camera still invisible to
    /// this process. Issue #120: AVFoundation's device list is
    /// effectively frozen per-process in this state — the host polled
    /// for 30s and re-checked for 2 minutes while a freshly-launched
    /// Zoom opened the very same device — so more querying can't help.
    /// Only a fresh process gets a fresh CMIO context, which is
    /// exactly what Settings tells the user to do by hand. Do it for
    /// them, once, with a notice.
    ///
    /// Not offered in `.requiresReboot`, nor when the reboot question
    /// went unanswered: on a machine with a stale copy queued for
    /// uninstall-on-reboot a bare relaunch provably loops (#110/#112),
    /// so anything short of a clean properties query keeps the manual
    /// advice.
    private func relaunchForStaleDiscovery() {
        // Log the device-list pair before any decision, so the
        // relaunched-but-still-broken process — the exact one this
        // diagnostic exists for — records it too.
        Self.logCMIOCrossCheck(phase: "re-check")
        switch Self.autoRelaunchDecision(
            state: state,
            rebootRefinement: rebootRefinement,
            latchAvailable: relaunchGuard.canRelaunch
        ) {
        case .declineWrongState:
            logger.notice("Stale-discovery relaunch declined: state is \(String(describing: self.state), privacy: .public) — its own recovery advice stands")
            return
        case .declineRebootUnresolved:
            logger.error("Stale-discovery relaunch declined: the relaunch-vs-reboot query never answered, so a relaunch could be the futile kind (#110) — leaving the manual recovery advice in place")
            return
        case .declineLatchSpent:
            logger.error("Stale-discovery relaunch declined: this process already came back from one and still can't see the camera — leaving the manual recovery advice in place")
            return
        case .relaunch:
            break
        }
        // Marker goes down before the notice, not after: it needs the
        // notice window to reach cfprefsd before the process dies. The
        // paths below that don't end in a relaunch hand it back.
        relaunchGuard.markRelaunched()
        logger.notice("Stale-discovery relaunch: in-process discovery is frozen, quitting for a fresh CMIO context")

        let capped = DispatchWorkItem { [weak self] in
            logger.notice("Stale-discovery relaunch: notice never reported back within \(Self.relaunchNoticeCapSeconds, privacy: .public)s, quitting anyway")
            self?.performStaleDiscoveryRelaunch()
        }
        pendingRelaunchWorkItem = capped
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.relaunchNoticeCapSeconds,
            execute: capped
        )
        onStaleDiscoveryRelaunch? { [weak self] in
            self?.performStaleDiscoveryRelaunch()
        }
    }

    /// Quit for a fresh process, now that the user has been told (or
    /// telling them has provably failed). Idempotent: the notice
    /// continuation and the cap can both arrive, and `relaunch()`
    /// refuses a second `open -n` besides.
    private func performStaleDiscoveryRelaunch() {
        // The continuation is the host notifier's to call — an
        // external boundary that could call it twice — and the cap may
        // have fired first. Once a replacement is launching there's
        // nothing left to decide.
        guard !relaunchInFlight else { return }
        pendingRelaunchWorkItem?.cancel()
        pendingRelaunchWorkItem = nil
        // The wait is short but not zero, and the user can act inside
        // it — a Settings Restart click, a toggle-off, a late heal back
        // to `.on`. Anything that moved us off `.requiresRelaunch`
        // owns the outcome now.
        guard state == .requiresRelaunch else {
            logger.notice("Stale-discovery relaunch abandoned: state moved to \(String(describing: self.state), privacy: .public) while the notice was in flight")
            relaunchGuard.clearRelaunchMarker()
            return
        }
        if !relaunch() {
            // Launch Services refused, so nothing is going to quit and
            // the re-check has already stood down. Give the latch back
            // — this episode got no retry at all — and leave the
            // Settings advice as the way out.
            logger.error("Stale-discovery relaunch failed to spawn a replacement — manual recovery advice stands")
            relaunchGuard.clearRelaunchMarker()
        }
    }

    /// Whether an automatic relaunch is warranted. Pure and static so
    /// the decline matrix is unit-testable without AVFoundation, CMIO,
    /// or a real host process in the loop.
    static func autoRelaunchDecision(
        state: State,
        rebootRefinement: RebootRefinement,
        latchAvailable: Bool
    ) -> AutoRelaunchDecision {
        guard state == .requiresRelaunch else { return .declineWrongState }
        guard rebootRefinement == .clean else { return .declineRebootUnresolved }
        guard latchAvailable else { return .declineLatchSpent }
        return .relaunch
    }

    enum AutoRelaunchDecision: Equatable {
        case relaunch
        case declineWrongState
        case declineRebootUnresolved
        case declineLatchSpent
    }

    /// Log-only cross-check of the two device lists at an escalation
    /// point. `CMIOObjectGetPropertyData(kCMIOHardwarePropertyDevices)`
    /// re-reads the system list on every call; DiscoverySession answers
    /// from a per-process cache. "CMIO yes, AVFoundation no" is the
    /// stale-context signature from #120, and both halves are measured
    /// (not assumed) so a support log can tell that apart from an
    /// extension that genuinely never published. Deliberately does NOT
    /// gate the relaunch decision — CMIO's behavior in the stale state
    /// hasn't been verified on hardware, and the relaunch is the right
    /// move either way.
    private static func logCMIOCrossCheck(phase: String) {
        let cmioSees = CMIODeviceCatalog.deviceID(forUID: virtualCameraUID) != nil
        let avSees = hostCanSeeVirtualCamera()
        logger.notice("CMIO cross-check (\(phase, privacy: .public)): CMIO=\(cmioSees, privacy: .public) AVFoundation=\(avSees, privacy: .public)")
    }

    /// On disable, if the system-wide preferred camera still points
    /// at our virtual camera (because a recent profile-apply set it
    /// while the toggle was on), redirect AVFoundation-modern apps
    /// to whatever macOS would naturally pick instead. Otherwise
    /// FaceTime / Safari getUserMedia stay stuck on a virtual
    /// camera that's no longer producing frames. AppDelegate
    /// follows up with `engine.reapply()` so the active profile's
    /// real camera is the new explicit preference where applicable.
    private static func restoreUserPreferredCameraIfVirtual() {
        guard
            let user = AVCaptureDevice.userPreferredCamera,
            user.uniqueID == Self.virtualCameraUID
        else { return }
        AVCaptureDevice.userPreferredCamera = AVCaptureDevice.systemPreferredCamera
        logger.notice(
            "Cleared userPreferredCamera that was pointing at the virtual camera; system fallback now \(AVCaptureDevice.systemPreferredCamera?.localizedName ?? "(none)", privacy: .public)"
        )
    }

    private static func hostCanSeeVirtualCamera() -> Bool {
        CameraDiscovery.virtualCameraDevice() != nil
    }

    // MARK: - Consumer-driven capture lifecycle

    /// Subscribe to the extension's "consumer connected/disconnected"
    /// Darwin notifications and seed the initial state. The capture
    /// pipeline is started/stopped purely from these signals — the
    /// activator no longer eagerly opens an `AVCaptureSession` on
    /// `enable()`. Idempotent.
    private func beginConsumerWatch() {
        guard !consumerWatchActive else {
            logger.notice("beginConsumerWatch: already active — no-op")
            return
        }
        let observer = Unmanaged.passUnretained(self).toOpaque()
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let callback: CFNotificationCallback = { _, observer, name, _, _ in
            guard let observer, let name else { return }
            let me = Unmanaged<VirtualCameraActivator>
                .fromOpaque(observer)
                .takeUnretainedValue()
            // CFNotificationName.rawValue is a CFString; bridge to
            // String for ergonomic switching.
            let nameStr = name.rawValue as String
            DispatchQueue.main.async {
                switch nameStr {
                case VirtualCameraActivator.consumerActiveNotification:
                    me.handleConsumerActive()
                case VirtualCameraActivator.consumerInactiveNotification:
                    me.handleConsumerInactive()
                default:
                    break
                }
            }
        }
        CFNotificationCenterAddObserver(
            center, observer, callback,
            Self.consumerActiveNotification as CFString,
            nil, .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            center, observer, callback,
            Self.consumerInactiveNotification as CFString,
            nil, .deliverImmediately
        )
        consumerWatchActive = true

        // Seed initial state. Edge case worth covering: extension was
        // activated by a prior host instance and a Zoom call is
        // already in progress when this host launches. Without the
        // ping, we'd miss the 0→1 transition and the call would see
        // no frames until it disconnects.
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(Self.queryConsumerStateNotification as CFString),
            nil, nil, true
        )
    }

    private func endConsumerWatch() {
        guard consumerWatchActive else { return }
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer
        )
        consumerWatchActive = false
    }

    private func handleConsumerActive() {
        consumerActive = true
        // A new consumer arrived inside the grace window — keep the
        // pipeline that's already running and cancel the pending stop.
        stopGraceTimer?.cancel()
        stopGraceTimer = nil
        if captureSession == nil {
            logger.notice("Consumer connected — starting host capture pipeline")
            startCapturePipeline()
        }
    }

    private func handleConsumerInactive() {
        consumerActive = false
        // Don't tear down immediately. Most users hang up one Zoom
        // call and start another within seconds; a 30-s grace bridges
        // those without re-paying the AVCaptureSession warmup, and
        // collapses the green-light flicker between calls.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.stopGraceSeconds)
        timer.setEventHandler { [weak self] in
            guard let self, !self.consumerActive else { return }
            logger.notice("Stop grace expired — tearing down host capture pipeline")
            self.stopCapturePipeline()
            self.stopGraceTimer = nil
        }
        stopGraceTimer?.cancel()
        stopGraceTimer = timer
        timer.resume()
    }

    // MARK: - Relaunch-vs-reboot refinement

    /// In-flight properties query submitted after a visibility-check
    /// failure. Held so the shared `OSSystemExtensionRequestDelegate`
    /// callbacks can tell it apart from activation / deactivation
    /// requests — without the identity guard, the query's `.completed`
    /// result would flip `.requiresRelaunch` back to `.on` and restart
    /// the failing visibility loop. Cleared in the terminal delegate
    /// callbacks (didFinish / didFail), not in `foundProperties`,
    /// because both fire for the same request in that order.
    private var pendingPropertiesRequest: OSSystemExtensionRequest?

    private func refineRelaunchEscalation() {
        rebootRefinement = .pending
        let request = OSSystemExtensionRequest.propertiesRequest(
            forExtensionWithIdentifier: Self.extensionBundleID,
            queue: .main
        )
        request.delegate = self
        pendingPropertiesRequest = request
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func request(
        _ request: OSSystemExtensionRequest,
        foundProperties properties: [OSSystemExtensionProperties]
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self, request === self.pendingPropertiesRequest else { return }
            let stale = properties.filter(\.isUninstalling)
            guard !stale.isEmpty else {
                logger.notice("Properties query: no copy queued for uninstall — an app relaunch should recover")
                // The one answer that licenses the automatic relaunch.
                self.rebootRefinement = .clean
                return
            }
            // Only upgrade the escalation the visibility check set.
            // If the user already toggled off (state .off) or some
            // other transition happened while the query was in
            // flight, don't stomp it.
            guard self.state == .requiresRelaunch else { return }
            let versions = stale.map(\.bundleShortVersion).joined(separator: ", ")
            logger.error("Properties query: stale copy queued for uninstall-on-reboot (\(versions, privacy: .public)) — escalating to .requiresReboot")
            self.state = .requiresReboot
        }
    }

    // MARK: - OSSystemExtensionRequestDelegate

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        // Always replace. Sparkle-installed upgrades will hit this
        // path for every v0.2.x → v0.2.y bump.
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        logger.notice("Camera Extension needs user approval — open System Settings → Login Items & Extensions")
        DispatchQueue.main.async { [weak self] in
            // Don't override .on — a Sparkle-driven upgrade-replace
            // flow can fire needs-user-approval AFTER the original
            // is already running, and we don't want to regress the
            // status badge in that case.
            guard let self, self.state != .on else { return }
            self.state = .needsApproval
        }
    }

    func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        logger.notice("Camera Extension request finished: result=\(result.rawValue, privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Terminal callback for the relaunch-vs-reboot properties
            // query — `foundProperties` already did the state work.
            if request === self.pendingPropertiesRequest {
                self.pendingPropertiesRequest = nil
                return
            }
            switch result {
            case .completed:
                // Activation OR deactivation completed. Distinguish
                // by current state: if we were already heading off
                // (disable() set state=.off), leave it. Otherwise
                // this is a successful activation → .on.
                if self.state != .off {
                    self.state = .on
                    self.scheduleHostVisibilityCheck()
                    self.beginConsumerWatch()
                }
            case .willCompleteAfterReboot:
                // Rare path — extension upgrade queued for next
                // reboot. Mark as failed so the user knows the new
                // version isn't live yet.
                self.state = .failed("Upgrade pending — reboot required")
            @unknown default:
                self.state = .failed("Unknown activation result")
            }
        }
    }

    func request(
        _ request: OSSystemExtensionRequest,
        didFailWithError error: Error
    ) {
        // Failed relaunch-vs-reboot properties query: keep the
        // `.requiresRelaunch` state the visibility check already set
        // — wrong-but-recoverable advice beats surfacing a query
        // error over a working escalation path.
        if request === pendingPropertiesRequest {
            logger.error("Properties query failed: \(error.localizedDescription, privacy: .public) — keeping .requiresRelaunch, and the automatic relaunch stays off the table")
            DispatchQueue.main.async { [weak self] in
                self?.pendingPropertiesRequest = nil
                // Unanswered reboot question: `.requiresRelaunch` here
                // may well be the futile-relaunch machine from #110,
                // so the escalation stops at manual advice.
                self?.rebootRefinement = .unavailable
            }
            return
        }

        // Auth-cancel during deactivate: the prompt was declined, so
        // the extension is still alive on the OS side and only the
        // host's view of state is wrong (disable() flipped to .off
        // synchronously). Roll back to .on. Activate-side cancels
        // still escalate to .failed via the path below.
        let nsError = error as NSError
        let isDeactivateAuthCancel = state == .off
            && nsError.domain == OSSystemExtensionErrorDomain
            && nsError.code == OSSystemExtensionError.Code.authorizationRequired.rawValue
        if isDeactivateAuthCancel {
            logger.notice("Camera Extension deactivate cancelled by user (auth prompt declined); rolling back toggle to on")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.deactivatedThisSession = false
                self.beginConsumerWatch()
                self.state = .on
                self.onDeactivateAuthCancelled?()
            }
            return
        }
        let message = error.localizedDescription
        logger.error("Camera Extension request failed: \(message, privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            self?.stopCapturePipeline()
            self?.state = .failed(message)
        }
    }
}
