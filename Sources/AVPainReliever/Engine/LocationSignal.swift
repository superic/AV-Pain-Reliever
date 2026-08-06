import Foundation

/// Decides whether an attached USB device is evidence of *being
/// somewhere* — a dock, a desk, a conference room — or just a thing
/// the user happened to plug in (flash drive, phone on a charge
/// cable). The unknown-location prompt only fires when at least one
/// location-signal device is present; see
/// `AppDelegate.handleUnknownLocation`.
///
/// This is deliberately a *denylist* of known-transient classes, not
/// an allowlist of AV classes. A legitimate location can have zero
/// USB AV devices — a dock whose audio goes out over HDMI/DisplayPort
/// presents only hub + HID interfaces on the USB side — so requiring
/// a camera/mic/speaker would silently stop prompting at exactly the
/// setups the app exists for. Filtering only what we positively
/// recognize as transient fails open: an unclassifiable device still
/// prompts.
extension NamedUSBDevice {
    /// USB interface classes that mark a device as transient when
    /// they're the *only* thing it exposes: Still Image / PTP (0x06 —
    /// phones and cameras in transfer mode) and Mass Storage (0x08 —
    /// flash drives, card readers). Grow this list with real-world
    /// evidence, not speculation.
    private static let transientClasses: Set<Int> = [0x06, 0x08]

    /// Vendor-specific (0xFF) is discounted before the transient
    /// check rather than denylisted. An iPhone on a charge cable
    /// exposes PTP *plus* a vendor-specific usbmux interface — a
    /// strict subset rule would count it as signal and keep
    /// prompting. But a device that is *purely* vendor-specific
    /// tells us nothing, so it fails open to signal.
    private static let vendorSpecificClass = 0xFF

    /// True when this device should count toward "the user is at a
    /// location worth setting up". False only when every meaningful
    /// class on the device is a known-transient one.
    public var isLocationSignal: Bool {
        let meaningful = usbClasses.subtracting([Self.vendorSpecificClass])
        guard !meaningful.isEmpty else { return true }
        return !meaningful.isSubset(of: Self.transientClasses)
    }
}
