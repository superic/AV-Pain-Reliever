import SwiftUI
import AVFoundation
import AVPainReliever
import AVPainRelieverSharedConstants
import os.log

private let logger = Logger(
    subsystem: "com.ericwillis.avpainreliever",
    category: "CameraPreview"
)

/// What the Settings → Camera live preview is currently seeing.
///
/// Derived from the preview's own `AVCaptureSession` — the same kind
/// of session any video app opens on the published CMIO device — so a
/// green status means a real consumer got real frames through the
/// real pipeline: extension published, consumer notification
/// delivered, host capture spun up, frames relayed.
///
/// Frame *arrival* alone stopped proving that last step once the
/// extension gained its no-signal placeholder: past
/// `NoSignalPolicy.holdWindowNs` of a dry sink it synthesises frames
/// and sends those down the source stream, and no consumer can tell
/// them from live video by looking. So exactly one host-internal fact
/// crosses into this derivation — `VirtualCameraActivator
/// .hostDeliveredFrameCount`, the host's own count of frames it put
/// into the sink — and it is what separates `.streaming` from
/// `.showingPlaceholder`. Green still means live video from a named
/// camera; it just takes two signals to say so now.
enum VirtualCameraPreviewStatus: Equatable {
    /// Preview isn't running: the Camera tab isn't showing, or the
    /// extension isn't in the `.on` state.
    case idle
    /// The extension reports active but the device isn't in
    /// `AVCaptureDevice.DiscoverySession` — same condition the
    /// activator's visibility check escalates on.
    case deviceMissing
    /// The user denied camera access to the app, so no session can
    /// deliver anything.
    case accessDenied
    /// Session is running on the virtual camera and has never
    /// received a frame — the extension is sending nothing at all.
    ///
    /// Narrower than it used to be. "Host camera is dead" used to land
    /// here, because a dry sink meant a silent source stream; the
    /// placeholder now fills that silence, and
    /// `.showingPlaceholder` is where that fault reports. What's left
    /// is the opening moment of a session and an extension that isn't
    /// pumping.
    case waitingForFrames
    /// Frames were arriving and then stopped.
    case stalled
    /// Frames arriving, measured over the last sampling window.
    case streaming(fps: Int)
    /// Frames are arriving, but the host hasn't put one into the sink
    /// for `hostDeliveryGraceSeconds` — so what's on screen is the
    /// extension's no-signal placeholder, not the user's camera. The
    /// pipeline is healthy end to end; the camera at the end of it
    /// isn't sending.
    case showingPlaceholder

    /// True when the video surface should be shown. In every other
    /// case there's no session to render and the card shows a
    /// placeholder instead.
    var showsVideoSurface: Bool {
        switch self {
        case .idle, .deviceMissing, .accessDenied: return false
        case .waitingForFrames, .stalled, .streaming, .showingPlaceholder: return true
        }
    }

    /// One-line status sentence. `sourceName` is the camera the host
    /// pipeline actually has open (`VirtualCameraActivator
    /// .routedSourceName`), nil when nothing is on air.
    ///
    /// Frames arriving with no open source is its own answer, not a
    /// nameless relay: the extension re-emits its cached frame at full
    /// rate when the sink dries up, so that combination means the
    /// picture on screen is a held frame, not live video.
    func label(sourceName: String?) -> String {
        switch self {
        case .idle:
            return "Preview runs while the virtual camera is active."
        case .deviceMissing:
            return "Virtual camera isn't in the system's camera list."
        case .accessDenied:
            return "Camera access is off in System Settings → Privacy & Security."
        case .waitingForFrames:
            return "Source connected, no frames arriving."
        case .stalled:
            return "Frames stopped arriving."
        case .streaming(let fps):
            guard let sourceName else {
                return "Holding the last frame — no source camera is open."
            }
            return "Relaying \(fps) fps from \(sourceName)."
        case .showingPlaceholder:
            guard let sourceName else {
                return "No picture from your camera — showing the no-signal placeholder."
            }
            return "No picture from \(sourceName) — showing the no-signal placeholder."
        }
    }

