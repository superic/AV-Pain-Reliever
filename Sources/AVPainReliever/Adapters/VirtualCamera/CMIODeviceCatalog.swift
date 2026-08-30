import Foundation
import CoreMediaIO

/// Read-only lookups against the CMIO subsystem's device list.
///
/// Was private to `CMIOSinkWriter` until the host's post-activation
/// visibility check needed the same "does CMIO know this UID?"
/// question for a diagnostic cross-check (issue #120). The two
/// answers can disagree, and the disagreement is the whole
/// diagnosis: `CMIOObjectGetPropertyData(kCMIOHardwarePropertyDevices)`
/// re-reads the system's device list on every call, while
/// `AVCaptureDevice.DiscoverySession` answers from a per-process
/// cache that can stay frozen for the life of the process after an
/// in-place extension replace.
public enum CMIODeviceCatalog {
    /// The CMIO device whose `kCMIODevicePropertyDeviceUID` matches
    /// `uid`, or nil when the system's device list has no such
    /// device. Comparison is case-insensitive — the UID round-trips
    /// through CMIO as a plain string and case has never been
    /// load-bearing for it.
    public static func deviceID(forUID uid: String) -> CMIODeviceID? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        guard
            CMIOObjectGetPropertyDataSize(
                CMIOObjectID(kCMIOObjectSystemObject),
                &address, 0, nil,
                &dataSize
            ) == noErr,
            dataSize > 0
        else { return nil }

        let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        var devices = [CMIOObjectID](repeating: 0, count: count)
        var dataUsed: UInt32 = 0
        guard
            CMIOObjectGetPropertyData(
                CMIOObjectID(kCMIOObjectSystemObject),
                &address, 0, nil,
                dataSize, &dataUsed,
                &devices
            ) == noErr
        else { return nil }

        for device in devices {
            guard let candidate = copyDeviceUID(deviceID: device) else { continue }
            if candidate.caseInsensitiveCompare(uid) == .orderedSame {
                return device
            }
        }
        return nil
    }

    private static func copyDeviceUID(deviceID: CMIODeviceID) -> String? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var size: UInt32 = UInt32(MemoryLayout<CFString>.size)
        var uid: Unmanaged<CFString>?
        let status = CMIOObjectGetPropertyData(
            deviceID, &address, 0, nil, size, &size, &uid
        )
        guard status == noErr, let unmanaged = uid else { return nil }
        return unmanaged.takeRetainedValue() as String
    }
}
