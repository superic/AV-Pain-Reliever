import AVFoundation

/// Single source of truth for `AVCaptureDevice.DiscoverySession`
/// configuration shared across the engine's camera adapters.
///
/// `AVFoundationCameraController` (sets `userPreferredCamera` for
/// AVFoundation-modern apps) and `CameraCaptureSession` (the host
/// capture pipeline that feeds the virtual camera) both need to
/// enumerate the same device-type set. Centralising the list here
/// keeps them in lockstep when the supported camera kinds evolve
/// (e.g. when Apple adds another `AVCaptureDevice.DeviceType`).
///
/// The session is constructed fresh on every call — sessions are
/// cheap (microseconds) and we want fresh results when the user
/// docks a Continuity Camera mid-wizard.
///
/// Public so the app target shares the same list: the activator's
/// host-visibility check and the Settings live preview both look for
/// the virtual camera's UID in exactly this set of device types.
public enum CameraDiscovery {
    /// Includes every camera type that surfaces on macOS 14+:
    ///   - `builtInWideAngleCamera`: the Mac's own webcam
    ///   - `external`: USB / Thunderbolt cameras (LG UltraFine,
    ///     capture cards routed as cameras, etc.)
    ///   - `continuityCamera`: iPhone-as-webcam
    ///   - `deskViewCamera`: Apple's perspective-corrected
    ///     ultra-wide variant
    public static func session() -> AVCaptureDevice.DiscoverySession {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .external,
                .continuityCamera,
                .deskViewCamera,
            ],
            mediaType: .video,
            position: .unspecified
        )
    }
}
