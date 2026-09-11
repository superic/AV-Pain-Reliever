import Foundation

/// Darwin-notification name strings exchanged between the host app
/// (`VirtualCameraActivator`) and the embedded Camera Extension
/// (`CameraExtensionStreamSource`). The extension is a separate
/// sandboxed executable that doesn't link against the engine
/// library, so this small target sits underneath both and gets
/// statically linked into each.
///
/// Names are Team-ID-prefixed so the extension's sandbox lets it
/// post / observe them. Changing the prefix means rebuilding both
/// binaries — there is no schema-evolution path here, just a
/// hand-shake contract.
public enum CameraExtensionNotifications {
    /// Posted by the extension when an AVCapture client connects to
    /// the source stream. The host gates its real-camera capture
    /// pipeline on this signal so the macOS green camera light only
    /// turns on when something is actually reading frames.
    public static let consumerActive =
        "HLH4LEWS9S.com.ericwillis.avpainreliever.consumer-active"

    /// Posted by the extension after the last AVCapture client
    /// disconnects. The host treats this as "tear-down candidate"
    /// and runs a grace-window timer before actually stopping its
    /// pipeline (cheap re-arm for back-to-back calls).
    public static let consumerInactive =
        "HLH4LEWS9S.com.ericwillis.avpainreliever.consumer-inactive"

    /// Posted by the host when it (re)starts observing — the
    /// extension responds by re-broadcasting the current
    /// consumer-active value so a host that missed the most recent
    /// transition can seed its initial state.
    public static let queryConsumerState =
        "HLH4LEWS9S.com.ericwillis.avpainreliever.query-consumer-state"

    /// Posted by the host after it writes a new `NoSignalMode` into
    /// the shared App Group container. Carries no payload — Darwin
    /// notifications can't — so it means only "re-read the key".
    /// See `NoSignalSharedStore`.
    public static let noSignalModeChanged =
        "HLH4LEWS9S.com.ericwillis.avpainreliever.no-signal-mode-changed"
}
