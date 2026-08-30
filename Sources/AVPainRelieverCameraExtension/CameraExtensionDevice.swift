import Foundation
import CoreMediaIO
import CoreMedia
import IOKit.audio
import os.log

private let logger = Logger(
    subsystem: "com.ericwillis.avpainreliever.CameraExtension",
    category: "Device"
)

/// The single virtual camera device registered by this extension.
/// Owns two streams:
///
/// - `streamSource` (.source direction) — what AVCapture clients
///   like Zoom read from.
/// - `streamSink` (.sink direction) — what the host app writes to
///   over CMIO's cross-process queue.
///
/// When the host starts streaming into the sink, this class kicks
/// off a `consumeSampleBuffer` loop that pulls frames out and
/// pushes them through the source stream. macOS's CMIO subsystem
/// passes IOSurfaces between host and extension processes
/// transparently — no explicit XPC.
///
/// That loop is a timer, and it runs for as long as the host holds
/// the sink open — which some clients (Zoom) do for their entire
/// process lifetime, call or no call. So the pump has two cadences:
/// the full 90 Hz drain whenever anything is happening, and a slow
/// idle tick once the source has no clients *and* the sink has been
/// dry for a few seconds. It jumps back to full rate the instant a
/// frame arrives or an AVCapture client attaches.
///
/// Identifier and name are stable so reinstalls don't churn the
/// device registry — apps that remember "AV Pain Reliever" by
/// uniqueID continue to find it after a v0.2.x → v0.2.y upgrade.
final class CameraExtensionDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private(set) var streamSource: CameraExtensionStreamSource!
    private(set) var streamSink: CameraExtensionStreamSink!

    private static let deviceUUID = UUID(
        uuidString: "B45B7E4D-3F4E-4F4D-9C2A-1B2C3D4E5F60"
    )!
    private static let sourceStreamUUID = UUID(
        uuidString: "C7E8F901-2A3B-4C5D-6E7F-8091A2B3C4D5"
    )!
    private static let sinkStreamUUID = UUID(
        uuidString: "D8F9A012-3B4C-5D6E-7F80-91A2B3C4D5E6"
    )!

    /// The host app finds this device via `CMIODevicePropertyDeviceUID`.
    /// The string form must match what we set as `deviceID` on the
    /// `CMIOExtensionDevice` — exposed here so the host doesn't
    /// have to reach inside.
    static let deviceUID = deviceUUID.uuidString

    private let consumeQueue = DispatchQueue(
        label: "com.ericwillis.avpainreliever.cameraext.consume",
        qos: .userInteractive
    )
    private var consumeTimer: DispatchSourceTimer?

    /// Whether `consumeTimer` is currently on the idle schedule.
    /// Mutated only on `consumeQueue`; read from the consume
    /// completion as a cheap "do I need to hop?" hint.
    private var pumpIsIdle = false

    init(localizedName: String) {
        super.init()
        self.device = CMIOExtensionDevice(
            localizedName: localizedName,
            deviceID: Self.deviceUUID,
            legacyDeviceID: nil,
            source: self
        )

        let format = CameraExtensionStreamSource.standardFormat()

        self.streamSource = CameraExtensionStreamSource(
            localizedName: "\(localizedName).video",
            streamID: Self.sourceStreamUUID,
            streamFormat: format
        )
        streamSource.device = self

        self.streamSink = CameraExtensionStreamSink(
            localizedName: "\(localizedName).sink",
            streamID: Self.sinkStreamUUID,
            streamFormat: format
        )
        streamSink.device = self

        do {
            // Order matters: source first, sink second. The host
            // picks the sink by index (streams[1]) when finding it.
            try device.addStream(streamSource.stream)
            try device.addStream(streamSink.stream)
        } catch {
            fatalError("addStream failed: \(error)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>)
        throws -> CMIOExtensionDeviceProperties
    {
        let p = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            // 'virt' FourCC. Constant is named for audio but is the
            // conventional value for any virtual CMIO device.
            p.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            p.model = "AV Pain Reliever Virtual Camera"
        }
        return p
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties)
        throws {}

    // MARK: - Sink → source pipeline

    /// Called by `CameraExtensionStreamSink.startStream` when the
    /// host starts pushing frames to the sink. Begins the consume
    /// timer that drains the sink and forwards to the source.
    func sinkStartedStreaming(client: CMIOExtensionClient) {
        logger.info("sinkStartedStreaming")
        consumeQueue.async { [weak self] in
            guard let self else { return }
            self.startConsumeTimer(client: client)
        }
    }

    func sinkStoppedStreaming() {
        logger.info("sinkStoppedStreaming")
        consumeQueue.async { [weak self] in
            self?.consumeTimer?.cancel()
            self?.consumeTimer = nil
        }
    }

    /// Active cadence: 3× the frame rate so we never lag behind a
    /// producer that happens to deliver slightly bursty frames.
    private static let activeTickInterval = DispatchTimeInterval.nanoseconds(
        Int(1_000_000_000.0 / (30.0 * 3.0))
    )

    /// Idle cadence: just often enough to notice the sink coming back
    /// to life on its own, in the case where no client edge fires.
    private static let idleTickInterval = DispatchTimeInterval.milliseconds(500)

    /// Generous leeway on both schedules — the 3× oversampling exists
    /// precisely so individual wakeups don't have to be punctual, and
    /// slack lets the kernel coalesce our timer with everyone else's
    /// instead of waking the core on its own. (The old `.strict` +
    /// 1 ms schedule cost ~1.7% of a core around the clock whenever a
    /// client held the sink open.)
    private static let activeTickLeeway = DispatchTimeInterval.milliseconds(8)
    private static let idleTickLeeway = DispatchTimeInterval.milliseconds(250)

    /// How many back-to-back empty consumes before we downshift —
    /// ~3 s at the active cadence.
    private static let idleDownshiftAfterEmpties: UInt64 = 90 * 3

    /// Whether the pump can drop to the idle cadence. Deliberately
    /// conservative: a watching client keeps the full-rate schedule
    /// no matter how dry the sink is, because the hold-last-frame
    /// re-emits it depends on ride on these same ticks.
    private static func shouldRunIdle(
        sourceClients: UInt32,
        consecutiveEmptyConsumes: UInt64
    ) -> Bool {
        sourceClients == 0
            && consecutiveEmptyConsumes >= idleDownshiftAfterEmpties
    }

    private func startConsumeTimer(client: CMIOExtensionClient) {
        consumeTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: consumeQueue)
        pumpIsIdle = false
        consecutiveEmptyConsumes = 0
        schedule(timer, idle: false)
        timer.setEventHandler { [weak self] in
            self?.consumeOne(client: client)
        }
        consumeTimer = timer
        timer.resume()
    }

    private func schedule(_ timer: DispatchSourceTimer, idle: Bool) {
        timer.schedule(
            deadline: .now(),
            repeating: idle ? Self.idleTickInterval : Self.activeTickInterval,
            leeway: idle ? Self.idleTickLeeway : Self.activeTickLeeway
        )
    }

    /// Move the running pump between cadences. Must be called on
    /// `consumeQueue` — it touches the timer and the empty-run
    /// counter that the tick handler owns.
    private func setPumpIdle(_ idle: Bool) {
        guard pumpIsIdle != idle, let timer = consumeTimer else { return }
        pumpIsIdle = idle
        if !idle { consecutiveEmptyConsumes = 0 }
        schedule(timer, idle: idle)
        logger.info(
            "consume pump → \(idle ? "idle" : "active", privacy: .public) cadence"
        )
    }

    /// Called by `CameraExtensionStreamSource.startStream` on the 0→1
    /// client edge. Someone is about to watch, so the pump needs to
    /// be back at full rate before the first frame is expected.
    func sourceClientBecameActive() {
        consumeQueue.async { [weak self] in
            self?.setPumpIdle(false)
        }
    }

    private var consumedCount: UInt64 = 0
    private var forwardedCount: UInt64 = 0
    private var emptyConsumeCount: UInt64 = 0
    private var consecutiveEmptyConsumes: UInt64 = 0
    private var heldFrameCount: UInt64 = 0

    /// Most recent sample buffer received from the host. Re-emitted
    /// when the sink yields nothing — keeps the source flowing during
    /// the ~500 ms input-swap window inside `CameraCaptureSession`.
    /// Without this, AVCapture clients (Zoom) see the call freeze or
    /// drop while the new camera warms up.
    private var lastFrameImage: CVPixelBuffer?
    private var lastFrameFormat: CMFormatDescription?

    /// Host time of the most recent frame we sent through the source
    /// stream — whether a fresh sink frame or a held repeat. Used to
    /// rate-limit hold-last-frame emissions to roughly the source's
    /// declared frame duration.
    private var lastSourceSendHostTimeNs: UInt64 = 0

    /// Minimum spacing between hold-last-frame emissions. Matches the
    /// source's declared 30 fps so AVCapture clients see a steady
    /// cadence rather than a 90 Hz burst (the consume timer ticks at
    /// 3× framerate, but only one in three should re-emit).
    private static let heldFrameMinSpacingNs: UInt64 =
        UInt64(1_000_000_000.0 / 30.0)

    private func consumeOne(client: CMIOExtensionClient) {
        streamSink.stream.consumeSampleBuffer(from: client) {
            [weak self] sampleBuffer, sequenceNumber, _, _, error in
            guard let self else { return }
            if let error {
                logger.error("consume error: \(error.localizedDescription, privacy: .public)")
                return
            }
            let nowNs = UInt64(
                CMClockGetTime(CMClockGetHostTimeClock()).seconds
                    * Double(NSEC_PER_SEC)
            )

            guard let sampleBuffer else {
                self.emptyConsumeCount += 1
                self.consecutiveEmptyConsumes += 1
                if self.emptyConsumeCount % 90 == 1 {
                    logger.debug(
                        "consume returned no buffer (\(self.emptyConsumeCount, privacy: .public) empty so far)"
                    )
                }
                self.maybeEmitHeldFrame(nowNs: nowNs)
                if !self.pumpIsIdle,
                   Self.shouldRunIdle(
                       sourceClients: self.streamSource.streamingCounter,
                       consecutiveEmptyConsumes: self.consecutiveEmptyConsumes
                   )
                {
                    self.consumeQueue.async { self.setPumpIdle(true) }
                }
                return
            }

            self.consecutiveEmptyConsumes = 0
            if self.pumpIsIdle {
                self.consumeQueue.async { self.setPumpIdle(false) }
            }
            self.consumedCount += 1
            if self.consumedCount == 1 || self.consumedCount % 60 == 0 {
                logger.info(
                    "Consumed frame #\(self.consumedCount, privacy: .public), source streamingCounter=\(self.streamSource.streamingCounter, privacy: .public)"
                )
            }

            // Tell the sink the frame moved through, so its
            // `streamSinkEndOfData` and underrun counters stay
            // sane.
            let scheduled = CMIOExtensionScheduledOutput(
                sequenceNumber: sequenceNumber,
                hostTimeInNanoseconds: nowNs
            )
            self.streamSink.stream.notifyScheduledOutputChanged(scheduled)

            // Cache the underlying image + format so we can re-emit
            // it during a source swap when the sink temporarily
            // dries up. Holding the CVPixelBuffer (not the parent
            // CMSampleBuffer) lets us mint fresh sample buffers
            // with current timestamps for each repeat.
            if let image = CMSampleBufferGetImageBuffer(sampleBuffer),
               let format = CMSampleBufferGetFormatDescription(sampleBuffer)
            {
                self.lastFrameImage = image
                self.lastFrameFormat = format
            }

            // Drop the frame on the floor if no AVCapture client is
            // currently watching the source. Saves the cost of
            // a `stream.send` that nobody would consume anyway.
            guard self.streamSource.streamingCounter > 0 else { return }

            let pts = sampleBuffer.presentationTimeStamp
            let ptsNs = UInt64(pts.seconds * Double(NSEC_PER_SEC))
            self.streamSource.stream.send(
                sampleBuffer,
                discontinuity: [],
                hostTimeInNanoseconds: ptsNs
            )
            self.lastSourceSendHostTimeNs = nowNs
            self.forwardedCount += 1
            if self.forwardedCount == 1 || self.forwardedCount % 60 == 0 {
                logger.info(
                    "Forwarded frame #\(self.forwardedCount, privacy: .public) to source"
                )
            }
        }
    }

    /// Re-emit the cached frame on a sink-empty tick when (a) someone
    /// is watching, (b) we have a frame to repeat, and (c) we haven't
    /// already sent one recently. The "recent" gate keeps the source's
    /// effective FPS pinned to ~30 even though the consume timer
    /// fires at 90 Hz.
    private func maybeEmitHeldFrame(nowNs: UInt64) {
        guard streamSource.streamingCounter > 0,
              let image = lastFrameImage,
              let format = lastFrameFormat
        else { return }
        if nowNs - lastSourceSendHostTimeNs < Self.heldFrameMinSpacingNs {
            return
        }
        guard let repeated = makeSampleBuffer(
            image: image,
            format: format,
            hostTimeNs: nowNs
        ) else { return }
        streamSource.stream.send(
            repeated,
            discontinuity: [],
            hostTimeInNanoseconds: nowNs
        )
        lastSourceSendHostTimeNs = nowNs
        heldFrameCount += 1
        if heldFrameCount == 1 || heldFrameCount % 30 == 0 {
            logger.info(
                "Held-last-frame emit #\(self.heldFrameCount, privacy: .public)"
            )
        }
    }

    private func makeSampleBuffer(
        image: CVPixelBuffer,
        format: CMFormatDescription,
        hostTimeNs: UInt64
    ) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(
                value: CMTimeValue(hostTimeNs),
                timescale: CMTimeScale(NSEC_PER_SEC)
            ),
            decodeTimeStamp: .invalid
        )
        var out: CMSampleBuffer?
        let status = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: image,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &out
        )
        if status != noErr {
            logger.error("makeSampleBuffer failed: \(status, privacy: .public)")
            return nil
        }
        return out
    }
}
