import Cocoa

typealias CGSConnectionID = Int32
typealias CGSSpaceID = UInt64

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSCopyManagedDisplaySpaces")
func _CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> Unmanaged<CFArray>

func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> [[String: Any]]? {
    _CGSCopyManagedDisplaySpaces(cid).takeRetainedValue() as? [[String: Any]]
}

@_silgen_name("CGSGetActiveSpace")
func CGSGetActiveSpace(_ cid: CGSConnectionID) -> CGSSpaceID

@_silgen_name("CGSManagedDisplayGetCurrentSpace")
func CGSManagedDisplayGetCurrentSpace(_ cid: CGSConnectionID, _ display: CFString) -> CGSSpaceID

/// Switches `display` to `space`. Private SkyLight API; the visual transition
/// is performed by WindowServer and does not require Accessibility permission.
@_silgen_name("CGSManagedDisplaySetCurrentSpace")
func CGSManagedDisplaySetCurrentSpace(_ cid: CGSConnectionID, _ display: CFString, _ space: CGSSpaceID)

enum CGSSpaceType: Int {
    case user = 0
    case fullscreen = 4
}

extension NSScreen {
    var cgDisplayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
    }

    var displayUUID: String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(cgDisplayID) else { return nil }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
    }
}

func uint64ID(_ any: Any?) -> UInt64? {
    (any as? NSNumber)?.uint64Value
}
