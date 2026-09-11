import Foundation

/// What the virtual camera shows when no frames are arriving from the
/// real camera.
///
/// The extension caches the last frame it received and re-emits it on
/// dry ticks so a profile swap doesn't freeze or drop a call. That
/// hold is correct for the ~500 ms swap window it was built for, and
/// wrong past it: a camera that never starts delivering — a physical
/// power switch still off at the top of a call — used to leave the
/// last frame of a *previous* session on screen indefinitely.
///
/// Past `NoSignalPolicy.holdWindowNs` the extension stops holding and
/// emits one of these instead.
public enum NoSignalMode: String, CaseIterable, Sendable {
    /// Solid black. The default: on a live call it reads as "camera
    /// isn't on yet", which is exactly what happened, and it puts no
    /// novelty graphic on a colleague's screen.
    case black

    /// SMPTE-style colour bars. Unmistakably deliberate, so it
    /// distinguishes "the app is showing you a placeholder" from "the
    /// app is stuck" — useful when diagnosing a dead source.
    case testPattern

    /// Analogue-style noise. Animated, because frozen noise reads as
    /// a corrupted still rather than as snow.
    case staticNoise

    /// Falls back here whenever nothing is persisted or a stored
    /// string doesn't parse. Being both the default and the fallback
    /// is deliberate: an extension that can't read the setting
    /// degrades to the quietest option rather than a surprising one.
    public static let fallback: NoSignalMode = .black
}

/// When the extension holds the last frame, when it swaps to a
/// placeholder, and when it sends nothing at all.
///
/// Split out as a pure function so the matrix is testable without a
/// CMIO stack, following the precedent set by
/// `VirtualCameraActivator.autoRelaunchDecision`.
public enum NoSignalDecision: String, Equatable, Sendable {
    /// Re-emit the cached frame. Covers the input-swap window.
    case holdLastFrame

    /// Emit the configured `NoSignalMode` frame.
    case placeholder

    /// Emit nothing — nobody is reading the source stream.
    case idle
}

public enum NoSignalPolicy {
    /// How long the extension keeps re-emitting a cached frame after
    /// the sink goes dry, before giving up and showing a placeholder.
    ///
    /// `CameraCaptureSession`'s input swap is documented at ~500 ms;
    /// this is 4× that. The margin is deliberately generous and
    /// asymmetric in cost: overshooting means a slow-warming capture
    /// card holds a good frame a little longer, while undershooting
    /// means a placeholder flashes mid-call every time the user walks
    /// between locations. The first is invisible, the second is a bug
    /// report.
    ///
    /// This window is *not* what protects against a stale frame from
    /// an earlier call — that's the invalidation on consumer attach
    /// (see `decide`'s `hasHeldFrame`). By the time a new client is
    /// reading the source there is no held frame to serve, so the
    /// window never gets the chance to leak one across a session
    /// boundary.
    public static let holdWindowNs: UInt64 = 2_000_000_000

    /// - Parameters:
    ///   - hasWatchers: whether any AVCapture client is reading the
    ///     source stream right now.
    ///   - hasHeldFrame: whether a cached frame from *this* consumer
    ///     session exists. The extension drops the cache when the sink
    ///     stops, and when a consumer attaches to a sink that isn't
    ///     currently delivering — so this is false at the top of every
    ///     call, while a second client joining a stream already
    ///     carrying live video doesn't cost the first one a frame.
    ///   - dryDurationNs: nanoseconds since the last live frame
    ///     arrived from the sink.
    public static func decide(
        hasWatchers: Bool,
        hasHeldFrame: Bool,
        dryDurationNs: UInt64
    ) -> NoSignalDecision {
        guard hasWatchers else { return .idle }
        guard hasHeldFrame else { return .placeholder }
        return dryDurationNs < holdWindowNs ? .holdLastFrame : .placeholder
    }
}

/// The one piece of configuration that crosses the process boundary.
///
/// Darwin notifications carry no payload, so the value itself rides in
/// the App Group defaults container both binaries are entitled to, and
/// a notification only tells the extension to re-read. The host writes;
/// the extension reads.
public enum NoSignalSharedStore {
    /// Matches `com.apple.security.application-groups` in both
    /// entitlements files. Team-ID-prefixed because the sandbox
    /// requires it.
    public static let appGroupSuiteName =
        "HLH4LEWS9S.group.com.ericwillis.avpainreliever"

    /// Spelled out rather than derived, so `defaults read` on the
    /// container is self-explanatory in a support log.
    public static let modeKey = "noSignalMode"

    /// The shared container.
    ///
    /// Returns nil only for the two suite names `UserDefaults` refuses
    /// outright (the bundle identifier and the global domain), so in
    /// practice this is never nil here — it does NOT report whether
    /// this process actually holds the App Group entitlement. Don't
    /// read a nil check as a guard against an unentitled process.
    ///
    /// The real failure mode is silent and worth knowing about: an
    /// unentitled process (an unsigned local build, most likely) gets
    /// a private per-process domain under the same name instead of the
    /// group container. Host and extension then read and write
    /// different stores, so the picker appears to do nothing and no
    /// error is raised anywhere. A signed build with the entitlement
    /// — which both `.entitlements` files declare — resolves the
    /// shared container correctly.
    public static func sharedDefaults() -> UserDefaults? {
        UserDefaults(suiteName: appGroupSuiteName)
    }

    /// Reads the mode the host last published, falling back to
    /// `NoSignalMode.fallback` for a missing key, an unparsable
    /// string, or (unreachably in practice — see `sharedDefaults()`) a
    /// nil container.
    ///
    /// Uses `object(forKey:)` rather than `string(forKey:)` so a
    /// missing key and a stored value stay distinguishable, and never
    /// writes — the extension is a pure reader of this key, and the
    /// host owns the lazy-default rule on its own side.
    public static func readMode(
        from defaults: UserDefaults? = sharedDefaults()
    ) -> NoSignalMode {
        guard
            let raw = defaults?.object(forKey: modeKey) as? String,
            let mode = NoSignalMode(rawValue: raw)
        else { return .fallback }
        return mode
    }

    /// Publishes the mode for the extension to pick up. Host-side only.
    public static func writeMode(
        _ mode: NoSignalMode,
        to defaults: UserDefaults? = sharedDefaults()
    ) {
        defaults?.set(mode.rawValue, forKey: modeKey)
    }
}
