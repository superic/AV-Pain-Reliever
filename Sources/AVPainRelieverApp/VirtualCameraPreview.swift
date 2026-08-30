import SwiftUI
import AVFoundation
import AVPainReliever
import os.log

private let logger = Logger(
    subsystem: "com.ericwillis.avpainreliever",
    category: "CameraPreview"
)

/// What the Settings → Camera live preview is currently seeing.
///
/// Derived from the preview's own `AVCaptureSession` — the same kind
/// of session any video app opens on the published CMIO device — so a
/// green status here means a real consumer got real frames through the
/// real pipeline: extension published, consumer notification
/// delivered, host capture spun up, frames relayed. Nothing in here
/// peeks at host-internal state.
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
    /// received a frame. Means the extension has no cached frame to
    /// forward, i.e. the host's source camera isn't delivering.
    case waitingForFrames
    /// Frames were arriving and then stopped.
    case stalled
    /// Frames arriving, measured over the last sampling window.
    case streaming(fps: Int)

    /// True when the video surface should be shown. In every other
    /// case there's no session to render and the card shows a
    /// placeholder instead.
    var showsVideoSurface: Bool {
        switch self {
        case .idle, .deviceMissing, .accessDenied: return false
        case .waitingForFrames, .stalled, .streaming: return true
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
        case .waitingForFrames, .stalled:
            return Theme.Color.warn
        case .streaming:
            return sourceName == nil ? Theme.Color.warn : Theme.Color.success
        }
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

    @StateObject private var controller = VirtualCameraPreviewController()

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
        .frame(width: 256, height: 144)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.separator)
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// Owns the preview's `AVCaptureSession` and the frame-cadence
/// measurement behind the status row.
///
/// Deliberately a plain consumer: it finds the virtual camera by the
/// UID the extension publishes and opens it with an
/// `AVCaptureDeviceInput`, exactly like any video app. It never reads
/// the activator's pipeline internals, so "the preview works" and
/// "another app will work" are the same statement.
final class VirtualCameraPreviewController: NSObject, ObservableObject {
    @Published private(set) var status: VirtualCameraPreviewStatus = .idle

    /// Handed to the preview layer. One session for the controller's
    /// lifetime so the layer's binding stays stable across
    /// start/stop cycles; `stop()` removes the input and output
    /// instead of replacing the session.
    let session = AVCaptureSession()

    /// Status sampling cadence. Also the fps averaging window — long
    /// enough to be steady, short enough that a stall shows up while
    /// the user is still looking at the tab.
    private static let sampleInterval: TimeInterval = 1.0

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

    /// Frames counted since the last sampling tick. Written on
    /// `sampleQueue` by the sample-buffer delegate, read on the main
    /// thread by the tick, hence the lock rather than queue
    /// confinement.
    private let frameCountLock = NSLock()
    private var framesSinceSample = 0

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

        // No installed device → `configureIfPossible` owns the status
        // (`.deviceMissing`), and any frames counted are leftovers from
        // the run that just ended rather than evidence of a live feed.
        guard input != nil else { return }

        if frames > 0 {
            everDelivered = true
            setStatus(.streaming(fps: max(1, Int((Double(frames) / elapsed).rounded()))))
        } else {
            setStatus(everDelivered ? .stalled : .waitingForFrames)
        }
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
        }

        required init?(coder: NSCoder) {
            fatalError("PreviewHostView is never loaded from a nib")
        }

        override func makeBackingLayer() -> CALayer { previewLayer }
    }
}
