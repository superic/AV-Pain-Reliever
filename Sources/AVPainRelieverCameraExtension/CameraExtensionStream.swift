import Foundation
import CoreMediaIO
import CoreMedia
import AVPainRelieverSharedConstants
import os.log

private let logger = Logger(
    subsystem: "com.ericwillis.avpainreliever.CameraExtension",
    category: "Source"
)

/// The .source direction stream — what AVCapture clients (Zoom,
/// FaceTime, Slack, …) read from. Pure relay endpoint: frames are
/// pushed in by `CameraExtensionDeviceSource` after it consumes
/// them from the sibling sink stream. The host app writes frames
/// to the sink; the device source forwards each consumed frame
/// here via `stream.send(...)`.
final class CameraExtensionStreamSource: NSObject, CMIOExtensionStreamSource {
    /// Re-exports of the shared notification names so existing
    /// `Self.consumerActiveNotification` call sites in this file
    /// keep their current spellings. The canonical strings live in
    /// `AVPainRelieverSharedConstants`, which both this extension
    /// and the host's `VirtualCameraActivator` link statically —
    /// no hand-mirroring across the two binaries.
    static let consumerActiveNotification =
        CameraExtensionNotifications.consumerActive
    static let consumerInactiveNotification =
        CameraExtensionNotifications.consumerInactive
    static let queryConsumerStateNotification =
        CameraExtensionNotifications.queryConsumerState

    private(set) var stream: CMIOExtensionStream!
    private let streamFormat: CMIOExtensionStreamFormat
    weak var device: CameraExtensionDeviceSource?

    /// Number of currently-active CMIO clients reading this stream.
    /// `device` checks this before forwarding consumed frames so we
    /// don't waste cycles encoding when no one's watching.
    private(set) var streamingCounter: UInt32 = 0

    static let frameWidth: Int32 = 1280
    static let frameHeight: Int32 = 720
    static let frameDuration = CMTime(value: 1, timescale: 30)

    static func standardFormat() -> CMIOExtensionStreamFormat {
        var formatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: frameWidth,
            height: frameHeight,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        return CMIOExtensionStreamFormat(
            formatDescription: formatDescription!,
            maxFrameDuration: frameDuration,
            minFrameDuration: frameDuration,
            validFrameDurations: nil
        )
    }

    init(
        localizedName: String,
        streamID: UUID,
        streamFormat: CMIOExtensionStreamFormat
    ) {
        self.streamFormat = streamFormat
        super.init()
        self.stream = CMIOExtensionStream(
            localizedName: localizedName,
            streamID: streamID,
            direction: .source,
            clockType: .hostTime,
            source: self
        )
        registerQueryListener()
    }

    deinit {
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer
        )
    }

    /// Listen for the host's "what's the current state?" ping and
    /// respond by re-broadcasting the current consumer-active value.
    /// Lets a host that just registered observers seed its initial
    /// state without having to read a property cross-process.
    private func registerQueryListener() {
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let me = Unmanaged<CameraExtensionStreamSource>
                    .fromOpaque(observer)
                    .takeUnretainedValue()
                me.postCurrentState()
            },
            Self.queryConsumerStateNotification as CFString,
            nil,
            .deliverImmediately
        )
    }

    private func postCurrentState() {
        let name = streamingCounter > 0
            ? Self.consumerActiveNotification
            : Self.consumerInactiveNotification
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil, nil, true
        )
    }

    var formats: [CMIOExtensionStreamFormat] { [streamFormat] }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>)
        throws -> CMIOExtensionStreamProperties
    {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            p.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            p.frameDuration = Self.frameDuration
        }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties)
        throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws {
        let wasIdle = streamingCounter == 0
        streamingCounter += 1
        logger.info("source startStream — streamingCounter=\(self.streamingCounter, privacy: .public)")
        // Edge-trigger only: a 0→1 transition is the moment the host
        // needs to spin up its capture pipeline, and the moment our
        // own consume pump has to leave its idle cadence. Subsequent
        // clients joining a stream that's already live don't need to
        // wake anything up.
        if wasIdle {
            device?.sourceClientBecameActive()
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName(Self.consumerActiveNotification as CFString),
                nil, nil, true
            )
        }
    }

    func stopStream() throws {
        if streamingCounter > 0 { streamingCounter -= 1 }
        logger.info("source stopStream — streamingCounter=\(self.streamingCounter, privacy: .public)")
        if streamingCounter == 0 {
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName(Self.consumerInactiveNotification as CFString),
                nil, nil, true
            )
        }
    }
}
