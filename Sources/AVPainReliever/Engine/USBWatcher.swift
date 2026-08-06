import Foundation
import IOKit

/// USB device with its human-readable product + vendor names
/// attached. The resolver doesn't need names (matching is `(vid, pid)`
/// only), but the wizard UI does — when the user is picking which
/// devices belong to a location's fingerprint, "LG Electronics — USB
/// 2.1 Hub" is massively more useful than `vid=0x043e pid=0x9a61`,
/// and "LG UltraFine Display Camera" is unambiguous on its own.
public struct NamedUSBDevice: Hashable, Sendable, Identifiable {
    public let device: USBDevice
    /// USB Product Name string. `nil` when the device doesn't
    /// expose one — typically internal hub legs of multi-function
    /// devices like the LG UltraFine, which often have only a
    /// vendor name.
    public let name: String?
    /// USB Vendor Name string (e.g. "LG Electronics", "Apple Inc."),
    /// from IOKit's "USB Vendor Name" property. `nil` when the
    /// device doesn't expose one. Combined with `name` in the UI to
    /// disambiguate multi-function-device hub legs that share the
    /// same product label.
    public let vendorName: String?
    /// USB class codes observed on the device: `bDeviceClass` (when
    /// it's a meaningful value — `0x00` "per-interface" and `0xEF`
    /// "miscellaneous/IAD" are omitted) plus every child interface's
    /// `bInterfaceClass`. Empty when IOKit exposes no class data.
    /// Drives `isLocationSignal`; see `LocationSignal.swift`.
    public let usbClasses: Set<Int>

    public init(
        device: USBDevice,
        name: String?,
        vendorName: String? = nil,
        usbClasses: Set<Int> = []
    ) {
        self.device = device
        self.name = name
        self.vendorName = vendorName
        self.usbClasses = usbClasses
    }

    public var id: USBDevice { device }

    /// Human-friendly label for the wizard UI. Combines vendor +
    /// product name when both are available; falls back to whichever
    /// is set; falls back to `(unnamed device)` when neither is.
    public var displayName: String {
        Self.formatDisplayName(vendorName: vendorName, name: name)
    }

    /// Shared label-formatting ladder for callers that hold the
    /// vendor + product strings directly (e.g. the app's persisted
    /// `IgnoredLocation.Device`, which can't carry a live
    /// `NamedUSBDevice`). Keeps the wizard list and the Settings →
    /// Profiles "Ignored Locations" list rendering names identically
    /// for the same `(vendorName, name)` pair.
    public static func formatDisplayName(vendorName: String?, name: String?) -> String {
        switch (vendorName, name) {
        case let (.some(v), .some(n)): return "\(v) — \(n)"
        case (.some(let v), .none):    return v
        case (.none, .some(let n)):    return n
        case (.none, .none):           return "(unnamed device)"
        }
    }
}

/// Reads the set of currently-attached USB devices and notifies the
/// engine when that set changes. Production uses `IOKitUSBWatcher`;
/// tests inject a recording fake.
///
/// The engine re-enumerates fresh on every evaluation rather than
/// trusting an internal cache — USB events can race, duplicate, or be
/// dropped, so a confirmed snapshot at evaluation time is safer than
/// trying to maintain incremental state.
public protocol USBWatcher {
    /// Fresh snapshot of the currently-attached USB devices. Cheap
    /// (microseconds on modern Macs); call as often as needed.
    func currentDevices() -> Set<USBDevice>

    /// Like `currentDevices()` but also returns each device's
    /// human-readable name. Used by the wizard UI when the user picks
    /// which currently-attached devices belong to a new location's
    /// fingerprint. Order is not guaranteed (IOKit's enumeration
    /// order isn't stable), so callers that need a deterministic
    /// list should sort by name or `(vid, pid)`.
    func currentDevicesNamed() -> [NamedUSBDevice]

    /// Begin observing USB add/remove events. `onChange` fires once
    /// per IOKit event burst on the main thread. Must be paired with a
    /// `stop()` call before the watcher is deallocated.
    ///
    /// Notifications generated during registration (the "initial state"
    /// pings IOKit emits when first-match is registered) are
    /// suppressed — `onChange` only fires for genuine changes after
    /// `start()` returns.
    func start(onChange: @escaping () -> Void)

    /// Stop observing. Idempotent; safe to call from `deinit`.
    func stop()
}

/// Production `USBWatcher` backed by IOKit. Lifted from
/// `prototypes/usb-watcher.swift` once that prototype proved the
/// notification-port + drained-iterator pattern works (see
/// `docs/architecture.md` → "IOKit prototype findings").
///
/// Threading: the IOKit notification port is wired into the main run
/// loop, so `onChange` always fires on the main thread, matching the
/// rest of the engine's main-thread-only execution model.
public final class IOKitUSBWatcher: USBWatcher {
    /// Modern (XHCI) host-stack class. The legacy `IOUSBDevice` class
    /// returns nothing on Apple Silicon — confirmed during the IOKit
    /// prototype.
    private static let usbDeviceClass = "IOUSBHostDevice"

