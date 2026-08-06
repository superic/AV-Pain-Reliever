import Testing
@testable import AVPainReliever

/// Pins the transient-device classification that gates the
/// unknown-location prompt. The two fail-open arms (no class data,
/// vendor-specific only) are the load-bearing ones — a regression
/// there silently stops the prompt for devices we can't classify,
/// which is much worse than a spurious prompt.
@Suite("NamedUSBDevice.isLocationSignal")
struct LocationSignalTests {
    private func device(classes: Set<Int>) -> NamedUSBDevice {
        NamedUSBDevice(
            device: USBDevice(vendorID: 0x1234, productID: 0x5678),
            name: nil,
            usbClasses: classes
        )
    }

    @Test("mass-storage-only (flash drive) is transient")
    func massStorageOnly() {
        #expect(!device(classes: [0x08]).isLocationSignal)
    }

    @Test("still-image-only (camera in PTP mode) is transient")
    func stillImageOnly() {
        #expect(!device(classes: [0x06]).isLocationSignal)
    }

    @Test("PTP + vendor-specific (iPhone on a charge cable) is transient")
    func phone() {
        // The vendor-specific usbmux interface is discounted, not
        // counted as signal — otherwise every charging iPhone would
        // keep re-prompting.
        #expect(!device(classes: [0x06, 0xFF]).isLocationSignal)
    }

    @Test("storage + still-image combo (card reader) is transient")
    func storagePlusStillImage() {
        #expect(!device(classes: [0x06, 0x08]).isLocationSignal)
    }

    @Test("audio + storage combo is signal")
    func audioPlusStorage() {
        // A dock leg exposing audio alongside a card reader is a
        // location device — any non-transient class wins.
        #expect(device(classes: [0x01, 0x08]).isLocationSignal)
    }

    @Test("video device (webcam) is signal")
    func webcam() {
        #expect(device(classes: [0x0E, 0x01]).isLocationSignal)
    }

    @Test("hub is signal")
    func hub() {
        // Docks are location-defining even when audio rides
        // HDMI/DisplayPort instead of USB.
        #expect(device(classes: [0x09]).isLocationSignal)
    }

    @Test("HID (keyboard/mouse) is signal")
    func hid() {
        #expect(device(classes: [0x03]).isLocationSignal)
    }

    @Test("no class data fails open to signal")
    func noClassData() {
        #expect(device(classes: []).isLocationSignal)
    }

    @Test("vendor-specific-only fails open to signal")
    func vendorSpecificOnly() {
        #expect(device(classes: [0xFF]).isLocationSignal)
    }
}
