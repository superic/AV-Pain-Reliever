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

    @Published private(set) var state: State = .off {
        didSet {
            // Skip logging the no-change case. Many call sites
            // re-assign the same value to trigger downstream sinks.
            guard oldValue != state else { return }
            logger.debug("state: \(String(describing: oldValue), privacy: .public) → \(String(describing: self.state), privacy: .public)")
        }
    }

    /// Fires on the main thread when `scheduleHostVisibilityCheck`
    /// confirms `AVCaptureDevice.DiscoverySession` sees the virtual
    /// camera. Set once during host setup; the rationale lives at
    /// the consumer's wiring site.
    var onVisibilityConfirmed: (() -> Void)?

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
    /// state.
    func relaunch() {
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
            return
        }
        DispatchQueue.main.async {
            NSApplication.shared.terminate(nil)
        }
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
        session.start()
        sinkWriter = writer
        captureSession = session
        logger.notice("Started host-side capture + CMIO sink writer (initialSource=\(self.pendingSourceName ?? "<system-default>", privacy: .public))")
    }

    private func stopCapturePipeline() {
        captureSession?.stop()
        captureSession = nil
        sinkWriter = nil
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
    /// affordance the disable→enable path uses.
    private func scheduleHostVisibilityCheck() {
        // First check at 1.5s (the calibrated minimum for fresh-launch
        // where CMIO has published and AVFoundation's DiscoverySession
        // cache has refreshed). On failure, poll every 1s up to 8s
        // total. The auto-relaunch path (host restarted after a
        // toggle-off-then-on cycle) often needs 3-5s for the OS to
        // fully republish the extension; a one-shot 1.5s check
        // escalates to `.requiresRelaunch` every time and forces a
        // second relaunch.
        let deadline = Date().addingTimeInterval(8.0)
        pollHostVisibility(deadline: deadline, nextAttemptIn: 1.5)
    }

    private func pollHostVisibility(deadline: Date, nextAttemptIn delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.state == .on else { return }
            if Self.hostCanSeeVirtualCamera() {
                logger.notice("Visibility check: host sees the virtual camera in DiscoverySession")
                self.onVisibilityConfirmed?()
                return
            }
            if Date() >= deadline {
                logger.error("Visibility check: host process can't see its own Camera Extension within budget; escalating to .requiresRelaunch")
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
                return
            }
            logger.debug("Visibility check: not yet visible, retrying in 1s")
            self.pollHostVisibility(deadline: deadline, nextAttemptIn: 1.0)
        }
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
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .external,
                .continuityCamera,
                .deskViewCamera,
            ],
            mediaType: .video,
            position: .unspecified
        )
        return session.devices.contains { $0.uniqueID == Self.virtualCameraUID }
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
            logger.error("Properties query failed: \(error.localizedDescription, privacy: .public) — keeping .requiresRelaunch")
            DispatchQueue.main.async { [weak self] in
                self?.pendingPropertiesRequest = nil
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
