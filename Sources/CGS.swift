import Cocoa
import ApplicationServices
import Darwin

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

/// Moves windows between Spaces. `CGSMoveWindowsToManagedSpace` is a no-op on
/// Sequoia; the bridged SkyLight operation is what actually works.
enum WindowSpaceMover {
    private static let skyLight = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        RTLD_LAZY
    )
    private static let objcMsgSend: UnsafeMutableRawPointer? = {
        guard let handle = dlopen(nil, RTLD_LAZY) else { return nil }
        return dlsym(handle, "objc_msgSend")
    }()

    static func move(_ windowIDs: [CGWindowID], to space: CGSSpaceID, connection: CGSConnectionID) {
        let ids = windowIDs.filter { $0 != 0 }
        guard !ids.isEmpty else { return }

        if moveUsingBridgedOperation(ids, space: space) { return }
        if moveUsingCompatWorkspace(ids, space: space, connection: connection) { return }

        let array = ids.map { NSNumber(value: Int32(bitPattern: $0)) } as CFArray
        CGSMoveWindowsToManagedSpace(connection, array, space)
        if let handle = skyLight, let addAndRemove = dlsym(handle, "CGSSpaceAddWindowsAndRemoveFromSpaces") {
            typealias AddAndRemove = @convention(c) (CGSConnectionID, CGSSpaceID, CFArray, Int) -> Void
            unsafeBitCast(addAndRemove, to: AddAndRemove.self)(connection, space, array, 0x7)
        }
    }

    private static func moveUsingBridgedOperation(_ windowIDs: [CGWindowID], space: CGSSpaceID) -> Bool {
        guard let objcMsgSend,
              let operationClass = NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation") as? NSObject.Type
        else { return false }

        let initializer = NSSelectorFromString("initWithWindows:spaceID:")
        guard operationClass.instancesRespond(to: initializer) else { return false }

        typealias Alloc = @convention(c) (AnyClass, Selector) -> AnyObject
        typealias Init = @convention(c) (AnyObject, Selector, NSArray, UInt64) -> AnyObject?
        let allocated = unsafeBitCast(objcMsgSend, to: Alloc.self)(operationClass, NSSelectorFromString("alloc"))
        let numbers = windowIDs.map { NSNumber(value: Int32(bitPattern: $0)) } as NSArray
        guard let operation = unsafeBitCast(objcMsgSend, to: Init.self)(allocated, initializer, numbers, space) else {
            return false
        }

        let perform = NSSelectorFromString("performWithWMBridgeDelegate")
        if (operation as AnyObject).responds(to: perform) {
            typealias Perform = @convention(c) (AnyObject, Selector) -> AnyObject?
            _ = unsafeBitCast(objcMsgSend, to: Perform.self)(operation, perform)
            return true
        }

        if let handle = skyLight,
           let async = dlsym(handle, "SLSPerformAsynchronousBridgedWindowManagementOperation") {
            typealias Async = @convention(c) (AnyObject) -> Int64
            _ = unsafeBitCast(async, to: Async.self)(operation)
            return true
        }

        return false
    }

    private static func moveUsingCompatWorkspace(
        _ windowIDs: [CGWindowID],
        space: CGSSpaceID,
        connection: CGSConnectionID
    ) -> Bool {
        guard let handle = skyLight,
              let setCompat = dlsym(handle, "SLSSpaceSetCompatID"),
              let setWorkspace = dlsym(handle, "SLSSetWindowListWorkspace")
        else { return false }

        typealias SetCompat = @convention(c) (CGSConnectionID, CGSSpaceID, Int32) -> Int32
        typealias SetWorkspace = @convention(c) (CGSConnectionID, UnsafePointer<UInt32>, Int32, Int32) -> Int32
        let setCompatID = unsafeBitCast(setCompat, to: SetCompat.self)
        let setWindowListWorkspace = unsafeBitCast(setWorkspace, to: SetWorkspace.self)
        let token: Int32 = 0x7961_6265

        guard setCompatID(connection, space, token) == 0 else { return false }
        defer { _ = setCompatID(connection, space, 0) }

        let ids = windowIDs
        let status = ids.withUnsafeBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return setWindowListWorkspace(connection, base, Int32(buffer.count), token)
        }
        return status == 0
    }
}

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
