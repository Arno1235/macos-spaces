import Cocoa
import ApplicationServices

struct SavedWindow: Codable, Equatable {
    var bundleID: String
    var appName: String
    var title: String
    var windowID: UInt32
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var minimized: Bool

    var frame: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

struct SavedLayout: Codable, Equatable {
    var spaceUUID: String
    var spaceName: String
    var displayID: String?
    var savedAt: Date
    var windows: [SavedWindow]

    var bundleIDs: [String] {
        var seen: [String] = []
        for window in windows where !seen.contains(window.bundleID) {
            seen.append(window.bundleID)
        }
        return seen
    }
}

struct LayoutSummary: Equatable, Identifiable {
    var id: String { spaceUUID }
    var spaceUUID: String
    var spaceName: String
    var displayID: String?
    var savedAt: Date
    var windowCount: Int
    var bundleIDs: [String]
}

struct CaptureResult {
    var windowCount: Int
    var appCount: Int
}

struct RestoreResult {
    var placed: Int
    var launched: Int
    var missed: Int

    var message: String {
        var parts = ["Restored \(placed) window\(placed == 1 ? "" : "s")"]
        if launched > 0 {
            parts.append("launched \(launched) app\(launched == 1 ? "" : "s")")
        }
        if missed > 0 {
            parts.append("\(missed) could not be placed")
        }
        return parts.joined(separator: " · ")
    }
}

final class LayoutEngine {
    private let connection: CGSConnectionID
    private let storeURL: URL
    private var layouts: [String: SavedLayout] = [:]

    init(connection: CGSConnectionID = CGSMainConnectionID()) {
        self.connection = connection
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Spaces", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        self.storeURL = support.appendingPathComponent("layouts.json")
        load()
    }

    func summary(for spaceUUID: String) -> LayoutSummary? {
        layouts[spaceUUID].map(Self.summary(from:))
    }

    func summaries() -> [String: LayoutSummary] {
        Dictionary(uniqueKeysWithValues: layouts.map { ($0.key, Self.summary(from: $0.value)) })
    }

    func layout(for spaceUUID: String) -> SavedLayout? {
        layouts[spaceUUID]
    }

    func removeLayout(for spaceUUID: String) {
        layouts.removeValue(forKey: spaceUUID)
        save()
    }

    func rekey(from oldUUID: String, to newUUID: String) {
        guard var layout = layouts[oldUUID] else { return }
        layouts.removeValue(forKey: oldUUID)
        layout.spaceUUID = newUUID
        layouts[newUUID] = layout
        save()
    }

    private static func summary(from layout: SavedLayout) -> LayoutSummary {
        LayoutSummary(
            spaceUUID: layout.spaceUUID,
            spaceName: layout.spaceName,
            displayID: layout.displayID,
            savedAt: layout.savedAt,
            windowCount: layout.windows.count,
            bundleIDs: layout.bundleIDs
        )
    }

