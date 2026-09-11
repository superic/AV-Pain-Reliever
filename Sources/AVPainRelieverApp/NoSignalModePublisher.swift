import Foundation
import AVPainRelieverSharedConstants

/// Closure shape for mirroring a `NoSignalMode` change out of this
/// process. `SettingsStore` injects this the same way it injects
/// `LoginItemApplier` for `launchAtLogin`: production passes
/// `NoSignalModePublisher.publish`; tests pass a no-op (or a spy)
/// so `swift test` never writes into the real App Group container or
/// pings a Camera Extension that happens to be running on the
/// developer's machine.
typealias NoSignalModePublishing = (NoSignalMode) -> Void

/// Mirrors `SettingsStore.noSignalMode` into the App Group container
/// and tells the Camera Extension to re-read it.
///
/// The extension is a separate sandboxed process — it can't see
/// `UserDefaults.standard` — so the value has to cross via the shared
/// App Group container, and Darwin notifications carry no payload, so
/// a notification only ever means "go read the key again." Split out
/// as its own type rather than growing `VirtualCameraActivator`,
/// which owns the extension's activation lifecycle, not this
/// unrelated settings hand-off.
enum NoSignalModePublisher {
    /// Write `mode` into the shared container and post
    /// `CameraExtensionNotifications.noSignalModeChanged`. Call this
    /// on every change AND once at host startup — an extension that
    /// launches after a setting change (or before the host has ever
    /// run) otherwise reads a stale or default value out of the
    /// container.
    static func publish(_ mode: NoSignalMode) {
        NoSignalSharedStore.writeMode(mode)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(CameraExtensionNotifications.noSignalModeChanged as CFString),
            nil, nil, true
        )
    }
}