    /// Dot colour, paired with `label(sourceName:)` so the two can't
    /// disagree about how good the news is. Green is reserved for
    /// "live frames from a named, open source".
    func dotTint(sourceName: String?) -> Color {
        switch self {
        case .idle:
            return .secondary
        case .deviceMissing, .accessDenied:
            return Theme.Color.error
        case .waitingForFrames, .stalled, .showingPlaceholder:
            return Theme.Color.warn
        case .streaming:
            return sourceName == nil ? Theme.Color.warn : Theme.Color.success
        }
    }

    /// How long the host can go without handing a frame to the sink
    /// before frames still arriving on the source get attributed to the
    /// extension's placeholder rather than to a live camera.
    ///
    /// Two terms, both load-bearing. `NoSignalPolicy.holdWindowNs` is
    /// the extension's own switchover point: inside it the source is
    /// re-emitting a real cached frame, so calling "placeholder" any
    /// earlier would be a lie about pixels that are genuinely the
    /// user's. On top of that the preview only looks once per
    /// `VirtualCameraPreviewController.sampleInterval`, so an enqueue
    /// landing just after a tick isn't seen until the next one, and a
    /// window measured to tick granularity needs a tick of slack.
    ///
    /// Sum is the earliest instant at which a dry host provably means
    /// placeholder pixels. Erring longer is the cheap direction: a
    /// slow-but-real source — a capture card at a few fps, comfortably
    /// inside the hold window — keeps reading as the live camera it is,
    /// and the cost of the extra second is a green row that lags a real
    /// fault by one tick.
    static let hostDeliveryGraceSeconds: TimeInterval =
        Double(NoSignalPolicy.holdWindowNs) / Double(NSEC_PER_SEC)
        + VirtualCameraPreviewController.sampleInterval

    /// The whole status derivation, as a pure function of the two
    /// counts the sampling tick collects. Split out so the matrix is
    /// testable without a CMIO stack, following
    /// `VirtualCameraActivator.autoRelaunchDecision`.
    ///
    /// - Parameters:
    ///   - sourceFrames: frames the preview's own output delivered
    ///     during the window — placeholder and live alike, since the
    ///     source stream doesn't distinguish them.
    ///   - windowSeconds: length of that window, measured rather than
    ///     assumed (timer leeway drifts it).
    ///   - everDelivered: whether this session has ever seen a frame,
    ///     which is what separates "never started" from "stopped".
    ///   - hostEverDelivered: whether `VirtualCameraActivator
    ///     .hostDeliveredFrameCount` has moved at all in this sampling
    ///     session. Mirrors `everDelivered` one level down: that one
    ///     tells "never started" from "stopped" for the *source*, this
    ///     one tells it for the *host*. The grace window below is only
    ///     for the second case — a host that proved it was alive and
    ///     then went quiet earns the benefit of the doubt for
    ///     `hostDeliveryGraceSeconds`. A host that has never delivered
    ///     has proven nothing, so there is no doubt to give the benefit
    ///     of: `false` here means placeholder immediately, independent
    ///     of `hostDrySeconds`.
    ///   - hostDrySeconds: time since `VirtualCameraActivator
    ///     .hostDeliveredFrameCount` last moved. Meaningless when
    ///     `hostEverDelivered` is `false` (there is no "last moved" to
    ///     measure from yet) and not consulted in that case.
    static func derive(
        sourceFrames: Int,
        windowSeconds: TimeInterval,
        everDelivered: Bool,
        hostEverDelivered: Bool,
        hostDrySeconds: TimeInterval
    ) -> VirtualCameraPreviewStatus {
        guard sourceFrames > 0 else {
            return everDelivered ? .stalled : .waitingForFrames
        }
        guard hostEverDelivered, hostDrySeconds < hostDeliveryGraceSeconds else {
            return .showingPlaceholder
        }
        return .streaming(
            fps: max(1, Int((Double(sourceFrames) / windowSeconds).rounded()))
        )
    }
}

/// Live preview of the virtual camera's output plus a one-line status
/// row, rendered as one row inside the Camera tab's Form.
///
/// Runs only while the Camera tab is showing (`isTabVisible`) *and*
/// the extension is `.on`. Leaving the tab or closing the Settings
/// window stops the session, which drops the extension's source-stream
/// client count back to zero — the host's own consumer-driven
/// teardown then applies, so an idle Settings window doesn't keep the
/// capture pipeline and the real camera hot.
struct VirtualCameraPreviewCard: View {
    @ObservedObject var activator: VirtualCameraActivator
    /// True while Settings → Camera is the selected tab. Driven from
    /// `AppDelegate.settingsTab`, which `SettingsView` resets to
    /// `.general` when the window closes — so a closing window turns
    /// the preview off through the same path a tab switch does.
    let isTabVisible: Bool