    static func isTrusted(prompt: Bool = false) -> Bool {
        if prompt {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
        return AXIsProcessTrusted()
    }

    func liveBundleIDs(in spaces: [Space]) -> [String: [String]] {
        let byManaged = Dictionary(uniqueKeysWithValues: spaces.map { ($0.managedID, $0) })
        var result: [String: [String]] = [:]
        for window in capturableWindows() {
            let space: Space?
            if let spaceID = window.spaceIDs.first(where: { byManaged[$0] != nil }) {
                space = byManaged[spaceID]
            } else if window.spaceIDs.isEmpty {
                space = spaces.first { candidate in
                    guard candidate.isCurrentOnDisplay,
                          let displayID = NSScreen.screens.first(where: { $0.displayUUID == candidate.displayID })?.cgDisplayID
                    else { return false }
                    return isOnDisplay(window.frame, displayID: displayID)
                }
            } else {
                space = nil
            }
            guard let space else { continue }
            if result[space.uuid]?.contains(window.bundleID) != true {
                result[space.uuid, default: []].append(window.bundleID)
            }
        }
        return result
    }

    @discardableResult
    func capture(_ space: Space) -> CaptureResult {
        let displayID = NSScreen.screens.first(where: { $0.displayUUID == space.displayID })?.cgDisplayID
        let windows = capturableWindows().compactMap { window -> SavedWindow? in
            let onThisSpace = window.spaceIDs.contains(space.managedID)
            let onThisDisplay = displayID.map { isOnDisplay(window.frame, displayID: $0) } ?? false
            let inferred = space.isCurrentOnDisplay && window.spaceIDs.isEmpty && onThisDisplay
            guard onThisSpace || inferred else { return nil }
            return SavedWindow(
                bundleID: window.bundleID,
                appName: window.appName,
                title: window.title,
                windowID: window.windowID,
                x: window.frame.origin.x,
                y: window.frame.origin.y,
                width: window.frame.size.width,
                height: window.frame.size.height,
                minimized: window.minimized
            )
        }

        layouts[space.uuid] = SavedLayout(
            spaceUUID: space.uuid,
            spaceName: space.displayName,
            displayID: space.displayID,
            savedAt: Date(),
            windows: windows
        )
        save()
        return CaptureResult(windowCount: windows.count, appCount: Set(windows.map(\.bundleID)).count)
    }

    func restore(
        _ layout: SavedLayout,
        onto space: Space,
        allSpaces: [Space],
        switchTo: @escaping (Space) async -> Void
    ) async -> RestoreResult {
        await switchTo(space)
        try? await Task.sleep(nanoseconds: 350_000_000)

        var launched = 0
        var launchedIDs: Set<String> = []
        for bundleID in layout.bundleIDs {
            if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID }) {
                continue
            }
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { continue }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
            launchedIDs.insert(bundleID)
            launched += 1
        }

        if launched > 0 {
            await waitForApps(bundleIDs: launchedIDs, timeout: 8)
            try? await Task.sleep(nanoseconds: 800_000_000)
        }

        var used = Set<CGWindowID>()
        var assignments: [(saved: SavedWindow, live: LiveWindow)] = []
        var live = capturableWindows(includeAX: false)

        for saved in layout.windows {
            if let match = matchWindow(saved, among: live, on: space, excluding: used) {
                used.insert(match.windowID)
                assignments.append((saved, match))
            }
        }

        WindowSpaceMover.move(assignments.map(\.live.windowID), to: space.managedID, connection: connection)
        try? await Task.sleep(nanoseconds: 350_000_000)
        await switchTo(space)
        try? await Task.sleep(nanoseconds: 300_000_000)

        let matchedBundles = Set(assignments.map(\.saved.bundleID))
        let missingBundles = layout.bundleIDs.filter { !matchedBundles.contains($0) }
        for bundleID in missingBundles {
            openOnCurrentSpace(bundleID: bundleID)
            launched += 1
        }
        if !missingBundles.isEmpty {
            try? await Task.sleep(nanoseconds: 900_000_000)
            live = capturableWindows(includeAX: false)
            let assignedSaved = Set(assignments.map(\.saved.windowID))
            for saved in layout.windows where !assignedSaved.contains(saved.windowID) {
                if let match = matchWindow(saved, among: live, on: space, excluding: used) {
                    used.insert(match.windowID)
                    assignments.append((saved, match))
                }
            }
        }

        let stillElsewhere = assignments.filter { assignment in
            axElement(
                pid: assignment.live.pid,
                windowID: assignment.live.windowID,
                title: assignment.saved.title,
                frame: assignment.saved.frame
            ) == nil
        }
        if !stillElsewhere.isEmpty {
            await dragWindowsOntoSpace(stillElsewhere.map(\.live), target: space, allSpaces: allSpaces, switchTo: switchTo)
            await switchTo(space)
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        var placed = 0
        for (saved, liveWindow) in assignments {
            if let element = axElement(
                pid: liveWindow.pid,
                windowID: liveWindow.windowID,
                title: saved.title,
                frame: saved.frame
            ) {
                setMinimized(element, saved.minimized)
                setFrame(element, saved.frame)
                AXUIElementPerformAction(element, kAXRaiseAction as CFString)
                placed += 1
            } else if liveWindow.spaceIDs.contains(space.managedID) {
                placed += 1
            }
        }

        let missed = max(0, layout.windows.count - placed)
        return RestoreResult(placed: placed, launched: launched, missed: missed)
    }