    private var notifyPort: IONotificationPortRef?
    private var addedIter: io_iterator_t = 0
    private var removedIter: io_iterator_t = 0
    private var firstAddDrainDone = false
    private var firstRemoveDrainDone = false
    private var onChange: (() -> Void)?
    private let logger: ApplierLogger?

    /// `logger`, when supplied, receives `.debug` lines for IOKit
    /// notification arming, suppressed initial drains, and per-burst
    /// add/remove counts. Default `nil` keeps tests quiet and the
    /// existing call sites source-compatible.
    public init(logger: ApplierLogger? = nil) {
        self.logger = logger
    }

    deinit {
        stop()
    }

    // MARK: - Snapshot

    public func currentDevices() -> Set<USBDevice> {
        guard let matching = IOServiceMatching(Self.usbDeviceClass) else {
            return []
        }
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iter) }
        var devices: Set<USBDevice> = []
        Self.drain(iter) { entry in
            if let device = Self.deviceInfo(entry) {
                devices.insert(device)
            }
        }
        return devices
    }

    public func currentDevicesNamed() -> [NamedUSBDevice] {
        guard let matching = IOServiceMatching(Self.usbDeviceClass) else {
            return []
        }
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iter) }
        var seen: Set<USBDevice> = []
        var named: [NamedUSBDevice] = []
        Self.drain(iter) { entry in
            guard let device = Self.deviceInfo(entry),
                  !seen.contains(device) else { return }
            seen.insert(device)
            named.append(NamedUSBDevice(
                device: device,
                name: Self.productName(entry),
                vendorName: Self.vendorName(entry),
                usbClasses: Self.usbClasses(entry)
            ))
        }
        // Sort for stable UI ordering (IOKit doesn't guarantee an
        // order, and the wizard list looks weird when devices shuffle
        // between renders). Use the same `displayName` the UI shows
        // so what the user sees is what drives the sort.
        return named.sorted { $0.displayName < $1.displayName }
    }

    // MARK: - Notifications

    public func start(onChange: @escaping () -> Void) {
        // Idempotent guard — calling start twice without an intervening
        // stop is a programmer error but shouldn't leak a notification
        // port.
        guard notifyPort == nil else { return }
        self.onChange = onChange
        logger?.debug("usb-watcher: starting (matching class=\(Self.usbDeviceClass))")

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            return
        }
        notifyPort = port

        let runLoopSource = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)

        // Pass `self` to the C-style callbacks via the refCon
        // parameter. Unmanaged.passUnretained is safe here because the
        // notification port and iterators are owned by `self` — they
        // can't outlive it.
        let context = Unmanaged.passUnretained(self).toOpaque()

        let addedCallback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            Unmanaged<IOKitUSBWatcher>.fromOpaque(refcon)
                .takeUnretainedValue()
                .handleAddedIterator(iterator)
        }

        let removedCallback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            Unmanaged<IOKitUSBWatcher>.fromOpaque(refcon)
                .takeUnretainedValue()
                .handleRemovedIterator(iterator)
        }

        // IOServiceMatching consumes one CF reference per call site, so
        // build a fresh dict for each subscription. (Lesson from the
        // IOKit prototype.)
        if let added = IOServiceMatching(Self.usbDeviceClass) {
            IOServiceAddMatchingNotification(
                port, kIOFirstMatchNotification, added,
                addedCallback, context, &addedIter
            )
        }
        if let removed = IOServiceMatching(Self.usbDeviceClass) {
            IOServiceAddMatchingNotification(
                port, kIOTerminatedNotification, removed,
                removedCallback, context, &removedIter
            )
        }

        // Manually drain the initial iterators to arm the
        // notifications. The first-match callback always fires once
        // synchronously here with all already-attached devices —
        // suppress those, since the caller already has the current set
        // via `currentDevices()`.
        handleAddedIterator(addedIter)
        handleRemovedIterator(removedIter)
    }

    public func stop() {
        guard let port = notifyPort else { return }
        logger?.debug("usb-watcher: stopping")
        // Release the iterators returned by IOServiceAddMatchingNotification
        // before destroying the port. Per Apple's IOKitLib.h
        // documentation, those iterators "should be released by the
        // caller when the notification is to be destroyed", and
        // IONotificationPortDestroy only releases the port + its
        // mach_ports + CFRunLoopSources — not the iterators themselves.
        if addedIter != 0 { IOObjectRelease(addedIter) }
        if removedIter != 0 { IOObjectRelease(removedIter) }
        IONotificationPortDestroy(port)
        notifyPort = nil
        addedIter = 0
        removedIter = 0
        firstAddDrainDone = false
        firstRemoveDrainDone = false
        onChange = nil
    }

    // MARK: - Iterator handlers

    private func handleAddedIterator(_ iter: io_iterator_t) {
        let suppress = !firstAddDrainDone
        var count = 0
        Self.drain(iter) { _ in count += 1 }
        firstAddDrainDone = true
        if suppress {
            logger?.debug("usb-watcher: initial-add drain (\(count) device(s)), suppressed")
        } else {
            logger?.debug("usb-watcher: add burst (\(count) device(s)), firing onChange")
            if count > 0 { onChange?() }
        }
    }

    private func handleRemovedIterator(_ iter: io_iterator_t) {
        let suppress = !firstRemoveDrainDone
        var count = 0
        Self.drain(iter) { _ in count += 1 }
        firstRemoveDrainDone = true
        if suppress {
            logger?.debug("usb-watcher: initial-remove drain (\(count) device(s)), suppressed")
        } else {
            logger?.debug("usb-watcher: remove burst (\(count) device(s)), firing onChange")
            if count > 0 { onChange?() }
        }
    }

    // MARK: - IOKit helpers

    /// Drain an iterator to exhaustion, releasing each entry.
    /// Non-negotiable per IOKit semantics — a partially-drained
    /// iterator stops re-arming the notification port.
    private static func drain(_ iter: io_iterator_t, body: (io_object_t) -> Void) {
        var entry = IOIteratorNext(iter)
        while entry != 0 {
            body(entry)
            IOObjectRelease(entry)
            entry = IOIteratorNext(iter)
        }
    }

    private static func deviceInfo(_ entry: io_object_t) -> USBDevice? {
        guard let vid = intProperty(entry, "idVendor"),
              let pid = intProperty(entry, "idProduct") else {
            return nil
        }
        return USBDevice(
            vendorID: vid,
            productID: pid,
            serialNumber: serialNumber(entry)
        )
    }

    private static func serialNumber(_ entry: io_object_t) -> String? {
        // Try the friendly "USB Serial Number" key first — many
        // devices expose it as a mirror of the underlying
        // `kUSBSerialNumberString`. Some devices (e.g., the
        // 0x1e4e:0x701f HDMI-to-USB capture cards we ship in the
        // home-office profile) only expose the raw key, so we have
        // to fall back. Without the fallback, fingerprints with a
        // pinned serial silently fail to match those devices and
        // the engine resolves to the implicit-fallback profile
        // instead of the configured one.
        for key in ["USB Serial Number", "kUSBSerialNumberString"] {
            guard let raw = IORegistryEntryCreateCFProperty(
                entry, key as CFString, kCFAllocatorDefault, 0
            ) else { continue }
            guard let serial = raw.takeRetainedValue() as? String,
                  !serial.isEmpty else { continue }
            return serial
        }
        return nil
    }

    private static func productName(_ entry: io_object_t) -> String? {
        guard let raw = IORegistryEntryCreateCFProperty(
            entry, "USB Product Name" as CFString, kCFAllocatorDefault, 0
        ) else {
            return nil
        }
        return raw.takeRetainedValue() as? String
    }

    /// Collect the device's USB class codes: `bDeviceClass` when it
    /// carries real signal, plus each child `IOUSBHostInterface`'s
    /// `bInterfaceClass`. Composite devices report `bDeviceClass` as
    /// `0x00` ("look at the interfaces") or `0xEF` (misc/IAD wrapper)
    /// — neither says anything about what the device *is*, so both
    /// are dropped rather than polluting the classifier's input.
    private static func usbClasses(_ entry: io_object_t) -> Set<Int> {
        var classes: Set<Int> = []
        if let deviceClass = intProperty(entry, "bDeviceClass"),
           deviceClass != 0x00, deviceClass != 0xEF {
            classes.insert(deviceClass)
        }
        var childIter: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &childIter) == KERN_SUCCESS else {
            return classes
        }
        defer { IOObjectRelease(childIter) }
        drain(childIter) { child in
            guard IOObjectConformsTo(child, "IOUSBHostInterface") != 0,
                  let interfaceClass = intProperty(child, "bInterfaceClass") else {
                return
            }
            classes.insert(interfaceClass)
        }
        return classes
    }

    private static func vendorName(_ entry: io_object_t) -> String? {
        guard let raw = IORegistryEntryCreateCFProperty(
            entry, "USB Vendor Name" as CFString, kCFAllocatorDefault, 0
        ) else {
            return nil
        }
        return raw.takeRetainedValue() as? String
    }

    private static func intProperty(_ entry: io_object_t, _ key: String) -> Int? {
        guard let raw = IORegistryEntryCreateCFProperty(
            entry, key as CFString, kCFAllocatorDefault, 0
        ) else {
            return nil
        }
        return raw.takeRetainedValue() as? Int
    }
}
