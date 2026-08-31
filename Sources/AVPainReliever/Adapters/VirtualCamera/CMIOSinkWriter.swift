import Foundation
import CoreMediaIO
import CoreMedia
import CoreVideo
import VideoToolbox

/// Opens the AV Pain Reliever virtual camera as a CMIO consumer
/// and writes frames into its sink stream's `CMSimpleQueue`. The
/// kernel's CMIO subsystem passes those frames (including the
/// underlying IOSurfaces) through to the extension process — no
/// XPC, no sockets, no shared memory plumbing on our side.
///
/// Why raw CMIO instead of AVFoundation: AVFoundation only exposes
/// cameras as *inputs*. The sink stream we're writing to looks
/// like a camera to the system but accepts frames as if it were
/// an output device. The CMIO C API is the only public way to do
/// this writing today.
///
/// Mirrors the pattern OBS uses in its mac-virtualcam plugin
/// (referenced for architecture, not code).
public final class CMIOSinkWriter {
    private let deviceUID: String
    private let logger: ApplierLogger
    private var deviceID: CMIODeviceID = 0
    private var streamID: CMIOStreamID = 0
    private var queue: CMSimpleQueue?

    /// Format description used for the most recent enqueue,
    /// keyed by the underlying pixel buffer pointer. Re-derived
    /// when the buffer changes — VT-converted destination
    /// buffers carry source-derived color attachments that the
    /// strict CMSampleBuffer validator (-12743) rejects when a
    /// format description from one buffer is reused for another,
    /// even when dimensions + format are identical. M2's lesson:
    /// derive the format description from the SAME buffer you're
    /// wrapping. The pool recycles a small handful of buffers, so
    /// in steady state the cache hits 90%+ even with this strict
    /// keying.
    private var lastFormatBufferID: ObjectIdentifier?
    private var lastFormatDescription: CMFormatDescription?

    /// Convert + scale arbitrary input pixel buffers (any format,
    /// any dimensions — capture cards typically deliver YUV at
    /// 1080p) to the target 1280×720 BGRA. Hardware-accelerated
    /// where the GPU supports it. Created lazily on first enqueue
    /// so we don't pay the cost when the host isn't producing.
    private var transferSession: VTPixelTransferSession?

    /// Recycles the destination BGRA pixel buffers VT writes into.
    /// Pool size is left to CV defaults (small, refill as needed)
    /// — capture is steady-state at 30 fps so we'd retain at most
    /// a couple of buffers in flight.
    private var bufferPool: CVPixelBufferPool?

    /// Format + dimensions of the most recently logged host frame,
    /// or nil before the first frame. Used to log once per
    /// (format, dimensions) pair the host delivers, so a profile
    /// change shows up in the log without flooding with one line
    /// per frame.
    private struct InputSignature: Equatable {
        let format: OSType
        let width: Int
        let height: Int
    }
    private var lastLoggedInputSignature: InputSignature?

    /// Output target. The extension's source stream advertises
    /// 1280×720 BGRA; matching here avoids a format mismatch on
    /// AVCapture clients that read from the source.
    private static let outputWidth: Int = 1280
    private static let outputHeight: Int = 720
    private static let outputFormat: OSType = kCVPixelFormatType_32BGRA

    /// Log-rate-limit cadences. Heartbeat fires every Nth successful
    /// enqueue so the log shows the pipeline is alive without one
    /// line per frame; reject cadence fires every Nth rejected
    /// enqueue so a steady-state queue-full pattern is visible
    /// without flooding.
    private static let enqueueHeartbeatStride: UInt64 = 60
    private static let enqueueRejectStride: UInt64 = 30

    public init(deviceUID: String, logger: ApplierLogger) {
        self.deviceUID = deviceUID
        self.logger = logger
    }

    /// Discovers the device, opens its sink stream, primes the
    /// buffer queue, and starts streaming. Returns true on success.
    /// All failures log via the injected `ApplierLogger`; caller
    /// decides whether to retry.
    func start() -> Bool {
        guard let device = CMIODeviceCatalog.deviceID(forUID: deviceUID) else {
            logger.error("CMIO device with UID \(self.deviceUID) not found")
            return false
        }
        deviceID = device
        logger.info("Found device id=\(device)")

        guard let sink = findSinkStream(deviceID: device) else {
            logger.error("sink stream not found on device")
            return false
        }
        streamID = sink
        logger.info("Picked sink stream id=\(sink)")

        var unmanaged: Unmanaged<CMSimpleQueue>?
        let copyStatus = CMIOStreamCopyBufferQueue(sink, { _, _, _ in }, nil, &unmanaged)
        guard copyStatus == noErr, let unmanaged else {
            logger.error("CMIOStreamCopyBufferQueue failed: \(copyStatus)")
            return false
        }
        self.queue = unmanaged.takeRetainedValue()

        let startStatus = CMIODeviceStartStream(device, sink)
        guard startStatus == noErr else {
            logger.error("CMIODeviceStartStream failed: \(startStatus)")
            return false
        }

        logger.info("CMIOSinkWriter started successfully")
        return true
    }