    func inferredDisplayID(for layout: SavedLayout) -> String? {
        if let stored = layout.displayID, NSScreen.screens.contains(where: { $0.displayUUID == stored }) {
            return stored
        }
        for window in layout.windows where window.width > 200 && window.height > 200 {
            var count: UInt32 = 0
            var ids = [CGDirectDisplayID](repeating: 0, count: 8)
            CGGetDisplaysWithRect(window.frame, 8, &ids, &count)
            if let display = ids.prefix(Int(count)).compactMap({ id in
                NSScreen.screens.first(where: { $0.cgDisplayID == id })?.displayUUID
            }).first {
                return display
            }
        }
        return nil
    }

    // MARK: - Capture internals

    private struct LiveWindow {
        let bundleID: String
        let appName: String
        let title: String
        let windowID: CGWindowID
        let frame: CGRect
        let minimized: Bool
        let spaceIDs: [CGSSpaceID]
        let element: AXUIElement?
        let pid: pid_t
    }

    private func openOnCurrentSpace(bundleID: String) {
        if bundleID == "com.google.Chrome" {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            proc.arguments = ["-a", "Google Chrome", "--args", "--new-window"]
            try? proc.run()
            return
        }
        if bundleID == "com.apple.finder" {
            NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser)
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
    }

    private func axElement(pid: pid_t, windowID: CGWindowID, title: String, frame: CGRect) -> AXUIElement? {
        let byID = axWindows(pid: pid)
        if let element = byID[windowID] { return element }

        let app = AXUIElementCreateApplication(pid)
        guard let windows: [AXUIElement] = axValue(app, kAXWindowsAttribute as String) else { return nil }
        if !title.isEmpty {
            let titled = windows.filter { axString($0, kAXTitleAttribute as String) == title }
            if titled.count == 1 { return titled[0] }
        }
        if let closest = windows.min(by: { frameDistance(axFrame($0), frame) < frameDistance(axFrame($1), frame) }),
           frameDistance(axFrame(closest), frame) < 80 {
            return closest
        }
        return nil
    }

    private func frameDistance(_ a: CGRect?, _ b: CGRect) -> CGFloat {
        guard let a else { return .greatestFiniteMagnitude }
        return abs(a.midX - b.midX) + abs(a.midY - b.midY) + abs(a.width - b.width) + abs(a.height - b.height)
    }