    @StateObject private var controller: VirtualCameraPreviewController

    /// Hands the activator to the controller at construction rather
    /// than wiring it up in `onAppear`, so the controller is never
    /// briefly sampling without its host-side signal. The
    /// `StateObject` autoclosure runs once for the view's lifetime and
    /// keeps the first activator it's given — safe here because
    /// `AppDelegate` owns exactly one for the life of the process.
    init(activator: VirtualCameraActivator, isTabVisible: Bool) {
        self.activator = activator
        self.isTabVisible = isTabVisible
        _controller = StateObject(
            wrappedValue: VirtualCameraPreviewController(activator: activator)
        )
    }

    private var shouldRun: Bool {
        isTabVisible && activator.state == .on
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            surface
            HStack(spacing: 8) {
                StatusDot(
                    tint: controller.status.dotTint(
                        sourceName: activator.routedSourceName
                    )
                )
                Text(controller.status.label(sourceName: activator.routedSourceName))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .onAppear { controller.setRunning(shouldRun) }
        .onDisappear { controller.setRunning(false) }
        .onChange(of: shouldRun) { _, running in
            controller.setRunning(running)
        }
    }

    private var surface: some View {
        ZStack {
            if controller.status.showsVideoSurface {
                CapturePreviewLayerView(session: controller.session)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                Image(systemName: Theme.Symbol.previewUnavailable)
                    .font(.title)
                    .foregroundStyle(.secondary)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.separator)
        )
    }
}

/// Owns the preview's `AVCaptureSession` and the frame-cadence
/// measurement behind the status row.
///
/// Deliberately a plain consumer: it finds the virtual camera by the
/// UID the extension publishes and opens it with an
/// `AVCaptureDeviceInput`, exactly like any video app. Everything the
/// *picture* proves, it proves the same way another app would, so "the
/// preview works" and "another app will work" stay the same statement.
///
/// The one exception is `VirtualCameraActivator
/// .hostDeliveredFrameCount`, sampled alongside the frame count. A
/// video app can't read it and doesn't need to — it just shows
/// whatever arrives — but this row claims to say *why* the picture
/// looks the way it does, and the extension's placeholder is
/// indistinguishable from live video on the wire. See
/// `VirtualCameraPreviewStatus`.
final class VirtualCameraPreviewController: NSObject, ObservableObject {
    @Published private(set) var status: VirtualCameraPreviewStatus = .idle

    /// Source of the host-side delivery count. Strong: the activator
    /// outlives every preview and holds nothing back, so there's no
    /// cycle to break.
    private let activator: VirtualCameraActivator

    /// Handed to the preview layer. One session for the controller's
    /// lifetime so the layer's binding stays stable across
    /// start/stop cycles; `stop()` removes the input and output
    /// instead of replacing the session.
    let session = AVCaptureSession()

    /// Status sampling cadence. Also the fps averaging window — long
    /// enough to be steady, short enough that a stall shows up while
    /// the user is still looking at the tab. Not private because
    /// `VirtualCameraPreviewStatus.hostDeliveryGraceSeconds` is
    /// defined in terms of it.
    static let sampleInterval: TimeInterval = 1.0

    private let sampleQueue = DispatchQueue(
        label: "com.ericwillis.avpainreliever.preview.samples",
        qos: .userInitiated
    )

    private var input: AVCaptureDeviceInput?
    private var output: AVCaptureVideoDataOutput?
    private var sampleTimer: DispatchSourceTimer?
    private var isRunning = false
    /// Last thing `setRunning` was told. Re-checked after the
    /// camera-access prompt returns: the user can switch tabs or close
    /// the window while that system dialog is up, and a session that
    /// started afterwards would hold the real camera open with nothing
    /// on screen.
    private var wantsRunning = false
    /// True between asking for camera access and the prompt's answer.
    /// Without it, a second `setRunning(true)` while the dialog is up
    /// (tab away and back) registers a second `requestAccess`
    /// callback, and the grant would then run `beginSession` twice.
    private var accessPromptPending = false
    /// Latches once the session has delivered at least one frame, so
    /// an empty sampling window can tell "never started" from
    /// "stopped". Reset by `stop()`; main-thread only.
    private var everDelivered = false
    private var lastSampleAt: TimeInterval = 0

