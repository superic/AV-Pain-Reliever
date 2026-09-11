import Foundation
import CoreMediaIO
import CoreMedia
import IOKit.audio
import AVPainRelieverSharedConstants
import os.log

private let logger = Logger(
    subsystem: "com.ericwillis.avpainreliever.CameraExtension",
    category: "Device"
)

/// A pixel buffer and the `CMFormatDescription` derived from *that*
/// buffer. The two always travel together because the strict
/// `CMSampleBufferCreateForImageBuffer` validator rejects a description
/// minted from a different buffer with -12743, even when dimensions and
/// pixel format match. Whatever the source stream sends — a frame
/// consumed from the sink, or a placeholder from `NoSignalFrameSource`
/// — arrives as one of these.
typealias SourceFrame = (image: CVPixelBuffer, format: CMFormatDescription)

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
/// That loop is a timer, and it runs whenever there is *either* a
/// host writing to the sink or an AVCapture client reading the
/// source — the two are independent, and the pump has work to do
/// under either one alone. With a sink attached each tick drains it;
/// without one, each tick goes straight to the dry path, which is
/// what keeps a placeholder flowing to a client whose host has torn
/// its capture pipeline down. With neither, the timer is cancelled
/// outright.
///
/// Some clients (Zoom) hold the sink open for their entire process
/// lifetime, call or no call, so the pump also has two cadences: the
/// full 90 Hz drain whenever anything is happening, and a slow idle
/// tick once the source has no clients *and* the sink has been dry
/// for a few seconds. It jumps back to full rate the instant a frame
/// arrives or an AVCapture client attaches.
///
/// On a tick where the sink yields nothing, what the source emits is
/// `NoSignalPolicy`'s call: the cached frame while the dry spell is
/// still inside `holdWindowNs`, the configured `NoSignalMode`
/// placeholder once it isn't (or when there is no cached frame at
/// all), and nothing whatsoever when no client is watching. Either
/// way the send is spaced to the declared 30 fps, so one tick in
/// three actually emits.
///
/// **Threading.** `consumeQueue` owns every mutable field below, and
/// is the only place frames are emitted or `noSignalFrames` is
/// touched. CMIO delivers the `consumeSampleBuffer` completion on a
/// queue of its own, so that completion's first act is to hop back
/// here; everything arriving from a Darwin notification or from a
/// stream callback hops the same way. Nothing is read or written
/// across threads, which is why none of this needs a lock — and the
/// client counts the pump reads are mirrored into `hasSourceWatchers`
/// on those hops rather than reached for on the stream object.
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
    private var pumpIsIdle = false

    /// The host client currently writing to the sink, or nil when no
    /// host is. Doubles as the pump's "is there a sink to drain?"
    /// flag: a tick with no client goes straight to the dry path.
    private var sinkClient: CMIOExtensionClient?

    /// Whether an AVCapture client is reading the source stream.
    /// Mirrors `CameraExtensionStreamSource.streamingCounter`'s 0↔1
    /// edges onto `consumeQueue` (see `sourceClientBecameActive` /
    /// `sourceClientBecameInactive`) so the pump reads a field it owns
    /// rather than a counter another thread is mutating.
    private var hasSourceWatchers = false

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

        registerNoSignalModeListener()
    }

    deinit {
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer
        )
    }

    /// The host writes the picked mode into the shared App Group
    /// container and posts a payload-free Darwin notification; we
    /// re-read the key. Same shape as
    /// `CameraExtensionStreamSource.registerQueryListener()`.
    private func registerNoSignalModeListener() {
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let me = Unmanaged<CameraExtensionDeviceSource>
                    .fromOpaque(observer)
                    .takeUnretainedValue()
                me.reloadNoSignalMode()
            },
            CameraExtensionNotifications.noSignalModeChanged as CFString,
            nil,
            .deliverImmediately
        )
    }

    /// Hops to `consumeQueue` because `noSignalFrames` is owned by the
    /// consume path — the notification lands on some other thread.
    private func reloadNoSignalMode() {
        let mode = NoSignalSharedStore.readMode()
        consumeQueue.async { [weak self] in
            self?.noSignalFrames.setMode(mode)
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
    /// host starts pushing frames to the sink. Adopts the client and
    /// makes sure the pump is running at full rate, so the ticks that
    /// were emitting placeholders (or weren't running at all) start
    /// draining the sink instead.
    func sinkStartedStreaming(client: CMIOExtensionClient) {
        logger.info("sinkStartedStreaming")
        consumeQueue.async { [weak self] in
            guard let self else { return }
            self.sinkClient = client
            self.startPump()
        }
    }

    /// The host has torn its capture pipeline down. That is *not* the
    /// end of the pump: an AVCapture client can still be holding the
    /// source open, and leaving it with the last real frame of the
    /// user frozen on screen is the exact failure the placeholder
    /// exists to prevent. So the cached frame goes, the sink client
    /// goes, and the tick keeps running on dry ticks alone until the
    /// last watcher leaves too.
    func sinkStoppedStreaming() {
        logger.info("sinkStoppedStreaming")
        consumeQueue.async { [weak self] in
            guard let self else { return }
            self.sinkClient = nil
            // Whatever the host last sent is now an image of a session
            // that's over. See `heldFrame`.
            self.heldFrame = nil
            self.stopPumpIfUnused()
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
    /// no matter how dry the sink is, because the dry-tick emits it
    /// depends on — held frame or placeholder — ride on these same
    /// ticks. With no client there is nothing to emit either way, so
    /// the placeholder never holds the pump up.
    private static func shouldRunIdle(
        hasWatchers: Bool,
        consecutiveEmptyConsumes: UInt64
    ) -> Bool {
        !hasWatchers
            && consecutiveEmptyConsumes >= idleDownshiftAfterEmpties
    }

    /// Get the pump running at the active cadence, starting the timer
    /// if it isn't already. Must be called on `consumeQueue`.
    ///
    /// The tick reads `sinkClient` rather than closing over one, so a
    /// pump started by a watching client keeps running unchanged when
    /// a host later attaches to the sink, and vice versa.
    private func startPump() {
        guard consumeTimer == nil else {
            setPumpIdle(false)
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: consumeQueue)
        pumpIsIdle = false
        consecutiveEmptyConsumes = 0
        schedule(timer, idle: false)
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        consumeTimer = timer
        timer.resume()
    }

    /// Stop the pump once nothing is left for it to do — no host
    /// writing to the sink and nobody reading the source. Must be
    /// called on `consumeQueue`.
    private func stopPumpIfUnused() {
        guard sinkClient == nil, !hasSourceWatchers else { return }
        consumeTimer?.cancel()
        consumeTimer = nil
    }

    /// One pump tick. Drains the sink when a host is writing to it;
    /// otherwise there is nothing to drain and the dry path — hold or
    /// placeholder — runs directly.
    private func tick() {
        if let sinkClient {
            consumeOne(client: sinkClient)
        } else {
            dryTick(nowNs: Self.hostTimeNs())
        }
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
    /// client edge. Someone is about to watch, so the pump needs to be
    /// running and at full rate before the first frame is expected —
    /// including when no host is writing to the sink at all, in which
    /// case these ticks are the only thing standing between the client
    /// and a black hole.
    ///
    /// It's also where the held frame dies. A client that just
    /// attached must never be shown a frame that was cached before it
    /// attached: the extension process outlives any one call, so
    /// without this, the first seconds of a new call can broadcast an
    /// image captured in an earlier one.
    ///
    /// That only applies to a frame nobody is refreshing, though. When
    /// the sink is still delivering — a second client attaching to a
    /// live stream, say, or the Settings preview reopening inside the
    /// host's stop grace — the cache is a few milliseconds old and
    /// about to be overwritten by the next live frame anyway, and
    /// dropping it opens a window where a dry tick landing between two
    /// live frames would punch a single placeholder frame into
    /// otherwise-live video. So the cache survives exactly as long as
    /// the sink is demonstrably still feeding it.
    func sourceClientBecameActive() {
        consumeQueue.async { [weak self] in
            guard let self else { return }
            self.hasSourceWatchers = true
            self.startPump()
            let sinkIsDelivering = self.sinkClient != nil
                && Self.hostTimeNs() - self.lastLiveFrameHostTimeNs
                    < Self.liveSinkGraceNs
            if !sinkIsDelivering { self.heldFrame = nil }
        }
    }

    /// Called by `CameraExtensionStreamSource.stopStream` on the 1→0
    /// client edge. With nobody watching there is nothing to emit, so
    /// the pump can stop entirely unless the host is still writing to
    /// the sink.
    func sourceClientBecameInactive() {
        consumeQueue.async { [weak self] in
            guard let self else { return }
            self.hasSourceWatchers = false
            self.stopPumpIfUnused()
        }
    }

    private var consumedCount: UInt64 = 0
    private var forwardedCount: UInt64 = 0
    private var emptyConsumeCount: UInt64 = 0
    private var consecutiveEmptyConsumes: UInt64 = 0
    private var heldFrameCount: UInt64 = 0
    private var placeholderFrameCount: UInt64 = 0

    /// Image + format of the most recent frame received from the host,
    /// cached together because they're only ever used together.
    /// Re-emitted when the sink yields nothing, which keeps the source
    /// flowing during the ~500 ms input-swap window inside
    /// `CameraCaptureSession` — without it, AVCapture clients (Zoom)
    /// see the call freeze or drop while the new camera warms up.
    ///
    /// Bounded in two directions, because an unbounded hold broadcasts
    /// a stale picture of the user: `NoSignalPolicy.holdWindowNs` caps
    /// how long a dry spell keeps re-emitting it, and it is dropped
    /// outright when the sink stops (see `sinkStoppedStreaming`) and
    /// when a consumer attaches to a sink that isn't currently
    /// delivering (see `sourceClientBecameActive`).
    private var heldFrame: SourceFrame?

    /// Host time of the most recent *live* frame consumed from the
    /// sink. Distinct from `lastSourceSendHostTimeNs`, which also
    /// advances on held and placeholder sends: the dry duration has to
    /// measure the silence from the host, and anything we emit
    /// ourselves must not reset it.
    private var lastLiveFrameHostTimeNs: UInt64 = 0

    /// Host time of the most recent frame we sent through the source
    /// stream — fresh, held or placeholder. Used to rate-limit dry-tick
    /// emissions to roughly the source's declared frame duration.
    private var lastSourceSendHostTimeNs: UInt64 = 0

    /// Minimum spacing between dry-tick emissions. Matches the
    /// source's declared 30 fps so AVCapture clients see a steady
    /// cadence rather than a 90 Hz burst (the consume timer ticks at
    /// 3× framerate, but only one in three should re-emit).
    private static let heldFrameMinSpacingNs: UInt64 =
        UInt64(1_000_000_000.0 / 30.0)

    /// How recently a live frame must have arrived for the sink to
    /// count as still delivering when a consumer attaches. Two frame
    /// intervals — long enough to ride out ordinary 30 fps jitter,
    /// far short of any gap that could span two sessions. See
    /// `sourceClientBecameActive`.
    private static let liveSinkGraceNs: UInt64 = heldFrameMinSpacingNs * 2

    /// Placeholder pixels. Seeded from the shared container at startup
    /// and re-read on the host's Darwin notification; touched only on
    /// `consumeQueue`.
    private let noSignalFrames = NoSignalFrameSource(
        mode: NoSignalSharedStore.readMode()
    )

    private static func hostTimeNs() -> UInt64 {
        UInt64(
            CMClockGetTime(CMClockGetHostTimeClock()).seconds
                * Double(NSEC_PER_SEC)
        )
    }

    private func consumeOne(client: CMIOExtensionClient) {
        streamSink.stream.consumeSampleBuffer(from: client) {
            [weak self] sampleBuffer, sequenceNumber, _, _, error in
            guard let self else { return }
            // CMIO calls this back on a queue of its own. Every field
            // the handler touches belongs to `consumeQueue`, so hop
            // before touching any of it.
            self.consumeQueue.async {
                self.handleConsumed(
                    sampleBuffer,
                    sequenceNumber: sequenceNumber,
                    error: error
                )
            }
        }
    }

    /// Everything a consume yields, handled on `consumeQueue`.
    private func handleConsumed(
        _ sampleBuffer: CMSampleBuffer?,
        sequenceNumber: UInt64,
        error: Error?
    ) {
        if let error {
            logger.error("consume error: \(error.localizedDescription, privacy: .public)")
            return
        }
        let nowNs = Self.hostTimeNs()

        guard let sampleBuffer else {
            emptyConsumeCount += 1
            if emptyConsumeCount % 90 == 1 {
                logger.debug(
                    "consume returned no buffer (\(self.emptyConsumeCount, privacy: .public) empty so far)"
                )
            }
            dryTick(nowNs: nowNs)
            return
        }

        consecutiveEmptyConsumes = 0
        setPumpIdle(false)
        consumedCount += 1
        if consumedCount == 1 || consumedCount % 60 == 0 {
            logger.info(
                "Consumed frame #\(self.consumedCount, privacy: .public), watched=\(self.hasSourceWatchers, privacy: .public)"
            )
        }

        // Tell the sink the frame moved through, so its
        // `streamSinkEndOfData` and underrun counters stay sane.
        let scheduled = CMIOExtensionScheduledOutput(
            sequenceNumber: sequenceNumber,
            hostTimeInNanoseconds: nowNs
        )
        streamSink.stream.notifyScheduledOutputChanged(scheduled)

        // Cache the underlying image + format so we can re-emit it
        // during a source swap when the sink temporarily dries up.
        // Holding the CVPixelBuffer (not the parent CMSampleBuffer)
        // lets us mint fresh sample buffers with current timestamps
        // for each repeat.
        if let image = CMSampleBufferGetImageBuffer(sampleBuffer),
           let format = CMSampleBufferGetFormatDescription(sampleBuffer)
        {
            heldFrame = (image, format)
            lastLiveFrameHostTimeNs = nowNs
        }

        // Drop the frame on the floor if no AVCapture client is
        // currently watching the source. Saves the cost of a
        // `stream.send` that nobody would consume anyway.
        guard hasSourceWatchers else { return }

        let ptsNs = UInt64(
            sampleBuffer.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)
        )
        streamSource.stream.send(
            sampleBuffer,
            discontinuity: [],
            hostTimeInNanoseconds: ptsNs
        )
        lastSourceSendHostTimeNs = nowNs
        forwardedCount += 1
        if forwardedCount == 1 || forwardedCount % 60 == 0 {
            logger.info(
                "Forwarded frame #\(self.forwardedCount, privacy: .public) to source"
            )
        }
    }

    /// A tick that produced no live frame — either the consume came
    /// back empty or there is no sink to consume from at all. Emits
    /// whatever `NoSignalPolicy` calls for and downshifts the cadence
    /// once the dry run is long enough and nobody is watching. Must be
    /// called on `consumeQueue`.
    private func dryTick(nowNs: UInt64) {
        consecutiveEmptyConsumes += 1
        maybeEmitDryTickFrame(nowNs: nowNs)
        if Self.shouldRunIdle(
            hasWatchers: hasSourceWatchers,
            consecutiveEmptyConsumes: consecutiveEmptyConsumes
        ) {
            setPumpIdle(true)
        }
    }

    /// Decide and send this dry tick's frame.
    ///
    /// The spacing gate governs *when* — it keeps the source's
    /// effective FPS pinned to ~30 even though the pump ticks at
    /// 90 Hz — and `NoSignalPolicy` governs *what*, so the held
    /// frame / placeholder / nothing matrix lives in one testable
    /// place shared with the host rather than in the pump.
    private func maybeEmitDryTickFrame(nowNs: UInt64) {
        guard nowNs - lastSourceSendHostTimeNs >= Self.heldFrameMinSpacingNs
        else { return }

        let decision = NoSignalPolicy.decide(
            hasWatchers: hasSourceWatchers,
            hasHeldFrame: heldFrame != nil,
            dryDurationNs: nowNs - lastLiveFrameHostTimeNs
        )
        let frame: SourceFrame?
        switch decision {
        case .idle:
            frame = nil
        case .holdLastFrame:
            frame = heldFrame
        case .placeholder:
            frame = noSignalFrames.nextFrame()
        }

        guard
            let frame,
            let repeated = makeSampleBuffer(
                image: frame.image,
                format: frame.format,
                hostTimeNs: nowNs
            )
        else { return }
        streamSource.stream.send(
            repeated,
            discontinuity: [],
            hostTimeInNanoseconds: nowNs
        )
        lastSourceSendHostTimeNs = nowNs

        if decision == .holdLastFrame {
            heldFrameCount += 1
            if heldFrameCount == 1 || heldFrameCount % 30 == 0 {
                logger.info(
                    "Held-last-frame emit #\(self.heldFrameCount, privacy: .public)"
                )
            }
        } else {
            placeholderFrameCount += 1
            if placeholderFrameCount == 1 || placeholderFrameCount % 30 == 0 {
                logger.info(
                    "No-signal placeholder emit #\(self.placeholderFrameCount, privacy: .public) mode=\(self.noSignalFrames.mode.rawValue, privacy: .public)"
                )
            }
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
