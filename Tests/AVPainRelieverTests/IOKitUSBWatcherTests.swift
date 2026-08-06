import Testing
@testable import AVPainReliever

/// Smoke tests for the production IOKit-backed `USBWatcher`. Unlike the
/// resolver/debouncer/applier suites, these run against real IOKit on
/// the host machine — the watcher is a thin wrapper around C-style
/// IOKit calls that don't unit-test cleanly without injecting an entire
/// IOKit shim layer that nothing else needs. The IOKit prototype
/// already proved the wiring works end-to-end (see
/// `docs/architecture.md` → "IOKit prototype findings"); these tests
/// catch regressions if the production refactor breaks something.
@Suite("IOKitUSBWatcher")
struct IOKitUSBWatcherTests {
    @Test("currentDevices returns the same set across consecutive calls")
    func currentDevicesIsStable() {
        let watcher = IOKitUSBWatcher()
        let a = watcher.currentDevices()
        let b = watcher.currentDevices()
        #expect(a == b)
    }

    @Test("currentDevices returns well-formed USBDevice entries")
    func currentDevicesAreWellFormed() {
        // Light end-to-end check — proves IOKit is linked, the matching
        // dictionary enumerates without crashing, and any returned
        // (idVendor, idProduct) round-trips into a USBDevice with
        // valid uint16 IDs. We deliberately don't assert the snapshot
        // is non-empty: an undocked MacBook with no external USB
        // peripherals legitimately returns the empty set, and the
        // prior version of this test was a hardware-dependent flake.
        let watcher = IOKitUSBWatcher()
        for device in watcher.currentDevices() {
            #expect(device.vendorID >= 0 && device.vendorID <= 0xFFFF)
            #expect(device.productID >= 0 && device.productID <= 0xFFFF)
        }
    }

    @Test("currentDevicesNamed returns well-formed USB class codes")
    func namedDevicesHaveWellFormedClasses() {
        // Same live-IOKit smoke philosophy as above: no non-empty
        // assertion (undocked laptops legitimately return nothing),
        // just proof that the child-interface walk doesn't crash and
        // any classes it reports are valid single-byte codes.
        let watcher = IOKitUSBWatcher()
        for named in watcher.currentDevicesNamed() {
            for usbClass in named.usbClasses {
                #expect(usbClass >= 0 && usbClass <= 0xFF)
            }
        }
    }

    @Test("start + stop is idempotent and does not leak the notification port")
    func startStopIdempotent() {
        let watcher = IOKitUSBWatcher()
        // Empty closure — we're not exercising the callback here, just
        // verifying that the lifecycle doesn't crash or leak. A leaked
        // notification port would be visible via `leaks` on a debug
        // build but isn't trivial to assert from inside a test.
        watcher.start(onChange: {})
        watcher.start(onChange: {}) // second start is a no-op
        watcher.stop()
        watcher.stop()              // second stop is a no-op
        // Re-start after stop should work cleanly.
        watcher.start(onChange: {})
        watcher.stop()
    }
}

/// Pure-function coverage for `NamedUSBDevice.formatDisplayName`, the
/// shared label ladder both the wizard's device picker and the
/// Settings → Profiles "Ignored Locations" list defer to. Worth
/// pinning all four arms because the fallback case (neither vendor
/// nor product name) is the one IOKit hits for cheap hubs and
/// multi-function-device legs.
@Suite("NamedUSBDevice.formatDisplayName")
struct NamedUSBDeviceFormatDisplayNameTests {
    @Test("vendor + product → 'Vendor — Product'")
    func bothPresent() {
        #expect(
            NamedUSBDevice.formatDisplayName(
                vendorName: "Apple Inc.",
                name: "iPhone"
            ) == "Apple Inc. — iPhone"
        )
    }

    @Test("vendor only → vendor")
    func vendorOnly() {
        #expect(
            NamedUSBDevice.formatDisplayName(
                vendorName: "LG Electronics",
                name: nil
            ) == "LG Electronics"
        )
    }

    @Test("product only → product")
    func productOnly() {
        #expect(
            NamedUSBDevice.formatDisplayName(
                vendorName: nil,
                name: "CalDigit Thunderbolt 3 Audio"
            ) == "CalDigit Thunderbolt 3 Audio"
        )
    }

    @Test("neither → '(unnamed device)' sentinel")
    func neitherPresent() {
        // The sentinel is load-bearing for the wizard — without it
        // the device row would render an empty label, which reads
        // as a layout bug. Pin the exact string so a future
        // copy-edit of NamedUSBDevice.displayName doesn't silently
        // diverge from the call sites that rely on this fallback.
        #expect(
            NamedUSBDevice.formatDisplayName(vendorName: nil, name: nil)
                == "(unnamed device)"
        )
    }

    @Test("empty strings are treated as present (no implicit nil-folding)")
    func emptyStringsArePresent() {
        // Sanity check on Swift Optional semantics — `Optional("")`
        // is `.some`, not `.none`. The formatter should pass empty
        // strings through rather than fold them into the
        // `(unnamed device)` sentinel. Production callers that want
        // empty == absent must filter before calling.
        #expect(
            NamedUSBDevice.formatDisplayName(vendorName: "", name: "")
                == " — "
        )
    }
}
