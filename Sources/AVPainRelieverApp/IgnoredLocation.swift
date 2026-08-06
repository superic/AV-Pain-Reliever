import Foundation
import AVPainReliever

/// A dismissed "new location" suggestion. Persisted in `SettingsStore`
/// under `ignoredLocations` so the engine stops surfacing the same
/// fingerprint after the user marks it as not-a-real-location.
///
/// Keyed by the canonical fingerprint string of the attached USB set
/// (see `LocationFingerprint.canonical`), filtered to location-signal
/// devices — transient plug-ins (flash drives, phones) are excluded
/// before keying, so "dock" and "dock + USB stick" dismiss as one
/// location. Entries persisted before that filtering existed may
/// carry full-set keys; `handleUnknownLocation` checks both.
/// `devices` is display-only — it carries the names captured at
/// dismiss time so the Settings → Profiles "Ignored locations" list
/// can render "iPhone" instead of raw vid:pid hex.
struct IgnoredLocation: Codable, Hashable, Identifiable {
    /// Canonical fingerprint string for the attached device set.
    /// Stable across launches: same devices in the same combination
    /// produce the same key.
    let key: String

    /// The devices that made up the dismissed location. Display-only;
    /// matching uses `key`.
    let devices: [Device]

    /// When the user dismissed the location. Surfaced in the Settings
    /// list as relative-time ("2h ago") to help the user remember
    /// which one they intended to un-ignore.
    let dismissedAt: Date

    var id: String { key }

    struct Device: Codable, Hashable {
        let vendorID: Int
        let productID: Int
        let serialNumber: String?
        /// USB Product Name as IOKit reported it. May be nil for
        /// devices that don't expose one (cheap hubs, multi-function
        /// device legs).
        let name: String?
        /// USB Vendor Name as IOKit reported it. Same nil semantics.
        let vendorName: String?

        /// Defers to `NamedUSBDevice.formatDisplayName` so the
        /// Settings → Profiles "Ignored Locations" list and the
        /// wizard's device picker render names identically for the
        /// same `(vendorName, name)` pair. (none, none) falls back
        /// to `"(unnamed device)"` — capturing devices via the
        /// transient watcher at dismiss time means we almost always
        /// have at least a vendor name.
        var displayName: String {
            NamedUSBDevice.formatDisplayName(vendorName: vendorName, name: name)
        }
    }
}

/// Canonical string fingerprint for an attached device set. The same
/// `Set<USBDevice>` always produces the same string regardless of
/// enumeration order; two different sets always produce different
/// strings.
///
/// Format: pipe-joined `vid:pid[/serial]` entries, sorted by
/// `(vid, pid, serial ?? "")`. Hex is lowercase 4-char so a casual
/// `defaults read` is human-readable.
enum LocationFingerprint {
    static func canonical(for devices: Set<USBDevice>) -> String {
        let sorted = devices.sorted { lhs, rhs in
            if lhs.vendorID != rhs.vendorID { return lhs.vendorID < rhs.vendorID }
            if lhs.productID != rhs.productID { return lhs.productID < rhs.productID }
            return (lhs.serialNumber ?? "") < (rhs.serialNumber ?? "")
        }
        return sorted.map { device in
            let base = String(format: "%04x:%04x", device.vendorID, device.productID)
            if let serial = device.serialNumber, !serial.isEmpty {
                return "\(base)/\(serial)"
            }
            return base
        }.joined(separator: "|")
    }
}
