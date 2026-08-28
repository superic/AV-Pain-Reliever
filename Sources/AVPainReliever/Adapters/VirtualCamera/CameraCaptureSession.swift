import Foundation
import AVFoundation
import CoreVideo

/// Captures from a webcam and hands each frame to `CMIOSinkWriter`,
/// which enqueues it on the virtual camera's sink stream. The host
/// app is a normal user-process AVFoundation client — no sandbox,
/// no recursion through CMIO. TCC permission for the camera is
/// granted to the host on first use; the extension never touches
/// AVFoundation.
///
/// Source selection:
///
/// - First start picks the system's preferred camera (`userPreferredCamera`
///   → `systemPreferredCamera` → first discovered) so the virtual
///   camera shows *something* before the engine has resolved a
///   profile.
/// - `setSource(named:)` swaps inputs on the running session at
///   runtime. The active profile drives this through
///   `VirtualCameraSourceController` from `ProfileApplier`.
///
/// Switching uses `beginConfiguration` / `commitConfiguration` so
/// the session keeps running across the swap — the only gap is the
/// ~500 ms it takes the new device to start delivering frames. The
/// extension covers that gap by holding the last frame.
public final class CameraCaptureSession: NSObject {
    private let session = AVCaptureSession()
    private let captureQueue = DispatchQueue(
        label: "com.ericwillis.avpainreliever.host.capture",
        qos: .userInteractive
    )
    private let sink: CMIOSinkWriter
    private let logger: ApplierLogger
    private var sinkStarted = false
    private var capturedFrameCount: UInt64 = 0
    private var output: AVCaptureVideoDataOutput?
    private var currentInput: AVCaptureDeviceInput?
    private var currentDeviceUniqueID: String?

    /// Log-rate-limit cadence for the "sink writer still not ready"
    /// retry path. Capture is steady-state at 30 fps, so every Nth
    /// frame is roughly one log line per N/30 seconds while the
    /// extension is missing — informative without flooding.
    private static let sinkRetryLogStride: UInt64 = 90

    /// Camera the active profile wanted as the source at session-
    /// boot time. The activator remembers the most recent
    /// `setSource(named:)` request and passes it here so that when
    /// lazy capture starts up late (a Zoom client connects after a
    /// profile-driven setSource fired against a then-nil session),
    /// we open the right device on the first attempt instead of
    /// falling through to `userPreferredCamera` — which under the
    /// new override semantics is the virtual camera itself, and
    /// would create a self-source feedback loop.
    private let initialSourceName: String?

    /// Tokens returned by `NotificationCenter.addObserver(forName:…)`.
    /// Released in `deinit` so the runtime stops calling the closures
    /// after the capture session is gone. The selector-based form
    /// auto-zeroed, but the closure-token form requires explicit
    /// teardown.
    private var observers: [NSObjectProtocol] = []