    func stop() {
        if deviceID != 0 && streamID != 0 {
            CMIODeviceStopStream(deviceID, streamID)
        }
        deviceID = 0
        streamID = 0
        queue = nil
        transferSession = nil
        bufferPool = nil
        lastFormatBufferID = nil
        lastFormatDescription = nil
        lastLoggedInputSignature = nil
    }

    private var enqueueCount: UInt64 = 0
    private var enqueueRejectCount: UInt64 = 0

    /// Wraps an incoming pixel buffer in a CMSampleBuffer and
    /// enqueues it. Caller owns the pixel buffer; this method does
    /// NOT retain it long-term — `CMSampleBufferCreateForImageBuffer`
    /// retains internally.
    func enqueue(pixelBuffer: CVPixelBuffer, hostTimeNs: UInt64) {
        guard let queue else {
            if enqueueCount == 0 {
                logger.error("enqueue called before queue ready — dropping")
            }
            return
        }

        logIncomingFormatIfChanged(pixelBuffer: pixelBuffer)

        guard let convertedBuffer = convertToOutputBuffer(input: pixelBuffer)
        else { return }

        guard let formatDescription = ensureOutputFormatDescription(for: convertedBuffer)
        else { return }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(
                value: CMTimeValue(hostTimeNs),
                timescale: CMTimeScale(NSEC_PER_SEC)
            ),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: convertedBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            logger.error("CMSampleBufferCreateForImageBuffer failed: \(status)")
            return
        }

        // CMSimpleQueue takes ownership of the enqueued ref. Pass
        // a retained pointer so the queue can release after the
        // consumer takes it.
        let retained = Unmanaged.passRetained(sampleBuffer).toOpaque()
        let enqueueStatus = CMSimpleQueueEnqueue(queue, element: retained)
        if enqueueStatus != noErr {
            // Queue full or otherwise rejected. Reclaim the retain
            // we just gave it so the buffer doesn't leak.
            Unmanaged<CMSampleBuffer>.fromOpaque(retained).release()
            enqueueRejectCount += 1
            if enqueueRejectCount % Self.enqueueRejectStride == 1 {
                logger.error(
                    "CMSimpleQueueEnqueue rejected (rejects=\(self.enqueueRejectCount)/\(self.enqueueCount), status=\(enqueueStatus))"
                )
            }
            return
        }

