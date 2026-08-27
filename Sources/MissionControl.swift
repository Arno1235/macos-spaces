import Cocoa
import ApplicationServices
import Darwin

enum MissionControl {
    static func addDesktop(onDisplay displayID: String?) async -> Bool {
        let before = currentSpaceUUIDs()
        open()
        try? await Task.sleep(nanoseconds: 700_000_000)

        let pressed = pressAddDesktop(onDisplay: displayID)
        try? await Task.sleep(nanoseconds: 400_000_000)
        close()
        try? await Task.sleep(nanoseconds: 350_000_000)
        return pressed || currentSpaceUUIDs().subtracting(before).isEmpty == false
    }

    private static func open() {
        if sendDockNotification("com.apple.expose.awake") { return }
        let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }

    private static func close() {
        if sendDockNotification("com.apple.expose.awake") { return }
        postKey(53) // escape
    }

    private static func sendDockNotification(_ name: String) -> Bool {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CoreDockSendNotification") else {
            return false
        }
        typealias Fn = @convention(c) (CFString, Int32) -> Void
        unsafeBitCast(symbol, to: Fn.self)(name as CFString, 1)
        return true
    }

    private static func postKey(_ virtualKey: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private static func pressAddDesktop(onDisplay displayID: String?) -> Bool {
        guard let dock = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.dock"
        }) else { return false }

        let app = AXUIElementCreateApplication(dock.processIdentifier)
        let buttons = find(identifier: "mc.spaces.add", from: app)
        let fallback = find(description: "add desktop", from: app)
        let candidates = buttons.isEmpty ? fallback : buttons
        guard !candidates.isEmpty else { return false }

        let target = pick(candidates, onDisplay: displayID) ?? candidates[0]
        return AXUIElementPerformAction(target, kAXPressAction as CFString) == .success
    }

    private static func pick(_ buttons: [AXUIElement], onDisplay displayID: String?) -> AXUIElement? {
        guard let displayID,
              let screen = NSScreen.screens.first(where: { $0.displayUUID == displayID })
        else { return buttons.last }

        let screenID = screen.cgDisplayID
        return buttons.first { button in
            guard let frame = axFrame(button) else { return false }
            var count: UInt32 = 0
            var ids = [CGDirectDisplayID](repeating: 0, count: 4)
            CGGetDisplaysWithRect(frame, 4, &ids, &count)
            return ids.prefix(Int(count)).contains(screenID)
        } ?? buttons.last
    }

    private static func find(identifier: String, from root: AXUIElement) -> [AXUIElement] {
        find(from: root) { axString($0, kAXIdentifierAttribute as String) == identifier }
    }

    private static func find(description: String, from root: AXUIElement) -> [AXUIElement] {
        find(from: root) { value in
            let text = (axString(value, kAXDescriptionAttribute as String) ?? "").lowercased()
            return text == description.lowercased() || text.contains("add desktop")
        }
    }

    private static func find(from root: AXUIElement, matching: (AXUIElement) -> Bool) -> [AXUIElement] {
        var queue = children(root)
        var hits: [AXUIElement] = []
        var visited = 0
        while !queue.isEmpty, visited < 800 {
            let element = queue.removeFirst()
            visited += 1
            if matching(element) { hits.append(element) }
            queue.append(contentsOf: children(element))
        }
        return hits
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success else {
            return []
        }
        return (ref as? [AXUIElement]) ?? []
    }

    private static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func axFrame(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              CFGetTypeID(posRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }
        let pos = unsafeBitCast(posRef, to: AXValue.self)
        let size = unsafeBitCast(sizeRef, to: AXValue.self)
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(pos, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    private static func currentSpaceUUIDs() -> Set<String> {
        guard let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) else { return [] }
        var uuids: Set<String> = []
        for display in displays {
            guard let spaces = display["Spaces"] as? [[String: Any]] else { continue }
            for space in spaces {
                if let uuid = space["uuid"] as? String { uuids.insert(uuid) }
            }
        }
        return uuids
    }
}
