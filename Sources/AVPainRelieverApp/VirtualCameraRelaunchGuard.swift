import Foundation

/// One-shot latch for the automatic host relaunch that recovers a
/// stale per-process CMIO context (issue #120).
///
/// The relaunch has to survive the thing it triggers — the process
/// disappears — so the latch lives in `UserDefaults` rather than in
/// `VirtualCameraActivator`. Semantics:
///
/// - `canRelaunch` is true on a fresh install and after any
///   confirmed visibility. That's the state where one automatic
///   relaunch is worth spending.
/// - `markRelaunched()` is written *before* the relaunch, so the
///   process that comes back up knows it already got its retry. If
///   its own poll + re-check still can't see the camera, the
///   activator leaves the manual recovery advice standing instead of
///   relaunching again — no quit/launch loop.
/// - `clearRelaunchMarker()` runs the moment the host confirms it can
///   see the camera, in whichever process gets there. A later,
///   unrelated stale-context episode then gets its own single retry.
///
/// **The invariant every clear point has to keep:** the latch may only
/// be given back by something *outside* the failing loop — a confirmed
/// sighting of the camera, or a deliberate user action. Today that
/// means two call sites: `noteVisibilityConfirmed()` and `disable()`
/// (the user turned the feature off, which ends the episode as
/// decisively as a sighting and can't recur without them turning it
/// back on). Clearing on anything the broken path reaches by itself —
/// a failed re-check, an escalation declining — would let two
/// processes hand the latch back and forth and quit each other
/// forever. `relaunchForStaleDiscovery`'s own abandon/failure paths
/// are the one exception, and they're safe because no relaunch
/// happened in them: the process is still alive and has stood its
/// re-check down.
///
/// Not part of `SettingsStore`: this isn't a user preference, it's
/// crash-and-relaunch bookkeeping, and the activator shouldn't need a
/// settings reference to do it. Reads never write (missing key →
/// `bool(forKey:)` is false), matching the store's lazy-default rule.
struct VirtualCameraRelaunchGuard {
    /// Key is spelled out in full so a support log or `defaults read`
    /// makes it obvious what tripped.
    static let markerKey = "virtualCameraRelaunchedForStaleDiscovery"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// True while an automatic relaunch is still available to spend.
    var canRelaunch: Bool {
        !defaults.bool(forKey: Self.markerKey)
    }

    func markRelaunched() {
        defaults.set(true, forKey: Self.markerKey)
    }

    /// Drop the latch. No-op (and no disk write) when it isn't set,
    /// which is the case on nearly every launch — visibility gets
    /// confirmed a second or two into a normal cold start.
    func clearRelaunchMarker() {
        guard defaults.object(forKey: Self.markerKey) != nil else { return }
        defaults.removeObject(forKey: Self.markerKey)
    }
}
