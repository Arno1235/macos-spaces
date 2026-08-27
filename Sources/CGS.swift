import Cocoa
import ApplicationServices

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

@_silgen_name("CGSCopySpacesForWindows")
func _CGSCopySpacesForWindows(_ cid: CGSConnectionID, _ mask: UInt32, _ windows: CFArray) -> Unmanaged<CFArray>?

func spacesContainingWindow(_ cid: CGSConnectionID, _ windowID: CGWindowID) -> [CGSSpaceID] {
    let ids = [NSNumber(value: windowID)] as CFArray
    guard let unmanaged = _CGSCopySpacesForWindows(cid, 0x7, ids),
          let numbers = unmanaged.takeRetainedValue() as? [NSNumber]
    else { return [] }
    return numbers.map(\.uint64Value)
}

@_silgen_name("CGSMoveWindowsToManagedSpace")
func CGSMoveWindowsToManagedSpace(_ cid: CGSConnectionID, _ windows: CFArray, _ space: CGSSpaceID)

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

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