        enqueueCount += 1
        if enqueueCount == 1 || enqueueCount % Self.enqueueHeartbeatStride == 0 {
            logger.info(
                "Enqueued frame #\(self.enqueueCount) (rejects=\(self.enqueueRejectCount))"
            )
        }
    }

    // MARK: - CMIO discovery

    private func findSinkStream(deviceID: CMIODeviceID) -> CMIOStreamID? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        guard
            CMIOObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
                == noErr,
            dataSize > 0
        else { return nil }

        let count = Int(dataSize) / MemoryLayout<CMIOStreamID>.size
        var streams = [CMIOStreamID](repeating: 0, count: count)
        var dataUsed: UInt32 = 0
        guard
            CMIOObjectGetPropertyData(
                deviceID, &address, 0, nil,
                dataSize, &dataUsed, &streams
            ) == noErr
        else { return nil }

        logger.info("Device exposes \(count) stream(s): \(streams.map(String.init).joined(separator: ", "))")

        // Don't trust ordering — query each stream's direction
        // property and return the first sink. CMIO assigns IDs in
        // its own order which may not match the order
        // CameraExtensionDeviceSource.init added them.
        for stream in streams {
            if let direction = streamDirection(streamID: stream) {
                logger.info("Stream \(stream) direction=\(direction)")
                // direction 0 = output (host → device, i.e. sink)
                // direction 1 = input  (device → host, i.e. source)
                if direction == 0 {
                    return stream
                }
            }
        }
        return nil
    }

    /// Returns a format description derived from the supplied
    /// pixel buffer. Cached against the buffer's pointer because
    /// the pool recycles a small handful of IOSurface-backed
    /// buffers — same pointer → same attachments → cache hit.
    /// New pointer → rebuild, because VT-attached colorspace
    /// metadata differs per source frame.
    private func ensureOutputFormatDescription(for pixelBuffer: CVPixelBuffer)
        -> CMFormatDescription?
    {
        let id = ObjectIdentifier(pixelBuffer)
        if let cached = lastFormatDescription,
           lastFormatBufferID == id
        {
            return cached
        }
        var fmt: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &fmt
        )
        guard status == noErr, let fmt else {
            logger.error("CMVideoFormatDescriptionCreateForImageBuffer failed: \(status)")
            return nil
        }
        lastFormatBufferID = id
        lastFormatDescription = fmt
        return fmt
    }

    /// Convert + scale `input` into a freshly-pooled 1280×720 BGRA
    /// pixel buffer. Returns the input as-is when it already
    /// matches the target format AND dimensions, so built-in
    /// cameras that natively deliver 1280×720 BGRA stay on the
    /// zero-copy fast path. USB capture cards (HDMI to U3 capture
    /// is the user's known case) deliver 1080p YUV422 — those
    /// flow through `VTPixelTransferSessionTransferImage` for
    /// hardware-accelerated downscale + colorspace conversion.
    private func convertToOutputBuffer(input: CVPixelBuffer) -> CVPixelBuffer? {
        let inputWidth = CVPixelBufferGetWidth(input)
        let inputHeight = CVPixelBufferGetHeight(input)
        let inputFormat = CVPixelBufferGetPixelFormatType(input)
        if inputFormat == Self.outputFormat
            && inputWidth == Self.outputWidth
            && inputHeight == Self.outputHeight
        {
            return input
        }

        guard let session = ensureTransferSession(),
              let pool = ensureBufferPool()
        else { return nil }

        var destination: CVPixelBuffer?
        let createStatus = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault, pool, &destination
        )
        guard createStatus == kCVReturnSuccess, let destination else {
            logger.error(
                "CVPixelBufferPoolCreatePixelBuffer failed: \(createStatus)"
            )
            return nil
        }

        let xferStatus = VTPixelTransferSessionTransferImage(
            session,
            from: input,
            to: destination
        )
        guard xferStatus == noErr else {
            logger.error(
                "VTPixelTransferSessionTransferImage failed: \(xferStatus)"
            )
            return nil
        }
        return destination
    }

    private func ensureTransferSession() -> VTPixelTransferSession? {
        if let transferSession { return transferSession }
        var session: VTPixelTransferSession?
        let status = VTPixelTransferSessionCreate(
            allocator: kCFAllocatorDefault,
            pixelTransferSessionOut: &session
        )
        guard status == noErr, let session else {
            logger.error("VTPixelTransferSessionCreate failed: \(status)")
            return nil
        }
        // High-quality scaling — hardware path on Apple Silicon,
        // worth the negligible cost on Intel too. The session
        // reads the source/destination buffer attributes to pick
        // an internal pixel-transfer pipeline; no further config
        // needed for our 30-fps single-stream use case.
        VTSessionSetProperty(
            session,
            key: kVTPixelTransferPropertyKey_ScalingMode,
            value: kVTScalingMode_Letterbox
        )
        transferSession = session
        return session
    }

    private func ensureBufferPool() -> CVPixelBufferPool? {
        if let bufferPool { return bufferPool }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Self.outputFormat,
            kCVPixelBufferWidthKey as String: Self.outputWidth,
            kCVPixelBufferHeightKey as String: Self.outputHeight,
            // IOSurface-backed so the buffer can be marshalled
            // across the host → extension process boundary by
            // CMIO without an extra copy.
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            nil,
            attrs as CFDictionary,
            &pool
        )
        guard status == kCVReturnSuccess, let pool else {
            logger.error("CVPixelBufferPoolCreate failed: \(status)")
            return nil
        }
        bufferPool = pool
        return pool
    }

    private func logIncomingFormatIfChanged(pixelBuffer: CVPixelBuffer) {
        let signature = InputSignature(
            format: CVPixelBufferGetPixelFormatType(pixelBuffer),
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        if signature == lastLoggedInputSignature { return }
        lastLoggedInputSignature = signature
        let fourcc = FourCC.pretty(signature.format)
        let needsConversion = signature.format != Self.outputFormat
            || signature.width != Self.outputWidth
            || signature.height != Self.outputHeight
        logger.info(
            "Host frame format: \(fourcc) \(signature.width)x\(signature.height) — \(needsConversion ? "convert+scale" : "passthrough")"
        )
    }

    private func streamDirection(streamID: CMIOStreamID) -> UInt32? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOStreamPropertyDirection),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var direction: UInt32 = 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        var used: UInt32 = 0
        let status = CMIOObjectGetPropertyData(
            streamID, &address, 0, nil, size, &used, &direction
        )
        return status == noErr ? direction : nil
    }
}