    public init(
        sink: CMIOSinkWriter,
        logger: ApplierLogger,
        initialSourceName: String? = nil
    ) {
        self.sink = sink
        self.logger = logger
        self.initialSourceName = initialSourceName
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .AVCaptureSessionRuntimeError,
            object: session,
            queue: nil
        ) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.logger.error("AVCaptureSession runtime error: \(error?.localizedDescription ?? "unknown")")
        })
        observers.append(center.addObserver(
            forName: .AVCaptureSessionDidStartRunning,
            object: session,
            queue: nil
        ) { [weak self] _ in
            self?.logger.info("AVCaptureSession reported running")
        })
    }

    deinit {
        let center = NotificationCenter.default
        for token in observers {
            center.removeObserver(token)
        }
    }

    /// Boots up capture asynchronously. Returns immediately.
    /// Failures are logged; the menu bar doesn't surface them today.
    public func start() {
        captureQueue.async { [weak self] in
            self?.bootIfAuthorized()
        }
    }

    public func stop() {
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.session.stopRunning()
            if self.sinkStarted {
                self.sink.stop()
                self.sinkStarted = false
            }
        }
    }

    private func bootIfAuthorized() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        logger.info("Camera authorization status: \(status.rawValue) (0=notDetermined 1=restricted 2=denied 3=authorized)")
        switch status {
        case .authorized:
            installAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                self?.logger.info("Camera access request: granted=\(granted)")
                self?.captureQueue.async {
                    if granted {
                        self?.installAndStart()
                    } else {
                        self?.logger.error("Camera access denied; virtual camera will see no frames")
                    }
                }
            }
        case .denied, .restricted:
            logger.error("Camera access denied/restricted; virtual camera will see no frames")
        @unknown default:
            logger.error("Unknown camera authorization status")
        }
    }

    private func installAndStart() {
        guard !session.isRunning else {
            logger.info("installAndStart: session already running")
            return
        }

        guard let device = pickInitialDevice() else {
            logger.error("No video capture devices available")
            return
        }
        logger.info("Initial capture device: \(device.localizedName) (\(device.uniqueID))")

        session.beginConfiguration()
        // No sessionPreset: never force a specific format onto the
        // device (the default .high picks from the device's own
        // supported formats). Same lesson as the videoSettings
        // comment below, one layer up: .hd1280x720 asks the DEVICE
        // to run a 720p format, and a capture card only offers the
        // format of its live HDMI signal (HDMI to U3 capture
        // delivers 1080p60 only). With the preset forced, a solo
        // open stalls at zero frames with no error; frames only
        // flowed while another app had negotiated the device's
        // native format. `CMIOSinkWriter` normalizes every frame to
        // the source stream's 1280×720 BGRA via
        // `VTPixelTransferSession`, so the capture format is free
        // to be whatever the device actually does.

        guard installInput(device: device) else {
            session.commitConfiguration()
            return
        }

        let output = AVCaptureVideoDataOutput()
        // Deliver the device's NATIVE pixel format and dimensions.
        // An earlier iteration forced 1280×720 BGRA via
        // `videoSettings`, which works for the FaceTime HD camera
        // but silently produces zero frames on USB capture cards
        // (HDMI to U3 capture 0x1e4e/0x701f is the user's known
        // case: it advertises BGRA in
        // `availableVideoPixelFormatTypes` but the actual delivery
        // path drops every frame). Letting the device
        // pick its own format makes the AVCaptureSession work for
        // every camera; `CMIOSinkWriter` then converts to
        // 1280×720 BGRA via `VTPixelTransferSession` before
        // enqueueing — that's the format the extension's source
        // stream advertises to AVCapture clients.
        output.videoSettings = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: captureQueue)

        guard session.canAddOutput(output) else {
            logger.error("Cannot add video output")
            session.commitConfiguration()
            return
        }
        session.addOutput(output)
        self.output = output
        session.commitConfiguration()

        logger.info("Calling session.startRunning()")
        session.startRunning()
        logger.info("session.isRunning=\(self.session.isRunning)")

        sinkStarted = sink.start()
        logger.info("sink.start() returned \(self.sinkStarted)")
    }

    /// Initial source pick. Priority:
    ///
    /// 1. `initialSourceName` if the activator passed one — i.e. the
    ///    active profile already named a source camera before the
    ///    consumer connected and we'd otherwise have lost it.
    /// 2. Fallback chain: userPreferred → systemPreferred → first
    ///    discovered.
    ///
    /// In every case, the embedded virtual camera is rejected. If
    /// the host opened its own output as a source we'd close a
    /// feedback loop — host writes whatever it just read, the
    /// extension forwards it back, frozen frame forever. Under the
    /// `preferredCameraOverride` semantics `userPreferredCamera`
    /// regularly *is* the virtual camera, which is exactly what we
    /// want for AVFoundation-modern apps but exactly what we don't
    /// want here.
    private func pickInitialDevice() -> AVCaptureDevice? {
        if let name = initialSourceName,
           let device = Self.findDevice(named: name)
        {
            return device
        }
        if let user = AVCaptureDevice.userPreferredCamera,
           !Self.isVirtualCamera(user)
        {
            return user
        }
        if let system = AVCaptureDevice.systemPreferredCamera,
           !Self.isVirtualCamera(system)
        {
            return system
        }
        return CameraDiscovery.session().devices
            .first { !Self.isVirtualCamera($0) }
    }

    /// True iff `device` is the embedded AV Pain Reliever virtual
    /// camera. Used to keep the host from ever opening its own
    /// output as a capture source.
    private static func isVirtualCamera(_ device: AVCaptureDevice) -> Bool {
        device.uniqueID == VirtualCameraIdentity.deviceUID
    }

    /// Add an `AVCaptureDeviceInput` for `device` to the session.
    /// Caller is responsible for `beginConfiguration` /
    /// `commitConfiguration`. Updates `currentInput` and
    /// `currentDeviceUniqueID` on success.
    private func installInput(device: AVCaptureDevice) -> Bool {
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                logger.error("Cannot add input for \(device.localizedName)")
                return false
            }
            session.addInput(input)
            currentInput = input
            currentDeviceUniqueID = device.uniqueID
            return true
        } catch {
            logger.error("AVCaptureDeviceInput failed for \(device.localizedName): \(error.localizedDescription)")
            return false
        }
    }

    /// Swap the running session's input to the camera with the given
    /// `localizedName`. No-ops when the source is already that
    /// device. Runs on `captureQueue` so it serializes with frame
    /// delivery.
    func switchSource(toLocalizedName name: String) {
        captureQueue.async { [weak self] in
            self?.swapInputLocked(toLocalizedName: name)
        }
    }

    private func swapInputLocked(toLocalizedName name: String) {
        guard let device = Self.findDevice(named: name) else {
            logger.error("switchSource: no camera with localizedName '\(name)' — skipping")
            return
        }
        if device.uniqueID == currentDeviceUniqueID {
            logger.info("switchSource: already on '\(name)' — no-op")
            return
        }

        logger.info("switchSource: '\(self.currentDeviceUniqueID ?? "<none>")' → '\(device.uniqueID)' (\(name))")

        session.beginConfiguration()
        // Stash the previous input so we can put it back if the new
        // device fails to install. Without this fallback a transient
        // failure (device unplugged between findDevice and
        // AVCaptureDeviceInput init, format incompatibility surfacing
        // late) leaves the session with no input and frames silently
        // stop — the previous-input restore keeps the pipeline flowing.
        let previousInput = currentInput
        let previousUID = currentDeviceUniqueID
        if let previousInput {
            session.removeInput(previousInput)
            self.currentInput = nil
            self.currentDeviceUniqueID = nil
        }
        if !installInput(device: device) {
            if let previousInput, session.canAddInput(previousInput) {
                session.addInput(previousInput)
                self.currentInput = previousInput
                self.currentDeviceUniqueID = previousUID
                logger.warn("switchSource: install failed; restored previous source '\(previousUID ?? "<none>")'")
            } else {
                logger.error("switchSource: install failed and no previous source could be restored — session has no input")
            }
        }
        session.commitConfiguration()

        if !session.isRunning {
            // installAndStart never finished (e.g. initial discovery
            // returned nil). Start now that we have a real source.
            logger.info("switchSource: session was not running — starting")
            session.startRunning()
        }

        if !sinkStarted {
            sinkStarted = sink.start()
            if sinkStarted {
                logger.info("switchSource: sink started after source swap")
            }
        }
    }

    private static func findDevice(named name: String) -> AVCaptureDevice? {
        CameraDiscovery.session().devices.first {
            $0.localizedName == name && !isVirtualCamera($0)
        }
    }
}