    /// Host-side delivery count as of the last tick that saw it move,
    /// and when that was. Compared for *change* rather than growth:
    /// tearing the capture pipeline down and building it back up hands
    /// out a fresh `CMIOSinkWriter` whose count restarts at zero, and
    /// that restart is still evidence the host is alive. Main-thread
    /// only, like the tick that maintains them.
    private var lastHostDeliveryCount: UInt64 = 0
    private var lastHostDeliveryMovedAt: TimeInterval = 0

    /// Whether the host has put at least one frame into the sink in
    /// this sampling session — `hostDeliveredFrameCount` moving, or
    /// already nonzero when the session started. Reset by
    /// `beginSession()`; latched `true` by `sample()` the moment the
    /// count first moves. Gates `hostDeliveryGraceSeconds` in
    /// `.derive`: a host that has never delivered gets no grace,
    /// because grace is forgiveness for a host that proved it was
    /// alive and then paused, and this one hasn't proved anything yet.
    /// Without this, `startSampling()` seeding `lastHostDeliveryMovedAt`
    /// to "now" made a host that will never deliver look exactly like
    /// one that just delivered — the #125 masking bug this replaces.
    private var hostEverDelivered = false

    /// Frames counted since the last sampling tick. Written on
    /// `sampleQueue` by the sample-buffer delegate, read on the main
    /// thread by the tick, hence the lock rather than queue
    /// confinement.
    private let frameCountLock = NSLock()
    private var framesSinceSample = 0

    init(activator: VirtualCameraActivator) {
        self.activator = activator
        super.init()
    }

    /// Idempotent start/stop entry point. Every lifecycle signal the
    /// view has (appear, disappear, tab switch, extension state
    /// change) funnels through here.
    func setRunning(_ running: Bool) {
        wantsRunning = running
        running ? start() : stop()
    }