    private func dragWindowsOntoSpace(
        _ windows: [LiveWindow],
        target: Space,
        allSpaces: [Space],
        switchTo: @escaping (Space) async -> Void
    ) async {
        var remaining = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0) })
        var byKnownSpace: [CGSSpaceID: [LiveWindow]] = [:]
        var unknown: [LiveWindow] = []
        for window in windows {
            if let spaceID = window.spaceIDs.first(where: { id in allSpaces.contains(where: { $0.managedID == id }) }) {
                byKnownSpace[spaceID, default: []].append(window)
            } else {
                unknown.append(window)
            }
        }

        for space in allSpaces where !unknown.isEmpty && space.managedID != target.managedID {
            await switchTo(space)
            try? await Task.sleep(nanoseconds: 280_000_000)
            var found: [LiveWindow] = []
            for window in unknown {
                if axWindows(pid: window.pid)[window.windowID] != nil {
                    found.append(window)
                }
            }
            if !found.isEmpty {
                byKnownSpace[space.managedID, default: []].append(contentsOf: found)
                let foundIDs = Set(found.map(\.windowID))
                unknown.removeAll { foundIDs.contains($0.windowID) }
            }
        }

        let savedCursor = NSEvent.mouseLocation
        for (spaceID, group) in byKnownSpace {
            guard let source = allSpaces.first(where: { $0.managedID == spaceID }) else { continue }
            for window in group {
                guard remaining[window.windowID] != nil else { continue }
                await dragWindow(window, from: source, to: target, switchTo: switchTo)
                remaining.removeValue(forKey: window.windowID)
            }
        }
        postMouse(.mouseMoved, at: quartzPoint(fromCocoa: savedCursor))
    }

    private func dragWindow(
        _ window: LiveWindow,
        from source: Space,
        to target: Space,
        switchTo: @escaping (Space) async -> Void
    ) async {
        await switchTo(source)
        try? await Task.sleep(nanoseconds: 320_000_000)

        guard let element = axWindows(pid: window.pid)[window.windowID] ?? window.element else { return }
        setMinimized(element, false)
        try? await Task.sleep(nanoseconds: 80_000_000)
        let frame = axFrame(element) ?? window.frame
        let grab = grabPoint(for: frame)
        let quartz = quartzPoint(fromCocoa: grab)

        postMouse(.mouseMoved, at: quartz)
        try? await Task.sleep(nanoseconds: 30_000_000)
        postMouse(.leftMouseDown, at: quartz)
        postMouse(.leftMouseDragged, at: CGPoint(x: quartz.x + 4, y: quartz.y))
        try? await Task.sleep(nanoseconds: 50_000_000)

        await switchTo(target)
        try? await Task.sleep(nanoseconds: 400_000_000)
        postMouse(.leftMouseUp, at: quartzPoint(fromCocoa: grabPoint(for: frame)))
        try? await Task.sleep(nanoseconds: 80_000_000)
    }

    private func grabPoint(for frame: CGRect) -> CGPoint {
        if frame.height < 80 {
            return CGPoint(x: frame.midX, y: frame.midY)
        }
        return CGPoint(x: frame.midX, y: frame.maxY - 10)
    }

    private func quartzPoint(fromCocoa point: CGPoint) -> CGPoint {
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
        let maxY = primary?.frame.maxY ?? 0
        return CGPoint(x: point.x, y: maxY - point.y)
    }

    private func postMouse(_ type: CGEventType, at point: CGPoint) {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
        event?.post(tap: .cghidEventTap)
    }

    private func capturableWindows(includeAX: Bool = true) -> [LiveWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var skipped = Set<pid_t>()
        var context: [pid_t: (app: NSRunningApplication, bundleID: String, axByID: [CGWindowID: AXUIElement])] = [:]
        var result: [LiveWindow] = []
        let selfPID = pid_t(ProcessInfo.processInfo.processIdentifier)

        for info in list {
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let pidNumber = info[kCGWindowOwnerPID as String] as? NSNumber,
                  let number = info[kCGWindowNumber as String] as? NSNumber,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let quartz = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  quartz.width > 60, quartz.height > 60
            else { continue }

            let pid = pid_t(pidNumber.int32Value)
            if pid == selfPID || skipped.contains(pid) { continue }

            if (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue == 0 { continue }

            let appContext: (app: NSRunningApplication, bundleID: String, axByID: [CGWindowID: AXUIElement])
            if let existing = context[pid] {
                appContext = existing
            } else if let app = NSRunningApplication(processIdentifier: pid),
                      app.activationPolicy == .regular,
                      let bundleID = app.bundleIdentifier,
                      bundleID != Bundle.main.bundleIdentifier,
                      !Self.ignoredBundleIDs.contains(bundleID) {
                var axByID: [CGWindowID: AXUIElement] = [:]
                if includeAX, Self.isTrusted(prompt: false) {
                    axByID = axWindows(pid: pid)
                }
                let created = (app, bundleID, axByID)
                context[pid] = created
                appContext = created
            } else {
                skipped.insert(pid)
                continue
            }

            let windowID = CGWindowID(number.uint32Value)
            let ax = appContext.axByID[windowID]
            if let ax, let subrole = axString(ax, kAXSubroleAttribute as String),
               subrole != kAXStandardWindowSubrole as String {
                continue
            }

            let frame = ax.flatMap(axFrame) ?? quartz
            guard frame.width > 60, frame.height > 60 else { continue }

            let title = ax.flatMap { axString($0, kAXTitleAttribute as String) }
                ?? (info[kCGWindowName as String] as? String)
                ?? ""
            let minimized = ax.flatMap { axBool($0, kAXMinimizedAttribute as String) } ?? false

            result.append(LiveWindow(
                bundleID: appContext.bundleID,
                appName: appContext.app.localizedName ?? appContext.bundleID,
                title: title,
                windowID: windowID,
                frame: frame,
                minimized: minimized,
                spaceIDs: spacesContainingWindow(connection, windowID),
                element: ax,
                pid: pid
            ))
        }

        return result
    }

    private func isOnDisplay(_ frame: CGRect, displayID: CGDirectDisplayID) -> Bool {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        CGGetDisplaysWithRect(frame, 8, &ids, &count)
        return ids.prefix(Int(count)).contains(displayID)
    }

    private func matchWindow(
        _ saved: SavedWindow,
        among candidates: [LiveWindow],
        on space: Space,
        excluding used: Set<CGWindowID>
    ) -> LiveWindow? {
        let pool = candidates.filter { $0.bundleID == saved.bundleID && !used.contains($0.windowID) }
        guard !pool.isEmpty else { return nil }
        return pool.max { lhs, rhs in
            let left = score(lhs, saved: saved, space: space)
            let right = score(rhs, saved: saved, space: space)
            if left != right { return left < right }
            return frameDistance(lhs.frame, saved.frame) > frameDistance(rhs.frame, saved.frame)
        }
    }

    private func score(_ window: LiveWindow, saved: SavedWindow, space: Space) -> Int {
        var value = 1
        if window.windowID == saved.windowID { value += 8 }
        if !saved.title.isEmpty, window.title == saved.title { value += 4 }
        if window.spaceIDs.contains(space.managedID) { value += 2 }
        return value
    }

    private func waitForApps(bundleIDs: Set<String>, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            if bundleIDs.isSubset(of: running) { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private static let ignoredBundleIDs: Set<String> = [
        "com.apple.dock",
        "com.apple.WindowManager",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.loginwindow",
        "com.apple.systemuiserver",
        "com.apple.Spotlight",
        "com.apple.screencaptureui",
        "com.apple.TextInputMenuAgent",
        "com.apple.wallpaper.agent",
    ]

    // MARK: - AX

    private func axWindows(pid: pid_t) -> [CGWindowID: AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        guard let windows: [AXUIElement] = axValue(app, kAXWindowsAttribute as String) else { return [:] }
        var map: [CGWindowID: AXUIElement] = [:]
        for window in windows {
            var id: CGWindowID = 0
            if _AXUIElementGetWindow(window, &id) == .success {
                map[id] = window
            }
        }
        return map
    }

    private func axValue<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? T
    }

    private func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        axValue(element, attribute)
    }

    private func axBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        (axValue(element, attribute) as NSNumber?)?.boolValue
    }

    private func axFrame(_ element: AXUIElement) -> CGRect? {
        guard let position: AXValue = axValue(element, kAXPositionAttribute as String),
              let size: AXValue = axValue(element, kAXSizeAttribute as String)
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin),
              AXValueGetValue(size, .cgSize, &extent)
        else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    private func setFrame(_ element: AXUIElement, _ rect: CGRect) {
        var size = rect.size
        var origin = rect.origin
        guard let sizeValue = AXValueCreate(.cgSize, &size),
              let originValue = AXValueCreate(.cgPoint, &origin)
        else { return }
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, originValue)
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
    }

    private func setMinimized(_ element: AXUIElement, _ minimized: Bool) {
        AXUIElementSetAttributeValue(
            element,
            kAXMinimizedAttribute as CFString,
            minimized ? kCFBooleanTrue : kCFBooleanFalse
        )
    }

    // MARK: - Persistence

    private struct DiskStore: Codable {
        var layouts: [String: SavedLayout]
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: storeURL),
              let store = try? decoder.decode(DiskStore.self, from: data)
        else { return }
        layouts = store.layouts
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(DiskStore(layouts: layouts)) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