extension CameraCaptureSession: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        capturedFrameCount += 1
        if capturedFrameCount == 1, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let w = CVPixelBufferGetWidth(pb)
            let h = CVPixelBufferGetHeight(pb)
            let fourcc = FourCC.pretty(CVPixelBufferGetPixelFormatType(pb))
            logger.info("First frame from webcam: \(w)x\(h) format=\(fourcc)")
        }

        // If sink wasn't ready when capture started (extension not
        // yet active), retry every few frames.
        if !sinkStarted {
            sinkStarted = sink.start()
            if sinkStarted {
                logger.info("Sink writer connected on retry (after \(self.capturedFrameCount) frames)")
            } else if capturedFrameCount % Self.sinkRetryLogStride == 1 {
                logger.error("Sink writer still not ready after \(self.capturedFrameCount) frames")
            }
            if !sinkStarted { return }
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        let hostTime = CMClockGetTime(CMClockGetHostTimeClock())
        let hostTimeNs = UInt64(hostTime.seconds * Double(NSEC_PER_SEC))
        sink.enqueue(pixelBuffer: pixelBuffer, hostTimeNs: hostTimeNs)
    }
}

// MARK: - Engine-facing source swap

extension CameraCaptureSession {
    /// Swap the running session's input to the camera with the given
    /// `localizedName`. The `VirtualCameraSourceController` plumbed
    /// into `ProfileApplier` is the host's activator (it gates on the
    /// extension's lifecycle); it forwards into this method when the
    /// virtual camera is live. Returns `.notFound` if no such camera
    /// is currently visible, `.ok` otherwise.
    public func setSource(named: String) -> CameraApplyResult {
        logger.debug("CameraCaptureSession.setSource(named: \(named))")
        guard Self.findDevice(named: named) != nil else {
            logger.debug("CameraCaptureSession.setSource: \(named) not visible, returning .notFound")
            return .notFound
        }
        switchSource(toLocalizedName: named)
        return .ok
    }
}