    private func start() {
        guard !isRunning else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            beginSession()
        case .notDetermined:
            guard !accessPromptPending else { return }
            accessPromptPending = true
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.accessPromptPending = false
                    guard self.wantsRunning else { return }
                    if granted {
                        self.beginSession()
                    } else {
                        self.setStatus(.accessDenied)
                    }
                }
            }
        case .denied, .restricted:
            setStatus(.accessDenied)
        @unknown default:
            setStatus(.accessDenied)
        }
    }

    private func beginSession() {
        guard !isRunning else { return }
        isRunning = true
        everDelivered = false
        hostEverDelivered = false
        setStatus(.waitingForFrames)
        configureIfPossible()
        startSampling()
    }

    /// Find the published virtual camera and wire it up. Runs on
    /// every sampling tick until it succeeds: the activator flips to
    /// `.on` before its visibility poll confirms the host can see the
    /// device, so a tab opened at exactly that moment has to keep
    /// looking rather than latching a false "not found".
    private func configureIfPossible() {
        guard input == nil else { return }
        guard let device = CameraDiscovery.virtualCameraDevice() else {
            setStatus(.deviceMissing)
            return
        }
        guard let deviceInput = try? AVCaptureDeviceInput(device: device) else {
            logger.error("Preview: AVCaptureDeviceInput failed for the virtual camera")
            setStatus(.deviceMissing)
            return
        }

        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: sampleQueue)
        input = deviceInput
        output = videoOutput
        setStatus(.waitingForFrames)

        // Every mutation of the session runs on `sampleQueue`, so
        // configuration and start/stop can't interleave when the user
        // flips tabs quickly. `startRunning` also blocks for as long
        // as the device takes to spin up, which has no business
        // happening on the main thread.
        let session = self.session
        sampleQueue.async { [weak self] in
            session.beginConfiguration()
            // `canAdd…` before every add: the device was looked up on
            // the main thread a moment ago and can be gone by now (the
            // user toggling the virtual camera off on this very tab, an
            // extension crash or Sparkle replace), and a rejected add
            // raises an ObjC exception Swift can't catch — it takes the
            // app down.
            //
            // No sessionPreset, for the reason spelled out in
            // `CameraCaptureSession.installAndStart`: never force a
            // format onto the device. The extension's source stream
            // advertises exactly one (1280×720 BGRA), so the default
            // pick is the only pick.
            let canAdd = session.canAddInput(deviceInput)
                && session.canAddOutput(videoOutput)
            if canAdd {
                session.addInput(deviceInput)
                session.addOutput(videoOutput)
            }
            session.commitConfiguration()
            guard canAdd else {
                videoOutput.setSampleBufferDelegate(nil, queue: nil)
                logger.error("Preview: session refused the virtual camera's input/output — treating the device as gone")
                DispatchQueue.main.async {
                    self?.handleConfigurationRefused()
                }
                return
            }
            session.startRunning()
        }
        logger.notice("Preview: opened the virtual camera as a consumer")
    }

    /// The session wouldn't take the device. Drop back to the
    /// device-missing state with nothing installed, so the next
    /// sampling tick retries the lookup from scratch.
    private func handleConfigurationRefused() {
        guard isRunning else { return }
        input = nil
        output = nil
        setStatus(.deviceMissing)
    }

    private func stop() {
        // Ahead of the `isRunning` guard: a session that never started
        // can still have left a status behind (`.accessDenied` from a
        // denied prompt), and switching the preview off has to clear
        // it — otherwise the red access error outlives the virtual
        // camera being deliberately turned off.
        setStatus(.idle)
        guard isRunning else { return }
        isRunning = false
        sampleTimer?.cancel()
        sampleTimer = nil
        everDelivered = false
        hostEverDelivered = false

        // Input and output are installed together or not at all;
        // nothing to release if `configureIfPossible` never found the
        // device.
        guard let input, let output else { return }
        self.input = nil
        self.output = nil
        let session = self.session
        sampleQueue.async { [weak self] in
            // Detaching the delegate from the delegate's own queue
            // guarantees no callback is in flight past this point, so
            // the counter reset that follows can't be outrun by a
            // frame leaking into the next run's first tick.
            output.setSampleBufferDelegate(nil, queue: nil)
            self?.resetFrameCount()
            session.beginConfiguration()
            // Remove only what the configuration pass actually
            // installed: a refused add (see `configureIfPossible`)
            // leaves these detached, and removing a stranger raises an
            // uncatchable ObjC exception.
            if session.inputs.contains(where: { $0 === input }) {
                session.removeInput(input)
            }
            if session.outputs.contains(where: { $0 === output }) {
                session.removeOutput(output)
            }
            session.commitConfiguration()
            session.stopRunning()
        }
        logger.notice("Preview: released the virtual camera")
    }

    private func startSampling() {
        lastSampleAt = ProcessInfo.processInfo.systemUptime
        // Seed the host-delivery baseline at the same instant. This
        // only feeds the grace window's dryness clock — it does not by
        // itself claim the host has ever delivered. A nonzero count
        // here means a pipeline that was already live before this
        // preview session opened (the activator's count is
        // process-lifetime, not session-lifetime), which is real
        // evidence, so `hostEverDelivered` starts `true`. A zero count
        // is the opposite: no evidence at all yet, so it starts
        // `false` and `.derive` gives it no grace — `sample()` flips it
        // the moment the count actually moves.
        lastHostDeliveryCount = activator.hostDeliveredFrameCount
        lastHostDeliveryMovedAt = lastSampleAt
        hostEverDelivered = lastHostDeliveryCount != 0
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + Self.sampleInterval,
            repeating: Self.sampleInterval,
            leeway: .milliseconds(200)
        )
        timer.setEventHandler { [weak self] in
            self?.sample()
        }
        sampleTimer?.cancel()
        sampleTimer = timer
        timer.resume()
    }

    private func sample() {
        // Still hunting for the device (fresh activation, or the
        // extension really isn't published).
        configureIfPossible()

        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastSampleAt
        lastSampleAt = now
        let frames = takeFrameCount()

        let hostCount = activator.hostDeliveredFrameCount
        if hostCount != lastHostDeliveryCount {
            lastHostDeliveryCount = hostCount
            lastHostDeliveryMovedAt = now
            hostEverDelivered = true
        }

        // No installed device → `configureIfPossible` owns the status
        // (`.deviceMissing`), and any frames counted are leftovers from
        // the run that just ended rather than evidence of a live feed.
        guard input != nil else { return }

        if frames > 0 { everDelivered = true }
        setStatus(
            .derive(
                sourceFrames: frames,
                windowSeconds: elapsed,
                everDelivered: everDelivered,
                hostEverDelivered: hostEverDelivered,
                hostDrySeconds: now - lastHostDeliveryMovedAt
            )
        )
    }

    /// Equality-guarded so an unchanged status doesn't fire
    /// `objectWillChange` once a second for the life of the tab. The
    /// source-name half of the row has its own publisher
    /// (`VirtualCameraActivator.routedSourceName`) and doesn't rely on
    /// this churn to stay fresh.
    private func setStatus(_ newStatus: VirtualCameraPreviewStatus) {
        guard status != newStatus else { return }
        status = newStatus
    }

    private func takeFrameCount() -> Int {
        frameCountLock.lock()
        defer { frameCountLock.unlock() }
        let count = framesSinceSample
        framesSinceSample = 0
        return count
    }

    private func resetFrameCount() {
        frameCountLock.lock()
        framesSinceSample = 0
        frameCountLock.unlock()
    }

    /// Last-resort teardown. `onDisappear` and the tab-selection flag
    /// are the intended paths, but SwiftUI can drop a scene's view
    /// tree without calling either, and a session left running holds
    /// the real camera open behind a window that no longer exists.
    /// Only touches the capture objects — no `@Published` writes, the
    /// observers are already gone.
    deinit {
        sampleTimer?.cancel()
        let session = self.session
        let output = self.output
        sampleQueue.async {
            output?.setSampleBufferDelegate(nil, queue: nil)
            session.stopRunning()
        }
    }
}

extension VirtualCameraPreviewController: AVCaptureVideoDataOutputSampleBufferDelegate {
    /// Frame cadence is the only thing wanted from the buffers — the
    /// preview layer renders them independently — so this stays a
    /// counter bump. The status row's fps comes from dividing it by
    /// the sampling window.
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        frameCountLock.lock()
        framesSinceSample += 1
        frameCountLock.unlock()
    }
}

/// `AVCaptureVideoPreviewLayer` as a SwiftUI view. The layer is the
/// host view's *backing* layer, so AppKit resizes it with the view and
/// there's no manual frame bookkeeping. Corner radius lives on the
/// layer because a SwiftUI `clipShape` doesn't clip AppKit layer
/// content.
private struct CapturePreviewLayerView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ view: PreviewHostView, context: Context) {
        view.previewLayer.session = session
        // Covers attaching to a session that was already running
        // (fast tab flips outrun the stop), where the start
        // notification fired before this view existed.
        view.applyMirroring()
    }

    final class PreviewHostView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            // Black rather than clear so "no frames yet" reads as the
            // black feed a video app would show, not as a hole in the
            // window.
            previewLayer.backgroundColor = NSColor.black.cgColor
            previewLayer.videoGravity = .resizeAspect
            previewLayer.cornerRadius = 6
            previewLayer.masksToBounds = true
            // The preview connection only exists once the session
            // gains its input on the capture queue, so mirroring is
            // applied when the session reports it started running.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(sessionDidStartRunning(_:)),
                name: .AVCaptureSessionDidStartRunning,
                object: nil
            )
        }

        @objc private func sessionDidStartRunning(_ note: Notification) {
            guard (note.object as? AVCaptureSession) === previewLayer.session else { return }
            DispatchQueue.main.async { [weak self] in self?.applyMirroring() }
        }

        /// Mirror like every macOS self-view. Preview-only: the
        /// virtual camera's output to video apps is untouched — they
        /// apply their own self-view mirroring.
        func applyMirroring() {
            guard let connection = previewLayer.connection,
                  connection.isVideoMirroringSupported else { return }
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }

        required init?(coder: NSCoder) {
            fatalError("PreviewHostView is never loaded from a nib")
        }

        override func makeBackingLayer() -> CALayer { previewLayer }
    }
}
